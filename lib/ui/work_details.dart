import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/contracts.dart';

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
  'picSeq': '图片序号',
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
  @override
  Widget build(BuildContext context) {
    final entries = woInfoFields(widget.record).entries.toList();
    final matches = entries
        .where(
          (e) => '${fieldLabels[e.key]} ${e.key} ${value(e.value)}'
              .toLowerCase()
              .contains(filter.toLowerCase()),
        )
        .toList();
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
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '完整单据信息 · ${entries.length} 项',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    IconButton(
                      tooltip: '导出完整 JSON',
                      onPressed: widget.onDownload,
                      icon: const Icon(Icons.download_outlined, size: 20),
                    ),
                    IconButton(
                      tooltip: grouped ? '全部字段' : '分组展示',
                      onPressed: () => setState(() => grouped = !grouped),
                      icon: Icon(
                        grouped
                            ? Icons.view_list_outlined
                            : Icons.dashboard_outlined,
                        size: 20,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const ValueKey('field-search'),
                  controller: search,
                  onChanged: (v) => setState(() => filter = v),
                  decoration: InputDecoration(
                    hintText: '搜索字段名称、Key 或内容',
                    prefixIcon: const Icon(Icons.search, size: 19),
                    suffixIcon: filter.isEmpty
                        ? null
                        : IconButton(
                            tooltip: '清空字段搜索',
                            onPressed: () {
                              search.clear();
                              setState(() => filter = '');
                            },
                            icon: const Icon(Icons.close, size: 17),
                          ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
              children: [
                if (matches.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Text('没有匹配字段，请尝试其他关键词。'),
                  ),
                for (final group in groups.entries) ...[
                  InkWell(
                    onTap: () => setState(
                      () => collapsed.contains(group.key)
                          ? collapsed.remove(group.key)
                          : collapsed.add(group.key),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Row(
                        children: [
                          Container(
                            width: 3,
                            height: 15,
                            color: const Color(0xff2869e8),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              group.key,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Text(
                            '${group.value.length} 项',
                            style: const TextStyle(
                              color: Color(0xff8192a9),
                              fontSize: 11,
                            ),
                          ),
                          Icon(
                            collapsed.contains(group.key)
                                ? Icons.expand_more
                                : Icons.expand_less,
                            size: 19,
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (!collapsed.contains(group.key) || filter.isNotEmpty)
                    for (final e in group.value)
                      Container(
                        padding: const EdgeInsets.symmetric(vertical: 12),
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
                                        ClipboardData(
                                          text: e.value == null
                                              ? 'null'
                                              : value(e.value),
                                        ),
                                      );
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text('字段内容已复制'),
                                          duration: Duration(seconds: 1),
                                        ),
                                      );
                                    },
                                    icon: const Icon(
                                      Icons.copy_outlined,
                                      size: 14,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 5),
                            SelectableText(
                              value(e.value),
                              style: TextStyle(
                                fontSize: 13,
                                height: 1.65,
                                color: e.value == null
                                    ? const Color(0xffa4afbf)
                                    : const Color(0xff1b2b42),
                              ),
                            ),
                          ],
                        ),
                      ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
