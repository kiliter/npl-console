import 'package:flutter/material.dart';

/// 长文本只读视图：按行切成小块，用 ListView 懒加载排版。
///
/// 单个 SelectableText 承载数 MB 文本时，排版与命中测试都是整段 O(n)，
/// 打开或重建都会卡顿。分块后只排版可见区域，块内及相邻已构建块可选中复制；
/// 需要完整内容时由调用方提供“复制”按钮复制原文。
class LargeTextView extends StatefulWidget {
  final String text;
  final TextStyle style;
  final EdgeInsetsGeometry padding;

  /// 单块最大 UTF-16 长度；优先在换行处切分，超长单行按长度硬切。
  final int blockSize;

  const LargeTextView({
    super.key,
    required this.text,
    required this.style,
    this.padding = const EdgeInsets.all(22),
    this.blockSize = 2048,
  });

  @override
  State<LargeTextView> createState() => _LargeTextViewState();
}

class _LargeTextViewState extends State<LargeTextView> {
  final scroll = ScrollController();
  late List<String> blocks = split(widget.text, widget.blockSize);

  @override
  void didUpdateWidget(covariant LargeTextView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.blockSize != widget.blockSize ||
        !(identical(oldWidget.text, widget.text) ||
            oldWidget.text == widget.text)) {
      blocks = split(widget.text, widget.blockSize);
    }
  }

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  /// 不切断代理对，也不把 CRLF 拆到两块；拼接全部块等于原文。
  static List<String> split(String text, int size) {
    if (text.length <= size) return [text];
    final result = <String>[];
    var start = 0;
    while (start < text.length) {
      var end = start + size;
      if (end >= text.length) {
        result.add(text.substring(start));
        break;
      }
      final newline = text.lastIndexOf('\n', end - 1);
      if (newline >= start + size ~/ 2) {
        end = newline + 1;
      } else {
        final previous = text.codeUnitAt(end - 1);
        if ((previous >= 0xd800 && previous <= 0xdbff) ||
            (previous == 13 && text.codeUnitAt(end) == 10)) {
          end--;
        }
      }
      result.add(text.substring(start, end));
      start = end;
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    // 去掉块末换行，避免 Text 在块尾额外渲染一个空行；块间以列表顺序衔接。
    String display(String block) => block.endsWith('\r\n')
        ? block.substring(0, block.length - 2)
        : block.endsWith('\n')
        ? block.substring(0, block.length - 1)
        : block;
    return Scrollbar(
      controller: scroll,
      child: SelectionArea(
        child: ListView.builder(
          controller: scroll,
          padding: widget.padding,
          itemCount: blocks.length,
          itemBuilder: (context, index) =>
              Text(display(blocks[index]), style: widget.style),
        ),
      ),
    );
  }
}

/// 字段值超过该长度（UTF-16 码元）时，详情面板改用 [LargeFieldText] 分块展示。
/// 普通字段仍用 SelectableText，保持整段连续选中。
const largeFieldThreshold = 20000;

/// 详情列表中的超长字段值（如数 MB 的请求参数、返回详情）：
/// 固定高度、内部独立滚动、按块懒加载，避免整段排版拖慢面板打开和搜索输入。
/// 完整内容请用字段旁的复制按钮获取。
class LargeFieldText extends StatelessWidget {
  final String text;
  final TextStyle style;
  final double height;
  const LargeFieldText({
    super.key,
    required this.text,
    required this.style,
    this.height = 320,
  });

  @override
  Widget build(BuildContext context) => Container(
    height: height,
    decoration: BoxDecoration(
      color: const Color(0xfff7f9fc),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: const Color(0xffe4ebf4)),
    ),
    child: LargeTextView(
      text: text,
      style: style,
      padding: const EdgeInsets.all(10),
    ),
  );
}
