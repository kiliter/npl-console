import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/batch_repair/batch_repair.dart';
import '../../core/batch_repair/repair_rules.dart';
import '../../core/maintenance_controller.dart';
import '../../core/pdf_editor/pdf_engine.dart';
import '../listenable_selector.dart';
import 'upload_dialog.dart';

const _ink = Color(0xff0f1e36),
    _muted = Color(0xff7f91ab),
    _blue = Color(0xff2563eb),
    _line = Color(0xffdde6f1),
    _seal = Color(0xffc8372d),
    _ok = Color(0xff0d8a6a),
    _warn = Color(0xffc66908);
const _mono = 'Menlo';

Color statusColor(BatchOrderStatus s) => switch (s) {
  BatchOrderStatus.repaired => _seal,
  BatchOrderStatus.ok => _ok,
  BatchOrderStatus.unresolved || BatchOrderStatus.notFound => _warn,
  BatchOrderStatus.failed => const Color(0xff7a2b25),
  BatchOrderStatus.running => _blue,
  BatchOrderStatus.pending => _muted,
};

Widget chip(String text, Color color, {Key? key}) => Container(
  key: key,
  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
  decoration: BoxDecoration(
    color: color.withValues(alpha: .1),
    borderRadius: BorderRadius.circular(999),
    border: Border.all(color: color.withValues(alpha: .35)),
  ),
  child: Text(
    text,
    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color),
  ),
);

String fileSize(int n) => n >= 1048576
    ? '${(n / 1048576).toStringAsFixed(2)} MB'
    : '${(n / 1024).toStringAsFixed(0)} KB';

/// 批量修复（仅 Windows、macOS）：输入一组订单号 → 只读查询近三个月单据 → 自动分析并修补
/// 最新单据 → 预览修复前后 → 多重确认后逐个上传。
class BatchRepairScreen extends StatefulWidget {
  final MaintenanceController controller;
  final BatchRepairSession? session;
  const BatchRepairScreen({super.key, required this.controller, this.session});
  @override
  State<BatchRepairScreen> createState() => _BatchRepairScreenState();
}

class _BatchRepairScreenState extends State<BatchRepairScreen> {
  late final BatchRepairSession session =
      widget.session ?? BatchRepairSession(controller: widget.controller);
  final inputs = <TextEditingController>[TextEditingController()];
  String? current;
  final _regenerate = <String, Timer>{};

  @override
  void dispose() {
    for (final c in inputs) {
      c.dispose();
    }
    for (final t in _regenerate.values) {
      t.cancel();
    }
    if (widget.session == null) session.dispose();
    super.dispose();
  }

  Widget watch<T>(T Function() select, Widget Function() build) =>
      ListenableSelector<T>(
        listenable: session,
        selector: select,
        builder: (context, _) => build(),
      );

  List<String> get numbers => [
    for (final c in inputs)
      if (orderNumberPattern.hasMatch(c.text.trim())) c.text.trim(),
  ];

  /// 一个输入框里粘贴了多个订单号时自动拆成多行。
  void _onChanged(int index, String value) {
    final found = extractOrderNumbers(value);
    if (found.length > 1) {
      final existing = {for (final c in inputs) c.text.trim()};
      inputs[index].text = found.first;
      var at = index + 1;
      for (final n in found.skip(1)) {
        if (existing.contains(n)) continue;
        inputs.insert(at++, TextEditingController(text: n));
      }
    }
    setState(() {});
  }

  Future<void> submit() async {
    final list = numbers.toSet().toList();
    if (list.isEmpty || session.running) return;
    if (session.orders.isNotEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('开始新一批'),
          content: const Text('当前列表会被清空。已生成的文件和日志仍保留在原目录。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('开始'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => current = list.first);
    await session.start(list);
  }

  void openFolder(String path) {
    Process.run(Platform.isWindows ? 'explorer' : 'open', [path]).ignore();
  }

  void toggle(BatchOrder o, RepairItem item, bool value) {
    session.select(o, item.id, value);
    // 连续勾选合并为一次重新生成。
    _regenerate[o.order]?.cancel();
    _regenerate[o.order] = Timer(const Duration(milliseconds: 500), () {
      _regenerate.remove(o.order);
      session.regenerate(o);
    });
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0xffeef2f7),
    child: Column(
      children: [
        watch(() => (session.revision), toolbar),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 330, child: sidebar()),
              const VerticalDivider(width: 1, color: _line),
              Expanded(child: watch(() => (session.revision, current), detail)),
            ],
          ),
        ),
      ],
    ),
  );

  Widget toolbar() {
    final dir = session.batchDir;
    final ready = session.orders
        .where((o) => o.uploadable && session.uploaded(o) == null)
        .length;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: _line)),
      ),
      child: Row(
        children: [
          const Icon(Icons.auto_fix_high, size: 18, color: _blue),
          const SizedBox(width: 8),
          const Text(
            '批量修复',
            style: TextStyle(fontWeight: FontWeight.w700, color: _ink),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: dir == null
                ? const Text(
                    '输入订单号后提交：只读查询近三个月单据，自动补齐最新单据缺失的签字和证件图片。',
                    style: TextStyle(fontSize: 12, color: _muted),
                    overflow: TextOverflow.ellipsis,
                  )
                : Text(
                    '工作目录 ${dir.path}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: _muted,
                      fontFamily: _mono,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
          ),
          if (dir != null)
            TextButton.icon(
              onPressed: () => openFolder(dir.path),
              icon: const Icon(Icons.folder_open, size: 16),
              label: const Text('打开目录'),
            ),
          const SizedBox(width: 8),
          FilledButton.icon(
            key: const ValueKey('batch-upload'),
            style: FilledButton.styleFrom(backgroundColor: _seal),
            onPressed: session.running || ready == 0
                ? null
                : () => showUploadDialog(context, session),
            icon: const Icon(Icons.cloud_upload_outlined, size: 16),
            label: Text(ready == 0 ? '上传到生产…' : '上传到生产…（待上传 $ready 份）'),
          ),
        ],
      ),
    );
  }

  Widget sidebar() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _line),
        ),
        child: watch(() => (session.running, inputs.length), form),
      ),
      Expanded(child: watch(() => (session.revision, current), orderList)),
    ],
  );

  Widget form() {
    final running = session.running;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '订单号',
          style: TextStyle(fontWeight: FontWeight.w700, color: _ink),
        ),
        const SizedBox(height: 2),
        const Text(
          '2 开头的 18 位数字；可一次粘贴多个，自动拆成多行',
          style: TextStyle(fontSize: 11, color: _muted),
        ),
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 260),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: inputs.length,
            itemBuilder: (context, i) {
              final text = inputs[i].text.trim();
              final invalid =
                  text.isNotEmpty && !orderNumberPattern.hasMatch(text);
              final duplicate =
                  text.isNotEmpty &&
                  inputs.indexWhere((c) => c.text.trim() == text) != i;
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    SizedBox(
                      width: 22,
                      child: Text(
                        '${i + 1}',
                        style: const TextStyle(fontSize: 11, color: _muted),
                      ),
                    ),
                    Expanded(
                      child: TextField(
                        key: ValueKey('order-input-$i'),
                        controller: inputs[i],
                        enabled: !running,
                        onChanged: (v) => _onChanged(i, v),
                        onSubmitted: (_) =>
                            setState(() => inputs.add(TextEditingController())),
                        style: const TextStyle(fontFamily: _mono, fontSize: 13),
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: '200664218695020220',
                          errorText: invalid
                              ? '不是订单号'
                              : duplicate
                              ? '重复'
                              : null,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '删除',
                      iconSize: 16,
                      onPressed: running
                          ? null
                          : () => setState(() {
                              if (inputs.length == 1) {
                                inputs.first.clear();
                              } else {
                                inputs.removeAt(i).dispose();
                              }
                            }),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            OutlinedButton.icon(
              key: const ValueKey('order-add'),
              onPressed: running
                  ? null
                  : () => setState(() => inputs.add(TextEditingController())),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('新增'),
            ),
            const Spacer(),
            FilledButton(
              key: const ValueKey('order-submit'),
              onPressed: running || numbers.isEmpty ? null : submit,
              child: Text(running ? '处理中…' : '提交（${numbers.toSet().length}）'),
            ),
          ],
        ),
      ],
    );
  }

  Widget orderList() {
    if (session.orders.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text(
          '提交后，订单会列在这里。',
          style: TextStyle(color: _muted, fontSize: 12),
        ),
      );
    }
    final counts = {
      for (final s in BatchOrderStatus.values)
        s: session.orders.where((o) => o.status == s).length,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: Text(
            '${session.orders.length} 个订单 · 可上传 ${counts[BatchOrderStatus.repaired]} · '
            '无需修补 ${counts[BatchOrderStatus.ok]} · 失败 ${counts[BatchOrderStatus.failed]}',
            style: const TextStyle(fontSize: 12, color: _muted),
          ),
        ),
        Expanded(
          child: ListView(
            children: [for (final o in session.orders) orderTile(o)],
          ),
        ),
      ],
    );
  }

  Widget orderTile(BatchOrder o) {
    final active = current == o.order;
    final done = session.uploaded(o);
    return InkWell(
      key: ValueKey('order-tile-${o.order}'),
      onTap: () => setState(() => current = o.order),
      child: Container(
        padding: const EdgeInsets.fromLTRB(13, 9, 12, 9),
        decoration: BoxDecoration(
          color: active ? Colors.white : null,
          border: Border(
            left: BorderSide(
              color: active ? _seal : Colors.transparent,
              width: 3,
            ),
            bottom: const BorderSide(color: _line),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              o.order,
              style: const TextStyle(
                fontFamily: _mono,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 3),
            Row(
              children: [
                done != null
                    ? chip('已上传', _ok)
                    : chip(o.status.label, statusColor(o.status)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    o.stage.isNotEmpty
                        ? o.stage
                        : o.target == null
                        ? ''
                        : '${o.target!.caseNo}${o.fixable.isEmpty ? '' : ' · ${o.fixable.length} 项'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11.5, color: _muted),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget detail() {
    final o =
        session.orders.where((o) => o.order == current).firstOrNull ??
        session.orders.firstOrNull;
    if (o == null) {
      return const Center(
        child: Text(
          '在左侧填写订单号并提交，修复前后的对比会显示在这里。',
          style: TextStyle(color: _muted),
        ),
      );
    }
    final done = session.uploaded(o);
    final target = o.target;
    final hitPages = {for (final i in o.items) i.page}.toList()..sort();
    return ListView(
      key: PageStorageKey('batch-detail-${o.order}'),
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 60),
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 6,
          children: [
            const Text('订单号', style: TextStyle(color: _muted, fontSize: 13)),
            Text(
              o.order,
              style: const TextStyle(
                fontFamily: _mono,
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
            done != null
                ? chip('已上传', _ok)
                : chip(o.status.label, statusColor(o.status)),
            if (o.status != BatchOrderStatus.running && !session.running ||
                o.status == BatchOrderStatus.failed)
              o.status == BatchOrderStatus.failed
                  ? FilledButton.icon(
                      key: const ValueKey('order-retry'),
                      style: FilledButton.styleFrom(backgroundColor: _seal),
                      onPressed: o.status == BatchOrderStatus.running
                          ? null
                          : () => session.retry(o),
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('重试'),
                    )
                  : OutlinedButton.icon(
                      key: const ValueKey('order-retry'),
                      onPressed:
                          o.status == BatchOrderStatus.running || done != null
                          ? null
                          : () => session.retry(o),
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('重新查询分析'),
                    ),
          ],
        ),
        const SizedBox(height: 8),
        if (target != null)
          Wrap(
            spacing: 24,
            runSpacing: 4,
            children: [
              fact('最新单据', target.caseNo),
              fact('办理时间', target.opTime.isEmpty ? '—' : target.opTime),
              fact(
                '历史单据',
                o.history.isEmpty
                    ? '无'
                    : o.history
                          .map((d) => '${d.caseNo}（${d.opTime}）')
                          .join('、'),
              ),
              if (o.output != null)
                fact(
                  '修复件',
                  '${o.outputName} · ${fileSize(o.output!.bytes.length)} · ${o.output!.label}'
                      '${o.renderDiff == null ? '' : ' · 渲染差 ${o.renderDiff!.toStringAsFixed(2)}'}',
                ),
            ],
          ),
        const SizedBox(height: 12),
        message(o, done),
        if (target != null) ...[
          const SizedBox(height: 12),
          pageStrip(o, hitPages.toSet()),
        ],
        if (o.items.isNotEmpty) ...[
          const SizedBox(height: 14),
          itemsCard(o, done != null),
        ],
        if (target != null)
          for (final page in hitPages) pageGroup(o, page),
      ],
    );
  }

  Widget fact(String label, String value) => Text.rich(
    TextSpan(
      text: '$label ',
      style: const TextStyle(color: _muted, fontSize: 13),
      children: [
        TextSpan(
          text: value,
          style: const TextStyle(
            color: _ink,
            fontFamily: _mono,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );

  Widget message(BatchOrder o, UploadedRecord? done) {
    final color = o.status == BatchOrderStatus.failed || o.problems.isNotEmpty
        ? const Color(0xff7a2b25)
        : o.status == BatchOrderStatus.unresolved ||
              o.status == BatchOrderStatus.notFound
        ? _warn
        : _line;
    final text = o.status == BatchOrderStatus.running
        ? '${o.stage}…'
        : done != null
        ? '已于 ${done.time.substring(0, 19).replaceFirst('T', ' ')} 上传成功并回读一致（批次 ${done.batch}）。${o.message}'
        : o.message.isEmpty
        ? o.status.label
        : o.message;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(left: BorderSide(color: color, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (o.status == BatchOrderStatus.running) ...[
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(child: SelectableText(text)),
            ],
          ),
          for (final f in o.failures)
            Text(f, style: const TextStyle(fontSize: 12, color: _muted)),
        ],
      ),
    );
  }

  Widget pageStrip(BatchOrder o, Set<int> hits) => Wrap(
    spacing: 3,
    runSpacing: 3,
    children: [
      for (final p in o.target!.analysis.pages)
        Tooltip(
          message: '第 ${p.index + 1} 页 · ${p.kind.label}',
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: hits.contains(p.index) ? _seal : const Color(0xffd9dfe5),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              '${p.index + 1} ${p.kind.short}',
              style: TextStyle(
                fontSize: 11,
                color: hits.contains(p.index)
                    ? Colors.white
                    : p.kind == PdfPageKind.acceptance
                    ? const Color(0xff9aa4ae)
                    : const Color(0xff4a5563),
              ),
            ),
          ),
        ),
    ],
  );

  Widget itemsCard(BatchOrder o, bool locked) => Container(
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: _line),
    ),
    child: Column(
      children: [
        for (final i in o.items)
          Container(
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xffedf0f3))),
            ),
            color: null,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 36,
                  child: i.fixable
                      ? Checkbox(
                          value: o.selected.contains(i.id),
                          onChanged:
                              locked || o.status == BatchOrderStatus.running
                              ? null
                              : (v) => toggle(o, i, v ?? false),
                        )
                      : const SizedBox(),
                ),
                SizedBox(
                  width: 96,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '第 ${i.page + 1} 页\n${i.pageKind.label}',
                      style: const TextStyle(
                        fontFamily: _mono,
                        fontSize: 12,
                        color: _muted,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${i.element.label}${i.fixable ? '' : ' · 无法补齐'}',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: i.fixable ? _ink : _warn,
                          ),
                        ),
                        Text(
                          i.message,
                          style: const TextStyle(fontSize: 12, color: _muted),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );

  Widget pageGroup(BatchOrder o, int page) {
    final target = o.target!;
    final info = target.analysis.pages[page];
    final items = [
      for (final i in o.items)
        if (i.page == page) i,
    ];
    final selected = [
      for (final i in items)
        if (o.selected.contains(i.id) && i.fixable) i,
    ];
    final sources = <(int, int)>{
      for (final i in items)
        if (i.fixable)
          for (final p in i.placements) (p.history, p.sourcePage),
    };
    final boxes = [
      for (final i in items)
        if (i.region != null) _Box(i.region!, region: true),
      for (final i in selected)
        for (final p in i.placements) _Box(p.target),
    ];
    final panes = <Widget>[
      _PagePane(
        label: '修复前',
        caption: target.caseNo,
        engine: session.engine,
        bytes: target.bytes,
        page: page,
        size: info.size,
        boxes: [
          for (final b in boxes)
            if (b.region) b,
        ],
      ),
      if (o.output != null)
        _PagePane(
          label: '修复后',
          caption: '按当前勾选生成',
          engine: session.engine,
          bytes: o.output!.bytes,
          page: page,
          size: info.size,
          boxes: boxes,
        )
      else
        _PlaceholderPane(
          label: '修复后',
          text: o.status == BatchOrderStatus.running ? '生成中…' : '未生成',
          size: info.size,
        ),
      for (final (h, sp) in sources)
        _PagePane(
          label: '来源',
          caption: '${o.history[h].caseNo} 第 ${sp + 1} 页',
          engine: session.engine,
          bytes: o.history[h].bytes,
          page: sp,
          size: o.history[h].analysis.pages[sp].size,
          boxes: [
            for (final i in items)
              for (final p in i.placements)
                if (p.history == h && p.sourcePage == sp) _Box(p.sourceBounds),
          ],
        ),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              text: '第 ${page + 1} 页 · ${info.kind.label}',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
              children: const [
                TextSpan(
                  text: '   虚线框为补入位置，点击页面放大查看',
                  style: TextStyle(
                    fontWeight: FontWeight.w400,
                    fontSize: 12,
                    color: _muted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth > 1100 ? 3 : 2;
              final width =
                  (constraints.maxWidth - 16 * (columns - 1)) / columns;
              return Wrap(
                spacing: 16,
                runSpacing: 16,
                children: [
                  for (final p in panes) SizedBox(width: width, child: p),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _Box {
  final Rect rect;
  final bool region;
  const _Box(this.rect, {this.region = false});
}

/// 页面渲染图缓存：按字节版本与页码，最多保留 48 张。
final _pageImages = <(int, int), Future<Uint8List>>{};
final _pageKeys = Expando<int>('batchPageKey');
var _nextPageKey = 0;
Future<Uint8List> _pageImage(PdfEditEngine engine, Uint8List bytes, int page) {
  final key = (_pageKeys[bytes] ??= ++_nextPageKey, page);
  final hit = _pageImages.remove(key);
  if (hit != null) return _pageImages[key] = hit;
  final future = engine.inspect(bytes, page).then((s) => s.png);
  future.ignore();
  _pageImages[key] = future;
  while (_pageImages.length > 48) {
    _pageImages.remove(_pageImages.keys.first);
  }
  return future;
}

class _PagePane extends StatelessWidget {
  final String label, caption;
  final PdfEditEngine engine;
  final Uint8List bytes;
  final int page;
  final Size size;
  final List<_Box> boxes;
  const _PagePane({
    required this.label,
    required this.caption,
    required this.engine,
    required this.bytes,
    required this.page,
    required this.size,
    required this.boxes,
  });

  Widget sheet({bool large = false}) => AspectRatio(
    aspectRatio: size.width / size.height,
    child: DecoratedBox(
      decoration: const BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Color(0x1f232b36),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: FutureBuilder<Uint8List>(
        future: _pageImage(engine, bytes, page),
        builder: (context, snapshot) => Stack(
          fit: StackFit.expand,
          children: [
            if (snapshot.hasData)
              Image.memory(
                snapshot.data!,
                fit: BoxFit.fill,
                gaplessPlayback: true,
                filterQuality: FilterQuality.medium,
              )
            else
              Center(
                child: Text(
                  snapshot.hasError ? '渲染失败' : '渲染中…',
                  style: const TextStyle(fontSize: 12, color: _muted),
                ),
              ),
            CustomPaint(painter: _BoxPainter(boxes, large ? 2.5 : 1.6)),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
          ),
          const Spacer(),
          Flexible(
            child: Text(
              caption,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: _muted),
            ),
          ),
        ],
      ),
      const SizedBox(height: 6),
      MouseRegion(
        cursor: SystemMouseCursors.zoomIn,
        child: GestureDetector(
          onTap: () => showDialog<void>(
            context: context,
            builder: (context) => Dialog(
              insetPadding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 8, 4),
                    child: Row(
                      children: [
                        Text(
                          '$label · $caption',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const Spacer(),
                        const Text(
                          '滚轮或双指缩放',
                          style: TextStyle(fontSize: 12, color: _muted),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: InteractiveViewer(
                      maxScale: 8,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: sheet(large: true),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          child: sheet(),
        ),
      ),
    ],
  );
}

class _PlaceholderPane extends StatelessWidget {
  final String label, text;
  final Size size;
  const _PlaceholderPane({
    required this.label,
    required this.text,
    required this.size,
  });
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        label,
        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
      ),
      const SizedBox(height: 6),
      AspectRatio(
        aspectRatio: size.width / size.height,
        child: Container(
          color: Colors.white,
          alignment: Alignment.center,
          child: Text(text, style: const TextStyle(color: _muted)),
        ),
      ),
    ],
  );
}

class _BoxPainter extends CustomPainter {
  final List<_Box> boxes;
  final double stroke;
  const _BoxPainter(this.boxes, this.stroke);
  @override
  void paint(Canvas canvas, Size size) {
    for (final b in boxes) {
      final r = Rect.fromLTRB(
        b.rect.left * size.width,
        b.rect.top * size.height,
        b.rect.right * size.width,
        b.rect.bottom * size.height,
      );
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = b.region ? _seal.withValues(alpha: .45) : _seal;
      if (!b.region) {
        canvas.drawRect(r, Paint()..color = _seal.withValues(alpha: .06));
      }
      // 虚线框
      final dash = b.region ? 2.0 : 6.0, gap = b.region ? 3.0 : 4.0;
      void line(Offset a, Offset c) {
        final length = (c - a).distance;
        final dir = (c - a) / length;
        for (var d = 0.0; d < length; d += dash + gap) {
          canvas.drawLine(
            a + dir * d,
            a + dir * (d + dash).clamp(0, length),
            paint,
          );
        }
      }

      line(r.topLeft, r.topRight);
      line(r.topRight, r.bottomRight);
      line(r.bottomRight, r.bottomLeft);
      line(r.bottomLeft, r.topLeft);
    }
  }

  @override
  bool shouldRepaint(_BoxPainter old) =>
      old.boxes != boxes || old.stroke != stroke;
}
