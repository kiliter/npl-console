import 'dart:convert';
import 'package:flutter/material.dart';
import '../core/local_config.dart';
import '../core/contracts.dart';
import '../core/maintenance_controller.dart';
import 'listenable_selector.dart';

/// 查询条件用于回填历史；本地只保存条件，不包含密钥、JWT 或接口响应。
class QueryDraft {
  String field = 'phoneNo', value = '';
  DateTime start = DateTime(DateTime.now().year, DateTime.now().month);
  DateTime end = DateTime(DateTime.now().year, DateTime.now().month);
  bool range = false;
  String month(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}';
  String get label =>
      value.isEmpty ? '手机号、受理流水或单据号' : '${queryLabels[field]} · $value';

  /// 保留查询方式、号码、月份和范围开关，重启后恢复原条件。
  Map<String, dynamic> toJson() => {
    'field': field,
    'value': value,
    'start': month(start),
    'end': month(end),
    'range': range,
  };
  static QueryDraft fromJson(Map<String, dynamic> data) => QueryDraft()
    ..field = data['field'] as String
    ..value = data['value'] as String
    ..start = DateTime.parse('${data['start']}-01')
    ..end = DateTime.parse('${data['end']}-01')
    ..range = data['range'] as bool;

  QueryDraft copy() => QueryDraft()
    ..field = field
    ..value = value
    ..start = start
    ..end = end
    ..range = range;
}

const _historyKey = 'query_history_v1';

/// 最近三十次合法提交按时间倒序保存，不因失败或取消丢失查询条件。
Future<void> saveQueryHistory(List<QueryDraft> history) async {
  final prefs = const LocalConfig();
  final saved = await prefs.setString(
    _historyKey,
    jsonEncode(history.take(30).map((q) => q.toJson()).toList()),
  );
  if (!saved) throw StateError('本地存储未完成写入');
}

/// 进入查询面板时读取历史，不发起网络请求。
Future<List<QueryDraft>> loadQueryHistory() async {
  final prefs = const LocalConfig();
  final raw = await prefs.getString(_historyKey);
  if (raw == null) return [];
  return (jsonDecode(raw) as List)
      .take(30)
      .map(
        (item) => QueryDraft.fromJson(Map<String, dynamic>.from(item as Map)),
      )
      .toList();
}

const queryLabels = {'phoneNo': '手机号码', 'sysAccept': '受理流水', 'caseNo': '单据号'};

/// 独立搜索面板：输入滚动、底部提交固定；月份选择不要求手输格式。
class QuerySheet extends StatefulWidget {
  final MaintenanceController controller;
  final QueryDraft draft;
  final List<QueryDraft> history;
  const QuerySheet({
    super.key,
    required this.controller,
    required this.draft,
    required this.history,
  });
  @override
  State<QuerySheet> createState() => _QuerySheetState();
}

class _QuerySheetState extends State<QuerySheet> {
  late final input = TextEditingController(text: widget.draft.value);
  QueryDraft get q => widget.draft;
  String? error;
  bool submitted = false;
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  /// 复用业务契约校验，错误就地展示，合法条件才发起只读查询。
  Future<void> submit() async {
    if (submitted) return;
    q.value = input.text.trim();
    try {
      if (q.field == 'phoneNo' && !RegExp(r'^\d{11}$').hasMatch(q.value)) {
        throw const FormatException('请输入 11 位手机号码');
      }
      queryBodies(q.field, q.value, q.month(q.start), q.month(q.end), q.range);
    } on FormatException catch (e) {
      setState(() => error = e.message);
      return;
    }
    setState(() {
      error = null;
      submitted = true;
    });
    widget.history.insert(0, q.copy());
    if (widget.history.length > 30) {
      widget.history.removeRange(30, widget.history.length);
    }
    await persistHistory();
    if (!mounted) return;
    await widget.controller.search(
      q.field,
      q.value,
      q.month(q.start),
      q.month(q.end),
      q.range,
    );
    if (!mounted) return;
    if (widget.controller.error && widget.controller.works.isEmpty) {
      setState(() {
        submitted = false;
        error = widget.controller.message;
      });
      return;
    }
    Navigator.pop(context, true);
  }

  /// 历史写入失败仅提示，不影响工单查询；清空也同步到本机存储。
  Future<void> persistHistory() async {
    try {
      await saveQueryHistory(widget.history);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('搜索历史保存失败，本次更改可能无法在重启后保留。')));
    }
  }

  Future<void> pickMonth(bool last) async {
    final current = last ? q.end : q.start;
    final selected = await showDialog<DateTime>(
      context: context,
      builder: (_) => MonthPicker(current: current),
    );
    if (selected != null && mounted) {
      setState(() {
        if (last) {
          q.end = selected;
        } else {
          q.start = selected;
        }
      });
    }
  }

  Widget monthButton(bool last) => OutlinedButton.icon(
    onPressed: () => pickMonth(last),
    icon: const Icon(
      Icons.calendar_month_outlined,
      size: 16,
      color: Color(0xff2563eb),
    ),
    label: Text(
      q.month(last ? q.end : q.start),
      style: const TextStyle(
        fontFamily: 'Menlo',
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: Color(0xff0f1e36),
      ),
    ),
    style: OutlinedButton.styleFrom(
      backgroundColor: const Color(0xfff8fafd),
      side: const BorderSide(color: Color(0xffdde6f1)),
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
    ),
  );

  static const _fieldIcons = {
    'phoneNo': Icons.phone_iphone_outlined,
    'sysAccept': Icons.receipt_long_outlined,
    'caseNo': Icons.badge_outlined,
  };

  Widget _fieldTypeSwitch(bool running) => Container(
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      color: const Color(0xfff1f5fb),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: const Color(0xffdde6f1)),
    ),
    child: Row(
      children: [
        for (final e in queryLabels.entries)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1.5),
              child: Material(
                color: q.field == e.key ? Colors.white : Colors.transparent,
                borderRadius: BorderRadius.circular(7),
                elevation: q.field == e.key ? 1 : 0,
                shadowColor: const Color(0x1f0f1e36),
                child: InkWell(
                  borderRadius: BorderRadius.circular(7),
                  onTap: running
                      ? null
                      : () => setState(() {
                          q.field = e.key;
                          error = null;
                        }),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _fieldIcons[e.key] ?? Icons.search,
                          size: 15,
                          color: q.field == e.key
                              ? const Color(0xff2563eb)
                              : const Color(0xff7f91ab),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          e.value,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: q.field == e.key
                                ? FontWeight.w700
                                : FontWeight.w600,
                            color: q.field == e.key
                                ? const Color(0xff2563eb)
                                : const Color(0xff4a5d78),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );

  Widget _rangeSwitch(bool running) => Container(
    padding: const EdgeInsets.all(2.5),
    decoration: BoxDecoration(
      color: const Color(0xfff1f5fb),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: const Color(0xffdde6f1)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final item in const [(false, '单月'), (true, '范围')])
          Material(
            color: q.range == item.$1 ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            elevation: q.range == item.$1 ? 1 : 0,
            shadowColor: const Color(0x1f0f1e36),
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: running ? null : () => setState(() => q.range = item.$1),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 5,
                ),
                child: Text(
                  item.$2,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: q.range == item.$1
                        ? FontWeight.w700
                        : FontWeight.w600,
                    color: q.range == item.$1
                        ? const Color(0xff2563eb)
                        : const Color(0xff4a5d78),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );

  /// 控制器任何变化（接口记录、图片加载等）都会通知；面板只在本次提交的查询
  /// 进行中关心进度与消息，其余时间不随控制器重建。
  Object? _progress() {
    final c = widget.controller;
    if (!(c.querying && submitted)) return null;
    return (c.total, c.completed, c.message, c.works.length);
  }

  @override
  Widget build(BuildContext context) => ListenableSelector<Object?>(
    listenable: widget.controller,
    selector: _progress,
    builder: (context, _) {
      final c = widget.controller, running = c.querying && submitted;
      return PopScope(
        canPop: !running,
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(20, 14, 12, 12),
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
                        border: Border.all(color: const Color(0xffbfd6ff)),
                      ),
                      child: const Icon(
                        Icons.manage_search_rounded,
                        size: 19,
                        color: Color(0xff2563eb),
                      ),
                    ),
                    const SizedBox(width: 11),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '查找工单',
                            style: TextStyle(
                              fontSize: 16.5,
                              fontWeight: FontWeight.w700,
                              color: Color(0xff0f1e36),
                            ),
                          ),
                          SizedBox(height: 2),
                          Text(
                            '一次受理，完整关联 · 支持单月与跨月范围检索',
                            style: TextStyle(
                              color: Color(0xff7f91ab),
                              fontSize: 11.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭查询',
                      onPressed: running ? null : () => Navigator.pop(context),
                      icon: const Icon(Icons.close, size: 20),
                    ),
                  ],
                ),
              ),
              Flexible(
                fit: FlexFit.loose,
                child: SingleChildScrollView(
                  key: const ValueKey('mobile-query-panel'),
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _fieldTypeSwitch(running),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Text(
                            queryLabels[q.field]!,
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: Color(0xff0f1e36),
                            ),
                          ),
                          const Spacer(),
                          Text(
                            q.field == 'caseNo'
                                ? '单据号无需选择月份'
                                : '按号码与业务月份组合查询',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xff7f91ab),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        key: const ValueKey('query-value'),
                        controller: input,
                        enabled: !running,
                        keyboardType: q.field == 'phoneNo'
                            ? TextInputType.phone
                            : TextInputType.text,
                        textInputAction: TextInputAction.search,
                        autocorrect: false,
                        onSubmitted: (_) => submit(),
                        style: const TextStyle(
                          fontFamily: 'Menlo',
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Color(0xff0f1e36),
                        ),
                        decoration: InputDecoration(
                          hintText: q.field == 'phoneNo'
                              ? '输入 11 位手机号码'
                              : '输入完整${queryLabels[q.field]}',
                          prefixIcon: const Icon(
                            Icons.search,
                            size: 18,
                            color: Color(0xff2563eb),
                          ),
                          fillColor: const Color(0xfff8fafd),
                        ),
                      ),
                      if (q.field != 'caseNo') ...[
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xfff8fafd),
                            borderRadius: BorderRadius.circular(11),
                            border: Border.all(color: const Color(0xffdde6f1)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  const Expanded(
                                    child: Text(
                                      '业务月份',
                                      style: TextStyle(
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w700,
                                        color: Color(0xff0f1e36),
                                      ),
                                    ),
                                  ),
                                  _rangeSwitch(running),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  Expanded(child: monthButton(false)),
                                  if (q.range) ...[
                                    const Padding(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: 8,
                                      ),
                                      child: Text(
                                        '→',
                                        style: TextStyle(
                                          color: Color(0xff7f91ab),
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    Expanded(child: monthButton(true)),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 9),
                              Row(
                                children: [
                                  Wrap(
                                    spacing: 6,
                                    children: [
                                      for (final n in [1, 3, 6])
                                        ActionChip(
                                          visualDensity: VisualDensity.compact,
                                          backgroundColor: Colors.white,
                                          side: const BorderSide(
                                            color: Color(0xffdde6f1),
                                          ),
                                          label: Text(
                                            n == 1 ? '本月' : '最近 $n 个月',
                                            style: const TextStyle(
                                              fontSize: 11.5,
                                              fontWeight: FontWeight.w600,
                                              color: Color(0xff4a5d78),
                                            ),
                                          ),
                                          onPressed: running
                                              ? null
                                              : () => setState(() {
                                                  final now = DateTime.now();
                                                  q.end = DateTime(
                                                    now.year,
                                                    now.month,
                                                  );
                                                  q.start = DateTime(
                                                    now.year,
                                                    now.month - n + 1,
                                                  );
                                                  q.range = n > 1;
                                                }),
                                        ),
                                    ],
                                  ),
                                  const Spacer(),
                                  Flexible(
                                    child: Text(
                                      q.range ? '最多跨 12 个月' : '仅查单月',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: Color(0xff7f91ab),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                      if (error != null)
                        Container(
                          margin: const EdgeInsets.only(top: 12),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xfffef2f2),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0xfffecaca)),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.error_outline,
                                size: 16,
                                color: Color(0xffdc2626),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  error!,
                                  key: const ValueKey('query-error'),
                                  style: const TextStyle(
                                    color: Color(0xffdc2626),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (running) ...[
                        const SizedBox(height: 16),
                        LinearProgressIndicator(
                          value: c.total == 0 ? null : c.completed / c.total,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '${c.message} · 已找到 ${c.works.length} 份工单',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xff4a5d78),
                          ),
                        ),
                      ],
                      if (widget.history.isNotEmpty && !running) ...[
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            const Icon(
                              Icons.history,
                              size: 14,
                              color: Color(0xff7f91ab),
                            ),
                            const SizedBox(width: 5),
                            Expanded(
                              child: Text(
                                '最近查询记录 (${widget.history.length})',
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xff7f91ab),
                                ),
                              ),
                            ),
                            InkWell(
                              borderRadius: BorderRadius.circular(6),
                              onTap: () async {
                                setState(widget.history.clear);
                                await persistHistory();
                              },
                              child: const Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                child: Text(
                                  '清空',
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xff2563eb),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        for (final h in widget.history)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Material(
                              color: const Color(0xfff8fafd),
                              borderRadius: BorderRadius.circular(9),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(9),
                                onTap: () => setState(() {
                                  error = null;
                                  q.field = h.field;
                                  q.start = h.start;
                                  q.end = h.end;
                                  q.range = h.range;
                                  input.text = h.value;
                                }),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 11,
                                    vertical: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(9),
                                    border: Border.all(
                                      color: const Color(0xffe4ecf6),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: const Color(0xffeaf2ff),
                                          borderRadius: BorderRadius.circular(
                                            5,
                                          ),
                                        ),
                                        child: Text(
                                          queryLabels[h.field] ?? h.field,
                                          style: const TextStyle(
                                            fontSize: 10.5,
                                            fontWeight: FontWeight.w600,
                                            color: Color(0xff2563eb),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          h.value,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontFamily: 'Menlo',
                                            fontSize: 12.5,
                                            fontWeight: FontWeight.w600,
                                            color: Color(0xff0f1e36),
                                          ),
                                        ),
                                      ),
                                      if (h.field != 'caseNo') ...[
                                        const SizedBox(width: 8),
                                        Text(
                                          '${h.month(h.start)}${h.range ? ' → ${h.month(h.end)}' : ''}',
                                          style: const TextStyle(
                                            fontFamily: 'Menlo',
                                            fontSize: 11,
                                            color: Color(0xff7f91ab),
                                          ),
                                        ),
                                      ],
                                      const SizedBox(width: 6),
                                      const Icon(
                                        Icons.north_west_rounded,
                                        size: 14,
                                        color: Color(0xff7f91ab),
                                      ),
                                    ],
                                  ),
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
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
                decoration: const BoxDecoration(
                  color: Color(0xfff5f8fc),
                  border: Border(top: BorderSide(color: Color(0xffdde6f1))),
                ),
                child: SizedBox(
                  width: double.infinity,
                  height: 44,
                  child: FilledButton.icon(
                    onPressed: running
                        ? () {
                            c.cancel();
                            Navigator.pop(context, true);
                          }
                        : submit,
                    icon: Icon(
                      running ? Icons.stop_circle_outlined : Icons.search,
                      size: 18,
                    ),
                    label: Text(running ? '取消查询，保留已完成结果' : '查询工单'),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// 年份可切换的月份网格，手机单手选择，无日期粒度的多余操作。
/// 查询面板与数据查询面板共用。
class MonthPicker extends StatefulWidget {
  final DateTime current;
  const MonthPicker({super.key, required this.current});
  @override
  State<MonthPicker> createState() => _MonthPickerState();
}

class _MonthPickerState extends State<MonthPicker> {
  late int year = widget.current.year;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Row(
      children: [
        IconButton(
          tooltip: '上一年',
          onPressed: () => setState(() => year--),
          icon: const Icon(Icons.chevron_left),
        ),
        Expanded(child: Text('$year 年', textAlign: TextAlign.center)),
        IconButton(
          tooltip: '下一年',
          onPressed: () => setState(() => year++),
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    ),
    content: SizedBox(
      width: 320,
      child: GridView.count(
        shrinkWrap: true,
        crossAxisCount: 3,
        childAspectRatio: 1.6,
        children: [
          for (var m = 1; m <= 12; m++)
            TextButton(
              onPressed: () => Navigator.pop(context, DateTime(year, m)),
              child: Text(
                '$m 月',
                style: TextStyle(
                  fontWeight:
                      year == widget.current.year && m == widget.current.month
                      ? FontWeight.bold
                      : FontWeight.normal,
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
