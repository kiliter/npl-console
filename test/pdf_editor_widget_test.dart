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
    testWidgets(
      'editor responsive at $width: collect, place, undo, duplicate and drawer',
      (tester) async {
        tester.view.physicalSize = Size(
          width,
          width == 800
              ? 650
              : width == 390
              ? 844
              : 1024,
        );
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final session = PdfEditSession(), c = MaintenanceController();
        await tester.runAsync(
          () => session.load(
            'DEMO202610002',
            bytes,
            sourceNo: 'DEMO202610001',
            sourceBytes: bytes,
          ),
        );
        expect(session.error, isNull);
        Future<void> waitForEdit() async {
          final limit = DateTime.now().add(const Duration(seconds: 20));
          while (session.busy) {
            if (DateTime.now().isAfter(limit)) {
              throw StateError('PDF edit did not finish');
            }
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          expect(session.error, isNull);
        }

        final boundary = GlobalKey();
        Future<void> capture() async {
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage();
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            Directory('build/editor-qa').createSync(recursive: true);
            File(
              'build/editor-qa/editor-${width.toInt()}.png',
            ).writeAsBytesSync(png!.buffer.asUint8List());
            image.dispose();
          });
        }

        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: MaintenanceApp(controller: c, editorSession: session),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('online-editor-tab')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (width < 900) {
          await tester.tap(find.text('老单据'));
          await tester.pumpAndSettle();
        }
        // Select the embedded image via its actual paper coordinates.
        final source = find.byKey(const ValueKey('source-canvas'));
        final paper = find
            .descendant(of: source, matching: find.byType(Image))
            .first;
        var box = tester.getRect(paper);
        final image = session.source!.snapshot.objects.firstWhere(
          (o) => o.kind == PdfObjectKind.image,
        );
        final viewport = tester.getRect(source);
        final imageY = box.top + box.height * image.bounds.center.dy;
        if (imageY > viewport.bottom - 30) {
          await tester.drag(source, Offset(0, viewport.center.dy - imageY));
          await tester.pumpAndSettle();
          box = tester.getRect(paper);
        }
        await tester.tapAt(
          Offset(
            box.left + box.width * image.bounds.center.dx,
            box.top + box.height * image.bounds.center.dy,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('加入共享区'), findsOneWidget);
        await tester.runAsync(() async {
          await tester.tap(find.text('加入共享区'));
          await waitForEdit();
        });
        await tester.pumpAndSettle();
        expect(session.materials, hasLength(1));
        expect(tester.takeException(), isNull, reason: 'source collection');
        // Clicking a shared material switches to target, collapses phone drawer.
        await tester.tap(find.textContaining('来源：DEMO202610001').first);
        await tester.pumpAndSettle();
        expect(find.text('点击页面放置图片'), findsOneWidget);
        final target = find.byKey(const ValueKey('target-canvas'));
        final targetPaper = find
            .descendant(of: target, matching: find.byType(Image))
            .first;
        final targetRect = tester
            .getRect(targetPaper)
            .intersect(tester.getRect(target));
        await tester.runAsync(() async {
          await tester.tapAt(
            Offset(
              targetRect.left + targetRect.width * .5,
              targetRect.top + targetRect.height * .35,
            ),
          );
          await waitForEdit();
        });
        await tester.pumpAndSettle();
        expect(session.target!.undo, hasLength(1));
        expect(
          session.target!.snapshot.objects.where(
            (o) => o.kind == PdfObjectKind.image,
          ),
          hasLength(2),
        );
        final placed = session.target!.snapshot.objects.lastWhere(
          (o) => o.kind == PdfObjectKind.image,
        );
        var placedBox = tester.getRect(targetPaper);
        var where = Offset(
          placedBox.left + placedBox.width * placed.bounds.center.dx,
          placedBox.top + placedBox.height * placed.bounds.center.dy,
        );
        final visible = tester.getRect(target);
        if (!visible.deflate(20).contains(where)) {
          await tester.drag(target, Offset(0, visible.center.dy - where.dy));
          await tester.pumpAndSettle();
          placedBox = tester.getRect(targetPaper);
          where = Offset(
            placedBox.left + placedBox.width * placed.bounds.center.dx,
            placedBox.top + placedBox.height * placed.bounds.center.dy,
          );
        }
        await tester.tapAt(where);
        await tester.pumpAndSettle();
        if (width < 900) {
          await tester.tap(find.text('共享素材 (1)').first);
          await tester.pumpAndSettle();
        }
        expect(
          tester.takeException(),
          isNull,
          reason: 'selection and material drawer must fit',
        );
        await tester.runAsync(
          () => precacheImage(
            MemoryImage(session.target!.snapshot.png),
            boundary.currentContext!,
          ),
        );
        await tester.pumpAndSettle();
        await capture();
        await tester.runAsync(() async {
          await tester.tap(
            width < 900 ? find.text('撤销') : find.byTooltip('撤销'),
          );
          await waitForEdit();
        });
        await tester.pumpAndSettle();
        expect(
          session.target!.snapshot.objects.where(
            (o) => o.kind == PdfObjectKind.image,
          ),
          hasLength(1),
        );
        await tester.runAsync(() => session.duplicate());
        await tester.pumpAndSettle();
        expect(session.target!.snapshot.pageCount, 4);
        expect(tester.takeException(), isNull);
        final originalPicker = FilePickerPlatform.instance;
        final picker = _MemorySavePicker();
        FilePickerPlatform.instance = picker;
        addTearDown(() => FilePickerPlatform.instance = originalPicker);
        await tester.tap(find.text(width < 900 ? '保存' : '保存副本'));
        await tester.pumpAndSettle();
        expect(
          session.target!.dirty,
          isTrue,
        ); // Cancel must not clear dirty state.
        picker.cancel = false;
        await tester.tap(find.text(width < 900 ? '保存' : '保存副本'));
        await tester.pumpAndSettle();
        expect(session.target!.dirty, isFalse);
        expect(picker.bytes, session.target!.bytes);
        final saved = await tester.runAsync(
          () => session.engine.inspect(picker.bytes!, 0),
        );
        expect(saved!.pageCount, 4);
        await tester.pumpWidget(const SizedBox());
        session.dispose();
        c.dispose();
      },
    );
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
