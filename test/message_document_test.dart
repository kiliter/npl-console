import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:npl_maintenance/core/message_document.dart';

/// 验证真实报文常见的 JSON、XML、CDATA 交错嵌套及搜索。
void main() {
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
