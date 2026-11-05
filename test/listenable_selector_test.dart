import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:npl_maintenance/ui/listenable_selector.dart';

class _Model extends ChangeNotifier {
  int watched = 0, other = 0;
  void touch() => notifyListeners();
  bool get listening => hasListeners;
}

/// 局部刷新组件：仅关心的字段变化时重建，监听对象替换后迁移订阅。
void main() {
  testWidgets('仅选择值变化时重建，无关通知跳过', (tester) async {
    final model = _Model();
    var builds = 0;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ListenableSelector<int>(
          listenable: model,
          selector: () => model.watched,
          builder: (context, value) {
            builds++;
            return Text('值 $value');
          },
        ),
      ),
    );
    expect(builds, 1);
    model
      ..other = 5
      ..touch();
    await tester.pump();
    expect(builds, 1);
    model
      ..watched = 2
      ..touch();
    await tester.pump();
    expect(builds, 2);
    expect(find.text('值 2'), findsOneWidget);
    model.dispose();
  });

  testWidgets('替换监听对象后取消旧订阅并按新对象取值', (tester) async {
    final first = _Model()..watched = 1, second = _Model()..watched = 7;
    Widget build(_Model model) => Directionality(
      textDirection: TextDirection.ltr,
      child: ListenableSelector<int>(
        listenable: model,
        selector: () => model.watched,
        builder: (context, value) => Text('值 $value'),
      ),
    );
    await tester.pumpWidget(build(first));
    await tester.pumpWidget(build(second));
    expect(find.text('值 7'), findsOneWidget);
    expect(first.listening, isFalse);
    expect(second.listening, isTrue);
    await tester.pumpWidget(const SizedBox());
    expect(second.listening, isFalse);
    first.dispose();
    second.dispose();
  });
}
