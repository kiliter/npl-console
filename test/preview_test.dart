import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:npl_maintenance/ui/file_preview.dart';

void main() {
  testWidgets('文本保留全部内容不分页，查找不删减文本，支持全屏和 Esc', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    final text = List.generate(150, (i) => '第 $i 行：原始报文内容').join('\n');
    final fullscreenCalls = <bool>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('cn.agilestar.maintenance/window'),
      (call) async {
        fullscreenCalls.add((call.arguments as Map)['enabled'] as bool);
        return false;
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FilePreview(
            bytes: Uint8List.fromList(utf8.encode(text)),
            type: 'text',
            name: 'sample.txt',
          ),
        ),
      ),
    );
    expect(
      tester
          .widget<SelectableText>(find.byType(SelectableText))
          .textSpan!
          .toPlainText(),
      text,
    );
    expect(find.text('上一页'), findsNothing);
    expect(find.text('下一页'), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('keyword-search')),
      '第 1 行',
    );
    await tester.pump();
    expect(
      tester
          .widget<SelectableText>(find.byType(SelectableText))
          .textSpan!
          .toPlainText(),
      text,
    );
    await tester.tap(find.byKey(const ValueKey('preview-fullscreen')));
    await tester.pumpAndSettle();
    expect(find.text('退出全屏 · Esc'), findsOneWidget);
    expect(fullscreenCalls, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('退出全屏 · Esc'), findsNothing);
    expect(fullscreenCalls, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('cn.agilestar.maintenance/window'),
      null,
    );
    await tester.binding.setSurfaceSize(null);
    debugDefaultTargetPlatformOverride = null;
  });
}
