import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:npl_maintenance/core/pdf_memory_document.dart';
import 'package:npl_maintenance/core/pdf_editor/edit_session.dart';
import 'package:npl_maintenance/core/pdf_editor/pdf_engine.dart';
import 'support/pdfium_test_module.dart';

/// 共享未压缩 RGB 图像，构造超过默认 1MB 阈值的真实六页 PDF。
Uint8List largePdf() {
  final bytes = BytesBuilder();
  final offsets = <int>[0];
  void text(String value) => bytes.add(latin1.encode(value));
  void object(int number, List<int> content) {
    offsets.add(bytes.length);
    text('$number 0 obj\n');
    bytes.add(content);
    text('\nendobj\n');
  }

  text('%PDF-1.4\n');
  object(1, latin1.encode('<< /Type /Catalog /Pages 2 0 R >>'));
  object(
    2,
    latin1.encode(
      '<< /Type /Pages /Count 6 /Kids [4 0 R 6 0 R 8 0 R 10 0 R 12 0 R 14 0 R] >>',
    ),
  );
  final pixels = Uint8List(768 * 512 * 3);
  for (var i = 0; i < pixels.length; i++) {
    pixels[i] = i % 251;
  }
  object(
    3,
    (BytesBuilder()
          ..add(
            latin1.encode(
              '<< /Type /XObject /Subtype /Image /Width 768 /Height 512 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Length ${pixels.length} >>\nstream\n',
            ),
          )
          ..add(pixels)
          ..add(latin1.encode('\nendstream')))
        .takeBytes(),
  );
  for (var i = 0; i < 6; i++) {
    final page = 4 + i * 2;
    object(
      page,
      latin1.encode(
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 220] /Resources << /XObject << /Im 3 0 R >> >> /Contents ${page + 1} 0 R >>',
      ),
    );
    const content = 'q 280 0 0 190 10 10 cm /Im Do Q\n';
    object(
      page + 1,
      latin1.encode(
        '<< /Length ${content.length} >>\nstream\n${content}endstream',
      ),
    );
  }
  final xref = bytes.length;
  text('xref\n0 ${offsets.length}\n0000000000 65535 f \n');
  for (final offset in offsets.skip(1)) {
    text('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  text(
    'trailer\n<< /Size ${offsets.length} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n',
  );
  return bytes.takeBytes();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    Pdfrx.pdfiumModulePath = pdfiumTestModule();
    await pdfrxInitialize();
  });
  test('超过1MB的PDF显式全量内存读取，引用键稳定且不同文档不混用', () async {
    final bytes = largePdf();
    expect(bytes.length, greaterThan(1024 * 1024));
    final ref = memoryPdfReference(bytes, '测试');
    expect(ref.maxSizeToCacheOnMemory, bytes.length);
    expect(ref.key, memoryPdfReference(bytes, '测试').key);
    expect(
      ref.key,
      isNot(memoryPdfReference(Uint8List.fromList(bytes), '测试').key),
    );
    final document = await openMemoryPdf(bytes, '测试');
    try {
      expect(document.pages.length, 6);
    } finally {
      await document.dispose();
    }
  });
  test('左右大文档六页正文与缩略图交错请求，后续页及重新打开均能完成', () async {
    final engine = PdfEditEngine();
    final bytes = largePdf();
    for (var round = 0; round < 2; round++) {
      final first = await engine.inspect(bytes, 0);
      final left = EditDocument('测试左', bytes, first);
      final right = EditDocument('测试右', bytes, first);
      await Future.wait([
        for (final doc in [left, right]) ...[
          for (var page = 0; page < 6; page++)
            doc.preview(engine, page).then((snapshot) {
              expect(snapshot.pageCount, 6);
              expect(snapshot.png, isNotEmpty);
              expect(
                snapshot.objects.where((o) => o.kind == PdfObjectKind.image),
                hasLength(1),
              );
            }),
          for (var page = 0; page < 6; page++)
            doc.thumbnail(engine, page).then((png) => expect(png, isNotEmpty)),
        ],
      ]).timeout(const Duration(seconds: 45));
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
