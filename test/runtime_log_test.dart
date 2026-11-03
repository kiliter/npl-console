import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:npl_maintenance/core/request_log_store.dart';
import 'package:npl_maintenance/core/runtime_log.dart';

void main() {
  test('运行日志独立落盘，记录调用栈并隐藏常见凭据', () async {
    final directory = await Directory.systemTemp.createTemp('runtime-log-');
    addTearDown(() => directory.delete(recursive: true));
    final log = RuntimeLog(
      store: RequestLogStore(
        directoryProvider: () async => directory,
        folderName: 'runtime-logs',
        filePrefix: 'runtime',
      ),
    );
    addTearDown(log.dispose);
    await log.write(
      '控制台',
      message:
          'password="private value" authorization: Bearer abc123 token=secret123 '
          'eyJhbGci.eyJzdWI.signature\n-----BEGIN PRIVATE KEY-----\nprivate\n-----END PRIVATE KEY-----',
    );
    log.failure(
      '未处理异常',
      const FormatException('不能记录的业务正文'),
      StackTrace.current,
    );
    await log.write('写入完成');
    final text = await File(log.store.path!).readAsString();
    expect(log.store.path, contains('runtime-logs/runtime-'));
    for (final secret in [
      'private value',
      'abc123',
      'secret123',
      'eyJhbGci',
      '不能记录的业务正文',
      'BEGIN PRIVATE',
    ]) {
      expect(text, isNot(contains(secret)));
    }
    final rows = text.trim().split('\n').map(jsonDecode);
    final error = rows.singleWhere((r) => r['事件'] == '未处理异常');
    expect(error['消息'], 'FormatException');
    expect(error['调用栈'], isNotEmpty);
  });

  test('运行日志轮转保留数量有界，接口日志不受影响', () async {
    final directory = await Directory.systemTemp.createTemp('runtime-rotate-');
    addTearDown(() => directory.delete(recursive: true));
    final runtime = RequestLogStore(
      directoryProvider: () async => directory,
      folderName: 'runtime-logs',
      filePrefix: 'runtime',
      maxBytes: 30,
      retainedParts: 2,
    );
    final requests = RequestLogStore(directoryProvider: () async => directory);
    await requests.append({'接口': '保留'});
    for (var i = 0; i < 6; i++) {
      await runtime.append({'序号': i, '消息': '用于触发轮转的测试消息'});
    }
    expect(await Directory('${directory.path}/runtime-logs').list().length, 2);
    expect(await File(requests.path!).exists(), isTrue);
    expect(jsonDecode(await File(runtime.path!).readAsString())['序号'], 5);
  });
}
