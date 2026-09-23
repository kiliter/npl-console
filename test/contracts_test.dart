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
  test('按表查询仅保留非空条件，月份转分表格式，图片序号限定图片表', () {
    expect(tableQueryBody(TableKind.woinfo, caseNo: 'CASE'), {
      'caseNo': 'CASE',
    });
    expect(
      tableQueryBody(
        TableKind.woinfo,
        sysAccept: ' FLOW ',
        opMonth: '2026-09',
      ),
      {'sysAccept': 'FLOW', 'opMonth': '202609'},
    );
    expect(
      tableQueryBody(
        TableKind.wopicinfo,
        caseNo: 'CASE',
        opMonth: '2026-09',
        picSeq: '3',
      ),
      {'caseNo': 'CASE', 'opMonth': '202609', 'picSeq': '3'},
    );
    expect(() => tableQueryBody(TableKind.woinfo), throwsFormatException);
    expect(
      () => tableQueryBody(TableKind.woinfo, sysAccept: 'FLOW'),
      throwsFormatException,
    );
    expect(
      () => tableQueryBody(TableKind.woinfo, caseNo: 'CASE', opMonth: '2026-9'),
      throwsFormatException,
    );
    expect(
      () => tableQueryBody(TableKind.woinfo, caseNo: 'CASE', picSeq: '1'),
      throwsFormatException,
    );
    expect(
      () =>
          tableQueryBody(TableKind.wopicinfo, caseNo: 'CASE', picSeq: 'abc'),
      throwsFormatException,
    );
    expect(
      () => tableQueryBody(TableKind.wopicinfo, caseNo: 'CASE', picSeq: '0'),
      throwsFormatException,
    );
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
  test('全量报文仅传 caseNo，成功返回内容，失败抛出服务端描述', () async {
    final requests = <http.Request>[];
    var fail = false;
    final controller = MaintenanceController(
      clientFactory: () => MockClient((request) async {
        requests.add(request);
        return fail
            ? http.Response(
                '{"result":1,"desc":"不存在此单据"}',
                200,
                headers: {'content-type': 'application/json; charset=utf-8'},
              )
            : http.Response('{"result":0,"data":"<xml/>","desc":""}', 200);
      }),
      testToken: () => 'temporary-test-token',
    )..settings = settings;
    // 未选择工单时本地拒绝，不发起请求。
    await expectLater(controller.downloadFullBiz(), throwsFormatException);
    expect(requests, isEmpty);
    controller.work = {'caseNo': 'CASE'};
    final content = await controller.downloadFullBiz();
    expect(content, '<xml/>');
    expect(requests.single.url.path, '/npl/agapi/biz/downloadBiz');
    expect(jsonDecode(requests.single.body), {'caseNo': 'CASE'});
    expect(controller.error, isFalse);
    expect(controller.logs.single.state, '成功');
    // 接口记录按路径识别中文名，列表无需点进详情即可区分接口。
    expect(controller.logs.single.label, '全量报文下载');
    fail = true;
    await expectLater(
      controller.downloadFullBiz(),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('不存在此单据'),
        ),
      ),
    );
    expect(controller.error, isTrue);
    controller.dispose();
  });
  test('报文列表追加全量报文，选中后经 downloadBiz 加载为文本解析', () async {
    final controller = MaintenanceController(
      clientFactory: () => MockClient((request) async {
        if (request.url.path.endsWith('/agapi/biz/downloadBiz')) {
          return http.Response('{"result":0,"data":"{\\"a\\":1}","desc":""}', 200);
        }
        if (request.url.path.endsWith('/test/un_look')) {
          return http.Response('留存报文内容', 200, headers: {
            'content-type': 'text/plain; charset=utf-8',
          });
        }
        return http.Response('[{"caseNo":"CASE","cmdCode":"cmdjs001"}]', 200);
      }),
      testToken: () => 'test',
    )..settings = settings;
    controller.work = {'caseNo': 'CASE', 'opMonth': '202609', 'regionCode': '025'};
    await controller.selectCategory(Category.message);
    // 三份留存报文之后追加一份全量报文，默认仍加载首份留存报文。
    expect(controller.assets.length, 4);
    expect(controller.assets.last.kind, 'fullbiz');
    expect(controller.assets.last.label, '全量报文');
    await controller.loadAsset(controller.assets.last);
    expect(utf8.decode(controller.bytes!), '{"a":1}');
    expect(controller.contentType, 'text');
    expect(controller.asset?.name, 'CASE_全量报文.json');
    controller.dispose();
  });
  test('全量报文 data 嵌套转义信封时逐层还原出真实报文', () async {
    // 服务端把整包响应再塞进 data：{"result":0,"data":"{\"result\":0,\"data\":\"...\"}"}。
    final nested = jsonEncode({
      'result': 0,
      'data': jsonEncode({
        'result': 0,
        'data': jsonEncode({
          'svcCont': {'orderId': 'ORD-1'},
        }),
        'desc': '',
      }),
      'desc': '',
    });
    final controller = MaintenanceController(
      clientFactory: () => MockClient((request) async {
        return http.Response(nested, 200);
      }),
      testToken: () => 'test',
    )..settings = settings;
    controller.work = {'caseNo': 'CASE'};
    // 还原后应直接得到真实报文 JSON，而不是带信封的转义字符串。
    expect(
      await controller.downloadFullBiz(),
      '{"svcCont":{"orderId":"ORD-1"}}',
    );
    controller.dispose();
  });
}
