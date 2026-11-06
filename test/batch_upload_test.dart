import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:npl_maintenance/core/batch_repair/batch_repair.dart';
import 'package:npl_maintenance/core/batch_repair/pdf_optimizer.dart';
import 'package:npl_maintenance/core/batch_repair/repair_rules.dart';
import 'package:npl_maintenance/core/contracts.dart';
import 'package:npl_maintenance/core/maintenance_controller.dart';

/// 批量上传流程：全部使用模拟 HTTP（example.invalid），绝不访问真实服务。
class FakeObs {
  final objects = <String, Uint8List>{};
  final uploads = <Map<String, Object>>[];

  /// 依次返回的上传响应（状态码、正文）；用完后返回 200 true。
  final replies = <(int, String)>[];

  /// 第几次上传之后，下载返回错误内容（模拟回读不一致）。
  int? corruptAfter;

  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path;
    if (path.endsWith('/test/un_look')) {
      final form = Uri.splitQueryString(request.body);
      final data = objects[form['objectName']];
      if (data == null) return http.Response('not found', 404);
      final corrupt = corruptAfter != null && uploads.length > corruptAfter!;
      final out = corrupt ? Uint8List.fromList([...data, 1]) : data;
      return http.Response.bytes(out, 200);
    }
    if (path.endsWith('/test/look')) {
      final body = request.bodyBytes;
      final text = latin1.decode(body);
      String field(String name) {
        final at = text.indexOf('name="$name"');
        final start = text.indexOf('\r\n\r\n', at) + 4;
        return text.substring(start, text.indexOf('\r\n', start));
      }

      final fileAt = text.indexOf('\r\n\r\n', text.indexOf('name="file"')) + 4;
      final fileEnd = text.lastIndexOf('\r\n--');
      final file = Uint8List.fromList(body.sublist(fileAt, fileEnd));
      uploads.add({
        'objectName': field('objectName'),
        'bucketName': field('bucketName'),
        'ext8': field('ext8'),
        'size': file.length,
      });
      final (status, reply) = replies.isEmpty
          ? (200, 'true')
          : replies.removeAt(0);
      if (status == 200 && reply == 'true') objects[field('objectName')] = file;
      return http.Response(reply, status);
    }
    return http.Response('[]', 200);
  }
}

Uint8List pdf(String tag, [int size = 2000]) => Uint8List.fromList([
  ...latin1.encode('%PDF-1.7 $tag '),
  ...List.filled(size, 32),
]);

void main() {
  late Directory root;
  late FakeObs obs;
  late MaintenanceController controller;
  late BatchRepairSession session;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('npl-batch-upload-');
    obs = FakeObs();
    controller =
        MaintenanceController(
            clientFactory: () => MockClient(obs.handle),
            testToken: () => 'temporary-test-token',
          )
          ..settings = const ConnectionSettings(
            baseUrl: 'https://example.invalid/npl',
            loginNo: 'test',
            channel: 'test',
          );
    session = BatchRepairSession(
      controller: controller,
      rootProvider: () async => root,
    );
    session.batchDir = Directory('${root.path}/batch')
      ..createSync(recursive: true);
  });
  tearDown(() async {
    session.dispose();
    controller.dispose();
    await root.delete(recursive: true);
  });

  /// 一个已生成修复件的订单：线上与分析时的原件一致。
  BatchOrder order(String number, String caseNo, {int size = 2000}) {
    final original = pdf('original-$caseNo'),
        repaired = pdf('repaired-$caseNo', size);
    obs.objects['$caseNo.pdf'] = original;
    final o = BatchOrder(number)
      ..target = BatchDocument(
        {
          'caseNo': caseNo,
          'sysAccept': number,
          'regionCode': '14',
          'ext8': '2',
        },
        original,
        RepairDocument(caseNo, '', const []),
      )
      ..output = OptimizeResult(repaired, 0, repaired.length)
      ..outputPath = '${session.batchDir!.path}/$caseNo-$number.pdf'
      ..status = BatchOrderStatus.repaired;
    File(o.outputPath!).writeAsBytesSync(repaired);
    session.orders.add(o);
    return o;
  }

  List<String> events(UploadRun run) => [
    for (final line in run.logFile.readAsLinesSync())
      '${(jsonDecode(line) as Map)['event']}',
  ];

  test('完整流程：先备份线上原件，三项确认齐全才上传，回读一致才算成功', () async {
    final a = order('200000000000000001', '900000000000000001');
    final run = await session.prepareUpload([a]);
    expect(run.state, UploadRunState.ready);
    final f = run.files.single;
    expect(f.status, UploadFileStatus.ready);
    expect(f.target, {
      'bucketName': 'receipt14',
      'objectName': '900000000000000001.pdf',
      'ext8': '2',
    });
    expect(
      File(f.backup).readAsBytesSync(),
      a.target!.bytes,
      reason: '备份必须是线上当前文件',
    );
    expect(obs.uploads, isEmpty, reason: '准备阶段只读');
    expect(run.phrase, '确认上传1份');
    for (final bad in [
      () => session.startUpload(
        run,
        targetsConfirmed: false,
        backupConfirmed: true,
        phrase: run.phrase,
      ),
      () => session.startUpload(
        run,
        targetsConfirmed: true,
        backupConfirmed: false,
        phrase: run.phrase,
      ),
      () => session.startUpload(
        run,
        targetsConfirmed: true,
        backupConfirmed: true,
        phrase: '确认上传',
      ),
    ]) {
      await expectLater(bad(), throwsA(isA<FormatException>()));
    }
    expect(obs.uploads, isEmpty, reason: '确认不完整时不能上传');
    await session.startUpload(
      run,
      targetsConfirmed: true,
      backupConfirmed: true,
      phrase: run.phrase,
    );
    expect(run.state, UploadRunState.done);
    expect(f.status, UploadFileStatus.uploaded);
    expect(obs.objects['900000000000000001.pdf'], a.output!.bytes);
    expect(events(run), [
      'prepare_start',
      'backup_saved',
      'prepare_done',
      'confirmed',
      'upload_request',
      'upload_response',
      'readback',
      'batch_end',
    ]);
    final log = run.logFile.readAsStringSync();
    expect(log.contains('temporary-test-token'), isFalse, reason: '日志不得包含 JWT');
    expect(File('${run.dir.path}/summary.json').existsSync(), isTrue);
    expect(session.historyFile.readAsStringSync(), contains('"readback"'));
    // 确认只能用一次。
    await expectLater(
      session.startUpload(
        run,
        targetsConfirmed: true,
        backupConfirmed: true,
        phrase: run.phrase,
      ),
      throwsA(isA<FormatException>()),
    );
    // 已上传的按上传历史剔除。
    expect(session.uploaded(a), isNotNull);
    final again = await session.prepareUpload([a]);
    expect(again.files.single.status, UploadFileStatus.skipped);
    expect(again.files.single.reason, contains('已于'));
  });

  test('某一份失败（413）不影响后面的，失败后回读确认线上仍是原件，可单独重试', () async {
    final a = order('200000000000000001', '900000000000000001');
    final b = order('200000000000000002', '900000000000000002');
    obs.replies.add((413, '<html>413 Request Entity Too Large</html>'));
    final run = await session.prepareUpload([a, b]);
    await session.startUpload(
      run,
      targetsConfirmed: true,
      backupConfirmed: true,
      phrase: run.phrase,
    );
    expect(run.state, UploadRunState.partial);
    expect(
      [for (final f in run.files) f.status],
      [UploadFileStatus.failed, UploadFileStatus.uploaded],
    );
    expect(run.files.first.result, contains('2MB'));
    expect(run.files.first.online, contains('原件'));
    expect(obs.objects['900000000000000001.pdf'], a.target!.bytes);
    expect(events(run), contains('check_after_failure'));
    // 重试：新批次里只剩失败的那份，成功的被剔除。
    final retry = await session.prepareUpload([a, b]);
    expect(
      [for (final f in retry.files) f.status],
      [UploadFileStatus.ready, UploadFileStatus.skipped],
    );
    expect(retry.phrase, '确认上传1份');
    await session.startUpload(
      retry,
      targetsConfirmed: true,
      backupConfirmed: true,
      phrase: retry.phrase,
    );
    expect(retry.files.first.status, UploadFileStatus.uploaded);
  });

  test('服务端返回 false 或回读不一致都判失败', () async {
    final a = order('200000000000000001', '900000000000000001');
    obs.replies.add((200, 'false'));
    var run = await session.prepareUpload([a]);
    await session.startUpload(
      run,
      targetsConfirmed: true,
      backupConfirmed: true,
      phrase: run.phrase,
    );
    expect(run.files.single.status, UploadFileStatus.failed);
    expect(run.files.single.result, contains('未返回 true'));
    run = await session.prepareUpload([a]);
    obs.corruptAfter = obs.uploads.length;
    await session.startUpload(
      run,
      targetsConfirmed: true,
      backupConfirmed: true,
      phrase: run.phrase,
    );
    expect(run.files.single.status, UploadFileStatus.failed);
    expect(run.files.single.result, contains('回读内容'));
    expect(session.uploaded(a), isNull);
  });

  test('线上文件被他人改动、修复件超过 2MB、修复件被改动：准备阶段拦下，不发送', () async {
    final a = order('200000000000000001', '900000000000000001');
    obs.objects['900000000000000001.pdf'] = pdf('changed');
    final big = order(
      '200000000000000002',
      '900000000000000002',
      size: fileLimit + 10,
    );
    final touched = order('200000000000000003', '900000000000000003');
    File(touched.outputPath!).writeAsBytesSync(pdf('edited'));
    final run = await session.prepareUpload([a, big, touched]);
    expect(run.state, UploadRunState.blocked);
    expect(run.files[0].reason, contains('不一致'));
    expect(run.files[1].reason, contains('2MB'));
    expect(run.files[2].reason, contains('改动'));
    expect(obs.uploads, isEmpty);
  });

  test('停止后续上传：当前这份完成后，其余标为未上传', () async {
    final a = order('200000000000000001', '900000000000000001');
    final b = order('200000000000000002', '900000000000000002');
    final run = await session.prepareUpload([a, b]);
    final started = session.startUpload(
      run,
      targetsConfirmed: true,
      backupConfirmed: true,
      phrase: run.phrase,
    );
    session.stopUpload();
    await started;
    expect(run.state, UploadRunState.stopped);
    expect(run.files.last.status, UploadFileStatus.cancelled);
  });
}
