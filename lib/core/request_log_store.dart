import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// 按会话保存 JSONL 请求日志；串行追加并立即刷新，便于应用运行期间读取。
/// 只接收调用方挑选的字段，不接收认证头、签名器或密钥配置。
class RequestLogStore {
  final Future<Directory> Function() directoryProvider;
  Future<void> _pending = Future.value();
  File? _file;
  String? error;

  RequestLogStore({Future<Directory> Function()? directoryProvider})
    : directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  String? get path => _file?.path;

  /// 首次写入时创建会话文件；目录由系统提供，兼容四端应用沙盒。
  Future<void> _open() async {
    if (_file != null) return;
    final root = await directoryProvider();
    final directory = Directory('${root.path}/request-logs');
    await directory.create(recursive: true);
    final stamp = DateTime.now().toUtc().microsecondsSinceEpoch;
    final file = File('${directory.path}/requests-$stamp-$pid.jsonl');
    await file.writeAsString('', flush: true);
    _file = file;
  }

  /// 写入失败只记录异常类型，不干扰业务请求；后续追加会再次尝试。
  Future<void> append(Map<String, Object?> record) {
    final line = '${jsonEncode(record)}\n';
    _pending = _pending.then((_) async {
      try {
        await _open();
        await _file!.writeAsString(line, mode: FileMode.append, flush: true);
        error = null;
      } catch (exception) {
        error = '接口日志写入失败（${exception.runtimeType}）';
      }
    });
    return _pending;
  }
}
