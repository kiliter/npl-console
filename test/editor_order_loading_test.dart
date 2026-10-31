import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:npl_maintenance/core/contracts.dart';
import 'package:npl_maintenance/core/maintenance_controller.dart';

void main() {
  test(
    'editor load uses exact case number, query and OBS contracts without changing query selection',
    () async {
      final requests = <http.Request>[];
      final pdf = File('test/fixtures/reader.pdf').readAsBytesSync();
      final c =
          MaintenanceController(
              testToken: () => 'token',
              clientFactory: () => MockClient((request) async {
                requests.add(request);
                if (request.url.path.endsWith('/api/wo/queryList')) {
                  expect(jsonDecode(request.body), {'caseNo': 'NEW'});
                  return http.Response(
                    jsonEncode([
                      {
                        'caseNo': 'NEW',
                        'regionCode': '3301',
                        'opMonth': '202610',
                        'ext8': '1',
                      },
                    ]),
                    200,
                  );
                }
                expect(Uri.splitQueryString(request.body), {
                  'bucketName': 'receipt3301',
                  'objectName': 'NEW.pdf',
                  'ext8': '1',
                });
                return http.Response.bytes(pdf, 200);
              }),
            )
            ..settings = const ConnectionSettings(
              baseUrl: 'https://example.invalid/npl',
              loginNo: 'a',
              channel: 'b',
            )
            ..work = {'caseNo': 'EXISTING'}
            ..works = [
              {'caseNo': 'EXISTING'},
            ];
      final result = await c.loadEditorPdf(' NEW ');
      expect(result.work['caseNo'], 'NEW');
      expect(result.bytes, pdf);
      expect(c.work!['caseNo'], 'EXISTING');
      expect(c.works.single['caseNo'], 'EXISTING');
      expect(requests.map((r) => r.url.path), [
        '/npl/api/wo/queryList',
        '/npl/test/un_look',
      ]);
      expect(requests.every((r) => r.headers['kkk'] == 'token'), isTrue);
      c.dispose();
    },
  );
  test('missing or ambiguous order fails before any OBS access', () async {
    var calls = 0;
    final c =
        MaintenanceController(
            testToken: () => 'token',
            clientFactory: () => MockClient((request) async {
              calls++;
              return http.Response(
                jsonEncode([
                  {'caseNo': 'SOMEONE_ELSE'},
                ]),
                200,
              );
            }),
          )
          ..settings = const ConnectionSettings(
            baseUrl: 'https://example.invalid',
            loginNo: 'a',
            channel: 'b',
          );
    await expectLater(c.loadEditorPdf('NEW'), throwsFormatException);
    expect(calls, 1);
    c.dispose();
  });
  test('HTML or other bytes cannot be opened as a valid PDF', () async {
    final c =
        MaintenanceController(
            testToken: () => 'token',
            clientFactory: () => MockClient((request) async {
              return http.Response(
                request.url.path.contains('queryList')
                    ? '[{"caseNo":"NEW","regionCode":"1"}]'
                    : '<html>login</html>',
                200,
              );
            }),
          )
          ..settings = const ConnectionSettings(
            baseUrl: 'https://example.invalid',
            loginNo: 'a',
            channel: 'b',
          );
    await expectLater(c.loadEditorPdf('NEW'), throwsFormatException);
    c.dispose();
  });
}
