import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../core/pdf_editor/edit_session.dart';
import '../../core/pdf_editor/pdf_engine.dart';

/// 修复预览的解码与背景缓存，按编辑会话共享。
///
/// 连续滚动时页面组件会反复销毁、重建；不缓存时每次回到同一页都要重新解码
/// 共享图片，并通过 PDFium 重新渲染遮掉原图的背景。缓存按会话保存解码后的
/// 位图（按显示宽度分桶）和背景 PNG，调用方拿到的是位图克隆，自行释放。
class RepairPreviewCache {
  RepairPreviewCache._(this.session);
  final PdfEditSession session;
  static final _bySession = Expando<RepairPreviewCache>('repairPreviewCache');

  static RepairPreviewCache of(PdfEditSession session) =>
      _bySession[session] ??= RepairPreviewCache._(session);

  /// 编辑页销毁时释放该会话的全部缓存位图。
  static void release(PdfEditSession session) {
    _bySession[session]?._clear();
    _bySession[session] = null;
  }

  static const maxImages = 48, maxBackgrounds = 8;
  final _images = <(SharedPdfImage, int), _CacheEntry<ui.Image>>{};
  final _backgrounds = <(Uint8List, int, String), _CacheEntry<Uint8List>>{};

  /// 实际解码与背景渲染次数，仅供测试验证缓存命中。
  @visibleForTesting
  int decodeCount = 0, backgroundCount = 0;

  /// 已解码完成时同步返回克隆，避免滚回页面时先闪一帧无图状态。
  ui.Image? imageNow(SharedPdfImage m, int width) {
    final entry = _touch(_images, (m, width));
    return entry?.value?.clone();
  }

  Future<ui.Image> image(SharedPdfImage m, int width) async {
    _prune();
    final key = (m, width);
    var entry = _touch(_images, key);
    if (entry == null) {
      decodeCount++;
      final created = entry = _CacheEntry(_decode(m.png, width));
      _images[key] = created;
      created.future.then<void>(
        (image) => created.value = image,
        // 失败的解码不留在缓存里，下次重试。
        onError: (Object _) {
          if (identical(_images[key], created)) _images.remove(key);
        },
      );
      while (_images.length > maxImages) {
        _images.remove(_images.keys.first)!.dispose();
      }
    }
    // 先于任何淘汰回调注册，克隆一定发生在主位图释放之前。
    final image = await entry.future;
    return image.clone();
  }

  Uint8List? backgroundNow(Uint8List bytes, int page, String key) =>
      _touch(_backgrounds, (bytes, page, key))?.value;

  Future<Uint8List> background(
    Uint8List bytes,
    int page,
    String key,
    List<PdfEditObject> hidden,
  ) {
    final id = (bytes, page, key);
    final cached = _touch(_backgrounds, id);
    if (cached != null) return cached.future;
    backgroundCount++;
    final entry = _CacheEntry(
      session.engine.previewBackground(bytes, page, hidden),
    );
    _backgrounds[id] = entry;
    entry.future.then<void>(
      (png) => entry.value = png,
      onError: (Object _) {
        if (identical(_backgrounds[id], entry)) _backgrounds.remove(id);
      },
    );
    while (_backgrounds.length > maxBackgrounds) {
      _backgrounds.remove(_backgrounds.keys.first);
    }
    return entry.future;
  }

  /// 按最近使用排序：命中的条目移到末尾，淘汰从头部开始。
  static _CacheEntry<T>? _touch<K, T>(Map<K, _CacheEntry<T>> map, K key) {
    final entry = map.remove(key);
    if (entry != null) map[key] = entry;
    return entry;
  }

  /// 移出共享区的图片不再出现在任何页面，释放其位图。
  void _prune() {
    final alive = session.materials.toSet();
    _images.removeWhere((key, entry) {
      if (alive.contains(key.$1)) return false;
      entry.dispose();
      return true;
    });
  }

  void _clear() {
    for (final entry in _images.values) {
      entry.dispose();
    }
    _images.clear();
    _backgrounds.clear();
  }

  static Future<ui.Image> _decode(Uint8List png, int width) async {
    final codec = await ui.instantiateImageCodec(
      png,
      targetWidth: width,
      allowUpscaling: false,
    );
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  }
}

class _CacheEntry<T> {
  final Future<T> future;
  T? value;
  _CacheEntry(this.future);

  void dispose() {
    final value = this.value;
    if (value is ui.Image) {
      value.dispose();
    } else {
      future.then<void>(
        (v) => v is ui.Image ? v.dispose() : null,
        onError: (Object _) {},
      );
    }
  }
}

/// 位图解码宽度按 256 物理像素分桶，窗口微调不会反复解码。
int repairDecodeWidth(double physicalPixels) =>
    math.max(256, (physicalPixels / 256).ceil() * 256);

/// PDF 底图保持稳定，共享区仅更新 Canvas 图层；应用时才写 PDF。
class RepairPreview extends StatefulWidget {
  final PdfEditSession session;
  final EditDocument document;
  final int page;
  final PdfPageSnapshot snapshot;
  final ValueChanged<int>? onCopyPage;

  /// 页面底图解码宽度（物理像素），为空时按原图尺寸解码。
  final int? cacheWidth;
  const RepairPreview({
    super.key,
    required this.session,
    required this.document,
    required this.page,
    required this.snapshot,
    this.onCopyPage,
    this.cacheWidth,
  });
  @override
  State<RepairPreview> createState() => _RepairPreviewState();
}

class _RepairPreviewState extends State<RepairPreview> {
  late RepairPreviewCache cache = RepairPreviewCache.of(widget.session);

  /// 本页的共享图片，随 [PdfEditSession.materialsRevision] 刷新。
  List<SharedPdfImage> images = const [];
  final decoded = <SharedPdfImage, ({int width, ui.Image image})>{};
  final requested = <SharedPdfImage, int>{};
  Uint8List? background;
  String hiddenKey = '';
  String? error;
  int revision = 0;
  int? seenRevision;
  Size? size;
  double pixelRatio = 1;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(update);
    refresh(force: true, rebuild: false);
  }

  @override
  void didUpdateWidget(covariant RepairPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session)) {
      oldWidget.session.removeListener(update);
      widget.session.addListener(update);
      cache = RepairPreviewCache.of(widget.session);
    }
    if (!identical(oldWidget.session, widget.session) ||
        !identical(oldWidget.document, widget.document) ||
        !identical(oldWidget.snapshot, widget.snapshot) ||
        oldWidget.page != widget.page) {
      hiddenKey = '';
      refresh(force: true, rebuild: false);
    }
  }

  @override
  void dispose() {
    revision++;
    widget.session.removeListener(update);
    for (final entry in decoded.values) {
      entry.image.dispose();
    }
    super.dispose();
  }

  Rect bounds(SharedPdfImage m) {
    final r = m.bounds!, from = m.sourceSize!, to = widget.snapshot.size;
    return Rect.fromLTWH(
      r.left * from.width / to.width,
      r.top * from.height / to.height,
      r.width * from.width / to.width,
      r.height * from.height / to.height,
    );
  }

  /// 会话通知很频繁（busy 切换、同步状态等），只有共享图片或删除标记变化才刷新本页。
  void update() => refresh();

  void refresh({bool force = false, bool rebuild = true}) {
    final current = widget.session.materialsRevision;
    if (!force && current == seenRevision) return;
    seenRevision = current;
    images = widget.session.imagesForPage(widget.page);
    for (final m in decoded.keys.toList()) {
      if (!images.contains(m)) decoded.remove(m)!.image.dispose();
    }
    requested.removeWhere((m, _) => !images.contains(m));
    requestImages();
    final hidden = <String, PdfEditObject>{
      for (final o
          in widget.session.deletedImages[widget.page] ?? <PdfEditObject>[])
        o.id: o,
    };
    for (final m in images) {
      final r = bounds(m);
      for (final o in widget.snapshot.objects.where(
        (o) => o.kind == PdfObjectKind.image,
      )) {
        if (sameImageBounds(r, o.bounds)) {
          hidden[o.id] = o;
        }
      }
    }
    final key = (hidden.keys.toList()..sort()).join('|');
    if (key != hiddenKey) {
      hiddenKey = key;
      final request = ++revision;
      error = null;
      if (hidden.isEmpty) {
        background = null;
      } else {
        final bytes = widget.document.bytes, page = widget.page;
        background = cache.backgroundNow(bytes, page, key);
        if (background == null) {
          cache
              .background(bytes, page, key, hidden.values.toList())
              .then(
                (png) {
                  if (mounted && request == revision) {
                    setState(() => background = png);
                  }
                },
                onError: (Object e) {
                  if (mounted && request == revision) {
                    setState(() => error = '本页预览失败，请重试');
                  }
                },
              );
        }
      }
    }
    if (rebuild && mounted) setState(() {});
  }

  /// 按图片在页面上的显示尺寸解码；已有的更高分辨率位图直接沿用。
  void requestImages() {
    final page = size;
    if (page == null) return;
    for (final m in images) {
      final dest = bounds(m);
      final width = repairDecodeWidth(
        math.max(dest.width * page.width, dest.height * page.height) *
            pixelRatio,
      );
      final have = decoded[m];
      if ((have != null && have.width >= width) || requested[m] == width) {
        continue;
      }
      final ready = cache.imageNow(m, width);
      if (ready != null) {
        have?.image.dispose();
        decoded[m] = (width: width, image: ready);
        continue;
      }
      requested[m] = width;
      cache
          .image(m, width)
          .then(
            (image) {
              if (!mounted || requested[m] != width || !images.contains(m)) {
                image.dispose();
                return;
              }
              requested.remove(m);
              setState(() {
                decoded.remove(m)?.image.dispose();
                decoded[m] = (width: width, image: image);
              });
            },
            onError: (Object _) {
              if (!mounted) return;
              if (requested[m] == width) requested.remove(m);
              setState(() => error = '图片预览失败，请重试');
            },
          );
    }
  }

  Future<void> menu(
    Offset local,
    Offset global,
    Size size, {
    bool onlyImage = false,
  }) async {
    if (widget.session.busy) return;
    final point = Offset(local.dx / size.width, local.dy / size.height);
    final materials = widget.session
        .imagesForPage(widget.page)
        .reversed
        .where((m) => bounds(m).contains(point));
    final material = materials.isEmpty ? null : materials.first;
    final deleted = widget.session.deletedImages[widget.page] ?? [];
    final objects = widget.snapshot.objects.reversed.where(
      (o) =>
          o.kind == PdfObjectKind.image &&
          o.bounds.contains(point) &&
          !deleted.any((d) => d.id == o.id),
    );
    final object = objects.isEmpty ? null : objects.first;
    if (onlyImage && material == null && object == null) return;
    if (material == null &&
        object == null &&
        deleted.isEmpty &&
        widget.onCopyPage == null) {
      return;
    }
    final box = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(global.dx, global.dy, 1, 1),
        Offset.zero & box.size,
      ),
      items: [
        if (material != null || object != null)
          const PopupMenuItem(value: 'stash', child: Text('移入共享区暂存')),
        if (material != null || object != null)
          const PopupMenuItem(value: 'delete', child: Text('删除图片')),
        if (deleted.isNotEmpty)
          const PopupMenuItem(value: 'restore', child: Text('恢复本页删除的图片')),
        if (widget.onCopyPage != null)
          const PopupMenuItem(value: 'copy', child: Text('复制本页到指定页下面…')),
      ],
    );
    if (!mounted || widget.session.busy) return;
    if (action == 'stash') {
      await widget.session.stashTargetImage(
        widget.page,
        material: material,
        object:
            material == null ||
                (object != null &&
                    sameImageBounds(bounds(material), object.bounds))
            ? object
            : null,
      );
    } else if (action == 'delete') {
      if (material != null) {
        await widget.session.removeMaterial(material);
        if (object != null &&
            sameImageBounds(bounds(material), object.bounds)) {
          widget.session.deleteTargetImage(widget.page, object);
        }
      } else if (object != null) {
        widget.session.deleteTargetImage(widget.page, object);
      }
    } else if (action == 'restore') {
      widget.session.restoreDeletedImages(widget.page);
    } else if (action == 'copy') {
      widget.onCopyPage?.call(widget.page);
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final size = Size(box.maxWidth, box.maxHeight);
      final ratio = MediaQuery.devicePixelRatioOf(context);
      if (size != this.size || ratio != pixelRatio) {
        this.size = size;
        pixelRatio = ratio;
        requestImages();
      }
      return DragTarget<SharedPdfImage>(
        onWillAcceptWithDetails: (details) =>
            !widget.session.busy &&
            details.data.staged &&
            widget.session.materials.contains(details.data),
        onAcceptWithDetails: (details) {
          final render = context.findRenderObject()! as RenderBox;
          final point = render.globalToLocal(details.offset);
          widget.session.placeStagedImage(
            details.data,
            widget.page,
            Offset(point.dx / size.width, point.dy / size.height),
          );
        },
        builder: (context, candidates, rejected) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) =>
              menu(d.localPosition, d.globalPosition, size, onlyImage: true),
          onSecondaryTapUp: (d) =>
              menu(d.localPosition, d.globalPosition, size),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.memory(
                background ?? widget.snapshot.png,
                fit: BoxFit.fill,
                gaplessPlayback: true,
                cacheWidth: widget.cacheWidth,
              ),
              IgnorePointer(
                child: CustomPaint(
                  painter: _OverlayPainter(
                    [
                      for (final m in images)
                        if (decoded[m] case final entry?) (m, entry.image),
                    ],
                    widget.snapshot.size,
                    Theme.of(context).textTheme.bodySmall?.fontFamily,
                    seenRevision ?? 0,
                  ),
                ),
              ),
              if (candidates.isNotEmpty)
                IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: const Color(0x182869e8),
                      border: Border.all(
                        color: const Color(0xff2869e8),
                        width: 2,
                      ),
                    ),
                    child: const Center(
                      child: Text(
                        '松开放置暂存图片',
                        style: TextStyle(color: Color(0xff2869e8)),
                      ),
                    ),
                  ),
                ),
              if (error != null)
                Align(
                  alignment: Alignment.topCenter,
                  child: TextButton(
                    onPressed: () {
                      hiddenKey = 'retry';
                      refresh(force: true);
                    },
                    child: Text(error!),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}

class _OverlayPainter extends CustomPainter {
  final List<(SharedPdfImage, ui.Image)> images;
  final Size page;
  final String? fontFamily;

  /// 共享图片的位置、页码可原地修改，以会话版本号判断内容是否变化。
  final int revision;
  _OverlayPainter(this.images, this.page, this.fontFamily, this.revision);
  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    for (final (m, image) in images) {
      final from = m.sourceSize!, r = m.bounds!, basis = m.basis;
      canvas.save();
      if (basis != null && basis.length == 3) {
        // PDF 图像原点在左下，位图原点在左上。
        Offset scaled(Offset p) => Offset(
          p.dx * from.width / page.width * size.width,
          p.dy * from.height / page.height * size.height,
        );
        final origin = scaled(basis[2]),
            x = scaled(basis[1]) - scaled(basis[0]),
            y = scaled(basis[0]) - scaled(basis[2]);
        canvas.transform(
          Float64List.fromList([
            x.dx,
            x.dy,
            0,
            0,
            y.dx,
            y.dy,
            0,
            0,
            0,
            0,
            1,
            0,
            origin.dx,
            origin.dy,
            0,
            1,
          ]),
        );
        canvas.drawImageRect(
          image,
          Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
          const Rect.fromLTWH(0, 0, 1, 1),
          Paint()..filterQuality = FilterQuality.medium,
        );
      } else {
        final dest = Rect.fromLTWH(
          r.left * from.width / page.width * size.width,
          r.top * from.height / page.height * size.height,
          r.width * from.width / page.width * size.width,
          r.height * from.height / page.height * size.height,
        );
        canvas.drawImageRect(
          image,
          Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
          dest,
          Paint()..filterQuality = FilterQuality.medium,
        );
      }
      canvas.restore();
    }
    // 来源标识只在画布绘制，应用/导出不包含边框和标签。
    for (final (m, _) in images) {
      final r = m.bounds!, from = m.sourceSize!;
      final rect = Rect.fromLTWH(
        r.left * from.width / page.width * size.width,
        r.top * from.height / page.height * size.height,
        r.width * from.width / page.width * size.width,
        r.height * from.height / page.height * size.height,
      ).intersect(Offset.zero & size);
      if (rect.isEmpty) continue;
      final color = m.staged
          ? const Color(0xff7854aa)
          : m.local
          ? const Color(0xffaa6216)
          : const Color(0xff2869e8);
      final paint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      if (m.staged) {
        final path = Path()..addRect(rect.deflate(.75));
        for (final metric in path.computeMetrics()) {
          for (var offset = 0.0; offset < metric.length; offset += 9) {
            canvas.drawPath(
              metric.extractPath(offset, (offset + 5).clamp(0, metric.length)),
              paint,
            );
          }
        }
      } else {
        canvas.drawRect(rect.deflate(.75), paint);
      }
      final label = TextPainter(
        text: TextSpan(
          text: m.staged
              ? '暂存图片'
              : m.local
              ? '本地图片'
              : '共享图片',
          style: TextStyle(
            color: Colors.white,
            fontSize: 10,
            height: 1.2,
            fontFamily: fontFamily,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: size.width);
      final x = rect.left.clamp(
        0.0,
        (size.width - label.width - 8).clamp(0.0, size.width),
      );
      final y = rect.top >= label.height + 4
          ? rect.top - label.height - 4
          : rect.top;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y, label.width + 8, label.height + 4),
          const Radius.circular(3),
        ),
        Paint()..color = color,
      );
      label.paint(canvas, Offset(x + 4, y + 2));
      label.dispose();
    }
  }

  /// 父级重建（如画布启用状态切换）而图层内容不变时不重绘。
  @override
  bool shouldRepaint(covariant _OverlayPainter oldDelegate) =>
      oldDelegate.revision != revision ||
      oldDelegate.page != page ||
      oldDelegate.fontFamily != fontFamily ||
      !listEquals(oldDelegate.images, images);
}
