import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:npl_maintenance/core/app_update.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 验证加速站配置存取与 Release 附件下载，全部使用模拟存储与模拟 HTTP。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 系统临时目录下的唯一测试文件路径，用后即删。
  String tempFile(String tag) =>
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'app_update_test_${tag}_${DateTime.now().microsecondsSinceEpoch}.bin';

  group('加速站配置存取', () {
    test('默认空串，保存后可读取，保存空白即清除', () async {
      SharedPreferences.setMockInitialValues({});
      final store = GithubProxyStore();
      expect(await store.load(), '');
      await store.save(' https://ghproxy.net/ ');
      expect(await store.load(), 'https://ghproxy.net/');
      await store.save('   ');
      expect(await store.load(), '');
    });
  });

  group('下载 Release 附件', () {
    test('流式写入文件并回调进度', () async {
      final client = MockClient.streaming(
        (request, bodyStream) async => http.StreamedResponse(
          Stream.fromIterable([utf8.encode('hello '), utf8.encode('world')]),
          200,
          contentLength: 11,
        ),
      );
      final path = tempFile('ok');
      addTearDown(() async {
        final file = File(path);
        if (await file.exists()) await file.delete();
      });
      final progress = <(int, int)>[];
      await downloadRelease(
        url: 'https://example.com/pkg',
        destPath: path,
        client: client,
        onProgress: (received, total) => progress.add((received, total)),
      );
      expect(await File(path).readAsString(), 'hello world');
      expect(progress, [
        (6, 11),
        (11, 11),
      ]);
    });

    test('非 200 抛 FormatException 且不留残留文件', () async {
      final client = MockClient.streaming(
        (request, bodyStream) async =>
            http.StreamedResponse(const Stream.empty(), 404),
      );
      final path = tempFile('404');
      await expectLater(
        downloadRelease(
          url: 'https://example.com/x',
          destPath: path,
          client: client,
        ),
        throwsA(isA<FormatException>()),
      );
      expect(await File(path).exists(), isFalse);
    });

    test('取消令牌中断下载并删除残留文件', () async {
      final token = DownloadToken();
      final client = MockClient.streaming(
        (request, bodyStream) async => http.StreamedResponse(
          Stream.fromIterable([
            [1, 2, 3],
            [4, 5, 6],
          ]),
          200,
        ),
      );
      final path = tempFile('cancel');
      await expectLater(
        downloadRelease(
          url: 'https://example.com/x',
          destPath: path,
          client: client,
          token: token,
          // 收到第一个数据块后取消，第二个数据块处应中断。
          onProgress: (_, _) => token.cancel(),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(await File(path).exists(), isFalse);
    });
  });
}
