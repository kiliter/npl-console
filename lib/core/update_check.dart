import 'dart:convert';
import 'package:http/http.dart' as http;

/// 应用当前版本；发布新版本时与 pubspec.yaml 的 version 字段同步修改。
const appVersion = '1.2.0';

/// GitHub 发布仓库（所有者/仓库名），正式包由 CI 推送到该仓库 Release。
const releaseRepo = 'kiliter/npl-console';

/// 一次检查更新的结果，仅在发现更新版本时返回。
class UpdateInfo {
  final String version, url, notes;
  const UpdateInfo({
    required this.version,
    required this.url,
    required this.notes,
  });
}

/// 语义化版本比较：a 较新返回正数，相等返回 0，a 较旧返回负数。
/// 忽略 v/V 前缀与 + 构建号，段数不足按 0 补齐，非数字段按 0 处理。
int compareVersions(String a, String b) {
  List<int> parse(String text) => text
      .trim()
      .replaceAll(RegExp(r'^[vV]'), '')
      .split('+')
      .first
      .split('.')
      .map((part) => int.tryParse(part) ?? 0)
      .toList();
  final va = parse(a), vb = parse(b);
  for (var i = 0; i < 3; i++) {
    final x = i < va.length ? va[i] : 0;
    final y = i < vb.length ? vb[i] : 0;
    if (x != y) return x - y;
  }
  return 0;
}

/// 查询 GitHub 最新 Release：有更新版本返回 UpdateInfo，已是最新返回 null。
/// 网络失败或返回结构不符合预期时抛 FormatException，由调用方展示。
/// 该请求只访问 GitHub 公开接口，与业务服务地址无关。
Future<UpdateInfo?> checkLatestRelease({
  http.Client? client,
  String currentVersion = appVersion,
}) async {
  final httpClient = client ?? http.Client();
  try {
    final response = await httpClient
        .get(
          Uri.parse(
            'https://api.github.com/repos/$releaseRepo/releases/latest',
          ),
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw FormatException('检查更新失败：HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map || decoded['tag_name'] is! String) {
      throw const FormatException('检查更新失败：发布信息格式异常');
    }
    final latest = decoded['tag_name'] as String;
    if (compareVersions(latest, currentVersion) <= 0) return null;
    return UpdateInfo(
      version: latest.replaceAll(RegExp(r'^[vV]'), ''),
      url:
          '${decoded['html_url'] ?? 'https://github.com/$releaseRepo/releases/latest'}',
      notes: '${decoded['body'] ?? ''}'.trim(),
    );
  } finally {
    if (client == null) httpClient.close();
  }
}
