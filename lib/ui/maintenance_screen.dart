import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import '../core/breakpoints.dart';
import '../core/contracts.dart';
import '../core/maintenance_controller.dart';
import '../core/secure_links.dart';
import 'file_preview.dart';
import 'image_gallery.dart';
import 'listenable_selector.dart';
import 'log_files_sheet.dart';
import 'settings_dialog.dart';
import 'query_sheet.dart';
import 'table_query_sheet.dart';
import 'web_page.dart';
import 'work_details.dart';
import 'logs_dialog.dart';
import 'pdf_editor/pdf_editor_screen.dart';
import 'batch_repair/batch_repair_screen.dart';
import '../core/pdf_editor/edit_session.dart';

const ink = Color(0xff0f1e36),
    muted = Color(0xff7f91ab),
    blue = Color(0xff2563eb),
    line = Color(0xffdde6f1);
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
  final PdfEditSession? editorSession;
  const MaintenanceScreen({
    super.key,
    required this.controller,
    this.editorSession,
  });
  @override
  State<MaintenanceScreen> createState() => _MaintenanceScreenState();
}

class _MaintenanceScreenState extends State<MaintenanceScreen> {
  MaintenanceController get c => widget.controller;
  final draft = QueryDraft();
  final history = <QueryDraft>[];
  String filter = '';
  int section = 0;
  bool editorTab = false, editorOpened = false;

  /// 批量修复只在桌面端（Windows、macOS）提供。
  bool batchTab = false, batchOpened = false;
  static final batchAvailable = Platform.isMacOS || Platform.isWindows;

  /// 单据修复与批量修复都是整页工具，顶栏与底部导航的处理相同。
  bool get toolTab => editorTab || batchTab;
  late final editorSession = widget.editorSession ?? PdfEditSession();
  bool get mobile => isMobileWidth(MediaQuery.sizeOf(context).width);
  @override
  void initState() {
    super.initState();
    _rootKey = _rootSelect();
    c.addListener(update);
  }

  /// 整页骨架只依赖选中工单与连接设置；其余区域（状态条、进度、结果列表、
  /// 资料区、接口记录数）由各自的 ListenableSelector 局部重建，
  /// 避免每次请求、每张图片加载完成都重建整页（包括后台的单据修复页）。
  Object? _rootKey;
  Object? _rootSelect() => (c.work, c.settings);

  void update() {
    if (!mounted) return;
    final next = _rootSelect();
    if (next == _rootKey) return;
    setState(() => _rootKey = next);
  }

  /// 局部监听：仅 [select] 结果变化时重建 [build]。
  Widget watch<T>(T Function() select, Widget Function() build) =>
      ListenableSelector<T>(
        listenable: c,
        selector: select,
        builder: (context, _) => build(),
      );

  /// 单据修复页实例常驻：整页骨架重建时 Flutter 直接复用，不触发编辑器重建。
  late final Widget editorScreen = PdfEditorScreen(
    controller: c,
    session: editorSession,
  );
  late final Widget batchScreen = BatchRepairScreen(controller: c);

  /// 工单的小写 JSON 文本，用于结果筛选；工单记录查询后不再修改，可安全缓存。
  static final _searchTexts = Expando<String>('workSearchText');
  static String _searchText(Record work) =>
      _searchTexts[work] ??= jsonEncode(work).toLowerCase();

  @override
  void dispose() {
    c.removeListener(update);
    if (widget.editorSession == null) editorSession.dispose();
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
    final result = mobile
        ? await showModalBottomSheet<bool>(
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
          )
        : await showDialog<bool>(
            context: context,
            builder: (context) => Dialog(
              backgroundColor: Colors.white,
              surfaceTintColor: Colors.transparent,
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: const BorderSide(color: line),
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 560,
                  maxHeight: MediaQuery.sizeOf(context).height * .85,
                ),
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

  Future<bool> confirmEditorConnectionChange() async {
    if (editorSession.target?.dirty != true) return true;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('单据修复尚未保存'),
            content: const Text('更改连接会清空当前修复结果和共享区，请先保存副本。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('返回保存'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('继续更改连接'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> settings() async {
    if (!await confirmEditorConnectionChange() || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => SettingsDialog(controller: c),
    );
  }

  void logs() => showDialog<void>(
    context: context,
    builder: (_) => LogsDialog(controller: c),
  );

  /// 内置链接经私钥解密后在应用内打开；未导入密钥时提示先完成设置。
  void openSecureLink(String name, String title) {
    final uri = SecureLinks.resolve(name, c.signer);
    if (uri == null) {
      c.status('请先在设置中导入密钥库，再访问$title。', isError: true);
      settings();
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => WebPage(uri: uri, title: title),
      ),
    );
  }

  /// 数据查询作为独立弹层呈现，不影响当前工单查询结果与阅读区。
  void openTableQuery() => mobile
      ? showModalBottomSheet<void>(
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
        )
      : showDialog<void>(
          context: context,
          builder: (context) => Dialog(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: line),
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 760,
                maxHeight: MediaQuery.sizeOf(context).height * .85,
              ),
              child: TableQuerySheet(controller: c),
            ),
          ),
        );

  /// 日志文件面板与数据查询一样作为独立弹层，不影响当前查询结果。
  void openLogFiles() => mobile
      ? showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          backgroundColor: Colors.white,
          constraints: const BoxConstraints(maxWidth: 820),
          builder: (context) => SizedBox(
            height: MediaQuery.sizeOf(context).height * .9,
            child: LogFilesSheet(controller: c),
          ),
        )
      : showDialog<void>(
          context: context,
          builder: (context) => Dialog(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: line),
            ),
            child: SizedBox(
              width: 840,
              height: MediaQuery.sizeOf(context).height * .82,
              child: LogFilesSheet(controller: c),
            ),
          ),
        );

  /// 切换环境后结果与缓存清空，失败原因写入状态条。
  Future<void> switchEnvironment(int index) async {
    if (index == c.settings.active ||
        !await confirmEditorConnectionChange() ||
        !mounted) {
      return;
    }
    try {
      await c.selectEnvironment(index);
    } catch (e) {
      c.status(
        e is FormatException ? e.message : '切换环境失败：${e.runtimeType}',
        isError: true,
      );
    }
  }

  /// 窄桌面只显示图标，环境名放在提示中，避免顶栏溢出。
  Widget environmentMenu() {
    final wide = MediaQuery.sizeOf(context).width >= 1150;
    return PopupMenuButton<int>(
      tooltip: '切换环境 · 当前：${c.settings.current.name}',
      onSelected: switchEnvironment,
      itemBuilder: (_) => [
        for (var i = 0; i < c.settings.environments.length; i++)
          CheckedPopupMenuItem(
            value: i,
            checked: i == c.settings.active,
            child: Text(c.settings.environments[i].name),
          ),
      ],
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: wide ? 10 : 7,
          vertical: wide ? 6 : 5,
        ),
        decoration: BoxDecoration(
          color: const Color(0xfff1f5fb),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: line),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: const BoxDecoration(
                color: Color(0xff10b981),
                shape: BoxShape.circle,
              ),
            ),
            if (wide) ...[
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 110),
                child: Text(
                  c.settings.current.name.isEmpty
                      ? '未配置环境'
                      : c.settings.current.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: ink,
                  ),
                ),
              ),
            ],
            const SizedBox(width: 4),
            const Icon(Icons.swap_horiz, size: 15, color: muted),
          ],
        ),
      ),
    );
  }

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
        bottomNavigationBar: !toolTab && mobile && c.work != null
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
              if (toolTab && MediaQuery.sizeOf(context).width < 1150)
                editorHeader()
              else
                header(),
              if (!toolTab && MediaQuery.sizeOf(context).width < 1150)
                Container(
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    border: Border(bottom: BorderSide(color: line)),
                  ),
                  padding: EdgeInsets.symmetric(
                    horizontal: mobile ? 10 : 20,
                    vertical: 5,
                  ),
                  child: Row(children: [modeSwitch()]),
                ),
              // 状态行移动端独立成行；桌面端已并入顶栏，仅保留查询进度条。
              if (mobile && !toolTab) status(),
              if (!mobile)
                watch(
                  () => (c.querying, c.completed, c.total),
                  () => c.querying
                      ? LinearProgressIndicator(
                          value: c.total == 0 ? null : c.completed / c.total,
                          minHeight: 3,
                        )
                      : const SizedBox.shrink(),
                ),
              Expanded(
                child: IndexedStack(
                  index: batchTab
                      ? 2
                      : editorTab
                      ? 1
                      : 0,
                  // IndexedStack 会保持隐藏页的动画继续运行（Visibility.maintain），
                  // 单据修复页的连线流动动画在后台仍会逐帧重绘；隐藏页暂停 Ticker。
                  children: [
                    TickerMode(
                      enabled: !toolTab,
                      child: mobile ? mobileBody() : desktopBody(),
                    ),
                    TickerMode(
                      enabled: editorTab,
                      child: editorOpened ? editorScreen : const SizedBox(),
                    ),
                    TickerMode(
                      enabled: batchTab,
                      child: batchOpened ? batchScreen : const SizedBox(),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  Widget modeSwitch() => Container(
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      color: const Color(0xfff1f5fb),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: line),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        tab('工单查询', 0, Icons.search),
        const SizedBox(width: 2),
        tab('单据图片修复', 1, Icons.edit_document),
        if (batchAvailable) ...[
          const SizedBox(width: 2),
          tab('批量修复', 2, Icons.auto_fix_high),
        ],
      ],
    ),
  );

  Widget tab(String label, int mode, IconData icon) {
    final editor = mode == 1;
    final active = (batchTab ? 2 : editorTab ? 1 : 0) == mode;
    return Material(
      color: active ? Colors.white : Colors.transparent,
      borderRadius: BorderRadius.circular(7),
      elevation: active ? 1 : 0,
      shadowColor: const Color(0x260f1e36),
      child: InkWell(
        key: ValueKey(
          ['work-query-tab', 'online-editor-tab', 'batch-repair-tab'][mode],
        ),
        borderRadius: BorderRadius.circular(7),
        onTap: () => setState(() {
          editorTab = editor;
          editorOpened |= editor;
          batchTab = mode == 2;
          batchOpened |= batchTab;
        }),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 14,
                color: active ? blue : const Color(0xff4a5d78),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w600,
                  color: active ? blue : const Color(0xff4a5d78),
                ),
              ),
              if (editor)
                ListenableSelector<bool>(
                  listenable: editorSession,
                  selector: () => editorSession.target?.dirty == true,
                  builder: (context, dirty) => dirty
                      ? Container(
                          margin: const EdgeInsets.only(left: 5),
                          width: 6,
                          height: 6,
                          decoration: const BoxDecoration(
                            color: Color(0xffd97706),
                            shape: BoxShape.circle,
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget editorHeader() => Container(
    decoration: const BoxDecoration(
      color: Colors.white,
      border: Border(bottom: BorderSide(color: line)),
    ),
    padding: EdgeInsets.symmetric(horizontal: mobile ? 8 : 20, vertical: 6),
    child: Row(
      children: [
        if (mobile)
          IconButton(
            tooltip: '返回工单查询',
            onPressed: () => setState(() => editorTab = batchTab = false),
            icon: const Icon(Icons.arrow_back_ios_new, size: 19),
          )
        else
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.asset(
              'assets/branding/app-icon.png',
              width: 30,
              height: 30,
            ),
          ),
        const SizedBox(width: 10),
        if (mobile)
          const Expanded(
            child: Text(
              '单据图片修复',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: ink,
              ),
            ),
          )
        else ...[
          const Text(
            '无纸化 / 维护中心',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: ink,
            ),
          ),
          const SizedBox(width: 16),
          modeSwitch(),
          const Spacer(),
        ],
        environmentMenu(),
        IconButton(
          tooltip: '设置',
          onPressed: settings,
          icon: const Icon(Icons.tune, size: 20),
        ),
      ],
    ),
  );

  Widget editorStatusInline() => Tooltip(
    message: '实时流光连线已启用 · 编辑仅在本地合成 PDF，不会自动覆盖 OBS',
    waitDuration: const Duration(milliseconds: 150),
    child: Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        color: const Color(0xffe6f7f2),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xffb2e8d8)),
      ),
      child: const Icon(Icons.bolt, size: 16, color: Color(0xff0d8a6a)),
    ),
  );

  Widget header() {
    final screenW = MediaQuery.sizeOf(context).width;
    final wideDesktop = !mobile && screenW >= 1150;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: mobile ? 16 : 16,
        vertical: mobile ? 10 : 7,
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
                width: 34,
                height: 34,
              ),
            ),
            const SizedBox(width: 10),
          ],
          if (wideDesktop) ...[
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      '无纸化 / 维护中心',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: ink,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1.5,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xffeaf2ff),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: const Color(0xffbfd6ff)),
                      ),
                      child: const Text(
                        'v1.6.2',
                        style: TextStyle(
                          fontFamily: 'Menlo',
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: blue,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 1),
                const Text(
                  'NPL CONSOLE · 工单核对与影像修复',
                  style: TextStyle(fontSize: 10.5, color: muted),
                ),
              ],
            ),
            const SizedBox(width: 12),
            modeSwitch(),
            const SizedBox(width: 12),
          ] else
            Expanded(
              child: Text(
                mobile && c.work != null ? sections[section] : '无纸化 / 维护中心',
                style: TextStyle(
                  fontSize: mobile ? 17 : 18,
                  fontWeight: FontWeight.w700,
                  color: ink,
                ),
              ),
            ),
          if (!mobile) ...[
            if (wideDesktop)
              Expanded(
                child: toolTab
                    ? Align(
                        alignment: Alignment.centerLeft,
                        child: editorTab
                            ? editorStatusInline()
                            : const SizedBox.shrink(),
                      )
                    : Row(
                        children: [
                          Expanded(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 420),
                              child: searchLaunch(),
                            ),
                          ),
                          if (screenW >= 1320) ...[
                            const SizedBox(width: 8),
                            Flexible(child: statusInline()),
                          ],
                        ],
                      ),
              )
            else
              SizedBox(
                width: math.min(400, screenW * .28),
                child: searchLaunch(),
              ),
            watch(
              () => c.cacheHits,
              () => IconButton(
                tooltip: '缓存命中 ${c.cacheHits} 次 · 点击清空',
                onPressed: c.clearCache,
                icon: const Icon(Icons.cached, size: 18),
              ),
            ),
            if (wideDesktop)
              TextButton.icon(
                onPressed: openTableQuery,
                icon: const Icon(Icons.table_view_outlined, size: 16),
                label: const Text('数据查询', style: TextStyle(fontSize: 12)),
              )
            else
              IconButton(
                tooltip: '数据查询',
                onPressed: openTableQuery,
                icon: const Icon(Icons.table_view_outlined, size: 19),
              ),
            IconButton(
              tooltip: '日志文件',
              onPressed: openLogFiles,
              icon: const Icon(Icons.article_outlined, size: 19),
            ),
            watch(
              // 内存记录有上限，条数不再增长时以最新一条的身份判定变化。
              () => (c.logs.length, c.logs.isEmpty ? null : c.logs.first),
              () => TextButton.icon(
                onPressed: logs,
                icon: const Icon(Icons.data_object, size: 16),
                label: Text(
                  '接口记录 ${c.logs.length}',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
            // 门户入口合并为菜单，窄桌面顶栏不溢出。
            PopupMenuButton<String>(
              tooltip: '门户网页',
              onSelected: (v) =>
                  openSecureLink(v, v == 'intranet' ? '内网门户' : '外网门户'),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'intranet', child: Text('内网门户')),
                PopupMenuItem(value: 'extranet', child: Text('外网门户')),
              ],
              icon: const Icon(Icons.language, size: 18),
            ),
            environmentMenu(),
            const SizedBox(width: 6),
            OutlinedButton.icon(
              onPressed: settings,
              icon: const Icon(Icons.tune, size: 16),
              label: const Text('设置', style: TextStyle(fontSize: 12)),
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
                if (v == 'logFiles') openLogFiles();
                if (v.startsWith('env:')) {
                  switchEnvironment(int.parse(v.substring(4)));
                }
                if (v == 'cache') c.clearCache();
                if (v == 'intranet') openSecureLink('intranet', '内网门户');
                if (v == 'extranet') openSecureLink('extranet', '外网门户');
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'tables', child: Text('数据查询')),
                const PopupMenuItem(value: 'logFiles', child: Text('日志文件')),
                for (var i = 0; i < c.settings.environments.length; i++)
                  CheckedPopupMenuItem(
                    value: 'env:$i',
                    checked: i == c.settings.active,
                    child: Text('环境 · ${c.settings.environments[i].name}'),
                  ),
                const PopupMenuItem(value: 'intranet', child: Text('内网门户')),
                const PopupMenuItem(value: 'extranet', child: Text('外网门户')),
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
  }
  Widget searchLaunch() => InkWell(
    onTap: openSearch,
    borderRadius: BorderRadius.circular(11),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xfff4f7fb),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: line),
      ),
      child: Row(
        children: [
          const Icon(Icons.search, size: 18, color: blue),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              draft.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Color(0xff4a5d78)),
            ),
          ),
          if (!mobile && MediaQuery.sizeOf(context).width >= 1100) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: line),
              ),
              child: const Text(
                '⌘K',
                style: TextStyle(
                  fontFamily: 'Menlo',
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: muted,
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          const Icon(Icons.tune, size: 17, color: muted),
        ],
      ),
    ),
  );

  /// 状态条依赖的字段；失败列表原地追加，按长度判定。
  Object? _statusSelect() => (c.message, c.error, c.busy, c.failures.length);

  /// 桌面端顶栏内联状态：绿点 + 当前消息 + 取消 / 查看失败，不独占一行。
  Widget statusInline() => watch(_statusSelect, _statusInline);
  Widget _statusInline() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: c.error ? const Color(0xfffef2f2) : const Color(0xfff5f8fc),
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: c.error ? const Color(0xfffecaca) : line),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          c.error ? Icons.error_outline : Icons.circle,
          size: c.error ? 13 : 7,
          color: c.error ? const Color(0xffdc2626) : const Color(0xff10b981),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: Text(
              c.message,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: c.error
                    ? const Color(0xffdc2626)
                    : const Color(0xff4a5d78),
              ),
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
    ),
  );
  Widget status() =>
      watch(() => (_statusSelect(), c.querying, c.completed, c.total), _status);
  Widget _status() => Column(
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
              size: c.error ? 14 : 7,
              color: c.error
                  ? const Color(0xffdc2626)
                  : const Color(0xff10b981),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                c.message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: c.error ? const Color(0xffdc2626) : muted,
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
      borderRadius: BorderRadius.circular(15),
      border: Border.all(color: line),
      boxShadow: const [
        BoxShadow(
          color: Color(0x090f1e36),
          blurRadius: 16,
          offset: Offset(0, 4),
        ),
      ],
    ),
    child: child,
  );

  /// 全部工单连续展示，不按窗口高度截断；卡片与当前选中项始终同步。
  /// 查询期间工单原地追加，按列表身份与长度判定变化。
  Widget results({bool compact = false}) => watch(
    () => (c.works, c.works.length, c.querying, c.work),
    () => _results(compact),
  );
  Widget _results(bool compact) {
    final keyword = filter.toLowerCase();
    // 未筛选时直接复用列表；筛选文本按工单对象缓存，避免每次重建都序列化全部工单。
    final rows = keyword.isEmpty
        ? c.works
        : c.works.where((w) => _searchText(w).contains(keyword)).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 10, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '查询结果 · ${c.works.length}',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: ink,
                  ),
                ),
              ),
              IconButton(
                tooltip: '重新查询',
                onPressed: openSearch,
                icon: const Icon(Icons.manage_search, size: 19, color: muted),
              ),
            ],
          ),
        ),
        if (c.works.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: TextField(
              onChanged: (v) => setState(() => filter = v),
              decoration: const InputDecoration(
                hintText: '在结果中筛选（业务名 / 单据号 / 工号）',
                prefixIcon: Icon(Icons.search, size: 17),
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
                  padding: const EdgeInsets.fromLTRB(10, 2, 10, 12),
                  itemCount: rows.length,
                  separatorBuilder: (_, i) => const SizedBox(height: 8),
                  itemBuilder: (context, index) =>
                      workCard(rows[index], compact),
                ),
        ),
        if (compact)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: const BoxDecoration(
              color: Color(0xfff5f8fc),
              border: Border(top: BorderSide(color: line)),
            ),
            child: watch(
              () => c.cacheHits,
              () => Row(
                children: [
                  const Icon(Icons.bolt, size: 14, color: Color(0xff10b981)),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      '缓存命中 ${c.cacheHits} 次',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: muted,
                      ),
                    ),
                  ),
                  InkWell(
                    onTap: c.clearCache,
                    borderRadius: BorderRadius.circular(5),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      child: Text(
                        '清空缓存',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: Color(0xff4a5d78),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget workCard(Record row, bool compact) {
    final selected = identical(c.work, row);
    final subLeft = row['regionName'] ?? row['phoneNo'] ?? '—';
    final subRight = row['groupName'] ?? row['sysAccept'] ?? '—';
    return AnimatedContainer(
      duration: MediaQuery.of(context).disableAnimations
          ? Duration.zero
          : const Duration(milliseconds: 180),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: selected ? const Color(0xfff2f7ff) : Colors.white,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(
          color: selected ? blue : line,
          width: selected ? 1.3 : 1,
        ),
        boxShadow: selected
            ? const [
                BoxShadow(
                  color: Color(0x142563eb),
                  blurRadius: 10,
                  offset: Offset(0, 3),
                ),
              ]
            : null,
      ),
      child: Stack(
        children: [
          if (selected)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: 3.5,
              child: Container(color: blue),
            ),
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(11),
              onTap: () => choose(row),
              child: Padding(
                padding: EdgeInsets.fromLTRB(selected ? 13 : 12, 11, 11, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${row['opName'] ?? '业务工单'}',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: selected ? blue : ink,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Icon(
                          Icons.chevron_right,
                          size: 16,
                          color: selected ? blue : muted,
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '${row['caseNo'] ?? '—'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'Menlo',
                        fontSize: 11,
                        color: Color(0xff4a5d78),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '$subLeft · $subRight',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11.5, color: muted),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 7),
                      child: Divider(height: 1, color: Color(0xffecf1f8)),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${row['opTime'] ?? row['opMonth'] ?? '—'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'Menlo',
                              fontSize: 10.5,
                              color: muted,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        badge('${row['stsDesc'] ?? row['sts'] ?? '状态未提供'}'),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget badge(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: const Color(0xffe6f7f2),
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: const Color(0xffb2e8d8)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 5,
          height: 5,
          decoration: const BoxDecoration(
            color: Color(0xff10b981),
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 5),
        Text(
          text,
          style: const TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
            color: Color(0xff0d8a6a),
          ),
        ),
      ],
    ),
  );
  Widget workspace() {
    final w = c.work!;
    final wide = MediaQuery.sizeOf(context).width >= 1150;
    return Column(
      children: [
        // 工单头部第 1 行：标题 + 状态胶囊 + 右侧快捷操作按钮（送入图片修复 / 复制单据号 / 导出 JSON）
        Padding(
          padding: EdgeInsets.fromLTRB(
            mobile ? 16 : 20,
            mobile ? 12 : 12,
            mobile ? 16 : 20,
            mobile ? 6 : 6,
          ),
          child: Row(
            children: [
              Flexible(
                child: Text(
                  '${w['opName'] ?? '业务单据'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: ink,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              badge('${w['stsDesc'] ?? w['sts'] ?? '状态未提供'}'),
              if (!mobile) ...[
                const Spacer(),
                TextButton.icon(
                  onPressed: () => setState(() {
                    editorTab = true;
                    editorOpened = true;
                    batchTab = false;
                  }),
                  style: TextButton.styleFrom(
                    foregroundColor: blue,
                    backgroundColor: const Color(0xffeaf2ff),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 6,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                      side: const BorderSide(color: Color(0xffbfd6ff)),
                    ),
                  ),
                  icon: const Icon(Icons.edit_document, size: 15),
                  label: const Text(
                    '送入图片修复',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: 6),
                OutlinedButton.icon(
                  onPressed: () {
                    Clipboard.setData(
                      ClipboardData(text: '${w['caseNo'] ?? ''}'),
                    );
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('单据号已复制'),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  },
                  icon: const Icon(Icons.copy_outlined, size: 14),
                  label: const Text('复制单据号', style: TextStyle(fontSize: 12)),
                ),
                const SizedBox(width: 6),
                OutlinedButton.icon(
                  onPressed: downloadJson,
                  icon: const Icon(Icons.download_outlined, size: 15),
                  label: const Text('导出 JSON', style: TextStyle(fontSize: 12)),
                ),
              ],
            ],
          ),
        ),
        // 工单头部第 2 行：单据号 + 受理流水 + 营业厅 + 受理时间 元数据条
        Padding(
          padding: EdgeInsets.fromLTRB(
            mobile ? 16 : 20,
            0,
            mobile ? 16 : 20,
            mobile ? 10 : 8,
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  const Text(
                    '单据号: ',
                    style: TextStyle(fontSize: 11.5, color: muted),
                  ),
                  SelectableText(
                    '${w['caseNo'] ?? '—'}',
                    style: const TextStyle(
                      fontFamily: 'Menlo',
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: Color(0xff4a5d78),
                    ),
                  ),
                  if (!mobile) ...[
                    _metaDivider(),
                    const Text(
                      '受理流水: ',
                      style: TextStyle(fontSize: 11.5, color: muted),
                    ),
                    Text(
                      '${w['sysAccept'] ?? '—'}',
                      style: const TextStyle(
                        fontFamily: 'Menlo',
                        fontSize: 11.5,
                        color: Color(0xff4a5d78),
                      ),
                    ),
                    _metaDivider(),
                    const Text(
                      '营业厅: ',
                      style: TextStyle(fontSize: 11.5, color: muted),
                    ),
                    Text(
                      '${w['groupName'] ?? '—'}',
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                        color: Color(0xff4a5d78),
                      ),
                    ),
                    _metaDivider(),
                    const Text(
                      '受理时间: ',
                      style: TextStyle(fontSize: 11.5, color: muted),
                    ),
                    Text(
                      '${w['opTime'] ?? '—'}',
                      style: const TextStyle(
                        fontFamily: 'Menlo',
                        fontSize: 11.5,
                        color: Color(0xff4a5d78),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        if (!mobile)
          Padding(
            padding: const EdgeInsets.only(bottom: 7),
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        for (var i = 0; i < sections.length; i++) ...[
                          if (i > 0) const SizedBox(width: 5),
                          TextButton.icon(
                            onPressed: () => navigate(i),
                            style: TextButton.styleFrom(
                              foregroundColor: section == i
                                  ? blue
                                  : const Color(0xff4a5d78),
                              backgroundColor: section == i
                                  ? const Color(0xffeaf2ff)
                                  : Colors.transparent,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                                side: section == i
                                    ? const BorderSide(color: Color(0xffbfd6ff))
                                    : BorderSide.none,
                              ),
                            ),
                            icon: Icon(sectionIcons[i], size: 15),
                            label: Text(
                              sections[i],
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: section == i
                                    ? FontWeight.w700
                                    : FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                if (wide)
                  const Padding(
                    padding: EdgeInsets.only(right: 20),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.verified_user_outlined,
                          size: 13,
                          color: muted,
                        ),
                        SizedBox(width: 4),
                        Text(
                          '遵循 WO_INFO202610 建表规范 · EXT1~10 完整保留',
                          style: TextStyle(fontSize: 11, color: muted),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        const Divider(height: 1),
        if (section >= 2)
          watch(
            () => (
              c.assets,
              c.assets.length,
              c.asset,
              c.category,
              c.busy,
              c.linkedRecords,
            ),
            assetTools,
          ),
        Expanded(
          child: watch(
            () => (
              c.gallery,
              c.busy,
              c.error,
              // 空态卡片展示进度/失败文案，仅忙碌或失败时才关心消息变化。
              c.busy || c.error ? c.message : null,
              c.bytes,
              c.contentType,
              c.asset,
              c.work,
            ),
            () => AnimatedSwitcher(
              duration: MediaQuery.of(context).disableAnimations
                  ? Duration.zero
                  : const Duration(milliseconds: 180),
              child: section == 0 ? detailsArea() : content(),
            ),
          ),
        ),
      ],
    );
  }

  Widget _metaDivider() => Container(
    width: 1,
    height: 12,
    margin: const EdgeInsets.symmetric(horizontal: 10),
    color: line,
  );

  /// 单据信息全宽单栏展示，不再与 PDF 分栏（原型已定稿）。
  Widget detailsArea() => WorkDetails(
    key: ValueKey(c.work),
    record: c.work!,
    onDownload: downloadJson,
  );
  Widget assetTools() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
    decoration: const BoxDecoration(
      color: Color(0xfff5f8fc),
      border: Border(bottom: BorderSide(color: line)),
    ),
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
              style: const TextStyle(
                color: Color(0xff4a5d78),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
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
              color: const Color(0xffeaf2ff),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xffbfd6ff)),
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
                    color: blue,
                  ),
          ),
          const SizedBox(height: 18),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: ink,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12.5, height: 1.7, color: muted),
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
    final selectedWork = c.work,
        selectedAsset = c.asset,
        currentBytes = c.bytes;
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
    final target = await confirmRepairTarget(
      selectedWork,
      file.name,
      newBytes.length,
      preset,
    );
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
                    fileName: assetName.replaceAll(
                      RegExp(r'[\\/:*?"<>|]'),
                      '_',
                    ),
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
