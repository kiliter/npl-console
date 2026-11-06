import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/contracts.dart';
import '../core/inter_result_decryption.dart';
import '../core/maintenance_controller.dart';
import 'large_text_view.dart';
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
      Text(
        label,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: Color(0xff0f1e36),
        ),
      ),
      const SizedBox(height: 6),
      TextField(
        controller: input,
        enabled: !running,
        keyboardType: number ? TextInputType.number : TextInputType.text,
        autocorrect: false,
        onSubmitted: (_) => submit(),
        style: const TextStyle(
          fontFamily: 'Menlo',
          fontSize: 13,
          color: Color(0xff0f1e36),
        ),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(
            fontFamily: '.AppleSystemUIFont',
            fontSize: 12,
            color: Color(0xff94a3b8),
          ),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 12,
          ),
        ),
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
          mainAxisSize: MainAxisSize.min,
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
                      Icons.table_view_rounded,
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
                              '数据查询',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                color: Color(0xff0f1e36),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xffeaf2ff),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                table.tableName,
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
                        Text(
                          '按表直查 · 当前 ${table.label}（${table.tableName}）',
                          style: const TextStyle(
                            color: Color(0xff64748b),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭数据查询',
                    onPressed: running ? null : () => Navigator.pop(context),
                    icon: const Icon(
                      Icons.close,
                      size: 18,
                      color: Color(0xff475569),
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              fit: FlexFit.loose,
              child: SingleChildScrollView(
                key: const ValueKey('table-query-panel'),
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xfff8fafd),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xffe4ecf6)),
                      ),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final wide = constraints.maxWidth >= 480;
                          final tableSelect = DropdownButtonFormField<TableKind>(
                            initialValue: table,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: '查询表',
                              fillColor: Colors.white,
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 11,
                              ),
                            ),
                            items: [
                              for (final item in TableKind.values)
                                DropdownMenuItem(
                                  value: item,
                                  child: Text(
                                    '${item.label}（${item.tableName}）',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
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
                          );
                          final monthSelect = Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              OutlinedButton.icon(
                                onPressed: running ? null : pickMonth,
                                icon: const Icon(
                                  Icons.calendar_month_outlined,
                                  size: 16,
                                  color: Color(0xff2563eb),
                                ),
                                label: Text(
                                  month == null ? '不限制月份' : monthText,
                                  style: TextStyle(
                                    fontFamily:
                                        month == null ? null : 'Menlo',
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: const Color(0xff0f1e36),
                                  ),
                                ),
                                style: OutlinedButton.styleFrom(
                                  backgroundColor: Colors.white,
                                  side: const BorderSide(
                                    color: Color(0xffdde6f1),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 14,
                                    horizontal: 12,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                              ),
                              if (month != null) ...[
                                const SizedBox(width: 4),
                                IconButton(
                                  tooltip: '清除月份条件',
                                  onPressed: running
                                      ? null
                                      : () => setState(() => month = null),
                                  icon: const Icon(Icons.close, size: 16),
                                ),
                              ],
                            ],
                          );
                          if (!wide) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                tableSelect,
                                const SizedBox(height: 12),
                                const Text(
                                  '业务月份',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xff0f1e36),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                monthSelect,
                              ],
                            );
                          }
                          return Row(
                            children: [
                              Expanded(child: tableSelect),
                              const SizedBox(width: 12),
                              monthSelect,
                            ],
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 14),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        if (constraints.maxWidth < 480) {
                          return Column(
                            children: [
                              conditionField(
                                '单据号',
                                caseNo,
                                hint: '输入完整单据号，可单独查询',
                              ),
                              const SizedBox(height: 12),
                              conditionField(
                                '受理流水',
                                sysAccept,
                                hint: '按受理流水查询需选择业务月份',
                              ),
                            ],
                          );
                        }
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: conditionField(
                                '单据号',
                                caseNo,
                                hint: '输入完整单据号，可单独查询',
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: conditionField(
                                '受理流水',
                                sysAccept,
                                hint: '按受理流水查询需选择业务月份',
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                    if (table == TableKind.interResult) ...[
                      const SizedBox(height: 12),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          if (constraints.maxWidth < 480) {
                            return Column(
                              children: [
                                conditionField(
                                  '接口标识',
                                  interUrl,
                                  hint: '可选；签字识别填写 signcheck',
                                ),
                                const SizedBox(height: 12),
                                conditionField(
                                  '返回码',
                                  retCode,
                                  hint: '可选，按原始返回码精确查询',
                                ),
                              ],
                            );
                          }
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: conditionField(
                                  '接口标识',
                                  interUrl,
                                  hint: '可选；签字识别填写 signcheck',
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: conditionField(
                                  '返回码',
                                  retCode,
                                  hint: '可选，按原始返回码精确查询',
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xfff8fafd),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xffdde6f1)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            TextField(
                              controller: decryptKey,
                              enabled: !running,
                              obscureText: true,
                              autocorrect: false,
                              enableSuggestions: false,
                              enableIMEPersonalizedLearning: false,
                              style: const TextStyle(
                                fontFamily: 'Menlo',
                                fontSize: 13,
                              ),
                              decoration: const InputDecoration(
                                fillColor: Colors.white,
                                labelText: 'SM4 解密密钥',
                                hintText: '原始密钥，UTF-8 编码须为 16 字节',
                                isDense: true,
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 11,
                                ),
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
                              style: TextStyle(
                                fontSize: 11,
                                color: Color(0xff64748b),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Wrap(
                              spacing: 8,
                              children: [
                                TextButton(
                                  onPressed:
                                      running ||
                                          decrypting ||
                                          originalRows == null
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
                                            decryptionStatus =
                                                '已清除密钥并恢复原始结果';
                                          });
                                        },
                                  child: const Text('清除密钥及明文'),
                                ),
                              ],
                            ),
                            if (decrypting) const LinearProgressIndicator(),
                            if (decryptionStatus != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  decryptionStatus!,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xff0d8a6a),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    const Row(
                      children: [
                        Icon(
                          Icons.info_outline_rounded,
                          size: 13,
                          color: Color(0xff94a3b8),
                        ),
                        SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            '至少填写一个条件；单据号可单独查询，受理流水需搭配业务月份。',
                            style: TextStyle(
                              fontSize: 11,
                              color: Color(0xff64748b),
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (error != null)
                      Container(
                        margin: const EdgeInsets.only(top: 12),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 9,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xfffef2f2),
                          borderRadius: BorderRadius.circular(9),
                          border: Border.all(color: const Color(0xfffecaca)),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.error_outline_rounded,
                              size: 16,
                              color: Color(0xffdc2626),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                error!,
                                key: const ValueKey('table-query-error'),
                                style: const TextStyle(
                                  color: Color(0xffb91c1c),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (running) ...[
                      const SizedBox(height: 16),
                      const LinearProgressIndicator(),
                      const SizedBox(height: 10),
                      Text(
                        widget.controller.message,
                        style: const TextStyle(fontSize: 12, height: 1.6),
                      ),
                    ],
                    if (rows != null) ...[
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: rows!.isEmpty
                                  ? const Color(0xff94a3b8)
                                  : const Color(0xff10b981),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              rows!.isEmpty
                                  ? '未查询到记录'
                                  : '查询结果 · ${rows!.length} 条记录${rows!.first.keys.length > 8 ? ' · 表格仅展示前 8 列，点击行查看完整字段' : ''}',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: Color(0xff0f1e36),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      if (rows!.isNotEmpty) _resultTable(fields),
                    ],
                  ],
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
              decoration: const BoxDecoration(
                color: Color(0xfff5f8fc),
                border: Border(top: BorderSide(color: Color(0xffdde6f1))),
              ),
              child: SizedBox(
                width: double.infinity,
                height: 42,
                child: FilledButton.icon(
                  onPressed: running ? cancel : submit,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xff2563eb),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    textStyle: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  icon: Icon(
                    running ? Icons.stop_circle_outlined : Icons.search,
                    size: 16,
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

  /// 结果表格按（结果列表、表类型）缓存同一个组件实例。
  /// 输入密钥、选择月份等操作会重建整个面板，返回相同实例时 Flutter 直接跳过
  /// 表格子树，不再为每行每列重新序列化单元格。
  Object? _tableKey;
  Widget? _table;
  Widget _resultTable(List<String> fields) {
    final cacheKey = (rows, table);
    if (_tableKey == cacheKey && _table != null) return _table!;
    _tableKey = cacheKey;
    return _table = ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xffe4ebf4)),
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
                    builder: (_) =>
                        RecordDetailsDialog(table: table, record: record),
                  ),
                  cells: [
                    for (final key in fields)
                      DataCell(
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 220),
                          child: Text(
                            _cellText(record[key]),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                  ],
                ),
            ],
          ),
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
    // 每个字段只格式化一次，展示与复制共用。
    final texts = {for (final e in entries) e.key: _valueText(e.value)};
    const style = TextStyle(
      fontSize: 13,
      height: 1.65,
      color: Color(0xff1b2b42),
    );
    return AlertDialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xffdde6f1)),
      ),
      title: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: const Color(0xffeaf2ff),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xffbfdbfe)),
            ),
            child: const Icon(
              Icons.article_outlined,
              size: 16,
              color: Color(0xff2563eb),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${table.label}记录详情 · ${entries.length} 项',
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: Color(0xff0f1e36),
              ),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 600,
        height: 480,
        child: ListView(
          children: [
            for (final e in entries)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xfff8fafd),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xffe4ecf6)),
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
                              color: Color(0xff64748b),
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
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
                                ClipboardData(text: texts[e.key]!),
                              );
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('字段内容已复制'),
                                  duration: Duration(seconds: 1),
                                ),
                              );
                            },
                            icon: const Icon(
                              Icons.copy_outlined,
                              size: 14,
                              color: Color(0xff475569),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    texts[e.key]!.length > largeFieldThreshold
                        ? LargeFieldText(text: texts[e.key]!, style: style)
                        : SelectableText(texts[e.key]!, style: style),
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
