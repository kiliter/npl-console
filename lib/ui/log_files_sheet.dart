import 'dart:io';
import 'package:flutter/material.dart';
import '../core/contracts.dart';
import '../core/log_batch.dart';
import '../core/log_files.dart';
import '../core/maintenance_controller.dart';
import 'log_batch_dialog.dart';

/// 日志文件面板：浏览服务 / web 全部副本的 /usr/local/logs，
/// 选择文件后按 1.5MB 分片下载，并在本机顺序拼接后保存。
class LogFilesSheet extends StatefulWidget {
  final MaintenanceController controller;
  const LogFilesSheet({super.key, required this.controller});
  @override
  State<LogFilesSheet> createState() => _LogFilesSheetState();
}

class _LogFilesSheetState extends State<LogFilesSheet> {
  LogApp app = LogApp.server;
  late LogFileClient client = LogFileClient(widget.controller, app);
  String dir = '';
  List<LogInstance>? instances;
  String? error;
  bool loading = false;
  String? downloading;
  int done = 0, total = 0;

  @override
  void initState() {
    super.initState();
    load('');
  }

  @override
  void dispose() {
    client.cancel();
    super.dispose();
  }

  Future<void> load(String next) async {
    client.cancel();
    setState(() {
      dir = next;
      loading = true;
      error = null;
      instances = null;
      downloading = null;
    });
    try {
      final result = await client.list(next);
      if (mounted) setState(() => instances = result);
    } on LogCancelled {
      return;
    } catch (e) {
      if (mounted) setState(() => error = _text(e));
    }
    if (mounted) setState(() => loading = false);
  }

  void switchApp(LogApp next) {
    if (next == app) return;
    client.cancel();
    app = next;
    client = LogFileClient(widget.controller, app);
    load('');
  }

  /// 先选保存目录，分片边下载边写盘；同名文件以 Pod 名前缀区分副本。
  Future<void> download(LogInstance instance, LogEntry entry) async {
    final folder = await chooseLogFolder();
    if (folder == null || !mounted) return;
    final target = File(
      '${folder.path}${Platform.pathSeparator}${safeLogName('${instance.title}_${entry.name}')}',
    );
    client.cancel();
    setState(() {
      loading = false;
      error = null;
      downloading = '${instance.title} / ${entry.name}';
      done = 0;
      total = entry.size;
    });
    try {
      final result = await client.download(
        instance,
        entry,
        target,
        onProgress: (value, size) {
          if (mounted) {
            setState(() {
              done = value;
              total = size;
            });
          }
        },
      );
      if (!mounted) return;
      setState(() => downloading = null);
      widget.controller.status(
        '日志文件已保存：${result.file.path}（${_size(result.size)}）',
      );
    } on LogCancelled {
      return;
    } catch (e) {
      if (mounted) {
        setState(() {
          downloading = null;
          error = _text(e);
        });
      }
    }
  }

  /// 批量下载复用当前目录列表与连接；关闭弹窗时会终止未完成的下载。
  Future<void> openBatch() => showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => LogBatchDialog(
      controller: widget.controller,
      client: client,
      dir: dir,
      instances: instances!,
    ),
  );

  void cancelDownload() {
    client.cancel();
    setState(() => downloading = null);
  }

  String _text(Object e) =>
      e is FormatException ? e.message : '请求失败（${e.runtimeType}），请检查网络或查看接口记录。';

  static String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final parts = dir.isEmpty ? <String>[] : dir.split('/');
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '日志文件',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: downloading == null && !loading && instances != null
                    ? openBatch
                    : null,
                icon: const Icon(Icons.download_for_offline_outlined, size: 18),
                label: const Text('批量下载'),
              ),
              IconButton(
                tooltip: '刷新',
                onPressed: downloading == null ? () => load(dir) : null,
                icon: const Icon(Icons.refresh),
              ),
              IconButton(
                tooltip: '关闭',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          Text(
            '环境：${widget.controller.settings.current.name} · 目录 /usr/local/logs · 覆盖注册中心中的全部副本',
            style: const TextStyle(fontSize: 12, color: Color(0xff8090a5)),
          ),
          const SizedBox(height: 12),
          SegmentedButton<LogApp>(
            segments: [
              for (final item in LogApp.values)
                ButtonSegment(value: item, label: Text(item.label)),
            ],
            selected: {app},
            onSelectionChanged: downloading == null
                ? (value) => switchApp(value.single)
                : null,
          ),
          const SizedBox(height: 8),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton(
                onPressed: downloading == null ? () => load('') : null,
                child: const Text('logs'),
              ),
              for (var i = 0; i < parts.length; i++) ...[
                const Icon(Icons.chevron_right, size: 16),
                TextButton(
                  onPressed: downloading == null
                      ? () => load(parts.sublist(0, i + 1).join('/'))
                      : null,
                  child: Text(parts[i]),
                ),
              ],
            ],
          ),
          if (downloading != null) progress(),
          if (error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: SelectableText(
                error!,
                style: const TextStyle(color: Colors.red),
              ),
            ),
          Expanded(child: body()),
        ],
      ),
    );
  }

  Widget progress() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '正在下载 $downloading · ${_size(done)} / ${_size(total)}',
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 6),
              LinearProgressIndicator(value: total > 0 ? done / total : null),
            ],
          ),
        ),
        TextButton(onPressed: cancelDownload, child: const Text('取消')),
      ],
    ),
  );

  Widget body() {
    if (loading) return const Center(child: CircularProgressIndicator());
    final list = instances;
    if (list == null) return const SizedBox.shrink();
    if (list.isEmpty) return const Center(child: Text('注册中心未返回副本'));
    return ListView(
      children: [
        for (final instance in list) ...[
          ListTile(
            dense: true,
            leading: Icon(
              instance.ok ? Icons.dns_outlined : Icons.error_outline,
              color: instance.ok ? null : Colors.red,
            ),
            title: Text(
              instance.title,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text(
              instance.ok
                  ? '${instance.instance} · ${instance.entries.length} 项'
                  : '${instance.instance} · ${instance.status} · ${instance.message}',
            ),
          ),
          if (instance.ok && instance.entries.isEmpty)
            const Padding(
              padding: EdgeInsets.only(left: 56, bottom: 8),
              child: Text('空目录', style: TextStyle(color: Color(0xff8090a5))),
            ),
          for (final entry in instance.entries)
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.only(left: 40, right: 8),
              leading: Icon(
                entry.isDir
                    ? Icons.folder_outlined
                    : Icons.description_outlined,
              ),
              title: Text(entry.name),
              subtitle: Text(
                entry.isDir
                    ? entry.lastModified
                    : '${_size(entry.size)} · ${entry.lastModified}',
              ),
              trailing: entry.isDir
                  ? const Icon(Icons.chevron_right)
                  : const Icon(Icons.download_outlined),
              enabled: downloading == null,
              onTap: () =>
                  entry.isDir ? load(entry.path) : download(instance, entry),
            ),
          const Divider(height: 1),
        ],
      ],
    );
  }
}
