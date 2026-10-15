import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:npl_maintenance/core/contracts.dart';
import 'package:npl_maintenance/core/log_files.dart';
import 'package:npl_maintenance/core/maintenance_controller.dart';
import 'package:npl_maintenance/core/request_log_store.dart';

/// 日志文件接口全部使用模拟 HTTP，不访问真实服务。
void main() {
  final settings = ConnectionSettings.multi(
    environments: const [
      Environment(
        name: '测试',
        baseUrl: 'https://server.invalid/npl',
        webBaseUrl: 'https://web.invalid/nplweb',
      ),
    ],
    loginNo: 'test',
    channel: 'test',
  );
  // http.Response 默认按 Latin1 编码字符串，中文响应体需以 UTF-8 字节构造。
  http.Response json(Object body, int status) =>
      http.Response.bytes(utf8.encode(jsonEncode(body)), status);
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('npl-log-file-');
  });
  tearDown(() => directory.delete(recursive: true));

  MaintenanceController controller(http.Client client) => MaintenanceController(
    clientFactory: () => client,
    testToken: () => 'temporary-test-token',
    logStore: RequestLogStore(directoryProvider: () async => directory),
  )..settings = settings;

  http.Response chunk(List<int> bytes, int offset, int size, String key) =>
      http.Response.bytes(
        bytes,
        200,
        headers: {
          'content-type': 'application/octet-stream',
          'x-file-size': '$size',
          'x-chunk-offset': '$offset',
          'x-file-key': Uri.encodeQueryComponent(key),
          'x-file-name': Uri.encodeQueryComponent('app.log'),
        },
      );

  Map<String, Object> listBody(String path, String key) => {
    'resultCode': '0',
    'resultDesc': 'SUCCESS',
    'app': 'npl-web',
    'instances': [
      {
        'instance': '10.0.0.1:8080',
        'pod': 'web-0',
        'status': 'OK',
        'entries': [
          {
            'path': path,
            'type': 'FILE',
            'size': 10,
            'lastModified': '2026-10-15 10:00:00',
            'fileKey': key,
          },
        ],
      },
      {
        'instance': '10.0.0.2:8080',
        'pod': 'web-1',
        'status': 'TIMEOUT',
        'message': '副本响应超时',
      },
    ],
  };

  test('web 列表走 web 地址，带 kkk 鉴权；副本状态逐个解析', () async {
    final requests = <http.Request>[];
    final c = controller(
      MockClient((request) async {
        requests.add(request);
        return json(listBody('app.log', 'k1'), 200);
      }),
    );
    final result = await LogFileClient(c, LogApp.web).list('');
    expect(
      requests.single.url.toString(),
      'https://web.invalid/nplweb/log-file/list',
    );
    expect(requests.single.headers['kkk'], 'temporary-test-token');
    expect(jsonDecode(requests.single.body), {'dir': ''});
    expect(result.first.ok, isTrue);
    expect(result.first.entries.single.fileKey, 'k1');
    expect(result.last.ok, isFalse);
    expect(c.logs.single.label, '日志文件列表');
    c.dispose();
  });

  test('按 offset 循环下载分片并拼接，只取到首片的文件大小为止', () async {
    final content = utf8.encode('0123456789');
    final offsets = <String>[];
    final c = controller(
      MockClient((request) async {
        expect(request.url.path, '/npl/log-file/download');
        final offset = int.parse(request.url.queryParameters['offset']!);
        offsets.add('$offset');
        expect(request.url.queryParameters['fileKey'], 'k1');
        // 第三片模拟下载期间追加了新日志，超出首片文件大小的部分不应混入。
        final end = offset + 4 > 10 ? 10 : offset + 4;
        final bytes = [...content.sublist(offset, end), if (end == 10) 65];
        return chunk(bytes, offset, offset == 0 ? 10 : 11, 'k1');
      }),
    );
    final instance = LogInstance.fromJson(
      (listBody('app.log', 'k1')['instances'] as List).first as Map,
    );
    final progress = <int>[];
    final target = File('${directory.path}/out/app.log');
    final result = await LogFileClient(c, LogApp.server).download(
      instance,
      instance.entries.single,
      target,
      onProgress: (done, _) => progress.add(done),
    );
    expect(offsets, ['0', '4', '8']);
    expect(progress, [4, 8, 10]);
    expect(await target.readAsString(), '0123456789');
    expect(result.size, 10);
    expect(result.fileName, 'app.log');
    expect(File('${target.path}.part').existsSync(), isFalse);
    c.dispose();
  });

  test('文件轮转返回 409 时按 fileKey 重新定位后从当前 offset 续传', () async {
    final content = utf8.encode('0123456789');
    final calls = <String>[];
    final c = controller(
      MockClient((request) async {
        if (request.url.path.endsWith('/log-file/list')) {
          calls.add('list ${jsonDecode(request.body)['dir']}');
          return json(listBody('biz/app.log.1', 'k1'), 200);
        }
        final path = request.url.queryParameters['path']!;
        final offset = int.parse(request.url.queryParameters['offset']!);
        calls.add('download $path $offset');
        if (path == 'biz/app.log' && offset > 0) {
          return json({'resultCode': '409', 'resultDesc': '文件已轮转'}, 409);
        }
        final end = offset + 6 > 10 ? 10 : offset + 6;
        return chunk(content.sublist(offset, end), offset, 10, 'k1');
      }),
    );
    final instance = LogInstance.fromJson(
      (listBody('biz/app.log', 'k1')['instances'] as List).first as Map,
    );
    final result = await LogFileClient(c, LogApp.server).download(
      instance,
      instance.entries.single,
      File('${directory.path}/r.log'),
    );
    expect(calls, [
      'download biz/app.log 0',
      'download biz/app.log 6',
      'list biz',
      'download biz/app.log.1 6',
    ]);
    expect(await result.file.readAsString(), '0123456789');
    c.dispose();
  });

  test('下载接口返回 HTML 页面或错误码时给出明确原因', () async {
    var html = true;
    final c = controller(
      MockClient((request) async {
        if (html) {
          return http.Response(
            '<html>login</html>',
            200,
            headers: {'content-type': 'text/html'},
          );
        }
        return json({'resultCode': '401', 'resultDesc': 'JWT鉴权失败'}, 401);
      }),
    );
    final instance = LogInstance.fromJson(
      (listBody('app.log', 'k1')['instances'] as List).first as Map,
    );
    final client = LogFileClient(c, LogApp.web);
    final failed = File('${directory.path}/failed.log');
    await expectLater(
      client.download(instance, instance.entries.single, failed),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('未返回文件分片'),
        ),
      ),
    );
    html = false;
    await expectLater(
      client.download(instance, instance.entries.single, failed),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('JWT鉴权失败'),
        ),
      ),
    );
    // 失败不留下半截文件。
    expect(failed.existsSync(), isFalse);
    expect(File('${failed.path}.part').existsSync(), isFalse);
    // 接口记录不保存凭据。
    final saved = await File(c.logStore.path!).readAsString();
    expect(saved, isNot(contains('temporary-test-token')));
    c.dispose();
  });

  test('未配置 web 地址时拒绝请求并提示', () async {
    final c = controller(MockClient((_) async => http.Response('[]', 200)))
      ..settings = const ConnectionSettings(
        baseUrl: 'https://server.invalid',
        loginNo: 'test',
        channel: 'test',
      );
    await expectLater(
      LogFileClient(c, LogApp.web).list(''),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('未配置 web 地址'),
        ),
      ),
    );
    c.dispose();
  });
}
