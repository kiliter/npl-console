import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:npl_maintenance/core/contracts.dart';
import 'package:npl_maintenance/core/maintenance_controller.dart';

/// 验证数据查询复用既有只读接口、请求体与错误处理，使用模拟 HTTP，不访问生产服务。
void main() {
  const settings = ConnectionSettings(
    baseUrl: 'https://example.invalid/npl',
    loginNo: 'test',
    channel: 'test',
  );
  test('按表命中对应只读接口，返回原始记录并更新状态', () async {
    final requests = <http.Request>[];
    final controller = MaintenanceController(
      clientFactory: () => MockClient((request) async {
        requests.add(request);
        return http.Response(jsonEncode([
          {'caseNo': 'CASE', 'picSeq': '3'},
        ]), 200);
      }),
      testToken: () => 'temporary-test-token',
    )..settings = settings;
    final body = tableQueryBody(
      TableKind.wopicinfo,
      caseNo: 'CASE',
      opMonth: '2026-09',
      picSeq: '3',
    );
    final rows = await controller.queryTable(TableKind.wopicinfo, body);
    expect(rows, [
      {'caseNo': 'CASE', 'picSeq': '3'},
    ]);
    expect(requests.single.url.path, '/npl/api/wopic/queryList');
    expect(jsonDecode(requests.single.body), body);
    expect(requests.single.headers['kkk'], 'temporary-test-token');
    expect(controller.error, isFalse);
    expect(controller.message, contains('1 条记录'));
    expect(controller.logs.single.state, '成功');
    controller.dispose();
  });
  test('四张表分别映射到既有 queryList 接口', () {
    expect(TableKind.woinfo.category.endpoint, '/api/wo/queryList');
    expect(TableKind.wobizinfo.category.endpoint, '/api/wobiz/queryList');
    expect(TableKind.wosigninfo.category.endpoint, '/api/wosign/queryList');
    expect(TableKind.wopicinfo.category.endpoint, '/api/wopic/queryList');
    expect(TableKind.wopicinfo.hasPicSeq, isTrue);
    expect(TableKind.woinfo.hasPicSeq, isFalse);
  });
  test('接口失败抛出可读错误并标记状态，不吞掉失败', () async {
    final controller = MaintenanceController(
      clientFactory: () =>
          MockClient((_) async => http.Response('拒绝访问', 403)),
      testToken: () => 'test',
    )..settings = settings;
    await expectLater(
      controller.queryTable(TableKind.woinfo, {'caseNo': 'CASE'}),
      throwsFormatException,
    );
    expect(controller.error, isTrue);
    expect(controller.logs.single.state, '失败');
    controller.dispose();
  });
  test('缺少连接设置或密钥时本地拒绝，不发起请求', () async {
    var calls = 0;
    final controller = MaintenanceController(
      clientFactory: () => MockClient((_) async {
        calls++;
        return http.Response('[]', 200);
      }),
      testToken: () => 'test',
    );
    await expectLater(
      controller.queryTable(TableKind.woinfo, {'caseNo': 'CASE'}),
      throwsFormatException,
    );
    expect(calls, 0);
    expect(controller.error, isTrue);
    controller.dispose();
  });
  test('取消后迟到响应不返回结果，请求标记为已取消', () async {
    final completer = Completer<http.Response>();
    final controller = MaintenanceController(
      clientFactory: () => MockClient((_) => completer.future),
      testToken: () => 'test',
    )..settings = settings;
    final pending = controller.queryTable(TableKind.woinfo, {'caseNo': 'CASE'});
    await Future<void>.delayed(Duration.zero);
    controller.cancel();
    completer.complete(http.Response('[{"caseNo":"LATE"}]', 200));
    await expectLater(pending, throwsA(isNot(isA<FormatException>())));
    expect(controller.busy, isFalse);
    expect(controller.logs.single.state, '已取消');
    controller.dispose();
  });
}
