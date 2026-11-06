import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/maintenance_controller.dart';
import '../core/runtime_log.dart';
import 'large_text_view.dart';
import 'listenable_selector.dart';

const ink = Color(0xff0f1e36);

/// 调用详情最新优先；刷新采用通知监听，不影响正在进行的查询。
class LogsDialog extends StatefulWidget {
  final MaintenanceController controller;
  const LogsDialog({super.key, required this.controller});
  @override
  State<LogsDialog> createState() => LogsDialogState();
}

class LogsDialogState extends State<LogsDialog> {
  CallLog? selected;

  Widget _logPathBadge(String tag, String text, {bool isError = false}) =>
      Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: isError
                  ? const Color(0xfffef2f2)
                  : const Color(0xffeaf2ff),
              borderRadius: BorderRadius.circular(5),
              border: Border.all(
                color: isError
                    ? const Color(0xfffecaca)
                    : const Color(0xffbfdbfe),
              ),
            ),
            child: Text(
              tag,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: isError
                    ? const Color(0xffdc2626)
                    : const Color(0xff2563eb),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              text,
              style: TextStyle(
                fontFamily: 'Menlo',
                fontSize: 11,
                color: isError
                    ? const Color(0xffb91c1c)
                    : const Color(0xff475569),
              ),
            ),
          ),
        ],
      );

  Widget _statusPill(CallLog log) {
    final ok = log.status == 200 || log.state.contains('成功');
    final err =
        (log.status != null && log.status! >= 400) ||
        log.state.contains('失败') ||
        log.state.contains('异常');
    final bg = ok
        ? const Color(0xffecfdf5)
        : err
        ? const Color(0xfffef2f2)
        : const Color(0xffeaf2ff);
    final fg = ok
        ? const Color(0xff047857)
        : err
        ? const Color(0xffb91c1c)
        : const Color(0xff2563eb);
    final border = ok
        ? const Color(0xffa7f3d0)
        : err
        ? const Color(0xfffecaca)
        : const Color(0xffbfdbfe);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border),
      ),
      child: Text(
        '${log.state} · ${log.status ?? '—'}',
        style: TextStyle(
          fontFamily: 'Menlo',
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: fg,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: Colors.white,
    surfaceTintColor: Colors.transparent,
    clipBehavior: Clip.antiAlias,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: const BorderSide(color: Color(0xffdde6f1)),
    ),
    child: SizedBox(
      width: 1150,
      height: 680,
      child: ListenableSelector(
        listenable: widget.controller,
        // 仅记录列表、最新/选中记录的状态或日志路径变化时重建；
        // 详情文本可能达数 MB，不随无关通知重复拼接与排版。
        selector: () {
          final c = widget.controller, logs = c.logs;
          final first = logs.isEmpty ? null : logs.first;
          return (
            logs.length,
            first,
            first?.state,
            selected?.state,
            c.logStore.path,
            c.logStore.error,
          );
        },
        builder: (context, _) {
          final logs = widget.controller.logs;
          final entry = selected ?? (logs.isEmpty ? null : logs.first);
          return Column(
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
                        Icons.data_object,
                        size: 18,
                        color: Color(0xff2563eb),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Text(
                                '接口调用记录',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                  color: ink,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xffeaf2ff),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  '共 ${logs.length} 条',
                                  style: const TextStyle(
                                    fontFamily: 'Menlo',
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xff2563eb),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          const Text(
                            '最新请求优先 · 支持实时观察请求参数、响应报文与落盘日志路径',
                            style: TextStyle(
                              fontSize: 11,
                              color: Color(0xff64748b),
                            ),
                          ),
                        ],
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: entry == null
                          ? null
                          : () => Clipboard.setData(
                              ClipboardData(text: entry.detail),
                            ),
                      icon: const Icon(Icons.copy_outlined, size: 14),
                      label: const Text('复制详情'),
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
                    const SizedBox(width: 6),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(
                        Icons.close,
                        size: 18,
                        color: Color(0xff475569),
                      ),
                    ),
                  ],
                ),
              ),
              // 实际落盘路径可直接复制，写入失败时明确展示，避免误以为日志已保存。
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
                decoration: const BoxDecoration(
                  color: Color(0xfff8fafd),
                  border: Border(bottom: BorderSide(color: Color(0xffe4ecf6))),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _logPathBadge(
                      '请求日志',
                      widget.controller.logStore.error ??
                          '日志文件：${widget.controller.logStore.path ?? '首次请求后创建'}',
                      isError: widget.controller.logStore.error != null,
                    ),
                    const SizedBox(height: 6),
                    ListenableBuilder(
                      listenable: RuntimeLog.instance,
                      builder: (context, _) => _logPathBadge(
                        '运行日志',
                        RuntimeLog.instance.store.error != null
                            ? '程序运行日志写入失败：${RuntimeLog.instance.store.error}'
                            : '程序运行日志：${RuntimeLog.instance.store.path ?? '尚未创建'}',
                        isError: RuntimeLog.instance.store.error != null,
                      ),
                    ),
                  ],
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
                        child: LargeTextView(
                          text: entry?.detail ?? '尚无接口调用。',
                          padding: const EdgeInsets.all(16),
                          style: const TextStyle(fontSize: 12, height: 1.7),
                        ),
                      ),
                    ],
                  ),
                )
              else
                Expanded(
                  child: Row(
                    children: [
                      Container(
                        width: math.min(
                          280,
                          MediaQuery.sizeOf(context).width * .3,
                        ),
                        decoration: const BoxDecoration(
                          color: Color(0xfff8fafd),
                          border: Border(
                            right: BorderSide(color: Color(0xffdde6f1)),
                          ),
                        ),
                        child: logs.isEmpty
                            ? const Center(
                                child: Text(
                                  '尚无接口调用记录',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Color(0xff94a3b8),
                                  ),
                                ),
                              )
                            : ListView.builder(
                                padding: const EdgeInsets.all(10),
                                itemCount: logs.length,
                                itemBuilder: (context, index) {
                                  final log = logs[index];
                                  final active = log == entry;
                                  return Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: Material(
                                      color: active
                                          ? Colors.white
                                          : const Color(0xfff1f5f9)
                                                .withValues(alpha: 0.55),
                                      borderRadius: BorderRadius.circular(10),
                                      child: InkWell(
                                        borderRadius: BorderRadius.circular(10),
                                        onTap: () =>
                                            setState(() => selected = log),
                                        child: Container(
                                          padding: const EdgeInsets.all(11),
                                          decoration: BoxDecoration(
                                            borderRadius:
                                                BorderRadius.circular(10),
                                            border: Border.all(
                                              color: active
                                                  ? const Color(0xff2563eb)
                                                  : const Color(0xffe2e8f0),
                                              width: active ? 1.4 : 1,
                                            ),
                                            boxShadow: active
                                                ? const [
                                                    BoxShadow(
                                                      color: Color(0x142563eb),
                                                      blurRadius: 8,
                                                      offset: Offset(0, 2),
                                                    ),
                                                  ]
                                                : null,
                                          ),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Row(
                                                children: [
                                                  Expanded(
                                                    child: Text(
                                                      log.label,
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: TextStyle(
                                                        fontSize: 12.5,
                                                        fontWeight:
                                                            FontWeight.w700,
                                                        color: active
                                                            ? const Color(
                                                                0xff2563eb,
                                                              )
                                                            : ink,
                                                      ),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 6),
                                                  _statusPill(log),
                                                ],
                                              ),
                                              const SizedBox(height: 6),
                                              Text(
                                                log.url,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontFamily: 'Menlo',
                                                  fontSize: 10,
                                                  height: 1.4,
                                                  color: Color(0xff64748b),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (entry != null)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 18,
                                  vertical: 10,
                                ),
                                decoration: const BoxDecoration(
                                  color: Colors.white,
                                  border: Border(
                                    bottom: BorderSide(
                                      color: Color(0xffe4ecf6),
                                    ),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Text(
                                      entry.label,
                                      style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w800,
                                        color: ink,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    _statusPill(entry),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: SelectableText(
                                        entry.url,
                                        maxLines: 1,
                                        style: const TextStyle(
                                          fontFamily: 'Menlo',
                                          fontSize: 11,
                                          color: Color(0xff64748b),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            Expanded(
                              child: ColoredBox(
                                color: const Color(0xfff8fafd),
                                child: SizedBox.expand(
                                  child: LargeTextView(
                                    text: entry?.detail ?? '尚无接口调用。',
                                    style: const TextStyle(
                                      fontFamily: 'Menlo',
                                      fontSize: 12,
                                      height: 1.75,
                                      color: ink,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
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
