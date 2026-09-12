import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:npl_maintenance/ui/work_details.dart';
import 'package:npl_maintenance/ui/query_sheet.dart';
import 'package:npl_maintenance/core/maintenance_controller.dart';

/// 完整长值、表字段和范围限制的回归；不调用真实接口。
void main() {
  testWidgets('完整字段搜索包含空值和表字段，长值不截断', (tester) async {
    final longValue = List.filled(80, '完整长内容').join();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkDetails(
            record: {
              'caseNo': 'DEMO',
              'innerJson': longValue,
              'ext1': null,
              'extraBean': 'hidden',
            },
            onDownload: () {},
          ),
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('field-search')),
      'innerJson',
    );
    await tester.pumpAndSettle();
    final text = tester.widget<SelectableText>(
      find.byWidgetPredicate((w) => w is SelectableText && w.data == longValue),
    );
    expect(text.maxLines, isNull);
    await tester.enterText(find.byKey(const ValueKey('field-search')), 'ext1');
    await tester.pumpAndSettle();
    // 搜索 ext1 同时匹配保留的 ext1 和 ext10。
    expect(find.text('未提供'), findsNWidgets(2));
    await tester.enterText(
      find.byKey(const ValueKey('field-search')),
      'hidden',
    );
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate((w) => w is SelectableText && w.data == 'hidden'),
      findsNothing,
    );
    expect(find.text('没有匹配字段，请尝试其他关键词。'), findsOneWidget);
  });
  testWidgets('范围超过十二个月就地拒绝且不请求接口', (tester) async {
    final c = MaintenanceController();
    final draft = QueryDraft()
      ..value = '13800000000'
      ..range = true
      ..start = DateTime(2025, 9)
      ..end = DateTime(2026, 9);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: QuerySheet(controller: c, draft: draft, history: []),
        ),
      ),
    );
    await tester.tap(find.text('查询工单'));
    await tester.pumpAndSettle();
    expect(find.textContaining('范围最多十二个月'), findsOneWidget);
    expect(c.logs, isEmpty);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}
