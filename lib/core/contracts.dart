import 'dart:convert';
import 'dart:typed_data';

typedef Record = Map<String, dynamic>;

/// 持久化配置不包含密码、JWT 或私钥。
class ConnectionSettings {
  final String baseUrl, bucket, loginNo, channel;
  const ConnectionSettings({
    this.baseUrl = '',
    this.bucket = '',
    this.loginNo = '',
    this.channel = '',
  });
  Map<String, String> toJson() => {
    'baseUrl': baseUrl,
    'bucket': bucket,
    'loginNo': loginNo,
    'channel': channel,
  };
  factory ConnectionSettings.fromJson(Record json) => ConnectionSettings(
    baseUrl: json['baseUrl']?.toString() ?? '',
    bucket: json['bucket']?.toString() ?? '',
    loginNo: json['loginNo']?.toString() ?? '',
    channel: json['channel']?.toString() ?? '',
  );
  void validate() {
    final uri = Uri.tryParse(baseUrl);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException(
        '服务地址必须是 HTTP/HTTPS 地址，可包含上下文路径，但不能包含密码、查询参数或片段',
      );
    }
    if (loginNo.isEmpty || channel.isEmpty) {
      throw const FormatException('请填写 JWT 工号及渠道');
    }
  }
}

enum Category { work, message, sign, picture }

extension CategoryName on Category {
  String get label => ['工单信息', '报文信息', '签字信息', '图片信息'][index];
  String get endpoint => [
    '/api/wo/queryList',
    '/api/wobiz/queryList',
    '/api/wosign/queryList',
    '/api/wopic/queryList',
  ][index];
}

/// 单据号交给服务端解析月份；其它查询仅构造明确月份，范围首尾均包含。
List<Record> queryBodies(
  String field,
  String value,
  String start,
  String end,
  bool range,
) {
  value = value.trim();
  if (value.isEmpty) throw const FormatException('请输入查询条件');
  if (field == 'caseNo') {
    return [
      {'caseNo': value},
    ];
  }
  if (!['phoneNo', 'sysAccept'].contains(field)) {
    throw const FormatException('不支持的查询字段');
  }
  final pattern = RegExp(r'^\d{4}-(0[1-9]|1[0-2])$');
  final last = range ? end : start;
  if (!pattern.hasMatch(start) || !pattern.hasMatch(last)) {
    throw const FormatException('月份格式应为 YYYY-MM，例如 2026-09');
  }
  int ordinal(String text) =>
      int.parse(text.substring(0, 4)) * 12 + int.parse(text.substring(5)) - 1;
  final from = ordinal(start), to = ordinal(last);
  if (to < from) throw const FormatException('结束月份不能早于起始月份');
  if (to - from >= 12) throw const FormatException('范围最多十二个月（含起止月份）');
  return [
    for (var month = from; month <= to; month++)
      {
        field: value,
        'opMonth':
            '${(month ~/ 12).toString().padLeft(4, '0')}${(month % 12 + 1).toString().padLeft(2, '0')}',
      },
  ];
}

/// 数据查询支持的四张业务表，分别复用现有只读接口，不新增后端接口。
/// 命名为 TableKind 以避免与 Flutter 的 DataTable 控件冲突。
enum TableKind { woinfo, wobizinfo, wosigninfo, wopicinfo }

extension TableKindName on TableKind {
  /// 面板展示用的中文名称。
  String get label => ['工单表', '报文表', '签字表', '图片表'][index];

  /// 服务端物理表名（按月份分表，此处为基表名）。
  String get tableName =>
      ['WO_INFO', 'WO_BIZ_INFO', 'WO_SIGN_INFO', 'WO_PIC_INFO'][index];

  /// 复用的只读查询接口类别。
  Category get category => [
    Category.work,
    Category.message,
    Category.sign,
    Category.picture,
  ][index];

  /// 图片序号条件仅适用于图片表。
  bool get hasPicSeq => this == TableKind.wopicinfo;
}

/// 构造按表查询请求体：只放入非空条件；opMonth 由 YYYY-MM 转为 YYYYMM，
/// 供服务端定位按月份拆分的物理表（如 WO_INFO202610）。
Record tableQueryBody(
  TableKind table, {
  String caseNo = '',
  String sysAccept = '',
  String opMonth = '',
  String picSeq = '',
}) {
  caseNo = caseNo.trim();
  sysAccept = sysAccept.trim();
  opMonth = opMonth.trim();
  picSeq = picSeq.trim();
  if (caseNo.isEmpty && sysAccept.isEmpty && opMonth.isEmpty && picSeq.isEmpty) {
    throw const FormatException('请至少填写一个查询条件');
  }
  if (caseNo.isEmpty && sysAccept.isNotEmpty && opMonth.isEmpty) {
    throw const FormatException('按受理流水查询请选择业务月份');
  }
  final body = <String, dynamic>{};
  if (caseNo.isNotEmpty) body['caseNo'] = caseNo;
  if (sysAccept.isNotEmpty) body['sysAccept'] = sysAccept;
  if (opMonth.isNotEmpty) {
    if (!RegExp(r'^\d{4}-(0[1-9]|1[0-2])$').hasMatch(opMonth)) {
      throw const FormatException('月份格式应为 YYYY-MM，例如 2026-09');
    }
    body['opMonth'] = opMonth.replaceAll('-', '');
  }
  if (picSeq.isNotEmpty) {
    if (!table.hasPicSeq) {
      throw const FormatException('图片序号仅适用于图片表');
    }
    if (!RegExp(r'^\d+$').hasMatch(picSeq) || int.parse(picSeq) <= 0) {
      throw const FormatException('图片序号应为正整数');
    }
    body['picSeq'] = picSeq;
  }
  return body;
}

/// OBS 命名依据 UploadFile2ObsHandler、OneStoreModelFileObjectService 与 WoBizTxtTypeEnum。
class Asset {
  final String name, label, kind;
  final Record record;
  const Asset(this.name, this.label, this.kind, this.record);
  static List<Asset> fromRecords(
    Category type,
    List<Record> records,
    Record work,
  ) {
    if (type == Category.work) {
      return [Asset('${work['caseNo']}.pdf', '单据 PDF', 'pdf', work)];
    }
    if (type == Category.message) {
      return records.expand((record) {
        if ('${record['caseNo'] ?? ''}'.isEmpty ||
            '${record['cmdCode'] ?? ''}'.isEmpty) {
          throw const FormatException('报文记录缺少 caseNo 或 cmdCode，无法构造 OBS 对象名');
        }
        return [('', '原始报文'), ('_oprInfo', '受理内容'), ('_h5', 'H5 报文')].map(
          (item) => Asset(
            '${record['caseNo']}_${record['cmdCode']}${item.$1}.txt',
            '${record['cmdCode']} · ${item.$2}',
            'text',
            record,
          ),
        );
      }).toList();
    }
    return records.map((record) {
      final path =
          '${record[type == Category.sign ? 'signPath' : 'picPath'] ?? ''}';
      final name = path.replaceAll('\\', '/').split('/').last;
      return Asset(
        name,
        '${record[type == Category.sign ? 'signTypeName' : 'picTypeName'] ?? name}',
        'image',
        record,
      );
    }).toList();
  }

  Record obsBody(Record work, ConnectionSettings settings) {
    final region = '${work['regionCode'] ?? ''}';
    if (settings.bucket.isEmpty && region.isEmpty) {
      throw const FormatException('工单缺少 regionCode，无法确定 OBS 桶');
    }
    if (name.isEmpty) throw const FormatException('记录缺少文件路径，无法确定 OBS 对象名');
    return {
      'bucketName': settings.bucket.isNotEmpty
          ? settings.bucket
          : 'receipt$region',
      'objectName': name,
      'ext8': '${work['ext8'] ?? '0'}',
    };
  }
}

/// 文件类型基于实际字节判断，避免把服务错误页显示成正常影像。
String detectType(Uint8List bytes, String expected) {
  bool starts(List<int> prefix) =>
      bytes.length >= prefix.length &&
      List.generate(
        prefix.length,
        (i) => bytes[i] == prefix[i],
      ).every((v) => v);
  if (starts([37, 80, 68, 70])) return 'pdf';
  if (starts([137, 80, 78, 71]) ||
      starts([255, 216]) ||
      starts([71, 73, 70]) ||
      starts([66, 77])) {
    return 'image';
  }
  if (bytes.length >= 12 &&
      ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP') {
    return 'image';
  }
  if (expected == 'text') {
    final sample = utf8
        .decode(bytes.take(100).toList(), allowMalformed: true)
        .trimLeft()
        .toLowerCase();
    if (sample.startsWith('<!doctype html') || sample.startsWith('<html')) {
      throw const FormatException('服务返回 HTML 页面，请检查地址或登录状态');
    }
    return 'text';
  }
  return 'binary';
}
