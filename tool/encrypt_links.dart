import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:pointycastle/export.dart';
import 'package:npl_maintenance/core/jwt_signer.dart';

/// 内置链接加密工具：用密钥库公钥（RSA-OAEP）加密 URL，输出可提交的密文常量。
/// 用法：dart run tool/encrypt_links.dart [keystore路径] [密钥库密码] [私钥密码] [别名]
/// 密文只能由持有对应私钥（已导入 App）的设备解密，仓库不含明文。
Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln(
      '用法: dart run tool/encrypt_links.dart <keystore> <密码> [私钥密码] [别名]',
    );
    exit(64);
  }
  final file = File(args[0]);
  if (!file.existsSync()) {
    stderr.writeln('密钥库文件不存在: ${args[0]}');
    exit(66);
  }
  final signer = JwtSigner.import(
    file.readAsBytesSync(),
    password: args[1],
    keyPassword: args.length > 2 ? args[2] : '',
    alias: args.length > 3 ? args[3] : '',
  );
  final links = {
    'intranet': 'https://192.168.2.109',
    'extranet': 'https://jianwei.kiliter.cn',
  };
  final encrypter = OAEPEncoding(RSAEngine())
    ..init(
      true,
      PublicKeyParameter<RSAPublicKey>(
        RSAPublicKey(signer.modulus, BigInt.from(65537)),
      ),
    );
  stdout.writeln('// 由 tool/encrypt_links.dart 生成，公钥加密，仅私钥持有者可解。');
  stdout.writeln('const encryptedLinks = {');
  for (final entry in links.entries) {
    final plain = Uint8List.fromList(utf8.encode(entry.value));
    final cipher = encrypter.process(plain);
    // 立即用私钥回解校验，避免输出无法解密的密文。
    final restored = signer.decrypt(cipher);
    if (restored != entry.value) {
      stderr.writeln('自检失败: ${entry.key} 回解结果不一致');
      exit(1);
    }
    stdout.writeln("  '${entry.key}':");
    stdout.writeln("      '${base64.encode(cipher)}',");
  }
  stdout.writeln('};');
}
