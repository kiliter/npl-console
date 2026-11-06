import 'dart:async';
import 'dart:io';
import 'request_log_store.dart';
import 'runtime_log.dart';

/// 主动跳过（非失败）的任务抛出的异常，诊断日志记为“跳过”，不记调用栈。
abstract interface class PdfDiagnosticsSkip implements Exception {}

/// 与接口记录共用文件；不接收单据号、正文、地址或认证参数。
class PdfDiagnostics {
  static RequestLogStore store = RequestLogStore();
  static int _sequence = 0;
  static String nextId() => 'pdf-${++_sequence}';

  static void record(
    String event, {
    String? id,
    Map<String, Object?> data = const {},
  }) {
    unawaited(
      RuntimeLog.instance.write(
        event,
        data: {'类型': 'PDF诊断', '操作': id, ...data},
      ),
    );
    unawaited(
      store.append({
        '时间': DateTime.now().toIso8601String(),
        '类型': 'PDF诊断',
        '事件': event,
        '操作': id,
        ...data,
      }),
    );
  }

  static void environment() {
    record(
      '应用启动',
      data: {
        '系统': Platform.operatingSystem,
        '系统版本': Platform.operatingSystemVersion,
        '进程': pid,
        '程序路径': Platform.resolvedExecutable,
        '工作目录': Directory.current.path,
        '用户目录':
            Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'],
        '临时目录': Directory.systemTemp.path,
      },
    );
  }

  /// 超时仅记日志，不中断原生任务，避免任务仍在执行时释放文档。
  static Future<T> trace<T>(
    String stage,
    Future<T> Function() action, {
    Map<String, Object?> data = const {},
  }) async {
    final id = nextId();
    final watch = Stopwatch()..start();
    record('$stage：开始', id: id, data: data);
    final timer = Timer(const Duration(seconds: 20), () {
      record('$stage：等待超过20秒', id: id, data: data);
    });
    try {
      final result = await action();
      record('$stage：完成', id: id, data: {'耗时毫秒': watch.elapsedMilliseconds});
      return result;
    } on PdfDiagnosticsSkip {
      record('$stage：跳过', id: id, data: {'耗时毫秒': watch.elapsedMilliseconds});
      rethrow;
    } catch (error, stack) {
      record(
        '$stage：失败',
        id: id,
        data: {
          '耗时毫秒': watch.elapsedMilliseconds,
          '异常类型': error.runtimeType.toString(),
          '调用栈': stack.toString(),
        },
      );
      rethrow;
    } finally {
      timer.cancel();
    }
  }
}
