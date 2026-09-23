import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:npl_maintenance/core/request_log_store.dart';

void main() {
  test('并发追加保持完整 JSON 行，应用退出前即可读取中文和换行内容', () async {
    final directory = await Directory.systemTemp.createTemp('npl-log-test-');
    addTearDown(() => directory.delete(recursive: true));
    final store = RequestLogStore(directoryProvider: () async => directory);
    await Future.wait([
      for (var i = 0; i < 8; i++)
        store.append({'index': i, 'response': '报文\n第二行'}),
    ]);
    final rows = await File(store.path!).readAsLines();
    expect(rows, hasLength(8));
    expect(
      rows.map((row) => jsonDecode(row)['index']),
      orderedEquals(List.generate(8, (i) => i)),
    );
    expect(jsonDecode(rows.first)['response'], '报文\n第二行');
    expect(store.error, isNull);
  });

  test('目录失败可诊断且后续写入可以恢复', () async {
    final directory = await Directory.systemTemp.createTemp('npl-log-retry-');
    addTearDown(() => directory.delete(recursive: true));
    var fail = true;
    final store = RequestLogStore(
      directoryProvider: () async {
        if (fail) throw const FileSystemException('不可回显的细节');
        return directory;
      },
    );
    await store.append({'event': 'first'});
    expect(store.error, contains('FileSystemException'));
    expect(store.error, isNot(contains('不可回显')));
    fail = false;
    await store.append({'event': 'retry'});
    expect(store.error, isNull);
    expect(
      jsonDecode(await File(store.path!).readAsString())['event'],
      'retry',
    );
  });
}
