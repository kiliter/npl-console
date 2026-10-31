import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:npl_maintenance/core/contracts.dart';
import 'package:npl_maintenance/core/maintenance_controller.dart';
import 'package:npl_maintenance/core/request_log_store.dart';
import 'package:npl_maintenance/ui/table_query_sheet.dart';

class MemoryLogStore extends RequestLogStore {
  final records = <Map<String, Object?>>[];

  @override
  Future<void> append(Map<String, Object?> record) async {
    records.add(record);
  }
}

// compute 使用真实 isolate；pumpAndSettle 本身不能等待其消息完成。
Future<void> waitForDecryption(WidgetTester tester) async {
  await tester.pump();
  final dynamic state = tester.state(find.byType(TableQuerySheet));
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (state.decrypting as bool) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('等待本地解密超时');
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
}

void main() {
  testWidgets('窄屏查询、解密、详情及清除密钥，原始日志不含本地明文', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const key = '0123456789abcdef';
    const cipher =
        'SM4:P5LJ4hZbtVbcXkRGTCKTg+wTK95NItvUa82Z0rygPX47fY5X7jfGUAgqyhU8Fbo1';
    const plain = '签字识别通过：{"result":0}';
    final requests = <http.Request>[];
    final logStore = MemoryLogStore();
    final controller =
        MaintenanceController(
            logStore: logStore,
            clientFactory: () => MockClient((request) async {
              requests.add(request);
              return http.Response(
                jsonEncode([
                  {'caseNo': 'CASE', 'retMsg': cipher, 'paramInt': '原始明文'},
                ]),
                200,
                headers: {'content-type': 'application/json; charset=utf-8'},
              );
            }),
            testToken: () => 'test',
          )
          ..settings = const ConnectionSettings(
            baseUrl: 'https://example.invalid/npl',
            loginNo: 'test',
            channel: 'test',
          );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TableQuerySheet(controller: controller)),
      ),
    );
    await tester.tap(find.byType(DropdownButtonFormField<TableKind>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('接口结果表（SYS_INTER_RESULT）').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'CASE');
    await tester.enterText(find.byType(TextField).at(2), 'signcheck');
    await tester.ensureVisible(find.byType(TextField).at(4));
    await tester.enterText(find.byType(TextField).at(4), key);
    await tester.tap(find.text('查询接口结果表'));
    await waitForDecryption(tester);
    await tester.pumpAndSettle();
    expect(requests.single.url.path, '/npl/api/inter/result/queryList');
    expect(jsonDecode(requests.single.body), {
      'caseNo': 'CASE',
      'interUrl': 'signcheck',
    });
    expect(controller.logs.single.response, contains(cipher));
    expect(controller.logs.single.response, isNot(contains(plain)));
    expect(controller.logs.single.requestBody, isNot(contains(key)));
    expect(jsonEncode(logStore.records), isNot(contains(key)));
    expect(jsonEncode(logStore.records), isNot(contains(plain)));
    expect(find.text('已本地解密 1 个字段；复制详情将包含明文'), findsOneWidget);
    final resultCell = find.descendant(
      of: find.byType(DataTable),
      matching: find.text('CASE'),
    );
    await tester.ensureVisible(resultCell);
    await tester.tap(resultCell);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(SelectableText, plain), findsOneWidget);
    Navigator.of(tester.element(find.byType(AlertDialog))).pop();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('清除密钥及明文'));
    await tester.tap(find.text('清除密钥及明文'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField).at(4)).controller!.text,
      '',
    );
    expect(find.text(plain), findsNothing);
    expect(find.text('已清除密钥并恢复原始结果'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
  for (final action in ['清除密钥', '修改密钥', '切换表', '重新查询', '关闭']) {
    testWidgets('真实 compute 进行中$action 后丢弃旧结果', (tester) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // 仅使用运行时生成的虚构密钥和无效测试密文，不含业务敏感数据。
      final syntheticKey = List.filled(16, 'x').join();
      var queryCount = 0;
      final logStore = MemoryLogStore();
      final controller =
          MaintenanceController(
              logStore: logStore,
              clientFactory: () => MockClient(
                (_) async => http.Response(
                  jsonEncode(
                    queryCount++ == 0
                        ? [
                            {
                              'caseNo': 'CASE',
                              'retMsg': 'SM4:invalid-test-fixture',
                            },
                          ]
                        : [
                            {'caseNo': 'NEW', 'retMsg': '新查询结果'},
                          ],
                  ),
                  200,
                  headers: {'content-type': 'application/json; charset=utf-8'},
                ),
              ),
              testToken: () => 'test',
            )
            ..settings = const ConnectionSettings(
              baseUrl: 'https://example.invalid/npl',
              loginNo: 'test',
              channel: 'test',
            );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TableQuerySheet(controller: controller)),
        ),
      );
      tester
          .widget<DropdownButtonFormField<TableKind>>(
            find.byType(DropdownButtonFormField<TableKind>),
          )
          .onChanged!(TableKind.interResult);
      await tester.pump();
      await tester.enterText(find.byType(TextField).first, 'CASE');
      await tester.tap(find.text('查询接口结果表'));
      await tester.pumpAndSettle();
      expect(find.text('检测到 1 个加密字段，请输入密钥后解密'), findsOneWidget);
      await tester.enterText(find.byType(TextField).at(4), syntheticKey);
      final dynamic state = tester.state(find.byType(TableQuerySheet));
      final pending = state.decryptResults() as Future<void>;
      await tester.pump();
      expect(find.text('正在本地解密…'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '本地解密'))
            .onPressed,
        isNull,
      );
      // 先使代次失效，再通过 runAsync 等待真实 isolate 完成。
      switch (action) {
        case '清除密钥':
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, '清除密钥及明文'))
              .onPressed!();
        case '修改密钥':
          final field = tester.widget<TextField>(find.byType(TextField).at(4));
          field.controller!.text = List.filled(16, 'y').join();
          field.onChanged!(field.controller!.text);
        case '切换表':
          tester
              .widget<DropdownButtonFormField<TableKind>>(
                find.byType(DropdownButtonFormField<TableKind>),
              )
              .onChanged!(TableKind.woinfo);
        case '重新查询':
          tester
                  .widget<TextField>(find.byType(TextField).first)
                  .controller!
                  .text =
              'NEW';
          await tester.tap(find.text('查询接口结果表'));
          await tester.pump();
        case '关闭':
          await tester.pumpWidget(const SizedBox());
      }
      var completed = false;
      pending.then((_) => completed = true);
      for (var attempt = 0; !completed && attempt < 1000; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(completed, isTrue);
      await tester.pumpAndSettle();
      expect(find.textContaining('个字段解密失败并保留密文'), findsNothing);
      switch (action) {
        case '清除密钥':
          expect(find.text('已清除密钥并恢复原始结果'), findsOneWidget);
        case '修改密钥':
          expect(find.text('密钥已变更，请重新解密'), findsOneWidget);
        case '切换表':
          expect(find.byType(DataTable), findsNothing);
        case '重新查询':
          expect(find.text('新查询结果'), findsOneWidget);
        case '关闭':
          expect(find.byType(TableQuerySheet), findsNothing);
      }
      expect(jsonEncode(logStore.records), isNot(contains(syntheticKey)));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  }
}
