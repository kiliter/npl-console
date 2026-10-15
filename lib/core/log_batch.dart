import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'log_files.dart';

/// 批量下载的一个目标：某副本上的某个文件。
class LogTarget {
  final LogInstance instance;
  final LogEntry entry;
  const LogTarget(this.instance, this.entry);
}

/// 批量下载结果：文件按 `<Pod>/<相对路径>` 写在 [folder] 下，失败原因写入「下载失败清单.txt」。
class LogBatchResult {
  final Directory folder;
  final int succeeded;
  final List<String> failures;
  const LogBatchResult(this.folder, this.succeeded, this.failures);
}

/// 选择日志保存目录：桌面端弹出目录选择；手机端系统目录选择器无法直接写入，
/// 固定保存到应用文档目录下的 log-files。用户取消时返回 null。
Future<Directory?> chooseLogFolder() async {
  final mobile =
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
  if (mobile) {
    final root = await getApplicationDocumentsDirectory();
    return Directory('${root.path}${Platform.pathSeparator}log-files');
  }
  final path = await FilePicker.getDirectoryPath(dialogTitle: '选择日志保存目录');
  return path == null ? null : Directory(path);
}

/// 文件名中的非法字符统一替换为下划线。
String safeLogName(String value) =>
    value.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

/// 在全部正常副本的当前目录列表中，按 shell 通配符（同 `ls *.pdf`）匹配文件名（不含目录）。
/// 支持 `*`、`?`、`[abc]` / `[!abc]`；多个模式用空格分隔，命中任一即可；须整名匹配、区分大小写。
List<LogTarget> matchLogFiles(List<LogInstance> instances, String pattern) {
  final globs = pattern.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
  if (globs.isEmpty) throw const FormatException('请输入文件名匹配模式，例如 *.log');
  final regexes = globs.map(globToRegExp).toList();
  return [
    for (final instance in instances)
      if (instance.ok)
        for (final entry in instance.entries)
          if (!entry.isDir && regexes.any((r) => r.hasMatch(entry.name)))
            LogTarget(instance, entry),
  ];
}

/// 把单个通配符模式转为整名匹配的正则；其余字符按字面量处理，未闭合的 `[` 视为普通字符。
RegExp globToRegExp(String glob) {
  final out = StringBuffer('^');
  for (var i = 0; i < glob.length; i++) {
    final c = glob[i];
    if (c == '*') {
      out.write('.*');
    } else if (c == '?') {
      out.write('.');
    } else if (c == '[') {
      final end = glob.indexOf(']', i + 2);
      if (end < 0) {
        out.write(r'\[');
        continue;
      }
      var body = glob.substring(i + 1, end);
      final negate = body.startsWith('!') || body.startsWith('^');
      if (negate) body = body.substring(1);
      out.write('[${negate ? '^' : ''}${body.replaceAll(r'\', r'\\')}]');
      i = end;
    } else {
      out.write(RegExp.escape(c));
    }
  }
  out.write(r'$');
  return RegExp(out.toString());
}

/// 逐个文件顺序下载到 [folder]（每个文件按 1.5MB 分片直接写盘，不在内存中拼接），
/// 单个失败记录原因后继续下一个；用户取消时抛出 [LogCancelled]，已完成的文件保留在目录中。
Future<LogBatchResult> downloadLogBatch(
  LogFileClient client,
  List<LogTarget> targets,
  Directory folder, {
  void Function(int index, LogTarget target, int done, int total)? onProgress,
}) async {
  final failures = <String>[];
  var succeeded = 0;
  final sep = Platform.pathSeparator;
  for (var i = 0; i < targets.length; i++) {
    final target = targets[i];
    // 用列表中的相对路径命名：同一 Pod 内唯一；下载中被轮转改名也仍对应用户所选文件。
    final relative = [
      safeLogName(target.instance.title),
      ...target.entry.path.split('/').map(safeLogName),
    ].join(sep);
    try {
      await client.download(
        target.instance,
        target.entry,
        File('${folder.path}$sep$relative'),
        onProgress: (done, total) => onProgress?.call(i, target, done, total),
      );
      succeeded++;
    } on LogCancelled {
      rethrow;
    } catch (e) {
      final reason = e is FormatException ? e.message : '${e.runtimeType}';
      failures.add('${target.instance.title} / ${target.entry.path}：$reason');
    }
  }
  if (failures.isNotEmpty) {
    await folder.create(recursive: true);
    await File(
      '${folder.path}$sep下载失败清单.txt',
    ).writeAsString('${failures.join('\n')}\n');
  }
  if (succeeded == 0) {
    throw FormatException(
      '全部 ${targets.length} 个文件下载失败：\n${failures.join('\n')}',
    );
  }
  return LogBatchResult(folder, succeeded, failures);
}
