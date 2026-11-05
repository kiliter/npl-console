import '../pdf_diagnostics.dart';
import 'dart:convert';
import 'dart:math' as math;
import 'package:image/image.dart' as img;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'pdf_engine.dart';

class SharedPdfImage {
  final Uint8List png;
  final String source;
  final bool imported;
  final bool local;
  final bool staged;
  int? targetPage;
  int page;
  final double aspectRatio;
  Rect? bounds;
  Size? sourceSize;
  final String? objectId;
  List<Offset>? basis;
  SharedPdfImage(
    Uint8List bytes,
    this.source,
    this.page,
    this.aspectRatio, {
    this.imported = false,
    this.staged = false,
    bool? local,
    this.targetPage,
    this.bounds,
    this.sourceSize,
    this.objectId,
    this.basis,
  }) : local = local ?? imported,
       png = Uint8List.fromList(bytes);
}

class EditDocument {
  final String caseNo;
  final Uint8List original;
  Uint8List bytes;
  late Uint8List repairBase = original;
  late final List<int> sourcePageOrigins = List.generate(
    snapshot.pageCount,
    (page) => page,
  );
  final Set<int> mirrorPages = {};
  final Map<int, Uint8List> _thumbnails = {};
  final Map<int, Future<Uint8List>> _pendingThumbnails = {};
  Future<Uint8List> thumbnail(PdfEditEngine engine, int page) {
    final cached = _thumbnails[page];
    if (cached != null) return Future.value(cached);
    return _pendingThumbnails.putIfAbsent(page, () {
      final revision = bytes;
      final future = PdfDiagnostics.trace(
        '缩略图排队及渲染',
        () => engine.thumbnail(revision, page),
        data: {'页码': page + 1, '文档': identityHashCode(revision)},
      );
      future.then<void>(
        (png) {
          if (identical(bytes, revision)) {
            _thumbnails[page] = png;
            while (_thumbnails.length > 40) {
              _thumbnails.remove(_thumbnails.keys.first);
            }
          }
          if (identical(_pendingThumbnails[page], future)) {
            _pendingThumbnails.remove(page);
          }
        },
        onError: (Object _, StackTrace _) {
          if (identical(_pendingThumbnails[page], future)) {
            _pendingThumbnails.remove(page);
          }
        },
      );
      return future;
    });
  }

  int page = 0;
  PdfPageSnapshot snapshot;
  final List<Uint8List> undo = [], redo = [];
  Uint8List? saved;
  final _pages = <int, PdfPageSnapshot>{};
  final _pendingPages = <int, Future<PdfPageSnapshot>>{};
  List<Size> get pageSizes =>
      snapshot.pageSizes ?? List.filled(snapshot.pageCount, snapshot.size);

  /// 预览页缓存上限。快速编码的预览图约 0.3～0.6 MB，保留 8 页便于来回滚动。
  static const maxCachedPages = 8;

  /// 页面预览局部加载，不触发整个会话的 busy 或 notifyListeners。
  ///
  /// 各页请求直接交给引擎调度：PDFium 渲染在引擎内串行，PNG 编码在多个
  /// isolate 中并行；[isNeeded] 在真正轮到渲染时才判断，滚走的页面直接跳过。
  Future<PdfPageSnapshot> preview(
    PdfEditEngine engine,
    int index, {
    bool Function()? isNeeded,
  }) {
    if (index == page) return Future.value(snapshot);
    final cached = _pages.remove(index);
    if (cached != null) {
      _pages[index] = cached;
      return Future.value(cached);
    }
    return _pendingPages.putIfAbsent(index, () {
      final revision = bytes;
      PdfDiagnostics.record(
        '页面预览排队',
        data: {'页码': index + 1, '文档': identityHashCode(revision)},
      );
      final task =
          PdfDiagnostics.trace(
            '页面预览',
            () => engine.inspect(revision, index, isNeeded: isNeeded),
            data: {'页码': index + 1, '文档': identityHashCode(revision)},
          ).then((result) {
            if (identical(bytes, revision)) {
              _pages[index] = result;
              while (_pages.length > maxCachedPages ||
                  (_pages.length > 1 &&
                      _pages.values.fold<int>(0, (n, p) => n + p.png.length) >
                          24 * 1024 * 1024)) {
                _pages.remove(_pages.keys.first);
              }
            }
            return result;
          });
      task.then<void>(
        (_) {
          if (identical(_pendingPages[index], task)) {
            _pendingPages.remove(index);
          }
        },
        onError: (Object _, StackTrace _) {
          if (identical(_pendingPages[index], task)) {
            _pendingPages.remove(index);
          }
        },
      );
      return task;
    });
  }

  void releasePreview(int index, Future<PdfPageSnapshot> request) {
    if (identical(_pendingPages[index], request)) _pendingPages.remove(index);
  }

  void clearPreviews() {
    _thumbnails.clear();
    _pendingThumbnails.clear();
    _pages.clear();
    _pendingPages.clear();
  }

  EditDocument(this.caseNo, Uint8List initial, this.snapshot)
    : original = Uint8List.fromList(initial),
      bytes = Uint8List.fromList(initial);

  /// 与已保存版本不同。逐字节比较数 MB 的 PDF 代价不低，而工具栏每次刷新都要读取，
  /// 结果按 (bytes, saved) 的对象身份缓存；各操作总是替换字节数组而非原地修改。
  bool get dirty {
    final key = (bytes, saved);
    if (_dirtyKey != key) {
      _dirtyKey = key;
      _dirty = !listEquals(bytes, saved ?? original);
    }
    return _dirty;
  }

  /// 与原始单据不同，按 bytes 身份缓存，理由同 [dirty]。
  bool get edited {
    if (!identical(_editedBytes, bytes)) {
      _editedBytes = bytes;
      _edited = !listEquals(bytes, original);
    }
    return _edited;
  }

  Object? _dirtyKey;
  bool _dirty = false;
  Uint8List? _editedBytes;
  bool _edited = false;
  void commit(Uint8List next) {
    undo.add(bytes);
    while (undo.length > 8 ||
        (undo.length > 1 &&
            undo.fold<int>(0, (n, b) => n + b.length) > 64 * 1024 * 1024)) {
      undo.removeAt(0);
    }
    redo.clear();
    bytes = next;
    clearPreviews();
  }
}

/// Shared images are session-only. Closing/discarding an edit never writes OBS.
class PdfEditSession extends ChangeNotifier {
  final PdfEditEngine engine;
  EditDocument? source, target, previewTarget;
  final Map<int, List<PdfEditObject>> deletedImages = {};
  final List<SharedPdfImage> materials = [];
  bool busy = false;
  String? error;
  String? syncStatus;
  bool needsSync = false;

  /// 共享区图片（增删、放置、页码）及删除标记的版本号。
  /// 共享区卡片、连线和画布预览只依赖这些数据，按版本号判断是否需要刷新，
  /// 不必随 busy 切换、同步状态文字等其它通知一起重建。
  int materialsRevision = 0;
  int _revision = 0;
  bool _disposed = false;
  PdfEditSession({PdfEditEngine? engine}) : engine = engine ?? PdfEditEngine();

  Future<void> load(
    String targetNo,
    Uint8List targetBytes, {
    String? sourceNo,
    Uint8List? sourceBytes,
  }) async {
    final revision = ++_revision;
    busy = true;
    error = null;
    notifyListeners();
    try {
      // 新老单据同时发出：PDFium 渲染一份时，另一份的 PNG 编码并行进行。
      final targetTask = PdfDiagnostics.trace(
        '目标单据解析及渲染',
        () => engine.inspect(targetBytes, 0),
      );
      final sourceTask = sourceBytes == null
          ? null
          : PdfDiagnostics.trace(
              '来源单据解析及渲染',
              () => engine.inspect(sourceBytes, 0),
            );
      // 先挂上空监听，任一份先失败都不会变成未捕获异常；await 仍会收到错误。
      targetTask.ignore();
      sourceTask?.ignore();
      final nextTarget = await targetTask;
      final nextSource = await sourceTask;
      if (_disposed || revision != _revision) return;
      materials.clear();
      materialsRevision++;
      syncStatus = null;
      needsSync = false;
      target = EditDocument(targetNo, targetBytes, nextTarget);
      source = nextSource == null
          ? null
          : EditDocument(sourceNo!, sourceBytes!, nextSource);
      previewTarget = EditDocument(targetNo, targetBytes, nextTarget);
      deletedImages.clear();
    } catch (e) {
      if (!_disposed && revision == _revision) error = _message(e);
    } finally {
      if (!_disposed && revision == _revision) {
        busy = false;
        notifyListeners();
      }
    }
  }

  int targetPage(SharedPdfImage image) =>
      image.imported ? image.targetPage! : image.page - 1;
  List<SharedPdfImage> imagesForPage(int page) =>
      materials.where((m) => targetPage(m) == page).toList();
  int get unmatchedImages => materials
      .where((m) => targetPage(m) >= (target?.snapshot.pageCount ?? 0))
      .length;

  int get parkedImageCount =>
      materials.where((m) => m.staged && m.targetPage == -1).length;

  void previewChanged() {
    materialsRevision++;
    needsSync = true;
    syncStatus =
        '画布预览 · 点击应用后生成单据${unmatchedImages == 0 ? '' : ' · $unmatchedImages 张图片暂无对应页'}';
    notifyListeners();
  }

  void deleteTargetImage(int page, PdfEditObject object) {
    if (busy || target == null) return;
    final list = deletedImages.putIfAbsent(page, () => []);
    if (list.any((o) => o.id == object.id)) return;
    list.add(object);
    previewChanged();
  }

  /// 提取成功后才暂存并标记删除，失败不改变原图。
  Future<void> stashTargetImage(
    int page, {
    PdfEditObject? object,
    SharedPdfImage? material,
  }) async {
    final doc = previewTarget, revision = _revision;
    if (busy || doc == null || (object == null && material == null)) return;
    await _run(() async {
      if (page < 0 ||
          page >= doc.pageSizes.length ||
          (material != null && !materials.contains(material))) {
        throw const FormatException('图片已失效');
      }
      if (material == null &&
          (deletedImages[page]?.any((o) => o.id == object!.id) ?? false)) {
        return;
      }
      if (materials.length - (material == null ? 0 : 1) >= 30) {
        throw const FormatException('共享区最多保留 30 张图片');
      }
      final png =
          material?.png ?? await engine.extractImage(doc.bytes, page, object!);
      if (_disposed || revision != _revision) return;
      final used =
          materials.fold<int>(0, (n, m) => n + m.png.length) -
          (material?.png.length ?? 0);
      if (used + png.length > 64 * 1024 * 1024) {
        throw const FormatException('共享区超过 64 MiB');
      }
      final bounds = material?.bounds ?? object!.bounds;
      final image = SharedPdfImage(
        png,
        doc.caseNo,
        page + 1,
        bounds.width / bounds.height,
        imported: true,
        local: false,
        staged: true,
        targetPage: -1,
        bounds: bounds,
        sourceSize: material?.sourceSize ?? doc.pageSizes[page],
        basis: material?.basis ?? object?.basis,
      );
      if (material != null) materials.remove(material);
      materials.add(image);
      if (object != null) {
        final deleted = deletedImages.putIfAbsent(page, () => []);
        if (!deleted.any((o) => o.id == object.id)) deleted.add(object);
      }
      previewChanged();
    });
  }

  /// 拖放以鼠标落点为中心，保留图片尺寸和旋转，超出页面时等比缩小。
  void placeStagedImage(SharedPdfImage image, int page, Offset point) {
    final doc = previewTarget;
    if (busy ||
        doc == null ||
        !image.staged ||
        !materials.contains(image) ||
        page < 0 ||
        page >= doc.pageSizes.length) {
      return;
    }
    final old = image.bounds!,
        from = image.sourceSize!,
        to = doc.pageSizes[page];
    final w = old.width * from.width / to.width,
        h = old.height * from.height / to.height;
    final scale = math.min(1.0, math.min(1 / w, 1 / h));
    final width = w * scale, height = h * scale;
    final next = Rect.fromLTWH(
      (point.dx - width / 2).clamp(0.0, 1 - width),
      (point.dy - height / 2).clamp(0.0, 1 - height),
      width,
      height,
    );
    image.basis = image.basis
        ?.map(
          (p) => Offset(
            next.left + (p.dx - old.left) / old.width * next.width,
            next.top + (p.dy - old.top) / old.height * next.height,
          ),
        )
        .toList();
    image.bounds = next;
    image.sourceSize = to;
    image.targetPage = page;
    previewChanged();
  }

  void restoreDeletedImages(int page) {
    if (busy) return;
    deletedImages.remove(page);
    previewChanged();
  }

  Future<void> navigate(bool old, int page) async {
    final doc = old ? source : target;
    if (doc == null || busy || page < 0 || page >= doc.snapshot.pageCount) {
      return;
    }
    await _run(() async {
      final snapshot = await engine.inspect(doc.bytes, page);
      if (_disposed) return;
      doc.page = page;
      doc.snapshot = snapshot;
    });
  }

  Future<void> collect(PdfEditObject object) async {
    final doc = source;
    final revision = _revision;
    if (doc == null || busy) return;
    await _run(() async {
      if (materials.length >= 30) {
        throw const FormatException('共享素材最多保留 30 张，请先移除部分素材');
      }
      final png = await engine.extractImage(doc.bytes, doc.page, object);
      if (_disposed || revision != _revision) return;
      final image = img.decodePng(png)!;
      final ratio = image.width / image.height;
      final used = materials.fold<int>(0, (n, m) => n + m.png.length);
      if (used + png.length > 64 * 1024 * 1024) {
        throw const FormatException('共享素材超过 64 MiB，请先移除部分素材');
      }
      materials.add(SharedPdfImage(png, doc.caseNo, doc.page + 1, ratio));
      materialsRevision++;
    });
  }

  Future<void> collectSelected(
    List<({int page, PdfEditObject object, Size size})> selected,
  ) async {
    final doc = source, revision = _revision;
    if (doc == null || busy || selected.isEmpty) return;
    await _run(() async {
      final additions = <SharedPdfImage>[];
      var used = materials.fold<int>(0, (n, m) => n + m.png.length);
      for (final item in selected) {
        if (materials.any(
          (m) =>
              m.source == doc.caseNo &&
              m.page == item.page + 1 &&
              m.objectId == item.object.id,
        )) {
          continue;
        }
        if (materials.length + additions.length >= 30) {
          throw const FormatException('共享区最多保留 30 张图片');
        }
        final png = await engine.extractImage(
          doc.bytes,
          item.page,
          item.object,
        );
        if (_disposed || revision != _revision) return;
        used += png.length;
        if (used > 64 * 1024 * 1024) {
          throw const FormatException('共享区超过 64 MiB，请减少选图数量');
        }
        additions.add(
          SharedPdfImage(
            png,
            doc.caseNo,
            item.page + 1,
            item.object.bounds.width / item.object.bounds.height,
            bounds: item.object.bounds,
            sourceSize: item.size,
            objectId: item.object.id,
            basis: item.object.basis,
          ),
        );
      }
      materials.addAll(additions);
      if (additions.isNotEmpty) {
        materialsRevision++;
        needsSync = true;
        syncStatus = null;
      }
    });
    if (error == null && !_disposed && revision == _revision && needsSync) {
      previewChanged();
    }
  }

  Future<void> synchronize() async {
    final doc = target, revision = _revision;
    if (doc == null || busy || (materials.isEmpty && !needsSync)) return;
    await _run(() async {
      if (materials.any((m) => m.bounds == null || m.sourceSize == null)) {
        throw const FormatException('图片缺少原页码或坐标，请从旧单据重新选择');
      }
      final next = await engine.synchronizeImages(doc.repairBase, [
        for (final material in materials)
          if (targetPage(material) >= 0 &&
              targetPage(material) < doc.snapshot.pageCount)
            PdfImagePlacement(
              material.png,
              targetPage(material),
              material.bounds!,
              material.sourceSize!,
              basis: material.basis,
            ),
      ], removed: deletedImages);
      final snapshot = await engine.inspect(next, 0);
      if (_disposed || revision != _revision) return;
      doc.commit(next);
      doc.page = 0;
      doc.snapshot = snapshot;
      needsSync = false;
      syncStatus =
          '已应用，可保存到本地${parkedImageCount == 0 ? '' : '；$parkedImageCount 张暂存图片尚未放置'}${unmatchedImages == 0 ? '' : '；$unmatchedImages 张图片无对应页，未写入'}';
    });
  }

  /// 左侧镜像只增加当前会话的来源页，右侧 PDF 及图片同步选择保持原意。
  Future<void> mirrorSourcePage({
    required int page,
    required int insertAt,
  }) async {
    final doc = source, destination = target, revision = _revision;
    if (doc == null || destination == null || busy) return;
    await _run(() async {
      if (page < 0 ||
          page >= doc.snapshot.pageCount ||
          insertAt < 0 ||
          insertAt > doc.snapshot.pageCount) {
        throw const FormatException('镜像来源或插入位置超出范围');
      }
      final origins = List<int>.of(doc.sourcePageOrigins);
      final next = await engine.copyPage(doc.bytes, doc.bytes, page, insertAt);
      final snapshot = await engine.inspect(next, 0);
      if (_disposed || revision != _revision) return;
      final mirrors =
          doc.mirrorPages.map((old) => old >= insertAt ? old + 1 : old).toSet()
            ..add(insertAt);
      doc.sourcePageOrigins
        ..clear()
        ..addAll(origins..insert(insertAt, origins[page]));
      doc.mirrorPages
        ..clear()
        ..addAll(mirrors);
      for (final material in materials.where((m) => !m.imported)) {
        if (material.page - 1 >= insertAt) material.page++;
      }
      doc.commit(next);
      doc.page = 0;
      doc.snapshot = snapshot;
      previewChanged();
    });
  }

  Future<void> copyPageToTarget({
    required bool fromOld,
    required int page,
    required int insertAt,
  }) async {
    final doc = target, from = fromOld ? source : target, revision = _revision;
    if (doc == null || from == null || busy) return;
    final copies = fromOld ? <SharedPdfImage>[] : imagesForPage(page);
    final copiedDeletes = fromOld
        ? <PdfEditObject>[]
        : List<PdfEditObject>.of(deletedImages[page] ?? []);
    await _run(() async {
      if (materials.length + copies.length > 30 ||
          [...materials, ...copies].fold<int>(0, (n, m) => n + m.png.length) >
              64 * 1024 * 1024) {
        throw const FormatException('复制后的共享图片超过容量，请先减少共享图片');
      }
      final next = await engine.copyPage(
        doc.repairBase,
        fromOld ? from.bytes : doc.repairBase,
        page,
        insertAt,
      );
      final snapshot = await engine.inspect(next, 0);
      if (_disposed || revision != _revision) return;
      doc.repairBase = next;
      final shifted = {
        for (final entry in deletedImages.entries)
          (entry.key >= insertAt ? entry.key + 1 : entry.key): entry.value,
      };
      deletedImages
        ..clear()
        ..addAll(shifted);
      if (copiedDeletes.isNotEmpty) deletedImages[insertAt] = copiedDeletes;
      for (final material in materials.where((m) => m.imported)) {
        if (material.targetPage! >= insertAt) {
          material.targetPage = material.targetPage! + 1;
        }
      }
      for (final m in copies) {
        materials.add(
          SharedPdfImage(
            m.png,
            m.source,
            insertAt + 1,
            m.aspectRatio,
            imported: true,
            local: m.local,
            staged: m.staged,
            targetPage: insertAt,
            bounds: m.bounds,
            sourceSize: m.sourceSize,
            basis: m.basis,
          ),
        );
      }
      doc.commit(next);
      doc.page = 0;
      doc.snapshot = snapshot;
      previewTarget = EditDocument(doc.caseNo, next, snapshot);
      previewChanged();
    });
  }

  Future<void> importLocalImage(
    Uint8List bytes,
    String name,
    int page,
    Rect bounds,
  ) async {
    final doc = target, revision = _revision;
    if (doc == null || busy) return;
    await _run(() async {
      if (page < 0 || page >= doc.pageSizes.length) {
        throw const FormatException('目标页码超出范围');
      }
      if (materials.length >= 30 || bytes.length > 20 * 1024 * 1024) {
        throw const FormatException('共享区最多 30 张，单张图片不得超过 20 MiB');
      }
      final decoded = await compute(normalizeImportedImage, bytes);
      if (_disposed || revision != _revision) return;
      if (materials.fold<int>(decoded.png.length, (n, m) => n + m.png.length) >
          64 * 1024 * 1024) {
        throw const FormatException('共享区超过 64 MiB');
      }
      final material = SharedPdfImage(
        decoded.png,
        name,
        page + 1,
        decoded.ratio,
        imported: true,
        targetPage: page,
        bounds: bounds,
        sourceSize: doc.pageSizes[page],
      );
      materials.add(material);
      previewChanged();
    });
  }

  Future<void> _change(
    Future<Uint8List> Function(EditDocument) operation, {
    bool nextPage = false,
  }) async {
    final doc = target;
    if (doc == null || busy) return;
    await _run(() async {
      final bytes = await operation(doc);
      final page = doc.page + (nextPage ? 1 : 0);
      final snapshot = await engine.inspect(bytes, page);
      if (_disposed) return;
      doc.commit(bytes);
      doc.page = page;
      doc.snapshot = snapshot;
    });
  }

  Future<void> text(PdfEditObject object, String value) => _change((doc) async {
    final font = await rootBundle.load('assets/fonts/NotoSansSC-Regular.ttf');
    final raw =
        jsonDecode(
              await rootBundle.loadString('assets/fonts/NotoSansSC.cmap.json'),
            )
            as Map<String, dynamic>;
    final glyphs = {
      for (final e in raw.entries) int.parse(e.key): e.value as int,
    };
    return engine.replaceText(
      doc.bytes,
      doc.page,
      object,
      value,
      glyphs: glyphs,
      fontBytes: font.buffer.asUint8List(
        font.offsetInBytes,
        font.lengthInBytes,
      ),
    );
  });
  Future<void> insert(SharedPdfImage material, Offset at) => _change((doc) {
    final width = .38;
    final height =
        (width *
                doc.snapshot.size.width /
                material.aspectRatio /
                doc.snapshot.size.height)
            .clamp(.01, .8);
    final rect = Rect.fromLTWH(
      (at.dx - width / 2).clamp(0, 1 - width),
      (at.dy - height / 2).clamp(0, 1 - height),
      width,
      height,
    );
    return engine.insertImage(doc.bytes, doc.page, material.png, rect);
  });
  Future<void> replace(PdfEditObject object, Uint8List png) =>
      _change((doc) => engine.replaceImage(doc.bytes, doc.page, object, png));
  Future<void> move(PdfEditObject object, Rect bounds) =>
      _change((doc) => engine.moveImage(doc.bytes, doc.page, object, bounds));
  Future<void> delete(PdfEditObject object) =>
      _change((doc) => engine.deleteImage(doc.bytes, doc.page, object));
  Future<void> duplicate() => _change(
    (doc) => engine.duplicatePage(doc.bytes, doc.page),
    nextPage: true,
  );

  Future<void> discardChanges() async {
    final doc = target;
    if (doc == null || busy) return;
    await _run(() async {
      final snapshot = await engine.inspect(doc.original, 0);
      if (_disposed) return;
      doc.bytes = Uint8List.fromList(doc.original);
      doc.page = 0;
      doc.snapshot = snapshot;
      doc.undo.clear();
      doc.redo.clear();
      doc.saved = null;
    });
  }

  Future<void> history(bool redo) async {
    final doc = target;
    if (doc == null || busy) return;
    final from = redo ? doc.redo : doc.undo, to = redo ? doc.undo : doc.redo;
    if (from.isEmpty) return;
    await _run(() async {
      final next = from.last;
      var page = doc.page;
      // A duplicated last page may disappear on undo.
      PdfPageSnapshot snapshot;
      try {
        snapshot = await engine.inspect(next, page);
      } on FormatException {
        page = 0;
        snapshot = await engine.inspect(next, page);
      }
      if (_disposed) return;
      from.removeLast();
      to.add(doc.bytes);
      doc.bytes = next;
      doc.page = page;
      doc.snapshot = snapshot;
    });
  }

  void markSaved(Uint8List saved) {
    if (_disposed || target == null || !listEquals(target!.bytes, saved)) {
      return;
    }
    target!.saved = Uint8List.fromList(saved);
    notifyListeners();
  }

  Future<void> removeMaterial(SharedPdfImage image) async {
    if (busy) return;
    materials.remove(image);
    previewChanged();
  }

  void clearMaterials() {
    materials.clear();
    previewChanged();
  }

  void reset() {
    _revision++;
    engine.releaseDocuments();
    busy = false;
    source = target = previewTarget = null;
    deletedImages.clear();
    materials.clear();
    materialsRevision++;
    needsSync = false;
    syncStatus = null;
    error = null;
    notifyListeners();
  }

  Future<void> _run(Future<void> Function() task) async {
    if (busy) return;
    final revision = _revision;
    busy = true;
    error = null;
    notifyListeners();
    try {
      await task();
    } catch (e) {
      if (!_disposed && revision == _revision) error = _message(e);
    } finally {
      if (!_disposed && revision == _revision) {
        busy = false;
        notifyListeners();
      }
    }
  }

  static String _message(Object e) =>
      e is FormatException ? e.message : 'PDF 操作失败（${e.runtimeType}）';
  @override
  void dispose() {
    _disposed = true;
    _revision++;
    engine.releaseDocuments();
    materials.clear();
    source = target = previewTarget = null;
    deletedImages.clear();
    super.dispose();
  }
}

({Uint8List png, double ratio}) normalizeImportedImage(Uint8List bytes) {
  final decoder = img.findDecoderForData(bytes);
  final info = decoder?.startDecode(bytes);
  if (info == null ||
      info.width <= 0 ||
      info.height <= 0 ||
      info.width * info.height > 40000000) {
    throw const FormatException('图片无法读取或超过 4000 万像素');
  }
  final frame = decoder!.decodeFrame(0);
  if (frame == null) throw const FormatException('图片解码失败');
  final image = img.bakeOrientation(frame);
  return (
    png: Uint8List.fromList(img.encodePng(image)),
    ratio: image.width / image.height,
  );
}
