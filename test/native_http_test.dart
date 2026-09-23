import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:npl_maintenance/core/contracts.dart';
import 'package:npl_maintenance/core/maintenance_controller.dart';
import 'package:npl_maintenance/core/request_log_store.dart';

/// 使用本机临时 HTTP 服务验证原生请求路径，不连接业务环境。
void main() {
  test('原生 HTTP 直接 POST，不发送浏览器 OPTIONS，OBS 文件保持原始字节', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final methods = <String>[], paths = <String>[], bodies = <String>[];
    server.listen((request) async {
      methods.add(request.method);
      paths.add(request.uri.path);
      bodies.add(await utf8.decoder.bind(request).join());
      if (request.uri.path.endsWith('/queryList')) {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          '[{"caseNo":"CASE","regionCode":"025","opMonth":"202609"}]',
        );
      } else {
        request.response.add(utf8.encode('%PDF-1.4\nTEST'));
      }
      await request.response.close();
    });
    final directory = await Directory.systemTemp.createTemp('npl-http-log-');
    addTearDown(() => directory.delete(recursive: true));
    final store = RequestLogStore(directoryProvider: () async => directory);
    final c =
        MaintenanceController(
            testToken: () => 'only-local-test',
            logStore: store,
          )
          ..settings = ConnectionSettings(
            baseUrl: 'http://127.0.0.1:${server.port}',
            loginNo: 'test',
            channel: 'test',
          );
    try {
      await c.search('caseNo', 'CASE', '', '', false);
      c.chooseWork(c.works.single);
      await c.showPdf();
      expect(methods, ['POST', 'POST']);
      expect(paths.last, '/test/un_look');
      expect(Uri.splitQueryString(bodies.last), {
        'bucketName': 'receipt025',
        'objectName': 'CASE.pdf',
        'ext8': '0',
      });
      expect(c.contentType, 'pdf');
      expect(utf8.decode(c.bytes!), '%PDF-1.4\nTEST');
      // 控制器仍运行时读取日志，确认完整文本可读、凭据和文件字节未落盘。
      final content = await File(store.path!).readAsString();
      final records = const LineSplitter()
          .convert(content)
          .map(jsonDecode)
          .toList();
      expect(records, hasLength(2));
      expect(records.first['response'], contains('CASE'));
      expect(records.last['response'], contains('二进制文件'));
      expect(content, isNot(contains('only-local-test')));
      expect(content, isNot(contains('%PDF-1.4')));
    } finally {
      c.dispose();
      await server.close(force: true);
    }
  });
}
