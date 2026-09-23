import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/maintenance_controller.dart';

const ink = Color(0xff1b2b42);

/// 调用详情最新优先；刷新采用通知监听，不影响正在进行的查询。
class LogsDialog extends StatefulWidget {
  final MaintenanceController controller;
  const LogsDialog({super.key, required this.controller});
  @override
  State<LogsDialog> createState() => LogsDialogState();
}

class LogsDialogState extends State<LogsDialog> {
  CallLog? selected;
  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 1150,
      height: 680,
      child: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          final logs = widget.controller.logs;
          final entry = selected ?? (logs.isEmpty ? null : logs.first);
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(18),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '接口调用记录',
                        style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: entry == null
                          ? null
                          : () => Clipboard.setData(
                              ClipboardData(text: entry.detail),
                            ),
                      child: const Text('复制详情'),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              // 实际落盘路径可直接复制，写入失败时明确展示，避免误以为日志已保存。
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 8,
                ),
                child: SelectableText(
                  widget.controller.logStore.error ??
                      '日志文件：${widget.controller.logStore.path ?? '首次请求后创建'}',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
              if (MediaQuery.sizeOf(context).shortestSide < 600)
                Expanded(
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: DropdownButtonFormField<CallLog>(
                          key: ValueKey(entry),
                          initialValue: entry,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: '选择接口请求',
                          ),
                          items: logs
                              .map(
                                (log) => DropdownMenuItem(
                                  value: log,
                                  child: Text(
                                    '${log.label} · ${log.state}',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: (log) => setState(() => selected = log),
                        ),
                      ),
                      Expanded(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(16),
                          child: SelectableText(
                            entry?.detail ?? '尚无接口调用。',
                            style: const TextStyle(fontSize: 12, height: 1.7),
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              else
                Expanded(
                  child: Row(
                    children: [
                      SizedBox(
                        width: math.min(
                          260,
                          MediaQuery.sizeOf(context).width * .3,
                        ),
                        child: ListView.builder(
                          itemCount: logs.length,
                          itemBuilder: (context, index) {
                            final log = logs[index];
                            return Material(
                              type: MaterialType.transparency,
                              child: ListTile(
                                selected: log == entry,
                                title: Text(
                                  log.label,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                subtitle: Text(
                                  '${log.state} · ${log.status ?? '—'}\n${log.url}',
                                  maxLines: 4,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 10),
                                ),
                                onTap: () => setState(() => selected = log),
                              ),
                            );
                          },
                        ),
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(
                        child: ColoredBox(
                          color: const Color(0xfff8faff),
                          child: SizedBox.expand(
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.all(22),
                              child: SelectableText(
                                entry?.detail ?? '尚无接口调用。',
                                style: const TextStyle(
                                  fontFamily: 'Menlo',
                                  fontSize: 12,
                                  height: 1.8,
                                  color: ink,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    ),
  );
}
