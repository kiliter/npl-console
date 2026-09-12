import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/contracts.dart';
import '../core/maintenance_controller.dart';

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
  final prefs = await SharedPreferences.getInstance();
  final saved = await prefs.setString(
    _historyKey,
    jsonEncode(history.take(30).map((q) => q.toJson()).toList()),
  );
  if (!saved) throw StateError('本地存储未完成写入');
}

/// 进入查询面板时读取历史，不发起网络请求。
Future<List<QueryDraft>> loadQueryHistory() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_historyKey);
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
      builder: (_) => _MonthPicker(current: current),
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
    icon: const Icon(Icons.calendar_month_outlined, size: 18),
    label: Text(q.month(last ? q.end : q.start)),
    style: OutlinedButton.styleFrom(
      padding: const EdgeInsets.symmetric(vertical: 19, horizontal: 12),
    ),
  );
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final c = widget.controller, running = c.querying && submitted;
      return PopScope(
        canPop: !running,
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 12, 8),
                child: Row(
                  children: [
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '查找工单',
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          SizedBox(height: 6),
                          Text(
                            '一次受理，完整关联',
                            style: TextStyle(
                              color: Color(0xff8192a9),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭查询',
                      onPressed: running ? null : () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  key: const ValueKey('mobile-query-panel'),
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SegmentedButton<String>(
                        segments: queryLabels.entries
                            .map(
                              (e) => ButtonSegment(
                                value: e.key,
                                label: Text(
                                  e.value,
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                            )
                            .toList(),
                        selected: {q.field},
                        showSelectedIcon: false,
                        onSelectionChanged: running
                            ? null
                            : (v) => setState(() {
                                q.field = v.single;
                                error = null;
                              }),
                      ),
                      const SizedBox(height: 25),
                      Text(
                        queryLabels[q.field]!,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 10),
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
                        style: const TextStyle(fontSize: 20),
                        decoration: InputDecoration(
                          hintText: q.field == 'phoneNo'
                              ? '输入 11 位手机号码'
                              : '输入完整${queryLabels[q.field]}',
                          prefixIcon: const Icon(Icons.search),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        q.field == 'caseNo'
                            ? '根据单据号定位工单，无需额外选择月份。'
                            : '按号码与业务月份组合查询。',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xff8192a9),
                        ),
                      ),
                      if (q.field != 'caseNo') ...[
                        const SizedBox(height: 28),
                        Row(
                          children: [
                            const Expanded(
                              child: Text(
                                '业务月份',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                            ),
                            SegmentedButton<bool>(
                              segments: const [
                                ButtonSegment(value: false, label: Text('单月')),
                                ButtonSegment(value: true, label: Text('范围')),
                              ],
                              selected: {q.range},
                              showSelectedIcon: false,
                              onSelectionChanged: running
                                  ? null
                                  : (v) => setState(() => q.range = v.single),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(child: monthButton(false)),
                            if (q.range) ...[
                              const Padding(
                                padding: EdgeInsets.all(8),
                                child: Text('—'),
                              ),
                              Expanded(child: monthButton(true)),
                            ],
                          ],
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          children: [
                            for (final n in [1, 3, 6])
                              ActionChip(
                                label: Text(n == 1 ? '本月' : '最近 $n 个月'),
                                onPressed: running
                                    ? null
                                    : () => setState(() {
                                        final now = DateTime.now();
                                        q.end = DateTime(now.year, now.month);
                                        q.start = DateTime(
                                          now.year,
                                          now.month - n + 1,
                                        );
                                        q.range = n > 1;
                                      }),
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          q.range
                              ? '逐月查询，可随时取消 · 首尾合计最多 12 个月'
                              : '仅查询选中月份，减少等待',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xff8192a9),
                          ),
                        ),
                      ],
                      if (error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 18),
                          child: Text(
                            error!,
                            key: const ValueKey('query-error'),
                            style: const TextStyle(
                              color: Colors.red,
                              height: 1.5,
                            ),
                          ),
                        ),
                      if (running) ...[
                        const SizedBox(height: 24),
                        LinearProgressIndicator(
                          value: c.total == 0 ? null : c.completed / c.total,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '${c.message}\n已找到 ${c.works.length} 份工单',
                          style: const TextStyle(height: 1.7),
                        ),
                      ],
                      if (widget.history.isNotEmpty && !running) ...[
                        const SizedBox(height: 28),
                        Row(
                          children: [
                            const Expanded(
                              child: Text(
                                '最近 30 次查询',
                                style: TextStyle(color: Color(0xff8192a9)),
                              ),
                            ),
                            TextButton(
                              onPressed: () async {
                                setState(widget.history.clear);
                                await persistHistory();
                              },
                              child: const Text('清空'),
                            ),
                          ],
                        ),
                        for (final h in widget.history)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.history, size: 18),
                            title: Text(h.value),
                            subtitle: Text(
                              h.field == 'caseNo'
                                  ? '单据号'
                                  : '${queryLabels[h.field]} · ${h.month(h.start)}${h.range ? ' — ${h.month(h.end)}' : ''}',
                            ),
                            onTap: () => setState(() {
                              error = null;
                              q.field = h.field;
                              q.start = h.start;
                              q.end = h.end;
                              q.range = h.range;
                              input.text = h.value;
                            }),
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
                    onPressed: running
                        ? () {
                            c.cancel();
                            Navigator.pop(context, true);
                          }
                        : submit,
                    icon: Icon(
                      running ? Icons.stop_circle_outlined : Icons.search,
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
class _MonthPicker extends StatefulWidget {
  final DateTime current;
  const _MonthPicker({required this.current});
  @override
  State<_MonthPicker> createState() => _MonthPickerState();
}

class _MonthPickerState extends State<_MonthPicker> {
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
