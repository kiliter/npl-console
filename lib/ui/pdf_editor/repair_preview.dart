import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../../core/pdf_editor/edit_session.dart';
import '../../core/pdf_editor/pdf_engine.dart';

/// PDF 底图保持稳定，共享区仅更新 Canvas 图层；应用时才写 PDF。
class RepairPreview extends StatefulWidget {
  final PdfEditSession session;
  final EditDocument document;
  final int page;
  final PdfPageSnapshot snapshot;
  final ValueChanged<int>? onCopyPage;
  const RepairPreview({
    super.key,
    required this.session,
    required this.document,
    required this.page,
    required this.snapshot,
    this.onCopyPage,
  });
  @override
  State<RepairPreview> createState() => _RepairPreviewState();
}

class _RepairPreviewState extends State<RepairPreview> {
  final decoded = <SharedPdfImage, ui.Image>{};
  final pending = <SharedPdfImage>{};
  Uint8List? background;
  String hiddenKey = '';
  String? error;
  int revision = 0;
  @override
  void initState() {
    super.initState();
    widget.session.addListener(update);
    update();
  }

  @override
  void dispose() {
    revision++;
    widget.session.removeListener(update);
    for (final image in decoded.values) {
      image.dispose();
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

  void update() {
    final images = widget.session.imagesForPage(widget.page);
    for (final m in decoded.keys.toList()) {
      if (!images.contains(m)) {
        decoded.remove(m)!.dispose();
      }
    }
    for (final m in images) {
      if (!decoded.containsKey(m) && pending.add(m)) {
        decode(m);
      }
    }
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
        widget.session.engine
            .previewBackground(
              widget.document.bytes,
              widget.page,
              hidden.values.toList(),
            )
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
    if (mounted) setState(() {});
  }

  Future<void> decode(SharedPdfImage m) async {
    try {
      final codec = await ui.instantiateImageCodec(m.png);
      ui.Image image;
      try {
        image = (await codec.getNextFrame()).image;
      } finally {
        codec.dispose();
      }
      if (!mounted || !widget.session.imagesForPage(widget.page).contains(m)) {
        image.dispose();
        return;
      }
      setState(() => decoded[m] = image);
    } catch (_) {
      if (mounted) setState(() => error = '图片预览失败，请重试');
    } finally {
      pending.remove(m);
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
              ),
              IgnorePointer(
                child: CustomPaint(
                  painter: _OverlayPainter(
                    widget.session
                        .imagesForPage(widget.page)
                        .where(decoded.containsKey)
                        .map((m) => (m, decoded[m]!))
                        .toList(),
                    widget.snapshot.size,
                    Theme.of(context).textTheme.bodySmall?.fontFamily,
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
                      update();
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
  _OverlayPainter(this.images, this.page, this.fontFamily);
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

  @override
  bool shouldRepaint(covariant _OverlayPainter oldDelegate) => true;
}
