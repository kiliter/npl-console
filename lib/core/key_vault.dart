import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'jwt_signer.dart';

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

  /// 读取失败保留原条目，交由界面提示，不自动删除或退回明文存储。
  Future<JwtSigner?> read() async {
    final value = await storage.read(key: entry);
    return value == null ? null : JwtSigner.fromSecureRecord(value);
  }

  /// 写入后读回核对，避免系统拒绝访问时界面误报保存成功。
  Future<void> write(JwtSigner signer) async {
    final value = signer.toSecureRecord();
    await storage.write(key: entry, value: value);
    if (await storage.read(key: entry) != value) {
      throw const FormatException('系统安全存储未确认密钥写入，请检查钥匙串访问权限');
    }
  }

  /// 仅删除本应用的签名条目，不影响其它钥匙串内容或原始 keystore 文件。
  Future<void> delete() => storage.delete(key: entry);
}
