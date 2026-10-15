import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import 'contracts.dart';
import 'maintenance_controller.dart';

/// 日志目录中的一个条目，字段与 npl-js LogFileEntry 一致。
class LogEntry {
  final String path, type, lastModified, fileKey;
  final int size;
  LogEntry.fromJson(Map json)
    : path = '${json['path'] ?? ''}',
      type = '${json['type'] ?? ''}',
      size = (json['size'] as num?)?.toInt() ?? 0,
      lastModified = '${json['lastModified'] ?? ''}',
      fileKey = '${json['fileKey'] ?? ''}';
  bool get isDir => type == 'DIR';
  String get name => path.split('/').last;
}

/// 某个副本的目录列表；status 为 OK / FAIL / TIMEOUT。
class LogInstance {
  final String instance, pod, status, message;
  final List<LogEntry> entries;
  LogInstance.fromJson(Map json)
    : instance = '${json['instance'] ?? ''}',
      pod = '${json['pod'] ?? ''}',
      status = '${json['status'] ?? ''}',
      message = '${json['message'] ?? ''}',
      entries = (json['entries'] as List? ?? const [])
          .whereType<Map>()
          .map(LogEntry.fromJson)
          .toList();
  bool get ok => status == 'OK';
  String get title => pod.isEmpty ? instance : pod;
}

/// 已写入磁盘的日志文件。
class LogDownload {
  /// 服务端返回的文件名（轮转后可能与列表不同）。
  final String fileName;
  final File file;
  final int size;
  const LogDownload(this.fileName, this.file, this.size);
}

/// 用户取消或新操作替代当前操作时抛出，界面直接忽略。
class LogCancelled implements Exception {
  const LogCancelled();
}

/// 日志文件接口客户端：列目录 + 按 offset 循环拉取 1.5MB 分片，在本机顺序拼接成完整文件。
/// 使用独立 HTTP 连接，取消时不影响工单查询；鉴权与接口记录复用 [MaintenanceController]。
class LogFileClient {
  /// 文件轮转（409）后按 fileKey 重新定位的最大次数。
  static const maxRelocate = 3;
  static const _timeout = Duration(seconds: 60);
  final MaintenanceController controller;
  final LogApp app;
  http.Client? _client;
  int _generation = 0;
  LogFileClient(this.controller, this.app);

  /// 终止进行中的请求；之后的新请求使用新连接。
  void cancel() {
    _generation++;
    _client?.close();
    _client = null;
  }

  Future<List<LogInstance>> list(String dir) => _list(dir, _generation);

  Future<List<LogInstance>> _list(String dir, int ticket) async {
    final response = await _send(
      MaintenanceController.logListEndpoint,
      ticket,
      body: jsonEncode({'dir': dir}),
    );
    final decoded = _json(response);
    if (response.statusCode != 200 || '${decoded['resultCode']}' != '0') {
      throw FormatException(
        '${app.label}日志列表查询失败：${decoded['resultDesc'] ?? 'HTTP ${response.statusCode}'}',
      );
    }
    return (decoded['instances'] as List? ?? const [])
        .whereType<Map>()
        .map(LogInstance.fromJson)
        .toList();
  }

  /// 以首片返回的文件大小为目标逐片下载，每片收到后立即追加写入 [target] 旁的 `.part` 文件，
  /// 内存中最多只有当前一片；全部完成后改名为 [target]，失败或取消时删除 `.part`。
  /// 文件在下载中被轮转改名（409）时，按 fileKey 在同一副本的同一目录重新定位后从当前 offset 续传。
  Future<LogDownload> download(
    LogInstance instance,
    LogEntry entry,
    File target, {
    void Function(int done, int total)? onProgress,
  }) async {
    final ticket = _generation;
    await target.parent.create(recursive: true);
    final part = File('${target.path}.part');
    final sink = await part.open(mode: FileMode.write);
    try {
      final (fileName, size) = await _downloadTo(
        sink,
        instance,
        entry,
        ticket,
        onProgress,
      );
      await sink.close();
      if (await target.exists()) await target.delete();
      await part.rename(target.path);
      return LogDownload(fileName, target, size);
    } catch (_) {
      // 关闭失败不掩盖原始异常；残留的 .part 一并清理。
      try {
        await sink.close();
      } on FileSystemException {
        // 已关闭或句柄失效。
      }
      if (await part.exists()) await part.delete();
      rethrow;
    }
  }

  Future<(String, int)> _downloadTo(
    RandomAccessFile sink,
    LogInstance instance,
    LogEntry entry,
    int ticket,
    void Function(int done, int total)? onProgress,
  ) async {
    var path = entry.path, fileKey = entry.fileKey, fileName = entry.name;
    var offset = 0, relocations = 0;
    int? total;
    while (total == null || offset < total) {
      final response = await _send(
        MaintenanceController.logDownloadEndpoint,
        ticket,
        query: {
          'instance': instance.instance,
          'path': path,
          'offset': '$offset',
          if (fileKey.isNotEmpty) 'fileKey': fileKey,
        },
      );
      if (response.statusCode == 409 &&
          fileKey.isNotEmpty &&
          relocations < maxRelocate) {
        relocations++;
        path = await _relocate(instance, path, fileKey, ticket);
        continue;
      }
      _checkChunk(response);
      final size = int.tryParse(response.headers['x-file-size'] ?? '');
      final at = int.tryParse(response.headers['x-chunk-offset'] ?? '');
      if (size == null || at != offset) {
        throw const FormatException('分片响应缺少文件大小或偏移，请确认网关透传 X-File-* 响应头');
      }
      total ??= size;
      if (fileKey.isEmpty) {
        fileKey = Uri.decodeQueryComponent(
          response.headers['x-file-key'] ?? '',
        );
      }
      final name = response.headers['x-file-name'];
      if (name != null && name.isNotEmpty) {
        fileName = Uri.decodeQueryComponent(name);
      }
      final bytes = response.bodyBytes;
      if (bytes.isEmpty) {
        if (offset >= total) break;
        throw FormatException('文件在下载期间被截断，已下载 $offset / $total 字节，请重新下载');
      }
      // 只取到首片确定的文件大小为止，下载期间追加的新日志不混入本次结果。
      final take = math.min(bytes.length, total - offset);
      await sink.writeFrom(bytes, 0, take);
      offset += take;
      onProgress?.call(offset, total);
    }
    return (fileName, offset);
  }

  Future<String> _relocate(
    LogInstance instance,
    String path,
    String fileKey,
    int ticket,
  ) async {
    final index = path.lastIndexOf('/');
    final dir = index < 0 ? '' : path.substring(0, index);
    final instances = await _list(dir, ticket);
    for (final item in instances) {
      if (item.instance != instance.instance) continue;
      for (final entry in item.entries) {
        if (!entry.isDir && entry.fileKey == fileKey) return entry.path;
      }
    }
    throw FormatException(
      '文件已轮转，且在 ${dir.isEmpty ? '根目录' : dir} 中找不到原文件，请刷新列表后重新下载',
    );
  }

  void _checkChunk(http.Response response) {
    if (response.statusCode != 200) {
      Object? desc;
      try {
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        if (decoded is Map) desc = decoded['resultDesc'];
      } catch (_) {
        desc = null;
      }
      throw FormatException(
        '日志下载失败（HTTP ${response.statusCode}）：${desc ?? '服务端未说明原因，请查看接口记录'}',
      );
    }
    final type = response.headers['content-type'] ?? '';
    if (!type.startsWith('application/octet-stream')) {
      throw FormatException('下载接口未返回文件分片，请检查${app.label}地址或登录状态');
    }
  }

  Map _json(http.Response response) {
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map) return decoded;
    } catch (_) {
      // 统一在下方给出明确提示。
    }
    throw FormatException(
      '${app.label}日志接口未返回 JSON（HTTP ${response.statusCode}），请检查${app.label}地址是否正确',
    );
  }

  Future<http.Response> _send(
    String endpoint,
    int ticket, {
    Map<String, String> query = const {},
    String? body,
  }) async {
    if (ticket != _generation) throw const LogCancelled();
    var uri = Uri.parse('${app.baseUrl(controller.settings)}$endpoint');
    if (query.isNotEmpty) uri = uri.replace(queryParameters: query);
    final contentType = body == null
        ? 'application/x-www-form-urlencoded;charset=UTF-8'
        : 'application/json';
    final call = controller.beginLogFileCall(
      endpoint,
      uri,
      body ?? jsonEncode(query),
      contentType,
    );
    final log = call.log;
    final elapsed = Stopwatch()..start();
    final client = _client ??= controller.clientFactory();
    try {
      final request = http.Request('POST', uri)
        ..followRedirects = false
        ..headers.addAll({
          'Content-Type': contentType,
          'kkk': call.token,
          'agAuthorization': call.token,
        });
      if (body != null) request.body = body;
      final streamed = await client.send(request).timeout(_timeout);
      final response = await http.Response.fromStream(
        streamed,
      ).timeout(_timeout);
      if (ticket != _generation) throw const LogCancelled();
      log.status = response.statusCode;
      final binary = (response.headers['content-type'] ?? '').startsWith(
        'application/octet-stream',
      );
      log.response = binary
          ? '日志分片 · ${response.bodyBytes.length} 字节 · offset ${response.headers['x-chunk-offset'] ?? '—'} / 文件 ${response.headers['x-file-size'] ?? '—'} 字节'
          : utf8.decode(response.bodyBytes, allowMalformed: true);
      log.state = response.statusCode == 200 ? '成功' : '失败';
      return response;
    } catch (exception) {
      log.state = ticket != _generation ? '已取消' : '失败';
      if (log.response.isEmpty) log.response = '请求未完成：${exception.runtimeType}';
      if (ticket != _generation) throw const LogCancelled();
      rethrow;
    } finally {
      elapsed.stop();
      await controller.finishLogFileCall(log, elapsed.elapsedMilliseconds);
    }
  }
}
