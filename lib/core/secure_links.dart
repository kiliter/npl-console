import 'dart:convert';
import 'jwt_signer.dart';

/// 内置链接：密文由 tool/encrypt_links.dart 用生产密钥库公钥（RSA-OAEP）预加密，
/// 仓库不含明文；仅导入了对应私钥的本机可解密。解密失败时对外返回 null。
class SecureLinks {
  static const _ciphertexts = {
    'intranet':
        'K2+23DE22zmWIn+CDO8T65Ya6l7Du5KTqa+9cU2hCSVWJJxdvm8PTSsme4xJI58vuuBZ2LoBX8ImK3QVML6E1fEsdnDaBBpYnMQkJodCaMuWo3Dv/qYhebTf7zenXeIPBIFe9+6ScOUT1tqMX1bwcDpJpD9qcPE3nZwGXR+hVeitzdDDEcmec31VOYaWxFJ7qiOwdDAFPS2Xg7KqrNlshNi8KEgRrNniapHKHWvcLzRnsndmfRjC2ivxJKohNv8rOTafOZG1XXMajjlyJWZNvmiWZYX73u0IXy/YDhmov7D2cviIRq0spdmuoz3gNg4kdFQmZ8GVHCEYQzkHiueyEg==',
    'extranet':
        'dj/iQ7UMEglkbUaq4xuR6eOYrY+xe+VXZCwqqvpY3/5DZv9RcVWWAx3/id4H4IimVNGvzzPoAes3Pe1u67vtYHxT6bFioVWpnCEvPAEpiTXUuXEs8aYkPTemHU3+AY/bZIcSdrTFhCJ15rw6ZzWrYmcSoiiiD0EY9jMyQq4VzpXkh5z8assOQ8kt4MRCrZRrEnYg5Qa99gswKDjPloeToXdkCKwQZRqoWRyK1oQQfuOKZoCYGDREi+/lMhFNC4xGcMDq2ZO8Ai8MkixBVfcld++8pb/iyZneJoyiVZs92upDQd+P7cGlM3RvHwIldE249LJDXFur8LTUohe5TIIyEg==',
  };

  /// 用已导入的签名私钥解密链接；未导入密钥或密文损坏返回 null。
  static Uri? resolve(String name, JwtSigner? signer) {
    final cipher = _ciphertexts[name];
    if (cipher == null || signer == null) return null;
    try {
      return Uri.parse(signer.decrypt(base64.decode(cipher)));
    } catch (_) {
      return null;
    }
  }
}
