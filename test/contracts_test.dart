import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:npl_maintenance/core/contracts.dart';
import 'package:npl_maintenance/core/maintenance_controller.dart';

/// 验证月份边界、OBS 契约及异步取消，使用模拟 HTTP，不访问生产服务。
void main() {
  test('单月忽略旧结束月份，范围含首尾最多十二个月', () {
    expect(queryBodies('phoneNo', '13800000000', '2026-09', '2027-10', false), [
      {'phoneNo': '13800000000', 'opMonth': '202609'},
    ]);
    expect(
      queryBodies('sysAccept', 'FLOW', '2025-10', '2026-09', true).length,
      12,
    );
    expect(
      () => queryBodies('phoneNo', '1', '2025-09', '2026-09', true),
      throwsFormatException,
    );
    expect(
      () => queryBodies('phoneNo', '1', '2026-09', '2026-08', true),
      throwsFormatException,
    );
    expect(queryBodies('caseNo', 'CASE', '', '', false), [
      {'caseNo': 'CASE'},
    ]);
  });
  test('多文件按平台既有规则构造对象名与解密参数', () {
    final work = <String, dynamic>{
      'caseNo': 'CASE',
      'regionCode': '025',
      'ext8': '2',
    };
    final records = <Record>[
      {'caseNo': 'CASE', 'cmdCode': 'cmdjs001'},
    ];
    final messages = Asset.fromRecords(Category.message, records, work);
    expect(messages.map((e) => e.name), [
      'CASE_cmdjs001.txt',
      'CASE_cmdjs001_oprInfo.txt',
      'CASE_cmdjs001_h5.txt',
    ]);
    expect(messages.first.obsBody(work, const ConnectionSettings()), {
      'bucketName': 'receipt025',
      'objectName': 'CASE_cmdjs001.txt',
      'ext8': '2',
    });
    expect(
      Asset.fromRecords(Category.sign, [
        {'signPath': '/nas/sign.png'},
        {'signPath': '/nas/other.png'},
      ], work).length,
      2,
    );
    expect(
      Asset.fromRecords(Category.picture, [
        {'picPath': r'C:\nas\photo.jpg'},
      ], work).single.name,
      'photo.jpg',
    );
  });
  const settings = ConnectionSettings(
    baseUrl: 'https://example.invalid/npl',
    loginNo: 'test',
    channel: 'test',
  );
  test('逐月调用仅查询工单，去重后等待用户选择，实际请求有认证头', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return http.Response(
        jsonEncode([
          {'caseNo': 'ONE', 'opMonth': '202609'},
          {'caseNo': 'TWO', 'opMonth': '202609'},
        ]),
        200,
      );
    });
    final controller = MaintenanceController(
      clientFactory: () => client,
      testToken: () => 'temporary-test-token',
    )..settings = settings;
    await controller.search(
      'phoneNo',
      '13800000000',
      '2026-08',
      '2026-09',
      true,
    );
    expect(requests.length, 2);
    expect(controller.works.length, 2);
    expect(controller.work, isNull);
    expect(
      requests.every((r) => r.url.path == '/npl/api/wo/queryList'),
      isTrue,
    );
    expect(jsonDecode(requests.first.body)['opMonth'], '202608');
    expect(requests.first.headers['kkk'], 'temporary-test-token');
    expect(
      controller.logs.any((log) => log.detail.contains('temporary-test-token')),
      isFalse,
    );
    await expectLater(
      controller.request('/api/wo/del', {}, 0),
      throwsFormatException,
    );
    controller.dispose();
  });
  test('取消后迟到响应不覆盖结果，不继续调用下个月', () async {
    final completer = Completer<http.Response>();
    var calls = 0;
    final controller = MaintenanceController(
      clientFactory: () => MockClient((_) {
        calls++;
        return completer.future;
      }),
      testToken: () => 'test',
    )..settings = settings;
    final pending = controller.search(
      'phoneNo',
      '1',
      '2026-08',
      '2026-09',
      true,
    );
    await Future<void>.delayed(Duration.zero);
    controller.cancel();
    completer.complete(http.Response('[{"caseNo":"LATE"}]', 200));
    await pending;
    expect(controller.works, isEmpty);
    expect(calls, 1);
    expect(controller.busy, isFalse);
    expect(controller.logs.single.state, '已取消');
    controller.dispose();
  });
  test('部分月份失败保留其它月份，结果不声称全部成功', () async {
    var count = 0;
    final controller = MaintenanceController(
      clientFactory: () => MockClient(
        (_) async => ++count == 1
            ? http.Response('拒绝访问', 403)
            : http.Response('[{"caseNo":"OK"}]', 200),
      ),
      testToken: () => 'test',
    )..settings = settings;
    await controller.search('sysAccept', 'FLOW', '2026-08', '2026-09', true);
    expect(controller.works.length, 1);
    expect(controller.failures.length, 1);
    expect(controller.error, isTrue);
    controller.dispose();
  });
}
