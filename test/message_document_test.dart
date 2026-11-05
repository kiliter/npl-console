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

  group('大报文后台解析', () {
    // 构造超过阈值的报文：外层 JSON、内嵌转义 JSON 字符串及 XML 字段。
    final big = jsonEncode({
      'head': {'caseNo': 'DEMO'},
      'xml': '<root a="1"><item>甲</item></root>',
      'inner': jsonEncode({'deep': '内层'}),
      'list': List.generate(4000, (i) => {'i': i, 'text': '业务内容$i' * 4}),
    });

    test('只有超过阈值的字符串才转后台，结构化节点与纯文本不转', () {
      expect(big.length, greaterThan(backgroundParseThreshold));
      expect(shouldParseInBackground(big), isTrue);
      expect(shouldParseInBackground(big, mode: 'text'), isFalse);
      expect(shouldParseInBackground('{"a":1}'), isFalse);
      expect(shouldParseInBackground({'a': big}), isFalse);
      expect(shouldParseInBackground('{"a":1}', threshold: 3), isTrue);
    });

    test('后台 isolate 结果与同步解析一致，XML 与内嵌 JSON 可继续专注', () async {
      final background = await parseMessageInBackground(big);
      final sync = parseMessage(big);
      expect(background.format, 'json');
      expect(background.source, big);
      expect(background.root.value, sync.root.value);
      final xml = searchMessage(background.root, key: 'xml').single;
      final xmlDoc = parseMessage(xml.focusValue);
      expect(xmlDoc.format, 'xml');
      expect(searchMessage(xmlDoc.root, key: '@a').single.value, '1');
      // 跨 isolate 传回的 XML 文档仍可在主线程继续解析与专注。
      final remoteXml = await parseMessageInBackground(
        '<root a="1">${'<item>甲</item>' * 20000}</root>',
      );
      expect(remoteXml.format, 'xml');
      expect(searchMessage(remoteXml.root, key: 'item').length, 20000);
      final inner = searchMessage(background.root, key: 'inner').single;
      expect(
        searchMessage(
          parseMessage(inner.focusValue).root,
          key: 'deep',
        ).single.value,
        '内层',
      );
    });

    test('后台解析保留畸形 JSON 修复与显式格式错误', () async {
      final broken =
          '{"reqData":"{"woInfo":{"loginNo":"DEMO1"}}","pad":"${'x' * 200000}"}';
      final repaired = await parseMessageInBackground(broken);
      expect(repaired.format, 'json');
      expect(repaired.source, broken);
      final failed = await parseMessageInBackground(
        '<${'x' * 200000}',
        mode: 'xml',
      );
      expect(failed.format, 'text');
      expect(failed.error, contains('XML 解析失败'));
    });

    test('专注结构化节点时原文按需生成，子节点缓存复用', () {
      final doc = parseMessage(big);
      final list = searchMessage(doc.root, key: 'list').single;
      final focused = parseMessage(list.focusValue);
      expect(focused.format, 'json');
      // 子节点只生成一次，字段树重复读取不再重新分配。
      expect(identical(focused.root.children, focused.root.children), isTrue);
      expect(focused.root.isBranch, isTrue);
      expect(focused.root.children, hasLength(4000));
      expect(
        focused.source,
        const JsonEncoder.withIndent('  ').convert(list.value),
      );
      expect(parseMessage(<String, Object?>{}).root.isBranch, isFalse);
      expect(parseMessage(<Object?>[]).root.isBranch, isFalse);
    });
  });
}
