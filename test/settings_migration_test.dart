import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:npl_maintenance/core/settings_migration.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 验证 macOS 沙盒版偏好迁移：旧容器 plist 中的 flutter.* 键搬回 SharedPreferences。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 把键值写成真实 plist 文件，模拟沙盒容器里的旧偏好。
  Future<String> writePlist(Map<String, Object> values) async {
    final path =
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'migration_test_${DateTime.now().microsecondsSinceEpoch}.plist';
    await File(path).writeAsString(jsonEncode(values));
    await Process.run('plutil', ['-convert', 'xml1', path]);
    addTearDown(() async {
      final file = File(path);
      if (await file.exists()) await file.delete();
    });
    return path;
  }

  test('旧偏好中的 flutter.* 键搬回，系统键不迁移', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final path = await writePlist({
      'flutter.connection': '{"baseUrl":"https://x"}',
      'flutter.github_proxy_v1': 'https://ghproxy.net/',
      'NSNavPanelExpandedSizeForOpenMode': '{880, 448}',
    });
    await migrateSandboxPreferences(legacyPlistPath: path, prefs: prefs);
    expect(prefs.getString('connection'), '{"baseUrl":"https://x"}');
    expect(prefs.getString('github_proxy_v1'), 'https://ghproxy.net/');
  });

  test('新位置已有连接配置时不覆盖', () async {
    SharedPreferences.setMockInitialValues({
      'flutter.connection': '{"baseUrl":"https://new"}',
    });
    final prefs = await SharedPreferences.getInstance();
    final path = await writePlist({
      'flutter.connection': '{"baseUrl":"https://old"}',
    });
    await migrateSandboxPreferences(legacyPlistPath: path, prefs: prefs);
    expect(prefs.getString('connection'), '{"baseUrl":"https://new"}');
  });

  test('旧偏好文件不存在时静默跳过', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await migrateSandboxPreferences(
      legacyPlistPath: '/tmp/不存在的文件.plist',
      prefs: prefs,
    );
    expect(prefs.getKeys(), isEmpty);
  });
}
