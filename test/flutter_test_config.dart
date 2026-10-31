import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:npl_maintenance/core/local_config.dart';

Future<void> testExecutable(FutureOr<void> Function() main) async {
  setUp(() async {
    LocalConfig.useTestDirectory(
      await Directory.systemTemp.createTemp('npl-config-test-'),
    );
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });
  tearDown(() async {
    final directory = LocalConfig.testDirectory;
    if (directory != null && await directory.exists()) {
      await directory.delete(recursive: true);
    }
    // 保留测试路径，迟到的异步操作也不能触碰真实用户目录。
  });
  await main();
}
