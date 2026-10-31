import 'dart:convert';
import 'dart:typed_data';

import 'contracts.dart';

class InterResultDecryption {
  static const fields = ['retMsg', 'retDetail', 'paramInt'];
  static const _sbox = [
    0xd6,
    0x90,
    0xe9,
    0xfe,
    0xcc,
    0xe1,
    0x3d,
    0xb7,
    0x16,
    0xb6,
    0x14,
    0xc2,
    0x28,
    0xfb,
    0x2c,
    0x05,
    0x2b,
    0x67,
    0x9a,
    0x76,
    0x2a,
    0xbe,
    0x04,
    0xc3,
    0xaa,
    0x44,
    0x13,
    0x26,
    0x49,
    0x86,
    0x06,
    0x99,
    0x9c,
    0x42,
    0x50,
    0xf4,
    0x91,
    0xef,
    0x98,
    0x7a,
    0x33,
    0x54,
    0x0b,
    0x43,
    0xed,
    0xcf,
    0xac,
    0x62,
    0xe4,
    0xb3,
    0x1c,
    0xa9,
    0xc9,
    0x08,
    0xe8,
    0x95,
    0x80,
    0xdf,
    0x94,
    0xfa,
    0x75,
    0x8f,
    0x3f,
    0xa6,
    0x47,
    0x07,
    0xa7,
    0xfc,
    0xf3,
    0x73,
    0x17,
    0xba,
    0x83,
    0x59,
    0x3c,
    0x19,
    0xe6,
    0x85,
    0x4f,
    0xa8,
    0x68,
    0x6b,
    0x81,
    0xb2,
    0x71,
    0x64,
    0xda,
    0x8b,
    0xf8,
    0xeb,
    0x0f,
    0x4b,
    0x70,
    0x56,
    0x9d,
    0x35,
    0x1e,
    0x24,
    0x0e,
    0x5e,
    0x63,
    0x58,
    0xd1,
    0xa2,
    0x25,
    0x22,
    0x7c,
    0x3b,
    0x01,
    0x21,
    0x78,
    0x87,
    0xd4,
    0x00,
    0x46,
    0x57,
    0x9f,
    0xd3,
    0x27,
    0x52,
    0x4c,
    0x36,
    0x02,
    0xe7,
    0xa0,
    0xc4,
    0xc8,
    0x9e,
    0xea,
    0xbf,
    0x8a,
    0xd2,
    0x40,
    0xc7,
    0x38,
    0xb5,
    0xa3,
    0xf7,
    0xf2,
    0xce,
    0xf9,
    0x61,
    0x15,
    0xa1,
    0xe0,
    0xae,
    0x5d,
    0xa4,
    0x9b,
    0x34,
    0x1a,
    0x55,
    0xad,
    0x93,
    0x32,
    0x30,
    0xf5,
    0x8c,
    0xb1,
    0xe3,
    0x1d,
    0xf6,
    0xe2,
    0x2e,
    0x82,
    0x66,
    0xca,
    0x60,
    0xc0,
    0x29,
    0x23,
    0xab,
    0x0d,
    0x53,
    0x4e,
    0x6f,
    0xd5,
    0xdb,
    0x37,
    0x45,
    0xde,
    0xfd,
    0x8e,
    0x2f,
    0x03,
    0xff,
    0x6a,
    0x72,
    0x6d,
    0x6c,
    0x5b,
    0x51,
    0x8d,
    0x1b,
    0xaf,
    0x92,
    0xbb,
    0xdd,
    0xbc,
    0x7f,
    0x11,
    0xd9,
    0x5c,
    0x41,
    0x1f,
    0x10,
    0x5a,
    0xd8,
    0x0a,
    0xc1,
    0x31,
    0x88,
    0xa5,
    0xcd,
    0x7b,
    0xbd,
    0x2d,
    0x74,
    0xd0,
    0x12,
    0xb8,
    0xe5,
    0xb4,
    0xb0,
    0x89,
    0x69,
    0x97,
    0x4a,
    0x0c,
    0x96,
    0x77,
    0x7e,
    0x65,
    0xb9,
    0xf1,
    0x09,
    0xc5,
    0x6e,
    0xc6,
    0x84,
    0x18,
    0xf0,
    0x7d,
    0xec,
    0x3a,
    0xdc,
    0x4d,
    0x20,
    0x79,
    0xee,
    0x5f,
    0x3e,
    0xd7,
    0xcb,
    0x39,
    0x48,
  ];

  static bool isEncrypted(Object? value) =>
      value is String && value.startsWith('SM4:');

  static void validateKey(String key) {
    if (utf8.encode(key).length != 16) {
      throw const FormatException('SM4 密钥必须为 16 个 UTF-8 字节，不是十六进制字符串');
    }
  }

  static int _rotate(int value, int bits) =>
      ((value << bits) | (value >>> (32 - bits))) & 0xffffffff;

  static int _tau(int value) =>
      (_sbox[(value >>> 24) & 255] << 24) |
      (_sbox[(value >>> 16) & 255] << 16) |
      (_sbox[(value >>> 8) & 255] << 8) |
      _sbox[value & 255];

  static String decrypt(String value, String key) {
    if (!isEncrypted(value)) return value;
    validateKey(key);
    final keyBytes = Uint8List.fromList(utf8.encode(key));
    final schedule = Uint32List(36);
    final state = Uint32List(36);
    Uint8List? output;
    try {
      final cipher = base64Decode(value.substring(4));
      if (cipher.isEmpty || cipher.length % 16 != 0) {
        throw const FormatException();
      }
      const initial = [0xa3b1bac6, 0x56aa3350, 0x677d9197, 0xb27022dc];
      final keyData = ByteData.sublistView(keyBytes);
      for (var index = 0; index < 4; index++) {
        schedule[index] = keyData.getUint32(index * 4) ^ initial[index];
      }
      for (var round = 0; round < 32; round++) {
        var constant = 0;
        for (var byte = 0; byte < 4; byte++) {
          constant = (constant << 8) | (((round * 4 + byte) * 7) & 255);
        }
        final substituted = _tau(
          schedule[round + 1] ^
              schedule[round + 2] ^
              schedule[round + 3] ^
              constant,
        );
        schedule[round + 4] =
            schedule[round] ^
            substituted ^
            _rotate(substituted, 13) ^
            _rotate(substituted, 23);
      }
      output = Uint8List(cipher.length);
      final inputData = ByteData.sublistView(cipher);
      final outputData = ByteData.sublistView(output);
      for (var offset = 0; offset < cipher.length; offset += 16) {
        for (var index = 0; index < 4; index++) {
          state[index] = inputData.getUint32(offset + index * 4);
        }
        for (var round = 0; round < 32; round++) {
          final substituted = _tau(
            state[round + 1] ^
                state[round + 2] ^
                state[round + 3] ^
                schedule[35 - round],
          );
          state[round + 4] =
              state[round] ^
              substituted ^
              _rotate(substituted, 2) ^
              _rotate(substituted, 10) ^
              _rotate(substituted, 18) ^
              _rotate(substituted, 24);
        }
        for (var index = 0; index < 4; index++) {
          outputData.setUint32(offset + index * 4, state[35 - index]);
        }
      }
      final padding = output.last;
      if (padding < 1 ||
          padding > 16 ||
          output.skip(output.length - padding).any((byte) => byte != padding)) {
        throw const FormatException();
      }
      return utf8.decode(output.sublist(0, output.length - padding));
    } catch (_) {
      throw const FormatException('SM4 解密失败，请核对密钥或密文完整性');
    } finally {
      keyBytes.fillRange(0, keyBytes.length, 0);
      schedule.fillRange(0, schedule.length, 0);
      state.fillRange(0, state.length, 0);
      output?.fillRange(0, output.length, 0);
    }
  }

  static ({List<Record> rows, int failures}) decryptRows(
    List<Record> rows,
    String key,
  ) {
    validateKey(key);
    var failures = 0;
    final decrypted = rows.map((record) {
      final copy = Record.from(record);
      for (final field in fields) {
        final value = record[field];
        if (!isEncrypted(value)) continue;
        try {
          copy[field] = decrypt(value as String, key);
        } on FormatException {
          failures++;
        }
      }
      return copy;
    }).toList();
    return (rows: decrypted, failures: failures);
  }
}
