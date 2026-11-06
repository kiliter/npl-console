part of 'pdf_engine.dart';

/// 批量修复用的单据分析结果：一页的类型、尺寸、正文和全部图片。
class RepairPageInfo {
  final int index;
  final PdfPageKind kind;

  /// 页面尺寸（pt）。
  final Size size;

  /// 全文（PDFium 文字层）。
  final String text;
  final List<RepairImageInfo> images;
  const RepairPageInfo(
    this.index,
    this.kind,
    this.size,
    this.text,
    this.images,
  );
}

class RepairImageInfo {
  final List<int> path;

  /// 归一化显示坐标（左上角原点，0～1）。
  final Rect bounds;
  final List<Offset>? basis;
  final int pixelWidth, pixelHeight;

  /// 合成到白底后的 16×16 灰度缩略图，用于跨单据判断“是同一张图”。
  final Uint8List thumb;

  /// 空白图（全透明、纯白或 1×1 占位图）。
  final bool blank;
  const RepairImageInfo(
    this.path,
    this.bounds,
    this.basis,
    this.pixelWidth,
    this.pixelHeight,
    this.thumb,
    this.blank,
  );
  String get id => path.join('.');
}

/// 把来源单据某页的一张图片放到目标单据的指定位置。
class ImageTransplant {
  /// 来源单据在 [PdfBatchEngine.transplantImages] 的 sources 中的下标。
  final int source;
  final int sourcePage;
  final List<int> path;
  final int targetPage;

  /// 目标页上的归一化显示坐标。
  final Rect target;

  /// 目标页上单位方块三点（保留旋转、翻转），为空时按 [target] 正放。
  final List<Offset>? basis;
  const ImageTransplant({
    required this.source,
    required this.sourcePage,
    required this.path,
    required this.targetPage,
    required this.target,
    this.basis,
  });
}

/// 批量修复：整份分析、跨文档移植图片、逐页渲染摘要。都在 PDFium 后台一次调用完成。
extension PdfBatchEngine on PdfEditEngine {
  Future<List<RepairPageInfo>> analyzeDocument(Uint8List bytes) =>
      _native(bytes, _analyzeTask());

  /// 在 [target] 上一次放入全部图片并保存。JPEG 且不透明的图片原样嵌入（不重新编码），
  /// 其余（带透明蒙版的签名、PNG）以原分辨率位图写入。
  Future<Uint8List> transplantImages(
    Uint8List target,
    List<Uint8List> sources,
    List<ImageTransplant> placements,
  ) => _native(target, _transplantTask(sources, placements));

  /// 每页按 [width] 像素宽渲染成灰度图，用于压缩前后逐页比对。
  Future<List<Uint8List>> pageDigests(
    Uint8List bytes, {
    int width = 500,
  }) async {
    final raw = await _native(bytes, _digestTask(width));
    return [for (final page in raw) page.materialize().asUint8List()];
  }
}

List<RepairPageInfo> Function(native.PDFium, native.FPDF_DOCUMENT)
_analyzeTask() => (a, pdf) {
  final count = a.FPDF_GetPageCount(pdf);
  return [
    for (var index = 0; index < count; index++)
      PdfEditEngine._withPage(a, pdf, index, (page, textPage) {
        final objects = PdfEditEngine._pageObjects(a, page, textPage);
        final kind = PdfEditEngine._classify(a, page, textPage, objects);
        final text = PdfEditEngine._fullText(a, textPage);
        final size = Size(
          a.FPDF_GetPageWidthF(page),
          a.FPDF_GetPageHeightF(page),
        );
        final images = <RepairImageInfo>[];
        // 业务受理单不检查，也不需要图片缩略图。
        if (kind != PdfPageKind.acceptance) {
          for (final object in objects.where(
            (o) => o.kind == PdfObjectKind.image,
          )) {
            images.add(_imageInfo(a, pdf, page, object));
          }
        }
        return RepairPageInfo(index, kind, size, text, images);
      }),
  ];
};

RepairImageInfo _imageInfo(
  native.PDFium a,
  native.FPDF_DOCUMENT pdf,
  native.FPDF_PAGE page,
  PdfEditObject object,
) {
  final handle = PdfEditEngine._find(a, page, object.path);
  final size = calloc<ffi.UnsignedInt>(2);
  var w = 0, h = 0;
  try {
    if (a.FPDFImageObj_GetImagePixelSize(handle, size, size + 1) != 0) {
      w = size[0];
      h = size[1];
    }
  } finally {
    calloc.free(size);
  }
  final thumb = Uint8List(256)..fillRange(0, 256, 255);
  var blank = w * h <= 16;
  if (!blank) {
    final gray = _composited(a, pdf, page, handle, w, h, 64);
    if (gray == null) {
      blank = true;
    } else {
      final (pixels, gw, gh) = gray;
      var sum = 0.0, squares = 0.0;
      for (final v in pixels) {
        sum += v;
        squares += v * v;
      }
      final n = pixels.length, mean = sum / n;
      final std = math.sqrt(math.max(0, squares / n - mean * mean));
      blank = std < 2.5 && mean > 240;
      for (var ty = 0; ty < 16; ty++) {
        final y0 = ty * gh ~/ 16, y1 = math.max(y0 + 1, (ty + 1) * gh ~/ 16);
        for (var tx = 0; tx < 16; tx++) {
          final x0 = tx * gw ~/ 16, x1 = math.max(x0 + 1, (tx + 1) * gw ~/ 16);
          var s = 0, c = 0;
          for (var y = y0; y < y1 && y < gh; y++) {
            for (var x = x0; x < x1 && x < gw; x++) {
              s += pixels[y * gw + x];
              c++;
            }
          }
          thumb[ty * 16 + tx] = c == 0 ? 255 : s ~/ c;
        }
      }
    }
  }
  return RepairImageInfo(
    object.path,
    object.bounds,
    object.basis,
    w,
    h,
    thumb,
    blank,
  );
}

/// 把图片对象单独渲染（含透明蒙版）成长边不超过 [maxSide] 的位图，合成到白底转灰度。
/// 会改动对象矩阵，只能在一次性的文档副本里调用。
(Uint8List, int, int)? _composited(
  native.PDFium a,
  native.FPDF_DOCUMENT pdf,
  native.FPDF_PAGE page,
  native.FPDF_PAGEOBJECT object,
  int w,
  int h,
  int maxSide,
) {
  final scale = math.min(1.0, maxSide / math.max(w, h));
  final tw = math.max(1, (w * scale).round()),
      th = math.max(1, (h * scale).round());
  PdfEditEngine._setMatrix(
    a,
    object,
    _Matrix(tw.toDouble(), 0, 0, th.toDouble(), 0, 0),
  );
  final bitmap = a.FPDFImageObj_GetRenderedBitmap(pdf, page, object);
  if (bitmap == ffi.nullptr) return null;
  try {
    final bw = a.FPDFBitmap_GetWidth(bitmap),
        bh = a.FPDFBitmap_GetHeight(bitmap);
    final stride = a.FPDFBitmap_GetStride(bitmap),
        format = a.FPDFBitmap_GetFormat(bitmap);
    if (bw <= 0 || bh <= 0) return null;
    final src = a.FPDFBitmap_GetBuffer(
      bitmap,
    ).cast<ffi.Uint8>().asTypedList(stride * bh);
    final out = Uint8List(bw * bh);
    for (var y = 0; y < bh; y++) {
      for (var x = 0; x < bw; x++) {
        final i = y * stride;
        int gray, alpha;
        if (format == 1) {
          gray = src[i + x];
          alpha = 255;
        } else {
          final bpp = format == 2 ? 3 : 4, p = i + x * bpp;
          gray = (src[p] * 29 + src[p + 1] * 150 + src[p + 2] * 77) >> 8;
          alpha = format == 4 ? src[p + 3] : 255;
        }
        out[y * bw + x] = (gray * alpha + 255 * (255 - alpha)) ~/ 255;
      }
    }
    return (out, bw, bh);
  } finally {
    a.FPDFBitmap_Destroy(bitmap);
  }
}

/// 图片是否带透明：单独渲染一张小图，看是否有不透明度低于 250 的像素。
bool _hasAlpha(
  native.PDFium a,
  native.FPDF_DOCUMENT pdf,
  native.FPDF_PAGE page,
  native.FPDF_PAGEOBJECT object,
  int w,
  int h,
) {
  final scale = math.min(1.0, 96 / math.max(w, h));
  PdfEditEngine._setMatrix(
    a,
    object,
    _Matrix(
      math.max(1, w * scale).toDouble(),
      0,
      0,
      math.max(1, h * scale).toDouble(),
      0,
      0,
    ),
  );
  final bitmap = a.FPDFImageObj_GetRenderedBitmap(pdf, page, object);
  if (bitmap == ffi.nullptr) return true;
  try {
    if (a.FPDFBitmap_GetFormat(bitmap) != 4) return false;
    final bw = a.FPDFBitmap_GetWidth(bitmap),
        bh = a.FPDFBitmap_GetHeight(bitmap);
    final stride = a.FPDFBitmap_GetStride(bitmap);
    final src = a.FPDFBitmap_GetBuffer(
      bitmap,
    ).cast<ffi.Uint8>().asTypedList(stride * bh);
    for (var y = 0; y < bh; y++) {
      for (var x = 0; x < bw; x++) {
        if (src[y * stride + x * 4 + 3] < 250) return true;
      }
    }
    return false;
  } finally {
    a.FPDFBitmap_Destroy(bitmap);
  }
}

String _filterName(native.PDFium a, native.FPDF_PAGEOBJECT object, int index) {
  final length = a.FPDFImageObj_GetImageFilter(object, index, ffi.nullptr, 0);
  if (length <= 1) return '';
  final buffer = calloc<ffi.Char>(length);
  try {
    a.FPDFImageObj_GetImageFilter(object, index, buffer.cast(), length);
    return buffer.cast<Utf8>().toDartString();
  } finally {
    calloc.free(buffer);
  }
}

/// 取出可以原样嵌入的 JPEG 字节；不是单一 DCTDecode 或带透明时返回 null。
Uint8List? _rawJpeg(
  native.PDFium a,
  native.FPDF_DOCUMENT pdf,
  native.FPDF_PAGE page,
  native.FPDF_PAGEOBJECT object,
  int w,
  int h,
) {
  if (a.FPDFImageObj_GetImageFilterCount(object) != 1) return null;
  if (_filterName(a, object, 0) != 'DCTDecode') return null;
  final length = a.FPDFImageObj_GetImageDataRaw(object, ffi.nullptr, 0);
  if (length <= 0 || length > 64 * 1024 * 1024) return null;
  final buffer = calloc<ffi.Uint8>(length);
  try {
    a.FPDFImageObj_GetImageDataRaw(object, buffer.cast(), length);
    final data = Uint8List.fromList(buffer.asTypedList(length));
    if (data.length < 4 || data[0] != 0xff || data[1] != 0xd8) return null;
    // 透明判断会改动矩阵，放在取完原始数据之后。
    if (_hasAlpha(a, pdf, page, object, w, h)) return null;
    return data;
  } finally {
    calloc.free(buffer);
  }
}

void _loadJpeg(native.PDFium a, native.FPDF_PAGEOBJECT object, Uint8List jpeg) {
  final callback =
      ffi.NativeCallable<
        ffi.Int Function(
          ffi.Pointer<ffi.Void>,
          ffi.UnsignedLong,
          ffi.Pointer<ffi.UnsignedChar>,
          ffi.UnsignedLong,
        )
      >.isolateLocal((
        ffi.Pointer<ffi.Void> param,
        int position,
        ffi.Pointer<ffi.UnsignedChar> buffer,
        int size,
      ) {
        if (position < 0 || position + size > jpeg.length) return 0;
        buffer
            .cast<ffi.Uint8>()
            .asTypedList(size)
            .setAll(0, Uint8List.sublistView(jpeg, position, position + size));
        return 1;
      }, exceptionalReturn: 0);
  final access = calloc<native.FPDF_FILEACCESS>();
  try {
    access.ref
      ..m_FileLen = jpeg.length
      ..m_GetBlock = callback.nativeFunction
      ..m_Param = ffi.nullptr;
    if (a.FPDFImageObj_LoadJpegFileInline(ffi.nullptr, 0, object, access) ==
        0) {
      throw const FormatException('JPEG 图片写入失败');
    }
  } finally {
    calloc.free(access);
    callback.close();
  }
}

/// 以原分辨率位图（含透明）写入。
void _copyBitmap(
  native.PDFium a,
  native.FPDF_DOCUMENT pdf,
  native.FPDF_PAGE page,
  native.FPDF_PAGEOBJECT source,
  native.FPDF_PAGEOBJECT target,
  int w,
  int h,
) {
  if (w <= 0 || h <= 0 || w * h > 40000000) {
    throw const FormatException('图片尺寸异常');
  }
  PdfEditEngine._setMatrix(
    a,
    source,
    _Matrix(w.toDouble(), 0, 0, h.toDouble(), 0, 0),
  );
  final bitmap = a.FPDFImageObj_GetRenderedBitmap(pdf, page, source);
  if (bitmap == ffi.nullptr) throw const FormatException('来源图片无法读取');
  try {
    if (a.FPDFImageObj_SetBitmap(ffi.nullptr, 0, target, bitmap) == 0) {
      throw const FormatException('图片写入失败');
    }
  } finally {
    a.FPDFBitmap_Destroy(bitmap);
  }
}

Uint8List Function(native.PDFium, native.FPDF_DOCUMENT) _transplantTask(
  List<Uint8List> sources,
  List<ImageTransplant> placements,
) => (a, pdf) {
  if ((a.FPDF_GetDocPermissions(pdf) & 8) == 0) {
    throw const FormatException('此 PDF 不允许修改');
  }
  final count = a.FPDF_GetPageCount(pdf);
  final opened = <int, (ffi.Pointer<ffi.Uint8>, native.FPDF_DOCUMENT)>{};
  native.FPDF_DOCUMENT open(int index) {
    final existing = opened[index];
    if (existing != null) return existing.$2;
    final bytes = sources[index];
    final data = calloc<ffi.Uint8>(bytes.length)
      ..asTypedList(bytes.length).setAll(0, bytes);
    final doc = a.FPDF_LoadMemDocument64(
      data.cast(),
      bytes.length,
      ffi.nullptr,
    );
    if (doc == ffi.nullptr) {
      calloc.free(data);
      throw const FormatException('来源单据无法打开');
    }
    opened[index] = (data, doc);
    return doc;
  }

  try {
    final byPage = <int, List<ImageTransplant>>{};
    for (final p in placements) {
      if (p.targetPage < 0 || p.targetPage >= count) {
        throw FormatException('新单据没有第 ${p.targetPage + 1} 页');
      }
      PdfEditEngine._validateBounds(p.target);
      byPage.putIfAbsent(p.targetPage, () => []).add(p);
    }
    for (final entry in byPage.entries) {
      final page = a.FPDF_LoadPage(pdf, entry.key);
      if (page == ffi.nullptr) throw const FormatException('无法读取目标页面');
      try {
        for (final p in entry.value) {
          final from = open(p.source);
          final sourcePage = a.FPDF_LoadPage(from, p.sourcePage);
          if (sourcePage == ffi.nullptr) {
            throw const FormatException('来源页码超出范围');
          }
          final object = a.FPDFPageObj_NewImageObj(pdf);
          try {
            final image = PdfEditEngine._find(a, sourcePage, p.path);
            if (a.FPDFPageObj_GetType(image) != 3) {
              throw const FormatException('来源对象不是图片');
            }
            final size = calloc<ffi.UnsignedInt>(2);
            var w = 0, h = 0;
            try {
              if (a.FPDFImageObj_GetImagePixelSize(image, size, size + 1) !=
                  0) {
                w = size[0];
                h = size[1];
              }
            } finally {
              calloc.free(size);
            }
            final jpeg = _rawJpeg(a, from, sourcePage, image, w, h);
            if (jpeg != null) {
              _loadJpeg(a, object, jpeg);
            } else {
              _copyBitmap(a, from, sourcePage, image, object, w, h);
            }
            final basis = p.basis;
            final _Matrix matrix;
            if (basis != null && basis.length == 3) {
              final points = basis
                  .map((b) => PdfEditEngine._fromDisplay(a, page, b))
                  .toList();
              final origin = points[0],
                  x = points[1] - origin,
                  y = points[2] - origin;
              matrix = _Matrix(x.dx, x.dy, y.dx, y.dy, origin.dx, origin.dy);
            } else {
              matrix = PdfEditEngine._displayMatrix(a, page, p.target);
            }
            PdfEditEngine._setMatrix(a, object, matrix);
            if (a.FPDFPage_InsertObject(page, object) == 0) {
              throw const FormatException('图片插入失败');
            }
          } catch (_) {
            a.FPDFPageObj_Destroy(object);
            rethrow;
          } finally {
            a.FPDF_ClosePage(sourcePage);
          }
        }
        if (a.FPDFPage_GenerateContent(page) == 0) {
          throw const FormatException('页面内容写入失败');
        }
      } finally {
        a.FPDF_ClosePage(page);
      }
    }
    return _saveNative(a, pdf);
  } finally {
    for (final (data, doc) in opened.values) {
      a.FPDF_CloseDocument(doc);
      calloc.free(data);
    }
  }
};

List<TransferableTypedData> Function(native.PDFium, native.FPDF_DOCUMENT)
_digestTask(int width) => (a, pdf) {
  final count = a.FPDF_GetPageCount(pdf);
  return [
    for (var index = 0; index < count; index++)
      PdfEditEngine._withPage(a, pdf, index, text: false, (page, _) {
        final pw = a.FPDF_GetPageWidthF(page), ph = a.FPDF_GetPageHeightF(page);
        final height = math.max(1, (width * ph / pw).round());
        final raw = PdfEditEngine._render(a, page, width, height);
        final bgra = raw.pixels!.materialize().asUint8List();
        return TransferableTypedData.fromList([
          bgraToGray(bgra, width, height),
        ]);
      }),
  ];
};
