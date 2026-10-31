import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../core/pdf_editor/pdf_engine.dart';
import '../../core/pdf_editor/edit_session.dart';

/// Fit-to-width paper with object hit testing. The raster is a preview only;
/// edits are applied to native PDF objects, never to this rendered image.
class EditorCanvas extends StatefulWidget {
  final EditDocument document;
  final bool source, enabled, textTool;
  final PdfEditObject? selected;
  final ValueChanged<PdfEditObject?> onSelect;
  final void Function(SharedPdfImage, Offset)? onPlace;
  final void Function(PdfEditObject, Rect)? onMove;
  final SharedPdfImage? pending;
  final Widget? selectionToolbar;
  const EditorCanvas({
    super.key,
    required this.document,
    required this.source,
    required this.enabled,
    required this.onSelect,
    this.selected,
    this.onPlace,
    this.onMove,
    this.pending,
    this.selectionToolbar,
    this.textTool = false,
  });
  @override
  State<EditorCanvas> createState() => _EditorCanvasState();
}

class _EditorCanvasState extends State<EditorCanvas> {
  final paperKey = GlobalKey();
  Rect? preview;
  Rect? gestureStart;
  Offset gestureDelta = Offset.zero;
  double zoom = 1;
  Offset point(Offset global) {
    final box = paperKey.currentContext!.findRenderObject()! as RenderBox;
    final local = box.globalToLocal(global);
    return Offset(
      (local.dx / box.size.width).clamp(0, 1),
      (local.dy / box.size.height).clamp(0, 1),
    );
  }

  void select(Offset at) {
    if (!widget.enabled) return;
    if (!widget.source && widget.pending != null) {
      widget.onPlace?.call(widget.pending!, at);
      return;
    }
    final objects = widget.document.snapshot.objects.reversed.where(
      (o) =>
          (widget.source
              ? o.kind == PdfObjectKind.image
              : !widget.textTool || o.kind == PdfObjectKind.text) &&
          o.bounds.inflate(.006).contains(at),
    );
    widget.onSelect(objects.isEmpty ? null : objects.first);
  }

  @override
  void didUpdateWidget(covariant EditorCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.document.snapshot != widget.document.snapshot ||
        oldWidget.selected != widget.selected) {
      preview = null;
    }
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0xffe9eef5),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final mobile = constraints.maxWidth < 600;
        final width = math.max(
          160.0,
          constraints.maxWidth - (mobile ? 16 : 32),
        );
        final size = widget.document.snapshot.size;
        return Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: width * zoom + (mobile ? 16 : 32),
                  child: SingleChildScrollView(
                    padding: EdgeInsets.all(mobile ? 8 : 16),
                    child: DragTarget<SharedPdfImage>(
                      onWillAcceptWithDetails: (_) =>
                          widget.enabled && !widget.source,
                      onAcceptWithDetails: (details) => widget.onPlace?.call(
                        details.data,
                        point(details.offset),
                      ),
                      builder: (context, candidates, rejected) => SizedBox(
                        key: paperKey,
                        width: width * zoom,
                        height: width * zoom * size.height / size.width,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapUp: (details) =>
                              select(point(details.globalPosition)),
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Positioned.fill(
                                child: Image.memory(
                                  widget.document.snapshot.png,
                                  fit: BoxFit.fill,
                                  gaplessPlayback: true,
                                  filterQuality: FilterQuality.high,
                                ),
                              ),
                              if (candidates.isNotEmpty)
                                Positioned.fill(
                                  child: IgnorePointer(
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: Colors.blue.withValues(
                                          alpha: .08,
                                        ),
                                        border: Border.all(
                                          color: Colors.blue,
                                          width: 2,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              if (widget.selected != null)
                                ...selection(
                                  width * zoom,
                                  width * zoom * size.height / size.width,
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
            Container(
              height: 36,
              color: Colors.white.withValues(alpha: .9),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: '缩小',
                    padding: EdgeInsets.zero,
                    iconSize: 16,
                    onPressed: () =>
                        setState(() => zoom = (zoom - .25).clamp(1, 3)),
                    icon: const Icon(Icons.remove),
                  ),
                  Text(
                    '${(zoom * 100).round()}%',
                    style: const TextStyle(fontSize: 11),
                  ),
                  IconButton(
                    tooltip: '放大',
                    padding: EdgeInsets.zero,
                    iconSize: 16,
                    onPressed: () =>
                        setState(() => zoom = (zoom + .25).clamp(1, 3)),
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    ),
  );
  List<Widget> selection(double w, double h) {
    final object = widget.selected!, rect = preview ?? object.bounds;
    final canMove =
        !widget.source &&
        widget.enabled &&
        object.kind == PdfObjectKind.image &&
        widget.pending == null &&
        !object.nested;
    void start() {
      gestureStart = rect;
      gestureDelta = Offset.zero;
    }

    void update(DragUpdateDetails d, bool resize, [Offset? corner]) {
      if (gestureStart == null) return;
      gestureDelta += Offset(d.delta.dx / w, d.delta.dy / h);
      final r = gestureStart!;
      setState(() {
        if (resize) {
          final left = corner?.dx == r.left, top = corner?.dy == r.top;
          final x = gestureDelta.dx * (left ? -1 : 1) / r.width,
              y = gestureDelta.dy * (top ? -1 : 1) / r.height;
          final scale = (1 + (x.abs() > y.abs() ? x : y)).clamp(
            math.min(.02 / r.width, .02 / r.height),
            math.min(
              (left ? r.right : 1 - r.left) / r.width,
              (top ? r.bottom : 1 - r.top) / r.height,
            ),
          );
          final newW = r.width * scale, newH = r.height * scale;
          preview = Rect.fromLTWH(
            left ? r.right - newW : r.left,
            top ? r.bottom - newH : r.top,
            newW,
            newH,
          );
        } else {
          preview = Rect.fromLTWH(
            (r.left + gestureDelta.dx).clamp(0, math.max(0, 1 - r.width)),
            (r.top + gestureDelta.dy).clamp(0, math.max(0, 1 - r.height)),
            r.width,
            r.height,
          );
        }
      });
    }

    void end() {
      if (preview != null) widget.onMove?.call(object, preview!);
      gestureStart = null;
    }

    return [
      if (widget.selectionToolbar != null)
        Positioned(
          left: (rect.center.dx * w - 108).clamp(0, math.max(0, w - 216)),
          top: math.max(0, rect.top * h - 50),
          child: Material(
            color: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: const BorderSide(color: Color(0xffe4ebf4)),
            ),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(width: 216, child: widget.selectionToolbar),
          ),
        ),
      Positioned(
        left: rect.left * w,
        top: rect.top * h,
        width: math.max(2, rect.width * w),
        height: math.max(2, rect.height * h),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => widget.onSelect(object),
          onPanStart: canMove ? (_) => start() : null,
          onPanUpdate: canMove ? (d) => update(d, false) : null,
          onPanEnd: canMove ? (_) => end() : null,
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xff2869e8), width: 2),
              color: Colors.blue.withValues(alpha: .04),
            ),
          ),
        ),
      ),
      if (canMove)
        for (final corner in [
          rect.topLeft,
          rect.topRight,
          rect.bottomLeft,
          rect.bottomRight,
        ])
          Positioned(
            left: corner.dx * w - 9,
            top: corner.dy * h - 9,
            width: 18,
            height: 18,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => start(),
              onPanUpdate: (d) => update(d, true, corner),
              onPanEnd: (_) => end(),
              child: Center(
                child: Container(
                  width: 11,
                  height: 11,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(
                      color: const Color(0xff2869e8),
                      width: 2,
                    ),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          ),
    ];
  }
}
