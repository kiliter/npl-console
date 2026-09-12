import 'dart:math' as math;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../core/maintenance_controller.dart';
import 'file_preview.dart';

/// 全部图片在同一个滚动区域展示，每张图独立显示加载、失败、下载与放大操作。
class ImageGallery extends StatelessWidget {
  final MaintenanceController controller;
  final bool fullscreen;
  const ImageGallery({
    super.key,
    required this.controller,
    this.fullscreen = false,
  });
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final items = controller.gallery;
      return Column(
        children: [
          Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            color: Colors.white,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '全部影像 · ${items.length} 份',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xff8392a8),
                    ),
                  ),
                ),
                if (!fullscreen)
                  TextButton.icon(
                    onPressed: () => openPreviewFullscreen(
                      context,
                      '全部影像',
                      (_) => ImageGallery(
                        controller: controller,
                        fullscreen: true,
                      ),
                    ),
                    icon: const Icon(Icons.fullscreen),
                    label: const Text('全屏'),
                  ),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, size) => GridView.builder(
                key: const ValueKey('all-images'),
                padding: const EdgeInsets.all(18),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: size.maxWidth > 850 ? 2 : 1,
                  mainAxisExtent: math.max(
                    300,
                    math.min(470, size.maxHeight - 30),
                  ),
                  crossAxisSpacing: 16,
                  mainAxisSpacing: 16,
                ),
                itemCount: items.length,
                itemBuilder: (context, index) =>
                    _card(context, items[index], index),
              ),
            ),
          ),
        ],
      );
    },
  );
  Widget _card(BuildContext context, GalleryItem item, int index) => Container(
    key: ValueKey('image-card-$index'),
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: const Color(0xffdfe7f2)),
    ),
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${index + 1}. ${item.asset.label}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: '重试此图片',
                onPressed: item.loading
                    ? null
                    : () => controller.retryImage(item),
                icon: const Icon(Icons.refresh, size: 18),
              ),
              IconButton(
                tooltip: '下载此文件',
                onPressed: item.bytes == null ? null : () => _save(item),
                icon: const Icon(Icons.download_outlined, size: 18),
              ),
              IconButton(
                tooltip: '全屏查看此图片',
                onPressed: item.bytes == null || item.type != 'image'
                    ? null
                    : () => openPreviewFullscreen(
                        context,
                        item.asset.label,
                        (_) => FilePreview(
                          bytes: item.bytes!,
                          type: 'image',
                          name: item.asset.name,
                          fullscreen: true,
                        ),
                      ),
                icon: const Icon(Icons.fullscreen, size: 21),
              ),
            ],
          ),
        ),
        Expanded(
          child: item.loading
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : item.error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(item.error!, textAlign: TextAlign.center),
                  ),
                )
              : Padding(
                  padding: const EdgeInsets.all(12),
                  child: SizedBox.expand(
                    child: Image.memory(
                      item.bytes!,
                      fit: BoxFit.contain,
                      errorBuilder: (_, error, stack) =>
                          const Center(child: Text('图片解码失败，请下载查看')),
                    ),
                  ),
                ),
        ),
        Padding(
          padding: const EdgeInsets.all(10),
          child: Text(
            item.asset.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10, color: Color(0xff8392a8)),
          ),
        ),
      ],
    ),
  );
  Future<void> _save(GalleryItem item) async {
    try {
      final uri = await FilePicker.saveFile(
        fileName: item.asset.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_'),
        bytes: item.bytes!,
      );
      controller.status(uri == null ? '已取消保存。' : '文件已保存：$uri');
    } catch (error) {
      controller.status('文件保存失败：$error', isError: true);
    }
  }
}
