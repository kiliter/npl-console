import 'package:flutter/material.dart';
import 'core/maintenance_controller.dart';
import 'core/settings_migration.dart';
import 'core/update_check.dart';
import 'ui/maintenance_screen.dart';
import 'ui/update_dialog.dart';

/// 原生入口；网络由 Dart HTTP 执行，不嵌入网页代理。
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = MaintenanceController();
  runApp(MaintenanceApp(controller: controller));
  // 从 macOS 沙盒版升级时先搬回旧偏好，再恢复业务设置。
  migrateSandboxPreferences().then((_) => controller.restore());
}

class MaintenanceApp extends StatefulWidget {
  final MaintenanceController controller;
  const MaintenanceApp({super.key, required this.controller});
  @override
  State<MaintenanceApp> createState() => _MaintenanceAppState();
}

class _MaintenanceAppState extends State<MaintenanceApp> {
  /// 全局 Navigator key：启动自动检查更新时需要在 MaterialApp 之下弹窗。
  final _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    // 首帧渲染后静默检查新版本，仅发现更新时打扰用户。
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoCheckUpdate());
  }

  /// 启动自动检查：失败（无网络、GitHub 不可达等）静默忽略，不影响使用。
  Future<void> _autoCheckUpdate() async {
    try {
      final update = await checkLatestRelease();
      final context = _navigatorKey.currentContext;
      if (update == null || context == null || !context.mounted) return;
      await showUpdateDialog(context, update);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: _navigatorKey,
    title: '无纸化维护中心',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff2869e8),
        surface: Colors.white,
        secondaryContainer: const Color(0xffeaf2ff),
        onSecondaryContainer: const Color(0xff2869e8),
        primary: const Color(0xff2869e8),
      ),
      scaffoldBackgroundColor: const Color(0xfff3f6fa),
      fontFamily: '.AppleSystemUIFont',
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          side: const BorderSide(color: Color(0xffdfe6f0)),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ),
      navigationBarTheme: const NavigationBarThemeData(
        backgroundColor: Colors.white,
        indicatorColor: Color(0xffebf2ff),
      ),
      dividerColor: const Color(0xffe5ebf4),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xfff6f8fc),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 15,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xffe2e9f3)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xffe2e9f3)),
        ),
      ),
    ),
    home: MaintenanceScreen(controller: widget.controller),
  );
}
