import 'dart:async';
import 'dart:collection';
import 'dart:ffi' as ffi;
import 'dart:io' show Platform;
import '../pdf_diagnostics.dart';
import '../pdf_memory_document.dart';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show compute, visibleForTesting;
import 'package:image/image.dart' as img;
import 'package:pdfrx/pdfrx.dart';
import 'package:pdfium_dart/pdfium_dart.dart' as native;

enum PdfObjectKind { text, image }

/// 预览、暂存、删除和导出使用同一归一化坐标容差。
bool sameImageBounds(Rect a, Rect b) =>
    (a.left - b.left).abs() < .0001 &&
    (a.top - b.top).abs() < .0001 &&
    (a.right - b.right).abs() < .0001 &&
    (a.bottom - b.bottom).abs() < .0001;

/// Object paths are indices within one immutable PDF revision, never native handles.
class PdfEditObject {
  final List<int> path;
  final PdfObjectKind kind;
  final Rect
  bounds; // Normalized displayed page coordinates, including rotation/crop.
  final String text;
  final double fontSize;
  final List<Offset>? basis;
  const PdfEditObject(
    this.path,
    this.kind,
    this.bounds, {
    this.text = '',
    this.fontSize = 12,
    this.basis,
  });
  String get id => path.join('.');
  bool get nested => path.length > 1;
}

class PdfPageSnapshot {
  final Uint8List png;
  final Size size;
  final List<PdfEditObject> objects;
  final int pageCount;
  final List<Size>? pageSizes;
  const PdfPageSnapshot(
    this.png,
    this.size,
    this.objects,
    this.pageCount, {
    this.pageSizes,
  });
}

/// 一张来源图片在目标单据中的页码和位置（页面左上角为原点）。
class PdfImagePlacement {
  final Uint8List png;
  final int page;
  final Rect bounds;
  final Size sourceSize;
  final List<Offset>? basis;
  const PdfImagePlacement(
    this.png,
    this.page,
    this.bounds,
    this.sourceSize, {
    this.basis,
  });
}

/// 页面渲染被调度到执行前已不再需要（如快速滚动时页面离开显示区域）。
class PdfRenderSkipped implements Exception {
  const PdfRenderSkipped();
  @override
  String toString() => '页面已离开显示区域';
}

/// PDFium 调度器。
///
/// PDFium 不是线程安全的，pdfrx 把全部调用集中在同一个后台 isolate 执行，
/// 多开 isolate 同时调用同一个动态库会破坏其全局状态，所以 PDFium 渲染只能串行。
/// 调度器保证同一时刻只有一个渲染任务占用文档，并让页面预览优先于缩略图：
/// 打开单据时缩略图条一次请求十几张，不能排在用户正在看的页面前面。
class _PdfiumScheduler {
  final _high = Queue<Future<void> Function()>(),
      _low = Queue<Future<void> Function()>();
  bool _running = false;

  Future<T> run<T>(Future<T> Function() task, {bool low = false}) {
    final completer = Completer<T>();
    (low ? _low : _high).add(() async {
      try {
        completer.complete(await task());
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    _drain();
    return completer.future;
  }

  Future<void> _drain() async {
    if (_running) return;
    _running = true;
    try {
      while (_high.isNotEmpty || _low.isNotEmpty) {
        await (_high.isNotEmpty ? _high.removeFirst() : _low.removeFirst())();
      }
    } finally {
      _running = false;
    }
  }
}

/// PNG 编码等纯 CPU 工作的并行池：在 PDFium 渲染下一页的同时，
/// 用多个 isolate（多核）并行编码已渲染的页面。并发数按 CPU 核数限制，
/// 每个任务持有一页原始像素（约 6 MB），不无限制地同时展开。
class _EncodePool {
  _EncodePool(this.size);
  final int size;
  int _active = 0;
  final _waiting = Queue<Completer<void>>();

  Future<T> run<T>(Future<T> Function() task) async {
    if (_active >= size) {
      final slot = Completer<void>();
      _waiting.add(slot);
      await slot.future;
    } else {
      _active++;
    }
    try {
      return await task();
    } finally {
      if (_waiting.isNotEmpty) {
        _waiting.removeFirst().complete();
      } else {
        _active--;
      }
    }
  }
}

/// PDFium calls run in pdfrx's worker isolate (including font callbacks). Every write uses a fresh
/// document: failures cannot partially mutate the user's current revision.
class PdfEditEngine {
  // 左右文档、页面和缩略图共用调度器，限制完整文档副本及位图同时驻留。
  static final _scheduler = _PdfiumScheduler();
  static final _encoders = _EncodePool(
    (Platform.numberOfProcessors - 1).clamp(1, 4),
  );

  /// 只读渲染复用已打开的文档。pdfrx 打开一份 5 MB 单据约 50～100 ms，
  /// 原先每渲染一页、每张缩略图都重新打开一次。按字节对象身份缓存最近的版本
  /// （修改总是生成新的字节数组），淘汰与释放都在调度器任务内进行，不会与渲染并发。
  final _documents = LinkedHashMap<Uint8List, Future<PdfDocument>>.identity();
  static const maxOpenDocuments = 4;

  /// 实际打开文档的次数，仅供测试验证缓存命中。
  @visibleForTesting
  int debugOpenCount = 0;

  Future<T> _native<T>(
    Uint8List bytes,
    T Function(native.PDFium, native.FPDF_DOCUMENT) task,
  ) async {
    await PdfDiagnostics.trace('修复引擎初始化', () => pdfrxFlutterInitialize());
    final result = await PdfDiagnostics.trace(
      'PDF原生处理',
      () => PdfrxEntryFunctions.instance.compute(_nativeWorker<T>, (
        bytes: bytes,
        task: task,
      )),
    );
    if (result.error != null) throw FormatException(result.error!);
    return result.value as T;
  }

  Future<PdfDocument> _document(Uint8List bytes) {
    final cached = _documents.remove(bytes);
    if (cached != null) return _documents[bytes] = cached;
    debugOpenCount++;
    final opening = openMemoryPdf(bytes, 'edit-${identityHashCode(bytes)}');
    _documents[bytes] = opening;
    opening.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {
        if (identical(_documents[bytes], opening)) _documents.remove(bytes);
      },
    );
    while (_documents.length > maxOpenDocuments) {
      _close(_documents.remove(_documents.keys.first)!);
    }
    return opening;
  }

  static void _close(Future<PdfDocument> document) => document.then(
    (doc) => PdfDiagnostics.trace('PDF文档释放', () => doc.dispose()),
    onError: (Object _, StackTrace _) {},
  );

  /// 释放缓存的已打开文档（关闭编辑页、切换环境时调用）。
  Future<void> releaseDocuments() => _scheduler.run(() async {
    final all = _documents.values.toList();
    _documents.clear();
    all.forEach(_close);
  });

  Future<T> _open<T>(
    Uint8List bytes,
    Future<T> Function(PdfDocument) task, {
    bool low = false,
    bool Function()? isNeeded,
  }) => _scheduler.run(() async {
    // 排队期间页面可能已滚出显示区域，轮到时再判断，避免渲染无人查看的页面。
    if (isNeeded != null && !isNeeded()) throw const PdfRenderSkipped();
    return task(await _document(bytes));
  }, low: low);

  /// 渲染一页预览。PDFium 只做对象解析与位图渲染；PNG 编码在释放调度器后
  /// 进入并行池，PDFium 可以立即开始渲染下一页。
  Future<PdfPageSnapshot> inspect(
    Uint8List bytes,
    int pageIndex, {
    bool Function()? isNeeded,
  }) async {
    final objectsTask = PdfDiagnostics.trace(
      '页面对象解析',
      () => _inspectObjects(bytes, pageIndex),
      data: {'页码': pageIndex + 1, '文档': identityHashCode(bytes)},
    );
    final renderTask = _open(bytes, isNeeded: isNeeded, (doc) async {
      if (pageIndex < 0 || pageIndex >= doc.pages.length) {
        throw const FormatException('页码超出范围');
      }
      final p = doc.pages[pageIndex];
      final image = await PdfDiagnostics.trace(
        '页面位图渲染',
        () => p.render(
          fullWidth: math.min(p.width * 1.8, 1500),
          fullHeight: math.min(p.width * 1.8, 1500) * p.height / p.width,
        ),
        data: {'页码': pageIndex + 1, '文档': identityHashCode(bytes)},
      );
      if (image == null) throw const FormatException('无法渲染 PDF');
      try {
        return (
          // 原生像素随 dispose 释放，复制到 Dart 堆后即可交还调度器。
          pixels: Uint8List.fromList(image.pixels),
          width: image.width,
          height: image.height,
          size: Size(p.width, p.height),
          pageCount: doc.pages.length,
          pageSizes: [
            for (final page in doc.pages) Size(page.width, page.height),
          ],
        );
      } finally {
        image.dispose();
      }
    });
    // 两者同时发出：对象解析与渲染在 pdfrx 后台依次执行，中间不留往返空档。
    // 先挂上空监听，任何一方先失败都不会变成未捕获异常；下面的 await 仍会收到错误。
    objectsTask.ignore();
    renderTask.ignore();
    final objects = await objectsTask;
    final page = await renderTask;
    final png = await PdfDiagnostics.trace(
      '页面PNG编码',
      () => _encode(page.pixels, page.width, page.height),
      data: {'页码': pageIndex + 1, '文档': identityHashCode(bytes)},
    );
    return PdfPageSnapshot(
      png,
      page.size,
      objects,
      page.pageCount,
      pageSizes: page.pageSizes,
    );
  }

  /// 预览图快速编码：压缩等级 1、不做行过滤。实测 1071×1515 的扫描单据页
  /// 编码由约 90 ms 降到约 20 ms，体积与默认参数相当；预览图不写入 PDF，画质无损。
  static Future<Uint8List> _encode(
    Uint8List pixels,
    int width,
    int height, {
    int? stride,
    int format = 4,
  }) => _encoders.run(
    () => compute(_encodePreview, (
      pixels: pixels,
      width: width,
      height: height,
      stride: stride ?? width * 4,
      format: format,
    )),
  );

  Future<List<PdfEditObject>> _inspectObjects(Uint8List bytes, int pageIndex) {
    return _native(bytes, (a, pdf) {
      final page = a.FPDF_LoadPage(pdf, pageIndex);
      if (page == ffi.nullptr) throw const FormatException('无法读取 PDF 页面');
      final textPage = a.FPDFText_LoadPage(page);
      try {
        final found = <PdfEditObject>[];
        void walk(
          native.FPDF_PAGEOBJECT? parent,
          List<int> prefix,
          _Matrix transform,
          int depth,
        ) {
          if (depth > 16) return;
          final count = parent == null
              ? a.FPDFPage_CountObjects(page)
              : a.FPDFFormObj_CountObjects(parent);
          for (var i = 0; i < count; i++) {
            final object = parent == null
                ? a.FPDFPage_GetObject(page, i)
                : a.FPDFFormObj_GetObject(parent, i);
            final type = a.FPDFPageObj_GetType(object), path = [...prefix, i];
            if (type == 5) {
              walk(object, path, transform * _matrix(a, object), depth + 1);
              continue;
            }
            if (type != 1 && type != 3) continue;
            final points = calloc<ffi.Float>(4);
            try {
              if (a.FPDFPageObj_GetBounds(
                    object,
                    points,
                    points + 1,
                    points + 2,
                    points + 3,
                  ) ==
                  0) {
                continue;
              }
              final bounds = Rect.fromLTRB(
                points[0],
                points[1],
                points[2],
                points[3],
              );
              final corners =
                  [
                        bounds.topLeft,
                        bounds.topRight,
                        bounds.bottomLeft,
                        bounds.bottomRight,
                      ]
                      .map(transform.apply)
                      .map((p) => _toDisplay(a, page, p))
                      .toList();
              final display = _box(corners);
              if (display.isEmpty) continue;
              var text = '', fontSize = 12.0;
              if (type == 1 && textPage != ffi.nullptr) {
                final length = a.FPDFTextObj_GetText(
                  object,
                  textPage,
                  ffi.nullptr,
                  0,
                );
                if (length > 2) {
                  final buffer = calloc<ffi.Uint16>((length + 1) ~/ 2);
                  try {
                    a.FPDFTextObj_GetText(
                      object,
                      textPage,
                      buffer.cast(),
                      length,
                    );
                    text = String.fromCharCodes(
                      buffer.asTypedList(length ~/ 2 - 1),
                    );
                  } finally {
                    calloc.free(buffer);
                  }
                }
                final size = calloc<ffi.Float>();
                try {
                  if (a.FPDFTextObj_GetFontSize(object, size) != 0) {
                    fontSize = size.value;
                  }
                } finally {
                  calloc.free(size);
                }
              }
              found.add(
                PdfEditObject(
                  List.unmodifiable(path),
                  type == 1 ? PdfObjectKind.text : PdfObjectKind.image,
                  display,
                  text: text,
                  fontSize: fontSize,
                  basis: type == 3
                      ? [
                              const Offset(0, 0),
                              const Offset(1, 0),
                              const Offset(0, 1),
                            ]
                            .map(
                              (point) => _toDisplay(
                                a,
                                page,
                                (transform * _matrix(a, object)).apply(point),
                              ),
                            )
                            .toList()
                      : null,
                ),
              );
            } finally {
              calloc.free(points);
            }
          }
        }

        walk(null, [], const _Matrix(), 0);
        return found;
      } finally {
        if (textPage != ffi.nullptr) a.FPDFText_ClosePage(textPage);
        a.FPDF_ClosePage(page);
      }
    });
  }

  Future<Uint8List> extractImage(
    Uint8List bytes,
    int index,
    PdfEditObject selected,
  ) {
    if (selected.kind != PdfObjectKind.image) {
      throw const FormatException('请选择图片对象');
    }
    return _native(bytes, (a, pdf) {
      if ((a.FPDF_GetDocPermissions(pdf) & 16) == 0) {
        throw const FormatException('此 PDF 不允许提取图片');
      }
      final page = a.FPDF_LoadPage(pdf, index);
      try {
        final object = _find(a, page, selected.path);
        final raw = a.FPDFImageObj_GetBitmap(object);
        if (raw != ffi.nullptr) {
          try {
            final w = a.FPDFBitmap_GetWidth(raw),
                h = a.FPDFBitmap_GetHeight(raw);
            if (w <= 0 || h <= 0 || w * h > 40000000) {
              throw const FormatException('图片尺寸过大');
            }
            _setMatrix(
              a,
              object,
              _Matrix(w.toDouble(), 0, 0, h.toDouble(), 0, 0),
            );
          } finally {
            a.FPDFBitmap_Destroy(raw);
          }
        }
        // Render only this image object (not a screenshot of the page), respecting its alpha mask.
        final bitmap = a.FPDFImageObj_GetRenderedBitmap(pdf, page, object);
        if (bitmap == ffi.nullptr) throw const FormatException('图片无法提取');
        try {
          final w = a.FPDFBitmap_GetWidth(bitmap),
              h = a.FPDFBitmap_GetHeight(bitmap);
          final stride = a.FPDFBitmap_GetStride(bitmap);
          if (w <= 0 || h <= 0 || w * h > 40000000) {
            throw const FormatException('图片过大或数据异常');
          }
          final pixels = a.FPDFBitmap_GetBuffer(
            bitmap,
          ).cast<ffi.Uint8>().asTypedList(stride * h);
          return _png(pixels, w, h, stride, a.FPDFBitmap_GetFormat(bitmap));
        } finally {
          a.FPDFBitmap_Destroy(bitmap);
        }
      } finally {
        a.FPDF_ClosePage(page);
      }
    });
  }

  Future<Uint8List> _write(
    Uint8List bytes,
    int index,
    void Function(native.PDFium, native.FPDF_DOCUMENT, native.FPDF_PAGE) edit,
  ) => _native(bytes, (a, pdf) {
    // Respect document modification restrictions; do not remove security.
    if ((a.FPDF_GetDocPermissions(pdf) & 8) == 0) {
      throw const FormatException('此 PDF 不允许修改');
    }
    final page = a.FPDF_LoadPage(pdf, index);
    if (page == ffi.nullptr) throw const FormatException('页码超出范围');
    try {
      edit(a, pdf, page);
      if (a.FPDFPage_GenerateContent(page) == 0) {
        throw const FormatException('PDF 内容写入失败');
      }
    } finally {
      a.FPDF_ClosePage(page);
    }
    return _saveNative(a, pdf);
  });

  Future<Uint8List> replaceText(
    Uint8List bytes,
    int page,
    PdfEditObject object,
    String text, {
    Uint8List? fontBytes,
    Map<int, int>? glyphs,
  }) {
    if (object.kind != PdfObjectKind.text) {
      throw const FormatException('请选择文字对象');
    }
    if (object.nested) throw const FormatException('此文字位于组合对象内，暂不支持直接修改');
    if (text.contains('\n') || text.contains('\r')) {
      throw const FormatException('请按原文字块编辑，暂不支持跨行重排');
    }
    if (fontBytes == null || fontBytes.isEmpty || glyphs == null) {
      throw const FormatException('缺少编辑字体');
    }
    return _write(bytes, page, (a, pdf, p) {
      final old = _find(a, p, object.path), matrix = _matrix(a, old);
      final runes = text.runes.toList(), unique = runes.toSet().toList();
      if (unique.any((r) => glyphs[r] == null)) {
        throw const FormatException('内置字体不包含部分字符，请使用支持的中英文字符');
      }
      final buffer = calloc<ffi.Uint8>(fontBytes.length)
        ..asTypedList(fontBytes.length).setAll(0, fontBytes);
      final ids = {for (var i = 0; i < unique.length; i++) unique[i]: i + 1};
      final cmap = StringBuffer(
        '/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def /CMapName /NPL-UCS def /CMapType 2 def 1 begincodespacerange <0000> <FFFF> endcodespacerange ',
      );
      for (var start = 0; start < unique.length; start += 100) {
        final chunk = unique.skip(start).take(100).toList();
        cmap.write('${chunk.length} beginbfchar ');
        for (final r in chunk) {
          final unicode = String.fromCharCode(
            r,
          ).codeUnits.map((c) => c.toRadixString(16).padLeft(4, '0')).join();
          cmap.write(
            '<${ids[r]!.toRadixString(16).padLeft(4, '0')}> <$unicode> ',
          );
        }
        cmap.write('endbfchar ');
      }
      cmap.write(
        'endcmap CMapName currentdict /CMap defineresource pop end end',
      );
      final unicodeMap = cmap.toString().toNativeUtf8();
      final cidMap = calloc<ffi.Uint8>((unique.length + 1) * 2);
      for (final r in unique) {
        final gid = glyphs[r]!, at = ids[r]! * 2;
        cidMap[at] = gid >> 8;
        cidMap[at + 1] = gid & 255;
      }
      final charcodes = calloc<ffi.Uint32>(runes.isEmpty ? 1 : runes.length);
      for (var i = 0; i < runes.length; i++) {
        charcodes[i] = ids[runes[i]]!;
      }
      native.FPDF_FONT? font;
      native.FPDF_PAGEOBJECT? next;
      try {
        font = a.FPDFText_LoadCidType2Font(
          pdf,
          buffer,
          fontBytes.length,
          unicodeMap.cast(),
          cidMap,
          (unique.length + 1) * 2,
        );
        if (font == ffi.nullptr) throw const FormatException('无法加载编辑字体');
        next = a.FPDFPageObj_CreateTextObj(pdf, font, object.fontSize);
        if (next == ffi.nullptr ||
            a.FPDFText_SetCharcodes(next, charcodes, runes.length) == 0) {
          throw const FormatException('文字写入失败');
        }
        _setMatrix(a, next, matrix);
        final colors = calloc<ffi.UnsignedInt>(4);
        try {
          if (a.FPDFPageObj_GetFillColor(
                old,
                colors,
                colors + 1,
                colors + 2,
                colors + 3,
              ) !=
              0) {
            a.FPDFPageObj_SetFillColor(
              next,
              colors[0],
              colors[1],
              colors[2],
              colors[3],
            );
          }
        } finally {
          calloc.free(colors);
        }
        // Replace at the original z-order, not a white cover or a screenshot.
        if (a.FPDFPage_RemoveObject(p, old) == 0) {
          throw const FormatException('原文字移除失败');
        }
        a.FPDFPageObj_Destroy(old);
        final inserted = a.FPDFPage_InsertObjectAtIndex(
          p,
          next,
          object.path.first,
        );
        next =
            null; // InsertObjectAtIndex consumes the object on success or failure.
        if (inserted == 0) throw const FormatException('新文字插入失败');
      } finally {
        if (next != null && next != ffi.nullptr) a.FPDFPageObj_Destroy(next);
        calloc.free(buffer);
        calloc.free(unicodeMap);
        calloc.free(cidMap);
        calloc.free(charcodes);
        if (font != null && font != ffi.nullptr) a.FPDFFont_Close(font);
      }
    });
  }

  Future<Uint8List> insertImage(
    Uint8List bytes,
    int page,
    Uint8List png,
    Rect bounds,
  ) {
    _validateBounds(bounds);
    return _write(bytes, page, (a, pdf, p) {
      final object = a.FPDFPageObj_NewImageObj(pdf);
      try {
        _setImage(a, object, png);
        _setMatrix(a, object, _displayMatrix(a, p, bounds));
      } catch (_) {
        a.FPDFPageObj_Destroy(object);
        rethrow;
      }
      if (a.FPDFPage_InsertObject(p, object) == 0) {
        throw const FormatException('图片插入失败');
      }
    });
  }

  /// 整批修复只打开、序列化一次 PDF；任一页失败均不返回部分结果。
  Future<Uint8List> synchronizeImages(
    Uint8List bytes,
    List<PdfImagePlacement> images, {
    Map<int, List<PdfEditObject>> removed = const {},
  }) => _native(bytes, (a, pdf) {
    if ((a.FPDF_GetDocPermissions(pdf) & 8) == 0) {
      throw const FormatException('此 PDF 不允许修改');
    }
    final count = a.FPDF_GetPageCount(pdf);
    for (final image in images) {
      if (image.page < 0 || image.page >= count) {
        throw FormatException('新单据没有第 ${image.page + 1} 页，无法同步；请核对新老单据');
      }
    }
    final pages = {...images.map((image) => image.page), ...removed.keys};
    for (final index in pages) {
      final page = a.FPDF_LoadPage(pdf, index);
      if (page == ffi.nullptr) throw const FormatException('无法读取目标页面');
      try {
        _removeImages(a, page, removed[index] ?? []);
        final width = a.FPDF_GetPageWidthF(page),
            height = a.FPDF_GetPageHeightF(page);
        final originals =
            <(native.FPDF_PAGEOBJECT, native.FPDF_PAGEOBJECT?, Rect)>[];
        void collectOriginals(
          native.FPDF_PAGEOBJECT? parent,
          _Matrix transform,
        ) {
          final count = parent == null
              ? a.FPDFPage_CountObjects(page)
              : a.FPDFFormObj_CountObjects(parent);
          for (var i = 0; i < count; i++) {
            final object = parent == null
                ? a.FPDFPage_GetObject(page, i)
                : a.FPDFFormObj_GetObject(parent, i);
            final type = a.FPDFPageObj_GetType(object);
            if (type == 5) {
              collectOriginals(object, transform * _matrix(a, object));
            } else if (type == 3) {
              final matrix = transform * _matrix(a, object);
              final bounds = _box(
                [
                  const Offset(0, 0),
                  const Offset(1, 0),
                  const Offset(0, 1),
                  const Offset(1, 1),
                ].map(matrix.apply).map((p) => _toDisplay(a, page, p)).toList(),
              );
              originals.add((object, parent, bounds));
            }
          }
        }

        collectOriginals(null, const _Matrix());
        for (final image in images.where((image) => image.page == index)) {
          // 保留原图相对于可见页左上角的实际尺寸和坐标，不随纸张尺寸拉伸。
          final r = Rect.fromLTWH(
            image.bounds.left * image.sourceSize.width / width,
            image.bounds.top * image.sourceSize.height / height,
            image.bounds.width * image.sourceSize.width / width,
            image.bounds.height * image.sourceSize.height / height,
          );
          _validateBounds(r);
          final basis = image.basis;
          final _Matrix placement;
          if (basis != null && basis.length == 3) {
            final points = basis
                .map(
                  (point) => _fromDisplay(
                    a,
                    page,
                    Offset(
                      point.dx * image.sourceSize.width / width,
                      point.dy * image.sourceSize.height / height,
                    ),
                  ),
                )
                .toList();
            final origin = points[0],
                x = points[1] - origin,
                y = points[2] - origin;
            placement = _Matrix(x.dx, x.dy, y.dx, y.dy, origin.dx, origin.dy);
          } else {
            placement = _displayMatrix(a, page, r);
          }
          // 仅删除底稿中匹配的图片，再将图层按共享区顺序追加到最上方。
          // 不能重新搜索刚插入的图层，否则同坐标透明图会互相覆盖。
          for (final original in originals.toList()) {
            if (!sameImageBounds(original.$3, r)) continue;
            final removed = original.$2 == null
                ? a.FPDFPage_RemoveObject(page, original.$1)
                : a.FPDFFormObj_RemoveObject(original.$2!, original.$1);
            if (removed == 0) throw const FormatException('图片替换失败');
            a.FPDFPageObj_Destroy(original.$1);
            originals.remove(original);
          }
          final object = a.FPDFPageObj_NewImageObj(pdf);
          try {
            _setImage(a, object, image.png);
            _setMatrix(a, object, placement);
            if (a.FPDFPage_InsertObject(page, object) == 0) {
              throw const FormatException('图片同步失败');
            }
          } catch (_) {
            a.FPDFPageObj_Destroy(object);
            rethrow;
          }
        }
        if (a.FPDFPage_GenerateContent(page) == 0) {
          throw const FormatException('图片同步写入失败');
        }
      } finally {
        a.FPDF_ClosePage(page);
      }
    }
    return _saveNative(a, pdf);
  });

  /// 只渲染受影响的一页背景，不生成或保存 PDF。用于画布遮掉已删除/被替换的图层。
  Future<Uint8List> previewBackground(
    Uint8List bytes,
    int index,
    List<PdfEditObject> hidden,
  ) async {
    final raw = await _renderBackground(bytes, index, hidden);
    return _encode(
      raw.pixels,
      raw.width,
      raw.height,
      stride: raw.stride,
      format: raw.format,
    );
  }

  Future<({Uint8List pixels, int width, int height, int stride, int format})>
  _renderBackground(Uint8List bytes, int index, List<PdfEditObject> hidden) =>
      _native(bytes, (a, pdf) {
        final page = a.FPDF_LoadPage(pdf, index);
        if (page == ffi.nullptr) throw const FormatException('无法读取预览页');
        try {
          _removeImages(a, page, hidden);
          final pw = a.FPDF_GetPageWidthF(page),
              ph = a.FPDF_GetPageHeightF(page);
          final scale = math.min(1500 / pw, 1500 / ph);
          final w = (pw * scale).ceil(), h = (ph * scale).ceil();
          final bitmap = a.FPDFBitmap_Create(w, h, 1);
          if (bitmap == ffi.nullptr) throw const FormatException('预览内存不足');
          try {
            a.FPDFBitmap_FillRect(bitmap, 0, 0, w, h, 0xffffffff);
            a.FPDF_RenderPageBitmap(bitmap, page, 0, 0, w, h, 0, 1);
            final stride = a.FPDFBitmap_GetStride(bitmap);
            // 只返回像素，PNG 编码移出 PDFium 后台，避免占住唯一的渲染线程。
            return (
              pixels: Uint8List.fromList(
                a.FPDFBitmap_GetBuffer(
                  bitmap,
                ).cast<ffi.Uint8>().asTypedList(stride * h),
              ),
              width: w,
              height: h,
              stride: stride,
              format: a.FPDFBitmap_GetFormat(bitmap),
            );
          } finally {
            a.FPDFBitmap_Destroy(bitmap);
          }
        } finally {
          a.FPDF_ClosePage(page);
        }
      });

  static void _removeImages(
    native.PDFium a,
    native.FPDF_PAGE page,
    List<PdfEditObject> objects,
  ) {
    // 先解析不可变版本中的路径，移除对象后索引会改变。
    final resolved = [
      for (final object in objects)
        (
          object,
          _find(a, page, object.path),
          object.nested
              ? _find(a, page, object.path.sublist(0, object.path.length - 1))
              : null,
        ),
    ];
    for (final entry in resolved) {
      if (entry.$1.kind != PdfObjectKind.image) {
        throw const FormatException('只能删除图片');
      }
      final removed = entry.$3 == null
          ? a.FPDFPage_RemoveObject(page, entry.$2)
          : a.FPDFFormObj_RemoveObject(entry.$3!, entry.$2);
      if (removed == 0) throw const FormatException('图片删除失败');
      a.FPDFPageObj_Destroy(entry.$2);
    }
  }

  Future<Uint8List> replaceImage(
    Uint8List bytes,
    int page,
    PdfEditObject object,
    Uint8List png,
  ) {
    if (object.kind != PdfObjectKind.image) {
      throw const FormatException('请选择图片对象');
    }
    return _write(
      bytes,
      page,
      (a, pdf, p) => _setImage(a, _find(a, p, object.path), png),
    );
  }

  Future<Uint8List> moveImage(
    Uint8List bytes,
    int page,
    PdfEditObject object,
    Rect bounds,
  ) {
    _validateBounds(bounds);
    if (object.nested) {
      throw const FormatException('组合对象内的图片支持替换；移动时请先提取到共享区，再插入页面');
    }
    if (object.kind != PdfObjectKind.image) {
      throw const FormatException('请选择图片对象');
    }
    return _write(bytes, page, (a, pdf, p) {
      var parent = const _Matrix();
      for (var i = 1; i < object.path.length; i++) {
        parent = parent * _matrix(a, _find(a, p, object.path.sublist(0, i)));
      }
      final target = _find(a, p, object.path);
      final delta =
          _displayMatrix(a, p, bounds) *
          _displayMatrix(a, p, object.bounds).inverse;
      _setMatrix(
        a,
        target,
        parent.inverse * delta * parent * _matrix(a, target),
      );
    });
  }

  Future<Uint8List> deleteImage(
    Uint8List bytes,
    int page,
    PdfEditObject object,
  ) {
    if (object.nested) throw const FormatException('组合对象内的图片支持替换，暂不支持删除');
    return _write(bytes, page, (a, pdf, p) {
      final target = _find(a, p, object.path);
      if (object.kind != PdfObjectKind.image ||
          a.FPDFPage_RemoveObject(p, target) == 0) {
        throw const FormatException('图片删除失败');
      }
      a.FPDFPageObj_Destroy(target);
    });
  }

  /// 从任意来源 PDF 复制完整页面，插入位置使用从零开始的页间索引。
  Future<Uint8List> copyPage(
    Uint8List target,
    Uint8List source,
    int index,
    int insertAt,
  ) => _native(target, (a, pdf) {
    if ((a.FPDF_GetDocPermissions(pdf) & 1024) == 0) {
      throw const FormatException('新单据不允许插入页面');
    }
    if (insertAt < 0 || insertAt > a.FPDF_GetPageCount(pdf)) {
      throw const FormatException('插入位置超出范围');
    }
    final data = calloc<ffi.Uint8>(source.length)
      ..asTypedList(source.length).setAll(0, source);
    final from = a.FPDF_LoadMemDocument64(
      data.cast(),
      source.length,
      ffi.nullptr,
    );
    final range = (index + 1).toString().toNativeUtf8();
    try {
      if (from == ffi.nullptr ||
          index < 0 ||
          index >= a.FPDF_GetPageCount(from)) {
        throw const FormatException('来源页码超出范围');
      }
      if ((a.FPDF_GetDocPermissions(from) & 16) == 0) {
        throw const FormatException('来源单据不允许复制');
      }
      if (a.FPDF_ImportPages(pdf, from, range.cast(), insertAt) == 0) {
        throw const FormatException('页面复制失败');
      }
      return _saveNative(a, pdf);
    } finally {
      if (from != ffi.nullptr) a.FPDF_CloseDocument(from);
      calloc.free(data);
      calloc.free(range);
    }
  });

  /// 缩略图低优先级排队，页面预览随时插到前面。
  Future<Uint8List> thumbnail(Uint8List bytes, int index) async {
    final raw = await _open(bytes, low: true, (doc) async {
      final page = doc.pages[index];
      final image = await page.render(
        fullWidth: 100,
        fullHeight: 100 * page.height / page.width,
      );
      if (image == null) throw const FormatException('缩略图加载失败');
      try {
        return (
          pixels: Uint8List.fromList(image.pixels),
          width: image.width,
          height: image.height,
        );
      } finally {
        image.dispose();
      }
    });
    return _encode(raw.pixels, raw.width, raw.height);
  }

  Future<Uint8List> duplicatePage(Uint8List bytes, int index) =>
      _native(bytes, (a, pdf) {
        if ((a.FPDF_GetDocPermissions(pdf) & 1024) == 0) {
          throw const FormatException('此 PDF 不允许复制页面');
        }
        if (index < 0 || index >= a.FPDF_GetPageCount(pdf)) {
          throw const FormatException('页码超出范围');
        }
        final data = calloc<ffi.Uint8>(bytes.length)
          ..asTypedList(bytes.length).setAll(0, bytes);
        final source = a.FPDF_LoadMemDocument64(
          data.cast(),
          bytes.length,
          ffi.nullptr,
        );
        final range = (index + 1).toString().toNativeUtf8();
        try {
          if (source == ffi.nullptr ||
              a.FPDF_ImportPages(pdf, source, range.cast(), index + 1) == 0) {
            throw const FormatException('页面复制失败');
          }
          return _saveNative(a, pdf);
        } finally {
          if (source != ffi.nullptr) a.FPDF_CloseDocument(source);
          calloc.free(data);
          calloc.free(range);
        }
      });

  static void _validateBounds(Rect r) {
    if (![r.left, r.top, r.width, r.height].every((n) => n.isFinite) ||
        r.width <= 0 ||
        r.height <= 0 ||
        r.left < 0 ||
        r.top < 0 ||
        r.right > 1.00001 ||
        r.bottom > 1.00001) {
      throw const FormatException('图片必须位于页面内');
    }
  }

  static Uint8List _png(
    Uint8List bytes,
    int w,
    int h,
    int stride,
    int format, {
    bool fast = false,
  }) {
    final channels = format == 1
        ? 1
        : format == 2
        ? 3
        : 4;
    final image = img.Image.fromBytes(
      width: w,
      height: h,
      bytes: bytes.buffer,
      bytesOffset: bytes.offsetInBytes,
      rowStride: stride,
      numChannels: channels,
      order: channels == 1
          ? img.ChannelOrder.red
          : channels == 3
          ? img.ChannelOrder.bgr
          : img.ChannelOrder.bgra,
    );
    if (format == 3) {
      for (final pixel in image) {
        pixel.a = 255;
      }
    }
    return Uint8List.fromList(
      fast
          ? img.encodePng(image, level: 1, filter: img.PngFilter.none)
          : img.encodePng(image),
    );
  }

  static void _setImage(
    native.PDFium a,
    native.FPDF_PAGEOBJECT object,
    Uint8List png,
  ) {
    final image = img.decodeImage(png);
    if (image == null || image.width * image.height > 40000000) {
      throw const FormatException('图片无法解码或尺寸过大');
    }
    final pixels = image.getBytes(order: img.ChannelOrder.bgra);
    final memory = calloc<ffi.Uint8>(pixels.length)
      ..asTypedList(pixels.length).setAll(0, pixels);
    final bitmap = a.FPDFBitmap_CreateEx(
      image.width,
      image.height,
      4,
      memory.cast(),
      image.width * 4,
    );
    try {
      if (bitmap == ffi.nullptr ||
          a.FPDFImageObj_SetBitmap(ffi.nullptr, 0, object, bitmap) == 0) {
        throw const FormatException('图片写入失败');
      }
    } finally {
      if (bitmap != ffi.nullptr) a.FPDFBitmap_Destroy(bitmap);
      calloc.free(memory);
    }
  }

  static native.FPDF_PAGEOBJECT _find(
    native.PDFium a,
    native.FPDF_PAGE page,
    List<int> path,
  ) {
    if (path.isEmpty) throw const FormatException('无效 PDF 对象');
    var object = a.FPDFPage_GetObject(page, path.first);
    for (final i in path.skip(1)) {
      object = a.FPDFFormObj_GetObject(object, i);
    }
    if (object == ffi.nullptr) throw const FormatException('对象已改变，请重新选择');
    return object;
  }

  static _Matrix _matrix(native.PDFium a, native.FPDF_PAGEOBJECT object) {
    final m = calloc<native.FS_MATRIX>();
    try {
      if (a.FPDFPageObj_GetMatrix(object, m) == 0) {
        throw const FormatException('无法读取对象变换');
      }
      return _Matrix(m.ref.a, m.ref.b, m.ref.c, m.ref.d, m.ref.e, m.ref.f);
    } finally {
      calloc.free(m);
    }
  }

  static void _setMatrix(
    native.PDFium a,
    native.FPDF_PAGEOBJECT object,
    _Matrix value,
  ) {
    final m = calloc<native.FS_MATRIX>();
    try {
      m.ref
        ..a = value.a
        ..b = value.b
        ..c = value.c
        ..d = value.d
        ..e = value.e
        ..f = value.f;
      if (a.FPDFPageObj_SetMatrix(object, m) == 0) {
        throw const FormatException('对象定位失败');
      }
    } finally {
      calloc.free(m);
    }
  }

  static Offset _toDisplay(native.PDFium a, native.FPDF_PAGE page, Offset p) {
    final out = calloc<ffi.Int>(2);
    try {
      if (a.FPDF_PageToDevice(
            page,
            0,
            0,
            1000000,
            1000000,
            0,
            p.dx,
            p.dy,
            out,
            out + 1,
          ) ==
          0) {
        throw const FormatException('页面坐标转换失败');
      }
      return Offset(out[0] / 1000000, out[1] / 1000000);
    } finally {
      calloc.free(out);
    }
  }

  static Offset _fromDisplay(native.PDFium a, native.FPDF_PAGE page, Offset p) {
    final out = calloc<ffi.Double>(2);
    try {
      if (a.FPDF_DeviceToPage(
            page,
            0,
            0,
            1000000,
            1000000,
            0,
            (p.dx * 1000000).round(),
            (p.dy * 1000000).round(),
            out,
            out + 1,
          ) ==
          0) {
        throw const FormatException('页面坐标转换失败');
      }
      return Offset(out[0], out[1]);
    } finally {
      calloc.free(out);
    }
  }

  static _Matrix _displayMatrix(native.PDFium a, native.FPDF_PAGE p, Rect r) {
    final origin = _fromDisplay(a, p, r.bottomLeft),
        x = _fromDisplay(a, p, r.bottomRight) - origin,
        y = _fromDisplay(a, p, r.topLeft) - origin;
    return _Matrix(x.dx, x.dy, y.dx, y.dy, origin.dx, origin.dy);
  }

  static Rect _box(List<Offset> p) => Rect.fromLTRB(
    p.map((p) => p.dx).reduce(math.min),
    p.map((p) => p.dy).reduce(math.min),
    p.map((p) => p.dx).reduce(math.max),
    p.map((p) => p.dy).reduce(math.max),
  );
}

class _Matrix {
  final double a, b, c, d, e, f;
  const _Matrix([
    this.a = 1,
    this.b = 0,
    this.c = 0,
    this.d = 1,
    this.e = 0,
    this.f = 0,
  ]);
  Offset apply(Offset p) =>
      Offset(a * p.dx + c * p.dy + e, b * p.dx + d * p.dy + f);
  _Matrix operator *(_Matrix o) => _Matrix(
    a * o.a + c * o.b,
    b * o.a + d * o.b,
    a * o.c + c * o.d,
    b * o.c + d * o.d,
    a * o.e + c * o.f + e,
    b * o.e + d * o.f + f,
  );
  _Matrix get inverse {
    final det = a * d - b * c;
    if (det.abs() < 1e-12) throw const FormatException('对象变换不可逆');
    return _Matrix(
      d / det,
      -b / det,
      -c / det,
      a / det,
      (c * f - d * e) / det,
      (b * e - a * f) / det,
    );
  }
}

class _NativeValue<T> {
  final T? value;
  final String? error;
  const _NativeValue(this.value, this.error);
}

_NativeValue<T> _nativeWorker<T>(
  ({Uint8List bytes, T Function(native.PDFium, native.FPDF_DOCUMENT) task})
  message,
) {
  final a = native.getPdfium(modulePath: Pdfrx.pdfiumModulePath);
  final data = calloc<ffi.Uint8>(message.bytes.length)
    ..asTypedList(message.bytes.length).setAll(0, message.bytes);
  native.FPDF_DOCUMENT? pdf;
  try {
    pdf = a.FPDF_LoadMemDocument64(
      data.cast(),
      message.bytes.length,
      ffi.nullptr,
    );
    if (pdf == ffi.nullptr) {
      return const _NativeValue(null, '无法打开 PDF，文件可能损坏或需要密码');
    }
    return _NativeValue(message.task(a, pdf), null);
  } on FormatException catch (e) {
    return _NativeValue(null, e.message);
  } finally {
    if (pdf != null && pdf != ffi.nullptr) a.FPDF_CloseDocument(pdf);
    calloc.free(data);
  }
}

Uint8List _saveNative(native.PDFium a, native.FPDF_DOCUMENT pdf) {
  final bytes = BytesBuilder();
  final callback =
      ffi.NativeCallable<
        ffi.Int Function(
          ffi.Pointer<native.FPDF_FILEWRITE>,
          ffi.Pointer<ffi.Void>,
          ffi.UnsignedLong,
        )
      >.isolateLocal((
        ffi.Pointer<native.FPDF_FILEWRITE> self,
        ffi.Pointer<ffi.Void> data,
        int size,
      ) {
        bytes.add(data.cast<ffi.Uint8>().asTypedList(size));
        return 1;
      }, exceptionalReturn: 0);
  final writer = calloc<native.FPDF_FILEWRITE>();
  try {
    writer.ref
      ..version = 1
      ..WriteBlock = callback.nativeFunction;
    if (a.FPDF_SaveAsCopy(pdf, writer, 2) == 0) {
      throw const FormatException('PDF 保存失败');
    }
    return bytes.toBytes();
  } finally {
    calloc.free(writer);
    callback.close();
  }
}

Uint8List _encodePreview(
  ({Uint8List pixels, int width, int height, int stride, int format}) data,
) => PdfEditEngine._png(
  data.pixels,
  data.width,
  data.height,
  data.stride,
  data.format,
  fast: true,
);
