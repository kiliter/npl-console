import 'dart:ffi' as ffi;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';
import 'package:ffi/ffi.dart';
import 'package:image/image.dart' as img;
import 'package:pdfrx/pdfrx.dart';
import 'package:pdfium_dart/pdfium_dart.dart' as native;

enum PdfObjectKind { text, image }

/// Object paths are indices within one immutable PDF revision, never native handles.
class PdfEditObject {
  final List<int> path;
  final PdfObjectKind kind;
  final Rect
  bounds; // Normalized displayed page coordinates, including rotation/crop.
  final String text;
  final double fontSize;
  const PdfEditObject(
    this.path,
    this.kind,
    this.bounds, {
    this.text = '',
    this.fontSize = 12,
  });
  String get id => path.join('.');
  bool get nested => path.length > 1;
}

class PdfPageSnapshot {
  final Uint8List png;
  final Size size;
  final List<PdfEditObject> objects;
  final int pageCount;
  const PdfPageSnapshot(this.png, this.size, this.objects, this.pageCount);
}

/// PDFium calls run in pdfrx's worker isolate (including font callbacks). Every write uses a fresh
/// document: failures cannot partially mutate the user's current revision.
class PdfEditEngine {
  Future<T> _native<T>(
    Uint8List bytes,
    T Function(native.PDFium, native.FPDF_DOCUMENT) task,
  ) async {
    pdfrxFlutterInitialize();
    await pdfrxInitialize();
    final result = await PdfrxEntryFunctions.instance.compute(
      _nativeWorker<T>,
      (bytes: bytes, task: task),
    );
    if (result.error != null) throw FormatException(result.error!);
    return result.value as T;
  }

  Future<T> _open<T>(
    Uint8List bytes,
    Future<T> Function(PdfDocument) task,
  ) async {
    pdfrxFlutterInitialize();
    final doc = await PdfDocument.openData(
      bytes,
      sourceName: 'edit-${identityHashCode(bytes)}',
    );
    try {
      return await task(doc);
    } finally {
      await doc.dispose();
    }
  }

  Future<PdfPageSnapshot> inspect(Uint8List bytes, int pageIndex) async {
    final objects = await _inspectObjects(bytes, pageIndex);
    return _open(bytes, (doc) async {
      if (pageIndex < 0 || pageIndex >= doc.pages.length) {
        throw const FormatException('页码超出范围');
      }
      final p = doc.pages[pageIndex];
      final image = await p.render(
        fullWidth: math.min(p.width * 1.8, 1500),
        fullHeight: math.min(p.width * 1.8, 1500) * p.height / p.width,
      );
      if (image == null) throw const FormatException('无法渲染 PDF');
      try {
        return PdfPageSnapshot(
          _png(image.pixels, image.width, image.height, image.width * 4, 4),
          Size(p.width, p.height),
          objects,
          doc.pages.length,
        );
      } finally {
        image.dispose();
      }
    });
  }

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

  static Uint8List _png(Uint8List bytes, int w, int h, int stride, int format) {
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
    return Uint8List.fromList(img.encodePng(image));
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
