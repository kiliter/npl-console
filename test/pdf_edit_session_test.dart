import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:npl_maintenance/core/pdf_editor/edit_session.dart';
import 'package:npl_maintenance/core/pdf_editor/pdf_engine.dart';

class _DelayedEngine extends PdfEditEngine {
  // 假引擎没有真实文字层，页面类型固定为地市协议页，避免调用原生识别。
  @override
  Future<PdfPageKind> pageKind(
    Uint8List bytes,
    int index, {
    bool Function()? isNeeded,
  }) async => PdfPageKind.cityAgreement;

  final first = Completer<PdfPageSnapshot>();
  int calls = 0;
  @override
  Future<PdfPageSnapshot> inspect(
    Uint8List bytes,
    int pageIndex, {
    bool Function()? isNeeded,
  }) async {
    if (calls++ == 0) return first.future;
    return PdfPageSnapshot(Uint8List(0), const Size(595, 842), [], 1);
  }
}

void main() {
  test(
    'environment reset cannot be overwritten by an old document load',
    () async {
      final engine = _DelayedEngine();
      final active = PdfEditSession(engine: engine);
      final loading = active.load('OLD_ENV', Uint8List.fromList([1]));
      active.reset();
      await active.load('NEW_ENV', Uint8List.fromList([2]));
      engine.first.complete(
        PdfPageSnapshot(Uint8List(0), const Size(595, 842), [], 1),
      );
      await loading;
      expect(active.target!.caseNo, 'NEW_ENV');
      expect(active.busy, isFalse);
      active.dispose();
    },
  );
  test(
    'disposing while a load is in flight does not notify or restore a document',
    () async {
      final engine = _DelayedEngine();
      final active = PdfEditSession(engine: engine);
      var notices = 0;
      active.addListener(() => notices++);
      final loading = active.load('OLD', Uint8List.fromList([1]));
      active.dispose();
      engine.first.complete(
        PdfPageSnapshot(Uint8List(0), const Size(595, 842), [], 1),
      );
      await loading;
      expect(notices, 1);
      expect(active.target, isNull);
    },
  );
  test(
    'failed saves and saving an old revision cannot clear new dirty state',
    () {
      final first = Uint8List.fromList([1]), next = Uint8List.fromList([2]);
      final doc = EditDocument(
        'A',
        first,
        PdfPageSnapshot(Uint8List(0), const Size(595, 842), [], 1),
      );
      final session = PdfEditSession()..target = doc;
      doc.commit(next);
      session.markSaved(first);
      expect(doc.dirty, isTrue);
      session.markSaved(next);
      expect(doc.dirty, isFalse);
      doc.commit(Uint8List.fromList([3]));
      expect(doc.dirty, isTrue);
      session.dispose();
    },
  );
}
