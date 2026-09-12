import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:npl_maintenance/core/contracts.dart';
import 'package:npl_maintenance/core/jwt_signer.dart';
import 'package:npl_maintenance/core/key_vault.dart';
import 'package:npl_maintenance/core/maintenance_controller.dart';

/// 使用独立测试密钥校验安全存储生命周期，不读取用户真实 keystore。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });
  test('保存后新控制器自动恢复，普通设置中没有私钥；移除后不再恢复', () async {
    final key = JwtSigner.import(
      File('test/fixtures/sample.jks').readAsBytesSync(),
      password: 'fixture-password',
    );
    final first = MaintenanceController();
    await first.configure(
      const ConnectionSettings(
        baseUrl: 'https://example.invalid',
        loginNo: 'demo',
        channel: 'demo',
      ),
      key,
    );
    expect(first.keyPersisted, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), {'connection'});
    expect(prefs.getString('connection'), isNot(contains('fixture-password')));
    first.dispose();
    final second = MaintenanceController();
    await second.restore();
    final time = DateTime.utc(2026);
    expect(
      second.signer!.token('demo', 'demo', now: time),
      key.token('demo', 'demo', now: time),
    );
    await second.removeStoredKey();
    expect(second.signer, isNull);
    expect(await const KeyVault().read(), isNull);
    second.dispose();
    final third = MaintenanceController();
    await third.restore();
    expect(third.signer, isNull);
    third.dispose();
  });
  test('损坏的保存项不会自动删除，错误不回显敏感内容', () async {
    FlutterSecureStorage.setMockInitialValues({
      KeyVault.entry: 'private-broken-payload',
    });
    final c = MaintenanceController();
    await c.restore();
    expect(c.error, isTrue);
    expect(c.message, isNot(contains('private-broken-payload')));
    expect(
      await const FlutterSecureStorage().read(key: KeyVault.entry),
      isNotNull,
    );
    c.dispose();
  });
}
