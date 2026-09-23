import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import '../core/breakpoints.dart';
import '../core/contracts.dart';
import '../core/maintenance_controller.dart';
import 'file_preview.dart';
import 'image_gallery.dart';
import 'settings_dialog.dart';
import 'query_sheet.dart';
import 'table_query_sheet.dart';
import 'work_details.dart';
import 'logs_dialog.dart';

const ink = Color(0xff1b2b42),
    muted = Color(0xff8192a9),
    blue = Color(0xff2869e8),
    line = Color(0xffe4ebf4);
const sections = ['单据信息', '单据 PDF', '报文信息', '签字信息', '图片信息'];
const sectionIcons = [
  Icons.article_outlined,
  Icons.picture_as_pdf_outlined,
  Icons.data_object,
  Icons.draw_outlined,
  Icons.photo_library_outlined,
];

/// 桌面结果、字段、纸张并排；手机独立搜索和详情，共用原有只读业务控制器。
class MaintenanceScreen extends StatefulWidget {
  final MaintenanceController controller;
  const MaintenanceScreen({super.key, required this.controller});
  @override
  State<MaintenanceScreen> createState() => _MaintenanceScreenState();
}

class _MaintenanceScreenState extends State<MaintenanceScreen> {
  MaintenanceController get c => widget.controller;
  final draft = QueryDraft();
  final history = <QueryDraft>[];
  String filter = '';
  int section = 0;
  bool get mobile => isMobileWidth(MediaQuery.sizeOf(context).width);
  @override
  void initState() {
    super.initState();
    c.addListener(update);
  }

  void update() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    c.removeListener(update);
    super.dispose();
  }

  /// 搜索作为独立路由呈现，软键盘只压缩表单，不挤占工单阅读区。
  Future<void> openSearch() async {
    try {
      final saved = await loadQueryHistory();
      history
        ..clear()
        ..addAll(saved);
    } catch (_) {
      c.status('搜索历史读取失败，仍可输入条件查询。', isError: true);
    }
    if (!mounted) return;
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.white,
      constraints: const BoxConstraints(maxWidth: 600),
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .9,
          child: QuerySheet(controller: c, draft: draft, history: history),
        ),
      ),
    );
    if (result == true && mounted) {
      setState(() {
        section = 0;
        filter = '';
      });
    }
  }

  void settings() => showDialog<void>(
    context: context,
    builder: (_) => SettingsDialog(controller: c),
  );
  void logs() => showDialog<void>(
    context: context,
    builder: (_) => LogsDialog(controller: c),
  );

  /// 数据查询作为独立弹层呈现，不影响当前工单查询结果与阅读区。
  void openTableQuery() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.white,
    constraints: const BoxConstraints(maxWidth: 720),
    builder: (context) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .9,
        child: TableQuerySheet(controller: c),
      ),
    ),
  );
  void choose(Record record) {
    section = 0;
    c.chooseWork(record);
  }

  /// PDF 与详情共享工单类别；切换其他类别时仍由控制器按选中工单关联查询。
  Future<void> navigate(int index) async {
    if (c.work == null) {
      c.status('请先选择一份工单，再查看关联资料。');
      return;
    }
    setState(() => section = index);
    if (index < 2) {
      if (c.category != Category.work) await c.selectCategory(Category.work);
      if (index == 1) {
        await c.showPdf();
      } else if (c.asset != null) {
        await c.selectCategory(Category.work);
      }
    } else {
      await c.selectCategory(Category.values[index - 1]);
    }
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.keyK, meta: true): openSearch,
      const SingleActivator(LogicalKeyboardKey.keyK, control: true): openSearch,
    },
    child: Focus(
      child: Scaffold(
        bottomNavigationBar: mobile && c.work != null
            ? NavigationBar(
                height: 66,
                selectedIndex: section,
                labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
                onDestinationSelected: navigate,
                destinations: [
                  for (var i = 0; i < sections.length; i++)
                    NavigationDestination(
                      icon: Icon(sectionIcons[i], size: 21),
                      label: ['详情', 'PDF', '报文', '签字', '图片'][i],
                    ),
                ],
              )
            : null,
        body: SafeArea(
          child: Column(
            children: [
              header(),
              // 状态行移动端独立成行；桌面端已并入顶栏，仅保留查询进度条。
              if (mobile) status(),
              if (!mobile && c.querying)
                LinearProgressIndicator(
                  value: c.total == 0 ? null : c.completed / c.total,
                  minHeight: 3,
                ),
              Expanded(child: mobile ? mobileBody() : desktopBody()),
            ],
          ),
        ),
      ),
    ),
  );
  Widget header() => Container(
    padding: EdgeInsets.symmetric(
      horizontal: mobile ? 16 : 24,
      vertical: mobile ? 10 : 8,
    ),
    decoration: const BoxDecoration(
      color: Colors.white,
      border: Border(bottom: BorderSide(color: line)),
    ),
    child: Row(
      children: [
        if (mobile && c.work != null)
          IconButton(
            tooltip: '返回工单列表',
            onPressed: c.showWorks,
            icon: const Icon(Icons.arrow_back_ios_new, size: 18),
          )
        else ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.asset(
              'assets/branding/app-icon.png',
              width: 36,
              height: 36,
            ),
          ),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Text(
            mobile && c.work != null ? sections[section] : '无纸化 / 维护中心',
            style: TextStyle(
              fontSize: mobile ? 17 : 19,
              fontWeight: FontWeight.w700,
              color: ink,
            ),
          ),
        ),
        if (!mobile) ...[
          SizedBox(
            // 搜索框宽随屏宽缩放，窄桌面优先保证右侧按钮不溢出。
            width: math.min(
              MediaQuery.sizeOf(context).width >= 1500 ? 560 : 400,
              MediaQuery.sizeOf(context).width * .35,
            ),
            child: searchLaunch(),
          ),
          // 内联状态仅在宽桌面展示，窄桌面保留操作按钮空间。
          if (MediaQuery.sizeOf(context).width >= 1100) ...[
            const SizedBox(width: 12),
            statusInline(),
          ],
          IconButton(
            tooltip: '缓存命中 ${c.cacheHits} 次 · 点击清空',
            onPressed: c.clearCache,
            icon: const Icon(Icons.cached, size: 19),
          ),
          TextButton.icon(
            onPressed: openTableQuery,
            icon: const Icon(Icons.table_view_outlined, size: 18),
            label: const Text('数据查询'),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            onPressed: logs,
            icon: const Icon(Icons.data_object, size: 18),
            label: Text('接口记录 ${c.logs.length}'),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: settings,
            icon: const Icon(Icons.tune, size: 17),
            label: const Text('设置'),
          ),
        ] else ...[
          IconButton(
            key: const ValueKey('mobile-search'),
            tooltip: '查询条件',
            onPressed: openSearch,
            icon: const Icon(Icons.search),
          ),
          PopupMenuButton<String>(
            tooltip: '更多操作',
            onSelected: (v) {
              if (v == 'settings') settings();
              if (v == 'logs') logs();
              if (v == 'tables') openTableQuery();
              if (v == 'cache') c.clearCache();
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'tables', child: Text('数据查询')),
              const PopupMenuItem(value: 'settings', child: Text('连接与密钥设置')),
              PopupMenuItem(
                value: 'logs',
                child: Text('接口记录 · ${c.logs.length}'),
              ),
              const PopupMenuItem(value: 'cache', child: Text('清空查询缓存')),
            ],
          ),
        ],
      ],
    ),
  );
  Widget searchLaunch() => InkWell(
    onTap: openSearch,
    borderRadius: BorderRadius.circular(12),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      decoration: BoxDecoration(
        color: const Color(0xfff4f7fc),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: line),
      ),
      child: Row(
        children: [
          const Icon(Icons.search, size: 19, color: blue),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              draft.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: muted),
            ),
          ),
          const Icon(Icons.tune, size: 18, color: muted),
        ],
      ),
    ),
  );
  /// 桌面端顶栏内联状态：绿点 + 当前消息 + 取消 / 查看失败，不独占一行。
  Widget statusInline() => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(
        c.error ? Icons.error_outline : Icons.circle,
        size: c.error ? 13 : 6,
        color: c.error ? Colors.red : const Color(0xff219975),
      ),
      const SizedBox(width: 6),
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 200),
        child: Text(
          c.message,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 10,
            color: c.error ? Colors.red : muted,
          ),
        ),
      ),
      if (c.busy) TextButton(onPressed: c.cancel, child: const Text('取消')),
      if (c.failures.isNotEmpty)
        TextButton(
          onPressed: () => showText('失败月份', c.failures.join('\n')),
          child: const Text('查看失败'),
        ),
    ],
  );
  Widget status() => Column(
    children: [
      Padding(
        padding: EdgeInsets.symmetric(
          horizontal: mobile ? 16 : 24,
          vertical: 8,
        ),
        child: Row(
          children: [
            Icon(
              c.error ? Icons.error_outline : Icons.circle,
              size: c.error ? 14 : 6,
              color: c.error ? Colors.red : const Color(0xff219975),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                c.message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: c.error ? Colors.red : muted,
                ),
              ),
            ),
            if (c.busy)
              TextButton(onPressed: c.cancel, child: const Text('取消')),
            if (c.failures.isNotEmpty)
              TextButton(
                onPressed: () => showText('失败月份', c.failures.join('\n')),
                child: const Text('查看失败'),
              ),
          ],
        ),
      ),
      if (c.querying)
        LinearProgressIndicator(
          value: c.total == 0 ? null : c.completed / c.total,
          minHeight: 3,
        ),
    ],
  );
  Widget desktopBody() => Padding(
    padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
    child: Row(
      children: [
        // 侧栏宽度随屏宽响应式加宽（250 / 290 / 330）。
        SizedBox(
          width: sidebarWidth(MediaQuery.sizeOf(context).width),
          child: panel(child: results(compact: true)),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: panel(
            child: c.work == null
                ? empty(
                    '选择工单，展开完整关联资料',
                    '左侧选择一份查询结果，查看单据、报文和影像。',
                    action: openSearch,
                    actionLabel: '查询工单',
                  )
                : workspace(),
          ),
        ),
      ],
    ),
  );
  Widget mobileBody() => c.work == null
      ? Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: searchLaunch(),
            ),
            Expanded(child: results()),
          ],
        )
      : workspace();
  Widget panel({required Widget child}) => Container(
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: line),
    ),
    child: child,
  );

  /// 全部工单连续展示，不按窗口高度截断；卡片与当前选中项始终同步。
  Widget results({bool compact = false}) {
    final rows = c.works
        .where(
          (w) => jsonEncode(w).toLowerCase().contains(filter.toLowerCase()),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 10, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '查询结果 · ${c.works.length}',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                tooltip: '重新查询',
                onPressed: openSearch,
                icon: const Icon(Icons.manage_search, size: 20),
              ),
            ],
          ),
        ),
        if (c.works.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            child: TextField(
              onChanged: (v) => setState(() => filter = v),
              decoration: const InputDecoration(
                hintText: '在结果中筛选',
                prefixIcon: Icon(Icons.search, size: 18),
              ),
            ),
          ),
        Expanded(
          child: rows.isEmpty
              ? empty(
                  c.querying
                      ? '正在查询工单'
                      : c.works.isEmpty
                      ? '从一次受理开始'
                      : '没有匹配的工单',
                  c.works.isEmpty ? '支持手机号、受理流水和单据号查询' : '尝试其他筛选关键词',
                  action: openSearch,
                  actionLabel: '查找工单',
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 14),
                  itemCount: rows.length,
                  separatorBuilder: (_, i) => const SizedBox(height: 8),
                  itemBuilder: (context, index) =>
                      workCard(rows[index], compact),
                ),
        ),
      ],
    );
  }

  Widget workCard(Record row, bool compact) {
    final selected = identical(c.work, row);
    return AnimatedContainer(
      duration: MediaQuery.of(context).disableAnimations
          ? Duration.zero
          : const Duration(milliseconds: 180),
      decoration: BoxDecoration(
        color: selected ? const Color(0xffeff5ff) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: selected ? blue : line),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => choose(row),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${row['opName'] ?? '业务工单'}',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const Icon(Icons.chevron_right, size: 17, color: muted),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '${row['caseNo'] ?? '—'}',
                  style: const TextStyle(
                    fontFamily: 'Menlo',
                    fontSize: 11,
                    color: muted,
                  ),
                ),
                if (!compact) ...[
                  const SizedBox(height: 7),
                  Text(
                    '${row['phoneNo'] ?? '—'} · ${row['groupName'] ?? row['sysAccept'] ?? '—'}',
                    style: const TextStyle(fontSize: 12, color: muted),
                  ),
                ],
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 5,
                  children: [
                    Text(
                      '${row['opTime'] ?? row['opMonth'] ?? '—'}',
                      style: const TextStyle(fontSize: 10, color: muted),
                    ),
                    badge('${row['stsDesc'] ?? row['sts'] ?? '状态未提供'}'),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget badge(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: const Color(0xffeaf7f1),
      borderRadius: BorderRadius.circular(5),
    ),
    child: Text(
      text,
      style: const TextStyle(fontSize: 10, color: Color(0xff26886b)),
    ),
  );
  Widget workspace() => Column(
    children: [
      // 工单头部：桌面端标题、状态与单据号同行内联，压低头部高度。
      Padding(
        padding: EdgeInsets.symmetric(
          horizontal: mobile ? 16 : 20,
          vertical: mobile ? 16 : 12,
        ),
        child: Row(
          children: [
            Flexible(
              child: Text(
                '${c.work!['opName'] ?? '业务单据'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                  color: ink,
                ),
              ),
            ),
            const SizedBox(width: 10),
            badge('${c.work!['stsDesc'] ?? c.work!['sts'] ?? '状态未提供'}'),
            if (!mobile) ...[
              const SizedBox(width: 12),
              Flexible(
                child: SelectableText(
                  '${c.work!['caseNo'] ?? '—'}',
                  style: const TextStyle(
                    fontFamily: 'Menlo',
                    fontSize: 11,
                    color: muted,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      if (mobile)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Align(
            alignment: Alignment.centerLeft,
            child: SelectableText(
              '${c.work!['caseNo'] ?? '—'}',
              style: const TextStyle(
                fontFamily: 'Menlo',
                fontSize: 11,
                color: muted,
              ),
            ),
          ),
        ),
      if (!mobile)
        Row(
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  children: [
                    for (var i = 0; i < sections.length; i++)
                      TextButton.icon(
                        onPressed: () => navigate(i),
                        style: TextButton.styleFrom(
                          foregroundColor: section == i ? blue : muted,
                          backgroundColor: section == i
                              ? const Color(0xffeaf2ff)
                              : null,
                        ),
                        icon: Icon(sectionIcons[i], size: 17),
                        label: Text(sections[i]),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      const Divider(height: 1),
      if (section >= 2) assetTools(),
      Expanded(
        child: AnimatedSwitcher(
          duration: MediaQuery.of(context).disableAnimations
              ? Duration.zero
              : const Duration(milliseconds: 180),
          child: section == 0 ? detailsArea() : content(),
        ),
      ),
    ],
  );
  /// 单据信息全宽单栏展示，不再与 PDF 分栏（原型已定稿）。
  Widget detailsArea() => WorkDetails(
    key: ValueKey(c.work),
    record: c.work!,
    onDownload: downloadJson,
  );
  Widget assetTools() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    child: Row(
      children: [
        if (c.assets.isNotEmpty && c.category == Category.message)
          Expanded(
            child: DropdownButtonFormField<Asset>(
              key: ValueKey(c.asset),
              initialValue: c.assets.contains(c.asset)
                  ? c.asset
                  : c.assets.first,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: '报文文件 · ${c.assets.length} 份',
              ),
              items: c.assets
                  .map(
                    (a) => DropdownMenuItem(
                      value: a,
                      child: Text(a.label, overflow: TextOverflow.ellipsis),
                    ),
                  )
                  .toList(),
              onChanged: (a) {
                if (a != null) c.loadAsset(a);
              },
            ),
          )
        else
          Expanded(
            child: Text(
              '关联资料 · ${c.assets.length} 份',
              style: const TextStyle(color: muted, fontSize: 12),
            ),
          ),
        IconButton(
          tooltip: '刷新关联列表',
          onPressed: c.busy
              ? null
              : () => c.selectCategory(c.category, forceRefresh: true),
          icon: const Icon(Icons.refresh, size: 20),
        ),
        if (c.linkedRecords.isNotEmpty)
          IconButton(
            tooltip: '关联记录详情',
            onPressed: () => showText(
              '关联记录',
              const JsonEncoder.withIndent('  ').convert(c.linkedRecords),
            ),
            icon: const Icon(Icons.data_object, size: 20),
          ),
      ],
    ),
  );
  Widget content() {
    if (c.gallery.isNotEmpty && section >= 3) {
      return ImageGallery(controller: c, key: ValueKey(c.gallery));
    }
    if (c.busy) return empty('正在读取关联资料', c.message, loading: true);
    if (c.error) {
      return empty(
        '资料读取未完成',
        c.message,
        action: () => section < 2
            ? c.showPdf()
            : c.selectCategory(c.category, forceRefresh: true),
        actionLabel: '重试',
      );
    }
    if (c.bytes != null) {
      return FilePreview(
        key: ValueKey(c.bytes),
        bytes: c.bytes!,
        type: c.contentType,
        name: c.asset?.name ?? '单据',
        onDownload: downloadAsset,
        onRefresh: c.asset == null
            ? null
            : () => c.loadAsset(c.asset!, forceRefresh: true),
        // 上传修复是危险写操作，仅「单据 PDF」页提供入口。
        onUpload: section == 1 && c.asset != null && c.work != null
            ? uploadRepair
            : null,
      );
    }
    return empty(
      section < 2 ? '单据 PDF' : '暂无关联资料',
      section < 2 ? '打开原始单据，连续阅读全部页面' : '当前工单没有此类文件',
      action: section < 2 ? c.showPdf : null,
      actionLabel: '打开 PDF',
    );
  }

  Widget empty(
    String title,
    String subtitle, {
    VoidCallback? action,
    String actionLabel = '重试',
    bool loading = false,
  }) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              color: const Color(0xffeaf1fb),
              borderRadius: BorderRadius.circular(22),
            ),
            child: loading
                ? const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(
                    Icons.article_outlined,
                    size: 32,
                    color: Color(0xff7899ca),
                  ),
          ),
          const SizedBox(height: 20),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: ink,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, height: 1.7, color: muted),
          ),
          if (action != null) ...[
            const SizedBox(height: 18),
            FilledButton.tonal(onPressed: action, child: Text(actionLabel)),
          ],
        ],
      ),
    ),
  );
  Future<void> save(String name, Uint8List bytes) async {
    try {
      final path = await FilePicker.saveFile(
        fileName: name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_'),
        bytes: bytes,
        dialogTitle: '保存查询文件',
      );
      c.status(path == null ? '已取消保存' : '文件已保存：$path');
    } catch (e) {
      c.status('文件保存失败：$e', isError: true);
    }
  }

  void downloadJson() => save(
    '${c.work!['caseNo']}.json',
    Uint8List.fromList(
      utf8.encode(
        const JsonEncoder.withIndent('  ').convert(woInfoFields(c.work!)),
      ),
    ),
  );
  void downloadAsset() {
    if (c.bytes != null) save(c.asset?.name ?? '单据文件', c.bytes!);
  }

  /// 上传修复流程（危险写操作）：选择修复 PDF → 备份当前文件到本地 →
  /// 三级确认（单据信息 → 备份确认 → 修复确认）→ 上传 → 强制刷新预览最新 PDF。
  /// 任一步取消或失败都立即终止，绝不发出上传请求。
  Future<void> uploadRepair() async {
    final selectedWork = c.work, selectedAsset = c.asset, currentBytes = c.bytes;
    if (selectedWork == null || selectedAsset == null || currentBytes == null) {
      c.status('请先打开单据 PDF，再执行上传修复。', isError: true);
      return;
    }
    // 第一步：选择修复用 PDF 文件。
    final picked = await FilePicker.pickFiles(
      dialogTitle: '选择修复用 PDF 文件',
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    if (!mounted || picked.isEmpty) return;
    final file = picked.single;
    final Uint8List newBytes;
    try {
      newBytes = await file.readAsBytes();
    } catch (e) {
      c.status('文件读取失败：$e', isError: true);
      return;
    }
    if (!mounted) return;
    if (newBytes.isEmpty) {
      c.status('所选文件为空，无法上传。', isError: true);
      return;
    }
    // 第二步：先弹内部备份提示，用户点击「保存备份文件」才调系统保存框；
    // 未成功保存或取消都终止流程，绝不继续上传。
    final backup = await promptBackup(selectedAsset.name, currentBytes);
    if (!mounted) return;
    if (backup == null) {
      c.status('已取消备份，上传终止。', isError: true);
      return;
    }
    // 目标参数预填自当前文件（与下载读取一致），第一级确认中可修改。
    final Record preset;
    try {
      preset = selectedAsset.obsBody(selectedWork, c.settings);
    } on FormatException catch (e) {
      c.status(e.message, isError: true);
      return;
    }
    if (!mounted) return;
    // 第一级确认：核对单据号、CRM 流水号（受理流水）与业务月份，确认目标参数。
    final target = await confirmRepairTarget(selectedWork, file.name, newBytes.length, preset);
    if (!mounted || target == null) return;
    // 第二级确认：确认当前单据已备份到本地。
    final backupOk = await confirmRepairBackup(backup);
    if (!mounted || !backupOk) return;
    // 第三级确认：最终确认执行修复（上传覆盖同名对象）。
    final repairOk = await confirmRepair(file.name, target);
    if (!mounted || !repairOk) return;
    try {
      await c.uploadFile(
        file.name,
        newBytes,
        '${target['bucketName']}',
        '${target['objectName']}',
        '${target['ext8']}',
      );
    } catch (_) {
      // uploadFile 已把失败原因写入状态条，此处不再重复提示。
      return;
    }
    if (!mounted) return;
    // 上传成功后重新走下载接口读取 OBS，预览最新的 PDF。
    await c.loadAsset(selectedAsset, forceRefresh: true);
  }

  /// 上传前的内部备份提示：用户主动点击「保存备份文件」才弹出系统保存框，
  /// 保存成功后点「已备份，继续」进入后续确认；任何取消都返回 null 终止上传。
  Future<String?> promptBackup(String assetName, Uint8List bytes) async {
    String? savedPath;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) => AlertDialog(
          title: const Text('备份当前单据（上传前必做）'),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('上传修复文件前，请先把当前单据 PDF 保存到本地留存，以便上传异常时恢复。'),
                if (savedPath != null) ...[
                  const SizedBox(height: 10),
                  const Text(
                    '已保存到：',
                    style: TextStyle(fontSize: 12, color: muted),
                  ),
                  SelectableText(
                    savedPath!,
                    style: const TextStyle(fontFamily: 'Menlo', fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消上传'),
            ),
            if (savedPath == null)
              FilledButton.icon(
                onPressed: () async {
                  final path = await FilePicker.saveFile(
                    fileName: assetName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_'),
                    bytes: bytes,
                    dialogTitle: '备份当前单据 PDF（上传前必做）',
                  );
                  if (path != null) setState(() => savedPath = '$path');
                },
                icon: const Icon(Icons.save_alt, size: 18),
                label: const Text('保存备份文件'),
              )
            else
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('已备份，继续'),
              ),
          ],
        ),
      ),
    );
    return confirmed == true ? savedPath : null;
  }

  /// 第一级确认：展示单据号、CRM 流水号（受理流水）、业务月份与修复文件，
  /// 目标 OBS 参数按当前文件预填、允许修改；返回确认后的目标参数，取消返回 null。
  Future<Record?> confirmRepairTarget(
    Record work,
    String fileName,
    int fileSize,
    Record preset,
  ) {
    final bucket = TextEditingController(text: '${preset['bucketName']}');
    final object = TextEditingController(text: '${preset['objectName']}');
    final ext8 = TextEditingController(text: '${preset['ext8']}');
    // 控制器不手动 dispose：关闭动画期间 TextField 仍在树中，
    // 提前释放会触发 use-after-dispose；该弹窗为低频手动操作，影响可忽略。
    return showDialog<Record>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('确认单据信息（1 / 3）'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('单据号：${work['caseNo'] ?? '—'}'),
                const SizedBox(height: 6),
                Text('CRM 流水号（受理流水）：${work['sysAccept'] ?? '—'}'),
                const SizedBox(height: 6),
                Text('业务月份：${work['opMonth'] ?? '—'}'),
                const Divider(height: 28),
                Text(
                  '修复文件：$fileName · ${(fileSize / 1024).toStringAsFixed(1)} KB',
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: bucket,
                  decoration: const InputDecoration(
                    labelText: 'OBS 桶 bucketName',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: object,
                  decoration: const InputDecoration(
                    labelText: '对象名 objectName',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: ext8,
                  decoration: const InputDecoration(
                    labelText: '加密标识 ext8',
                    isDense: true,
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (bucket.text.trim().isEmpty || object.text.trim().isEmpty) {
                return;
              }
              Navigator.pop(dialogContext, {
                'bucketName': bucket.text.trim(),
                'objectName': object.text.trim(),
                'ext8': ext8.text.trim().isEmpty ? '0' : ext8.text.trim(),
              });
            },
            child: const Text('确认无误，继续'),
          ),
        ],
      ),
    );
  }

  /// 第二级确认：展示备份保存路径，必须勾选确认已备份才能继续。
  Future<bool> confirmRepairBackup(String backupPath) async {
    var checked = false;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) => AlertDialog(
          title: const Text('确认备份（2 / 3）'),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('当前单据 PDF 已备份到：'),
                const SizedBox(height: 6),
                SelectableText(
                  backupPath,
                  style: const TextStyle(fontFamily: 'Menlo', fontSize: 12),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: checked,
                  onChanged: (value) =>
                      setState(() => checked = value ?? false),
                  title: const Text('我确认当前单据已备份到本地留存'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: checked
                  ? () => Navigator.pop(dialogContext, true)
                  : null,
              child: const Text('已备份，继续'),
            ),
          ],
        ),
      ),
    );
    return result ?? false;
  }

  /// 第三级确认：红色警示的最终确认，点击「确认修复」才真正发起上传。
  Future<bool> confirmRepair(String fileName, Record target) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('确认修复（3 / 3）'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '即将用「$fileName」覆盖 OBS 中的同名对象，此操作不可撤销！',
                style: const TextStyle(
                  color: Colors.red,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              Text('OBS 桶：${target['bucketName']}'),
              const SizedBox(height: 6),
              Text('对象名：${target['objectName']}'),
              const SizedBox(height: 6),
              Text('加密标识 ext8：${target['ext8']}'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('确认修复'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  void showText(String title, String value) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 740,
        child: SingleChildScrollView(
          child: SelectableText(
            value,
            style: const TextStyle(
              fontFamily: 'Menlo',
              fontSize: 12,
              height: 1.7,
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Clipboard.setData(ClipboardData(text: value)),
          child: const Text('复制'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}
