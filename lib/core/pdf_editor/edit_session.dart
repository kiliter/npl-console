import 'dart:convert';
import 'package:image/image.dart' as img;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'pdf_engine.dart';

class SharedPdfImage {
  final Uint8List png;
  final String source;
  final int page;
  final double aspectRatio;
  SharedPdfImage(Uint8List bytes, this.source, this.page, this.aspectRatio)
    : png = Uint8List.fromList(bytes);
}

class EditDocument {
  final String caseNo;
  final Uint8List original;
  Uint8List bytes;
  int page = 0;
  PdfPageSnapshot snapshot;
  final List<Uint8List> undo = [], redo = [];
  Uint8List? saved;
  EditDocument(this.caseNo, Uint8List initial, this.snapshot)
    : original = Uint8List.fromList(initial),
      bytes = Uint8List.fromList(initial);
  bool get dirty => !listEquals(bytes, saved ?? original);
  bool get edited => !listEquals(bytes, original);
  void commit(Uint8List next) {
    undo.add(bytes);
    while (undo.length > 8 ||
        (undo.length > 1 &&
            undo.fold<int>(0, (n, b) => n + b.length) > 64 * 1024 * 1024)) {
      undo.removeAt(0);
    }
    redo.clear();
    bytes = next;
  }
}

/// Shared images are session-only. Closing/discarding an edit never writes OBS.
class PdfEditSession extends ChangeNotifier {
  final PdfEditEngine engine;
  EditDocument? source, target;
  final List<SharedPdfImage> materials = [];
  bool busy = false;
  String? error;
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
      final nextTarget = await engine.inspect(targetBytes, 0);
      final nextSource = sourceBytes == null
          ? null
          : await engine.inspect(sourceBytes, 0);
      if (_disposed || revision != _revision) return;
      target = EditDocument(targetNo, targetBytes, nextTarget);
      source = nextSource == null
          ? null
          : EditDocument(sourceNo!, sourceBytes!, nextSource);
    } catch (e) {
      if (!_disposed && revision == _revision) error = _message(e);
    } finally {
      if (!_disposed && revision == _revision) {
        busy = false;
        notifyListeners();
      }
    }
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

  void removeMaterial(SharedPdfImage image) {
    materials.remove(image);
    notifyListeners();
  }

  void clearMaterials() {
    materials.clear();
    notifyListeners();
  }

  void reset() {
    _revision++;
    busy = false;
    source = target = null;
    materials.clear();
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
    materials.clear();
    source = target = null;
    super.dispose();
  }
}
