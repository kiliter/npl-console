import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// 应用当前版本；发布新版本时与 pubspec.yaml 的 version 字段同步修改。
const appVersion = '1.3.6';

/// GitHub 发布仓库（所有者/仓库名），正式包由 CI 推送到该仓库 Release。
const releaseRepo = 'kiliter/npl-console';

/// GitHub Release 的一个附件（安装包）。
class ReleaseAsset {
  final String name, downloadUrl;

  /// 附件字节数；服务端未给出时为 0。
  final int size;
  const ReleaseAsset({
    required this.name,
    required this.downloadUrl,
    required this.size,
  });
}

/// 一次检查更新的结果，仅在发现更新版本时返回。
class UpdateInfo {
  final String version, url, notes;

  /// 该 Release 的附件清单，用于按平台挑选可应用内安装的安装包。
  final List<ReleaseAsset> assets;
  const UpdateInfo({
    required this.version,
    required this.url,
    required this.notes,
    this.assets = const [],
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

/// 按运行平台从 Release 附件中挑选安装包；iOS（未签名 IPA 无法自安装）
/// 与没有匹配附件时返回 null，由调用方回退到浏览器下载。
/// macOS 优先 PKG（系统安装器自动覆盖旧版并提示清理安装包），
/// 兼容只有 DMG 的旧 Release。
/// 附件命名约定见 .github/workflows/release.yml。
ReleaseAsset? selectAssetForPlatform(
  TargetPlatform platform,
  List<ReleaseAsset> assets,
) {
  final suffixes = switch (platform) {
    TargetPlatform.android => const ['-android-release.apk'],
    TargetPlatform.macOS => const ['-macos-universal.pkg', '-macos-universal.dmg'],
    TargetPlatform.windows => const ['-windows-x64-selfsigned.zip'],
    _ => const <String>[],
  };
  for (final suffix in suffixes) {
    for (final asset in assets) {
      if (asset.name.endsWith(suffix)) return asset;
    }
  }
  return null;
}

/// 把 GitHub 附件下载地址改写为加速站地址；前缀为空时原样返回。
/// 加速站通常以前缀拼接方式代理，如 https://ghproxy.net/https://github.com/...
String applyProxyPrefix(String url, String proxyPrefix) {
  final prefix = proxyPrefix.trim();
  if (prefix.isEmpty) return url;
  return '$prefix$url';
}

/// 解析 Release JSON 中的附件清单；结构异常的条目直接跳过。
List<ReleaseAsset> _parseAssets(Object? raw) {
  final assets = <ReleaseAsset>[];
  if (raw is! List) return assets;
  for (final item in raw) {
    if (item is Map &&
        item['name'] is String &&
        item['browser_download_url'] is String) {
      assets.add(
        ReleaseAsset(
          name: item['name'] as String,
          downloadUrl: item['browser_download_url'] as String,
          size: item['size'] is int ? item['size'] as int : 0,
        ),
      );
    }
  }
  return assets;
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
      assets: _parseAssets(decoded['assets']),
    );
  } finally {
    if (client == null) httpClient.close();
  }
}
