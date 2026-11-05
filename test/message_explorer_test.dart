import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:npl_maintenance/core/message_document.dart';
import 'package:npl_maintenance/ui/file_preview.dart';
import 'package:npl_maintenance/ui/message_explorer.dart';

/// 从报文中的 XML 字段深入 CDATA JSON，验证折叠、搜索及返回根节点。
void main() {
  // 同一个预览组件接收新报文时，不能继续使用会话里缓存的旧根节点。
  testWidgets('刷新报文后展示新内容并清除旧专注和搜索', (tester) async {
    final session = MessageSession();
    Future<void> show(String text) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageExplorer(text: text, session: session),
        ),
      ),
    );
    await show('旧报文');
    await tester.enterText(find.byKey(const ValueKey('keyword-search')), '旧');
    await show('新报文完整内容');
    expect(session.frames.single.value, '新报文完整内容');
    expect(session.keywordText, isEmpty);
    expect(find.text('新报文完整内容'), findsOneWidget);
  });

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

  group('大报文后台解析过渡态', () {
    final source = jsonEncode({
      'user': {'phone': '123'},
      'body': 'x' * 64,
    });

    testWidgets('超过阈值先显示加载态，后台完成后展示字段树且可专注返回', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final requests = <(Object?, String)>[];
      final pending = <Completer<MessageDocument>>[];
      Future<MessageDocument> parser(Object? input, {String mode = 'auto'}) {
        requests.add((input, mode));
        final completer = Completer<MessageDocument>();
        pending.add(completer);
        return completer.future;
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageExplorer(
              text: source,
              backgroundThreshold: 32,
              backgroundParser: parser,
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('message-parsing')), findsOneWidget);
      expect(find.text('专注'), findsNothing);
      expect(requests.single, (source, 'auto'));
      pending.single.complete(parseMessage(source));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('message-parsing')), findsNothing);
      expect(find.text('专注'), findsWidgets);
      // user 是对象节点，同步专注；返回根节点直接复用已解析文档，不再后台解析。
      await tester.enterText(find.byKey(const ValueKey('key-search')), 'user');
      await tester.pump();
      await tester.tap(find.text('专注'));
      await tester.pump();
      expect(find.byKey(const ValueKey('message-parsing')), findsNothing);
      await tester.tap(find.text('原始报文'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('message-parsing')), findsNothing);
      expect(requests, hasLength(1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('解析中切换为纯文本后，迟到的后台结果被丢弃', (tester) async {
      final completer = Completer<MessageDocument>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageExplorer(
              text: source,
              backgroundThreshold: 32,
              backgroundParser: (input, {mode = 'auto'}) => completer.future,
            ),
          ),
        ),
      );
      await tester.tap(find.text('直接查看纯文本'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('message-parsing')), findsNothing);
      expect(find.byKey(const ValueKey('raw-message-text')), findsOneWidget);
      completer.complete(parseMessage(source));
      await tester.pumpAndSettle();
      // 仍停留在纯文本，没有被旧结果切回字段树。
      expect(find.text('专注'), findsNothing);
      expect(find.byKey(const ValueKey('raw-message-text')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('默认使用真实 isolate 解析超大报文', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final big = jsonEncode({
        'user': {'phone': '123'},
        'list': List.generate(9000, (i) => {'i': i, 'text': '内容$i'}),
      });
      expect(big.length, greaterThan(128 * 1024));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: MessageExplorer(text: big)),
        ),
      );
      expect(find.byKey(const ValueKey('message-parsing')), findsOneWidget);
      for (var i = 0; i < 200; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
        if (find.byKey(const ValueKey('message-parsing')).evaluate().isEmpty) {
          break;
        }
      }
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('message-parsing')), findsNothing);
      expect(find.text('专注'), findsWidgets);
      expect(find.textContaining('JSON ·'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('超长原文改为懒加载列表，只构建可见块', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final text = List.generate(30000, (i) => '第 $i 行纯文本').join('\n');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageExplorer(
              text: text,
              session: MessageSession()..mode = 'text',
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('complete-text-lazy')), findsOneWidget);
      final built = find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('raw-message-block-'),
      );
      expect(built.evaluate().length, lessThan(20));
      expect(tester.takeException(), isNull);
    });
  });
}
