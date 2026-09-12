import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'message_explorer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'pdf_reader.dart';

/// 全屏仅覆盖应用内部内容，不切换系统窗口或桌面；支持退出按钮及 Esc。
Future<void> openPreviewFullscreen(
  BuildContext context,
  String title,
  WidgetBuilder builder,
) async {
  if (!context.mounted) return;
  await showGeneralDialog<void>(
    context: context,
    barrierDismissible: false,
    transitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (context, animation, secondary) => CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.pop(context),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: const Color(0xfff1f5fb),
          appBar: AppBar(
            automaticallyImplyLeading: false,
            title: Text(title, style: const TextStyle(fontSize: 16)),
            actions: [
              TextButton.icon(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.fullscreen_exit),
                label: Text(
                  (defaultTargetPlatform == TargetPlatform.android ||
                          defaultTargetPlatform == TargetPlatform.iOS)
                      ? '退出全屏'
                      : '退出全屏 · Esc',
                ),
              ),
              const SizedBox(width: 16),
            ],
          ),
          body: SafeArea(child: builder(context)),
        ),
      ),
    ),
  );
}

/// PDF 连续滚动，文本完整展示；预览组件没有分页或人为分行。
class FilePreview extends StatefulWidget {
  final Uint8List bytes;
  final String type, name;
  final bool fullscreen;
  final MessageSession? messageSession;
  final VoidCallback? onDownload;
  final VoidCallback? onRefresh;
  final int initialPage;
  const FilePreview({
    super.key,
    required this.bytes,
    required this.type,
    required this.name,
    this.fullscreen = false,
    this.messageSession,
    this.onDownload,
    this.onRefresh,
    this.initialPage = 1,
  });
  @override
  State<FilePreview> createState() => _FilePreviewState();
}

class _FilePreviewState extends State<FilePreview> {
  final transform = TransformationController();
  late final session = widget.messageSession ?? MessageSession();
  int previewRevision = 0;
  late int pdfPage = widget.initialPage;
  @override
  void dispose() {
    transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, size) {
      // 手机键盘或横屏导致高度不足时允许外层滚动，避免遮挡搜索及退出操作。
      return size.maxHeight < 320
          ? SingleChildScrollView(
              child: SizedBox(height: 320, child: _preview()),
            )
          : _preview();
    },
  );

  Widget _preview() => Column(
    children: [
      Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        color: Colors.white,
        child: Row(
          children: [
            Expanded(
              child: Text(
                widget.type == 'pdf'
                    ? widget.name
                    : widget.type == 'image'
                    ? '手势缩放 / 拖拽查看'
                    : '完整文本 · 滚动阅读',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Color(0xff8392a8), fontSize: 12),
              ),
            ),
            if (widget.onRefresh != null)
              IconButton(
                tooltip: '重新读取',
                onPressed: widget.onRefresh,
                icon: const Icon(Icons.refresh, size: 20),
              ),
            if (widget.onDownload != null)
              IconButton(
                tooltip: '下载文件',
                onPressed: widget.onDownload,
                icon: const Icon(Icons.download_outlined, size: 20),
              ),
            if (widget.type == 'image')
              TextButton(
                onPressed: () => transform.value = Matrix4.identity(),
                child: const Text('适应窗口'),
              ),
            if (!widget.fullscreen)
              TextButton.icon(
                key: const ValueKey('preview-fullscreen'),
                onPressed: () async {
                  await openPreviewFullscreen(
                    context,
                    widget.name,
                    (_) => FilePreview(
                      bytes: widget.bytes,
                      type: widget.type,
                      name: widget.name,
                      fullscreen: true,
                      messageSession: session,
                      onDownload: widget.onDownload,
                      onRefresh: widget.onRefresh,
                      initialPage: pdfPage,
                    ),
                  );
                  if (mounted) setState(() => previewRevision++);
                },
                icon: const Icon(Icons.fullscreen, size: 21),
                label: const Text('全屏'),
              ),
          ],
        ),
      ),
      Expanded(child: _body()),
    ],
  );
  Widget _body() {
    if (widget.type == 'pdf') {
      return PdfReader(
        bytes: widget.bytes,
        name: widget.name,
        initialPage: pdfPage,
        onPageChanged: (page) => pdfPage = page,
      );
    }
    if (widget.type == 'image') {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: InteractiveViewer(
          transformationController: transform,
          minScale: .5,
          maxScale: 8,
          child: SizedBox.expand(
            child: Image.memory(
              widget.bytes,
              fit: BoxFit.contain,
              errorBuilder: (_, error, stack) =>
                  const Center(child: Text('图片解码失败，请下载查看')),
            ),
          ),
        ),
      );
    }
    if (widget.type != 'text') {
      return const Center(child: Text('此文件类型暂不支持预览，请下载查看。'));
    }
    return MessageExplorer(
      key: ValueKey(previewRevision),
      session: session,
      text: utf8.decode(widget.bytes, allowMalformed: true),
    );
  }
}
