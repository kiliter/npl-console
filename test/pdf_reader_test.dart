import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:npl_maintenance/ui/pdf_reader.dart';

/// 使用独立三页测试 PDF 验证真实引擎、缩略图和缩放，不读取业务文件。
void main() {
  // Flutter 测试运行器不自动装载原生资产，复用本机构建生成的 PDFium。
  final module =
      Platform.environment['PDFIUM_PATH'] ??
      'build/native_assets/macos/libpdfium.dylib';
  setUp(() {
    Pdfrx.pdfiumModulePath = File(module).absolute.path;
    return pdfrxInitialize();
  });
  testWidgets('真实 PDF 三页连续阅读，缩略图和缩放可用', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final bytes = File('test/fixtures/reader.pdf').readAsBytesSync();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PdfReader(bytes: bytes, name: 'reader.pdf'),
        ),
      ),
    );
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      if (find.text('1 / 3 页').evaluate().isNotEmpty) break;
    }
    expect(find.text('1 / 3 页'), findsOneWidget);
    final viewer = tester.widget<PdfViewer>(find.byType(PdfViewer));
    final controller = viewer.controller!;
    expect(controller.isReady, isTrue);
    final before = controller.currentZoom;
    await tester.tap(find.byTooltip('放大 PDF'));
    await tester.pumpAndSettle();
    expect(controller.currentZoom, greaterThan(before));
    await tester.tap(find.byTooltip('页面缩略图'));
    await tester.pumpAndSettle();
    expect(find.byType(PdfPageView), findsNWidgets(3));
    await tester.tap(find.text('3'));
    await tester.pumpAndSettle();
    expect(find.text('3 / 3 页'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
