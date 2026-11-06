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

  Widget _appSwitch() => Container(
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      color: const Color(0xffeaf0f8),
      borderRadius: BorderRadius.circular(9),
      border: Border.all(color: const Color(0xffd8e3f0)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final item in LogApp.values)
          GestureDetector(
            onTap: downloading == null ? () => switchApp(item) : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: app == item ? Colors.white : Colors.transparent,
                borderRadius: BorderRadius.circular(7),
                boxShadow: app == item
                    ? const [
                        BoxShadow(
                          color: Color(0x140f172a),
                          blurRadius: 4,
                          offset: Offset(0, 1),
                        ),
                      ]
                    : null,
              ),
              child: Text(
                item.label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: app == item ? FontWeight.w700 : FontWeight.w600,
                  color: app == item
                      ? const Color(0xff2563eb)
                      : const Color(0xff64748b),
                ),
              ),
            ),
          ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final parts = dir.isEmpty ? <String>[] : dir.split('/');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(20, 14, 12, 14),
          decoration: const BoxDecoration(
            color: Color(0xfff5f8fc),
            border: Border(bottom: BorderSide(color: Color(0xffdde6f1))),
          ),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: const Color(0xffeaf2ff),
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: const Color(0xffbfdbfe)),
                ),
                child: const Icon(
                  Icons.terminal_rounded,
                  size: 18,
                  color: Color(0xff2563eb),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '日志文件',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: Color(0xff0f1e36),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '环境：${widget.controller.settings.current.name} · 目录 /usr/local/logs · 覆盖注册中心中的全部副本',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xff64748b),
                      ),
                    ),
                  ],
                ),
              ),
              OutlinedButton.icon(
                onPressed: downloading == null && !loading && instances != null
                    ? openBatch
                    : null,
                icon: const Icon(Icons.download_for_offline_outlined, size: 16),
                label: const Text('批量下载'),
                style: OutlinedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: const Color(0xff2563eb),
                  side: const BorderSide(color: Color(0xffbfdbfe)),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  textStyle: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: '刷新',
                onPressed: downloading == null ? () => load(dir) : null,
                icon: const Icon(Icons.refresh, size: 18),
              ),
              IconButton(
                tooltip: '关闭',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close, size: 18),
              ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _appSwitch(),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          TextButton(
                            onPressed: downloading == null
                                ? () => load('')
                                : null,
                            child: const Text('logs'),
                          ),
                          for (var i = 0; i < parts.length; i++) ...[
                            const Icon(Icons.chevron_right, size: 16),
                            TextButton(
                              onPressed: downloading == null
                                  ? () =>
                                        load(parts.sublist(0, i + 1).join('/'))
                                  : null,
                              child: Text(parts[i]),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
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
          ),
        ),
      ],
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
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(
                color: instance.ok
                    ? const Color(0xffdde6f1)
                    : const Color(0xfffecaca),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  decoration: BoxDecoration(
                    color: instance.ok
                        ? const Color(0xfff5f8fc)
                        : const Color(0xfffef2f2),
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(10),
                    ),
                  ),
                  child: ListTile(
                    dense: true,
                    leading: Icon(
                      instance.ok ? Icons.dns_outlined : Icons.error_outline,
                      color: instance.ok
                          ? const Color(0xff0d8a6a)
                          : const Color(0xffdc2626),
                    ),
                    title: Text(
                      instance.title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: Color(0xff0f1e36),
                      ),
                    ),
                    subtitle: Text(
                      instance.ok
                          ? '${instance.instance} · ${instance.entries.length} 项'
                          : '${instance.instance} · ${instance.status} · ${instance.message}',
                    ),
                  ),
                ),
                if (instance.ok && instance.entries.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(left: 56, top: 8, bottom: 10),
                    child: Text(
                      '空目录',
                      style: TextStyle(color: Color(0xff7f91ab)),
                    ),
                  ),
                for (final entry in instance.entries)
                  ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.only(left: 40, right: 8),
                    leading: Icon(
                      entry.isDir
                          ? Icons.folder_outlined
                          : Icons.description_outlined,
                      color: entry.isDir
                          ? const Color(0xff2563eb)
                          : const Color(0xff4a5d78),
                    ),
                    title: Text(entry.name),
                    subtitle: Text(
                      entry.isDir
                          ? entry.lastModified
                          : '${_size(entry.size)} · ${entry.lastModified}',
                    ),
                    trailing: entry.isDir
                        ? const Icon(Icons.chevron_right)
                        : const Icon(
                            Icons.download_outlined,
                            color: Color(0xff2563eb),
                          ),
                    enabled: downloading == null,
                    onTap: () => entry.isDir
                        ? load(entry.path)
                        : download(instance, entry),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
