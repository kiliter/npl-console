import 'dart:io';
import 'package:flutter/material.dart';
import 'package:npl_maintenance/core/key_vault.dart';

/// 本地双进程安全存储检查：使用独立非敏感条目，不接触正式密钥。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('正在验证系统安全存储…'))),
    ),
  );
  const storage = KeyVault();
  const key = 'local-validation-probe-v1';
  try {
    final previous = await storage.storage.read(key: key);
    if (previous == null) {
      await storage.storage.write(key: key, value: 'local-validation-only');
      if (await storage.storage.read(key: key) != 'local-validation-only') {
        throw StateError('读回失败');
      }
      stdout.writeln('KEYCHAIN_PROBE_SAVED');
    } else {
      if (previous != 'local-validation-only') throw StateError('恢复值不一致');
      await storage.storage.delete(key: key);
      stdout.writeln('KEYCHAIN_PROBE_RESTORED_AND_REMOVED');
    }
    exit(0);
  } catch (error) {
    stdout.writeln('KEYCHAIN_PROBE_FAILED ${error.runtimeType}: $error');
    exit(1);
  }
}
