import 'dart:io';
import 'package:image/image.dart' as img;
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
import 'package:npl_maintenance/ui/pdf_editor/pdf_editor_screen.dart';
import 'package:npl_maintenance/core/maintenance_controller.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aWQAAAABJRU5ErkJggg==',
);
const _objects = [
  PdfEditObject([0], PdfObjectKind.image, Rect.fromLTWH(.1, .1, .2, .2)),
  PdfEditObject([1], PdfObjectKind.image, Rect.fromLTWH(.6, .1, .2, .2)),
];

class _Engine extends PdfEditEngine {
  // 假引擎没有真实文字层，页面类型固定为地市协议页，避免调用原生识别。
  @override
  Future<PdfPageKind> pageKind(
    Uint8List bytes,
    int index, {
    bool Function()? isNeeded,
  }) async => PdfPageKind.cityAgreement;

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
  Future<Uint8List> thumbnail(
    Uint8List bytes,
    int index, {
    bool Function()? isNeeded,
  }) async => _png;
  @override
  Future<PdfPageSnapshot> inspect(
    Uint8List bytes,
    int pageIndex, {
    bool Function()? isNeeded,
  }) async {
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

class _ValidImageEngine extends _Engine {
  final Uint8List png;
  _ValidImageEngine(this.png);
  @override
  Future<Uint8List> extractImage(
    Uint8List bytes,
    int index,
    PdfEditObject selected,
  ) async => png;
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
    for (var i = 2; i < EditDocument.maxCachedPages + 4; i++) {
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
                matching: find.byWidgetPredicate(
                  (w) =>
                      w is Scrollable && w.axisDirection == AxisDirection.down,
                ),
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

  test('修改状态按字节对象身份缓存，替换字节后重新比较', () {
    final doc = EditDocument(
      'NEW',
      Uint8List.fromList([1, 2]),
      PdfPageSnapshot(_png, const Size(400, 400), _objects, 1),
    );
    expect(doc.edited, isFalse);
    expect(doc.dirty, isFalse);
    doc.commit(Uint8List.fromList([1, 3]));
    expect(doc.edited, isTrue);
    expect(doc.dirty, isTrue);
    doc.saved = Uint8List.fromList([1, 3]);
    expect(doc.dirty, isFalse);
    expect(doc.edited, isTrue);
    doc.bytes = Uint8List.fromList([1, 2]);
    expect(doc.edited, isFalse);
    expect(doc.dirty, isTrue);
  });

  testWidgets('连线几何只在滚动、布局或数据变化时测量，视口内无连线时暂停动画', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final connections = RepairConnections();
    final image = SharedPdfImage(
      _png,
      'OLD',
      1,
      1,
      bounds: const Rect.fromLTWH(.1, .1, .2, .2),
      sourceSize: const Size(400, 400),
    );
    // leftTop 模拟旧单据页在视口内的位置（滚动），header 模拟顶栏高度变化。
    final leftTop = ValueNotifier<double>(0), header = ValueNotifier<double>(0);
    Widget registered(void Function(BuildContext) register, Widget child) =>
        Builder(
          builder: (context) {
            register(context);
            return child;
          },
        );
    Widget page(bool source) => registered(
      (context) => connections.pages[(source, 0)] = context,
      const SizedBox(width: 300, height: 300),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: RepairConnectionOverlay(
          connections: connections,
          enabled: true,
          child: Column(
            children: [
              ValueListenableBuilder<double>(
                valueListenable: header,
                builder: (_, height, _) => SizedBox(height: height),
              ),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: 400,
                      child: registered(
                        (context) => connections.viewports[true] = context,
                        ValueListenableBuilder<double>(
                          valueListenable: leftTop,
                          builder: (_, top, _) => Stack(
                            children: [
                              Positioned(left: 0, top: top, child: page(true)),
                            ],
                          ),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 200,
                      child: Center(
                        child: RepairSharedAnchor(
                          connections: connections,
                          image: image,
                          child: const SizedBox(width: 80, height: 60),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 400,
                      child: registered(
                        (context) => connections.viewports[false] = context,
                        Align(alignment: Alignment.topLeft, child: page(false)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    connections.setImages([image]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.binding.transientCallbackCount, greaterThan(0));

    // 动画逐帧推进时复用缓存几何，不再逐帧测量页面与卡片。
    final measured = connections.debugMeasureCount;
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(connections.debugMeasureCount, measured);

    // 滚动等通知使几何失效，下一帧重新测量一次。
    connections.refresh();
    await tester.pump(const Duration(milliseconds: 16));
    expect(connections.debugMeasureCount, measured + 1);

    // 顶栏变高使整个工作区下移，即使没有通知也会被视口位置校验发现。
    header.value = 20;
    await tester.pump(const Duration(milliseconds: 16));
    expect(connections.debugMeasureCount, measured + 2);

    // 旧单据页滚出视口：没有可见连线，动画暂停，不再逐帧重绘。
    leftTop.value = 900;
    connections.refresh();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.binding.hasScheduledFrame, isFalse);

    // 滚回视口后自动恢复流光动画。
    leftTop.value = 0;
    connections.refresh();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    leftTop.dispose();
    header.dispose();
    connections.dispose();
  });

  testWidgets('页面滚出再滚回时复用解码图与背景，会话忙碌切换不刷新预览', (tester) async {
    // 共用夹具 PNG 无法被引擎解码；这里需要真实解码成功才能验证缓存命中。
    final engine = _ValidImageEngine(
      Uint8List.fromList(img.encodePng(img.Image(width: 8, height: 8))),
    );
    final session = PdfEditSession(engine: engine);
    await session.load('NEW', Uint8List.fromList([1]));
    // 右侧原图移入暂存再放回本页：本页既有共享图层，也需要遮掉原图的背景。
    await session.stashTargetImage(0, object: _objects.first);
    session.placeStagedImage(session.materials.single, 0, const Offset(.5, .5));
    expect(session.error, isNull);
    expect(session.imagesForPage(0), hasLength(1));
    final doc = session.previewTarget!;
    Widget preview() => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 400,
          child: RepairPreview(
            session: session,
            document: doc,
            page: 0,
            snapshot: doc.snapshot,
          ),
        ),
      ),
    );
    await tester.pumpWidget(preview());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    final cache = RepairPreviewCache.of(session);
    expect(cache.decodeCount, 1);
    expect(cache.backgroundCount, 1);
    expect(find.textContaining('失败'), findsNothing);

    // busy、同步状态等与共享图片无关的通知不触发本页重新计算。
    final revision = session.materialsRevision;
    session.notifyListeners();
    await tester.pump();
    expect(session.materialsRevision, revision);
    expect(cache.backgroundCount, 1);

    // 模拟滚出视口后再滚回：页面组件重建，直接命中缓存。
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(preview());
    await tester.pumpAndSettle();
    expect(cache.decodeCount, 1);
    expect(cache.backgroundCount, 1);

    // 移除共享图后背景与图层随之更新。
    await session.removeMaterial(session.materials.single);
    await tester.pumpAndSettle();
    expect(session.materialsRevision, greaterThan(revision));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    RepairPreviewCache.release(session);
    session.dispose();
  });

  testWidgets('单据修复页局部刷新：共享区与状态变化不重建左右画布', (tester) async {
    tester.view.physicalSize = const Size(1440, 1024);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final engine = _Engine(), controller = MaintenanceController();
    final session = PdfEditSession(engine: engine);
    await session.load(
      'NEW',
      Uint8List.fromList([1]),
      sourceNo: 'OLD',
      sourceBytes: Uint8List.fromList([0]),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PdfEditorScreen(controller: controller, session: session),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Widget canvas(String key) => tester.widget(find.byKey(ValueKey(key)));
    final source = canvas('source-canvas'), target = canvas('target-canvas');
    expect(find.text('共享区 0'), findsOneWidget);

    // 共享图片变化：共享区与状态行更新，画布组件实例保持不变。
    await tester.runAsync(
      () => session.collectSelected([
        (page: 0, object: _objects.first, size: const Size(400, 400)),
      ]),
    );
    await tester.pumpAndSettle();
    expect(find.text('共享区 1'), findsOneWidget);
    expect(find.textContaining('画布预览 · 点击应用后生成单据'), findsOneWidget);

    // 加入共享区期间 busy 切换过，画布按可操作状态重建；之后的纯状态通知不再重建。
    final idleSource = canvas('source-canvas'),
        idleTarget = canvas('target-canvas');
    expect(identical(idleSource, source), isFalse);
    session.previewChanged();
    session.notifyListeners();
    await tester.pump();
    expect(identical(canvas('source-canvas'), idleSource), isTrue);
    expect(identical(canvas('target-canvas'), idleTarget), isTrue);
    expect(identical(idleTarget, target), isFalse);
    expect(find.widgetWithText(FilledButton, '应用'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '应用'))
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
    controller.dispose();
  });

  testWidgets('宽屏三栏可拖动调整宽度，双击恢复，画布不重建且保持阅读页', (tester) async {
    tester.view.physicalSize = const Size(1440, 1024);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final engine = _Engine(), controller = MaintenanceController();
    final session = PdfEditSession(engine: engine);
    await session.load(
      'NEW',
      Uint8List.fromList([1]),
      sourceNo: 'OLD',
      sourceBytes: Uint8List.fromList([0]),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PdfEditorScreen(controller: controller, session: session),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final source = find.byKey(const ValueKey('source-canvas')),
        target = find.byKey(const ValueKey('target-canvas')),
        shared = find.byKey(const ValueKey('repair-shared-column'));
    double width(Finder f) => tester.getSize(f).width;
    final left0 = width(source), right0 = width(target), mid0 = width(shared);
    expect(left0, closeTo(right0, 1));
    expect(mid0, 184);

    // 先把右栏滚到第 3 页，验证拖动后仍停在同一页。
    final scrollable = tester.state<ScrollableState>(
      find
          .descendant(
            of: target,
            matching: find.byWidgetPredicate(
              (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
            ),
          )
          .first,
    );
    final pageHeight = right0 - 24 + 44;
    scrollable.position.jumpTo(pageHeight * 2.25);
    await tester.pumpAndSettle();
    final canvasWidget = tester.widget(target);

    // 左分隔条向左拖：左栏变窄，右栏等量变宽，共享区不变。
    await tester.drag(
      find.byKey(const ValueKey('repair-split-left')),
      const Offset(-200, 0),
    );
    await tester.pumpAndSettle();
    expect(width(source), closeTo(left0 - 200, 2));
    expect(width(target), closeTo(right0 + 200, 2));
    expect(width(shared), mid0);
    // 拖动只重新布局，新单据画布仍是同一个组件实例。
    expect(identical(tester.widget(target), canvasWidget), isTrue);
    final newHeight = width(target) - 24 + 44;
    expect(scrollable.position.pixels / newHeight, closeTo(2.25, .02));

    // 右分隔条向右拖：共享区变宽，右栏变窄，左栏不变。
    final left1 = width(source);
    await tester.drag(
      find.byKey(const ValueKey('repair-split-right')),
      const Offset(80, 0),
    );
    await tester.pumpAndSettle();
    expect(width(shared), closeTo(mid0 + 80, 2));
    expect(width(source), closeTo(left1, 2));

    // 拖过头时保留画布最小宽度。
    await tester.drag(
      find.byKey(const ValueKey('repair-split-left')),
      const Offset(-2000, 0),
    );
    await tester.pumpAndSettle();
    expect(width(source), closeTo(260, 1));

    // 双击分隔条恢复默认布局。
    await tester.tap(find.byKey(const ValueKey('repair-split-left')));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(const ValueKey('repair-split-left')));
    await tester.pumpAndSettle();
    expect(width(source), closeTo(left0, 1));
    expect(width(shared), mid0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
    controller.dispose();
  });

  testWidgets('两栏同步缩放，放大后左右滚动同步，Ctrl/⌘ + 滚轮缩放不滚动页面', (tester) async {
    tester.view.physicalSize = const Size(1440, 1024);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final engine = _Engine(), controller = MaintenanceController();
    final session = PdfEditSession(engine: engine);
    await session.load(
      'NEW',
      Uint8List.fromList([1]),
      sourceNo: 'OLD',
      sourceBytes: Uint8List.fromList([0]),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PdfEditorScreen(controller: controller, session: session),
        ),
      ),
    );
    await tester.pumpAndSettle();
    ScrollPosition scrollOf(String side, AxisDirection direction) => tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byKey(ValueKey(side)),
                matching: find.byWidgetPredicate(
                  (w) => w is Scrollable && w.axisDirection == direction,
                ),
              )
              .first,
        )
        .position;
    ScrollPosition horizontal(String side) =>
        scrollOf(side, AxisDirection.right);
    ScrollPosition vertical(String side) => scrollOf(side, AxisDirection.down);
    final paper = find.descendant(
      of: find.byKey(const ValueKey('target-canvas')),
      matching: find.byType(RepairPreview),
    );
    final fitWidth = tester.getSize(paper.first).width;
    expect(horizontal('target-canvas').maxScrollExtent, 0);
    expect(find.text('适应宽度'), findsOneWidget);

    // 先停在第 2 页中部，缩放后仍停在这里。
    final pageHeight = fitWidth + 44;
    vertical('target-canvas').jumpTo(pageHeight * 1.5);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('repair-zoom-in')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('repair-zoom-in')));
    await tester.pumpAndSettle();
    expect(find.text('150%'), findsOneWidget);
    expect(tester.getSize(paper.first).width, closeTo(fitWidth * 1.5, 1));
    for (final side in ['source-canvas', 'target-canvas']) {
      expect(horizontal(side).maxScrollExtent, greaterThan(100));
      expect(vertical(side).pixels / (fitWidth * 1.5 + 44), closeTo(1.5, .03));
    }

    // 右栏横向滚到最右，左栏跟到最右；滚到中间，左栏按比例对齐。
    final right = horizontal('target-canvas'),
        left = horizontal('source-canvas');
    right.jumpTo(right.maxScrollExtent);
    await tester.pump();
    expect(left.pixels, closeTo(left.maxScrollExtent, .5));
    right.jumpTo(right.maxScrollExtent / 2);
    await tester.pump();
    expect(left.pixels / left.maxScrollExtent, closeTo(.5, .01));
    // 左栏反向带动右栏，且不互相回弹。
    left.jumpTo(0);
    await tester.pump();
    expect(right.pixels, 0);

    // Ctrl + 滚轮放大：只缩放，不上下滚动页面。
    final before = vertical('target-canvas').pixels;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    tester.binding.handlePointerEvent(
      PointerScrollEvent(
        position: tester.getCenter(paper.first),
        scrollDelta: const Offset(0, -40),
      ),
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.text('165%'), findsOneWidget);
    expect(vertical('target-canvas').pixels, closeTo(before * 1.1, 60));

    // 点击倍数恢复适应宽度，横向滚动随之消失。
    await tester.tap(find.byKey(const ValueKey('repair-zoom-reset')));
    await tester.pumpAndSettle();
    expect(find.text('适应宽度'), findsOneWidget);
    expect(horizontal('target-canvas').maxScrollExtent, 0);
    expect(tester.getSize(paper.first).width, closeTo(fitWidth, 1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
    controller.dispose();
  });

  testWidgets('缩略图条跟随当前页，左右两侧缩略图条同步滚动', (tester) async {
    // 10 页缩略图（500 宽）超出单栏宽度，缩略图条可滚动。
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final engine = _Engine(), controller = MaintenanceController();
    final session = PdfEditSession(engine: engine);
    await session.load(
      'NEW',
      Uint8List.fromList([1]),
      sourceNo: 'OLD',
      sourceBytes: Uint8List.fromList([0]),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PdfEditorScreen(controller: controller, session: session),
        ),
      ),
    );
    await tester.pumpAndSettle();
    ScrollPosition strip(String side) => tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byKey(ValueKey(side)),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position;
    final left = strip('source-thumbnails'), right = strip('target-thumbnails');
    expect(right.maxScrollExtent, greaterThan(0));
    expect(left.pixels, 0);
    expect(right.pixels, 0);

    // 手动滚动任一侧缩略图条，另一侧滚到相同位置。
    right.jumpTo(right.maxScrollExtent);
    await tester.pump();
    expect(left.pixels, right.pixels);
    left.jumpTo(30);
    await tester.pump();
    expect(right.pixels, 30);
    left.jumpTo(0);
    await tester.pump();

    // 页面滚到最后一页：当前页缩略图滚入可见范围，两侧保持一致。
    final pages = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byKey(const ValueKey('target-canvas')),
            matching: find.byWidgetPredicate(
              (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
            ),
          )
          .first,
    );
    pages.position.jumpTo(pages.position.maxScrollExtent);
    await tester.pumpAndSettle();
    final last =
        (session.previewTarget!.snapshot.pageCount - 1) * repairThumbnailExtent;
    expect(right.pixels, greaterThan(0));
    expect(last, greaterThanOrEqualTo(right.pixels));
    expect(
      last + repairThumbnailExtent,
      lessThanOrEqualTo(right.pixels + right.viewportDimension + .5),
    );
    expect(left.pixels, right.pixels);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
    controller.dispose();
  });

  test('同页预览请求合并需要判断：任一请求方仍需要就渲染，全部离开才跳过', () async {
    final engine = _GatedEngine();
    final session = PdfEditSession(engine: engine);
    await session.load('NEW', Uint8List.fromList([1]));
    engine.gate = Completer<void>();
    final doc = session.target!;
    var first = true, second = false;
    final a = doc.preview(engine, 3, isNeeded: () => first);
    final b = doc.preview(engine, 3, isNeeded: () => second);
    expect(identical(a, b), isTrue);
    // 首个请求方离开，后来的请求方仍需要：合并判断为需要。
    first = false;
    second = true;
    expect(engine.needed!(), isTrue);
    second = false;
    expect(engine.needed!(), isFalse);
    engine.gate!.complete();
    await expectLater(a, throwsA(isA<PdfRenderSkipped>()));
    // 跳过后的新请求重新排队并正常完成。
    engine.gate = null;
    expect((await doc.preview(engine, 3)).pageCount, 10);
    session.dispose();
  });

  testWidgets('点击应用后再修改，画布顶部的待应用标记随之出现', (tester) async {
    tester.view.physicalSize = const Size(1440, 1024);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final engine = _Engine(), controller = MaintenanceController();
    final session = PdfEditSession(engine: engine);
    await session.load(
      'NEW',
      Uint8List.fromList([1]),
      sourceNo: 'OLD',
      sourceBytes: Uint8List.fromList([0]),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PdfEditorScreen(controller: controller, session: session),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(session.needsSync, isFalse);
    expect(find.textContaining('待应用'), findsNothing);
    // 删除图片不切换 busy，也不重建画布，顶部标记仍需更新。
    session.deleteTargetImage(0, _objects.first);
    await tester.pump();
    expect(find.textContaining('待应用'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
    controller.dispose();
  });
  testWidgets('请求被跳过而组件仍在显示时只重试一次，不重复请求', (tester) async {
    var calls = 0;
    final first = Completer<String>();
    Future<String> request() {
      calls++;
      return calls == 1 ? first.future : Future.value('完成');
    }

    await tester.pumpWidget(MaterialApp(home: _RetryProbe(request: request)));
    // 挂起期间多帧重建都不触发重试。
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(calls, 1);
    first.completeError(const PdfRenderSkipped());
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('完成'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

/// 预览渲染卡在闸门上，记录引擎收到的合并需要判断。
class _GatedEngine extends _Engine {
  Completer<void>? gate;
  bool Function()? needed;
  @override
  Future<PdfPageSnapshot> inspect(
    Uint8List bytes,
    int pageIndex, {
    bool Function()? isNeeded,
  }) async {
    if (gate != null) {
      needed = isNeeded;
      await gate!.future;
      if (isNeeded != null && !isNeeded()) throw const PdfRenderSkipped();
    }
    return super.inspect(bytes, pageIndex);
  }
}

class _RetryProbe extends StatefulWidget {
  final Future<String> Function() request;
  const _RetryProbe({required this.request});
  @override
  State<_RetryProbe> createState() => _RetryProbeState();
}

class _RetryProbeState extends State<_RetryProbe> {
  late Future<String> value = widget.request();
  @override
  Widget build(BuildContext context) => FutureBuilder<String>(
    future: value,
    builder: (context, snapshot) {
      if (retryIfSkipped(this, snapshot, value, () {
        value = widget.request();
      })) {
        return const Text('等待');
      }
      return Text(snapshot.data ?? '加载中');
    },
  );
}
