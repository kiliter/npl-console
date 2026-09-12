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
}
