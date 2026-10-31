import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/contracts.dart';
import '../core/inter_result_decryption.dart';
import '../core/maintenance_controller.dart';
import 'query_sheet.dart';
import 'work_details.dart';

// 顶层入口仅接收数据快照，避免 isolate 捕获面板、控制器或日志对象。
({List<Record> rows, int failures}) _decryptInterResult(
  ({List<Record> rows, String key}) input,
) => InterResultDecryption.decryptRows(input.rows, input.key);

/// 数据查询面板：按物理表查询业务记录和接口结果，
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
  final interUrl = TextEditingController();
  final retCode = TextEditingController();
  final decryptKey = TextEditingController();
  List<Record>? originalRows;
  String? decryptionStatus;
  bool decrypting = false;
  int _decryptionGeneration = 0;
  int _queryGeneration = 0;

  void invalidateDecryption() {
    _decryptionGeneration++;
    decrypting = false;
  }

  TableKind table = TableKind.woinfo;
  DateTime? month;
  String? error;
  bool running = false;
  List<Record>? rows;
  @override
  void dispose() {
    _queryGeneration++;
    invalidateDecryption();
    caseNo.dispose();
    sysAccept.dispose();
    interUrl.dispose();
    retCode.dispose();
    decryptKey.clear();
    decryptKey.dispose();
    super.dispose();
  }

  String get monthText => month == null
      ? ''
      : '${month!.year}-${month!.month.toString().padLeft(2, '0')}';

  /// 先由业务契约本地校验，合法条件才发起只读查询，错误就地展示。
  Future<void> submit() async {
    if (running) return;
    invalidateDecryption();
    final generation = ++_queryGeneration;
    Record body;
    try {
      body = tableQueryBody(
        table,
        caseNo: caseNo.text,
        sysAccept: sysAccept.text,
        opMonth: monthText,
        interUrl: table == TableKind.interResult ? interUrl.text : '',
        retCode: table == TableKind.interResult ? retCode.text : '',
      );
    } on FormatException catch (e) {
      setState(() {
        error = e.message;
        rows = originalRows;
        decryptionStatus = null;
      });
      return;
    }
    setState(() {
      error = null;
      running = true;
      rows = null;
      originalRows = null;
      decryptionStatus = null;
    });
    try {
      final result = await widget.controller.queryTable(table, body);
      if (!mounted || generation != _queryGeneration) return;
      setState(() {
        running = false;
        rows = result;
        originalRows = result;
      });
      if (table == TableKind.interResult) decryptResults();
    } on FormatException catch (e) {
      if (!mounted || generation != _queryGeneration) return;
      setState(() {
        running = false;
        error = e.message;
      });
    } catch (_) {
      // 用户主动取消或其它代次失效，恢复表单但不报错。
      if (!mounted || generation != _queryGeneration) return;
      setState(() => running = false);
    }
  }

  void cancel() {
    _queryGeneration++;
    invalidateDecryption();
    widget.controller.cancel();
    setState(() => running = false);
  }

  Future<void> decryptResults() async {
    if (running ||
        decrypting ||
        originalRows == null ||
        table != TableKind.interResult) {
      return;
    }
    final source = originalRows!;
    final key = decryptKey.text;
    final generation = ++_decryptionGeneration;
    final encryptedCount = source.fold<int>(
      0,
      (count, record) =>
          count +
          InterResultDecryption.fields
              .where(
                (field) => InterResultDecryption.isEncrypted(record[field]),
              )
              .length,
    );
    setState(() {
      rows = source;
      decrypting = encryptedCount > 0 && key.isNotEmpty;
      decryptionStatus = encryptedCount == 0
          ? '结果中没有需要解密的 SM4 字段'
          : key.isEmpty
          ? '检测到 $encryptedCount 个加密字段，请输入密钥后解密'
          : '正在本地解密…';
    });
    if (!decrypting) return;
    try {
      final result = await compute(_decryptInterResult, (
        rows: source,
        key: key,
      ));
      if (!mounted || generation != _decryptionGeneration) return;
      setState(() {
        decrypting = false;
        rows = result.rows;
        decryptionStatus = result.failures == 0
            ? '已本地解密 $encryptedCount 个字段；复制详情将包含明文'
            : '已解密 ${encryptedCount - result.failures} 个字段，${result.failures} 个字段解密失败并保留密文，请核对密钥';
      });
    } catch (_) {
      if (!mounted || generation != _decryptionGeneration) return;
      // 不输出异常内容，避免意外携带密钥或业务明文。
      setState(() {
        decrypting = false;
        decryptionStatus = 'SM4 解密失败，请核对密钥（须为 16 个 UTF-8 字节）或密文完整性';
      });
    }
  }

  Future<void> pickMonth() async {
    final selected = await showDialog<DateTime>(
      context: context,
      builder: (_) => MonthPicker(
        current: month ?? DateTime(DateTime.now().year, DateTime.now().month),
      ),
    );
    if (selected != null && mounted) setState(() => month = selected);
  }

  Widget conditionField(
    String label,
    TextEditingController input, {
    String? hint,
    bool number = false,
  }) => Column(
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
    final fields =
        table == TableKind.interResult && rows != null && rows!.isNotEmpty
        ? ['caseNo', 'sysAccept', 'interUrl', 'retCode', 'retMsg', 'createTime']
        : rows == null || rows!.isEmpty
        ? <String>[]
        : rows!.first.keys.take(8).toList();
    return PopScope(
      canPop: !running,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          _queryGeneration++;
          invalidateDecryption();
        }
      },
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
                    DropdownButtonFormField<TableKind>(
                      initialValue: table,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: '查询表'),
                      items: [
                        for (final item in TableKind.values)
                          DropdownMenuItem(
                            value: item,
                            child: Text(
                              '${item.label}（${item.tableName}）',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                      ],
                      onChanged: running
                          ? null
                          : (v) => setState(() {
                              if (v == null) return;
                              _queryGeneration++;
                              invalidateDecryption();
                              table = v;
                              error = null;
                              rows = null;
                              originalRows = null;
                              decryptKey.clear();
                              decryptionStatus = null;
                            }),
                    ),
                    const SizedBox(height: 24),
                    conditionField('单据号', caseNo, hint: '输入完整单据号，可单独查询'),
                    const SizedBox(height: 18),
                    conditionField('受理流水', sysAccept, hint: '按受理流水查询需选择业务月份'),
                    if (table == TableKind.interResult) ...[
                      const SizedBox(height: 18),
                      conditionField(
                        '接口标识',
                        interUrl,
                        hint: '可选；签字识别填写 signcheck',
                      ),
                      const SizedBox(height: 18),
                      conditionField('返回码', retCode, hint: '可选，按原始返回码精确查询'),
                      const SizedBox(height: 18),
                      TextField(
                        controller: decryptKey,
                        enabled: !running,
                        obscureText: true,
                        autocorrect: false,
                        enableSuggestions: false,
                        enableIMEPersonalizedLearning: false,
                        decoration: const InputDecoration(
                          labelText: 'SM4 解密密钥',
                          hintText: '原始密钥，UTF-8 编码须为 16 字节',
                        ),
                        onChanged: (_) => setState(() {
                          invalidateDecryption();
                          rows = originalRows;
                          decryptionStatus = '密钥已变更，请重新解密';
                        }),
                        onSubmitted: (_) => decryptResults(),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        '密钥仅保留在当前面板，不发送到服务器、不保存。仅解密返回信息、返回详情和请求参数。',
                        style: TextStyle(fontSize: 12),
                      ),
                      Wrap(
                        spacing: 12,
                        children: [
                          TextButton(
                            onPressed:
                                running || decrypting || originalRows == null
                                ? null
                                : decryptResults,
                            child: const Text('本地解密'),
                          ),
                          TextButton(
                            onPressed: running
                                ? null
                                : () {
                                    invalidateDecryption();
                                    decryptKey.clear();
                                    setState(() {
                                      rows = originalRows;
                                      decryptionStatus = '已清除密钥并恢复原始结果';
                                    });
                                  },
                            child: const Text('清除密钥及明文'),
                          ),
                        ],
                      ),
                      if (decrypting) const LinearProgressIndicator(),
                      if (decryptionStatus != null) Text(decryptionStatus!),
                    ],
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
                                      onSelectChanged: (_) => showDialog<void>(
                                        context: context,
                                        builder: (_) => RecordDetailsDialog(
                                          table: table,
                                          record: record,
                                        ),
                                      ),
                                      cells: [
                                        for (final key in fields)
                                          DataCell(
                                            ConstrainedBox(
                                              constraints: const BoxConstraints(
                                                maxWidth: 220,
                                              ),
                                              child: Text(
                                                _cellText(record[key]),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
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
    final entries = record.entries.where((e) => _hasValue(e.value)).toList();
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
                  border: Border(bottom: BorderSide(color: Color(0xffedf1f6))),
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
