import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../core/breakpoints.dart';
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
              builder: (context, size) {
                // 桌面端按宽度分列（约 320px 一列，2–5 列）；
                // 两行内能放下就均分高度、禁止滚动一屏看完，否则紧凑卡片（高 280）滚动。
                final desktop = !isMobileWidth(
                  MediaQuery.sizeOf(context).width,
                );
                final cols = desktop
                    ? (size.maxWidth / 320).floor().clamp(2, 5)
                    : 1;
                final count = items.length;
                final rows = count == 0 ? 1 : (count / cols).ceil();
                const pad = 36.0, gap = 16.0;
                final fitExtent =
                    (size.maxHeight - pad - (rows - 1) * gap) / rows;
                final fillScreen = desktop && rows <= 2 && fitExtent >= 200;
                return GridView.builder(
                  key: const ValueKey('all-images'),
                  padding: const EdgeInsets.all(18),
                  physics: fillScreen
                      ? const NeverScrollableScrollPhysics()
                      : null,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: cols,
                    mainAxisExtent: fillScreen
                        ? fitExtent
                        : (desktop ? 280 : 300),
                    crossAxisSpacing: gap,
                    mainAxisSpacing: gap,
                  ),
                  itemCount: count,
                  itemBuilder: (context, index) =>
                      _card(context, items[index], index),
                );
              },
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
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${index + 1}. ${item.asset.label}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
              ),
              _cardAction(
                tooltip: '重试此图片',
                onPressed: item.loading
                    ? null
                    : () => controller.retryImage(item),
                icon: Icons.refresh,
              ),
              _cardAction(
                tooltip: '下载此文件',
                onPressed: item.bytes == null ? null : () => _save(item),
                icon: Icons.download_outlined,
              ),
              _cardAction(
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
                icon: Icons.fullscreen,
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
                  padding: const EdgeInsets.all(8),
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
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
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

  /// 卡片操作按钮：紧凑 30px 见方，避免撑高卡片头部。
  Widget _cardAction({
    required String tooltip,
    required VoidCallback? onPressed,
    required IconData icon,
  }) => SizedBox(
    width: 30,
    height: 30,
    child: IconButton(
      padding: EdgeInsets.zero,
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 17),
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
