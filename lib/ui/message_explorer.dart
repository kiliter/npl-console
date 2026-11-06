import 'dart:async';
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

/// 后台解析函数签名，默认使用 [parseMessageInBackground]；测试可注入可控实现。
typedef BackgroundMessageParser =
    Future<MessageDocument> Function(Object? input, {String mode});

/// 报文解析器：字段折叠、JSON/XML 内嵌内容逐层专注、路径返回与双搜索。
///
/// 小报文同步解析；超过 [backgroundThreshold] 的文本报文（原始报文或专注的
/// 字符串字段）在后台 isolate 解析，期间展示加载态，界面保持可操作。
class MessageExplorer extends StatefulWidget {
  final String text;
  final MessageSession? session;
  final int backgroundThreshold;
  final BackgroundMessageParser backgroundParser;
  const MessageExplorer({
    super.key,
    required this.text,
    this.session,
    this.backgroundThreshold = backgroundParseThreshold,
    this.backgroundParser = parseMessageInBackground,
  });
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

  /// 后台解析进行中。此时 [document] 是原文占位，正文区展示加载态。
  bool parsing = false;

  /// 解析代次：切换报文、专注、返回或改解析方式后，旧的后台结果直接丢弃。
  int _parseGeneration = 0;

  @override
  void initState() {
    super.initState();
    session = widget.session ?? MessageSession();
    if (frames.isEmpty) frames.add(MessageNode('原始报文', '', widget.text));
    keySearch.text = session.keyText;
    keyword.text = session.keywordText;
    // 首次进入沿用会话中的折叠状态（如退出全屏），只解析不清空。
    _startParse();
  }

  /// 刷新或切换数据时丢弃旧报文的导航状态，避免界面继续展示缓存内容。
  @override
  void didUpdateWidget(covariant MessageExplorer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.text, widget.text) ||
        oldWidget.text == widget.text) {
      return;
    }
    frames
      ..clear()
      ..add(MessageNode('原始报文', '', widget.text));
    mode = 'auto';
    rawView = pretty = false;
    keySearch.clear();
    keyword.clear();
    session.keyText = session.keywordText = '';
    _parse();
    if (scroll.hasClients) scroll.jumpTo(0);
  }

  /// 大报文搜索要遍历整棵字段树或全文，逐字输入时合并为停顿后一次刷新；
  /// 小报文立即刷新，保持输入即见结果。
  Timer? _searchTimer;
  static const searchDebounceLength = 256 * 1024;
  void _search(VoidCallback update) {
    update();
    _searchTimer?.cancel();
    if (document.source.length < searchDebounceLength) {
      setState(() {});
      return;
    }
    _searchTimer = Timer(const Duration(milliseconds: 220), () {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _parseGeneration++;
    keySearch.dispose();
    keyword.dispose();
    scroll.dispose();
    super.dispose();
  }

  void _parse() {
    collapsed.clear();
    opened.clear();
    collapseAll = false;
    _treeRevision++;
    _startParse();
  }

  /// 已解析文档按面包屑节点和解析方式缓存：返回上一层、退出全屏重建时不再重复解析。
  /// 节点随会话释放后缓存一并回收。
  static final _documents = Expando<Map<String, MessageDocument>>(
    'messageDocuments',
  );

  /// 小报文同步得到结果；大文本先放原文占位并转到后台解析，完成后再刷新。
  void _startParse() {
    final generation = ++_parseGeneration;
    final frame = frames.last, value = frame.value, parseMode = mode;
    final cache = _documents[frame] ??= {};
    final cached = cache[parseMode];
    if (cached != null) {
      parsing = false;
      document = cached;
      return;
    }
    if (!shouldParseInBackground(
      value,
      mode: parseMode,
      threshold: widget.backgroundThreshold,
    )) {
      parsing = false;
      document = cache[parseMode] = parseMessage(value, mode: parseMode);
      return;
    }
    final raw = value as String;
    parsing = true;
    document = MessageDocument('text', raw, MessageNode('文本', '', raw));
    widget
        .backgroundParser(raw, mode: parseMode)
        .then(
          (result) {
            // 即使用户已切走也写入缓存，回到这一层无需重新解析。
            cache[parseMode] = result;
            if (!mounted || generation != _parseGeneration) return;
            setState(() {
              parsing = false;
              document = result;
              _treeRevision++;
            });
          },
          onError: (Object error, StackTrace _) {
            if (!mounted || generation != _parseGeneration) return;
            // 后台失败（如平台不支持 isolate）时保留完整原文，不丢内容；不写入缓存，下次可重试。
            setState(() {
              parsing = false;
              document = MessageDocument(
                'text',
                raw,
                MessageNode('文本', '', raw),
                '后台解析失败，当前显示完整原文（${error.runtimeType}）',
              );
            });
          },
        );
  }

  /// 字段树展开状态的版本号；折叠/展开或重新解析时递增，用于判断行缓存是否失效。
  int _treeRevision = 0;
  Object? _rowsKey;
  List<(MessageNode, int)> _rowsCache = const [];

  /// 结构视图的可见行。父级重建（状态条、接口记录更新等）时直接复用，
  /// 仅在文档、搜索词或折叠状态变化时重新遍历整棵树。
  List<(MessageNode, int)> _treeRows(bool searching) {
    final key = (
      document,
      keySearch.text,
      keyword.text,
      collapseAll,
      _treeRevision,
    );
    if (_rowsKey == key) return _rowsCache;
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
    _rowsKey = key;
    return _rowsCache = rows;
  }

  Object? _blocksKey;
  ({List<List<TextSpan>> blocks, int count}) _blocksCache = (
    blocks: const [],
    count: 0,
  );

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
            decoration: const BoxDecoration(
              color: Color(0xfff5f8fc),
              border: Border(bottom: BorderSide(color: Color(0xffdde6f1))),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  const Icon(
                    Icons.account_tree_outlined,
                    size: 16,
                    color: Color(0xff2563eb),
                  ),
                  const SizedBox(width: 6),
                  for (var i = 0; i < frames.length; i++) ...[
                    if (i > 0)
                      const Icon(
                        Icons.chevron_right,
                        size: 15,
                        color: Color(0xff7f91ab),
                      ),
                    TextButton(
                      onPressed: i < frames.length - 1 ? () => _back(i) : null,
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        backgroundColor: i == frames.length - 1
                            ? const Color(0xffeaf2ff)
                            : Colors.white,
                        foregroundColor: i == frames.length - 1
                            ? const Color(0xff2563eb)
                            : const Color(0xff4a5d78),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(999),
                          side: BorderSide(
                            color: i == frames.length - 1
                                ? const Color(0xffbfd6ff)
                                : const Color(0xffdde6f1),
                          ),
                        ),
                      ),
                      child: Text(
                        frames[i].name,
                        style: const TextStyle(
                          fontFamily: 'Menlo',
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
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
                      parsing
                          ? '后台解析中…'
                          : '${document.format.toUpperCase()} · 字段可继续专注',
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
          Expanded(
            child: AnimatedSwitcher(
              duration: MediaQuery.of(context).disableAnimations
                  ? Duration.zero
                  : const Duration(milliseconds: 160),
              // 仅在“解析中 ↔ 完成”之间淡入；专注、折叠等切换不做过渡。
              // 只保留当前子树：新旧视图可能共用同一个滚动控制器，不能同时挂载。
              layoutBuilder: (current, _) => current ?? const SizedBox(),
              child: KeyedSubtree(
                key: ValueKey(parsing),
                child: parsing
                    ? _parsingView()
                    : document.structured && !rawView
                    ? _tree()
                    : _text(),
              ),
            ),
          ),
        ],
      );
    },
  );

  /// 后台解析时的过渡态：显示报文体量，用户可随时返回上一层或改为纯文本查看。
  Widget _parsingView() {
    final length = document.source.length;
    final size = length >= 1024 * 1024
        ? '${(length / 1024 / 1024).toStringAsFixed(1)}M'
        : '${(length / 1024).ceil()}K';
    return Center(
      key: const ValueKey('message-parsing'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          const SizedBox(height: 14),
          Text(
            '正在后台解析报文（约 $size 字符）…',
            style: const TextStyle(fontSize: 12, color: Color(0xff52647c)),
          ),
          const SizedBox(height: 6),
          TextButton(
            onPressed: () => setState(() {
              mode = 'text';
              _parse();
            }),
            child: const Text('直接查看纯文本'),
          ),
        ],
      ),
    );
  }

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
              onChanged: (value) => _search(() => session.keyText = value),
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
              onChanged: (value) => _search(() => session.keywordText = value),
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
                _treeRevision++;
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
    final rows = _treeRows(searching);
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
                  border: Border(bottom: BorderSide(color: Color(0xffecf1f8))),
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
                                  _treeRevision++;
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
                                  color: const Color(0xff7f91ab),
                                ),
                              )
                            : const Icon(
                                Icons.circle,
                                size: 4,
                                color: Color(0xffa6b4c8),
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
                                      color: Color(0xff2563eb),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  TextSpan(
                                    text: node.summary,
                                    style: const TextStyle(
                                      color: Color(0xff0f1e36),
                                    ),
                                  ),
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
                                  color: Color(0xff7f91ab),
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
                        icon: const Icon(
                          Icons.copy_outlined,
                          size: 15,
                          color: Color(0xff7f91ab),
                        ),
                      ),
                      TextButton(
                        onPressed: () => _focus(node),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          backgroundColor: const Color(0xffeaf2ff),
                          foregroundColor: const Color(0xff2563eb),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6),
                            side: const BorderSide(color: Color(0xffbfd6ff)),
                          ),
                        ),
                        child: const Text(
                          '专注',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
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
    final term = keyword.text;
    final (:blocks, :count) = _textBlocksFor(term);
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
          child: blocks.length > lazyTextBlocks
              ? _lazyText(blocks)
              : Scrollbar(
                  controller: scroll,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    key: const ValueKey('complete-text'),
                    controller: scroll,
                    padding: const EdgeInsets.all(22),
                    child: SizedBox(
                      width: double.infinity,
                      // 连续滚动、跨块选中；每块独立排版和绘制，避免整份长报文
                      // 形成一个巨大的 RenderParagraph。分块只影响显示，不改原文。
                      child: SelectionArea(
                        child: Column(
                          key: const ValueKey('raw-message-text'),
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (var i = 0; i < blocks.length; i++)
                              RepaintBoundary(
                                child: Text.rich(
                                  TextSpan(children: blocks[i]),
                                  key: ValueKey('raw-message-block-$i'),
                                  softWrap: true,
                                  style: _rawStyle,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  /// 原文超过该块数（约 256K 字符）时改为懒加载列表，只排版可见块；
  /// 较短原文仍整体排版，保证跨块连续选中。复制整份使用工具栏的复制按钮。
  static const lazyTextBlocks = 256;

  Widget _lazyText(List<List<TextSpan>> blocks) => Scrollbar(
    controller: scroll,
    thumbVisibility: true,
    child: SelectionArea(
      child: ListView.builder(
        key: const ValueKey('complete-text-lazy'),
        controller: scroll,
        padding: const EdgeInsets.all(22),
        itemCount: blocks.length,
        itemBuilder: (context, i) => Text.rich(
          TextSpan(children: blocks[i]),
          key: ValueKey('raw-message-block-$i'),
          softWrap: true,
          style: _rawStyle,
        ),
      ),
    ),
  );

  static const _rawStyle = TextStyle(
    fontFamily: 'Menlo',
    fontSize: 13,
    height: 1.8,
    color: Color(0xff36567d),
  );

  /// 原文视图的分块与匹配数。长报文格式化、全文搜索和分块都是 O(n) 的字符串复制，
  /// 结果按文档、格式化开关与关键字缓存，父级重建时不再重复计算。
  ({List<List<TextSpan>> blocks, int count}) _textBlocksFor(String term) {
    final key = (document, pretty, term);
    if (_blocksKey == key) return _blocksCache;
    var text = document.source;
    if (pretty && document.format == 'json') {
      text = const JsonEncoder.withIndent('  ').convert(document.root.value);
    }
    if (pretty && document.format == 'xml') {
      text = (document.root.value as XmlNode).toXmlString(pretty: true);
    }
    final spans = <TextSpan>[];
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
    _blocksKey = key;
    return _blocksCache = (blocks: _textBlocks(spans), count: count);
  }

  /// 限制单个文本块的 UTF-16 长度，同时保留全部字符与搜索高亮。
  /// 不切断代理对及 CRLF；跨边界的匹配保留两侧高亮，复制整份仍使用 source。
  List<List<TextSpan>> _textBlocks(List<TextSpan> spans) {
    const limit = 1024;
    final blocks = <List<TextSpan>>[];
    var block = <TextSpan>[];
    var length = 0;
    for (final span in spans) {
      final value = span.text ?? '';
      var start = 0;
      while (start < value.length) {
        var end = (start + limit - length).clamp(start, value.length);
        if (end < value.length && end > start) {
          final previous = value.codeUnitAt(end - 1);
          if ((previous >= 0xd800 && previous <= 0xdbff) ||
              (previous == 13 && value.codeUnitAt(end) == 10)) {
            end--;
          }
        }
        if (end > start) {
          block.add(
            TextSpan(text: value.substring(start, end), style: span.style),
          );
          length += end - start;
          start = end;
        }
        if (length == limit || start < value.length) {
          blocks.add(block);
          block = <TextSpan>[];
          length = 0;
        }
      }
    }
    if (block.isNotEmpty) blocks.add(block);
    return blocks;
  }
}
