import 'repair_connections.dart';
import '../../core/pdf_diagnostics.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:file_picker/file_picker.dart';
import '../../core/maintenance_controller.dart';
import '../../core/pdf_editor/edit_session.dart';
import 'editor_canvas.dart';

class PdfEditorScreen extends StatefulWidget {
  final MaintenanceController controller;
  final PdfEditSession? session;
  const PdfEditorScreen({super.key, required this.controller, this.session});
  @override
  State<PdfEditorScreen> createState() => _PdfEditorScreenState();
}

class _PdfEditorScreenState extends State<PdfEditorScreen> {
  late final PdfEditSession session = widget.session ?? PdfEditSession();
  final oldNo = TextEditingController(), newNo = TextEditingController();
  final connections = RepairConnections();
  final selection = ValueNotifier<Map<String, RepairSelection>>({});
  final scrollLink = ValueNotifier<RepairScrollPosition?>(null);
  bool loading = false, saving = false, showSource = true;
  String? loadError;
  late String connection = jsonEncode(widget.controller.settings.toJson());
  int loadRevision = 0;
  bool get busy => session.busy || loading || saving;

  @override
  void initState() {
    super.initState();
    oldNo.text = session.source?.caseNo ?? '';
    newNo.text = session.target?.caseNo ?? '';
    connections.setImages(session.materials);
    session.addListener(update);
    widget.controller.addListener(connectionChanged);
  }

  void update() {
    connections.setImages(session.materials);
    if (mounted) setState(() {});
  }

  void connectionChanged() {
    final next = jsonEncode(widget.controller.settings.toJson());
    if (next == connection) return;
    connection = next;
    loadRevision++;
    loading = false;
    selection.value = {};
    session.reset();
    if (mounted) setState(() => loadError = '连接环境已更改，请重新加载单据');
  }

  @override
  void dispose() {
    loadRevision++;
    widget.controller.removeListener(connectionChanged);
    session.removeListener(update);
    if (widget.session == null) session.dispose();
    oldNo.dispose();
    newNo.dispose();
    selection.dispose();
    scrollLink.dispose();
    connections.dispose();
    super.dispose();
  }

  Future<bool> confirmDiscard() async {
    if (session.target?.dirty != true &&
        !session.needsSync &&
        session.materials.isEmpty) {
      return true;
    }
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('重新加载单据？'),
            content: const Text('当前修复结果和共享区将被清空，请先保存需要保留的单据。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('重新加载'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> load() async {
    if (busy) return;
    final targetNo = newNo.text.trim(), sourceNo = oldNo.text.trim();
    if (targetNo.isEmpty || sourceNo.isEmpty) {
      setState(() => loadError = '请填写新老单据号');
      return;
    }
    if (targetNo == sourceNo) {
      setState(() => loadError = '新老单据号不能相同');
      return;
    }
    if (!await confirmDiscard() || !mounted) return;
    final revision = ++loadRevision;
    setState(() {
      loading = true;
      loadError = null;
    });
    try {
      final target = await PdfDiagnostics.trace(
        '目标单据查询及下载',
        () => widget.controller.loadEditorPdf(targetNo),
      );
      if (!mounted || revision != loadRevision) return;
      final source = await PdfDiagnostics.trace(
        '来源单据查询及下载',
        () => widget.controller.loadEditorPdf(sourceNo),
      );
      if (!mounted || revision != loadRevision) return;
      await session.load(
        targetNo,
        target.bytes,
        sourceNo: sourceNo,
        sourceBytes: source.bytes,
      );
      if (!mounted || revision != loadRevision) return;
      selection.value = {};
      setState(() => showSource = true);
    } catch (e) {
      if (mounted && revision == loadRevision) {
        setState(
          () => loadError = e is FormatException
              ? e.message
              : '单据加载失败（${e.runtimeType}）',
        );
      }
    } finally {
      if (mounted && revision == loadRevision) setState(() => loading = false);
    }
  }

  Future<void> collect() async {
    await session.collectSelected(selection.value.values.toList());
    if (mounted && session.error == null) selection.value = {};
  }

  Future<void> synchronize() async {
    setState(() => loadError = null);
    await session.synchronize();
    if (mounted && session.error == null) setState(() => showSource = false);
  }

  Future<void> save() async {
    final doc = session.target;
    if (doc == null || busy || session.needsSync) {
      return;
    }
    final bytes = Uint8List.fromList(doc.bytes), revision = loadRevision;
    setState(() {
      saving = true;
      loadError = null;
    });
    try {
      final result = await FilePicker.saveFile(
        bytes: bytes,
        mimeType: 'application/pdf',
        fileName:
            '${doc.caseNo.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')}_修复.pdf',
        dialogTitle: '保存修复后的单据',
      );
      if (!mounted || result == null || revision != loadRevision) return;
      session.markSaved(bytes);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('修复后的单据已保存到本地')));
    } catch (e) {
      if (mounted) {
        setState(() => loadError = '保存失败（${e.runtimeType}），修复结果仍保留，可重试');
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> copyPage(bool fromOld, int page) async {
    final doc = session.target,
        source = fromOld ? session.source : session.target;
    if (busy || doc == null || source == null) return;
    final revision = loadRevision;
    final choice = await showDialog<({int page, int insertAt})>(
      context: context,
      builder: (_) => _CopyPageDialog(
        fromOld: fromOld,
        page: page,
        sourceCount: source.snapshot.pageCount,
        targetCount: doc.snapshot.pageCount,
      ),
    );
    if (choice == null || !mounted || revision != loadRevision || busy) return;
    await session.copyPageToTarget(
      fromOld: fromOld,
      page: choice.page,
      insertAt: choice.insertAt,
    );
    if (mounted && session.error == null) setState(() => showSource = false);
  }

  Future<void> mirrorPage(int page) async {
    final doc = session.source, revision = loadRevision;
    if (doc == null || busy) return;
    final choice = await showDialog<({int page, int insertAt})>(
      context: context,
      builder: (_) => _CopyPageDialog(
        fromOld: true,
        page: page,
        sourceCount: doc.snapshot.pageCount,
        targetCount: doc.snapshot.pageCount,
        suggestedInsert: page + 1,
        mirror: true,
      ),
    );
    if (choice == null || !mounted || revision != loadRevision || busy) return;
    final before = doc.bytes;
    await session.mirrorSourcePage(
      page: choice.page,
      insertAt: choice.insertAt,
    );
    if (!mounted || revision != loadRevision || identical(before, doc.bytes)) {
      return;
    }
    // 尚未加入共享区的选框也跟随原页面，镜像页默认不选中任何图片。
    selection.value = {
      for (final item in selection.value.values)
        '${item.page >= choice.insertAt ? item.page + 1 : item.page}:${item.object.id}':
            (
              page: item.page >= choice.insertAt ? item.page + 1 : item.page,
              object: item.object,
              size: item.size,
            ),
    };
    setState(() => showSource = true);
  }

  Future<void> importImage() async {
    final doc = session.target, revision = loadRevision;
    if (doc == null || busy) return;
    setState(() {
      loading = true;
      loadError = null;
    });
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['png', 'jpg', 'jpeg', 'webp'],
        dialogTitle: '导入本地图片',
      );
      if (files.isEmpty || !mounted || revision != loadRevision) return;
      final file = files.single;
      if (await file.length() > 20 * 1024 * 1024) {
        throw const FormatException('图片文件不能超过 20 MiB');
      }
      final normalized = await compute(
        normalizeImportedImage,
        await file.readAsBytes(),
      );
      if (!mounted || revision != loadRevision) return;
      final choice = await showDialog<({int page, Rect bounds})>(
        context: context,
        builder: (_) => _ImportImageDialog(
          document: doc,
          png: normalized.png,
          ratio: normalized.ratio,
        ),
      );
      if (choice == null || !mounted || revision != loadRevision) return;
      await session.importLocalImage(
        normalized.png,
        file.name,
        choice.page,
        choice.bounds,
      );
      if (mounted && session.error == null) setState(() => showSource = false);
    } catch (e) {
      if (mounted && revision == loadRevision) {
        setState(
          () => loadError = e is FormatException ? e.message : '本地图片导入失败',
        );
      }
    } finally {
      if (mounted && revision == loadRevision) setState(() => loading = false);
    }
  }

  Widget document(bool source) {
    final doc = source ? session.source : session.previewTarget;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          color: Colors.white,
          child: Text(
            '${source ? '旧单据 · 选择图片' : '新单据 · 修复预览'}${doc == null ? '' : '  ${doc.caseNo}'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        Expanded(
          child: doc == null
              ? Center(
                  child: Text(source ? '加载后，选择需要同步的旧单据图片' : '加入共享区后，在这里实时预览'),
                )
              : EditorCanvas(
                  key: ValueKey(source ? 'source-canvas' : 'target-canvas'),
                  document: doc,
                  engine: session.engine,
                  source: source,
                  enabled: !busy,
                  selection: selection,
                  onCopyPage: (page) => copyPage(source, page),
                  onMirrorPage: source ? mirrorPage : null,
                  scrollLink: scrollLink,
                  connections: connections,
                  session: source ? null : session,
                ),
        ),
      ],
    );
  }

  Widget shared(bool compact) => NotificationListener<ScrollNotification>(
    onNotification: (_) {
      connections.refresh();
      return false;
    },
    child: Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border.symmetric(
          vertical: BorderSide(color: Color(0xffe0e7f0)),
        ),
      ),
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                Icons.collections_outlined,
                size: 15,
                color: Color(0xff52647c),
              ),
              const SizedBox(width: 5),
              Text(
                '共享区 ${session.materials.length}',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              const Icon(Icons.bolt, size: 14, color: Color(0xff1a8b72)),
            ],
          ),
          const SizedBox(height: 6),
          Expanded(
            child: session.materials.isEmpty
                ? const Center(
                    child: Text(
                      '选图或导入后实时预览',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xff728198), fontSize: 11),
                    ),
                  )
                : GridView.builder(
                    scrollDirection: compact ? Axis.horizontal : Axis.vertical,
                    gridDelegate: compact
                        ? const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 1,
                            mainAxisExtent: 86,
                            mainAxisSpacing: 6,
                          )
                        : const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            childAspectRatio: 1.12,
                            crossAxisSpacing: 6,
                            mainAxisSpacing: 6,
                          ),
                    itemCount: session.materials.length,
                    itemBuilder: (context, index) {
                      final image = session.materials[index];
                      final missing =
                          session.targetPage(image) >=
                          (session.target?.snapshot.pageCount ?? 0);
                      final color = image.staged
                          ? const Color(0xff7854aa)
                          : image.local
                          ? const Color(0xffaa6216)
                          : const Color(0xff2869e8);
                      final card = Tooltip(
                        message: image.staged
                            ? '暂存图片：拖到右侧页面放置，拖到页面外不改变位置'
                            : '${image.source}${missing ? ' · 新单据暂无对应页' : ''}',
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color(0xfff6f8fb),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: missing
                                  ? const Color(0xffe8b972)
                                  : const Color(0xffe4eaf2),
                            ),
                          ),
                          child: Column(
                            children: [
                              Expanded(
                                child: Stack(
                                  children: [
                                    Positioned.fill(
                                      child: Padding(
                                        padding: const EdgeInsets.all(4),
                                        child: Image.memory(
                                          image.png,
                                          fit: BoxFit.contain,
                                          cacheWidth: 160,
                                        ),
                                      ),
                                    ),
                                    Positioned(
                                      right: 0,
                                      top: 0,
                                      child: SizedBox(
                                        width: 24,
                                        height: 24,
                                        child: IconButton(
                                          tooltip: '移除第 ${index + 1} 张图片',
                                          padding: EdgeInsets.zero,
                                          iconSize: 13,
                                          onPressed: busy
                                              ? null
                                              : () => session.removeMaterial(
                                                  image,
                                                ),
                                          icon: const Icon(Icons.close),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: color.withValues(alpha: .08),
                                  borderRadius: const BorderRadius.vertical(
                                    bottom: Radius.circular(5),
                                  ),
                                ),
                                child: Text(
                                  image.staged
                                      ? (image.targetPage == -1
                                            ? '暂存 · 拖到右侧'
                                            : '暂存 · ${image.targetPage! + 1}页')
                                      : image.local
                                      ? '本地 · ${image.targetPage! + 1}页'
                                      : '旧图 · ${image.page}页${missing ? ' 缺页' : ''}',
                                  textAlign: TextAlign.center,
                                  maxLines: 1,
                                  style: TextStyle(fontSize: 10, color: color),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                      final hoverCard = RepairSharedAnchor(
                        key: ValueKey(image),
                        connections: connections,
                        image: image,
                        child: card,
                      );
                      if (!image.staged) return hoverCard;
                      return Draggable<SharedPdfImage>(
                        data: image,
                        maxSimultaneousDrags: busy ? 0 : 1,
                        dragAnchorStrategy: pointerDragAnchorStrategy,
                        feedback: Material(
                          elevation: 6,
                          borderRadius: BorderRadius.circular(6),
                          child: SizedBox(
                            width: 100,
                            height: 70,
                            child: Image.memory(
                              image.png,
                              fit: BoxFit.contain,
                              cacheWidth: 200,
                            ),
                          ),
                        ),
                        childWhenDragging: Opacity(
                          opacity: .35,
                          child: hoverCard,
                        ),
                        child: hoverCard,
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxWidth < 900;
      return RepairConnectionOverlay(
        connections: connections,
        enabled: !compact,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: oldNo,
                          enabled: !busy,
                          decoration: const InputDecoration(
                            labelText: '旧单据号',
                            isDense: true,
                          ),
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8),
                        child: Icon(Icons.arrow_forward, size: 18),
                      ),
                      Expanded(
                        child: TextField(
                          controller: newNo,
                          enabled: !busy,
                          onSubmitted: (_) => load(),
                          decoration: const InputDecoration(
                            labelText: '新单据号',
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      OutlinedButton(
                        onPressed: busy ? null : load,
                        child: Text(loading ? '加载中…' : '加载单据'),
                      ),
                      ValueListenableBuilder<Map<String, RepairSelection>>(
                        valueListenable: selection,
                        builder: (context, selected, _) => OutlinedButton(
                          onPressed: busy || selected.isEmpty ? null : collect,
                          child: Text(
                            selected.isEmpty
                                ? '加入共享区'
                                : '加入共享区（${selected.length}）',
                          ),
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: busy || session.target == null
                            ? null
                            : importImage,
                        icon: const Icon(
                          Icons.add_photo_alternate_outlined,
                          size: 16,
                        ),
                        label: const Text('导入本地图片'),
                      ),
                      FilledButton(
                        onPressed:
                            busy || session.target == null || !session.needsSync
                            ? null
                            : synchronize,
                        child: const Text('应用'),
                      ),
                      OutlinedButton.icon(
                        onPressed:
                            busy ||
                                session.target?.edited != true ||
                                session.needsSync
                            ? null
                            : save,
                        icon: const Icon(Icons.save_alt, size: 16),
                        label: Text(saving ? '保存中…' : '保存到本地'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '按住 Ctrl / ⌘ 多选加入共享区；按当前页序实时预览。右键可镜像、复制或删除图片，点击应用后保存。',
                      style: TextStyle(fontSize: 12, color: Color(0xff52647c)),
                    ),
                  ),
                ],
              ),
            ),
            if (session.source != null &&
                session.target != null &&
                session.source!.snapshot.pageCount !=
                    session.target!.snapshot.pageCount)
              Container(
                margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xfffff4df),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.info_outline,
                      size: 16,
                      color: Color(0xff9d6b19),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '页数不一致：旧 ${session.source!.snapshot.pageCount} 页，新 ${session.target!.snapshot.pageCount} 页。可用镜像或复制页面对齐。',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xff8a5c12),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (busy) const LinearProgressIndicator(minHeight: 2),
            if (loadError != null ||
                session.error != null ||
                session.syncStatus != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    loadError ?? session.error ?? session.syncStatus!,
                    style: TextStyle(
                      fontSize: 12,
                      color: loadError != null || session.error != null
                          ? Colors.red.shade700
                          : const Color(0xff2869e8),
                    ),
                  ),
                ),
              ),
            if (compact)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true, label: Text('旧单据')),
                    ButtonSegment(value: false, label: Text('新单据')),
                  ],
                  selected: {showSource},
                  onSelectionChanged: (value) =>
                      setState(() => showSource = value.single),
                ),
              ),
            Expanded(
              child: compact
                  ? IndexedStack(
                      index: showSource ? 0 : 1,
                      children: [document(true), document(false)],
                    )
                  : Row(
                      children: [
                        Expanded(child: document(true)),
                        SizedBox(width: 184, child: shared(false)),
                        Expanded(child: document(false)),
                      ],
                    ),
            ),
            if (compact) SizedBox(height: 104, child: shared(true)),
          ],
        ),
      );
    },
  );
}

class _CopyPageDialog extends StatefulWidget {
  final bool fromOld, mirror;
  final int page, sourceCount, targetCount;
  final int? suggestedInsert;
  const _CopyPageDialog({
    required this.fromOld,
    this.mirror = false,
    required this.page,
    required this.sourceCount,
    required this.targetCount,
    this.suggestedInsert,
  });
  @override
  State<_CopyPageDialog> createState() => _CopyPageDialogState();
}

class _CopyPageDialogState extends State<_CopyPageDialog> {
  late final page = TextEditingController(text: '${widget.page + 1}');
  late final after = TextEditingController(
    text:
        '${widget.suggestedInsert ?? (widget.fromOld ? widget.targetCount : widget.page + 1)}',
  );
  String? error;
  @override
  void dispose() {
    page.dispose();
    after.dispose();
    super.dispose();
  }

  void submit() {
    final source = int.tryParse(page.text), target = int.tryParse(after.text);
    if (source == null ||
        source < 1 ||
        source > widget.sourceCount ||
        target == null ||
        target < 0 ||
        target > widget.targetCount) {
      setState(() => error = '请填写有效页码');
      return;
    }
    Navigator.pop(context, (page: source - 1, insertAt: target));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.mirror
          ? '在左侧复制为镜像页'
          : widget.fromOld
          ? '复制旧单据页面到新单据'
          : '复制新单据页面',
    ),
    content: SizedBox(
      width: 360,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: page,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: '来源页码（1–${widget.sourceCount}）',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: after,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText:
                  '${widget.mirror ? '左侧' : '右侧'}插入到第几页之后（0–${widget.targetCount}）',
              helperText: '0 表示最前，最大值表示末尾',
            ),
          ),
          if (error != null)
            Text(error!, style: const TextStyle(color: Colors.red)),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: submit,
        child: Text(widget.mirror ? '创建镜像页' : '复制页面'),
      ),
    ],
  );
}

class _ImportImageDialog extends StatefulWidget {
  final EditDocument document;
  final Uint8List png;
  final double ratio;
  const _ImportImageDialog({
    required this.document,
    required this.png,
    required this.ratio,
  });
  @override
  State<_ImportImageDialog> createState() => _ImportImageDialogState();
}

class _ImportImageDialogState extends State<_ImportImageDialog> {
  final page = TextEditingController(text: '1'),
      x = TextEditingController(text: '10'),
      y = TextEditingController(text: '10'),
      width = TextEditingController(text: '35');
  String? error;
  @override
  void dispose() {
    for (final c in [page, x, y, width]) {
      c.dispose();
    }
    super.dispose();
  }

  void submit() {
    final p = int.tryParse(page.text),
        left = double.tryParse(x.text),
        top = double.tryParse(y.text),
        w = double.tryParse(width.text);
    if (p == null ||
        p < 1 ||
        p > widget.document.pageSizes.length ||
        left == null ||
        top == null ||
        w == null) {
      setState(() => error = '请填写有效页码和位置');
      return;
    }
    final size = widget.document.pageSizes[p - 1];
    final h = w / widget.ratio * size.width / size.height;
    if (![left, top, w, h].every((n) => n.isFinite) ||
        left < 0 ||
        top < 0 ||
        w <= 0 ||
        left + w > 100 ||
        top + h > 100) {
      setState(() => error = '图片超出页面，请减小宽度或调整位置');
      return;
    }
    Navigator.pop(context, (
      page: p - 1,
      bounds: Rect.fromLTWH(left / 100, top / 100, w / 100, h / 100),
    ));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('导入图片到新单据'),
    content: SizedBox(
      width: 380,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 100,
              child: Image.memory(widget.png, fit: BoxFit.contain),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: page,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: '目标页码（1–${widget.document.pageSizes.length}）',
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: x,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '距左侧 %'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: y,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '距顶部 %'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: width,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '图片宽度占页面 %'),
            ),
            const SizedBox(height: 8),
            const Text(
              '保持原图比例，导入后实时预览；点击应用后保存到本地。',
              style: TextStyle(fontSize: 12),
            ),
            if (error != null)
              Text(error!, style: const TextStyle(color: Colors.red)),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: submit, child: const Text('导入并预览')),
    ],
  );
}
