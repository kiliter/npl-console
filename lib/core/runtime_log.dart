import 'dart:async';
import 'package:flutter/foundation.dart';
import 'request_log_store.dart';

/// 独立程序运行日志。每次运行最多保留五个 4MB 分卷。
class RuntimeLog extends ChangeNotifier {
  static final instance = RuntimeLog();
  final RequestLogStore store;
  RuntimeLog({RequestLogStore? store})
    : store =
          store ??
          RequestLogStore(
            folderName: 'runtime-logs',
            filePrefix: 'runtime',
            maxBytes: 4 * 1024 * 1024,
          );

  static String sanitize(String text) {
    var value = text.replaceAll(
      RegExp(
        r'-----BEGIN [^-]*PRIVATE KEY-----[\s\S]*?-----END [^-]*PRIVATE KEY-----',
      ),
      '[私钥已隐藏]',
    );
    value = value.replaceAll(
      RegExp(r'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+'),
      '[JWT已隐藏]',
    );
    value = value.replaceAllMapped(
      RegExp(
        r'''((?:authorization|agAuthorization|password|secret|token|privateKey|accessKey|密钥|密码)["\s]*[:=]\s*)(?:Bearer\s+)?(?:"[^"]*"|'[^']*'|[^\s,;}]+)''',
        caseSensitive: false,
      ),
      (m) => '${m[1]}[已隐藏]',
    );
    return value.length > 16000 ? '${value.substring(0, 16000)}…[已截断]' : value;
  }

  Future<void> write(
    String event, {
    String? message,
    StackTrace? stack,
    Map<String, Object?> data = const {},
  }) async {
    final previousPath = store.path, previousError = store.error;
    await store.append({
      '时间': DateTime.now().toIso8601String(),
      '事件': event,
      if (message != null) '消息': sanitize(message),
      if (stack != null) '调用栈': sanitize(stack.toString()),
      ...data,
    });
    if (previousPath != store.path || previousError != store.error) {
      notifyListeners();
    }
  }

  void failure(String event, Object error, StackTrace stack) {
    // 不写任意异常对象的正文，避免 HTTP 响应或业务数据进入全局日志。
    unawaited(
      write(event, message: error.runtimeType.toString(), stack: stack),
    );
  }
}
