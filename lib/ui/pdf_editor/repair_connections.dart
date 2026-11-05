import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:ui' show PathMetric;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderViewport;
import '../../core/pdf_editor/edit_session.dart';

/// 仅记录可见页面的位置，不读取或重新渲染 PDF。
class RepairConnections extends ChangeNotifier {
  final pages = <(bool, int), BuildContext>{};
  final viewports = <bool, BuildContext>{};
  final cards = <SharedPdfImage, BuildContext>{};
  List<SharedPdfImage> images = [];
  Map<SharedPdfImage, ({double anchor, double bend})> lanes = {};

  /// 几何版本号：滚动、卡片注册、共享图片变化时递增。
  /// 连线层只在版本号变化（或视口整体移动）时重新测量各页面与卡片位置，
  /// 动画帧之间直接复用缓存的路径。
  int revision = 0;

  /// 完整测量次数，仅供测试验证几何缓存是否生效。
  @visibleForTesting
  int debugMeasureCount = 0;

  void setImages(List<SharedPdfImage> value) {
    images = value.where((m) => !m.imported).toList();
    lanes = repairConnectionLanes(images);
    refresh();
  }

  void refresh() {
    revision++;
    notifyListeners();
  }
}

/// 同行按左右位置分配稳定路线，不受共享区加入顺序或滚动影响。
Map<SharedPdfImage, ({double anchor, double bend})> repairConnectionLanes(
  List<SharedPdfImage> images,
) {
  final result = <SharedPdfImage, ({double anchor, double bend})>{};
  final pages = <int, List<SharedPdfImage>>{};
  for (final image in images.where((m) => !m.imported && m.bounds != null)) {
    pages.putIfAbsent(image.page, () => []).add(image);
  }
  for (final items in pages.values) {
    items.sort((a, b) {
      final y = a.bounds!.center.dy.compareTo(b.bounds!.center.dy);
      return y != 0 ? y : a.bounds!.left.compareTo(b.bounds!.left);
    });
    final rows = <List<SharedPdfImage>>[];
    for (final image in items) {
      final rect = image.bounds!;
      if (rows.isEmpty ||
          (rect.center.dy - rows.last.first.bounds!.center.dy).abs() >
              math.max(
                .02,
                math.min(rect.height, rows.last.first.bounds!.height) * .35,
              )) {
        rows.add([image]);
      } else {
        rows.last.add(image);
      }
    }
    for (final row in rows) {
      row.sort((a, b) {
        final x = a.bounds!.left.compareTo(b.bounds!.left);
        return x != 0 ? x : (a.objectId ?? '').compareTo(b.objectId ?? '');
      });
      for (var i = 0; i < row.length; i++) {
        final lane = i - (row.length - 1) / 2;
        result[row[i]] = (
          anchor: (.5 + lane * .24).clamp(.18, .82),
          bend: (lane * 72).clamp(-96.0, 96.0),
        );
      }
    }
  }
  return result;
}

class RepairConnectionOverlay extends StatefulWidget {
  final RepairConnections connections;
  final bool enabled;
  final Widget child;
  const RepairConnectionOverlay({
    super.key,
    required this.connections,
    required this.enabled,
    required this.child,
  });
  @override
  State<RepairConnectionOverlay> createState() =>
      _RepairConnectionOverlayState();
}

/// 流光动画只在确有连线落在视口内时运行：
/// 绘制层每次测量后上报是否有可见连线，没有时停止 Ticker，
/// 之后滚动或数据变化触发重绘、重新出现可见连线时再恢复。
class _RepairConnectionOverlayState extends State<RepairConnectionOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );
  final surface = GlobalKey();
  late final geometry = _ConnectionGeometry(onVisibleChanged: visibleChanged);
  bool reducedMotion = false;
  bool visible = false;
  bool _scheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    reducedMotion = MediaQuery.disableAnimationsOf(context);
    update();
  }

  @override
  void didUpdateWidget(covariant RepairConnectionOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.connections != widget.connections) geometry.invalidate();
    update();
  }

  /// 绘制阶段不能启停动画（会在绘制中标记重绘），推迟到帧结束后处理。
  void visibleChanged(bool value) {
    visible = value;
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) update();
    });
  }

  void update() {
    if (widget.enabled &&
        visible &&
        widget.connections.images.isNotEmpty &&
        !reducedMotion) {
      if (!animation.isAnimating) animation.repeat();
    } else if (animation.isAnimating) {
      animation.stop();
    }
  }

  @override
  void dispose() {
    animation.dispose();
    geometry.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      widget.child,
      Positioned.fill(
        child: IgnorePointer(
          child: RepaintBoundary(
            child: CustomPaint(
              key: surface,
              painter: _ConnectionPainter(
                widget.connections,
                animation,
                surface,
                widget.enabled,
                geometry,
              ),
            ),
          ),
        ),
      ),
    ],
  );
}

/// 一条连线段的缓存：路径及其度量，用于每帧推进流光点。
typedef _Segment = ({Path path, PathMetric metric});

/// 连线几何缓存，生命周期跟随连线层。
///
/// 页面、视口和卡片的位置只在 [RepairConnections.revision] 变化，
/// 或连线层/左右视口在屏幕上的位置、尺寸变化（窗口缩放、顶栏高度变化）时重新测量；
/// 静态部分（光晕、渐变线、端点）录制成 Picture，动画帧只绘制流光点。
class _ConnectionGeometry {
  final ValueChanged<bool> onVisibleChanged;
  _ConnectionGeometry({required this.onVisibleChanged});

  int? revision;
  Object? frameKey;
  List<_Segment> segments = const [];
  Path? clip;
  ui.Picture? picture;
  bool visible = false;

  void invalidate() => revision = null;

  void update({
    required int revision,
    required Object frameKey,
    required List<_Segment> segments,
    required Path? clip,
    required ui.Picture? picture,
  }) {
    this.revision = revision;
    this.frameKey = frameKey;
    this.segments = segments;
    this.clip = clip;
    this.picture?.dispose();
    this.picture = picture;
    final next = segments.isNotEmpty;
    if (next != visible) {
      visible = next;
      onVisibleChanged(next);
    }
  }

  void dispose() {
    picture?.dispose();
    picture = null;
  }
}

class _ConnectionPainter extends CustomPainter {
  final RepairConnections connections;
  final Animation<double> animation;
  final GlobalKey surface;
  final bool enabled;
  final _ConnectionGeometry geometry;
  _ConnectionPainter(
    this.connections,
    this.animation,
    this.surface,
    this.enabled,
    this.geometry,
  ) : super(repaint: Listenable.merge([connections, animation]));
  final _boxes = <BuildContext, Rect?>{};

  static final _glow = Paint()
    ..color = const Color(0x402aabff)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 7
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);
  static final _dotGlow = Paint()
    ..color = const Color(0x7032d5d0)
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
  static final _dot = Paint()..color = const Color(0xffe5ffff);
  static final _ring = Paint()
    ..color = const Color(0xff2869e8)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.5;
  static final _ringCenter = Paint()..color = Colors.white;

  Rect? box(BuildContext? context) {
    if (context == null) return null;
    return _boxes.putIfAbsent(context, () => measureBox(context));
  }

  Rect? measureBox(BuildContext? context) {
    if (context == null || !context.mounted) return null;
    final render = context.findRenderObject();
    if (render is! RenderBox || !render.attached || !render.hasSize) {
      return null;
    }
    return render.localToGlobal(Offset.zero) & render.size;
  }

  @override
  void paint(Canvas canvas, Size size) {
    _boxes.clear();
    if (!enabled) {
      geometry.update(
        revision: connections.revision,
        frameKey: size,
        segments: const [],
        clip: null,
        picture: null,
      );
      return;
    }
    // 每帧只量连线层与左右视口三处（O(1)）判断是否整体移动；
    // 页面与卡片相对视口的变化都会经由 connections 通知。
    final frameKey = (
      size,
      box(surface.currentContext),
      box(connections.viewports[true]),
      box(connections.viewports[false]),
    );
    if (geometry.revision != connections.revision ||
        geometry.frameKey != frameKey) {
      measure(size, frameKey);
    }
    final picture = geometry.picture;
    if (picture == null) return;
    canvas.drawPicture(picture);
    canvas.save();
    canvas.clipPath(geometry.clip!);
    for (final (path: _, :metric) in geometry.segments) {
      for (var i = 0; i < 3; i++) {
        final point = metric
            .getTangentForOffset(
              ((animation.value + i / 3) % 1) * metric.length,
            )!
            .position;
        canvas.drawCircle(point, 4, _dotGlow);
        canvas.drawCircle(point, 2, _dot);
      }
    }
    canvas.restore();
  }

  /// 完整测量并录制静态连线。
  void measure(Size size, Object frameKey) {
    connections.debugMeasureCount++;
    final overlay = box(surface.currentContext);
    final segments = <_Segment>[];
    ui.Picture? picture;
    Path? visible;
    if (overlay != null) {
      // 卡片遮罩只构造一次，避免每条连线逐卡片做布尔运算。
      visible = Path()..fillType = PathFillType.evenOdd;
      visible.addRect(Offset.zero & size);
      for (final context in connections.cards.values) {
        final card = box(context);
        if (card != null) visible.addRect(card.shift(-overlay.topLeft));
      }
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.clipPath(visible);
      for (final image in connections.images) {
        collect(canvas, image, overlay, segments);
      }
      picture = recorder.endRecording();
      if (segments.isEmpty) {
        picture.dispose();
        picture = null;
      }
    }
    geometry.update(
      revision: connections.revision,
      frameKey: frameKey,
      segments: segments,
      clip: visible,
      picture: picture,
    );
  }

  void collect(
    Canvas canvas,
    SharedPdfImage m,
    Rect overlay,
    List<_Segment> segments,
  ) {
    if (m.bounds == null) return;
    final left = box(connections.pages[(true, m.page - 1)]),
        right = box(connections.pages[(false, m.page - 1)]);
    final lv = box(connections.viewports[true]),
        rv = box(connections.viewports[false]);
    if (left == null || right == null || lv == null || rv == null) return;
    // 双栏才连线。避开离屏页面、缩略图和进度条。
    if (right.left <= left.right) return;
    final r = m.bounds!;
    final lane = connections.lanes[m] ?? (anchor: .5, bend: 0.0);
    final anchorY = r.top + r.height * lane.anchor;
    final start = Offset(
      left.left + r.right * left.width,
      left.top + anchorY * left.height,
    );
    // 右侧按原图实际尺寸放置；页面宽度不同仍保留坐标比例。
    final sourceSize = m.sourceSize;
    if (sourceSize == null) return;
    final targetPage = connections.pages[(false, m.page - 1)];
    final target = targetPage
        ?.findAncestorWidgetOfExactType<RepairPageGeometry>();
    final targetSize = target?.pageSize ?? sourceSize;
    final end = Offset(
      right.left + r.left * sourceSize.width / targetSize.width * right.width,
      right.top +
          anchorY * sourceSize.height / targetSize.height * right.height,
    );
    if (!Rect.fromLTWH(
          lv.left,
          lv.top,
          lv.width,
          (lv.height - 92).clamp(0, lv.height),
        ).contains(start) ||
        !Rect.fromLTWH(
          rv.left,
          rv.top,
          rv.width,
          (rv.height - 92).clamp(0, rv.height),
        ).contains(end)) {
      return;
    }
    final cardContext = connections.cards[m];
    final card = box(cardContext);
    if (card == null) return;
    final sharedViewport = cardContext
        ?.findAncestorRenderObjectOfType<RenderViewport>();
    if (sharedViewport != null &&
        !(sharedViewport.localToGlobal(Offset.zero) & sharedViewport.size)
            .contains(card.center)) {
      return;
    }
    final a = start - overlay.topLeft, b = end - overlay.topLeft;
    final incoming =
        Offset(card.left, card.top + card.height * lane.anchor) -
        overlay.topLeft;
    final outgoing =
        Offset(card.right, card.top + card.height * lane.anchor) -
        overlay.topLeft;
    final top = math.max(lv.top, rv.top) - overlay.top;
    final bottom = math.min(lv.bottom, rv.bottom) - 92 - overlay.top;
    if (bottom <= top) return;
    segments.add(drawSegment(canvas, a, incoming, lane.bend, top, bottom));
    segments.add(drawSegment(canvas, outgoing, b, lane.bend, top, bottom));
  }

  _Segment drawSegment(
    Canvas canvas,
    Offset a,
    Offset b,
    double laneBend,
    double top,
    double bottom,
  ) {
    final bend = (b.dx - a.dx).abs() * .42;
    final offsetA = laneBend == 0 ? -24.0 : laneBend;
    final offsetB = laneBend == 0 ? 24.0 : laneBend;
    final path = Path()
      ..moveTo(a.dx, a.dy)
      ..cubicTo(
        a.dx + bend,
        (a.dy + offsetA).clamp(top, bottom),
        b.dx - bend,
        (b.dy + offsetB).clamp(top, bottom),
        b.dx,
        b.dy,
      );
    canvas.drawPath(path, _glow);
    canvas.drawPath(
      path,
      Paint()
        ..shader = const LinearGradient(
          colors: [Color(0xff2869e8), Color(0xff32d5d0), Color(0xff8761ed)],
        ).createShader(Rect.fromPoints(a, b).inflate(1))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8,
    );
    for (final point in [a, b]) {
      canvas.drawCircle(point, 5, _ring);
      canvas.drawCircle(point, 2, _ringCenter);
    }
    return (path: path, metric: path.computeMetrics().first);
  }

  @override
  bool shouldRepaint(covariant _ConnectionPainter oldDelegate) {
    final changed =
        oldDelegate.enabled != enabled ||
        oldDelegate.connections != connections;
    if (changed) geometry.invalidate();
    return changed;
  }
}

/// 页尺寸随局部画布提供，不让流光层依赖文档解析。
class RepairPageGeometry extends InheritedWidget {
  final Size pageSize;
  const RepairPageGeometry({
    super.key,
    required this.pageSize,
    required super.child,
  });
  @override
  bool updateShouldNotify(covariant RepairPageGeometry oldWidget) =>
      pageSize != oldWidget.pageSize;
}

/// 共享卡片的实时位置，支持滚动、重排及移除。
class RepairSharedAnchor extends StatefulWidget {
  final RepairConnections connections;
  final SharedPdfImage image;
  final Widget child;
  const RepairSharedAnchor({
    super.key,
    required this.connections,
    required this.image,
    required this.child,
  });
  @override
  State<RepairSharedAnchor> createState() => _RepairSharedAnchorState();
}

class _RepairSharedAnchorState extends State<RepairSharedAnchor> {
  void register() {
    widget.connections.cards[widget.image] = context;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.connections.refresh();
    });
  }

  @override
  void initState() {
    super.initState();
    register();
  }

  @override
  void didUpdateWidget(covariant RepairSharedAnchor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.connections.cards[oldWidget.image], context)) {
      oldWidget.connections.cards.remove(oldWidget.image);
    }
    register();
  }

  @override
  void dispose() {
    if (identical(widget.connections.cards[widget.image], context)) {
      widget.connections.cards.remove(widget.image);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
