import 'dart:async';
import 'repair_connections.dart';
import 'repair_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import '../../core/pdf_editor/edit_session.dart';
import '../../core/pdf_editor/pdf_engine.dart';

typedef RepairScrollPosition = ({bool source, int page, double fraction});

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
  });
  @override
  State<EditorCanvas> createState() => _EditorCanvasState();
}

class _EditorCanvasState extends State<EditorCanvas> {
  final scroll = ScrollController();
  final progress = ValueNotifier<(int, double)>((0, 0));
  List<double> offsets = [];
  List<double> pageHeights = [];
  bool following = false;
  @override
  void initState() {
    super.initState();
    widget.connections?.viewports[widget.source] = context;
    scroll.addListener(updateProgress);
    widget.scrollLink?.addListener(followOther);
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
    if (!following && widget.scrollLink != null && page < pageHeights.length) {
      widget.scrollLink!.value = (
        source: widget.source,
        page: page,
        fraction: ((at - offsets[page]) / pageHeights[page]).clamp(0, 1),
      );
    }
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
    scroll.dispose();
    progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0xffe9eef5),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final width = (constraints.maxWidth - 24).clamp(1.0, double.infinity);
        final sizes = widget.document.pageSizes;
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
              child: Scrollbar(
                controller: scroll,
                thumbVisibility: true,
                interactive: true,
                child: ListView.builder(
                  key: PageStorageKey(
                    '${widget.source ? '旧' : '新'}-${widget.document.caseNo}',
                  ),
                  controller: scroll,
                  padding: const EdgeInsets.all(12),
                  scrollCacheExtent: const ScrollCacheExtent.pixels(300),
                  itemCount: sizes.length,
                  itemExtentBuilder: (index, dimensions) => heights[index],
                  itemBuilder: (context, index) => GestureDetector(
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
                                  key: ValueKey((widget.document.bytes, index)),
                                  document: widget.document,
                                  engine: widget.engine,
                                  page: index,
                                  source: widget.source,
                                  enabled: widget.enabled,
                                  selection: widget.selection,
                                  session: widget.session,
                                  connections: widget.connections,
                                  onCopyPage: widget.onCopyPage,
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
            SizedBox(
              height: 58,
              child: ValueListenableBuilder<(int, double)>(
                valueListenable: progress,
                builder: (context, position, _) => ListView.builder(
                  key: ValueKey(
                    widget.source ? 'source-thumbnails' : 'target-thumbnails',
                  ),
                  scrollDirection: Axis.horizontal,
                  itemCount: sizes.length,
                  itemBuilder: (context, index) => Padding(
                    padding: const EdgeInsets.all(4),
                    child: InkWell(
                      onTap: () => jump(index),
                      child: Container(
                        width: 42,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          border: Border.all(
                            color: position.$1 == index
                                ? const Color(0xff2869e8)
                                : const Color(0xffdce4ef),
                            width: position.$1 == index ? 2 : 1,
                          ),
                        ),
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
  const _RepairPage({
    super.key,
    this.session,
    this.connections,
    this.onCopyPage,
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
      );
      if (!widget.source) {
        if (widget.session == null) return paper;
        return RepairPreview(
          session: widget.session!,
          document: widget.document,
          page: widget.page,
          snapshot: snapshot,
          onCopyPage: widget.onCopyPage,
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
