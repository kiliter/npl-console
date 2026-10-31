import 'package:flutter_test/flutter_test.dart';
import 'package:npl_maintenance/core/inter_result_decryption.dart';
import 'package:npl_maintenance/core/contracts.dart';

void main() {
  const key = '0123456789abcdef';
  const cipher =
      'SM4:P5LJ4hZbtVbcXkRGTCKTg+wTK95NItvUa82Z0rygPX47fY5X7jfGUAgqyhU8Fbo1';
  test('解密独立 OpenSSL 生成的中文多分组向量', () {
    expect(InterResultDecryption.decrypt(cipher, key), '签字识别通过：{"result":0}');
    expect(
      InterResultDecryption.decrypt(
        'SM4:6vm0hDSSwLFMDg6/bjIsi9FNcHjS86Z/4A0yIdux1VY=',
        key,
      ),
      '1234567890abcdef',
    );
    expect(
      InterResultDecryption.decrypt('SM4:0U1weNLzpn/gDTIh27HVVg==', key),
      '',
    );
  });
  test('明文原样保留，密钥按 UTF-8 字节而非字符校验', () {
    expect(InterResultDecryption.decrypt('明文', ''), '明文');
    expect(
      () => InterResultDecryption.validateKey('中文中文中文中文中文中文中文中文'),
      throwsFormatException,
    );
    expect(
      () => InterResultDecryption.validateKey('0123456789abcdef '),
      throwsFormatException,
    );
    expect(
      () => InterResultDecryption.validateKey('中文1234567890'),
      returnsNormally,
    );
  });
  test('错误密钥、无效 Base64 和分组长度均明确失败且不泄漏密钥', () {
    for (final value in [cipher, 'SM4:!', 'SM4:', 'SM4:YWJj']) {
      expect(
        () => InterResultDecryption.decrypt(value, 'fedcba9876543210'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            '错误提示',
            'SM4 解密失败，请核对密钥或密文完整性',
          ),
        ),
      );
    }
  });
  test('仅处理三个目标字段，不修改原始响应，局部失败保留密文', () {
    final source = <Record>[
      {
        'retMsg': cipher,
        'retDetail': 'SM4:!',
        'paramInt': '明文',
        'other': cipher,
      },
      {'retMsg': null},
    ];
    final result = InterResultDecryption.decryptRows(source, key);
    expect(result.failures, 1);
    expect(result.rows.first['retMsg'], '签字识别通过：{"result":0}');
    expect(result.rows.first['retDetail'], 'SM4:!');
    expect(result.rows.first['paramInt'], '明文');
    expect(result.rows.first['other'], cipher);
    expect(source.first['retMsg'], cipher);
    expect(result.rows.last['retMsg'], isNull);
  });
  test('接口结果条件与月份校验', () {
    expect(
      tableQueryBody(
        TableKind.interResult,
        sysAccept: ' FLOW ',
        opMonth: '2026-10',
        interUrl: ' signcheck ',
        retCode: '0',
      ),
      {
        'sysAccept': 'FLOW',
        'opMonth': '202610',
        'interUrl': 'signcheck',
        'retCode': '0',
      },
    );
    expect(tableQueryBody(TableKind.interResult, caseNo: 'CASE'), {
      'caseNo': 'CASE',
    });
    expect(
      () => tableQueryBody(TableKind.interResult, opMonth: '2026-10'),
      throwsFormatException,
    );
    expect(
      () => tableQueryBody(TableKind.interResult, sysAccept: 'FLOW'),
      throwsFormatException,
    );
    expect(
      () => tableQueryBody(
        TableKind.woinfo,
        caseNo: 'CASE',
        interUrl: 'signcheck',
      ),
      throwsFormatException,
    );
  });
}
