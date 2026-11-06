import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:npl_maintenance/core/batch_repair/batch_repair.dart';
import 'package:npl_maintenance/core/batch_repair/pdf_objects.dart';
import 'package:npl_maintenance/core/batch_repair/pdf_optimizer.dart';
import 'package:npl_maintenance/core/batch_repair/repair_rules.dart';
import 'package:npl_maintenance/core/contracts.dart';
import 'package:npl_maintenance/core/maintenance_controller.dart';
import 'package:npl_maintenance/core/pdf_editor/pdf_engine.dart';
import 'package:pdfrx/pdfrx.dart';

import 'support/batch_fixtures.dart';
import 'support/pdfium_test_module.dart';

const order = '200000000000000009';
const newCase = '990000000000000002', oldCase = '980000000000000001';

/// 签字页文字（识别为爱知签字页）。
const signTexts = <FixtureText>[
  (text: '本人已经阅读并理解以上业务受理单相关内容，同意办理以下业务：', x: 40, y: 800, size: 11),
  (text: '本人同意所办理的业务采用电子协议模式。', x: 40, y: 200, size: 10),
  (text: '本人签名/经办人签名：', x: 40, y: 70, size: 10),
];
const certA = (
  seed: 1,
  left: 116.6,
  top: 168.8,
  right: 269.5,
  bottom: 374.4,
  alpha: false,
);
const certB = (
  seed: 2,
  left: 370.2,
  top: 168.3,
  right: 532.4,
  bottom: 374.5,
  alpha: false,
);
const signature = (
  seed: 3,
  left: 161.3,
  top: 751.3,
  right: 248.7,
  bottom: 794.9,
  alpha: true,
);

int countImages(Uint8List bytes, String filter) {
  final doc = PdfDocumentModel.parse(bytes);
  return doc.objects.values.where((v) {
    if (v is! PdfStream || (v.dict['Subtype'] as PdfName?)?.value != 'Image') {
      return false;
    }
    final f = doc.resolve(v.dict['Filter']);
    final name = f is List ? (f.isEmpty ? null : f.first) : f;
    return (name as PdfName?)?.value == filter;
  }).length;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    Pdfrx.pdfiumModulePath = pdfiumTestModule();
    await pdfrxInitialize();
  });

  test(
    '一个订单走完全流程：查询 → 下载 → 识别缺失 → 从历史单据补齐 → 压缩 → 复查落盘',
    () async {
      final builder = FixtureBuilder();
      // 最新单据：签字页缺签字，证件只有 A；历史单据：证件 A、B 和签字都有。
      final latest = builder.build([
        (texts: signTexts, images: [certA]),
      ]);
      final older = FixtureBuilder().build([
        (texts: signTexts, images: [certA, certB, signature]),
      ]);
      final requests = <String>[];
      final controller =
          MaintenanceController(
              clientFactory: () => MockClient((request) async {
                requests.add(request.url.path);
                if (request.url.path.endsWith('/api/wo/queryList')) {
                  final body = jsonDecode(request.body) as Map;
                  expect(body['sysAccept'], order);
                  if (body['opMonth'] != recentMonths(3).last) {
                    return http.Response('[]', 200);
                  }
                  return http.Response(
                    jsonEncode([
                      {
                        'caseNo': oldCase,
                        'sysAccept': order,
                        'opTime': '2026-10-01 10:00:00',
                        'regionCode': '14',
                        'ext8': '0',
                      },
                      {
                        'caseNo': newCase,
                        'sysAccept': order,
                        'opTime': '2026-11-05 10:00:00',
                        'regionCode': '14',
                        'ext8': '0',
                      },
                      // 其他订单的同名记录不能混进来。
                      {
                        'caseNo': '970000000000000000',
                        'sysAccept': '200000000000000008',
                        'opTime': '2026-11-06 10:00:00',
                      },
                    ]),
                    200,
                  );
                }
                if (request.url.path.endsWith('/test/un_look')) {
                  final form = Uri.splitQueryString(request.body);
                  expect(form['bucketName'], 'receipt14');
                  return http.Response.bytes(
                    form['objectName'] == '$newCase.pdf' ? latest : older,
                    200,
                  );
                }
                fail('不应调用 ${request.url.path}');
              }),
              testToken: () => 'temporary-test-token',
            )
            ..settings = const ConnectionSettings(
              baseUrl: 'https://example.invalid/npl',
              loginNo: 'test',
              channel: 'test',
            );
      final root = await Directory.systemTemp.createTemp('npl-batch-pipeline-');
      final session = BatchRepairSession(
        controller: controller,
        rootProvider: () async => root,
      );
      addTearDown(() async {
        session.dispose();
        controller.dispose();
        await root.delete(recursive: true);
      });

      await session.start([order, 'bad', order]);
      expect(session.orders, hasLength(1));
      final o = session.orders.single;
      expect(o.status, BatchOrderStatus.repaired, reason: o.message);
      expect(o.target!.caseNo, newCase);
      expect([for (final d in o.history) d.caseNo], [oldCase]);
      expect(o.target!.analysis.pages.single.kind, PdfPageKind.signature);
      expect(
        {for (final i in o.items) i.element},
        {RepairElement.signature, RepairElement.idSlot2},
      );
      expect(o.problems, isEmpty, reason: o.problems.join('；'));
      expect(o.output!.fits, isTrue);
      expect(o.renderDiff, lessThan(.5));
      expect(
        requests.where((p) => p.endsWith('/test/look')),
        isEmpty,
        reason: '修复阶段只读',
      );

      // 落盘文件 = 修复件；证件 B 以 JPEG 原样嵌入（不重新编码成位图）。
      final output = File(o.outputPath!).readAsBytesSync();
      expect(output, o.output!.bytes);
      expect(o.outputPath, endsWith('$newCase-$order.pdf'));
      expect(countImages(output, 'DCTDecode'), 2);
      final check = await session.engine.analyzeDocument(output);
      final images = check.single.images.where((i) => !i.blank).toList();
      expect(images, hasLength(3));
      // 补进来的签字与证件和历史单据是同一张图。
      final source = (await session.engine.analyzeDocument(
        older,
      )).single.images;
      for (final i in images) {
        expect(source.any((s) => samePicture(i, s)), isTrue);
      }

      // 日志与报告。
      final log = File(
        '${session.batchDir!.path}/repair.jsonl',
      ).readAsLinesSync().map((l) => (jsonDecode(l) as Map)['event']).toList();
      expect(log, [
        'batch_start',
        'query',
        'analysis',
        'generated',
        'batch_end',
      ]);
      expect(
        File('${session.batchDir!.path}/report.json').existsSync(),
        isTrue,
      );
      expect(
        File('${session.batchDir!.path}/originals/$newCase.pdf').existsSync(),
        isTrue,
      );

      // 取消勾选签字后重新生成：只补证件。
      session.select(
        o,
        o.items.firstWhere((i) => i.element == RepairElement.signature).id,
        false,
      );
      await session.regenerate(o);
      final partial = (await session.engine.analyzeDocument(
        o.output!.bytes,
      )).single.images.where((i) => !i.blank);
      expect(partial, hasLength(2));
      expect(o.output!.bytes.length, lessThanOrEqualTo(fileLimit));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('最新单据下载失败：订单标为失败，可手动重试成功', () async {
    final builder = FixtureBuilder();
    final latest = builder.build([
      (texts: signTexts, images: [certA, signature]),
    ]);
    var failures = 1;
    final controller =
        MaintenanceController(
            clientFactory: () => MockClient((request) async {
              if (request.url.path.endsWith('/api/wo/queryList')) {
                final body = jsonDecode(request.body) as Map;
                if (body['opMonth'] != recentMonths(3).last) {
                  return http.Response('[]', 200);
                }
                return http.Response(
                  jsonEncode([
                    {
                      'caseNo': newCase,
                      'sysAccept': order,
                      'opTime': '2026-11-05 10:00:00',
                      'regionCode': '14',
                    },
                  ]),
                  200,
                );
              }
              if (failures-- > 0) return http.Response('gateway', 502);
              return http.Response.bytes(latest, 200);
            }),
            testToken: () => 'temporary-test-token',
          )
          ..settings = const ConnectionSettings(
            baseUrl: 'https://example.invalid/npl',
            loginNo: 'test',
            channel: 'test',
          );
    final root = await Directory.systemTemp.createTemp('npl-batch-retry-');
    final session = BatchRepairSession(
      controller: controller,
      rootProvider: () async => root,
    );
    addTearDown(() async {
      session.dispose();
      controller.dispose();
      await root.delete(recursive: true);
    });
    await session.start([order]);
    final o = session.orders.single;
    expect(o.status, BatchOrderStatus.failed);
    expect(o.message, contains('下载失败'));
    await session.retry(o);
    expect(o.status, BatchOrderStatus.ok, reason: o.message);
    expect(o.message, contains('只有这一份单据'));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
