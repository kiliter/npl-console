import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:npl_maintenance/core/pdf_diagnostics.dart';
import 'package:npl_maintenance/core/request_log_store.dart';

void main() {
  test('诊断日志落盘并保留失败调用栈，不写异常中的业务内容', () async {
    final dir = await Directory.systemTemp.createTemp('pdf-diagnostics-');
    final previous = PdfDiagnostics.store;
    final store = RequestLogStore(directoryProvider: () async => dir);
    PdfDiagnostics.store = store;
    try {
      expect(await PdfDiagnostics.trace('测试成功', () async => 42), 42);
      await expectLater(
        PdfDiagnostics.trace<void>('测试失败', () async {
          throw const FormatException('敏感单据内容');
        }),
        throwsFormatException,
      );
      await store.append({'测试': '等待日志写入'});
      final text = await File(store.path!).readAsString();
      final rows = text.trim().split('\n').map(jsonDecode).toList();
      expect(rows.where((r) => r['事件'] == '测试成功：完成').length, 1);
      final failed = rows.singleWhere((r) => r['事件'] == '测试失败：失败');
      expect(failed['异常类型'], 'FormatException');
      expect(failed['调用栈'], isNotEmpty);
      expect(text, isNot(contains('敏感单据内容')));
    } finally {
      PdfDiagnostics.store = previous;
      await dir.delete(recursive: true);
    }
  });
}
