import 'package:npl_maintenance/core/request_log_store.dart';
import 'package:flutter/material.dart';
import 'package:npl_maintenance/ui/table_query_sheet.dart';
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
        return http.Response(
          jsonEncode([
            {'caseNo': 'CASE', 'picSeq': '3'},
          ]),
          200,
        );
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
  test('按受理流水查询：图片表只发送 picSeq，其余表仍发送 sysAccept', () async {
    for (final table in TableKind.values) {
      http.Request? sent;
      final c = MaintenanceController(
        clientFactory: () => MockClient((request) async {
          sent = request;
          return http.Response('[]', 200);
        }),
        testToken: () => 'test',
      )..settings = settings;
      final body = tableQueryBody(
        table,
        sysAccept: ' 000202610310000000000000003 ',
        opMonth: '2026-10',
      );
      await c.queryTable(table, body);
      expect(sent!.url.path, '/npl${table.endpoint}');
      expect(jsonDecode(sent!.body), {
        table == TableKind.wopicinfo ? 'picSeq' : 'sysAccept':
            '000202610310000000000000003',
        'opMonth': '202610',
      });
      c.dispose();
    }
  });
  testWidgets('图片表保留一个受理流水输入，实际请求使用 picSeq', (tester) async {
    await tester.binding.setSurfaceSize(const Size(700, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    http.Request? sent;
    final c = MaintenanceController(
      logStore: _MemoryLogStore(),
      clientFactory: () => MockClient((request) async {
        sent = request;
        return http.Response('[]', 200);
      }),
      testToken: () => 'test',
    )..settings = settings;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TableQuerySheet(controller: c)),
      ),
    );
    await tester.tap(find.byType(DropdownButtonFormField<TableKind>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('图片表（WO_PIC_INFO）').last);
    await tester.pumpAndSettle();
    expect(find.text('受理流水'), findsOneWidget);
    expect(find.text('图片序号'), findsNothing);
    await tester.enterText(find.byType(TextField).at(0), 'CASE');
    await tester.enterText(
      find.byType(TextField).at(1),
      '000202610310000000000000003',
    );
    await tester.tap(find.text('查询图片表'));
    await tester.pumpAndSettle();
    expect(sent!.url.path, '/npl/api/wopic/queryList');
    expect(jsonDecode(sent!.body), {
      'caseNo': 'CASE',
      'picSeq': '000202610310000000000000003',
    });
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
  test('五张表分别映射到既有 queryList 接口', () {
    expect(TableKind.woinfo.endpoint, '/api/wo/queryList');
    expect(TableKind.wobizinfo.endpoint, '/api/wobiz/queryList');
    expect(TableKind.wosigninfo.endpoint, '/api/wosign/queryList');
    expect(TableKind.wopicinfo.endpoint, '/api/wopic/queryList');
    expect(TableKind.interResult.endpoint, '/api/inter/result/queryList');
    expect(TableKind.wopicinfo.hasPicSeq, isTrue);
    expect(TableKind.woinfo.hasPicSeq, isFalse);
  });
  test('接口失败抛出可读错误并标记状态，不吞掉失败', () async {
    final controller = MaintenanceController(
      clientFactory: () => MockClient((_) async => http.Response('拒绝访问', 403)),
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

class _MemoryLogStore extends RequestLogStore {
  @override
  Future<void> append(Map<String, Object?> record) async {}
}
