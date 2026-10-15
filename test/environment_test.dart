import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:npl_maintenance/core/contracts.dart';
import 'package:npl_maintenance/core/maintenance_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const envs = [
    Environment(name: '测试', baseUrl: 'https://test.invalid/npl'),
    Environment(
      name: '生产',
      baseUrl: 'https://prod.invalid/npl',
      webBaseUrl: 'https://prod.invalid/nplweb',
    ),
  ];

  test('旧版单 baseUrl 配置读取为一个默认环境', () {
    final settings = ConnectionSettings.fromJson({
      'baseUrl': 'https://old.invalid/npl',
      'loginNo': 'a',
      'channel': 'b',
    });
    expect(settings.environments, hasLength(1));
    expect(settings.current.name, '默认环境');
    expect(settings.baseUrl, 'https://old.invalid/npl');
    settings.validate();
  });

  test('多环境序列化往返后保持当前环境', () {
    const settings = ConnectionSettings.multi(
      environments: envs,
      active: 1,
      loginNo: 'a',
      channel: 'b',
    );
    final restored = ConnectionSettings.fromJson(
      jsonDecode(jsonEncode(settings.toJson())) as Map<String, dynamic>,
    );
    expect(restored.active, 1);
    expect(restored.baseUrl, 'https://prod.invalid/npl');
    expect(restored.webBaseUrl, 'https://prod.invalid/nplweb');
    expect(LogApp.web.baseUrl(restored), 'https://prod.invalid/nplweb');
  });

  test('环境名称重复或地址非法时拒绝保存', () {
    expect(
      () => const ConnectionSettings.multi(
        environments: [
          Environment(name: '测试', baseUrl: 'https://a.invalid'),
          Environment(name: '测试', baseUrl: 'https://b.invalid'),
        ],
        loginNo: 'a',
        channel: 'b',
      ).validate(),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => const ConnectionSettings.multi(
        environments: [
          Environment(
            name: '坏',
            baseUrl: 'https://x.invalid',
            webBaseUrl: 'ftp://x',
          ),
        ],
        loginNo: 'a',
        channel: 'b',
      ).validate(),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('web 地址'),
        ),
      ),
    );
  });

  test('切换环境持久化下标并清空当前结果与缓存', () async {
    SharedPreferences.setMockInitialValues({});
    final c = MaintenanceController(testToken: () => 'token')
      ..settings = const ConnectionSettings.multi(
        environments: envs,
        loginNo: 'a',
        channel: 'b',
      )
      ..works = [
        {'caseNo': 'OLD'},
      ];
    await c.selectEnvironment(1);
    expect(c.settings.baseUrl, 'https://prod.invalid/npl');
    expect(c.works, isEmpty);
    expect(c.busy, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(jsonDecode(prefs.getString('connection')!)['active'], 1);
    c.dispose();
  });
}
