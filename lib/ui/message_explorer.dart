import 'dart:convert';
import 'package:xml/xml.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/message_document.dart';

/// 普通预览与全屏共享字段位置和搜索条件，退出全屏不会丢失阅读上下文。
class MessageSession {
  final frames = <MessageNode>[];
  final collapsed = <String>{}, opened = <String>{};
  String mode = 'auto', keyText = '', keywordText = '';
  bool rawView = false, collapseAll = false, pretty = false;
}

/// 报文解析器：字段折叠、JSON/XML 内嵌内容逐层专注、路径返回与双搜索。
class MessageExplorer extends StatefulWidget {
  final String text;
  final MessageSession? session;
  const MessageExplorer({super.key, required this.text, this.session});
  @override
  State<MessageExplorer> createState() => _MessageExplorerState();
}

class _MessageExplorerState extends State<MessageExplorer> {
  final keySearch = TextEditingController(), keyword = TextEditingController();
  final scroll = ScrollController();
  late final MessageSession session;
  List<MessageNode> get frames => session.frames;
  Set<String> get collapsed => session.collapsed;
  Set<String> get opened => session.opened;
  String get mode => session.mode;
  set mode(String value) => session.mode = value;
  bool get rawView => session.rawView;
  set rawView(bool value) => session.rawView = value;
  bool get collapseAll => session.collapseAll;
  set collapseAll(bool value) => session.collapseAll = value;
  bool get pretty => session.pretty;
  set pretty(bool value) => session.pretty = value;
  bool toolsOpen = false;
  late MessageDocument document;
  @override
  void initState() {
    super.initState();
    session = widget.session ?? MessageSession();
    if (frames.isEmpty) frames.add(MessageNode('原始报文', '', widget.text));
    keySearch.text = session.keyText;
    keyword.text = session.keywordText;
    document = parseMessage(frames.last.value, mode: mode);
  }

  @override
  void dispose() {
    keySearch.dispose();
    keyword.dispose();
    scroll.dispose();
    super.dispose();
  }

  void _parse() {
    document = parseMessage(frames.last.value, mode: mode);
    collapsed.clear();
    opened.clear();
    collapseAll = false;
  }

  void _focus(MessageNode node) => setState(() {
    frames.add(MessageNode(node.name, node.path, node.focusValue));
    mode = 'auto';
    rawView = false;
    pretty = false;
    keySearch.clear();
    keyword.clear();
    session.keyText = session.keywordText = '';
    _parse();
  });
  void _back(int index) => setState(() {
    frames.removeRange(index + 1, frames.length);
    mode = 'auto';
    keySearch.clear();
    keyword.clear();
    session.keyText = session.keywordText = '';
    rawView = false;
    _parse();
  });
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, size) {
      final compact = size.maxWidth < 600 || size.maxHeight < 400;
      return Column(
        children: [
          Container(
            width: double.infinity,
            color: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  const Icon(
                    Icons.account_tree_outlined,
                    size: 17,
                    color: Color(0xff8192a9),
                  ),
                  const SizedBox(width: 6),
                  for (var i = 0; i < frames.length; i++) ...[
                    if (i > 0)
                      const Icon(
                        Icons.chevron_right,
                        size: 15,
                        color: Color(0xff8192a9),
                      ),
                    TextButton(
                      onPressed: i < frames.length - 1 ? () => _back(i) : null,
                      child: Text(frames[i].name),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (compact)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${document.format.toUpperCase()} · 字段可继续专注',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xff8192a9),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '解析与搜索',
                    key: const ValueKey('message-tools'),
                    onPressed: () => setState(() => toolsOpen = !toolsOpen),
                    icon: Icon(
                      toolsOpen
                          ? Icons.filter_alt_off_outlined
                          : Icons.manage_search,
                    ),
                  ),
                ],
              ),
            ),
          if (!compact) _controls(),
          if (compact && toolsOpen)
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: size.maxHeight * .45),
              child: SingleChildScrollView(child: _controls()),
            ),
          if (document.error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                document.error!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.red, fontSize: 12),
              ),
            ),
          Expanded(child: document.structured && !rawView ? _tree() : _text()),
        ],
      );
    },
  );

  Widget _controls() => Padding(
    padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
    child: LayoutBuilder(
      builder: (context, box) => Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 140,
            child: DropdownButtonFormField<String>(
              key: ValueKey('${frames.length}-$mode'),
              initialValue: mode,
              decoration: const InputDecoration(labelText: '解析方式'),
              items: const [
                DropdownMenuItem(value: 'auto', child: Text('自动识别')),
                DropdownMenuItem(value: 'json', child: Text('JSON')),
                DropdownMenuItem(value: 'xml', child: Text('XML')),
                DropdownMenuItem(value: 'text', child: Text('纯文本')),
              ],
              onChanged: (value) => setState(() {
                mode = value!;
                _parse();
              }),
            ),
          ),
          SizedBox(
            width: box.maxWidth > 700 ? 180 : 150,
            child: TextField(
              key: const ValueKey('key-search'),
              controller: keySearch,
              decoration: const InputDecoration(
                labelText: '字段名 / key 搜索',
                prefixIcon: Icon(Icons.key_outlined, size: 16),
              ),
              onChanged: (value) => setState(() => session.keyText = value),
            ),
          ),
          SizedBox(
            width: box.maxWidth > 700 ? 210 : 160,
            child: TextField(
              key: const ValueKey('keyword-search'),
              controller: keyword,
              decoration: const InputDecoration(
                labelText: '内容关键字搜索',
                prefixIcon: Icon(Icons.search, size: 17),
              ),
              onChanged: (value) => setState(() => session.keywordText = value),
            ),
          ),
          if (document.structured)
            TextButton(
              onPressed: () => setState(() => rawView = !rawView),
              child: Text(rawView ? '结构视图' : '原文'),
            ),
          if (document.structured && !rawView)
            TextButton(
              onPressed: () => setState(() {
                collapseAll = !collapseAll;
                collapsed.clear();
                opened.clear();
              }),
              child: Text(collapseAll ? '展开字段' : '折叠字段'),
            ),
          if (rawView && document.structured)
            TextButton(
              onPressed: () => setState(() => pretty = !pretty),
              child: Text(pretty ? '原始格式' : '格式化'),
            ),
          IconButton(
            tooltip: '复制当前专注内容',
            onPressed: () =>
                Clipboard.setData(ClipboardData(text: document.source)),
            icon: const Icon(Icons.copy_outlined, size: 18),
          ),
        ],
      ),
    ),
  );

  Widget _tree() {
    final searching = keySearch.text.isNotEmpty || keyword.text.isNotEmpty;
    final rows = <(MessageNode, int)>[];
    if (searching) {
      rows.addAll(
        searchMessage(
          document.root,
          key: keySearch.text,
          keyword: keyword.text,
        ).map((node) => (node, 0)),
      );
    } else {
      final pending = <(MessageNode, int)>[(document.root, 0)];
      while (pending.isNotEmpty) {
        final row = pending.removeLast();
        rows.add(row);
        final expanded = collapseAll
            ? opened.contains(row.$1.path)
            : !collapsed.contains(row.$1.path);
        if (expanded) {
          pending.addAll(
            row.$1.children.reversed.map((node) => (node, row.$2 + 1)),
          );
        }
      }
    }
    if (rows.isEmpty) return const Center(child: Text('未找到匹配字段'));
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 5),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              searching
                  ? '找到 ${rows.length} 个字段 · 点击“专注”查看内部内容'
                  : '${document.format.toUpperCase()} · 点击箭头折叠，点击“专注”进入字段内容',
              style: const TextStyle(fontSize: 11, color: Color(0xff8192a9)),
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            key: const ValueKey('structured-message'),
            itemCount: rows.length,
            itemBuilder: (context, index) {
              final node = rows[index].$1, depth = rows[index].$2;
              final branch = node.isBranch,
                  expanded = collapseAll
                      ? opened.contains(node.path)
                      : !collapsed.contains(node.path);
              return Container(
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: Color(0xffedf1f6))),
                ),
                child: Padding(
                  padding: EdgeInsets.only(
                    left:
                        10 +
                        (depth >
                                    (MediaQuery.sizeOf(context).width < 600
                                        ? 3
                                        : 12)
                                ? (MediaQuery.sizeOf(context).width < 600
                                      ? 3
                                      : 12)
                                : depth) *
                            12.0,
                    right: 10,
                    top: 3,
                    bottom: 3,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 30,
                        child: branch
                            ? IconButton(
                                padding: EdgeInsets.zero,
                                tooltip: expanded
                                    ? '折叠 ${node.name}'
                                    : '展开 ${node.name}',
                                onPressed: () => setState(() {
                                  if (collapseAll) {
                                    expanded
                                        ? opened.remove(node.path)
                                        : opened.add(node.path);
                                  } else {
                                    expanded
                                        ? collapsed.add(node.path)
                                        : collapsed.remove(node.path);
                                  }
                                }),
                                icon: Icon(
                                  expanded
                                      ? Icons.expand_more
                                      : Icons.chevron_right,
                                  size: 18,
                                ),
                              )
                            : const Icon(
                                Icons.circle,
                                size: 4,
                                color: Color(0xffa7b7cd),
                              ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SelectableText.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: '${node.name}  ',
                                    style: const TextStyle(
                                      color: Color(0xff2869e8),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  TextSpan(text: node.summary),
                                ],
                              ),
                              style: const TextStyle(
                                fontFamily: 'Menlo',
                                fontSize: 12,
                                height: 1.7,
                              ),
                            ),
                            if (searching)
                              Text(
                                node.path.isEmpty ? '/' : node.path,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Color(0xff8b9ab0),
                                  fontSize: 10,
                                ),
                              ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: '复制字段内容',
                        onPressed: () =>
                            Clipboard.setData(ClipboardData(text: node.source)),
                        icon: const Icon(Icons.copy_outlined, size: 15),
                      ),
                      TextButton(
                        onPressed: () => _focus(node),
                        child: const Text('专注', style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _text() {
    var text = document.source;
    if (pretty && document.format == 'json') {
      text = const JsonEncoder.withIndent('  ').convert(document.root.value);
    }
    if (pretty && document.format == 'xml') {
      text = (document.root.value as XmlNode).toXmlString(pretty: true);
    }
    final spans = <TextSpan>[];
    final term = keyword.text;
    var offset = 0, count = 0;
    if (term.isNotEmpty) {
      final value = text.toLowerCase(), target = term.toLowerCase();
      var found = value.indexOf(target);
      while (found >= 0) {
        spans.add(TextSpan(text: text.substring(offset, found)));
        spans.add(
          TextSpan(
            text: text.substring(found, found + term.length),
            style: const TextStyle(backgroundColor: Color(0xffffe8a1)),
          ),
        );
        offset = found + term.length;
        count++;
        found = value.indexOf(target, offset);
      }
    }
    spans.add(TextSpan(text: text.substring(offset)));
    return Column(
      children: [
        if (term.isNotEmpty)
          Text('匹配 $count 处', style: const TextStyle(fontSize: 11)),
        if (keySearch.text.isNotEmpty)
          const Text(
            '字段名搜索仅对解析成功的结构视图生效',
            style: TextStyle(fontSize: 11, color: Color(0xff8192a9)),
          ),
        Expanded(
          child: Scrollbar(
            controller: scroll,
            thumbVisibility: true,
            child: SingleChildScrollView(
              key: const ValueKey('complete-text'),
              controller: scroll,
              padding: const EdgeInsets.all(22),
              child: SizedBox(
                width: double.infinity,
                child: SelectableText.rich(
                  TextSpan(children: spans),
                  style: const TextStyle(
                    fontFamily: 'Menlo',
                    fontSize: 13,
                    height: 1.8,
                    color: Color(0xff36567d),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
