import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/app_update.dart';
import '../core/update_check.dart';

/// 发现新版本后的统一交互弹窗：展示更新说明。
/// 有可安装附件的平台（Android / macOS / Windows）提供「下载并更新」；
/// 其余平台（iOS 未签名 IPA 无法自安装、附件缺失）回退「前往下载」打开浏览器。
Future<void> showUpdateDialog(BuildContext context, UpdateInfo update) async {
  final prefix = await GithubProxyStore().load();
  if (!context.mounted) return;
  final asset = selectAssetForPlatform(defaultTargetPlatform, update.assets);
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('发现新版本 v${update.version}'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: SelectableText(
            update.notes.isEmpty ? '新版本已发布，可前往下载。' : update.notes,
            style: const TextStyle(fontSize: 13, height: 1.7),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('关闭'),
        ),
        if (asset != null)
          FilledButton.icon(
            onPressed: () {
              Navigator.pop(dialogContext);
              // 外层 context 来自常驻页面，弹窗关闭后继续走下载流程。
              unawaited(_downloadAndInstall(context, update, asset, prefix));
            },
            icon: const Icon(Icons.download_outlined, size: 18),
            label: const Text('下载并更新'),
          )
        else
          FilledButton.icon(
            onPressed: () => launchUrl(Uri.parse(update.url)),
            icon: const Icon(Icons.download_outlined, size: 18),
            label: const Text('前往下载'),
          ),
      ],
    ),
  );
}

/// 应用内下载安装包并拉起安装：进度弹窗实时反馈，可取消；
/// 取消静默结束，失败提示原因，成功提示平台对应的后续操作。
Future<void> _downloadAndInstall(
  BuildContext context,
  UpdateInfo update,
  ReleaseAsset asset,
  String proxyPrefix,
) async {
  final token = DownloadToken();
  final progress = ValueNotifier<(int, int)>((0, asset.size));
  // 进度弹窗禁止点击外部关闭，避免下载状态失控。
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: Text('正在下载 v${update.version}'),
        content: ValueListenableBuilder<(int, int)>(
          valueListenable: progress,
          builder: (_, value, _) {
            final (received, total) = value;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(
                  value: total > 0 ? received / total : null,
                ),
                const SizedBox(height: 12),
                Text(
                  total > 0
                      ? '${_mb(received)} / ${_mb(total)} MB'
                      : '已下载 ${_mb(received)} MB',
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            );
          },
        ),
        actions: [
          TextButton(onPressed: token.cancel, child: const Text('取消')),
        ],
      ),
    ),
  );

  String? error;
  String? hint;
  try {
    final dir = await downloadDirectory();
    final path = '${dir.path}${Platform.pathSeparator}${asset.name}';
    await downloadRelease(
      url: applyProxyPrefix(asset.downloadUrl, proxyPrefix),
      destPath: path,
      token: token,
      onProgress: (received, total) => progress.value = (received, total),
    );
    hint = await launchInstaller(path);
  } on FormatException catch (exception) {
    // 用户主动取消不算失败，不展示错误。
    if (!token.cancelled) error = exception.message;
  } catch (_) {
    error = '下载失败，请检查网络或加速站配置后重试。';
  }

  progress.dispose();
  // 下载期间进度弹窗始终在最顶层，这里直接关闭它。
  if (context.mounted) Navigator.of(context).pop();
  if (!context.mounted || (hint == null && error == null)) return;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(hint != null ? '下载完成' : '更新失败'),
      content: SelectableText(hint ?? error!),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
}

/// 字节数格式化为一位小数的 MB 文本。
String _mb(int bytes) => (bytes / 1048576).toStringAsFixed(1);
