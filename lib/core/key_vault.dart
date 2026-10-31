import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'jwt_signer.dart';
import 'local_config.dart';

/// 固定服务和条目标识，覆盖安装继续读取同一项；只保存签名所需参数，不保存导入密码。
class KeyVault {
  static const service = 'cn.agilestar.nplMaintenance.jwt';
  static const entry = 'rsa-signing-key-v1';
  final FlutterSecureStorage storage;
  const KeyVault({
    this.storage = const FlutterSecureStorage(
      iOptions: IOSOptions(
        accountName: service,
        accessibility: KeychainAccessibility.unlocked_this_device,
        synchronizable: false,
      ),
      // Mac 使用系统登录钥匙串的应用访问控制，固定开发签名与服务标识，不申请跨应用共享访问组。
      mOptions: MacOsOptions(
        accountName: service,
        usesDataProtectionKeychain: false,
        synchronizable: false,
      ),
      aOptions: AndroidOptions(storageNamespace: service, resetOnError: false),
    ),
  });

  static const fileName = 'signing-key.json';
  static const migrationFile = 'keychain-migrated-v1';
  final LocalConfig files = const LocalConfig();

  Future<JwtSigner?> read() => LocalConfig.serialized(() async {
    final current = await files.readFile(fileName);
    final migrated = await files.readFile(migrationFile);
    if (current != null) {
      final signer = JwtSigner.fromSecureRecord(current);
      if (migrated == null) await _retireLegacy();
      return signer;
    }
    if (migrated != null) return null;
    final previous = await storage.read(key: entry);
    if (previous == null) {
      await files.writeFile(migrationFile, '1');
      return null;
    }
    final signer = JwtSigner.fromSecureRecord(previous);
    await files.writeFile(fileName, signer.toSecureRecord());
    // 文件持久化并读回校验完成后，才允许删除旧钥匙串副本。
    await _retireLegacy();
    return signer;
  });

  Future<void> _retireLegacy() async {
    await storage.delete(key: entry);
    if (await storage.containsKey(key: entry)) throw const FormatException('旧密钥副本未完成清理，请重试迁移');
    await files.writeFile(migrationFile, '1');
  }

  Future<void> write(JwtSigner signer) => LocalConfig.serialized(() async {
    await files.writeFile(fileName, signer.toSecureRecord());
    if (await files.readFile(migrationFile) == null) await _retireLegacy();
  });

  Future<void> delete() => LocalConfig.serialized(() async {
    if (await files.readFile(migrationFile) == null) await _retireLegacy();
    await files.deleteFile(fileName);
  });
}
