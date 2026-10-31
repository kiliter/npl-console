import 'dart:io';
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:npl_maintenance/core/pdf_editor/edit_session.dart';
import 'package:npl_maintenance/core/pdf_editor/pdf_engine.dart';
import 'support/pdfium_test_module.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    Pdfrx.pdfiumModulePath = pdfiumTestModule();
    await pdfrxInitialize();
  });
  Future<PdfEditSession> load({bool imageTarget = false}) async {
    final session = PdfEditSession();
    await session.load(
      'NEW',
      File(
        imageTarget ? 'test/fixtures/editor.pdf' : 'test/fixtures/reader.pdf',
      ).readAsBytesSync(),
      sourceNo: 'OLD',
      sourceBytes: File('test/fixtures/editor.pdf').readAsBytesSync(),
    );
    addTearDown(session.dispose);
    return session;
  }

  Future<void> collect(PdfEditSession s, int page) async {
    final snapshot = await s.engine.inspect(s.source!.bytes, page);
    await s.collectSelected([
      (
        page: page,
        object: snapshot.objects.firstWhere(
          (o) => o.kind == PdfObjectKind.image,
        ),
        size: snapshot.size,
      ),
    ]);
  }

  Future<int> images(PdfEditSession s, int page) async =>
      (await s.engine.inspect(s.target!.bytes, page)).objects
          .where(
            (o) =>
                o.kind == PdfObjectKind.image &&
                o.bounds.width > 0 &&
                o.bounds.height > 0,
          )
          .length;

  test('同坐标图层全部保留并置于底稿文字之上，重复应用不累加', () async {
    final s = await load(imageTarget: true);
    await collect(s, 0);
    final first = s.materials.single;
    await s.importLocalImage(first.png, '叠加.png', 0, first.bounds!);
    await s.synchronize();
    expect(s.error, isNull);
    expect(await images(s, 0), 2);
    final snapshot = await s.engine.inspect(s.target!.bytes, 0);
    expect(
      snapshot.objects.reversed
          .take(2)
          .every((o) => o.kind == PdfObjectKind.image),
      isTrue,
    );
    await s.synchronize();
    expect(s.error, isNull);
    expect(await images(s, 0), 2);
  });

  test('共享图片延迟应用，原图和镜像按当前页序独立预览', () async {
    final s = await load();
    final before = s.target!.bytes, preview = s.previewTarget;
    await collect(s, 0);
    await collect(s, 1);
    expect(s.target!.bytes, same(before));
    expect(s.previewTarget, same(preview));
    await s.mirrorSourcePage(page: 0, insertAt: 1);
    expect(s.source!.sourcePageOrigins, [0, 0, 1, 2]);
    expect(s.source!.mirrorPages, {1});
    expect(s.materials.map((m) => m.page), [1, 3]);
    expect(s.target!.bytes, same(before));
    await collect(s, 1);
    expect(s.imagesForPage(1), hasLength(1));
    await s.synchronize();
    expect(s.error, isNull);
    for (final page in [0, 1, 2]) {
      expect(await images(s, page), 1);
    }
    expect(s.previewTarget, same(preview));
    final applied = s.target!.bytes;
    await s.removeMaterial(s.imagesForPage(1).single);
    expect(s.target!.bytes, same(applied));
    await s.synchronize();
    expect(await images(s, 1), 0);
    final source = s.source!.bytes;
    await s.mirrorSourcePage(page: 99, insertAt: 0);
    expect(s.error, isNotNull);
    expect(s.source!.bytes, same(source));
  });

  test('旧页复制到右侧和新页自复制支持任意插入位置及未应用图层', () async {
    final s = await load();
    await collect(s, 0);
    await s.copyPageToTarget(fromOld: false, page: 0, insertAt: 2);
    expect(s.error, isNull);
    expect(s.target!.snapshot.pageCount, 4);
    expect(s.imagesForPage(2), hasLength(1));
    expect(s.imagesForPage(2).single.local, isFalse);
    await s.synchronize();
    expect(await images(s, 0), 1);
    expect(await images(s, 2), 1);
    final png = s.materials.first.png;
    await s.importLocalImage(
      png,
      '导入.png',
      1,
      const Rect.fromLTWH(.1, .1, .1, .1),
    );
    final before = s.target!.bytes;
    expect(s.needsSync, isTrue);
    expect(s.target!.bytes, same(before));
    await s.copyPageToTarget(fromOld: true, page: 2, insertAt: 0);
    expect(s.target!.snapshot.pageCount, 5);
    expect(s.materials.where((m) => m.source == '导入.png').single.targetPage, 2);
    await s.synchronize();
    expect(s.error, isNull);
    expect(await images(s, 2), 1);
    final bytes = s.target!.bytes;
    await s.copyPageToTarget(fromOld: true, page: 99, insertAt: 0);
    expect(s.error, isNotNull);
    expect(s.target!.bytes, same(bytes));
  });

  test('右侧删除只影响选中图片，背景预览不改PDF，应用后生效且可恢复', () async {
    final s = await load(imageTarget: true);
    final before = s.target!.bytes, preview = s.previewTarget;
    final first = s.previewTarget!.snapshot.objects.firstWhere(
      (o) => o.kind == PdfObjectKind.image,
    );
    s.deleteTargetImage(0, first);
    final png = await s.engine.previewBackground(s.previewTarget!.bytes, 0, [
      first,
    ]);
    expect(png, isNotEmpty);
    expect(s.target!.bytes, same(before));
    expect(s.previewTarget, same(preview));
    expect(s.needsSync, isTrue);
    await s.synchronize();
    expect(s.error, isNull);
    expect(await images(s, 0), 0);
    expect(await images(s, 1), 1);
    s.restoreDeletedImages(0);
    await s.synchronize();
    expect(await images(s, 0), 1);
    final nested = await s.engine.inspect(s.previewTarget!.bytes, 1);
    s.deleteTargetImage(
      1,
      nested.objects.firstWhere((o) => o.kind == PdfObjectKind.image),
    );
    await s.synchronize();
    expect(s.error, isNull);
    expect(await images(s, 1), 0);
  });

  test('缺页只提示，无对应页图片不写入，补页后可应用', () async {
    final s = await load();
    await s.mirrorSourcePage(page: 0, insertAt: 3);
    await collect(s, 3);
    expect(s.unmatchedImages, 1);
    await s.synchronize();
    expect(s.error, isNull);
    expect(s.target!.snapshot.pageCount, 3);
    await s.copyPageToTarget(fromOld: false, page: 0, insertAt: 3);
    expect(s.unmatchedImages, 0);
    await s.synchronize();
    expect(s.error, isNull);
    expect(await images(s, 3), 1);
  });
  test('右侧原图暂存后删除，跨页拖放保留旋转和尺寸，重复应用不叠图', () async {
    final s = await load(imageTarget: true);
    final before = s.target!.bytes, preview = s.previewTarget;
    for (final page in [0, 1, 2]) {
      final snap = await s.engine.inspect(s.previewTarget!.bytes, page);
      final object = snap.objects.firstWhere(
        (o) => o.kind == PdfObjectKind.image,
      );
      await s.stashTargetImage(page, object: object);
      expect(s.error, isNull);
    }
    expect(s.materials, hasLength(3));
    expect(s.materials.every((m) => m.staged && m.targetPage == -1), isTrue);
    expect(s.imagesForPage(0), isEmpty);
    expect(s.target!.bytes, same(before));
    expect(s.previewTarget, same(preview));
    await s.synchronize();
    expect(s.error, isNull);
    for (final page in [0, 1, 2]) {
      expect(await images(s, page), 0);
    }
    final staged = s.materials.last,
        basis = staged.basis!.toList(),
        old = staged.bounds!;
    s.placeStagedImage(staged, 0, const Offset(.5, .5));
    expect(staged.targetPage, 0);
    expect(staged.bounds!.center.dx, closeTo(.5, .001));
    final expectedX = (basis[1] - basis[0]).dx / old.width;
    expect(
      (staged.basis![1] - staged.basis![0]).dx / staged.bounds!.width,
      closeTo(expectedX, .001),
    );
    await s.synchronize();
    expect(s.error, isNull);
    expect(await images(s, 0), 1);
    await s.synchronize();
    expect(await images(s, 0), 1);
    s.placeStagedImage(staged, 1, const Offset(1, 1));
    expect(staged.bounds!.right, lessThanOrEqualTo(1.0));
    expect(staged.bounds!.bottom, lessThanOrEqualTo(1.0));
    await s.synchronize();
    expect(await images(s, 0), 0);
    expect(await images(s, 1), 1);
    await s.copyPageToTarget(fromOld: false, page: 0, insertAt: 0);
    expect(staged.targetPage, 2);
    expect(s.materials.where((m) => m.targetPage == -1), hasLength(2));
    await s.synchronize();
    expect(s.error, isNull);
    expect(await images(s, 2), 1);
  });

  test('暂存共享图层移除旧位置，重新拖入不会重复留在原页', () async {
    final s = await load();
    await collect(s, 0);
    final image = s.materials.single;
    await s.stashTargetImage(0, material: image);
    expect(s.materials, hasLength(1));
    expect(s.imagesForPage(0), isEmpty);
    expect(s.materials.single.staged, isTrue);
    s.placeStagedImage(s.materials.single, 1, const Offset(.5, .5));
    await s.synchronize();
    expect(s.error, isNull);
    expect(await images(s, 0), 0);
    expect(await images(s, 1), 1);
  });
}
