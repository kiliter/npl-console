import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/contracts.dart';
import '../core/maintenance_controller.dart';
import 'query_sheet.dart';
import 'work_details.dart';

/// 数据查询面板：按物理表直查 woinfo/wobizinfo/wosigninfo/wopicinfo，
/// 复用现有只读 queryList 接口；结果为表格列表，点击行查看完整字段。
class TableQuerySheet extends StatefulWidget {
  final MaintenanceController controller;
  const TableQuerySheet({super.key, required this.controller});
  @override
  State<TableQuerySheet> createState() => _TableQuerySheetState();
}

class _TableQuerySheetState extends State<TableQuerySheet> {
  final caseNo = TextEditingController();
  final sysAccept = TextEditingController();
  final picSeq = TextEditingController();
  TableKind table = TableKind.woinfo;
  DateTime? month;
  String? error;
  bool running = false;
  List<Record>? rows;
  @override
  void dispose() {
    caseNo.dispose();
    sysAccept.dispose();
    picSeq.dispose();
    super.dispose();
  }

  String get monthText => month == null
      ? ''
      : '${month!.year}-${month!.month.toString().padLeft(2, '0')}';

  /// 先由业务契约本地校验，合法条件才发起只读查询，错误就地展示。
  Future<void> submit() async {
    if (running) return;
    Record body;
    try {
      body = tableQueryBody(
        table,
        caseNo: caseNo.text,
        sysAccept: sysAccept.text,
        opMonth: monthText,
        picSeq: table.hasPicSeq ? picSeq.text : '',
      );
    } on FormatException catch (e) {
      setState(() => error = e.message);
      return;
    }
    setState(() {
      error = null;
      running = true;
      rows = null;
    });
    try {
      final result = await widget.controller.queryTable(table, body);
      if (!mounted) return;
      setState(() {
        running = false;
        rows = result;
      });
    } on FormatException catch (e) {
      if (!mounted) return;
      setState(() {
        running = false;
        error = e.message;
      });
    } catch (_) {
      // 用户主动取消或其它代次失效，恢复表单但不报错。
      if (!mounted) return;
      setState(() => running = false);
    }
  }

  void cancel() {
    widget.controller.cancel();
    setState(() => running = false);
  }

  Future<void> pickMonth() async {
    final selected = await showDialog<DateTime>(
      context: context,
      builder: (_) =>
          MonthPicker(current: month ?? DateTime(DateTime.now().year, DateTime.now().month)),
    );
    if (selected != null && mounted) setState(() => month = selected);
  }

  Widget conditionField(
    String label,
    TextEditingController input, {
    String? hint,
    bool number = false,
  }) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          TextField(
            controller: input,
            enabled: !running,
            keyboardType: number ? TextInputType.number : TextInputType.text,
            autocorrect: false,
            onSubmitted: (_) => submit(),
            decoration: InputDecoration(hintText: hint),
          ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final fields = rows == null || rows!.isEmpty
        ? <String>[]
        : rows!.first.keys.take(8).toList();
    return PopScope(
      canPop: !running,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '数据查询',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '按表直查 · 当前 ${table.label}（${table.tableName}）',
                          style: const TextStyle(
                            color: Color(0xff8192a9),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭数据查询',
                    onPressed: running ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                key: const ValueKey('table-query-panel'),
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SegmentedButton<TableKind>(
                      segments: [
                        for (final item in TableKind.values)
                          ButtonSegment(
                            value: item,
                            label: Text(
                              item.label,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                      ],
                      selected: {table},
                      showSelectedIcon: false,
                      onSelectionChanged: running
                          ? null
                          : (v) => setState(() {
                              table = v.single;
                              error = null;
                              rows = null;
                            }),
                    ),
                    const SizedBox(height: 24),
                    conditionField('单据号', caseNo, hint: '输入完整单据号，可单独查询'),
                    const SizedBox(height: 18),
                    conditionField('受理流水', sysAccept, hint: '按受理流水查询需选择业务月份'),
                    const SizedBox(height: 18),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '业务月份',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 8),
                              OutlinedButton.icon(
                                onPressed: running ? null : pickMonth,
                                icon: const Icon(
                                  Icons.calendar_month_outlined,
                                  size: 18,
                                ),
                                label: Text(
                                  month == null ? '不限制月份' : monthText,
                                ),
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 17,
                                    horizontal: 12,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (month != null) ...[
                          const SizedBox(width: 8),
                          IconButton(
                            tooltip: '清除月份条件',
                            onPressed: running
                                ? null
                                : () => setState(() => month = null),
                            icon: const Icon(Icons.close, size: 18),
                          ),
                        ],
                      ],
                    ),
                    if (table.hasPicSeq) ...[
                      const SizedBox(height: 18),
                      conditionField(
                        '图片序号',
                        picSeq,
                        hint: '正整数，仅图片表可用',
                        number: true,
                      ),
                    ],
                    const SizedBox(height: 12),
                    const Text(
                      '至少填写一个条件；单据号可单独查询，受理流水需搭配业务月份。',
                      style: TextStyle(fontSize: 12, color: Color(0xff8192a9)),
                    ),
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 18),
                        child: Text(
                          error!,
                          key: const ValueKey('table-query-error'),
                          style: const TextStyle(
                            color: Colors.red,
                            height: 1.5,
                          ),
                        ),
                      ),
                    if (running) ...[
                      const SizedBox(height: 24),
                      const LinearProgressIndicator(),
                      const SizedBox(height: 12),
                      Text(
                        widget.controller.message,
                        style: const TextStyle(height: 1.7),
                      ),
                    ],
                    if (rows != null) ...[
                      const SizedBox(height: 28),
                      Text(
                        rows!.isEmpty
                            ? '未查询到记录'
                            : '查询结果 · ${rows!.length} 条记录${rows!.first.keys.length > 8 ? ' · 表格仅展示前 8 列，点击行查看完整字段' : ''}',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 12),
                      if (rows!.isNotEmpty)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Container(
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: const Color(0xffe4ebf4),
                              ),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: DataTable(
                                headingRowHeight: 40,
                                dataRowMinHeight: 40,
                                dataRowMaxHeight: 48,
                                showCheckboxColumn: false,
                                columns: [
                                  for (final key in fields)
                                    DataColumn(
                                      label: Text(
                                        fieldLabels[key] ?? key,
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                    ),
                                ],
                                rows: [
                                  for (final record in rows!)
                                    DataRow(
                                      onSelectChanged: (_) =>
                                          showDialog<void>(
                                            context: context,
                                            builder: (_) =>
                                                RecordDetailsDialog(
                                                  table: table,
                                                  record: record,
                                                ),
                                          ),
                                      cells: [
                                        for (final key in fields)
                                          DataCell(
                                            ConstrainedBox(
                                              constraints:
                                                  const BoxConstraints(
                                                    maxWidth: 220,
                                                  ),
                                              child: Text(
                                                _cellText(record[key]),
                                                maxLines: 1,
                                                overflow:
                                                    TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(top: BorderSide(color: Color(0xffe4ebf4))),
              ),
              child: SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton.icon(
                  onPressed: running ? cancel : submit,
                  icon: Icon(
                    running ? Icons.stop_circle_outlined : Icons.search,
                  ),
                  label: Text(running ? '取消查询' : '查询${table.label}'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 表格单元格只展示标量摘要，嵌套结构留到行详情查看。
  static String _cellText(dynamic value) {
    if (value == null) return '';
    if (value is Map || value is List) {
      return jsonEncode(value);
    }
    return '$value';
  }
}

/// 空字符串、纯空白和空集合均视为未提供数据。
bool _hasValue(dynamic value) {
  if (value == null) return false;
  if (value is String) return value.trim().isNotEmpty;
  if (value is Iterable) return value.isNotEmpty;
  if (value is Map) return value.isNotEmpty;
  return true;
}

/// 单条记录的完整字段详情：中文标签优先，支持逐字段复制和整份 JSON 复制。
class RecordDetailsDialog extends StatelessWidget {
  final TableKind table;
  final Record record;
  const RecordDetailsDialog({
    super.key,
    required this.table,
    required this.record,
  });

  String _valueText(dynamic value) => value is Map || value is List
      ? const JsonEncoder.withIndent('  ').convert(value)
      : '$value';

  @override
  Widget build(BuildContext context) {
    final entries = record.entries
        .where((e) => _hasValue(e.value))
        .toList();
    return AlertDialog(
      title: Text('${table.label}记录详情 · ${entries.length} 项'),
      content: SizedBox(
        width: 560,
        height: 480,
        child: ListView(
          children: [
            for (final e in entries)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: const BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: Color(0xffedf1f6)),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${fieldLabels[e.key] ?? e.key}${fieldLabels.containsKey(e.key) ? ' · ${e.key}' : ''}',
                            style: const TextStyle(
                              color: Color(0xff8192a9),
                              fontSize: 11,
                            ),
                          ),
                        ),
                        SizedBox(
                          height: 25,
                          width: 30,
                          child: IconButton(
                            padding: EdgeInsets.zero,
                            tooltip: '复制 ${e.key}',
                            onPressed: () {
                              Clipboard.setData(
                                ClipboardData(text: _valueText(e.value)),
                              );
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('字段内容已复制'),
                                  duration: Duration(seconds: 1),
                                ),
                              );
                            },
                            icon: const Icon(Icons.copy_outlined, size: 14),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    SelectableText(
                      _valueText(e.value),
                      style: const TextStyle(
                        fontSize: 13,
                        height: 1.65,
                        color: Color(0xff1b2b42),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          icon: const Icon(Icons.copy_all_outlined, size: 17),
          label: const Text('复制 JSON'),
          onPressed: () {
            Clipboard.setData(
              ClipboardData(
                text: const JsonEncoder.withIndent('  ').convert(record),
              ),
            );
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('完整 JSON 已复制'),
                duration: Duration(seconds: 1),
              ),
            );
          },
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
