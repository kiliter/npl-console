import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:npl_maintenance/core/contracts.dart';
import 'package:npl_maintenance/core/maintenance_controller.dart';

/// 验证 OBS 上传接口（POST /test/look，multipart/form-data）的请求构造与错误处理。
/// 全部使用模拟 HTTP，绝不访问真实服务；该接口为危险写操作，禁止真实网络测试。
void main() {
  const settings = ConnectionSettings(
    baseUrl: 'https://example.invalid/npl',
    loginNo: 'test',
    channel: 'test',
  );
  MaintenanceController controller(http.BaseClient client) =>
      MaintenanceController(
        clientFactory: () => client,
        testToken: () => 'temporary-test-token',
      )..settings = settings;

  /// 在字节流中查找子序列（MockClient 会把 multipart 请求展平为原始字节，
  /// 无法直接读取 fields/files，只能在报文体字节上断言）。
  bool hasSub(List<int> haystack, List<int> needle) {
    if (needle.length > haystack.length) return false;
    for (var i = 0; i + needle.length <= haystack.length; i++) {
      var match = true;
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) {
          match = false;
          break;
        }
      }
      if (match) return true;
    }
    return false;
  }

  test('成功上传：multipart 字段、文件与鉴权头符合 upload2Obs 契约', () async {
    http.Request? sent;
    final c = controller(
      MockClient((request) async {
        sent = request;
        return http.Response('true', 200);
      }),
    );
    final bytes = Uint8List.fromList([37, 80, 68, 70, 1, 2, 3]);
    await c.uploadFile('fix.pdf', bytes, 'receipt025', 'CASE001.pdf', '0');
    expect(sent, isNotNull);
    expect(sent!.method, 'POST');
    expect(sent!.url.path, '/npl/test/look');
    expect(sent!.headers['kkk'], 'temporary-test-token');
    expect(sent!.headers['agAuthorization'], 'temporary-test-token');
    expect(
      sent!.headers['content-type'],
      startsWith('multipart/form-data; boundary='),
    );
    final body = sent!.bodyBytes;
    expect(
      hasSub(body, utf8.encode('name="bucketName"\r\n\r\nreceipt025')),
      isTrue,
    );
    expect(
      hasSub(body, utf8.encode('name="objectName"\r\n\r\nCASE001.pdf')),
      isTrue,
    );
    expect(hasSub(body, utf8.encode('name="ext8"\r\n\r\n0')), isTrue);
    expect(hasSub(body, utf8.encode('name="file"; filename="fix.pdf"')), isTrue);
    expect(hasSub(body, bytes), isTrue);
    expect(c.error, isFalse);
    expect(c.busy, isFalse);
    expect(c.message, contains('上传成功'));
    expect(c.logs.single.label, 'OBS 文件上传');
    expect(c.logs.single.state, '成功');
    // 日志只记录字段参数与文件名、大小，不得包含文件字节内容。
    expect(c.logs.single.requestBody, contains('fix.pdf'));
    expect(c.logs.single.requestBody, contains('${bytes.length} 字节'));
    c.dispose();
  });

  test('服务端返回 false：视为拒绝上传并报错', () async {
    final c = controller(MockClient((_) async => http.Response('false', 200)));
    await expectLater(
      c.uploadFile('fix.pdf', Uint8List.fromList([1]), 'b', 'o.pdf', '0'),
      throwsA(isA<FormatException>()),
    );
    expect(c.error, isTrue);
    expect(c.busy, isFalse);
    expect(c.logs.single.state, '失败');
    c.dispose();
  });

  test('HTTP 非 2xx：抛出可读错误并标记状态', () async {
    final c = controller(
      // http.Response 字符串体在无 charset 时按 latin1 编码，
      // 中文需显式声明 charset 或改用字节体。
      MockClient(
        (_) async => http.Response.bytes(utf8.encode('拒绝访问'), 403),
      ),
    );
    await expectLater(
      c.uploadFile('fix.pdf', Uint8List.fromList([1]), 'b', 'o.pdf', '0'),
      throwsA(isA<FormatException>()),
    );
    expect(c.error, isTrue);
    expect(c.logs.single.status, 403);
    c.dispose();
  });

  test('桶或对象名为空：直接拒绝且不发出任何请求', () async {
    var requested = false;
    final c = controller(
      MockClient((_) async {
        requested = true;
        return http.Response('true', 200);
      }),
    );
    await expectLater(
      c.uploadFile('fix.pdf', Uint8List.fromList([1]), '', 'o.pdf', '0'),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      c.uploadFile('fix.pdf', Uint8List.fromList([1]), 'b', '  ', '0'),
      throwsA(isA<FormatException>()),
    );
    expect(requested, isFalse);
    c.dispose();
  });

  test('文件内容为空：直接拒绝且不发出任何请求', () async {
    var requested = false;
    final c = controller(
      MockClient((_) async {
        requested = true;
        return http.Response('true', 200);
      }),
    );
    await expectLater(
      c.uploadFile('fix.pdf', Uint8List(0), 'b', 'o.pdf', '0'),
      throwsA(isA<FormatException>()),
    );
    expect(requested, isFalse);
    c.dispose();
  });
}
