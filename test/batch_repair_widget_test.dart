import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:npl_maintenance/core/batch_repair/batch_repair.dart';
import 'package:npl_maintenance/core/batch_repair/pdf_optimizer.dart';
import 'package:npl_maintenance/core/batch_repair/repair_rules.dart';
import 'package:npl_maintenance/core/contracts.dart';
import 'package:npl_maintenance/core/maintenance_controller.dart';
import 'package:npl_maintenance/ui/batch_repair/batch_repair_screen.dart';
import 'package:npl_maintenance/ui/batch_repair/upload_dialog.dart';

/// 界面测试：全部使用模拟 HTTP，绝不访问真实服务。
void main() {
  late Directory root;
  late MaintenanceController controller;
  late BatchRepairSession session;
  final uploads = <String>[];
  final online = <String, Uint8List>{};

  setUp(() async {
    uploads.clear();
    online.clear();
    root = Directory.systemTemp.createTempSync('npl-batch-widget-');
    controller =
        MaintenanceController(
            clientFactory: () => MockClient((request) async {
              if (request.url.path.endsWith('/test/un_look')) {
                return http.Response.bytes(
                  online[Uri.splitQueryString(request.body)['objectName']]!,
                  200,
                );
              }
              if (request.url.path.endsWith('/test/look')) {
                uploads.add(request.url.path);
                final text = latin1.decode(request.bodyBytes);
                final at =
                    text.indexOf(
                      '\r\n\r\n',
                      text.indexOf('name="objectName"'),
                    ) +
                    4;
                final name = text.substring(at, text.indexOf('\r\n', at));
                final fileAt =
                    text.indexOf('\r\n\r\n', text.indexOf('name="file"')) + 4;
                online[name] = Uint8List.fromList(
                  request.bodyBytes.sublist(fileAt, text.lastIndexOf('\r\n--')),
                );
                return http.Response('true', 200);
              }
              return http.Response('[]', 200);
            }),
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
  });
  tearDown(() {
    session.dispose();
    controller.dispose();
    root.deleteSync(recursive: true);
  });

  /// 真实文件读写在测试的假时间区里只有 pump 时才继续：交替真实等待与 pump。
  Future<void> waitFor(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(done(), isTrue);
  }

  Future<void> pump(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(1500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  }

  testWidgets('订单号表单：粘贴多个自动拆行，新增、校验，提交按钮显示有效数量', (tester) async {
    await pump(
      tester,
      BatchRepairScreen(controller: controller, session: session),
    );
    await tester.enterText(
      find.byKey(const ValueKey('order-input-0')),
      '200664218695020220、200664217227727232 其他',
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('order-input-1')), findsOneWidget);
    expect(find.text('提交（2）'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('order-add')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('order-input-2')),
      '12345',
    );
    await tester.pump();
    expect(find.text('不是订单号'), findsOneWidget);
    expect(find.text('提交（2）'), findsOneWidget);
    // 没有订单时上传按钮不可用。
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('batch-upload')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('上传对话框：三步确认都完成、手动输入口令后才上传', (tester) async {
    session.batchDir = Directory('${root.path}/batch')
      ..createSync(recursive: true);
    const caseNo = '900000000000000001', number = '200000000000000001';
    final original = Uint8List.fromList(latin1.encode('%PDF-1.7 original'));
    final repaired = Uint8List.fromList(latin1.encode('%PDF-1.7 repaired'));
    online['$caseNo.pdf'] = original;
    final o = BatchOrder(number)
      ..target = BatchDocument(
        {
          'caseNo': caseNo,
          'sysAccept': number,
          'regionCode': '14',
          'ext8': '0',
        },
        original,
        const RepairDocument(caseNo, '', []),
      )
      ..output = OptimizeResult(repaired, 0, repaired.length)
      ..outputPath = '${session.batchDir!.path}/$caseNo-$number.pdf'
      ..status = BatchOrderStatus.repaired;
    File(o.outputPath!).writeAsBytesSync(repaired);
    session.orders.add(o);

    await pump(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showUploadDialog(context, session),
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('upload-prepare')));
    await waitFor(
      tester,
      () => find.textContaining('逐行核对上传目标').evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    expect(
      find.text('逐行核对上传目标。标红的行不会上传。批次 ${session.upload!.id}'),
      findsOneWidget,
    );
    FilledButton button(String key) =>
        tester.widget<FilledButton>(find.byKey(ValueKey(key)));
    expect(button('upload-next-backups').onPressed, isNull);
    await tester.tap(find.byKey(const ValueKey('upload-check-targets')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('upload-next-backups')));
    await tester.pumpAndSettle();
    expect(button('upload-next-confirm').onPressed, isNull);
    await tester.tap(find.byKey(const ValueKey('upload-check-backups')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('upload-next-confirm')));
    await tester.pumpAndSettle();
    expect(button('upload-start').onPressed, isNull);
    // 粘贴被屏蔽。
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') return {'text': '确认上传1份'};
        if (call.method == 'Clipboard.hasStrings') return {'value': true};
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('upload-phrase')));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(button('upload-start').onPressed, isNull);
    await tester.enterText(
      find.byKey(const ValueKey('upload-phrase')),
      '确认上传1份',
    );
    await tester.pump();
    expect(uploads, isEmpty);
    await tester.tap(find.byKey(const ValueKey('upload-start')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('upload-final-confirm')));
    await waitFor(
      tester,
      () =>
          find.text('全部上传完成').evaluate().isNotEmpty &&
          !session.upload!.files.any(
            (f) => f.status == UploadFileStatus.uploading,
          ),
    );
    await tester.pumpAndSettle();
    expect(uploads, hasLength(1));
    expect(find.text('全部上传完成'), findsOneWidget);
    expect(online['$caseNo.pdf'], repaired);
  });
}
