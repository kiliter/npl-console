import 'dart:convert';
import 'dart:typed_data';

typedef Record = Map<String, dynamic>;

/// 一个可切换的后台环境：服务地址必填，web 地址仅日志文件功能使用（可选）。
class Environment {
  final String name, baseUrl, webBaseUrl;
  const Environment({this.name = '', this.baseUrl = '', this.webBaseUrl = ''});
  Map<String, String> toJson() => {
    'name': name,
    'baseUrl': baseUrl,
    'webBaseUrl': webBaseUrl,
  };
  factory Environment.fromJson(Map json) => Environment(
    name: json['name']?.toString() ?? '',
    baseUrl: json['baseUrl']?.toString() ?? '',
    webBaseUrl: json['webBaseUrl']?.toString() ?? '',
  );
}

/// 持久化配置不包含密码、JWT 或私钥。
/// 支持多个环境：默认构造兼容旧的单 baseUrl 写法，[ConnectionSettings.multi] 用于多环境。
// 命名参数无法写成私有字段的初始化形参，因此关闭该提示。
// ignore_for_file: prefer_initializing_formals
class ConnectionSettings {
  final String bucket, loginNo, channel;

  /// 当前环境下标；越界时由 [validate] 拒绝。
  final int active;
  final List<Environment>? _environments;
  final String _baseUrl, _webBaseUrl;
  const ConnectionSettings({
    String baseUrl = '',
    String webBaseUrl = '',
    this.bucket = '',
    this.loginNo = '',
    this.channel = '',
  }) : _baseUrl = baseUrl,
       _webBaseUrl = webBaseUrl,
       _environments = null,
       active = 0;
  const ConnectionSettings.multi({
    required List<Environment> environments,
    this.active = 0,
    this.bucket = '',
    this.loginNo = '',
    this.channel = '',
  }) : _environments = environments,
       _baseUrl = '',
       _webBaseUrl = '';

  List<Environment> get environments =>
      _environments ??
      [Environment(name: '默认环境', baseUrl: _baseUrl, webBaseUrl: _webBaseUrl)];

  Environment get current {
    final list = environments;
    return active >= 0 && active < list.length
        ? list[active]
        : const Environment();
  }

  String get baseUrl => current.baseUrl;
  String get webBaseUrl => current.webBaseUrl;

  /// 切换环境只改变下标，工号、渠道与桶覆盖保持全局。
  ConnectionSettings withActive(int index) => ConnectionSettings.multi(
    environments: environments,
    active: index,
    bucket: bucket,
    loginNo: loginNo,
    channel: channel,
  );

  Map<String, Object> toJson() => {
    'environments': [for (final item in environments) item.toJson()],
    'active': active,
    'bucket': bucket,
    'loginNo': loginNo,
    'channel': channel,
  };

  /// 兼容旧版仅保存单个 baseUrl 的配置。
  factory ConnectionSettings.fromJson(Record json) {
    final raw = json['environments'];
    final list = raw is List
        ? raw.whereType<Map>().map(Environment.fromJson).toList()
        : [
            Environment(
              name: '默认环境',
              baseUrl: json['baseUrl']?.toString() ?? '',
            ),
          ];
    final index = json['active'] is int ? json['active'] as int : 0;
    return ConnectionSettings.multi(
      environments: list,
      active: list.isEmpty ? 0 : index.clamp(0, list.length - 1),
      bucket: json['bucket']?.toString() ?? '',
      loginNo: json['loginNo']?.toString() ?? '',
      channel: json['channel']?.toString() ?? '',
    );
  }

  void validate() {
    final list = environments;
    if (list.isEmpty) throw const FormatException('请至少配置一个环境');
    if (active < 0 || active >= list.length) {
      throw const FormatException('请选择当前使用的环境');
    }
    final names = <String>{};
    for (final item in list) {
      if (item.name.trim().isEmpty) throw const FormatException('环境名称不能为空');
      if (!names.add(item.name.trim())) {
        throw FormatException('环境名称重复：${item.name}');
      }
      _checkUrl(item.baseUrl, '${item.name} 服务地址');
      if (item.webBaseUrl.isNotEmpty) {
        _checkUrl(item.webBaseUrl, '${item.name} web 地址');
      }
    }
    if (loginNo.isEmpty || channel.isEmpty) {
      throw const FormatException('请填写 JWT 工号及渠道');
    }
  }

  static void _checkUrl(String value, String label) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw FormatException(
        '$label 必须是 HTTP/HTTPS 地址，可包含上下文路径，但不能包含密码、查询参数或片段',
      );
    }
  }
}

/// 日志文件所属应用：服务（npl-service）或 web（npl-web）。
enum LogApp { server, web }

extension LogAppName on LogApp {
  String get label => this == LogApp.server ? '服务' : 'web';

  /// 解析当前环境对应的地址；web 地址未配置时给出明确提示。
  String baseUrl(ConnectionSettings settings) {
    final value = this == LogApp.server
        ? settings.baseUrl
        : settings.webBaseUrl;
    if (value.isEmpty) {
      throw FormatException(
        '当前环境「${settings.current.name}」未配置 $label 地址，请在设置中填写',
      );
    }
    return value.replaceAll(RegExp(r'/+$'), '');
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
  Category get category =>
      [Category.work, Category.message, Category.sign, Category.picture][index];

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
  if (caseNo.isEmpty &&
      sysAccept.isEmpty &&
      opMonth.isEmpty &&
      picSeq.isEmpty) {
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
