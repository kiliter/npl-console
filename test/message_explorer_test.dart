import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:npl_maintenance/ui/file_preview.dart';
import 'package:npl_maintenance/ui/message_explorer.dart';

/// 从报文中的 XML 字段深入 CDATA JSON，验证折叠、搜索及返回根节点。
void main() {
  testWidgets('字段逐层专注、折叠、搜索及面包屑返回', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    final source = jsonEncode({
      'body': '<root><payload><![CDATA[{"phone":"123"}]]></payload></root>',
      'other': 'untouched',
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MessageExplorer(text: source)),
      ),
    );
    await tester.tap(find.text('折叠字段'));
    await tester.pump();
    expect(find.text('专注'), findsOneWidget);
    await tester.tap(find.text('展开字段'));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('key-search')), 'body');
    await tester.pump();
    expect(find.text('专注'), findsOneWidget);
    await tester.tap(find.text('专注'));
    await tester.pump();
    expect(find.textContaining('XML ·'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('key-search')), 'payload');
    await tester.pump();
    await tester.tap(find.text('专注'));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('key-search')), 'phone');
    await tester.enterText(find.byKey(const ValueKey('keyword-search')), '123');
    await tester.pump();
    expect(find.text('专注'), findsOneWidget);
    await tester.tap(find.text('原始报文'));
    await tester.pump();
    expect(find.text('专注'), findsNWidgets(3));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(null);
  });
  testWidgets('手机紧凑工具栏与全屏保持专注上下文', (tester) async {
    tester.view.physicalSize = const Size(390, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = MessageSession();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FilePreview(
            bytes: utf8.encode('{"user":{"phone":"123"}}'),
            type: 'text',
            name: 'sample.txt',
            messageSession: session,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('message-tools')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('key-search')), 'user');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('message-tools')));
    await tester.pump();
    await tester.tap(find.text('专注'));
    await tester.pump();
    expect(session.frames.last.name, 'user');
    await tester.tap(find.byKey(const ValueKey('preview-fullscreen')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byWidgetPredicate((w) => w is FilePreview && w.fullscreen),
        matching: find.text('user'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('退出全屏'));
    await tester.pumpAndSettle();
    expect(find.text('user'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(null);
  });
}
