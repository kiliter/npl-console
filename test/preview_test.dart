import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:npl_maintenance/ui/file_preview.dart';

void main() {
  // 使用无换行的超长中文/XML 混合文本，验证实际排版首尾而不只检查字符串。
  testWidgets('长报文每块首尾均可到达，搜索和全屏后无遗漏', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final text = "报文开始${List.filled(3000, '<row>中文业务内容与条款</row>').join()}报文结束";
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FilePreview(
            bytes: utf8.encode(text),
            type: 'text',
            name: '长报文.txt',
          ),
        ),
      ),
    );

    // 字符的实际屏幕坐标必须落在滚动窗口内，首尾才能真正被用户阅读。
    Future<void> verifyEnds() async {
      final view = find.byKey(const ValueKey('complete-text')).last;
      // 正文只能有一个滚动位置，防止内外滚动分别停留在不同位置。
      expect(
        find.descendant(of: view, matching: find.byType(Scrollable)),
        findsOneWidget,
      );
      final widget = tester.widget<SingleChildScrollView>(view);
      final controller = widget.controller!;
      final rich = find.descendant(
        of: find.byKey(const ValueKey('raw-message-text')).last,
        matching: find.byType(RichText),
      );
      final paragraphs = tester
          .renderObjectList<RenderParagraph>(rich)
          .toList();
      expect(paragraphs.map((p) => p.text.toPlainText()).join(), text);
      expect(paragraphs.length, greaterThan(1));
      expect(controller.position.maxScrollExtent, greaterThan(800));
      // 遍历每一块的首尾，覆盖中间所有分块边界，不能只验证报文两端。
      for (final paragraph in paragraphs) {
        final value = paragraph.text.toPlainText();
        expect(value.length, lessThanOrEqualTo(1024));
        expect(paragraph.size.height, lessThan(1000));
        for (final offset in [0, value.length - 1]) {
          final box = paragraph
              .getBoxesForSelection(
                TextSelection(baseOffset: offset, extentOffset: offset + 1),
              )
              .first;
          final point = paragraph.localToGlobal(box.toRect().center);
          controller.jumpTo(
            (controller.offset + point.dy - tester.getRect(view).center.dy)
                .clamp(0, controller.position.maxScrollExtent),
          );
          await tester.pump();
          expect(
            tester
                .getRect(view)
                .contains(paragraph.localToGlobal(box.toRect().center)),
            isTrue,
          );
        }
      }
      controller.jumpTo(0);
      await tester.pump();
    }

    await verifyEnds();
    await tester.enterText(
      find.byKey(const ValueKey('keyword-search')),
      '业务内容',
    );
    await tester.pump();
    await verifyEnds();
    await tester.tap(find.byKey(const ValueKey('preview-fullscreen')));
    await tester.pumpAndSettle();
    await verifyEnds();
    await tester.tap(find.textContaining('退出全屏').first);
    await tester.pumpAndSettle();
    await verifyEnds();
    expect(tester.takeException(), isNull);
  });

  // 覆盖分块边界上的搜索命中、emoji 和换行，避免以修复显示为由丢字。
  testWidgets('跨块关键字保持高亮，emoji 和换行无损', (tester) async {
    final source = '${'甲' * 1023}😀跨块匹配${'乙' * 1015}\r\n结尾';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FilePreview(
            bytes: utf8.encode(source),
            type: 'text',
            name: '边界.txt',
          ),
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('keyword-search')),
      '😀跨块匹配',
    );
    await tester.pump();
    final blocks = tester
        .widgetList<Text>(
          find.descendant(
            of: find.byKey(const ValueKey('raw-message-text')),
            matching: find.byType(Text),
          ),
        )
        .toList();
    expect(blocks.map((b) => b.textSpan!.toPlainText()).join(), source);
    final highlighted = <String>[];
    for (final block in blocks) {
      final text = block.textSpan!.toPlainText();
      expect(text.runes.any((r) => r >= 0xd800 && r <= 0xdfff), isFalse);
      for (final span
          in (block.textSpan! as TextSpan).children!.cast<TextSpan>()) {
        if (span.style?.backgroundColor != null) highlighted.add(span.text!);
      }
    }
    expect(highlighted.join(), '😀跨块匹配');
    expect(tester.takeException(), isNull);
  });

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
          .widgetList<Text>(
            find.descendant(
              of: find.byKey(const ValueKey('raw-message-text')),
              matching: find.byType(Text),
            ),
          )
          .map((w) => w.textSpan!.toPlainText())
          .join(),
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
          .widgetList<Text>(
            find.descendant(
              of: find.byKey(const ValueKey('raw-message-text')),
              matching: find.byType(Text),
            ),
          )
          .map((w) => w.textSpan!.toPlainText())
          .join(),
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
