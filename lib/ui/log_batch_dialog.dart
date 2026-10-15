import 'dart:io';
import 'package:flutter/material.dart';
import '../core/contracts.dart';
import '../core/log_batch.dart';
import '../core/log_files.dart';
import '../core/maintenance_controller.dart';

/// 批量下载弹窗：按文件名通配符（同 ls *.pdf）过滤当前目录下全部副本的文件，
/// 确认后先选保存目录，再逐个下载，分片直接写入磁盘（按 Pod 分目录）。
class LogBatchDialog extends StatefulWidget {
  final MaintenanceController controller;
  final LogFileClient client;
  final String dir;
  final List<LogInstance> instances;
  const LogBatchDialog({
    super.key,
    required this.controller,
    required this.client,
    required this.dir,
    required this.instances,
  });
  @override
  State<LogBatchDialog> createState() => _LogBatchDialogState();
}

class _LogBatchDialogState extends State<LogBatchDialog> {
  final pattern = TextEditingController();
  List<LogTarget> targets = [];
  String? error;
  bool running = false;
  int index = 0, fileDone = 0, doneBefore = 0;

  @override
  void dispose() {
    if (running) widget.client.cancel();
    pattern.dispose();
    super.dispose();
  }

  void filter(String value) {
    setState(() {
      try {
        targets = value.trim().isEmpty
            ? []
            : matchLogFiles(widget.instances, value);
        error = null;
      } on FormatException catch (e) {
        targets = [];
        error = e.message;
      }
    });
  }

  int get plannedBytes => targets.fold(0, (sum, item) => sum + item.entry.size);

  Future<void> start() async {
    final root = await chooseLogFolder();
    if (root == null || !mounted) return;
    final now = DateTime.now();
    final stamp =
        '${now.year}${_two(now.month)}${_two(now.day)}_${_two(now.hour)}${_two(now.minute)}${_two(now.second)}';
    final folder = Directory(
      '${root.path}${Platform.pathSeparator}${widget.client.app.name}_logs_$stamp',
    );
    setState(() {
      running = true;
      error = null;
      index = fileDone = doneBefore = 0;
    });
    try {
      final result = await downloadLogBatch(
        widget.client,
        targets,
        folder,
        onProgress: (i, target, done, total) {
          if (!mounted) return;
          setState(() {
            if (i != index) {
              doneBefore += targets[index].entry.size;
              index = i;
            }
            fileDone = done;
          });
        },
      );
      final failed = result.failures.isEmpty
          ? ''
          : '，${result.failures.length} 个失败（见目录内「下载失败清单.txt」）';
      widget.controller.status(
        '批量日志已保存到：${result.folder.path}（成功 ${result.succeeded} 个$failed）',
        isError: result.failures.isNotEmpty,
      );
      if (mounted) Navigator.pop(context);
    } on LogCancelled {
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        running = false;
        error = e is FormatException
            ? e.message
            : '批量下载失败（${e.runtimeType}），请查看接口记录。';
      });
    }
  }

  void cancel() {
    widget.client.cancel();
    setState(() => running = false);
  }

  static String _two(int value) => value.toString().padLeft(2, '0');

  static String _size(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final planned = plannedBytes;
    final done = doneBefore + fileDone;
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: const Text('批量下载日志'),
      content: SizedBox(
        width: 560,
        height: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${widget.client.app.label} · 目录 logs${widget.dir.isEmpty ? '' : '/${widget.dir}'} · 全部正常副本',
              style: const TextStyle(fontSize: 12, color: Color(0xff8090a5)),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: pattern,
              enabled: !running,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              onChanged: filter,
              decoration: const InputDecoration(
                labelText: '文件名匹配（同 ls *.log）',
                hintText: '例如 *.log  或  npl-service.2026-10-15*  *.gz',
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '支持 * ? [abc]，多个模式用空格分隔；须整名匹配、区分大小写；不进入子目录。',
              style: const TextStyle(fontSize: 12, color: Color(0xff8090a5)),
            ),
            const SizedBox(height: 12),
            Text(
              '匹配 ${targets.length} 个文件 · 合计 ${_size(planned)}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            if (running) ...[
              const SizedBox(height: 8),
              Text(
                '正在下载 ${index + 1} / ${targets.length}：${targets[index].instance.title} / ${targets[index].entry.name}',
                style: const TextStyle(fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              LinearProgressIndicator(
                value: planned > 0 ? (done / planned).clamp(0.0, 1.0) : null,
              ),
            ],
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SelectableText(
                  error!,
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: targets.length,
                itemBuilder: (_, i) => ListTile(
                  dense: true,
                  leading: const Icon(Icons.description_outlined),
                  title: Text(targets[i].entry.name),
                  subtitle: Text(
                    '${targets[i].instance.title} · ${_size(targets[i].entry.size)} · ${targets[i].entry.lastModified}',
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (running)
          TextButton(onPressed: cancel, child: const Text('取消下载'))
        else
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        FilledButton(
          onPressed: running || targets.isEmpty ? null : start,
          child: Text(running ? '下载中…' : '批量下载'),
        ),
      ],
    );
  }
}
