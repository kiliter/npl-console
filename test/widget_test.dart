import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:npl_maintenance/core/maintenance_controller.dart';
import 'package:npl_maintenance/main.dart';

/// 验证桌面初始布局与窄屏收缩，防止关键控制在小窗口溢出。
void main() {
  testWidgets('桌面展示设置、只读分类及空状态', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    final controller = MaintenanceController();
    await tester.pumpWidget(MaintenanceApp(controller: controller));
    expect(find.text('无纸化 / 维护中心'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('查询结果 · 0'), findsOneWidget);
    expect(find.text('签名信息'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.binding.setSurfaceSize(const Size(800, 650));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await tester.binding.setSurfaceSize(null);
  });
}
