import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:npl_maintenance/core/contracts.dart';
import 'package:npl_maintenance/core/log_batch.dart';
import 'package:npl_maintenance/core/log_files.dart';
import 'package:npl_maintenance/core/maintenance_controller.dart';
import 'package:npl_maintenance/core/request_log_store.dart';

/// 批量下载全部使用模拟 HTTP，不访问真实服务。
void main() {
  Map<String, Object> entry(String path, int size, {String type = 'FILE'}) => {
    'path': path,
    'type': type,
    'size': size,
    'lastModified': '2026-10-15 10:00:00',
    'fileKey': 'key-$path',
  };
  final instances = [
    LogInstance.fromJson({
      'instance': '10.0.0.1:8080',
      'pod': 'svc-0',
      'status': 'OK',
      'entries': [
        entry('biz', 0, type: 'DIR'),
        entry('app.2026-10-15.log', 3),
        entry('app.2026-10-14.log', 3),
      ],
    }),
    LogInstance.fromJson({
      'instance': '10.0.0.2:8080',
      'pod': 'svc-1',
      'status': 'OK',
      'entries': [entry('app.2026-10-15.log', 3)],
    }),
    LogInstance.fromJson({
      'instance': '10.0.0.3:8080',
      'pod': 'svc-2',
      'status': 'TIMEOUT',
      'entries': [entry('app.2026-10-15.log', 3)],
    }),
  ];

  test('按 ls 通配符整名匹配正常副本中的文件，跳过目录和异常副本', () {
    String names(String pattern) => matchLogFiles(
      instances,
      pattern,
    ).map((t) => '${t.instance.pod}/${t.entry.path}').join(',');
    expect(
      names('*2026-10-15*'),
      'svc-0/app.2026-10-15.log,svc-1/app.2026-10-15.log',
    );
    // 整名匹配：不带 * 时不做部分匹配；`.` 按字面量处理。
    expect(names('2026-10-15'), isEmpty);
    expect(names('app?2026-10-14.log'), 'svc-0/app.2026-10-14.log');
    expect(names('app.2026-10-1[4].log'), 'svc-0/app.2026-10-14.log');
    expect(names('app.2026-10-1[!4].log'), contains('2026-10-15'));
    expect(names('*.LOG'), isEmpty);
    // 空格分隔多个模式，命中任一即可；目录不参与匹配。
    expect(matchLogFiles(instances, '*14.log  *15.log'), hasLength(3));
    expect(names('biz'), isEmpty);
    expect(globToRegExp('a[b').hasMatch('a[b'), isTrue);
    expect(
      () => matchLogFiles(instances, '  '),
      throwsA(isA<FormatException>()),
    );
  });

  test('逐个下载并按 Pod 分目录打包，单个失败继续并写入失败清单', () async {
    final directory = await Directory.systemTemp.createTemp('npl-log-batch-');
    addTearDown(() => directory.delete(recursive: true));
    final instancesCalled = <String>[];
    final c =
        MaintenanceController(
            clientFactory: () => MockClient((request) async {
              final instance = request.url.queryParameters['instance']!;
              instancesCalled.add(instance);
              if (instance == '10.0.0.2:8080') {
                return http.Response.bytes(
                  utf8.encode(
                    jsonEncode({'resultCode': '404', 'resultDesc': '文件不存在'}),
                  ),
                  404,
                );
              }
              return http.Response.bytes(
                utf8.encode('abc'),
                200,
                headers: {
                  'content-type': 'application/octet-stream',
                  'x-file-size': '3',
                  'x-chunk-offset': '0',
                },
              );
            }),
            testToken: () => 'temporary-test-token',
            logStore: RequestLogStore(directoryProvider: () async => directory),
          )
          ..settings = const ConnectionSettings(
            baseUrl: 'https://server.invalid',
            loginNo: 'test',
            channel: 'test',
          );
    final targets = matchLogFiles(instances, '*.log');
    final result = await downloadLogBatch(
      LogFileClient(c, LogApp.server),
      targets,
      Directory('${directory.path}/batch'),
    );
    expect(instancesCalled, [
      '10.0.0.1:8080',
      '10.0.0.1:8080',
      '10.0.0.2:8080',
    ]);
    expect(result.succeeded, 2);
    expect(result.failures.single, contains('文件不存在'));
    final files = result.folder
        .listSync(recursive: true)
        .whereType<File>()
        .map((f) => f.path.substring(result.folder.path.length + 1))
        .toSet();
    expect(files, {
      'svc-0/app.2026-10-15.log',
      'svc-0/app.2026-10-14.log',
      '下载失败清单.txt',
    });
    expect(
      File('${result.folder.path}/svc-0/app.2026-10-15.log').readAsStringSync(),
      'abc',
    );
    expect(
      File('${result.folder.path}/下载失败清单.txt').readAsStringSync(),
      contains('svc-1'),
    );
    c.dispose();
  });
}
