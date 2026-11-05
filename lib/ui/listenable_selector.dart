import 'package:flutter/widgets.dart';

/// 只在关心的状态变化时重建的监听组件。
///
/// 控制器是单一 ChangeNotifier，任何字段变化（状态条、接口记录、图片进度）
/// 都会通知全部监听者。本组件每次收到通知只执行一次轻量的 [selector]，
/// 选出值与上次相等（==）时跳过重建，从而把重建限制在真正受影响的局部。
///
/// [selector] 应返回不可变值或记录（record）；列表等可变集合请连同长度、
/// 版本号一起返回，避免原地修改后判定为“未变化”。
class ListenableSelector<T> extends StatefulWidget {
  final Listenable listenable;
  final T Function() selector;
  final Widget Function(BuildContext context, T value) builder;

  const ListenableSelector({
    super.key,
    required this.listenable,
    required this.selector,
    required this.builder,
  });

  @override
  State<ListenableSelector<T>> createState() => _ListenableSelectorState<T>();
}

class _ListenableSelectorState<T> extends State<ListenableSelector<T>> {
  late T _value = widget.selector();

  @override
  void initState() {
    super.initState();
    widget.listenable.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant ListenableSelector<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.listenable, widget.listenable)) {
      oldWidget.listenable.removeListener(_changed);
      widget.listenable.addListener(_changed);
    }
    // 父级重建时 selector 闭包可能依赖新的局部状态，重新取值保证一致。
    _value = widget.selector();
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    final next = widget.selector();
    if (next == _value) return;
    setState(() => _value = next);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _value);
}
