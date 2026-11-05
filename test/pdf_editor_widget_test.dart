import 'support/pdfium_test_module.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:npl_maintenance/core/maintenance_controller.dart';
import 'package:npl_maintenance/core/pdf_editor/edit_session.dart';
import 'package:npl_maintenance/core/pdf_editor/pdf_engine.dart';
import 'package:npl_maintenance/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Uint8List bytes;
  setUpAll(() async {
    Pdfrx.pdfiumModulePath = pdfiumTestModule();
    await pdfrxInitialize();
    bytes = File('test/fixtures/editor.pdf').readAsBytesSync();
    final loader = FontLoader('.AppleSystemUIFont')
      ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.ttf'));
    await loader.load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  for (final width in [390.0, 800.0, 1440.0]) {
    testWidgets('单据图片修复 $width：选图、同步、连续滚动和本地保存', (tester) async {
      tester.view.physicalSize = Size(
        width,
        width == 800
            ? 650
            : width == 390
            ? 844
            : 1024,
      );
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = PdfEditSession(), controller = MaintenanceController();
      await tester.runAsync(
        () => session.load('NEW', bytes, sourceNo: 'OLD', sourceBytes: bytes),
      );
      expect(session.error, isNull);
      await tester.runAsync(() async {
        for (final doc in [session.source!, session.previewTarget!]) {
          for (var thumb = 0; thumb < doc.snapshot.pageCount; thumb++) {
            await doc.thumbnail(session.engine, thumb);
          }
          for (var page = 1; page < doc.snapshot.pageCount; page++) {
            await doc.preview(session.engine, page);
          }
        }
      });
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaintenanceApp(controller: controller, editorSession: session),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('online-editor-tab')));
      await tester.pumpAndSettle();
      expect(find.text('单据图片修复'), findsWidgets);
      expect(find.text('直接编辑'), findsNothing);
      expect(find.byTooltip('下一页'), findsNothing);
      final source = find.byKey(const ValueKey('source-canvas'));
      final image = session.source!.snapshot.objects.firstWhere(
        (o) => o.kind == PdfObjectKind.image,
      );
      final paper = find
          .descendant(of: source, matching: find.byType(Image))
          .first;
      var rect = tester.getRect(paper);
      var point = Offset(
        rect.left + rect.width * image.bounds.center.dx,
        rect.top + rect.height * image.bounds.center.dy,
      );
      final viewport = tester.getRect(
        find.descendant(of: source, matching: find.byType(ListView)).first,
      );
      if (!viewport.deflate(10).contains(point)) {
        await tester.drag(source, Offset(0, viewport.center.dy - point.dy));
        await tester.pumpAndSettle();
        rect = tester.getRect(paper);
        point = Offset(
          rect.left + rect.width * image.bounds.center.dx,
          rect.top + rect.height * image.bounds.center.dy,
        );
      }
      await tester.longPressAt(point);
      await tester.pumpAndSettle();
      expect(find.text('加入共享区（1）'), findsOneWidget);
      Future<void> wait() async {
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        while (session.busy) {
          if (DateTime.now().isAfter(deadline)) throw StateError('修复超时');
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(session.error, isNull);
        for (final doc in [session.source!, session.previewTarget!]) {
          for (var thumb = 0; thumb < doc.snapshot.pageCount; thumb++) {
            await doc.thumbnail(session.engine, thumb);
          }
          for (var page = 1; page < doc.snapshot.pageCount; page++) {
            await doc.preview(session.engine, page);
          }
        }
      }

      await tester.runAsync(() async {
        await tester.tap(find.text('加入共享区（1）'));
        await wait();
      });
      await tester.pumpAndSettle();
      expect(session.materials, hasLength(1));
      expect(session.needsSync, isTrue);
      expect(session.target!.edited, isFalse);
      expect(find.text('页码选择'), findsNothing);
      expect(find.textContaining('待选择：'), findsNothing);
      expect(session.materials.single.bounds, image.bounds);
      await tester.runAsync(() async {
        await tester.tap(find.text('应用'));
        await wait();
      });
      await tester.pumpAndSettle();
      expect(session.target!.dirty, isTrue);
      expect(session.needsSync, isFalse);
      expect(
        session.target!.snapshot.objects.where(
          (o) => o.kind == PdfObjectKind.image,
        ),
        hasLength(1),
      );
      final picker = _MemorySavePicker(),
          previous = FilePickerPlatform.instance;
      FilePickerPlatform.instance = picker;
      addTearDown(() => FilePickerPlatform.instance = previous);
      await tester.tap(find.text('保存到本地'));
      await tester.pumpAndSettle();
      expect(session.target!.dirty, isTrue);
      picker.cancel = false;
      await tester.tap(find.text('保存到本地'));
      await tester.pumpAndSettle();
      expect(session.target!.dirty, isFalse);
      expect(picker.bytes, session.target!.bytes);
      // 滚动只加载目标页，不广播会话更新，也不改变源文档。
      var notices = 0;
      session.addListener(() => notices++);
      final sourceSnapshot = session.source!.snapshot;
      final target = find.byKey(const ValueKey('target-canvas'));
      await tester.drag(target, const Offset(0, -600));
      await tester.runAsync(() async {
        await session.target!.preview(session.engine, 1);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(notices, 0);
      expect(identical(sourceSnapshot, session.source!.snapshot), isTrue);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final capture =
            await (boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
        final png = await capture.toByteData(format: ui.ImageByteFormat.png);
        Directory('build/editor-qa').createSync(recursive: true);
        File(
          'build/editor-qa/repair-${width.toInt()}.png',
        ).writeAsBytesSync(png!.buffer.asUint8List());
        capture.dispose();
      });
      if (width == 1440) {
        final scroll = tester
            .state<ScrollableState>(
              find
                  .descendant(
                    of: source,
                    matching: find.byWidgetPredicate(
                      (w) =>
                          w is Scrollable &&
                          w.axisDirection == AxisDirection.down,
                    ),
                  )
                  .first,
            )
            .position;
        scroll.jumpTo(0);
        await tester.pumpAndSettle();
        final mouse = await tester.createGesture(
          kind: ui.PointerDeviceKind.mouse,
        );
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(tester.getCenter(find.text('旧图 · 1页')));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.runAsync(() async {
          final capture =
              await (boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
          final png = await capture.toByteData(format: ui.ImageByteFormat.png);
          File(
            'build/editor-qa/repair-connections-real.png',
          ).writeAsBytesSync(png!.buffer.asUint8List());
          capture.dispose();
        });
        await mouse.removePointer();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
      session.dispose();
      controller.dispose();
    });
  }
}

class _MemorySavePicker extends FilePickerPlatform {
  bool cancel = true;
  Uint8List? bytes;
  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    if (cancel) return null;
    this.bytes = Uint8List.fromList(bytes);
    return Uri.file('/tmp/editor-test.pdf');
  }
}
