import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:npl_maintenance/core/maintenance_controller.dart';
import 'package:npl_maintenance/main.dart';

/// 手机独立查询面板、键盘压缩和选择工单后的分类必须可操作。
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('手机搜索独立展示，月份范围校验和详情导航不溢出', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = MaintenanceController();
    await tester.pumpWidget(MaintenanceApp(controller: c));
    expect(find.byType(NavigationBar), findsNothing);
    await tester.tap(find.byKey(const ValueKey('mobile-search')));
    await tester.pumpAndSettle();
    expect(find.text('查找工单').hitTestable(), findsOneWidget);
    expect(find.text('单月'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('query-value')), '123');
    await tester.tap(find.text('查询工单'));
    await tester.pumpAndSettle();
    expect(find.text('请输入 11 位手机号码'), findsOneWidget);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('查询工单').hitTestable(), findsOneWidget);
    tester.view.resetViewInsets();
    await tester.tap(find.byTooltip('关闭查询'));
    await tester.pumpAndSettle();
    c.chooseWork({'caseNo': 'DEMO', 'opMonth': '202609', 'ext1': null});
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('field-search')), 'ext1');
    await tester.pumpAndSettle();
    // 搜索 ext1 同时匹配保留的 ext1 和 ext10。
    expect(find.text('未提供'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}
