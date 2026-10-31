import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:npl_maintenance/ui/pdf_editor/repair_connections.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:npl_maintenance/core/pdf_editor/edit_session.dart';
import 'package:npl_maintenance/core/pdf_editor/pdf_engine.dart';
import 'package:npl_maintenance/ui/pdf_editor/editor_canvas.dart';
import 'package:npl_maintenance/ui/pdf_editor/repair_preview.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aWQAAAABJRU5ErkJggg==',
);
const _objects = [
  PdfEditObject([0], PdfObjectKind.image, Rect.fromLTWH(.1, .1, .2, .2)),
  PdfEditObject([1], PdfObjectKind.image, Rect.fromLTWH(.6, .1, .2, .2)),
];

class _Engine extends PdfEditEngine {
  final calls = <int, int>{};
  final bases = <Uint8List>[];
  bool failExtract = false;
  @override
  Future<Uint8List> previewBackground(
    Uint8List bytes,
    int page,
    List<PdfEditObject> hidden,
  ) async => _png;
  Completer<Uint8List>? pending;
  @override
  Future<Uint8List> thumbnail(Uint8List bytes, int index) async => _png;
  @override
  Future<PdfPageSnapshot> inspect(Uint8List bytes, int pageIndex) async {
    calls.update(pageIndex, (n) => n + 1, ifAbsent: () => 1);
    return PdfPageSnapshot(_png, const Size(400, 400), _objects, 10);
  }

  @override
  Future<Uint8List> extractImage(
    Uint8List bytes,
    int index,
    PdfEditObject selected,
  ) async {
    if (failExtract && selected.id == '1') throw const FormatException('提取失败');
    return _png;
  }

  @override
  Future<Uint8List> synchronizeImages(
    Uint8List bytes,
    List<PdfImagePlacement> images, {
    Map<int, List<PdfEditObject>> removed = const {},
  }) async {
    bases.add(bytes);
    return pending?.future ?? Uint8List.fromList([2]);
  }
}

void main() {
  test('跨页选图去重、批次提取失败不留下部分素材；重复同步以原单据为基准', () async {
    final engine = _Engine();
    final active = PdfEditSession(engine: engine);
    await active.load(
      'NEW',
      Uint8List.fromList([1]),
      sourceNo: 'OLD',
      sourceBytes: Uint8List.fromList([0]),
    );
    final selected = [
      for (final object in _objects)
        (page: 1, object: object, size: const Size(400, 400)),
    ];
    engine.failExtract = true;
    await active.collectSelected(selected);
    expect(active.materials, isEmpty);
    expect(active.error, '提取失败');
    engine.failExtract = false;
    await active.collectSelected(selected);
    await active.collectSelected(selected);
    expect(active.materials, hasLength(2));
    expect(active.materials.every((m) => m.page == 2), isTrue);
    await active.synchronize();
    await active.synchronize();
    expect(engine.bases.every((b) => b.single == 1), isTrue);
    expect(active.needsSync, isFalse);
    active.dispose();
  });
  test('页面缓存复用、数量有界，加载预览不通知会话', () async {
    final engine = _Engine();
    final session = PdfEditSession(engine: engine);
    await session.load('NEW', Uint8List.fromList([1]));
    var notices = 0;
    session.addListener(() => notices++);
    await Future.wait([
      session.target!.preview(engine, 1),
      session.target!.preview(engine, 1),
    ]);
    await session.target!.preview(engine, 1);
    expect(engine.calls[1], 1);
    for (var i = 2; i < 9; i++) {
      await session.target!.preview(engine, i);
    }
    await session.target!.preview(engine, 1);
    expect(engine.calls[1], 2);
    expect(notices, 0);
    expect(session.busy, isFalse);
    session.dispose();
  });
  test('同步过程中切换环境不会恢复旧修复结果', () async {
    final engine = _Engine();
    final active = PdfEditSession(engine: engine);
    await active.load(
      'NEW',
      Uint8List.fromList([1]),
      sourceNo: 'OLD',
      sourceBytes: Uint8List.fromList([0]),
    );
    await active.collectSelected([
      (page: 0, object: _objects.first, size: const Size(400, 400)),
    ]);
    engine.pending = Completer<Uint8List>();
    final operation = active.synchronize();
    active.reset();
    engine.pending!.complete(Uint8List.fromList([2]));
    await operation;
    expect(active.target, isNull);
    expect(active.materials, isEmpty);
    expect(active.busy, isFalse);
    active.dispose();
  });
  testWidgets('Ctrl 点击与触屏长按多选，跨页选择保留', (tester) async {
    final engine = _Engine();
    final doc = EditDocument(
      'OLD',
      Uint8List.fromList([1]),
      await engine.inspect(Uint8List(0), 0),
    );
    final selection = ValueNotifier<Map<String, RepairSelection>>({});
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 424,
            height: 500,
            child: EditorCanvas(
              document: doc,
              engine: engine,
              source: true,
              enabled: true,
              selection: selection,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final paper = find.byType(Image).first;
    var rect = tester.getRect(paper);
    await tester.tapAt(
      rect.topLeft + Offset(rect.width * .2, rect.height * .2),
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tapAt(
      rect.topLeft + Offset(rect.width * .7, rect.height * .2),
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(selection.value, hasLength(2));
    await tester.longPressAt(
      rect.topLeft + Offset(rect.width * .7, rect.height * .2),
    );
    await tester.pumpAndSettle();
    expect(selection.value, hasLength(1));
    await tester.drag(find.byType(ListView).first, const Offset(0, -450));
    await tester.pumpAndSettle();
    expect(selection.value.keys, contains('0:0'));
    expect(find.textContaining('第 2 / 10 页'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    selection.dispose();
  });
  test('共享区只更新预览，点击应用才生成；移除也不触发生成', () async {
    final engine = _Engine();
    final session = PdfEditSession(engine: engine);
    await session.load(
      'NEW',
      Uint8List.fromList([1]),
      sourceNo: 'OLD',
      sourceBytes: Uint8List.fromList([0]),
    );
    final document = session.previewTarget;
    final calls = Map<int, int>.of(engine.calls);
    await session.collectSelected([
      (page: 0, object: _objects.first, size: const Size(400, 400)),
    ]);
    expect(session.imagesForPage(0), hasLength(1));
    expect(engine.bases, isEmpty);
    expect(engine.calls, calls);
    expect(session.target!.bytes, [1]);
    expect(session.previewTarget, same(document));
    await session.synchronize();
    expect(engine.bases, hasLength(1));
    expect(session.previewTarget, same(document));
    await session.removeMaterial(session.materials.single);
    expect(engine.bases, hasLength(1));
    expect(session.needsSync, isTrue);
    session.dispose();
  });
  testWidgets('右键镜像和复制由用户触发，双向滚动按页序且不回环', (tester) async {
    final engine = _Engine();
    final snapshot = await engine.inspect(Uint8List(0), 0);
    final old = EditDocument('OLD', Uint8List.fromList([1]), snapshot);
    final target = EditDocument('NEW', Uint8List.fromList([2]), snapshot);
    final selection = ValueNotifier<Map<String, RepairSelection>>({});
    final link = ValueNotifier<RepairScrollPosition?>(null);
    int? copied, mirrored;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              Expanded(
                child: EditorCanvas(
                  key: const ValueKey('left'),
                  document: old,
                  engine: engine,
                  source: true,
                  enabled: true,
                  selection: selection,
                  scrollLink: link,
                  onCopyPage: (page) => copied = page,
                  onMirrorPage: (page) => mirrored = page,
                ),
              ),
              Expanded(
                child: EditorCanvas(
                  key: const ValueKey('right'),
                  document: target,
                  engine: engine,
                  source: false,
                  enabled: true,
                  selection: selection,
                  scrollLink: link,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    ScrollPosition position(String side) => tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byKey(ValueKey(side)),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position;
    final left = position('left'), right = position('right');
    left.jumpTo(440);
    await tester.pumpAndSettle();
    expect(right.pixels, closeTo(left.pixels, 1));
    expect(link.value!.source, isTrue);
    right.jumpTo(100);
    await tester.pumpAndSettle();
    expect(left.pixels, closeTo(100, 1));
    right.jumpTo(440); // 未配置对应关系也按显示页序联动，不修改同步选择。
    await tester.pumpAndSettle();
    expect(left.pixels, closeTo(440, 1));
    expect(link.value!.source, isFalse);
    left.jumpTo(0);
    right.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(150, 100), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(copied, isNull);
    await tester.tap(find.text('复制此页到右侧…'));
    await tester.pumpAndSettle();
    expect(copied, 0);
    await tester.tapAt(const Offset(150, 100), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(mirrored, isNull);
    await tester.tap(find.text('在左侧复制为镜像页…'));
    await tester.pumpAndSettle();
    expect(mirrored, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    selection.dispose();
    link.dispose();
  });
  testWidgets('画布增删图片不重新解析单据，右侧删除菜单可操作', (tester) async {
    final engine = _Engine();
    final active = PdfEditSession(engine: engine);
    await active.load(
      'NEW',
      Uint8List.fromList([1]),
      sourceNo: 'OLD',
      sourceBytes: Uint8List.fromList([0]),
    );
    final doc = active.previewTarget!;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 400,
            child: RepairPreview(
              session: active,
              document: doc,
              page: 0,
              snapshot: doc.snapshot,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final originalCalls = Map<int, int>.of(engine.calls);
    await tester.runAsync(() async {
      await active.collectSelected([
        (page: 0, object: _objects.first, size: const Size(400, 400)),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    await tester.pumpAndSettle();
    expect(engine.calls, originalCalls);
    expect(engine.bases, isEmpty);
    expect(find.byType(CustomPaint), findsWidgets);
    await tester.tapAt(const Offset(80, 80));
    await tester.pumpAndSettle();
    expect(find.text('删除图片'), findsOneWidget);
    await tester.tap(find.text('删除图片'));
    await tester.pumpAndSettle();
    expect(active.materials, isEmpty);
    expect(active.deletedImages[0], hasLength(1));
    expect(engine.calls, originalCalls);
    expect(engine.bases, isEmpty);
    expect(active.previewTarget, same(doc));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    active.dispose();
  });
  test('提取失败不暂存也不删除原图片', () async {
    final engine = _Engine()..failExtract = true;
    final session = PdfEditSession(engine: engine);
    await session.load('NEW', Uint8List.fromList([1]));
    await session.stashTargetImage(0, object: _objects.last);
    expect(session.error, isNotNull);
    expect(session.materials, isEmpty);
    expect(session.deletedImages, isEmpty);
    expect(session.target!.bytes, [1]);
    session.dispose();
  });

  for (final action in ['删除图片', '移入共享区暂存']) {
    testWidgets('边界微差的替换图$action仍删除底稿原图', (tester) async {
      final engine = _Engine();
      final session = PdfEditSession(engine: engine);
      await session.load('NEW', Uint8List.fromList([1]));
      await tester.runAsync(
        () => session.importLocalImage(
          _png,
          '替换.png',
          0,
          const Rect.fromLTWH(.10001, .10001, .2, .2),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 400,
              child: RepairPreview(
                session: session,
                document: session.previewTarget!,
                page: 0,
                snapshot: session.previewTarget!.snapshot,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(80, 80), buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();
      expect(session.deletedImages[0]?.map((o) => o.id), contains('0'));
      expect(session.imagesForPage(0), isEmpty);
      expect(engine.bases, isEmpty);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    });
  }

  testWidgets('右键移入暂存再拖入画布，拖到页面外不放置且不生成PDF', (tester) async {
    final engine = _Engine();
    final active = PdfEditSession(engine: engine);
    await active.load('NEW', Uint8List.fromList([1]));
    final doc = active.previewTarget!;
    Widget screen() => MaterialApp(
      home: Scaffold(
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 150,
              child: AnimatedBuilder(
                animation: active,
                builder: (context, _) => Column(
                  children: [
                    for (final m in active.materials)
                      Draggable<SharedPdfImage>(
                        data: m,
                        dragAnchorStrategy: pointerDragAnchorStrategy,
                        feedback: const SizedBox(width: 40, height: 40),
                        child: const SizedBox(
                          width: 100,
                          height: 80,
                          child: Text('暂存图片'),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            SizedBox(
              width: 400,
              height: 400,
              child: RepairPreview(
                session: active,
                document: doc,
                page: 0,
                snapshot: doc.snapshot,
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pumpWidget(screen());
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(230, 80), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('移入共享区暂存'));
    await tester.pumpAndSettle();
    expect(active.materials, hasLength(1));
    expect(active.deletedImages[0], hasLength(1));
    final image = active.materials.single;
    await tester.drag(find.text('暂存图片'), const Offset(0, 450));
    await tester.pumpAndSettle();
    expect(image.targetPage, -1);
    final start = tester.getCenter(find.text('暂存图片'));
    await tester.dragFrom(start, const Offset(350, 200) - start);
    await tester.pumpAndSettle();
    expect(image.targetPage, 0);
    expect(image.bounds!.center, const Offset(.5, .5));
    expect(engine.bases, isEmpty);
    expect(active.target!.bytes, [1]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    active.dispose();
  });
  test('同行连线错开端点和弧线，按位置稳定分配且不影响其他行', () {
    SharedPdfImage item(double x, double y, String id) => SharedPdfImage(
      _png,
      'OLD',
      1,
      1,
      bounds: Rect.fromLTWH(x, y, .2, .2),
      sourceSize: const Size(400, 400),
      objectId: id,
    );
    final left = item(.1, .1, 'a'),
        right = item(.6, .1, 'b'),
        below = item(.1, .6, 'c');
    final lanes = repairConnectionLanes([right, below, left]);
    expect(lanes[left]!.anchor, lessThan(.5));
    expect(lanes[right]!.anchor, greaterThan(.5));
    expect(lanes[left]!.bend, lessThan(0));
    expect(lanes[right]!.bend, greaterThan(0));
    expect(lanes[below], (anchor: .5, bend: 0.0));
    expect(repairConnectionLanes([left, right, below]), lanes);
  });
  testWidgets('流光常驻仅重绘装饰层，移开悬停不消失，移除共享图后停止动画', (tester) async {
    final engine = _Engine(), connections = RepairConnections();
    final session = PdfEditSession(engine: engine);
    await session.load(
      'NEW',
      Uint8List.fromList([1]),
      sourceNo: 'OLD',
      sourceBytes: Uint8List.fromList([0]),
    );
    await session.collectSelected([
      for (final object in _objects)
        (page: 0, object: object, size: const Size(400, 400)),
    ]);
    final selection = ValueNotifier<Map<String, RepairSelection>>({});
    final boundary = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RepaintBoundary(
            key: boundary,
            child: RepairConnectionOverlay(
              connections: connections,
              enabled: true,
              child: Row(
                children: [
                  Expanded(
                    child: EditorCanvas(
                      document: session.source!,
                      engine: engine,
                      source: true,
                      enabled: true,
                      selection: selection,
                      connections: connections,
                    ),
                  ),
                  SizedBox(
                    width: 120,
                    child: MouseRegion(
                      onEnter: (_) {},
                      onExit: (_) {},
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text('悬停查看连线'),
                          for (final image in session.materials)
                            Padding(
                              padding: const EdgeInsets.all(6),
                              child: RepairSharedAnchor(
                                connections: connections,
                                image: image,
                                child: const SizedBox(
                                  width: 90,
                                  height: 64,
                                  child: ColoredBox(
                                    color: Colors.white,
                                    child: Center(child: Text('共享图片')),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  Expanded(
                    child: EditorCanvas(
                      document: session.previewTarget!,
                      engine: engine,
                      source: false,
                      enabled: true,
                      selection: selection,
                      connections: connections,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final calls = Map<int, int>.of(engine.calls);
    final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    expect(connections.cards.length, session.materials.length);
    connections.setImages(session.materials);
    await mouse.moveTo(tester.getCenter(find.text('悬停查看连线')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(connections.images, session.materials);
    expect(tester.binding.hasScheduledFrame, isTrue);
    expect(engine.calls, calls);
    expect(engine.bases, isEmpty);
    await tester.runAsync(() async {
      final capture =
          await (boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary)
              .toImage();
      final png = await capture.toByteData(format: ui.ImageByteFormat.png);
      Directory('build/editor-qa').createSync(recursive: true);
      File(
        'build/editor-qa/repair-connections.png',
      ).writeAsBytesSync(png!.buffer.asUint8List());
      capture.dispose();
    });
    await mouse.removePointer();
    await tester.pump(const Duration(milliseconds: 300));
    expect(connections.images, session.materials);
    expect(tester.binding.hasScheduledFrame, isTrue);
    connections.setImages([]);
    await tester.pumpAndSettle();
    expect(connections.images, isEmpty);
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    selection.dispose();
    session.dispose();
    connections.dispose();
  });
}
