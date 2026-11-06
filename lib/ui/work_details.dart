import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/breakpoints.dart';
import '../core/contracts.dart';
import 'large_text_view.dart';

/// WO_INFO 实际列对应的 JSON 属性，依据用户提供的 WO_INFO202610 建表语句，共 62 列。
/// 详情与 JSON 导出使用同一列表，排除 Bean 的辅助属性和关联对象。
const woInfoColumns = <String>{
  'sysAccept',
  'loginNo',
  'loginName',
  'groupId',
  'groupName',
  'areaCode',
  'areaName',
  'regionCode',
  'regionName',
  'opCode',
  'opName',
  'phoneNo',
  'sts',
  'stsDesc',
  'opTime',
  'tenantId',
  'provinceCode',
  'provinceName',
  'picSeq',
  'isSign',
  'isPhoto',
  'isRead',
  'isPreControl',
  'isAgainCreate',
  'signNum',
  'cardNum',
  'photoNum',
  'cdFlag',
  'ext1',
  'ext2',
  'ext3',
  'ext4',
  'ext5',
  'ext6',
  'ext7',
  'ext8',
  'ext9',
  'ext10',
  'chnlName',
  'cmdCode',
  'chnlCode',
  'fileName',
  'innerJson',
  'signFlag',
  'woType',
  'riskFlagName',
  'isModelGood',
  'riskFlag',
  'modelGoodType',
  'modelGoodTypeName',
  'customMergeList',
  'addprtFlag',
  'addprtTime',
  'addprtDesc',
  'cdTime',
  'cdDesc',
  'rejectionFlag',
  'rejectionTime',
  'rejectionDesc',
  'createTime',
  'caseNo',
  'opMonth',
};

/// 详情与导出隐藏非表字段及空值；EXT1～EXT10 即使未返回也保留。
/// 数字 0、布尔 false 均属于有效值，不按空值过滤。
Record woInfoFields(Record record) => {
  for (final key in woInfoColumns)
    if (RegExp(r'^ext(?:[1-9]|10)$').hasMatch(key) ||
        _hasFieldValue(record[key]))
      key: record[key],
};

/// 空字符串、纯空白和空集合均视为未提供数据。
bool _hasFieldValue(dynamic value) {
  if (value == null) return false;
  if (value is String) return value.trim().isNotEmpty;
  if (value is Iterable) return value.isNotEmpty;
  if (value is Map) return value.isNotEmpty;
  return true;
}

const fieldLabels = {
  'interUrl': '接口标识',
  'retCode': '返回码',
  'retMsg': '返回信息',
  'retDetail': '返回详情',
  'paramInt': '请求参数',
  'createTime': '创建时间',
  'endTime': '结束时间',
  'interName': '接口名称',
  'caseNo': '单据号',
  'sysAccept': '受理流水',
  'phoneNo': '手机号码',
  'opMonth': '业务月份',
  'opCode': '业务编码',
  'opName': '业务名称',
  'opTime': '受理时间',
  'sts': '状态编码',
  'stsDesc': '单据状态',
  'loginNo': '受理工号',
  'loginName': '受理人员',
  'groupId': '营业厅编码',
  'groupName': '营业厅名称',
  'tenantId': '租户标识',
  'cmdCode': '渠道编码',
  'provinceCode': '省份编码',
  'provinceName': '省份',
  'regionCode': '地市编码',
  'regionName': '地市',
  'areaCode': '区县编码',
  'areaName': '区县',
  'isSign': '是否签字',
  'isPhoto': '是否拍照',
  'isRead': '是否阅读',
  'signNum': '签字数量',
  'photoNum': '图片数量',
  'cardNum': '证件图片数',
  'picSeq': '受理流水',
  'isPreControl': '是否预控',
  'isAgainCreate': '是否重新生成',
  'cdFlag': '处理标记',
  'fileName': '文件路径',
  'ext7': '归档索引',
  'ext8': '加密标识',
};
const fieldGroups = {
  '单据与业务': [
    'caseNo',
    'sysAccept',
    'phoneNo',
    'opMonth',
    'opCode',
    'opName',
    'opTime',
    'sts',
    'stsDesc',
  ],
  '受理与渠道': [
    'loginNo',
    'loginName',
    'groupId',
    'groupName',
    'tenantId',
    'cmdCode',
  ],
  '归属与地区': [
    'provinceCode',
    'provinceName',
    'regionCode',
    'regionName',
    'areaCode',
    'areaName',
  ],
  '签署与影像': [
    'isSign',
    'isRead',
    'isPhoto',
    'signNum',
    'photoNum',
    'cardNum',
    'picSeq',
    'isPreControl',
    'isAgainCreate',
    'cdFlag',
  ],
};

/// 展示有值的 WO_INFO 表字段和全部 EXT 列，长值保持完整。
class WorkDetails extends StatefulWidget {
  final Record record;
  final VoidCallback onDownload;
  const WorkDetails({
    super.key,
    required this.record,
    required this.onDownload,
  });
  @override
  State<WorkDetails> createState() => _WorkDetailsState();
}

class _WorkDetailsState extends State<WorkDetails> {
  String filter = '';
  bool grouped = true;
  final collapsed = <String>{};
  final search = TextEditingController();
  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  String value(dynamic v) => v == null
      ? '未提供'
      : v is Map || v is List
      ? const JsonEncoder.withIndent('  ').convert(v)
      : '$v';

  /// 按工单记录缓存字段列表、展示文本与小写搜索文本。
  /// 搜索框每输入一个字符都会重建，不缓存时每次都要重新格式化 innerJson 等长 JSON。
  Record? _record;
  List<MapEntry<String, dynamic>> _entries = const [];
  final _texts = <String, String>{}, _searchTexts = <String, String>{};

  void _prepare() {
    if (identical(_record, widget.record)) return;
    _record = widget.record;
    _entries = woInfoFields(widget.record).entries.toList();
    _texts.clear();
    _searchTexts.clear();
    for (final e in _entries) {
      final text = _texts[e.key] = value(e.value);
      _searchTexts[e.key] = '${fieldLabels[e.key]} ${e.key} $text'
          .toLowerCase();
    }
  }

  /// 顶部四宫格摘要卡片（仅未输入筛选词时显示），快速呈现业务月份、签署、受理工号与归档存储。
  Widget _kpiStrip() => LayoutBuilder(
    builder: (context, size) {
      final r = widget.record;
      final cards = [
        _kpiCard(
          '业务月份 (opMonth)',
          '${r['opMonth'] ?? '—'}',
          '受理时间：${r['opTime'] ?? '—'}',
          Icons.calendar_today_outlined,
          const Color(0xff2563eb),
          const Color(0xffeaf2ff),
        ),
        _kpiCard(
          '电子签署与实名状态',
          '✓ 已签字(${r['signNum'] ?? 1}) · 已拍照(${r['photoNum'] ?? 0})',
          '证件核验：${r['cardNum'] ?? 0} 份 · 阅读：${r['isRead'] ?? '1'}',
          Icons.verified_user_outlined,
          const Color(0xff0d8a6a),
          const Color(0xffe6f7f2),
          primaryColor: const Color(0xff0d8a6a),
        ),
        _kpiCard(
          '受理员工号与渠道',
          '${r['loginNo'] ?? '—'} · ${r['chnlName'] ?? r['cmdCode'] ?? '实体渠道'}',
          '${r['groupName'] ?? '营业厅渠道'}',
          Icons.badge_outlined,
          const Color(0xff7c3aed),
          const Color(0xfff3eeff),
        ),
        _kpiCard(
          'OBS 归档索引 (ext7 / ext8)',
          '${r['ext7'] ?? 'OBS'} (ext8=${r['ext8'] ?? '0'})',
          '省份：${r['provinceName'] ?? r['provinceCode'] ?? '—'} · 地市：${r['regionName'] ?? r['regionCode'] ?? '—'}',
          Icons.inventory_2_outlined,
          const Color(0xffc66908),
          const Color(0xfffef5e7),
        ),
      ];
      final cols = size.maxWidth >= 820
          ? 4
          : size.maxWidth >= 460
          ? 2
          : 1;
      const gap = 10.0;
      final w = (size.maxWidth - (cols - 1) * gap) / cols;
      return Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 12),
        child: Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [for (final c in cards) SizedBox(width: w, child: c)],
        ),
      );
    },
  );

  Widget _kpiCard(
    String label,
    String primary,
    String sub,
    IconData icon,
    Color accent,
    Color softBg, {
    Color primaryColor = const Color(0xff0f1e36),
  }) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
    decoration: BoxDecoration(
      color: const Color(0xfff8fafd),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: const Color(0xffdde6f1)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: Color(0xff7f91ab),
                ),
              ),
            ),
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: softBg,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(icon, size: 12.5, color: accent),
            ),
          ],
        ),
        const SizedBox(height: 5),
        Text(
          primary,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: 'Menlo',
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: primaryColor,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          sub,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 10.5, color: Color(0xff7f91ab)),
        ),
      ],
    ),
  );

  /// 单个字段行：标签（中文 · key）+ 复制按钮 + 可选中值。
  Widget fieldRow(MapEntry<String, dynamic> e, {bool rightBorder = false}) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          border: Border(
            bottom: const BorderSide(color: Color(0xffecf1f8)),
            right: rightBorder
                ? const BorderSide(color: Color(0xffecf1f8))
                : BorderSide.none,
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
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xff7f91ab),
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                SizedBox(
                  height: 22,
                  width: 26,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    tooltip: '复制 ${e.key}',
                    onPressed: () {
                      Clipboard.setData(
                        ClipboardData(
                          text: e.value == null
                              ? 'null'
                              : _texts[e.key] ?? value(e.value),
                        ),
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
                      size: 13,
                      color: Color(0xff7f91ab),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            _fieldText(e),
          ],
        ),
      );

  Widget _fieldText(MapEntry<String, dynamic> e) {
    final text = _texts[e.key] ?? value(e.value);
    final style = TextStyle(
      fontFamily: 'Menlo',
      fontSize: 12,
      height: 1.5,
      color: e.value == null
          ? const Color(0xffa6b4c8)
          : const Color(0xff0f1e36),
    );
    if (text.length > largeFieldThreshold) {
      return LargeFieldText(text: text, style: style);
    }
    return SelectableText(text, style: style);
  }

  bool _isWideField(MapEntry<String, dynamic> e) {
    if (e.key == 'innerJson' || e.key == 'fileName') return true;
    final text = _texts[e.key] ?? '';
    return text.length > 64 || text.contains('\n');
  }

  /// 字段网格：移动端单列；桌面端按屏宽 3 / 4 列等宽带细线表格铺开，长字段自动跨全宽。
  Widget fieldGrid(List<MapEntry<String, dynamic>> fields) => LayoutBuilder(
    builder: (context, size) {
      final cols = detailColumns(MediaQuery.sizeOf(context).width);
      if (cols <= 1) {
        return Column(children: [for (final e in fields) fieldRow(e)]);
      }
      final cellWidth = size.maxWidth / cols;
      return Wrap(
        children: [
          for (var i = 0; i < fields.length; i++)
            SizedBox(
              width: _isWideField(fields[i]) ? size.maxWidth : cellWidth,
              child: fieldRow(
                fields[i],
                rightBorder: !_isWideField(fields[i]),
              ),
            ),
        ],
      );
    },
  );

  Widget _groupSwitchPill(String label, bool active, VoidCallback onTap) =>
      Material(
        color: active ? Colors.white : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        elevation: active ? 1 : 0,
        shadowColor: const Color(0x1f0f1e36),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: active ? FontWeight.w700 : FontWeight.w600,
                color: active
                    ? const Color(0xff2563eb)
                    : const Color(0xff4a5d78),
              ),
            ),
          ),
        ),
      );

  Widget _searchField() => TextField(
    key: const ValueKey('field-search'),
    controller: search,
    onChanged: (v) => setState(() => filter = v),
    style: const TextStyle(fontSize: 12),
    decoration: InputDecoration(
      isDense: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      hintText: '搜索字段名称、Key 或内容',
      prefixIcon: const Icon(Icons.search, size: 17),
      prefixIconConstraints: const BoxConstraints(minWidth: 34, minHeight: 32),
      suffixIcon: filter.isEmpty
          ? null
          : IconButton(
              tooltip: '清空字段搜索',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: () {
                search.clear();
                setState(() => filter = '');
              },
              icon: const Icon(Icons.close, size: 15),
            ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    _prepare();
    final entries = _entries, keyword = filter.toLowerCase();
    final matches = keyword.isEmpty
        ? entries
        : entries.where((e) => _searchTexts[e.key]!.contains(keyword)).toList();
    final groups = <String, List<MapEntry<String, dynamic>>>{};
    for (final e in matches) {
      final title = grouped
          ? fieldGroups.keys.firstWhere(
              (k) => fieldGroups[k]!.contains(e.key),
              orElse: () => '归档与扩展',
            )
          : '全部字段';
      groups.putIfAbsent(title, () => []).add(e);
    }
    return ColoredBox(
      color: Colors.white,
      child: Column(
        children: [
          LayoutBuilder(
            builder: (context, barSize) {
              final singleRow = barSize.maxWidth >= 660;
              final showRuleBadge = barSize.maxWidth >= 880;
              return Container(
                padding: EdgeInsets.symmetric(
                  horizontal: singleRow ? 16 : 12,
                  vertical: 8,
                ),
                decoration: const BoxDecoration(
                  color: Color(0xfff5f8fc),
                  border: Border(bottom: BorderSide(color: Color(0xffdde6f1))),
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(2.5),
                          decoration: BoxDecoration(
                            color: const Color(0xffebf1f8),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0xffdde6f1)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _groupSwitchPill(
                                '业务分组',
                                grouped,
                                () => setState(() => grouped = true),
                              ),
                              const SizedBox(width: 2),
                              _groupSwitchPill(
                                '全部字段',
                                !grouped,
                                () => setState(() => grouped = false),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        if (showRuleBadge) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xffe6f7f2),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: const Color(0xffb2e8d8),
                              ),
                            ),
                            child: const Text(
                              '✓ 0 与 false 均作为有效值保留',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                                color: Color(0xff0d8a6a),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                        ],
                        Expanded(
                          child: Text(
                            '完整单据信息 · ${entries.length} 项',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 12.5,
                              color: Color(0xff0f1e36),
                            ),
                          ),
                        ),
                        if (singleRow) ...[
                          SizedBox(width: 250, child: _searchField()),
                          const SizedBox(width: 4),
                        ],
                        IconButton(
                          tooltip: '导出完整 JSON',
                          visualDensity: VisualDensity.compact,
                          onPressed: widget.onDownload,
                          icon: const Icon(Icons.download_outlined, size: 19),
                        ),
                        IconButton(
                          tooltip: grouped ? '全部字段' : '分组展示',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => setState(() => grouped = !grouped),
                          icon: Icon(
                            grouped
                                ? Icons.view_list_outlined
                                : Icons.dashboard_outlined,
                            size: 19,
                          ),
                        ),
                      ],
                    ),
                    if (!singleRow) ...[
                      const SizedBox(height: 6),
                      _searchField(),
                    ],
                  ],
                ),
              );
            },
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
              children: [
                if (filter.isEmpty) _kpiStrip(),
                if (matches.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Text('没有匹配字段，请尝试其他关键词。'),
                  ),
                for (final group in groups.entries)
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(11),
                      border: Border.all(color: const Color(0xffdde6f1)),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        InkWell(
                          onTap: () => setState(
                            () => collapsed.contains(group.key)
                                ? collapsed.remove(group.key)
                                : collapsed.add(group.key),
                          ),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xfff5f8fc),
                              border:
                                  !collapsed.contains(group.key) ||
                                      filter.isNotEmpty
                                  ? const Border(
                                      bottom: BorderSide(
                                        color: Color(0xffdde6f1),
                                      ),
                                    )
                                  : null,
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 3.5,
                                  height: 14,
                                  decoration: BoxDecoration(
                                    color: const Color(0xff2563eb),
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                                const SizedBox(width: 9),
                                Expanded(
                                  child: Text(
                                    group.key,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 12.5,
                                      color: Color(0xff0f1e36),
                                    ),
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(999),
                                    border: Border.all(
                                      color: const Color(0xffdde6f1),
                                    ),
                                  ),
                                  child: Text(
                                    '${group.value.length} 项',
                                    style: const TextStyle(
                                      color: Color(0xff7f91ab),
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Icon(
                                  collapsed.contains(group.key)
                                      ? Icons.expand_more
                                      : Icons.expand_less,
                                  size: 18,
                                  color: const Color(0xff7f91ab),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (!collapsed.contains(group.key) || filter.isNotEmpty)
                          fieldGrid(group.value),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
            decoration: const BoxDecoration(
              color: Color(0xfff5f8fc),
              border: Border(top: BorderSide(color: Color(0xffdde6f1))),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '按 WO_INFO202610 建表字段展示 · 共 ${entries.length} 项（已排除额外 Bean 属性）',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xff7f91ab),
                    ),
                  ),
                ),
                InkWell(
                  onTap: widget.onDownload,
                  borderRadius: BorderRadius.circular(5),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    child: Text(
                      '导出同规则 JSON ↗',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Color(0xff2563eb),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
