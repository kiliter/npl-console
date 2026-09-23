import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:npl_maintenance/core/update_check.dart';

/// 验证检查更新的版本比较与 GitHub Release 解析，全部使用模拟 HTTP，不访问真实网络。
void main() {
  group('版本比较', () {
    test('忽略 v 前缀与构建号，按数字段比较', () {
      expect(compareVersions('v1.2.0', '1.1.0'), greaterThan(0));
      expect(compareVersions('1.2.0+3', 'v1.2.0'), 0);
      expect(compareVersions('1.10.0', '1.9.9'), greaterThan(0));
      expect(compareVersions('v0.9.9', '1.0.0'), lessThan(0));
      expect(compareVersions('1.2', '1.2.0'), 0);
      expect(compareVersions('v2', '1.9.9'), greaterThan(0));
    });
  });

  group('检查最新 Release', () {
    test('有更新版本时返回版本号、下载地址与更新说明', () async {
      final client = MockClient((request) async {
        expect(request.method, 'GET');
        expect(
          request.url.toString(),
          'https://api.github.com/repos/kiliter/npl-console/releases/latest',
        );
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'tag_name': 'v9.9.9',
              'html_url': 'https://github.com/kiliter/npl-console/releases/tag/v9.9.9',
              'body': '修复若干问题',
            }),
          ),
          200,
        );
      });
      final update = await checkLatestRelease(
        client: client,
        currentVersion: '1.2.0',
      );
      expect(update, isNotNull);
      expect(update!.version, '9.9.9');
      expect(
        update.url,
        'https://github.com/kiliter/npl-console/releases/tag/v9.9.9',
      );
      expect(update.notes, '修复若干问题');
    });

    test('已是最新（版本相同或更高）时返回 null', () async {
      MockClient client(String tag) => MockClient(
        (_) async => http.Response.bytes(
          utf8.encode(jsonEncode({'tag_name': tag, 'html_url': 'https://x'})),
          200,
        ),
      );
      expect(
        await checkLatestRelease(client: client('v1.2.0'), currentVersion: '1.2.0'),
        isNull,
      );
      expect(
        await checkLatestRelease(client: client('v1.1.0'), currentVersion: '1.2.0'),
        isNull,
      );
    });

    test('接口非 200 或结构异常时抛出 FormatException', () async {
      await expectLater(
        checkLatestRelease(
          client: MockClient((_) async => http.Response('not found', 404)),
        ),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        checkLatestRelease(
          client: MockClient(
            (_) async => http.Response.bytes(utf8.encode('[1,2]'), 200),
          ),
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('附件挑选与加速站', () {
    /// 模拟一次四端 Release 的附件清单，命名与 CI 发布约定一致。
    final assets = [
      const ReleaseAsset(
        name: 'NPL-Console-v9.9.9-android-release.apk',
        downloadUrl: 'https://github.com/x/android.apk',
        size: 100,
      ),
      const ReleaseAsset(
        name: 'NPL-Console-v9.9.9-macos-universal.dmg',
        downloadUrl: 'https://github.com/x/macos.dmg',
        size: 200,
      ),
      const ReleaseAsset(
        name: 'NPL-Console-v9.9.9-windows-x64-selfsigned.zip',
        downloadUrl: 'https://github.com/x/win.zip',
        size: 300,
      ),
      const ReleaseAsset(
        name: 'NPL-Console-v9.9.9-ios-unsigned.ipa',
        downloadUrl: 'https://github.com/x/ios.ipa',
        size: 400,
      ),
    ];

    test('按平台匹配对应附件', () {
      expect(
        selectAssetForPlatform(TargetPlatform.android, assets)!.name,
        endsWith('-android-release.apk'),
      );
      expect(
        selectAssetForPlatform(TargetPlatform.macOS, assets)!.name,
        endsWith('-macos-universal.dmg'),
      );
      expect(
        selectAssetForPlatform(TargetPlatform.windows, assets)!.name,
        endsWith('-windows-x64-selfsigned.zip'),
      );
    });

    test('iOS、不支持的平台与无匹配附件时返回 null', () {
      expect(selectAssetForPlatform(TargetPlatform.iOS, assets), isNull);
      expect(selectAssetForPlatform(TargetPlatform.linux, assets), isNull);
      expect(selectAssetForPlatform(TargetPlatform.android, const []), isNull);
    });

    test('加速站前缀改写下载地址，空前缀原样返回', () {
      const url = 'https://github.com/kiliter/npl-console/releases/download/v1/a.apk';
      expect(applyProxyPrefix(url, ''), url);
      expect(applyProxyPrefix(url, '   '), url);
      expect(
        applyProxyPrefix(url, 'https://ghproxy.net/'),
        'https://ghproxy.net/$url',
      );
    });

    test('Release 解析带出附件清单，结构异常条目被跳过', () async {
      final client = MockClient(
        (request) async => http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'tag_name': 'v9.9.9',
              'html_url': 'https://x',
              'assets': [
                {
                  'name': 'NPL-Console-v9.9.9-android-release.apk',
                  'browser_download_url': 'https://dl/apk',
                  'size': 123,
                },
                {'name': '缺少下载地址的条目'},
              ],
            }),
          ),
          200,
        ),
      );
      final update = await checkLatestRelease(
        client: client,
        currentVersion: '1.2.0',
      );
      expect(update!.assets, hasLength(1));
      expect(update.assets.single.size, 123);
      expect(update.assets.single.downloadUrl, 'https://dl/apk');
    });
  });
}
