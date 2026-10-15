import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:npl_maintenance/core/jwt_signer.dart';

/// 使用独立随机测试密钥验证 JKS 解密、JWT 声明及 RSA 公钥验签。
void main() {
  test('JKS 导入与 RS256 JWT 和证书对应的公钥匹配', () {
    final bytes = File('test/fixtures/sample.jks').readAsBytesSync();
    final key = JwtSigner.import(bytes, password: 'fixture-password');
    final now = DateTime.utc(2026, 9, 12);
    final token = key.token('test', 'test-channel', now: now),
        parts = token.split('.');
    final claims =
        jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))))
            as Map;
    expect(claims['exp'] - claims['iat'], 1200);
    expect(claims['aud'], 'az');
    expect(claims['iss'], 'test-channel');
    final jwk =
        jsonDecode(File('test/fixtures/public.json').readAsStringSync()) as Map;
    BigInt integer(String value) => base64Url
        .decode(base64Url.normalize(value))
        .fold(BigInt.zero, (n, b) => (n << 8) | BigInt.from(b));
    final verifier = RSASigner(SHA256Digest(), '0609608648016503040201')
      ..init(
        false,
        PublicKeyParameter<RSAPublicKey>(
          RSAPublicKey(integer(jwk['n']), integer(jwk['e'])),
        ),
      );
    expect(
      verifier.verifySignature(
        Uint8List.fromList(utf8.encode(parts.take(2).join('.'))),
        RSASignature(base64Url.decode(base64Url.normalize(parts[2]))),
      ),
      isTrue,
    );
    expect(
      () => JwtSigner.import(bytes, password: 'incorrect'),
      throwsFormatException,
    );
    final broken = Uint8List.fromList(bytes)..[20] ^= 1;
    expect(
      () => JwtSigner.import(broken, password: 'fixture-password'),
      throwsFormatException,
    );
  });

  /// OAEP 公钥加密、私钥解密往返：内置链接密文只能在持有私钥的设备还原。
  test('RSA-OAEP 加密链接仅私钥可解密', () {
    final key = JwtSigner.import(
      File('test/fixtures/sample.jks').readAsBytesSync(),
      password: 'fixture-password',
    );
    final encrypter = OAEPEncoding(RSAEngine())
      ..init(
        true,
        PublicKeyParameter<RSAPublicKey>(
          RSAPublicKey(key.modulus, BigInt.from(65537)),
        ),
      );
    final cipher = encrypter.process(
      Uint8List.fromList(utf8.encode('https://example.test/login/')),
    );
    expect(utf8.decode(cipher, allowMalformed: true), isNot(contains('http')));
    expect(key.decrypt(cipher), 'https://example.test/login/');
    expect(
      () => key.decrypt(Uint8List.fromList(cipher)..[10] ^= 1),
      throwsA(anything),
    );
  });
}
