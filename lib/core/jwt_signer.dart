import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

/// 本地 JKS/PKCS#8 解析及 RS256 签名；由系统安全存储持久保护，签名不使用 Java。
class JwtSigner {
  final RSAPrivateKey _key;
  final String alias;
  JwtSigner._(this._key, this.alias);

  /// 仅供系统安全存储序列化使用，不得写入普通配置、文件或日志。
  String toSecureRecord() => jsonEncode({
    'version': 1,
    'alias': alias,
    'n': _key.modulus.toString(),
    'd': _key.privateExponent.toString(),
    'p': _key.p.toString(),
    'q': _key.q.toString(),
  });

  /// 恢复本应用保存的 RSA 参数，损坏时仅报告固定错误，避免回显密钥内容。
  factory JwtSigner.fromSecureRecord(String record) {
    try {
      final data = jsonDecode(record) as Map<String, dynamic>;
      if (data['version'] != 1) throw const FormatException();
      final n = BigInt.parse(data['n'] as String),
          d = BigInt.parse(data['d'] as String);
      final p = BigInt.parse(data['p'] as String),
          q = BigInt.parse(data['q'] as String);
      if (p <= BigInt.one || q <= BigInt.one || n != p * q || d <= BigInt.one) {
        throw const FormatException();
      }
      return JwtSigner._(RSAPrivateKey(n, d, p, q), data['alias'] as String);
    } catch (_) {
      throw const FormatException('安全存储中的密钥格式异常，请重新导入密钥库');
    }
  }

  /// JKS 校验遵循 OpenJDK JavaKeyStore / KeyProtector 格式。
  factory JwtSigner.import(
    Uint8List bytes, {
    String password = '',
    String keyPassword = '',
    String alias = '',
  }) {
    if (bytes.length >= 4 && _Reader(bytes).number(4) == 0xfeedfeed) {
      return _fromJks(bytes, password, keyPassword, alias);
    }
    var der = bytes;
    final text = utf8.decode(bytes, allowMalformed: true);
    if (text.startsWith('-----')) {
      if (!text.contains('-----BEGIN PRIVATE KEY-----')) {
        throw const FormatException(
          '请选择 PKCS#8 PEM（BEGIN PRIVATE KEY）或 JKS 文件',
        );
      }
      der = base64.decode(text.replaceAll(RegExp(r'-----[^-]+-----|\s'), ''));
    }
    return JwtSigner._(_rsaKey(der), 'PKCS#8');
  }

  /// 声明与服务端 JwtTokenKeyStoreUtil 一致，有效期二十分钟。
  String token(String loginNo, String channel, {DateTime? now}) {
    final issued = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    String encode(Object value) =>
        base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    final message =
        '${encode({'alg': 'RS256'})}.${encode({'loginNo': loginNo, 'channelCode': channel, 'iss': channel, 'sub': 'token', 'aud': 'az', 'iat': issued, 'exp': issued + 1200})}';
    final signer = RSASigner(SHA256Digest(), '0609608648016503040201')
      ..init(true, PrivateKeyParameter<RSAPrivateKey>(_key));
    final signature = signer.generateSignature(
      Uint8List.fromList(utf8.encode(message)),
    );
    return '$message.${base64Url.encode(signature.bytes).replaceAll('=', '')}';
  }

  static Uint8List _password(String value) => Uint8List.fromList([
    for (final unit in value.codeUnits) ...[unit >> 8, unit & 255],
  ]);
  static Uint8List _hash(List<int> a, List<int> b) =>
      Uint8List.fromList(sha1.convert([...a, ...b]).bytes);
  static bool _equal(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a[i] ^ b[i];
    }
    return difference == 0;
  }

  static JwtSigner _fromJks(
    Uint8List bytes,
    String password,
    String keyPassword,
    String alias,
  ) {
    if (bytes.length < 32) throw const FormatException('JKS 文件不完整');
    final content = bytes.sublist(0, bytes.length - 20),
        pass = _password(password);
    try {
      final expected = _hash(pass, [
        ...utf8.encode('Mighty Aphrodite'),
        ...content,
      ]);
      if (!_equal(expected, bytes.sublist(bytes.length - 20))) {
        throw const FormatException('密钥库密码错误或 JKS 文件损坏');
      }
    } finally {
      pass.fillRange(0, pass.length, 0);
    }
    final reader = _Reader(content)..number(4);
    final version = reader.number(4), count = reader.number(4);
    if (![1, 2].contains(version) || count > 10000) {
      throw const FormatException('不支持的 JKS 版本或条目数量');
    }
    final keys = <String, Uint8List>{};
    for (var i = 0; i < count; i++) {
      final tag = reader.number(4), name = reader.text();
      reader.take(8);
      if (tag == 1) {
        keys[name] = reader.take(reader.number(4));
        final length = reader.number(4);
        if (length > 10000) throw const FormatException('JKS 证书链长度异常');
        for (var j = 0; j < length; j++) {
          _skipCertificate(reader, version);
        }
      } else if (tag == 2) {
        _skipCertificate(reader, version);
      } else {
        throw const FormatException('未知 JKS 条目类型');
      }
    }
    if (reader.position != content.length) {
      throw const FormatException('JKS 尾部内容异常');
    }
    final names = keys.keys
        .where(
          (name) => alias.isEmpty || name.toLowerCase() == alias.toLowerCase(),
        )
        .toList();
    if (names.length != 1) {
      throw FormatException('请指定私钥别名，可选：${keys.keys.join('、')}');
    }
    return JwtSigner._(
      _recover(
        keys[names.single]!,
        keyPassword.isEmpty ? password : keyPassword,
      ),
      names.single,
    );
  }

  static void _skipCertificate(_Reader reader, int version) {
    if (version == 2) reader.text();
    reader.take(reader.number(4));
  }

  /// Sun JKS 私钥保护机制：盐值、迭代 SHA-1 异或和密码校验摘要。
  static RSAPrivateKey _recover(Uint8List encrypted, String password) {
    final outer = _Der.read(encrypted, 0);
    final algorithm = _Der.read(outer.bytes, 0);
    final oid = _Der.read(algorithm.bytes, 0);
    final data = _Der.read(outer.bytes, algorithm.end);
    if (outer.tag != 48 ||
        algorithm.tag != 48 ||
        oid.tag != 6 ||
        data.tag != 4 ||
        !_equal(oid.bytes, [43, 6, 1, 4, 1, 42, 2, 17, 1, 1])) {
      throw const FormatException('不支持的 JKS 私钥保护算法');
    }
    final value = data.bytes;
    if (value.length <= 40) throw const FormatException('JKS 私钥内容不完整');
    final pass = _password(password), plain = Uint8List(value.length - 40);
    var digest = value.sublist(0, 20);
    try {
      for (var offset = 0; offset < plain.length; offset += 20) {
        digest = _hash(pass, digest);
        for (var j = 0; j < 20 && offset + j < plain.length; j++) {
          plain[offset + j] = value[20 + offset + j] ^ digest[j];
        }
      }
      if (!_equal(_hash(pass, plain), value.sublist(value.length - 20))) {
        throw const FormatException('私钥密码错误，可能与密钥库密码不同');
      }
      return _rsaKey(plain);
    } finally {
      pass.fillRange(0, pass.length, 0);
      plain.fillRange(0, plain.length, 0);
    }
  }

  static RSAPrivateKey _rsaKey(Uint8List bytes) {
    final outer = _Der.read(bytes, 0);
    final version = _Der.read(outer.bytes, 0);
    final algorithm = _Der.read(outer.bytes, version.end);
    final privateKey = _Der.read(outer.bytes, algorithm.end);
    if (outer.tag != 48 || privateKey.tag != 4) {
      throw const FormatException('私钥不是 PKCS#8 格式');
    }
    final rsa = _Der.read(privateKey.bytes, 0);
    final integers = <BigInt>[];
    var position = 0;
    while (position < rsa.bytes.length) {
      final item = _Der.read(rsa.bytes, position);
      if (item.tag != 2) throw const FormatException('私钥不是 RSA 格式');
      var value = BigInt.zero;
      for (final byte in item.bytes) {
        value = (value << 8) | BigInt.from(byte);
      }
      integers.add(value);
      position = item.end;
    }
    if (integers.length != 9 || integers[0] != BigInt.zero) {
      throw const FormatException('不支持的 RSA 私钥结构');
    }
    return RSAPrivateKey(integers[1], integers[3], integers[4], integers[5]);
  }
}

/// 长度检查保证损坏的密钥库不会导致越界读取。
class _Reader {
  final Uint8List bytes;
  int position = 0;
  _Reader(this.bytes);
  Uint8List take(int count) {
    if (count < 0 || position + count > bytes.length) {
      throw const FormatException('密钥文件长度异常');
    }
    final result = bytes.sublist(position, position + count);
    position += count;
    return result;
  }

  int number(int count) =>
      take(count).fold(0, (value, byte) => value * 256 + byte);
  String text() => utf8.decode(take(number(2)), allowMalformed: true);
}

/// 最小 DER TLV 读取器，仅用于 PKCS#8 及 JKS 加密私钥封装。
class _Der {
  final int tag, end;
  final Uint8List bytes;
  _Der(this.tag, this.end, this.bytes);
  factory _Der.read(Uint8List bytes, int offset) {
    final reader = _Reader(bytes)..position = offset;
    final tag = reader.number(1);
    var length = reader.number(1);
    if (length & 128 != 0) {
      final count = length & 127;
      if (count == 0 || count > 4) throw const FormatException('DER 长度编码异常');
      length = reader.number(count);
    }
    final data = reader.take(length);
    return _Der(tag, reader.position, data);
  }
}
