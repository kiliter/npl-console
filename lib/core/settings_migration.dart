import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// macOS 沙盒版的 bundle 标识，用于定位旧容器内的偏好文件。
const macosBundleId = 'cn.agilestar.nplMaintenance';

/// 一次性迁移：macOS 自 v1.3.4 起移除 App Sandbox，SharedPreferences 存储位置
/// 从沙盒容器 `~/Library/Containers/<id>/Data/Library/Preferences/<id>.plist`
/// 变为 `~/Library/Preferences/<id>.plist`，直接升级会导致设置与查询历史"丢失"。
/// 启动时检测：新位置还没有连接配置、且旧容器偏好存在时，把 flutter.* 键搬回。
/// 迁移失败静默跳过，用户可在设置页重新配置。
Future<void> migrateSandboxPreferences({
  String? legacyPlistPath,
  SharedPreferences? prefs,
}) async {
  if (!Platform.isMacOS) return;
  try {
    final home = Platform.environment['HOME'];
    if (home == null) return;
    final legacy = File(
      legacyPlistPath ??
          '$home/Library/Containers/$macosBundleId/Data/Library/Preferences/$macosBundleId.plist',
    );
    if (!legacy.existsSync()) return;
    final store = prefs ?? await SharedPreferences.getInstance();
    // 新位置已有连接配置，说明是新装或已迁移过，避免覆盖用户改动。
    if (store.containsKey('connection')) return;
    // 非沙盒进程可调用 plutil 把 plist 转 JSON，再逐项写回 SharedPreferences。
    final result = await Process.run('plutil', [
      '-convert',
      'json',
      '-o',
      '-',
      legacy.path,
    ]);
    if (result.exitCode != 0) return;
    final decoded = jsonDecode(result.stdout as String);
    if (decoded is! Map) return;
    for (final entry in decoded.entries) {
      final key = '${entry.key}';
      // shared_preferences 插件的键统一带 flutter. 前缀，本项目保存项均为字符串。
      if (key.startsWith('flutter.') && entry.value is String) {
        await store.setString(
          key.substring('flutter.'.length),
          entry.value as String,
        );
      }
    }
  } catch (_) {
    // 静默忽略：迁移是尽力而为的兼容逻辑，不能影响启动。
  }
}
