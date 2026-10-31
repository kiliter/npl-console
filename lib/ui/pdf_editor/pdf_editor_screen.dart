import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;
import '../../core/maintenance_controller.dart';
import '../../core/pdf_editor/edit_session.dart';
import '../../core/pdf_editor/pdf_engine.dart';
import 'editor_canvas.dart';

const _blue = Color(0xff2869e8),
    _ink = Color(0xff1b2b42),
    _line = Color(0xffe4ebf4);

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
  bool basedOnOld = true,
      showSource = false,
      drawerOpen = true,
      textTool = false,
      loading = false;
  PdfEditObject? oldSelected, selected;
  SharedPdfImage? pending;
  String? loadError;
  late String connection = jsonEncode(widget.controller.settings.toJson());
  int loadRevision = 0;
  bool get mobile => MediaQuery.sizeOf(context).width < 900;
  bool get busy => session.busy || loading;
  @override
  void initState() {
    super.initState();
    oldNo.text = session.source?.caseNo ?? '';
    newNo.text = session.target?.caseNo ?? '';
    session.addListener(update);
    widget.controller.addListener(connectionChanged);
  }

  void update() {
    if (mounted) setState(() {});
  }

  void connectionChanged() {
    final next = jsonEncode(widget.controller.settings.toJson());
    if (next == connection) return;
    connection = next;
    loadRevision++;
    loading = false;
    selected = oldSelected = null;
    pending = null;
    session.reset();
    if (mounted) setState(() => loadError = '连接环境已更改，请重新加载单据。');
  }

  @override
  void dispose() {
    loadRevision++;
    widget.controller.removeListener(connectionChanged);
    session.removeListener(update);
    if (widget.session == null) session.dispose();
    oldNo.dispose();
    newNo.dispose();
    super.dispose();
  }

  Future<bool> confirmDiscard() async {
    if (session.target?.dirty != true) return true;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('放弃未保存的修改？'),
            content: const Text('请先保存副本，或确认放弃后继续。共享素材仍会保留。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('返回编辑'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('放弃修改'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> load() async {
    if (busy) return;
    if (newNo.text.trim().isEmpty ||
        (basedOnOld && oldNo.text.trim().isEmpty)) {
      setState(() => loadError = '请填写${basedOnOld ? '新老' : '目标'}单据号');
      return;
    }
    if (!await confirmDiscard() || !mounted) return;
    final revision = ++loadRevision,
        targetNo = newNo.text.trim(),
        sourceNo = oldNo.text.trim();
    setState(() {
      loading = true;
      loadError = null;
    });
    try {
      final target = await widget.controller.loadEditorPdf(targetNo);
      final source = basedOnOld
          ? await widget.controller.loadEditorPdf(sourceNo)
          : null;
      if (!mounted || revision != loadRevision) return;
      await session.load(
        targetNo,
        target.bytes,
        sourceNo: sourceNo,
        sourceBytes: source?.bytes,
      );
      if (!mounted || revision != loadRevision) return;
      setState(() {
        selected = oldSelected = null;
        pending = null;
        showSource = false;
      });
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

  Future<void> queryDialog() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('加载单据'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (basedOnOld)
                TextField(
                  controller: oldNo,
                  decoration: const InputDecoration(labelText: '老单据号'),
                ),
              if (basedOnOld) const SizedBox(height: 14),
              TextField(
                controller: newNo,
                decoration: const InputDecoration(labelText: '新单据号'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) await load();
  }

  Future<void> save() async {
    final doc = session.target;
    if (doc == null || busy) return;
    final bytes = Uint8List.fromList(doc.bytes);
    try {
      final result = await FilePicker.saveFile(
        bytes: bytes,
        mimeType: 'application/pdf',
        fileName:
            '${doc.caseNo.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')}_编辑.pdf',
        dialogTitle: '保存编辑后的 PDF 副本',
      );
      if (!mounted || result == null) return;
      session.markSaved(bytes);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('PDF 副本已保存；后台原单据未修改。')));
    } catch (e) {
      if (mounted) {
        setState(() => loadError = '保存失败（${e.runtimeType}），修改仍保留，可重试。');
      }
    }
  }

  Future<Uint8List?> chooseImage() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['png', 'jpg', 'jpeg', 'webp'],
      dialogTitle: '选择图片',
    );
    if (files.isEmpty) return null;
    if (await files.single.length() > 20 * 1024 * 1024) {
      throw const FormatException('图片文件不能超过 20 MiB');
    }
    return files.single.readAsBytes();
  }

  Future<void> localImage({bool replace = false}) async {
    if (busy || session.target == null) return;
    final object = selected, document = session.target;
    final revision = loadRevision;
    try {
      final bytes = await chooseImage();
      if (bytes == null ||
          !mounted ||
          revision != loadRevision ||
          !identical(document, session.target)) {
        return;
      }
      final image = img.decodeImage(bytes);
      if (image == null || image.width * image.height > 40000000) {
        throw const FormatException('图片无法读取或尺寸过大');
      }
      if (replace && object != null) {
        await session.replace(object, bytes);
        if (mounted) setState(() => selected = null);
      } else {
        setState(() {
          pending = SharedPdfImage(
            bytes,
            '本地图片',
            0,
            image.width / image.height,
          );
          showSource = false;
          drawerOpen = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => loadError = e is FormatException
              ? e.message
              : '图片读取失败（${e.runtimeType}）',
        );
      }
    }
  }

  Future<void> editText() async {
    final object = selected;
    if (object == null || object.kind != PdfObjectKind.text) {
      setState(() {
        textTool = true;
        loadError = null;
      });
      return;
    }
    final input = TextEditingController(text: object.text);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑文字块'),
        content: SizedBox(
          width: 500,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '保持原位置与字号，使用内置中文字体。较长内容不会自动跨行重排。',
                style: TextStyle(fontSize: 12, color: Colors.blueGrey),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: input,
                autofocus: true,
                decoration: const InputDecoration(labelText: '文字内容'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.text),
            child: const Text('应用'),
          ),
        ],
      ),
    );
    // Dispose after route removal, including its closing animation.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    input.dispose();
    if (result != null && mounted) {
      await session.text(object, result);
      if (mounted) setState(() => selected = null);
    }
  }

  Future<void> place(SharedPdfImage image, Offset at) async {
    if (busy) return;
    setState(() {
      pending = null;
      selected = null;
    });
    await session.insert(image, at);
  }

  Future<void> collect() async {
    final object = oldSelected;
    if (object == null) return;
    await session.collect(object);
    if (!mounted) return;
    setState(() => drawerOpen = true);
  }

  Future<void> navigate(bool source, int page) async {
    setState(() {
      if (source) {
        oldSelected = null;
      } else {
        selected = null;
      }
    });
    await session.navigate(source, page);
  }

  void materialSelected(SharedPdfImage image) {
    if (busy) return;
    setState(() {
      pending = image;
      selected = null;
      showSource = false;
      if (mobile) drawerOpen = false;
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: session.target?.dirty != true,
    onPopInvokedWithResult: (didPop, _) async {
      if (!didPop && await confirmDiscard() && context.mounted) {
        Navigator.of(context).pop();
      }
    },
    child: Column(
      children: [
        Container(
          color: Colors.white,
          padding: EdgeInsets.symmetric(
            horizontal: mobile ? 12 : 24,
            vertical: mobile ? 6 : 14,
          ),
          child: Column(
            children: [
              Row(
                children: [
                  if (!mobile)
                    const Padding(
                      padding: EdgeInsets.only(right: 24),
                      child: Text(
                        '在线单据编辑',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: _ink,
                        ),
                      ),
                    ),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(value: false, label: Text('直接编辑')),
                          ButtonSegment(value: true, label: Text('基于老单据编辑')),
                        ],
                        selected: {basedOnOld},
                        showSelectedIcon: false,
                        onSelectionChanged: busy
                            ? null
                            : (values) async {
                                if (!await confirmDiscard() || !mounted) return;
                                setState(() {
                                  basedOnOld = values.first;
                                  showSource = false;
                                });
                              },
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (!mobile && session.target?.dirty == true) ...[
                    OutlinedButton(
                      onPressed: busy
                          ? null
                          : () async {
                              if (!await confirmDiscard() || !mounted) return;
                              selected = null;
                              pending = null;
                              await session.discardChanges();
                            },
                      child: const Text('取消编辑'),
                    ),
                    const SizedBox(width: 10),
                  ],
                  FilledButton(
                    onPressed: session.target == null || busy ? null : save,
                    child: Text(mobile ? '保存' : '保存副本'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (mobile)
                Row(
                  children: [
                    if (basedOnOld)
                      Expanded(
                        child: Text(
                          '老 ${session.source?.caseNo ?? '未加载'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    if (basedOnOld)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8),
                        child: Icon(Icons.arrow_forward, size: 16),
                      ),
                    Expanded(
                      child: Text(
                        '新 ${session.target?.caseNo ?? '未加载'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    TextButton(
                      onPressed: busy
                          ? null
                          : () async {
                              await queryDialog();
                            },
                      child: const Text('更换'),
                    ),
                    if (session.target == null)
                      FilledButton(
                        onPressed: busy ? null : load,
                        child: const Text('加载'),
                      ),
                  ],
                )
              else
                Row(
                  children: [
                    if (basedOnOld) ...[
                      const Text('老单据号'),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          key: const ValueKey('editor-old-no'),
                          controller: oldNo,
                          enabled: !busy,
                          decoration: const InputDecoration(hintText: '输入老单据号'),
                        ),
                      ),
                      const SizedBox(width: 24),
                    ],
                    const Text('新单据号'),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        key: const ValueKey('editor-new-no'),
                        controller: newNo,
                        enabled: !busy,
                        decoration: const InputDecoration(hintText: '输入目标单据号'),
                        onSubmitted: (_) => load(),
                      ),
                    ),
                    const SizedBox(width: 16),
                    FilledButton(
                      onPressed: busy ? null : load,
                      child: const Text('加载单据'),
                    ),
                  ],
                ),
            ],
          ),
        ),
        if (busy) const LinearProgressIndicator(minHeight: 3),
        if (loadError != null || session.error != null)
          MaterialBanner(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            content: Text(
              loadError ?? session.error!,
              style: const TextStyle(fontSize: 12),
            ),
            actions: [
              TextButton(
                onPressed: () => setState(() {
                  loadError = null;
                  session.error = null;
                }),
                child: const Text('关闭'),
              ),
            ],
          ),
        if (mobile)
          Container(
            color: Colors.white,
            child: Row(
              children: [
                if (basedOnOld)
                  TextButton(
                    onPressed: () => setState(() => showSource = true),
                    child: Text(
                      '老单据',
                      style: TextStyle(
                        color: showSource ? _blue : Colors.blueGrey,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                TextButton(
                  onPressed: () => setState(() => showSource = false),
                  child: Text(
                    '新单据',
                    style: TextStyle(
                      color: !showSource ? _blue : Colors.blueGrey,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const Spacer(),
                OutlinedButton.icon(
                  onPressed: () => setState(() => drawerOpen = !drawerOpen),
                  icon: const Icon(Icons.photo_library_outlined, size: 17),
                  label: Text('共享素材 (${session.materials.length})'),
                ),
                const SizedBox(width: 12),
              ],
            ),
          ),
        Expanded(
          child: mobile
              ? pane(showSource)
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (basedOnOld) Expanded(flex: 4, child: pane(true)),
                    if (basedOnOld) const VerticalDivider(width: 1),
                    SizedBox(width: 210, child: materials(false)),
                    const VerticalDivider(width: 1),
                    Expanded(flex: 5, child: pane(false)),
                  ],
                ),
        ),
        if (mobile && drawerOpen)
          SizedBox(
            height: MediaQuery.sizeOf(context).height < 750 ? 142 : 168,
            child: materials(true),
          ),
      ],
    ),
  );
  Widget pane(bool source) {
    final doc = source ? session.source : session.target;
    return Column(
      children: [
        if (!mobile)
          Container(
            height: 44,
            color: const Color(0xfff4f8fd),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Text(
                  source ? '来源单据 · 仅提取素材' : '目标单据 · 编辑中',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: _ink,
                  ),
                ),
                const Spacer(),
                Flexible(
                  child: Text(
                    doc?.caseNo ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.blueGrey,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (!source && !mobile) toolbar(),
        if (pending != null && !source)
          Container(
            width: double.infinity,
            color: const Color(0xffeaf2ff),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '点击页面放置图片',
                    style: TextStyle(color: _blue, fontSize: 12),
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() => pending = null),
                  child: const Text('取消放置'),
                ),
              ],
            ),
          ),
        if (textTool && !source && selected?.kind != PdfObjectKind.text)
          const Padding(
            padding: EdgeInsets.all(6),
            child: Text(
              '点击原有文字块，再编辑内容',
              style: TextStyle(fontSize: 12, color: _blue),
            ),
          ),
        if (!source && !mobile && selected?.kind == PdfObjectKind.image)
          imageActions(),
        if (!source && selected?.kind == PdfObjectKind.text)
          TextButton.icon(
            onPressed: busy ? null : editText,
            icon: const Icon(Icons.edit, size: 16),
            label: const Text('编辑选中文字'),
          ),
        Expanded(
          child: doc == null
              ? empty(source)
              : Stack(
                  fit: StackFit.expand,
                  children: [
                    EditorCanvas(
                      key: ValueKey(source ? 'source-canvas' : 'target-canvas'),
                      document: doc,
                      selectionToolbar:
                          mobile &&
                              !source &&
                              selected?.kind == PdfObjectKind.image
                          ? imageActions()
                          : null,
                      source: source,
                      enabled: !busy,
                      selected: source ? oldSelected : selected,
                      pending: source ? null : pending,
                      textTool: !source && textTool,
                      onSelect: (object) => setState(() {
                        if (source) {
                          oldSelected = object;
                        } else {
                          selected = object;
                        }
                      }),
                      onPlace: source ? null : place,
                      onMove: source
                          ? null
                          : (object, rect) async {
                              await session.move(object, rect);
                              if (mounted) setState(() => selected = null);
                            },
                    ),
                  ],
                ),
        ),
        if (source && oldSelected != null)
          Container(
            color: Colors.white,
            padding: const EdgeInsets.all(8),
            child: FilledButton.icon(
              onPressed: busy ? null : collect,
              icon: const Icon(Icons.add, size: 17),
              label: const Text('加入共享区'),
            ),
          ),
        if (doc != null)
          Container(
            color: Colors.white,
            height: 42,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: source ? '来源上一页' : '目标上一页',
                  onPressed: busy || doc.page == 0
                      ? null
                      : () => navigate(source, doc.page - 1),
                  icon: const Icon(Icons.chevron_left, size: 18),
                ),
                Text(
                  '${doc.page + 1} / ${doc.snapshot.pageCount} 页',
                  style: const TextStyle(fontSize: 12),
                ),
                IconButton(
                  tooltip: source ? '来源下一页' : '目标下一页',
                  onPressed: busy || doc.page + 1 >= doc.snapshot.pageCount
                      ? null
                      : () => navigate(source, doc.page + 1),
                  icon: const Icon(Icons.chevron_right, size: 18),
                ),
                if (!source)
                  Text(
                    doc.dirty ? '未保存' : '已保存',
                    style: TextStyle(
                      fontSize: 11,
                      color: doc.dirty ? Colors.deepOrange : Colors.blueGrey,
                    ),
                  ),
              ],
            ),
          ),
        if (!source && mobile) toolbar(),
      ],
    );
  }

  Widget imageActions() => Container(
    color: Colors.white,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        TextButton.icon(
          onPressed: busy ? null : () => localImage(replace: true),
          icon: const Icon(Icons.find_replace, size: 17),
          label: const Text('替换图片'),
        ),
        TextButton.icon(
          onPressed: busy
              ? null
              : () async {
                  await session.delete(selected!);
                  if (mounted) setState(() => selected = null);
                },
          icon: const Icon(Icons.delete_outline, size: 17, color: Colors.red),
          label: const Text('删除', style: TextStyle(color: Colors.red)),
        ),
      ],
    ),
  );
  Widget toolbar() {
    final doc = session.target;
    if (mobile) {
      Widget action(
        String label,
        IconData icon,
        VoidCallback? onTap, {
        bool active = false,
      }) => Expanded(
        child: TextButton(
          onPressed: onTap,
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 4),
            minimumSize: const Size(44, 48),
            foregroundColor: active ? _blue : _ink,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20),
              const SizedBox(height: 3),
              Text(label, style: const TextStyle(fontSize: 10)),
            ],
          ),
        ),
      );
      final enabled = !busy && doc != null;
      return Container(
        color: Colors.white,
        height: 56,
        child: Row(
          children: [
            action(
              '选择',
              Icons.near_me_outlined,
              enabled
                  ? () => setState(() {
                      textTool = false;
                      pending = null;
                    })
                  : null,
              active: !textTool,
            ),
            action(
              '文本',
              Icons.text_fields,
              enabled ? editText : null,
              active: textTool,
            ),
            action(
              '图片',
              Icons.add_photo_alternate_outlined,
              enabled ? () => localImage() : null,
            ),
            action(
              '复制页',
              Icons.copy_outlined,
              enabled
                  ? () async {
                      selected = null;
                      await session.duplicate();
                    }
                  : null,
            ),
            action(
              '撤销',
              Icons.undo,
              enabled && doc.undo.isNotEmpty
                  ? () async {
                      selected = null;
                      await session.history(false);
                    }
                  : null,
            ),
            action(
              '重做',
              Icons.redo,
              enabled && doc.redo.isNotEmpty
                  ? () async {
                      selected = null;
                      await session.history(true);
                    }
                  : null,
            ),
          ],
        ),
      );
    }
    return Container(
      height: 46,
      color: Colors.white,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            tool(
              '选择',
              Icons.near_me_outlined,
              () => setState(() {
                textTool = false;
                pending = null;
              }),
              active: !textTool,
            ),
            tool('编辑文本', Icons.text_fields, editText, active: textTool),
            tool(
              '新增图片',
              Icons.add_photo_alternate_outlined,
              () => localImage(),
            ),
            tool('复制页面', Icons.copy_outlined, () async {
              selected = null;
              await session.duplicate();
            }),
            IconButton(
              tooltip: '撤销',
              onPressed: busy || doc == null || doc.undo.isEmpty
                  ? null
                  : () async {
                      selected = null;
                      await session.history(false);
                    },
              icon: const Icon(Icons.undo, size: 19),
            ),
            IconButton(
              tooltip: '重做',
              onPressed: busy || doc == null || doc.redo.isEmpty
                  ? null
                  : () async {
                      selected = null;
                      await session.history(true);
                    },
              icon: const Icon(Icons.redo, size: 19),
            ),
          ],
        ),
      ),
    );
  }

  Widget tool(
    String label,
    IconData icon,
    VoidCallback action, {
    bool active = false,
  }) => TextButton.icon(
    onPressed: busy || session.target == null ? null : action,
    style: TextButton.styleFrom(
      foregroundColor: active ? _blue : _ink,
      backgroundColor: active ? const Color(0xffeaf2ff) : null,
    ),
    icon: Icon(icon, size: 18),
    label: Text(label, style: const TextStyle(fontSize: 12)),
  );
  Widget empty(bool source) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            source ? Icons.find_in_page_outlined : Icons.edit_document,
            size: 42,
            color: const Color(0xffa3b4cc),
          ),
          const SizedBox(height: 16),
          Text(
            source ? '加载老单据后，点击图片提取素材' : '加载单据，开始编辑 PDF',
            style: const TextStyle(color: Colors.blueGrey, fontSize: 14),
          ),
          const SizedBox(height: 8),
          const Text(
            '原始单据保持不变，编辑后可另存为 PDF 副本',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.blueGrey, fontSize: 11),
          ),
          if (mobile)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: OutlinedButton(
                onPressed: busy ? null : queryDialog,
                child: const Text('输入单据号'),
              ),
            ),
        ],
      ),
    ),
  );
  Widget materials(bool horizontal) {
    return Container(
      color: Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(12, horizontal ? 6 : 14, 4, 4),
            child: Row(
              children: [
                Text(
                  '共享素材 (${session.materials.length})',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: _ink,
                    fontSize: 14,
                  ),
                ),
                const Spacer(),
                if (horizontal)
                  IconButton(
                    tooltip: '清空共享素材',
                    onPressed: busy || session.materials.isEmpty
                        ? null
                        : () {
                            pending = null;
                            session.clearMaterials();
                          },
                    icon: const Icon(Icons.delete_outline, size: 17),
                  ),
                if (horizontal)
                  TextButton(
                    onPressed: () => setState(() => drawerOpen = false),
                    child: const Text('收起'),
                  )
                else
                  IconButton(
                    tooltip: '清空共享素材',
                    onPressed: busy || session.materials.isEmpty
                        ? null
                        : () {
                            pending = null;
                            session.clearMaterials();
                          },
                    icon: const Icon(Icons.delete_outline, size: 17),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              horizontal ? '选中素材后，点击页面放置' : '拖入目标 PDF，也可点击素材后点击页面放置',
              style: const TextStyle(color: Colors.blueGrey, fontSize: 11),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: session.materials.isEmpty
                ? const Center(
                    child: Text(
                      '从老单据选取图片\n或使用「新增图片」',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: Colors.blueGrey),
                    ),
                  )
                : ListView.separated(
                    scrollDirection: horizontal
                        ? Axis.horizontal
                        : Axis.vertical,
                    padding: const EdgeInsets.all(10),
                    itemCount: session.materials.length,
                    separatorBuilder: (_, _) => SizedBox(
                      width: horizontal ? 10 : 0,
                      height: horizontal ? 0 : 16,
                    ),
                    itemBuilder: (context, index) {
                      final image = session.materials[index];
                      final content = InkWell(
                        onTap: busy ? null : () => materialSelected(image),
                        child: Container(
                          width: horizontal ? 160 : null,
                          padding: const EdgeInsets.all(5),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: identical(pending, image) ? _blue : _line,
                              width: identical(pending, image) ? 2 : 1,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (horizontal)
                                Expanded(
                                  child: SizedBox(
                                    width: double.infinity,
                                    child: Image.memory(
                                      image.png,
                                      fit: BoxFit.contain,
                                    ),
                                  ),
                                )
                              else
                                SizedBox(
                                  height: 105,
                                  width: double.infinity,
                                  child: Image.memory(
                                    image.png,
                                    fit: BoxFit.contain,
                                  ),
                                ),
                              const SizedBox(height: 4),
                              Text(
                                '来源：${image.source} · 第 ${image.page} 页',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: Colors.blueGrey,
                                ),
                              ),
                              if (!horizontal)
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: IconButton(
                                    tooltip: '移除素材',
                                    onPressed: busy
                                        ? null
                                        : () {
                                            if (identical(pending, image)) {
                                              pending = null;
                                            }
                                            session.removeMaterial(image);
                                          },
                                    icon: const Icon(Icons.close, size: 14),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                      return horizontal
                          ? content
                          : Draggable<SharedPdfImage>(
                              data: image,
                              maxSimultaneousDrags: busy ? 0 : 1,
                              feedback: Material(
                                elevation: 6,
                                child: SizedBox(
                                  width: 160,
                                  height: 100,
                                  child: Image.memory(
                                    image.png,
                                    fit: BoxFit.contain,
                                  ),
                                ),
                              ),
                              childWhenDragging: Opacity(
                                opacity: .4,
                                child: content,
                              ),
                              child: content,
                            );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
