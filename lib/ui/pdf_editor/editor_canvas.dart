import 'dart:async';
import 'dart:math' as math;
import 'repair_connections.dart';
import 'repair_preview.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import '../../core/pdf_editor/edit_session.dart';
import '../../core/pdf_editor/pdf_engine.dart';

typedef RepairScrollPosition = ({bool source, int page, double fraction});

/// 横向滚动位置：发起方及其滚过的比例（0 为最左，1 为最右）。
/// 两栏缩放倍数同步、页面宽度随栏宽等比，按比例对齐即对上同一片区域。
typedef RepairHorizontalPosition = ({bool source, double fraction});

/// 缩略图条滚动位置：发起方及像素偏移。两侧缩略图等宽，
/// 相同偏移即两侧显示相同的页码区间。
typedef RepairThumbnailPosition = ({bool source, double offset});

/// 单张缩略图占位宽度（42 宽 + 两侧各 4 内边距），固定宽度便于两侧对齐。
const repairThumbnailExtent = 50.0;

/// 预览缩放：1 表示适应栏宽；按钮按固定档位切换，Ctrl/⌘ + 滚轮与触控板捏合连续缩放。
abstract final class RepairZoom {
  static const min = 1.0, max = 4.0;
  static const steps = [1.0, 1.25, 1.5, 2.0, 2.5, 3.0, 4.0];
  static double clamp(double value) => value.clamp(min, max).toDouble();
  static double up(double value) =>
      steps.firstWhere((s) => s > value + .001, orElse: () => max);
  static double down(double value) =>
      steps.lastWhere((s) => s < value - .001, orElse: () => min);
  static String label(double value) =>
      (value - 1).abs() < .001 ? '适应宽度' : '${(value * 100).round()}%';
}

typedef RepairSelection = ({int page, PdfEditObject object, Size size});

/// 连续滚动按需渲染。页面状态归页面所有，滚动与加载均不通知编辑会话。
class EditorCanvas extends StatefulWidget {
  final EditDocument document;
  final PdfEditEngine engine;
  final bool source, enabled;
  final ValueNotifier<Map<String, RepairSelection>> selection;
  final ValueChanged<int>? onCopyPage;
  final ValueNotifier<RepairScrollPosition?>? scrollLink;
  final PdfEditSession? session;
  final RepairConnections? connections;
  final ValueChanged<int>? onMirrorPage;

  /// 两栏共享的缩放倍数；为空时固定适应栏宽、不可缩放。
  final ValueNotifier<double>? zoom;

  /// 两栏横向滚动同步。
  final ValueNotifier<RepairHorizontalPosition?>? horizontalLink;

  /// 两栏底部缩略图条的滚动同步。
  final ValueNotifier<RepairThumbnailPosition?>? thumbnailLink;
  const EditorCanvas({
    super.key,
    required this.document,
    required this.engine,
    required this.source,
    required this.enabled,
    required this.selection,
    this.onCopyPage,
    this.scrollLink,
    this.session,
    this.connections,
    this.onMirrorPage,
    this.zoom,
    this.horizontalLink,
    this.thumbnailLink,
  });
  @override
  State<EditorCanvas> createState() => _EditorCanvasState();
}

class _EditorCanvasState extends State<EditorCanvas> {
  final scroll = ScrollController();

  /// 放大后页面比栏宽，横向滚动由外层水平滚动视图负责。
  final horizontal = ScrollController();
  bool horizontalFollowing = false;

  /// 底部缩略图条：跟随当前页滚动，并与另一侧同步。
  final thumbnails = ScrollController();
  bool thumbnailFollowing = false;
  double? lastContentWidth;

  /// 滚动进度（当前页, 比例）逐帧变化，只驱动底部滑杆；
  /// 缩略图条只关心当前页，单独用 [currentPage] 通知，避免每帧重建整条缩略图。
  final progress = ValueNotifier<(int, double)>((0, 0));
  final currentPage = ValueNotifier<int>(0);
  List<double> offsets = [];
  List<double> pageHeights = [];
  bool following = false;
  @override
  void initState() {
    super.initState();
    widget.connections?.viewports[widget.source] = context;
    scroll.addListener(updateProgress);
    widget.scrollLink?.addListener(followOther);
    horizontal.addListener(updateHorizontal);
    widget.horizontalLink?.addListener(followHorizontal);
    widget.zoom?.addListener(zoomChanged);
    thumbnails.addListener(updateThumbnails);
    widget.thumbnailLink?.addListener(followThumbnails);
    currentPage.addListener(revealThumbnail);
  }

  @override
  void didUpdateWidget(covariant EditorCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.thumbnailLink, widget.thumbnailLink)) {
      oldWidget.thumbnailLink?.removeListener(followThumbnails);
      widget.thumbnailLink?.addListener(followThumbnails);
    }
    if (!identical(oldWidget.zoom, widget.zoom)) {
      oldWidget.zoom?.removeListener(zoomChanged);
      widget.zoom?.addListener(zoomChanged);
    }
    if (!identical(oldWidget.horizontalLink, widget.horizontalLink)) {
      oldWidget.horizontalLink?.removeListener(followHorizontal);
      widget.horizontalLink?.addListener(followHorizontal);
    }
    if (!identical(oldWidget.scrollLink, widget.scrollLink)) {
      oldWidget.scrollLink?.removeListener(followOther);
      widget.scrollLink?.addListener(followOther);
    }
  }

  /// 缩放只改变本栏布局，阅读页与横向中心位置在 build 中保持。
  void zoomChanged() {
    if (mounted) setState(() {});
  }

  void setZoom(double value) {
    final zoom = widget.zoom;
    if (zoom == null) return;
    zoom.value = RepairZoom.clamp(value);
  }

  /// Ctrl/⌘ + 滚轮缩放。监听挂在页面上（比列表更内层），先于列表登记滚动信号，
  /// 按住修饰键时只缩放、不滚动。
  void pointerSignal(PointerSignalEvent event) {
    if (widget.zoom == null || event is! PointerScrollEvent) return;
    final keyboard = HardwareKeyboard.instance;
    if (!keyboard.isControlPressed && !keyboard.isMetaPressed) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (event) {
      final dy = (event as PointerScrollEvent).scrollDelta.dy;
      if (dy == 0) return;
      setZoom(widget.zoom!.value * (dy < 0 ? 1.1 : 1 / 1.1));
    });
  }

  /// 触控板双指捏合缩放；起始倍数在捏合开始时记录。
  double? pinchStart;
  void pinchUpdate(PointerPanZoomUpdateEvent event) {
    if (widget.zoom == null) return;
    pinchStart ??= widget.zoom!.value;
    if ((event.scale - 1).abs() < .02) return;
    setZoom(pinchStart! * event.scale);
  }

  void updateThumbnails() {
    final link = widget.thumbnailLink;
    if (thumbnailFollowing || link == null || !thumbnails.hasClients) return;
    link.value = (source: widget.source, offset: thumbnails.offset);
  }

  void followThumbnails() {
    final position = widget.thumbnailLink?.value;
    if (position == null ||
        position.source == widget.source ||
        !thumbnails.hasClients) {
      return;
    }
    thumbnailFollowing = true;
    try {
      thumbnails.jumpTo(
        position.offset.clamp(0, thumbnails.position.maxScrollExtent),
      );
    } finally {
      thumbnailFollowing = false;
    }
  }

  /// 当前页的缩略图不在可见范围时，把它滚到缩略图条中间；
  /// 已可见则不动，手动拖过的缩略图条不会被频繁拉回。
  void revealThumbnail() {
    if (!thumbnails.hasClients) return;
    final position = thumbnails.position;
    final start = currentPage.value * repairThumbnailExtent;
    final end = start + repairThumbnailExtent;
    if (start >= position.pixels &&
        end <= position.pixels + position.viewportDimension) {
      return;
    }
    thumbnails.jumpTo(
      (start - (position.viewportDimension - repairThumbnailExtent) / 2).clamp(
        0,
        position.maxScrollExtent,
      ),
    );
  }

  void updateHorizontal() {
    widget.connections?.refresh();
    final link = widget.horizontalLink;
    if (horizontalFollowing || link == null || !horizontal.hasClients) return;
    final max = horizontal.position.maxScrollExtent;
    link.value = (
      source: widget.source,
      fraction: max <= 0 ? 0 : (horizontal.offset / max).clamp(0, 1),
    );
  }

  void followHorizontal() {
    final position = widget.horizontalLink?.value;
    if (position == null ||
        position.source == widget.source ||
        !horizontal.hasClients) {
      return;
    }
    final max = horizontal.position.maxScrollExtent;
    horizontalFollowing = true;
    try {
      horizontal.jumpTo(max <= 0 ? 0 : position.fraction * max);
    } finally {
      horizontalFollowing = false;
    }
  }

  Future<void> pageMenu(int page, Offset at) async {
    if (!widget.enabled) return;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(at.dx, at.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          enabled: false,
          child: Text('${widget.source ? '旧' : '新'}单据 · 第 ${page + 1} 页'),
        ),
        if (widget.source && widget.onMirrorPage != null)
          const PopupMenuItem(value: 'mirror', child: Text('在左侧复制为镜像页…')),
        if (widget.onCopyPage != null)
          PopupMenuItem(
            value: 'copy',
            child: Text(widget.source ? '复制此页到右侧…' : '复制本页…'),
          ),
      ],
    );
    if (!mounted || !widget.enabled) return;
    if (choice == 'mirror') widget.onMirrorPage?.call(page);
    if (choice == 'copy') widget.onCopyPage?.call(page);
  }

  String pageLabel(int page) {
    final prefix = widget.source && widget.document.mirrorPages.contains(page)
        ? '镜像 · 原第 ${widget.document.sourcePageOrigins[page] + 1} 页 · '
        : '';
    return prefix.isEmpty ? (widget.source ? '旧单据' : '实时预览') : prefix;
  }

  void followOther() {
    final position = widget.scrollLink?.value;
    if (position == null ||
        position.source == widget.source ||
        !scroll.hasClients) {
      return;
    }
    if (offsets.isEmpty) return;
    final target = position.page.clamp(0, offsets.length - 1);
    following = true;
    try {
      scroll.jumpTo(
        (offsets[target] + position.fraction * pageHeights[target]).clamp(
          0,
          scroll.position.maxScrollExtent,
        ),
      );
    } finally {
      following = false;
    }
  }

  void updateProgress() {
    if (!scroll.hasClients || offsets.isEmpty) return;
    widget.connections?.refresh();
    final at = scroll.offset;
    var page = 0;
    for (var i = 1; i < offsets.length; i++) {
      if (offsets[i] > at + 24) break;
      page = i;
    }
    final total = scroll.position.maxScrollExtent;
    progress.value = (page, total <= 0 ? 1 : (at / total).clamp(0, 1));
    currentPage.value = page;
    if (!following && widget.scrollLink != null && page < pageHeights.length) {
      widget.scrollLink!.value = (
        source: widget.source,
        page: page,
        fraction: ((at - offsets[page]) / pageHeights[page]).clamp(0, 1),
      );
    }
  }

  double? lastWidth;

  /// 当前首个可见页及其已滚过的比例，用旧的页偏移计算。
  ({int page, double fraction})? readingPosition() {
    if (!scroll.hasClients || offsets.isEmpty) return null;
    final at = scroll.offset;
    var page = 0;
    for (var i = 1; i < offsets.length; i++) {
      if (offsets[i] > at) break;
      page = i;
    }
    return (
      page: page,
      fraction: ((at - offsets[page]) / pageHeights[page]).clamp(0, 1),
    );
  }

  /// 在布局阶段直接修正像素偏移（不通知监听者），本帧即按新位置排版，
  /// 拖动分隔条时页面不会先跳走再跳回。越界部分由视口布局自行收敛。
  void restore(({int page, double fraction}) position) {
    if (!scroll.hasClients || position.page >= offsets.length) return;
    scroll.position.correctPixels(
      math.max(
        0,
        offsets[position.page] + position.fraction * pageHeights[position.page],
      ),
    );
  }

  void jump(int page) {
    if (!scroll.hasClients || page >= offsets.length) return;
    scroll.jumpTo(offsets[page].clamp(0, scroll.position.maxScrollExtent));
  }

  @override
  void dispose() {
    if (identical(widget.connections?.viewports[widget.source], context)) {
      widget.connections?.viewports.remove(widget.source);
    }
    widget.scrollLink?.removeListener(followOther);
    widget.horizontalLink?.removeListener(followHorizontal);
    widget.thumbnailLink?.removeListener(followThumbnails);
    widget.zoom?.removeListener(zoomChanged);
    thumbnails.dispose();
    scroll.dispose();
    horizontal.dispose();
    progress.dispose();
    currentPage.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0xffe9eef5),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final viewportWidth = constraints.maxWidth;
        final zoom = widget.zoom?.value ?? 1.0;
        // 页面宽度 = 适应栏宽 × 缩放倍数；放大后内容比栏宽，可左右滚动。
        final width = (viewportWidth - 24).clamp(1.0, double.infinity) * zoom;
        final contentWidth = width + 24;
        // 缩放或改栏宽后保持横向中心落在页面同一位置。
        final previousContent = lastContentWidth;
        lastContentWidth = contentWidth;
        if (previousContent != null &&
            previousContent != contentWidth &&
            horizontal.hasClients) {
          final viewport = horizontal.position.viewportDimension;
          final center = (horizontal.offset + viewport / 2) / previousContent;
          horizontal.position.correctPixels(
            (center * contentWidth - viewportWidth / 2).clamp(
              0.0,
              math.max(0.0, contentWidth - viewportWidth),
            ),
          );
        }
        // 页面底图约 1500 像素宽，按实际显示的物理像素分桶降采样解码，
        // 缩小单页位图占用，图片缓存能容纳更多页，来回滚动时少重复解码。
        final cacheWidth = repairDecodeWidth(
          width * MediaQuery.devicePixelRatioOf(context),
        );
        final sizes = widget.document.pageSizes;
        // 拖动分隔条或缩放窗口时页面高度随宽度变化，按“页码 + 页内比例”
        // 保持当前阅读位置，不让像素偏移把页面带走。
        final keep = width != lastWidth && lastWidth != null
            ? readingPosition()
            : null;
        lastWidth = width;
        final heights = [
          for (final size in sizes) width * size.height / size.width + 44,
        ];
        pageHeights = heights;
        var offset = 0.0;
        offsets = [
          for (final height in heights)
            (() {
              final start = offset;
              offset += height;
              return start;
            })(),
        ];
        if (keep != null) restore(keep);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            following = true;
            updateProgress();
            following = false;
          }
        });
        return Column(
          children: [
            Expanded(
              // 竖向滚动条只接收内层页面列表（深度 1）的通知，固定在栏的右边缘；
              // 横向滚动条只在放大后显示在底部。
              child: Scrollbar(
                controller: scroll,
                thumbVisibility: true,
                interactive: true,
                notificationPredicate: (n) =>
                    n.depth == 1 && n.metrics.axis == Axis.vertical,
                child: Scrollbar(
                  controller: horizontal,
                  thumbVisibility: zoom > 1,
                  interactive: true,
                  notificationPredicate: (n) =>
                      n.depth == 0 && n.metrics.axis == Axis.horizontal,
                  child: SingleChildScrollView(
                    key: ValueKey(
                      widget.source ? 'source-horizontal' : 'target-horizontal',
                    ),
                    controller: horizontal,
                    scrollDirection: Axis.horizontal,
                    // 适应宽度时没有可横向滚动的内容，不参与手势竞争。
                    physics: zoom > 1
                        ? null
                        : const NeverScrollableScrollPhysics(),
                    child: SizedBox(
                      width: contentWidth,
                      child: ListView.builder(
                        key: PageStorageKey(
                          '${widget.source ? '旧' : '新'}-${widget.document.caseNo}',
                        ),
                        controller: scroll,
                        padding: const EdgeInsets.all(12),
                        scrollCacheExtent: const ScrollCacheExtent.pixels(300),
                        itemCount: sizes.length,
                        itemExtentBuilder: (index, dimensions) =>
                            heights[index],
                        itemBuilder: (context, index) => Listener(
                          onPointerSignal: pointerSignal,
                          onPointerPanZoomStart: (_) => pinchStart = null,
                          onPointerPanZoomUpdate: pinchUpdate,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onSecondaryTapUp: (details) =>
                                pageMenu(index, details.globalPosition),
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: 16),
                              child: Column(
                                children: [
                                  SizedBox(
                                    height: 28,
                                    child: Center(
                                      child: Text(
                                        '第 ${index + 1} / ${sizes.length} 页 · ${pageLabel(index)}',
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: Color(0xff52647c),
                                        ),
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                    width: width,
                                    height:
                                        width *
                                        sizes[index].height /
                                        sizes[index].width,
                                    child: RepaintBoundary(
                                      child: RepairPageGeometry(
                                        pageSize: sizes[index],
                                        child: _RepairPage(
                                          key: ValueKey((
                                            widget.document.bytes,
                                            index,
                                          )),
                                          document: widget.document,
                                          engine: widget.engine,
                                          page: index,
                                          source: widget.source,
                                          enabled: widget.enabled,
                                          selection: widget.selection,
                                          session: widget.session,
                                          connections: widget.connections,
                                          onCopyPage: widget.onCopyPage,
                                          cacheWidth: cacheWidth,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(
              height: 58,
              child: ListView.builder(
                key: ValueKey(
                  widget.source ? 'source-thumbnails' : 'target-thumbnails',
                ),
                controller: thumbnails,
                scrollDirection: Axis.horizontal,
                itemExtent: repairThumbnailExtent,
                itemCount: sizes.length,
                itemBuilder: (context, index) => Padding(
                  padding: const EdgeInsets.all(4),
                  child: InkWell(
                    onTap: () => jump(index),
                    // 翻页时只有新旧两张缩略图的边框重建，缩略图本身不重建。
                    child: ValueListenableBuilder<int>(
                      valueListenable: currentPage,
                      child: Column(
                        children: [
                          Expanded(
                            child: _PageThumbnail(
                              key: ValueKey((widget.document.bytes, index)),
                              document: widget.document,
                              engine: widget.engine,
                              index: index,
                            ),
                          ),
                          Text(
                            '${index + 1}',
                            style: const TextStyle(fontSize: 10),
                          ),
                        ],
                      ),
                      builder: (context, current, child) => Container(
                        width: 42,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          border: Border.all(
                            color: current == index
                                ? const Color(0xff2869e8)
                                : const Color(0xffdce4ef),
                            width: current == index ? 2 : 1,
                          ),
                        ),
                        child: child,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(
              height: 34,
              child: ValueListenableBuilder<(int, double)>(
                valueListenable: progress,
                builder: (context, position, _) => Row(
                  children: [
                    const SizedBox(width: 8),
                    Text(
                      '${position.$1 + 1}/${sizes.length}',
                      style: const TextStyle(fontSize: 11),
                    ),
                    Expanded(
                      child: Slider(
                        value: position.$2,
                        onChanged: (value) {
                          if (scroll.hasClients) {
                            scroll.jumpTo(
                              value * scroll.position.maxScrollExtent,
                            );
                          }
                        },
                      ),
                    ),
                    if (widget.source && widget.onMirrorPage != null)
                      IconButton(
                        tooltip: '在左侧复制为镜像页',
                        iconSize: 16,
                        onPressed: widget.enabled
                            ? () => widget.onMirrorPage!(position.$1)
                            : null,
                        icon: const Icon(Icons.flip_to_front),
                      ),
                    if (widget.onCopyPage != null)
                      TextButton.icon(
                        onPressed: widget.enabled
                            ? () => widget.onCopyPage!(position.$1)
                            : null,
                        icon: const Icon(Icons.copy, size: 14),
                        label: Text(
                          widget.source ? '复制到新单据' : '复制此页',
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}

class _PageThumbnail extends StatefulWidget {
  final EditDocument document;
  final PdfEditEngine engine;
  final int index;
  const _PageThumbnail({
    super.key,
    required this.document,
    required this.engine,
    required this.index,
  });
  @override
  State<_PageThumbnail> createState() => _PageThumbnailState();
}

class _PageThumbnailState extends State<_PageThumbnail> {
  late Future<Uint8List> image = widget.document.thumbnail(
    widget.engine,
    widget.index,
  );
  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
    future: image,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return IconButton(
          icon: const Icon(Icons.refresh, size: 16),
          tooltip: '重试缩略图',
          onPressed: () => setState(() {
            image = widget.document.thumbnail(widget.engine, widget.index);
          }),
        );
      }
      if (!snapshot.hasData) {
        return const Center(
          child: SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 1),
          ),
        );
      }
      return Image.memory(snapshot.data!, fit: BoxFit.contain);
    },
  );
}

class _RepairPage extends StatefulWidget {
  final PdfEditSession? session;
  final RepairConnections? connections;
  final ValueChanged<int>? onCopyPage;
  final EditDocument document;
  final PdfEditEngine engine;
  final int page;
  final bool source, enabled;
  final ValueNotifier<Map<String, RepairSelection>> selection;
  final int? cacheWidth;
  const _RepairPage({
    super.key,
    this.session,
    this.connections,
    this.onCopyPage,
    this.cacheWidth,
    required this.document,
    required this.engine,
    required this.page,
    required this.source,
    required this.enabled,
    required this.selection,
  });
  @override
  State<_RepairPage> createState() => _RepairPageState();
}

class _RepairPageState extends State<_RepairPage> {
  Timer? slowTimer;
  bool slow = false;
  void watchLoading() {
    slowTimer?.cancel();
    slow = false;
    slowTimer = Timer(const Duration(seconds: 20), () {
      if (mounted) setState(() => slow = true);
    });
  }

  late Future<PdfPageSnapshot> preview = widget.document.preview(
    widget.engine,
    widget.page,
    isNeeded: () => mounted,
  );

  @override
  void initState() {
    super.initState();
    widget.connections?.pages[(widget.source, widget.page)] = context;
    watchLoading();
  }

  @override
  void dispose() {
    if (identical(
      widget.connections?.pages[(widget.source, widget.page)],
      context,
    )) {
      widget.connections?.pages.remove((widget.source, widget.page));
    }
    slowTimer?.cancel();
    widget.document.releasePreview(widget.page, preview);
    super.dispose();
  }

  void select(
    PdfPageSnapshot snapshot,
    Offset local,
    Size size, {
    bool additive = false,
  }) {
    if (!widget.source || !widget.enabled) return;
    final at = Offset(local.dx / size.width, local.dy / size.height);
    final matches = snapshot.objects.reversed.where(
      (object) =>
          object.kind == PdfObjectKind.image && object.bounds.contains(at),
    );
    if (matches.isEmpty) return;
    final object = matches.first, key = '${widget.page}:${matches.first.id}';
    final keyboard = HardwareKeyboard.instance;
    final multiple =
        additive ||
        keyboard.isControlPressed ||
        keyboard.isMetaPressed ||
        keyboard.isShiftPressed;
    final next = multiple
        ? Map<String, RepairSelection>.of(widget.selection.value)
        : <String, RepairSelection>{};
    if (multiple && next.containsKey(key)) {
      next.remove(key);
    } else {
      next[key] = (page: widget.page, object: object, size: snapshot.size);
    }
    widget.selection.value = next;
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<PdfPageSnapshot>(
    future: preview,
    builder: (context, state) {
      if (state.connectionState == ConnectionState.done) slowTimer?.cancel();
      if (state.hasError) {
        return ColoredBox(
          color: Colors.white,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('本页加载失败'),
                TextButton(
                  onPressed: () => setState(() {
                    watchLoading();
                    preview = widget.document.preview(
                      widget.engine,
                      widget.page,
                    );
                  }),
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        );
      }
      final snapshot = state.data;
      if (snapshot == null) {
        if (slow) {
          return Center(
            child: Text(
              '第 ${widget.page + 1} 页加载超过 20 秒\n请查看程序运行日志',
              textAlign: TextAlign.center,
            ),
          );
        }
        return const ColoredBox(
          color: Colors.white,
          child: Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        );
      }
      final paper = Image.memory(
        snapshot.png,
        fit: BoxFit.fill,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
        cacheWidth: widget.cacheWidth,
      );
      if (!widget.source) {
        if (widget.session == null) return paper;
        return RepairPreview(
          session: widget.session!,
          document: widget.document,
          page: widget.page,
          snapshot: snapshot,
          onCopyPage: widget.onCopyPage,
          cacheWidth: widget.cacheWidth,
        );
      }
      return LayoutBuilder(
        builder: (context, box) {
          final size = Size(box.maxWidth, box.maxHeight);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (details) => select(snapshot, details.localPosition, size),
            onLongPressStart: (details) =>
                select(snapshot, details.localPosition, size, additive: true),
            child: ValueListenableBuilder<Map<String, RepairSelection>>(
              valueListenable: widget.selection,
              child: Positioned.fill(child: paper),
              builder: (context, selected, child) => Stack(
                children: [
                  child!,
                  for (final item in selected.values.where(
                    (item) => item.page == widget.page,
                  ))
                    Positioned(
                      left: item.object.bounds.left * size.width,
                      top: item.object.bounds.top * size.height,
                      width: item.object.bounds.width * size.width,
                      height: item.object.bounds.height * size.height,
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: const Color(0x202869e8),
                            border: Border.all(
                              color: const Color(0xff2869e8),
                              width: 2,
                            ),
                          ),
                          child: const Align(
                            alignment: Alignment.topRight,
                            child: Icon(
                              Icons.check_circle,
                              size: 20,
                              color: Color(0xff2869e8),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}
