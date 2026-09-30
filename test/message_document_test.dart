import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:npl_maintenance/core/message_document.dart';

/// 验证真实报文常见的 JSON、XML、CDATA 交错嵌套及搜索。
void main() {
  test('受理内容原始引号兼容解析，既有转义及字段完整保留', () {
    // 外层 data 已解码后的真实缺陷形态，测试数据不包含用户业务信息。
    const raw =
        r'{"reqData":{"woOpList":[{"acceptContent":"<row><b>"条款"</b></row><row>已转义\"引号\"与换行\n路径C:\\tmp</row>"}],"agreeCheck":true}}';
    final doc = parseMessage(raw);
    expect(doc.format, 'json');
    expect(doc.source, raw);
    expect(searchMessage(doc.root, key: 'agreeCheck').single.value, true);
    expect(
      searchMessage(doc.root, key: 'acceptContent').single.value,
      '<row><b>"条款"</b></row><row>已转义"引号"与换行\n路径C:\\tmp</row>',
    );
  });

  test('合法 acceptContent 不重复解码，普通错误不会被静默当作文本', () {
    const content = r'<row>字面量\n与"引号"</row>';
    final raw = jsonEncode({'acceptContent': content, 'after': '完整尾部'});
    final doc = parseMessage(raw);
    expect(searchMessage(doc.root, key: 'acceptContent').single.value, content);
    expect(searchMessage(doc.root, key: 'after').single.value, '完整尾部');
    expect(parseMessage('{"other":"未转义"引号"}').error, isNotNull);
  });

  test('多条超长受理内容全部解析，首尾字段和合法转义不丢失', () {
    // 模拟同一报文中多条业务，长度与条目数都超过早期简单样例。
    final content = '<row>"条款"${'完整中文内容' * 4000}\n结束</row>';
    final valid = jsonEncode({
      'before': '开头字段',
      'reqData': {
        'woOpList': List.generate(
          12,
          (i) => {'orderId': i, 'acceptContent': content},
        ),
        'agreeCheck': true,
      },
      'after': '末尾字段',
    });
    // 只移除业务条款引号的转义，保留真实 JSON 的换行和其它转义。
    final malformed = valid.replaceAll(r'\"条款\"', '"条款"');
    expect(malformed, isNot(valid));
    final doc = parseMessage(malformed);
    expect(doc.format, 'json');
    expect(doc.source, malformed);
    final root = doc.root.value as Map;
    expect(root['before'], '开头字段');
    expect(root['after'], '末尾字段');
    final req = root['reqData'] as Map;
    expect(req['agreeCheck'], true);
    final rows = req['woOpList'] as List;
    expect(rows.length, 12);
    for (var i = 0; i < rows.length; i++) {
      expect(rows[i]['orderId'], i);
      expect(rows[i]['acceptContent'], content);
    }
  });

  test('兼容范围之外的非法 JSON 保留原文并明确提示失败', () {
    const raw = '{"acceptContent":"不是 row 格式的"内容", "tail":true}';
    final doc = parseMessage(raw);
    expect(doc.format, 'text');
    expect(doc.source, raw);
    expect(doc.error, contains('JSON 解析未成功'));
  });

  test('JSON 内 XML 的 CDATA 可继续专注为 JSON', () {
    final doc = parseMessage(
      jsonEncode({
        'body':
            '<root><payload><![CDATA[{"user":{"phone":"123"}}]]></payload></root>',
      }),
    );
    final xml = parseMessage(doc.root.children.single.focusValue);
    expect(xml.format, 'xml');
    final payload = searchMessage(xml.root, key: 'payload').first;
    final json = parseMessage(payload.focusValue);
    expect(json.format, 'json');
    final user = searchMessage(json.root, key: 'user').single;
    expect(parseMessage(user.focusValue).root.children.single.value, '123');
  });
  test('XML 保留属性、重复元素，组合搜索返回正确路径', () {
    final doc = parseMessage(
      '<root id="a"><item>one</item><item>two</item></root>',
    );
    expect(searchMessage(doc.root, key: '@id').single.value, 'a');
    final matches = searchMessage(doc.root, key: 'item', keyword: 'two');
    expect(matches.length, 1);
    expect(matches.single.path, contains('item[1]'));
  });
  test('格式错误保留完整原文，显式解析返回错误', () {
    const raw = '<invalid';
    expect(parseMessage(raw).source, raw);
    expect(parseMessage(raw, mode: 'xml').error, isNotNull);
    expect(parseMessage(raw, mode: 'json').source, raw);
  });
  test('服务端未转义内嵌 JSON（reqData 形态）自动修复后可解析', () {
    // 真实报文形态：{"reqData":"{"woInfo":{...}}"} 内嵌 JSON 未转义，属非法 JSON。
    const broken =
        '{"reqData":"{"woInfo":{"loginNo":"DEMO1"},"list":[{"a":1}]}","regionCode":"13"}';
    final doc = parseMessage(broken);
    expect(doc.format, 'json');
    expect(doc.source, broken); // 原文保持不动
    final req = doc.root.children.firstWhere((e) => e.name == 'reqData');
    final inner = parseMessage(req.focusValue);
    expect(inner.format, 'json');
    expect(searchMessage(inner.root, key: 'loginNo').single.value, 'DEMO1');
  });
}
