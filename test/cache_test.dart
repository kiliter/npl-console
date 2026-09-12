import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:npl_maintenance/core/contracts.dart';
import 'package:npl_maintenance/core/maintenance_controller.dart';
import 'package:npl_maintenance/core/query_cache.dart';

void main() {
  const settings = ConnectionSettings(
    baseUrl: 'https://example.invalid',
    loginNo: 'test',
    channel: 'test',
  );
  test('缓存到期失效、容量淘汰且不保留请求认证头', () {
    var now = DateTime.utc(2026);
    final cache = QueryCache(now: () => now, maxBytes: 10, maxEntries: 2);
    cache.put(
      'a',
      http.Response(
        '1234',
        200,
        request: http.Request('POST', Uri.parse('https://example.invalid'))
          ..headers['kkk'] = 'secret',
      ),
    );
    expect(cache.get('a')!.request, isNull);
    cache.put('b', http.Response('12345678', 200));
    expect(cache.get('a'), isNull);
    now = now.add(const Duration(minutes: 6));
    expect(cache.get('b'), isNull);
  });
  test('重复工单和报文查询命中缓存，刷新与连接变更失效缓存', () async {
    final paths = <String>[];
    final c = MaintenanceController(
      testToken: () => 'test',
      clientFactory: () => MockClient((r) async {
        paths.add(r.url.path);
        if (r.url.path == '/api/wo/queryList') {
          return http.Response('[{"caseNo":"CASE","regionCode":"025"}]', 200);
        }
        if (r.url.path == '/api/wobiz/queryList') {
          return http.Response('[{"caseNo":"CASE","cmdCode":"cmd"}]', 200);
        }
        return http.Response.bytes(utf8.encode('完整报文'), 200);
      }),
    )..settings = settings;
    await c.search('caseNo', 'CASE', '', '', false);
    await c.search('caseNo', 'CASE', '', '', false);
    expect(paths.length, 1);
    c.chooseWork(c.works.single);
    await c.selectCategory(Category.message);
    await c.selectCategory(Category.work);
    await c.selectCategory(Category.message);
    expect(paths.length, 3, reason: '${c.message} $paths');
    expect(c.cacheHits, 3);
    await c.selectCategory(Category.message, forceRefresh: true);
    expect(paths.length, 5);
    SharedPreferences.setMockInitialValues({});
    await c.configure(settings, null);
    await c.search('caseNo', 'CASE', '', '', false);
    expect(paths.length, 6);
    c.dispose();
  });
  test('画廊加载全部图片，同对象并发合并，单图失败可重试', () async {
    final counts = <String, int>{};
    final c = MaintenanceController(
      testToken: () => 'test',
      clientFactory: () => MockClient((r) async {
        if (r.url.path == '/api/wopic/queryList') {
          return http.Response(
            jsonEncode([
              {'picPath': '/nas/a.png'},
              {'picPath': '/nas/a.png'},
              {'picPath': '/nas/b.png'},
            ]),
            200,
          );
        }
        final name = Uri.splitQueryString(r.body)['objectName']!;
        counts[name] = (counts[name] ?? 0) + 1;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        if (name == 'b.png' && counts[name] == 1) {
          return http.Response('missing', 404);
        }
        return http.Response.bytes([137, 80, 78, 71, 13, 10, 26, 10], 200);
      }),
    )..settings = settings;
    c.chooseWork({'caseNo': 'CASE', 'regionCode': '025'});
    await c.selectCategory(Category.picture);
    expect(c.gallery.length, 3);
    expect(counts['a.png'], 1);
    expect(c.gallery.last.error, isNotNull);
    expect(c.gallery.first.bytes, isNotNull);
    await c.retryImage(c.gallery.last);
    expect(counts['b.png'], 2);
    expect(c.gallery.last.error, isNull);
    await c.selectCategory(Category.work);
    await c.selectCategory(Category.picture);
    expect(counts, {'a.png': 1, 'b.png': 2});
    c.dispose();
  });
  test('失败接口响应不进入缓存', () async {
    var count = 0;
    final c = MaintenanceController(
      testToken: () => 'test',
      clientFactory: () => MockClient((r) async {
        count++;
        return http.Response('denied', 403);
      }),
    )..settings = settings;
    await c.search('caseNo', 'CASE', '', '', false);
    await c.search('caseNo', 'CASE', '', '', false);
    expect(count, 2);
    c.dispose();
  });
}
