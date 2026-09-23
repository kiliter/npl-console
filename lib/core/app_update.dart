import 'dart:io';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

/// GitHub 加速站前缀的持久化存取；前缀为空表示直连 GitHub。
/// 加速站以前缀拼接方式代理下载地址，仅作用于 Release 附件下载。
class GithubProxyStore {
  static const _key = 'github_proxy_v1';

  /// 读取已保存的加速站前缀；未设置时返回空串。
  Future<String> load() async =>
      (await SharedPreferences.getInstance()).getString(_key) ?? '';

  /// 保存加速站前缀；传入空白时清除设置。
  Future<void> save(String prefix) async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefix.trim();
    if (value.isEmpty) {
      await prefs.remove(_key);
    } else {
      await prefs.setString(_key, value);
    }
  }
}

/// 下载取消令牌：调用 [cancel] 后下载在下一个数据块处中断。
class DownloadToken {
  bool _cancelled = false;
  bool get cancelled => _cancelled;
  void cancel() => _cancelled = true;
}

/// 流式下载 Release 附件到 [destPath]。
/// [onProgress] 回调（已收字节数, 总字节数），总字节数未知时为 0。
/// 网络失败或非 200 抛 FormatException；中途失败或取消时删除残留的不完整文件。
Future<void> downloadRelease({
  required String url,
  required String destPath,
  void Function(int received, int total)? onProgress,
  DownloadToken? token,
  http.Client? client,
}) async {
  final httpClient = client ?? http.Client();
  final file = File(destPath);
  final sink = file.openWrite();
  try {
    final response = await httpClient
        .send(http.Request('GET', Uri.parse(url)))
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw FormatException('下载失败：HTTP ${response.statusCode}');
    }
    final total = response.contentLength ?? 0;
    var received = 0;
    await for (final chunk in response.stream) {
      if (token?.cancelled ?? false) {
        throw const FormatException('下载已取消');
      }
      sink.add(chunk);
      received += chunk.length;
      onProgress?.call(received, total);
    }
    await sink.flush();
    await sink.close();
  } catch (_) {
    await sink.close();
    if (await file.exists()) await file.delete();
    rethrow;
  } finally {
    if (client == null) httpClient.close();
  }
}

/// 选择下载保存目录。
/// macOS 正式包启用系统沙盒，直接写 ~/Downloads、spawn 进程均被拒绝，
/// 因此 macOS 保存到应用支持目录（沙盒内可写）；Android 放临时目录；
/// Windows 无沙盒，优先放系统下载目录，取不到时退回临时目录。
Future<Directory> downloadDirectory() async {
  if (Platform.isAndroid) return getTemporaryDirectory();
  if (Platform.isMacOS) {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}${Platform.pathSeparator}updates');
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }
  final downloads = await getDownloadsDirectory();
  return downloads ?? getTemporaryDirectory();
}

/// 下载完成后拉起安装，返回给用户的后续操作提示。
/// Android 调起系统安装器；macOS 打开 DMG；Windows 解压便携 ZIP 并打开所在目录。
/// iOS 不支持应用内安装，调用方应在 UI 层回退到浏览器下载。
Future<String> launchInstaller(String filePath) async {
  if (Platform.isAndroid) {
    final result = await OpenFilex.open(filePath);
    if (result.type != ResultType.done) {
      throw FormatException('无法打开安装包：${result.message}');
    }
    return '已调起系统安装器，请按提示完成安装。';
  }
  if (Platform.isMacOS) {
    // 沙盒内不能 spawn 进程（Process.run('open') 会被拒绝），
    // 改用 url_launcher，底层走系统 LaunchServices，沙盒允许。
    final opened = await launchUrl(Uri.file(filePath));
    if (!opened) throw const FormatException('无法打开磁盘映像');
    return '已打开磁盘映像，请将应用拖入「应用程序」完成更新。';
  }
  if (Platform.isWindows) {
    final target = await _extractZip(filePath);
    await Process.start('explorer', [target.path]);
    return '已解压新版本并打开所在文件夹，请关闭当前程序后运行新的 npl_maintenance.exe。';
  }
  throw const FormatException('当前平台不支持应用内更新');
}

/// 解压 Windows 便携 ZIP 到「文件名_extracted」目录；已存在时先清空重建。
Future<Directory> _extractZip(String zipPath) async {
  final bytes = await File(zipPath).readAsBytes();
  final archive = ZipDecoder().decodeBytes(bytes);
  final target = Directory('${zipPath}_extracted');
  if (target.existsSync()) await target.delete(recursive: true);
  await target.create(recursive: true);
  for (final entry in archive) {
    final outPath = '${target.path}${Platform.pathSeparator}${entry.name}';
    if (entry.isFile) {
      final out = File(outPath);
      await out.parent.create(recursive: true);
      await out.writeAsBytes(entry.content as List<int>);
    } else {
      await Directory(outPath).create(recursive: true);
    }
  }
  return target;
}
