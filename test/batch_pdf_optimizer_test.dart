import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:npl_maintenance/core/batch_repair/font_subset.dart';
import 'package:npl_maintenance/core/batch_repair/pdf_objects.dart';
import 'package:npl_maintenance/core/batch_repair/pdf_optimizer.dart';
import 'package:npl_maintenance/core/pdf_editor/pdf_engine.dart';
import 'package:pdfrx/pdfrx.dart';

import 'support/batch_fixtures.dart';
import 'support/pdfium_test_module.dart';

/// 两页单据：每页各带一份相同的完整字体（与真实单据一样逐页重复嵌入）。
Uint8List buildPdf(
  Uint8List font,
  List<int> gids,
  Map<int, int> widths,
  String text,
) {
  final doc = PdfDocumentModel({}, pdfDict());
  final hex = gids.map((g) => g.toRadixString(16).padLeft(4, '0')).join();
  final pages = <PdfRef>[];
  final pagesRef = PdfRef(doc.nextId);
  doc.objects[pagesRef.id] = null;
  for (var p = 0; p < 2; p++) {
    final file = doc.add(
      PdfStream(
        pdfDict({
          'Filter': const PdfName('FlateDecode'),
          'Length1': font.length,
        }),
        deflate(font),
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
        'W': [
          for (final g in gids) ...[
            g,
            [widths[g] ?? 1000],
          ],
        ],
      }),
    );
    final runes = text.runes.toList();
    final cmap = StringBuffer(
      '/CIDInit /ProcSet findresource begin 12 dict begin begincmap '
      '/CMapName /T def /CMapType 2 def 1 begincodespacerange <0000> <FFFF> endcodespacerange '
      '${gids.length} beginbfchar ',
    );
    for (var i = 0; i < gids.length; i++) {
      cmap.write(
        '<${gids[i].toRadixString(16).padLeft(4, '0')}> <${runes[i].toRadixString(16).padLeft(4, '0')}> ',
      );
    }
    cmap.write(
      'endbfchar endcmap CMapName currentdict /CMap defineresource pop end end',
    );
    final toUnicode = doc.add(
      PdfStream(pdfDict(), Uint8List.fromList(latin1.encode(cmap.toString()))),
    );
    final type0 = doc.add(
      pdfDict({
        'ToUnicode': toUnicode,
        'Type': const PdfName('Font'),
        'Subtype': const PdfName('Type0'),
        'BaseFont': const PdfName('ABCDEF+NotoSansSC'),
        'Encoding': const PdfName('Identity-H'),
        'DescendantFonts': [cid],
      }),
    );
    final content = doc.add(
      PdfStream(
        pdfDict(),
        Uint8List.fromList(
          latin1.encode('BT /F1 36 Tf 60 700 Td <$hex> Tj ET'),
        ),
      ),
    );
    pages.add(
      doc.add(
        pdfDict({
          'Type': const PdfName('Page'),
          'Parent': pagesRef,
          'MediaBox': [0, 0, 595, 842],
          'Resources': pdfDict({
            'Font': pdfDict({'F1': type0}),
          }),
          'Contents': content,
        }),
      ),
    );
  }
  doc.objects[pagesRef.id] = pdfDict({
    'Type': const PdfName('Pages'),
    'Kids': pages,
    'Count': pages.length,
  });
  final catalog = doc.add(
    pdfDict({'Type': const PdfName('Catalog'), 'Pages': pagesRef}),
  );
  doc.trailer['Root'] = catalog;
  return writeDocument(doc);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    Pdfrx.pdfiumModulePath = pdfiumTestModule();
    await pdfrxInitialize();
  });

  const sample = '单据修复测试 OK';
  late Uint8List font;
  late List<int> gids;
  setUpAll(() {
    final full = File('assets/fonts/NotoSansSC-Regular.ttf').readAsBytesSync();
    final cmap =
        (jsonDecode(
                  File('assets/fonts/NotoSansSC.cmap.json').readAsStringSync(),
                )
                as Map)
            .map((k, v) => MapEntry(int.parse(k as String), v as int));
    gids = [for (final r in sample.runes) cmap[r]!];
    font = stripFont(full, gids.toSet());
  });

  test('字形重编号：只保留有轮廓的字形，空字形（空格）映射到新的空字形', () {
    final subset = subsetTrueType(font)!;
    final space = gids['单据修复测试 '.length - 1];
    expect(subset.glyphs, lessThan(20));
    expect(subset.font.length, lessThan(font.length ~/ 20));
    int mapped(int cid) =>
        (subset.cidToGid[cid * 2] << 8) | subset.cidToGid[cid * 2 + 1];
    // 有轮廓的字形各得一个新编号，空格落到末尾的空字形，不落到 .notdef。
    final visible = {
      for (final g in gids)
        if (g != space) mapped(g),
    };
    expect(visible.length, gids.toSet().length - 1);
    expect(mapped(space), subset.glyphs - 1);
    expect(visible.contains(0), isFalse);
    // 已经精简过的字体不再处理。
    expect(subsetTrueType(subset.font), isNull);
  });

  test('整理单据：去重与字体精简后体积大幅下降，逐页渲染与文字完全一致', () async {
    final pdf = buildPdf(font, gids, {}, sample);
    final result = optimizeOnce(pdf, 0)!;
    expect(result.fontsSubset, 1);
    expect(result.objectsMerged, greaterThanOrEqualTo(4)); // 第二页的字体四件套合并到第一页
    expect(result.bytes.length, lessThan(pdf.length ~/ 5));
    final engine = PdfEditEngine();
    final before = await engine.pageDigests(pdf),
        after = await engine.pageDigests(result.bytes);
    expect(after.length, 2);
    for (var i = 0; i < 2; i++) {
      expect(after[i], before[i], reason: '第 ${i + 1} 页渲染应逐像素一致');
      // 确认页面确实画出了文字，而不是两份空白页相等。
      expect(before[i].any((v) => v < 128), isTrue);
    }
    final a = await engine.inspect(pdf, 0),
        b = await engine.inspect(result.bytes, 0);
    expect(
      b.objects.map((o) => o.text).join(),
      a.objects.map((o) => o.text).join(),
    );
    expect(a.objects.map((o) => o.text).join(), contains('单据修复测试'));
  });

  test('传统 xref 表的 PDF 可以解析并原样重写', () async {
    final bytes = File('test/fixtures/reader.pdf').readAsBytesSync();
    final result = optimizeOnce(bytes, 0)!;
    final engine = PdfEditEngine();
    expect(
      await engine.pageDigests(result.bytes),
      await engine.pageDigests(bytes),
    );
  });

  test('无法解析的文件返回空，由调用方保留未压缩文件', () {
    expect(
      optimizeOnce(Uint8List.fromList(latin1.encode('not a pdf')), 0),
      isNull,
    );
  });
}
