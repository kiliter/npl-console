import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
// 使用插件的内存实现模拟持久化删除失败，不新增项目依赖。
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:npl_maintenance/core/local_config.dart';
import 'package:npl_maintenance/core/key_vault.dart';
import 'package:npl_maintenance/core/jwt_signer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const files = LocalConfig(), vault = KeyVault();
  JwtSigner sample() => JwtSigner.import(
    File('test/fixtures/sample.jks').readAsBytesSync(),
    password: 'fixture-password',
  );
  test('配置迁移后清理旧偏好，删除后旧值不能复活', () async {
    SharedPreferences.setMockInitialValues({
      'connection': '{"baseUrl":"https://example.invalid"}',
      'query_history_v1': '[]',
    });
    expect(await files.getString('connection'), contains('example.invalid'));
    expect(
      (await SharedPreferences.getInstance()).getString('connection'),
      isNull,
    );
    await files.remove('connection');
    await (await SharedPreferences.getInstance()).setString(
      'connection',
      'stale',
    );
    expect(await files.getString('connection'), isNull);
    expect(await files.getString('query_history_v1'), '[]');
  });
  for (final marked in [false, true]) {
    test('新文件存在时清理旧副本并补齐迁移标记（已有标记：$marked）', () async {
      SharedPreferences.setMockInitialValues({'connection': '旧值'});
      await files.writeFile('connection.json', '新值');
      if (marked) await files.writeFile('connection.migrated', '1');

      expect(await files.getString('connection'), '新值');
      expect(await files.readFile('connection.migrated'), '1');
      final legacy = await SharedPreferences.getInstance();
      await legacy.reload();
      expect(legacy.getString('connection'), isNull);

      await files.deleteFile('connection.json');
      await legacy.setString('connection', '残留旧值');
      expect(await files.getString('connection'), isNull);
      await legacy.reload();
      expect(legacy.getString('connection'), isNull);
      expect(await files.readFile('connection.json'), isNull);
    });
  }

  for (final operation in ['迁移读取', '写入', '删除']) {
    test('$operation 检查旧偏好删除失败，缓存已清空仍可重试', () async {
      final store = _FailOncePreferences({'flutter.connection': '旧值'});
      SharedPreferencesStorePlatform.instance = store;
      final legacy = await SharedPreferences.getInstance();
      if (operation == '删除') {
        await files.writeFile('connection.json', '新值');
      }
      final Future<Object?> attempt = switch (operation) {
        '写入' => files.setString('connection', '新值'),
        '删除' => files.remove('connection'),
        _ => files.getString('connection'),
      };
      await expectLater(attempt, throwsFormatException);
      expect(store.removeCalls, 1);
      expect(legacy.getString('connection'), isNull);
      expect((await store.getAll())['flutter.connection'], '旧值');
      expect(await files.readFile('connection.migrated'), '1');
      final expected = operation == '删除'
          ? null
          : operation == '写入'
          ? '新值'
          : '旧值';
      expect(await files.readFile('connection.json'), expected);

      // 不 reload 缓存，验证后续读取会真正重试持久化删除。
      expect(await files.getString('connection'), expected);
      expect(store.removeCalls, 2);
      expect((await store.getAll()).containsKey('flutter.connection'), isFalse);
      expect(await files.readFile('connection.json'), expected);
    });
  }
  test('密钥迁移验证后清理旧副本，后续读取不再依赖钥匙串', () async {
    final key = sample();
    FlutterSecureStorage.setMockInitialValues({
      KeyVault.entry: key.toSecureRecord(),
    });
    final restored = await vault.read();
    expect(
      restored!.token('x', 'y', now: DateTime.utc(2026)),
      key.token('x', 'y', now: DateTime.utc(2026)),
    );
    expect(await vault.storage.read(key: KeyVault.entry), isNull);
    FlutterSecureStorage.setMockInitialValues({KeyVault.entry: '旧条目不能再被读取'});
    expect((await vault.read())!.alias, key.alias);
    final directory = await files.directory();
    if (!Platform.isWindows) {
      expect((await directory.stat()).mode & 511, 448);
      expect(
        (await File('${directory.path}/${KeyVault.fileName}').stat()).mode &
            511,
        384,
      );
    }
    await vault.delete();
    expect(await vault.read(), isNull);
  });
  test('损坏密钥迁移失败不会删除旧副本，也不落盘', () async {
    FlutterSecureStorage.setMockInitialValues({
      KeyVault.entry: 'broken-private-key',
    });
    await expectLater(vault.read(), throwsFormatException);
    expect(await vault.storage.read(key: KeyVault.entry), 'broken-private-key');
    expect(await files.readFile(KeyVault.fileName), isNull);
    expect(await files.readFile(KeyVault.migrationFile), isNull);
  });
  test('密钥文件写入失败保留旧副本，不跟随符号链接覆盖其他文件', () async {
    if (Platform.isWindows) return;
    final key = sample();
    FlutterSecureStorage.setMockInitialValues({
      KeyVault.entry: key.toSecureRecord(),
    });
    final dir = await files.directory();
    final other = File('${dir.path}/other')..writeAsStringSync('unchanged');
    await Link('${dir.path}/${KeyVault.fileName}').create(other.path);
    await expectLater(vault.read(), throwsFormatException);
    expect(await other.readAsString(), 'unchanged');
    expect(await vault.storage.read(key: KeyVault.entry), key.toSecureRecord());
  });
}

class _FailOncePreferences extends InMemorySharedPreferencesStore {
  _FailOncePreferences(super.data) : super.withData();

  int removeCalls = 0;

  @override
  Future<bool> remove(String key) async {
    removeCalls++;
    if (removeCalls == 1) return false;
    return super.remove(key);
  }
}
