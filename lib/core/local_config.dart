import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 配置与业务签名密钥存放在应用专属目录；密钥不得进入日志。
class LocalConfig {
  const LocalConfig();
  static Directory? testDirectory;
  static Future<void> _queue = Future.value();
  static void useTestDirectory(Directory directory) {
    testDirectory = directory;
    _queue = Future.value();
  }

  static Future<T> serialized<T>(Future<T> Function() operation) {
    final result = _queue.then((_) => operation());
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<Directory> directory() async {
    final Directory dir;
    if (testDirectory != null) {
      dir = testDirectory!;
    } else if (Platform.isMacOS || Platform.isLinux || Platform.isWindows) {
      final home =
          Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
      if (home == null || home.isEmpty) {
        throw const FormatException('无法定位用户配置目录');
      }
      dir = Directory('$home/.config/npl-maintenance');
    } else {
      dir = Directory(
        '${(await getApplicationSupportDirectory()).path}/.config/npl-maintenance',
      );
    }
    if (await FileSystemEntity.type(dir.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FormatException('配置目录不能是符号链接');
    }
    await dir.create(recursive: true);
    _permissions(dir.path, 448); // 0700
    return dir;
  }

  void _permissions(String path, int mode) {
    if (Platform.isWindows) return; // 使用用户目录继承的 ACL。
    final chmod = ffi.DynamicLibrary.process()
        .lookupFunction<
          ffi.Int32 Function(ffi.Pointer<Utf8>, ffi.Uint32),
          int Function(ffi.Pointer<Utf8>, int)
        >('chmod');
    final nativePath = path.toNativeUtf8();
    try {
      if (chmod(nativePath, mode) != 0) {
        throw const FormatException('无法设置本地配置访问权限');
      }
    } finally {
      calloc.free(nativePath);
    }
  }

  Future<File> _file(String name) async {
    if (!RegExp(r'^[a-zA-Z0-9_-]+(?:\.[a-zA-Z0-9_-]+)*$').hasMatch(name)) {
      throw const FormatException('无效配置文件名');
    }
    final file = File('${(await directory()).path}/$name');
    if (await FileSystemEntity.type(file.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FormatException('配置文件不能是符号链接');
    }
    return file;
  }

  Future<String?> readFile(String name) async {
    final file = await _file(name);
    if (!await file.exists()) return null;
    _permissions(file.path, 384); // 0600
    return file.readAsString();
  }

  Future<void> writeFile(String name, String value) async {
    final file = await _file(name);
    final temp = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await temp.writeAsString(value, flush: true);
      _permissions(temp.path, 384);
      if (await temp.readAsString() != value) {
        throw const FormatException('本地配置写入校验失败');
      }
      await temp.rename(file.path);
      if (await readFile(name) != value) {
        throw const FormatException('本地配置读回校验失败');
      }
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  Future<void> deleteFile(String name) async {
    final file = await _file(name);
    if (await file.exists()) await file.delete();
  }

  // remove 会先删除内存缓存，即使持久化失败也必须无条件重试。
  Future<void> _cleanupLegacy(SharedPreferences legacy, String key) async {
    if (!await legacy.remove(key)) {
      throw const FormatException('旧配置清理失败，请重试');
    }
  }

  /// 按项迁移，只有成功读回文件才清理旧偏好；标记防止删除后旧数据复活。
  Future<String?> getString(String key) => serialized(() async {
    final current = await readFile('$key.json');
    final migrated = await readFile('$key.migrated') != null;
    final legacy = await SharedPreferences.getInstance();
    if (current != null || migrated) {
      // 补齐写入新文件后中断留下的标记，再重试旧副本清理。
      if (!migrated) await writeFile('$key.migrated', '1');
      await _cleanupLegacy(legacy, key);
      return current;
    }
    final value = legacy.getString(key);
    if (value != null) await writeFile('$key.json', value);
    await writeFile('$key.migrated', '1');
    await _cleanupLegacy(legacy, key);
    return value;
  });
  Future<bool> setString(String key, String value) => serialized(() async {
    await writeFile('$key.json', value);
    await writeFile('$key.migrated', '1');
    await _cleanupLegacy(await SharedPreferences.getInstance(), key);
    return true;
  });
  Future<void> remove(String key) => serialized(() async {
    await writeFile('$key.migrated', '1');
    await deleteFile('$key.json');
    await _cleanupLegacy(await SharedPreferences.getInstance(), key);
  });
}
