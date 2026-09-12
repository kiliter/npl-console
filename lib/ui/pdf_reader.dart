import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:pdfrx/pdfrx.dart';

/// 真实 PDF 阅读器，共享文档生成缩略图，连续阅读不重新请求 OBS。
class PdfReader extends StatefulWidget {
  final Uint8List bytes;
  final String name;
  final int initialPage;
  final ValueChanged<int>? onPageChanged;
  const PdfReader({
    super.key,
    required this.bytes,
    required this.name,
    this.initialPage = 1,
    this.onPageChanged,
  });
  @override
  State<PdfReader> createState() => _PdfReaderState();
}

class _PdfReaderState extends State<PdfReader> {
  final controller = PdfViewerController();
  PdfDocument? document;
  late int page = widget.initialPage;
  bool thumbs = false;
  String fit = 'width';

  /// 布局完成后使用阅读器坐标计算适应比例，按钮与实际纸张缩放保持一致。
  void applyFit(String value) {
    setState(() => fit = value);
    if (!controller.isReady) return;
    if (value == 'actual') {
      controller.setZoom(controller.visibleRect.center, 1);
      return;
    }
    controller.goTo(
      value == 'page'
          ? controller.calcMatrixForFit(pageNumber: page)
          : controller.calcMatrixFitWidthForPage(pageNumber: page),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, size) => Column(
      children: [
        Container(
          color: Colors.white,
          height: 48,
          child: Row(
            children: [
              IconButton(
                tooltip: '页面缩略图',
                isSelected: thumbs,
                onPressed: () => setState(() => thumbs = !thumbs),
                icon: const Icon(Icons.view_sidebar_outlined, size: 19),
              ),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      Text(
                        '$page / ${document?.pages.length ?? '—'} 页',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xff71839c),
                        ),
                      ),
                      const SizedBox(width: 12),
                      DropdownButton<String>(
                        value: fit,
                        underline: const SizedBox(),
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xff253b59),
                        ),
                        items: const [
                          DropdownMenuItem(value: 'width', child: Text('适应宽度')),
                          DropdownMenuItem(value: 'page', child: Text('适应整页')),
                          DropdownMenuItem(
                            value: 'actual',
                            child: Text('实际大小'),
                          ),
                        ],
                        onChanged: (v) {
                          if (v != null) applyFit(v);
                        },
                      ),
                      IconButton(
                        tooltip: '缩小 PDF',
                        onPressed: () =>
                            controller.isReady ? controller.zoomDown() : null,
                        icon: const Icon(Icons.remove, size: 18),
                      ),
                      ListenableBuilder(
                        listenable: controller,
                        builder: (context, _) => Text(
                          controller.isReady
                              ? '${(controller.currentZoom * 100).round()}%'
                              : '—',
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                      IconButton(
                        tooltip: '放大 PDF',
                        onPressed: () =>
                            controller.isReady ? controller.zoomUp() : null,
                        icon: const Icon(Icons.add, size: 18),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Row(
            children: [
              if (thumbs && document != null)
                Container(
                  width: size.maxWidth < 500 ? 76 : 106,
                  color: const Color(0xffe8edf4),
                  child: ListView.builder(
                    itemCount: document!.pages.length,
                    padding: const EdgeInsets.all(8),
                    itemBuilder: (context, index) => InkWell(
                      onTap: () => controller.goToPage(pageNumber: index + 1),
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 14),
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: page == index + 1
                                ? const Color(0xff2869e8)
                                : Colors.transparent,
                            width: 2,
                          ),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Column(
                          children: [
                            AspectRatio(
                              aspectRatio:
                                  document!.pages[index].width /
                                  document!.pages[index].height,
                              child: PdfPageView(
                                document: document,
                                pageNumber: index + 1,
                                maximumDpi: 80,
                              ),
                            ),
                            const SizedBox(height: 5),
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
              Expanded(
                child: PdfViewer.data(
                  widget.bytes,
                  sourceName:
                      '${widget.name}-${identityHashCode(widget.bytes)}',
                  controller: controller,
                  initialPageNumber: widget.initialPage,
                  params: PdfViewerParams(
                    margin: 18,
                    backgroundColor: const Color(0xffe9eef5),
                    pageDropShadow: const BoxShadow(
                      color: Color(0x26324761),
                      blurRadius: 10,
                      offset: Offset(0, 4),
                    ),
                    onViewerReady: (doc, ctrl) {
                      if (!mounted) return;
                      setState(() => document = doc);
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted && controller.isReady) applyFit(fit);
                      });
                    },
                    onPageChanged: (value) {
                      if (value != null && mounted) {
                        setState(() => page = value);
                        widget.onPageChanged?.call(value);
                      }
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
        Container(
          height: 28,
          color: const Color(0xfff7f9fc),
          alignment: Alignment.center,
          child: const Text(
            '连续阅读 · 滚动浏览全部页面 · 双指缩放',
            style: TextStyle(fontSize: 10, color: Color(0xff8192a9)),
          ),
        ),
      ],
    ),
  );
}
