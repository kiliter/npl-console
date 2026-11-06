import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:npl_maintenance/core/batch_repair/pdf_objects.dart';

int _u16(List<int> b, int o) => (b[o] << 8) | b[o + 1];
int _u32(List<int> b, int o) =>
    (b[o] << 24 | b[o + 1] << 16 | b[o + 2] << 8 | b[o + 3]) & 0xffffffff;
void _put32(Uint8List b, int o, int v) {
  b[o] = v >> 24 & 0xff;
  b[o + 1] = v >> 16 & 0xff;
  b[o + 2] = v >> 8 & 0xff;
  b[o + 3] = v & 0xff;
}

/// 模拟单据里的嵌入字体：字形号和 loca/hmtx/cmap 按整套字库保留，只有用到的字形有轮廓。
Uint8List stripFont(Uint8List font, Set<int> keep) {
  final count = _u16(font, 4);
  final tables = <String, (int, int)>{};
  for (var i = 0; i < count; i++) {
    final at = 12 + i * 16;
    tables[String.fromCharCodes(font.sublist(at, at + 4))] = (
      _u32(font, at + 8),
      _u32(font, at + 12),
    );
  }
  final headAt = tables['head']!.$1;
  final longLoca = _u16(font, headAt + 50) == 1;
  final numGlyphs = _u16(font, tables['maxp']!.$1 + 4);
  final locaAt = tables['loca']!.$1, glyfAt = tables['glyf']!.$1;
  int offset(int g) =>
      longLoca ? _u32(font, locaAt + g * 4) : _u16(font, locaAt + g * 2) * 2;
  final glyf = BytesBuilder();
  final loca = Uint8List((numGlyphs + 1) * 4);
  for (var g = 0; g < numGlyphs; g++) {
    _put32(loca, g * 4, glyf.length);
    if (keep.contains(g) || g == 0) {
      glyf.add(font.sublist(glyfAt + offset(g), glyfAt + offset(g + 1)));
      while (glyf.length % 4 != 0) {
        glyf.addByte(0);
      }
    }
  }
  _put32(loca, numGlyphs * 4, glyf.length);
  final replaced = {'glyf': glyf.toBytes(), 'loca': loca};
  final tags = tables.keys.toList()..sort();
  final header = Uint8List(12 + tags.length * 16)
    ..setRange(0, 12, font.sublist(0, 12));
  final body = BytesBuilder();
  for (var i = 0; i < tags.length; i++) {
    final (o, l) = tables[tags[i]]!;
    var data = replaced[tags[i]] ?? font.sublist(o, o + l);
    if (tags[i] == 'head') {
      data = Uint8List.fromList(data);
      data[50] = 0;
      data[51] = 1; // 长格式 loca
    }
    final row = 12 + i * 16;
    header.setRange(row, row + 4, tags[i].codeUnits);
    _put32(header, row + 8, header.length + body.length);
    _put32(header, row + 12, data.length);
    body.add(data);
    while (body.length % 4 != 0) {
      body.addByte(0);
    }
  }
  return Uint8List.fromList([...header, ...body.toBytes()]);
}

/// 一行文字（PDF 坐标，左下原点）。
typedef FixtureText = ({String text, double x, double y, double size});

/// 一张图片：位置为页面左上原点的 pt 矩形；[alpha] 为透明签名（带 SMask），否则为 JPEG。
typedef FixtureImage = ({
  int seed,
  double left,
  double top,
  double right,
  double bottom,
  bool alpha,
});

/// 生成测试单据：每页逐页嵌入同一份字体（与真实单据一致），文字带 ToUnicode 可被识别。
class FixtureBuilder {
  late final Uint8List _font;
  late final Map<int, int> _cmap;
  FixtureBuilder() {
    final full = File('assets/fonts/NotoSansSC-Regular.ttf').readAsBytesSync();
    _cmap =
        (jsonDecode(
                  File('assets/fonts/NotoSansSC.cmap.json').readAsStringSync(),
                )
                as Map)
            .map((k, v) => MapEntry(int.parse(k as String), v as int));
    _all = full;
  }
  late final Uint8List _all;
  final _used = <int>{};

  Uint8List build(
    List<({List<FixtureText> texts, List<FixtureImage> images})> pages,
  ) {
    for (final p in pages) {
      for (final t in p.texts) {
        for (final r in t.text.runes) {
          _used.add(_cmap[r]!);
        }
      }
    }
    _font = stripFont(_all, _used);
    final doc = PdfDocumentModel({}, pdfDict());
    final pagesRef = PdfRef(doc.nextId);
    doc.objects[pagesRef.id] = null;
    final kids = <PdfRef>[];
    for (final p in pages) {
      final font = _fontObjects(doc, p.texts);
      final xobjects = pdfDict();
      final content = StringBuffer();
      for (final t in p.texts) {
        final hex = t.text.runes
            .map((r) => _cmap[r]!.toRadixString(16).padLeft(4, '0'))
            .join();
        content.write('BT /F1 ${t.size} Tf ${t.x} ${t.y} Td <$hex> Tj ET\n');
      }
      for (var i = 0; i < p.images.length; i++) {
        final im = p.images[i];
        xobjects['Im$i'] = _image(doc, im);
        final w = im.right - im.left, h = im.bottom - im.top;
        content.write(
          'q $w 0 0 $h ${im.left} ${842 - im.bottom} cm /Im$i Do Q\n',
        );
      }
      kids.add(
        doc.add(
          pdfDict({
            'Type': const PdfName('Page'),
            'Parent': pagesRef,
            'MediaBox': [0, 0, 595.22, 842],
            'Resources': pdfDict({
              'Font': pdfDict({'F1': font}),
              'XObject': xobjects,
            }),
            'Contents': doc.add(
              PdfStream(
                pdfDict({'Filter': const PdfName('FlateDecode')}),
                deflate(Uint8List.fromList(latin1.encode(content.toString()))),
              ),
            ),
          }),
        ),
      );
    }
    doc.objects[pagesRef.id] = pdfDict({
      'Type': const PdfName('Pages'),
      'Kids': kids,
      'Count': kids.length,
    });
    doc.trailer['Root'] = doc.add(
      pdfDict({'Type': const PdfName('Catalog'), 'Pages': pagesRef}),
    );
    return writeDocument(doc);
  }

  PdfRef _fontObjects(PdfDocumentModel doc, List<FixtureText> texts) {
    final file = doc.add(
      PdfStream(
        pdfDict({
          'Filter': const PdfName('FlateDecode'),
          'Length1': _font.length,
        }),
        deflate(_font),
      ),
    );
    final descriptor = doc.add(
      pdfDict({
        'Type': const PdfName('FontDescriptor'),
        'FontName': const PdfName('ABCDEF+NotoSansSC'),
        'Flags': 4,
        'FontBBox': [0, -200, 1000, 900],
        'ItalicAngle': 0,
        'Ascent': 880,
        'Descent': -120,
        'CapHeight': 700,
        'StemV': 80,
        'FontFile2': file,
      }),
    );
    final cid = doc.add(
      pdfDict({
        'Type': const PdfName('Font'),
        'Subtype': const PdfName('CIDFontType2'),
        'BaseFont': const PdfName('ABCDEF+NotoSansSC'),
        'CIDSystemInfo': pdfDict({
          'Registry': PdfString(latin1.encode('Adobe')),
          'Ordering': PdfString(latin1.encode('Identity')),
          'Supplement': 0,
        }),
        'FontDescriptor': descriptor,
        'CIDToGIDMap': const PdfName('Identity'),
        'DW': 1000,
      }),
    );
    final map = <int, int>{
      for (final t in texts)
        for (final r in t.text.runes) _cmap[r]!: r,
    };
    final cmap = StringBuffer(
      '/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CMapName /T def /CMapType 2 def '
      '1 begincodespacerange <0000> <FFFF> endcodespacerange ',
    );
    final entries = map.entries.toList();
    for (var i = 0; i < entries.length; i += 100) {
      final chunk = entries.skip(i).take(100).toList();
      cmap.write('${chunk.length} beginbfchar ');
      for (final e in chunk) {
        cmap.write(
          '<${e.key.toRadixString(16).padLeft(4, '0')}> <${e.value.toRadixString(16).padLeft(4, '0')}> ',
        );
      }
      cmap.write('endbfchar ');
    }
    cmap.write('endcmap CMapName currentdict /CMap defineresource pop end end');
    return doc.add(
      pdfDict({
        'Type': const PdfName('Font'),
        'Subtype': const PdfName('Type0'),
        'BaseFont': const PdfName('ABCDEF+NotoSansSC'),
        'Encoding': const PdfName('Identity-H'),
        'DescendantFonts': [cid],
        'ToUnicode': doc.add(
          PdfStream(
            pdfDict(),
            Uint8List.fromList(latin1.encode(cmap.toString())),
          ),
        ),
      }),
    );
  }

  /// 每个 seed 生成一张内容独特的图片；同 seed 即同一张图。
  static img.Image picture(int seed, int w, int h) {
    final image = img.Image(width: w, height: h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final v =
            ((x * (seed + 2) + y * (seed * 3 + 1)) ~/ 6 + seed * 40) % 220;
        image.setPixelRgb(
          x,
          y,
          v,
          (v * 7 + seed * 13) % 230,
          (v * 3 + 60) % 240,
        );
      }
    }
    return image;
  }

  PdfRef _image(PdfDocumentModel doc, FixtureImage im) {
    if (!im.alpha) {
      final jpeg = img.encodeJpg(picture(im.seed, 240, 180), quality: 90);
      return doc.add(
        PdfStream(
          pdfDict({
            'Type': const PdfName('XObject'),
            'Subtype': const PdfName('Image'),
            'Width': 240,
            'Height': 180,
            'ColorSpace': const PdfName('DeviceRGB'),
            'BitsPerComponent': 8,
            'Filter': const PdfName('DCTDecode'),
          }),
          Uint8List.fromList(jpeg),
        ),
      );
    }
    // 透明签名：黑色笔画 + 灰度蒙版。
    const w = 200, h = 100;
    final rgb = Uint8List(w * h * 3), mask = Uint8List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final stroke =
            ((x + im.seed * 7) % 23 < 3) && y > 20 && y < 80 ||
            (y - 50).abs() < 2;
        mask[y * w + x] = stroke ? 255 : 0;
      }
    }
    final smask = doc.add(
      PdfStream(
        pdfDict({
          'Type': const PdfName('XObject'),
          'Subtype': const PdfName('Image'),
          'Width': w,
          'Height': h,
          'ColorSpace': const PdfName('DeviceGray'),
          'BitsPerComponent': 8,
          'Filter': const PdfName('FlateDecode'),
        }),
        deflate(mask),
      ),
    );
    return doc.add(
      PdfStream(
        pdfDict({
          'Type': const PdfName('XObject'),
          'Subtype': const PdfName('Image'),
          'Width': w,
          'Height': h,
          'ColorSpace': const PdfName('DeviceRGB'),
          'BitsPerComponent': 8,
          'Filter': const PdfName('FlateDecode'),
          'SMask': smask,
        }),
        deflate(rgb),
      ),
    );
  }
}
