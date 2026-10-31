import 'support/pdfium_test_module.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdfrx/pdfrx.dart';
import 'package:npl_maintenance/core/pdf_editor/pdf_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final engine = PdfEditEngine();
  late Uint8List original;
  Uint8List picture(int r, int g, int b) {
    final image = img.Image(width: 40, height: 20, numChannels: 4);
    img.fill(image, color: img.ColorRgba8(r, g, b, 220));
    return Uint8List.fromList(img.encodePng(image));
  }

  setUpAll(() async {
    Pdfrx.pdfiumModulePath = pdfiumTestModule();
    await pdfrxInitialize();
    original = File('test/fixtures/reader.pdf').readAsBytesSync();
  });
  test(
    'real image insert, extract, replace, move, delete survive PDF reopening',
    () async {
      final bytes = await engine.insertImage(
        original,
        0,
        picture(255, 0, 0),
        const Rect.fromLTWH(.2, .3, .4, .15),
      );
      var page = await engine.inspect(bytes, 0);
      expect(
        page.objects.where((o) => o.kind == PdfObjectKind.text).single.text,
        'UI TEST PAGE 1',
      );
      final rendered = img.decodePng(page.png)!;
      final visible = rendered.getPixel(
        (rendered.width * .4).round(),
        (rendered.height * .375).round(),
      );
      expect(visible.r, greaterThan(230));
      expect(visible.b, lessThan(70));
      var image = page.objects.singleWhere(
        (o) => o.kind == PdfObjectKind.image,
      );
      expect(image.bounds.left, closeTo(.2, .002));
      expect(image.bounds.top, closeTo(.3, .002));
      final extracted = img.decodePng(
        await engine.extractImage(bytes, 0, image),
      )!;
      expect(extracted.getPixel(0, 0).r, greaterThan(240));
      expect(extracted.getPixel(0, 0).a, lessThan(250));
      final replaced = await engine.replaceImage(
        bytes,
        0,
        image,
        picture(0, 0, 255),
      );
      page = await engine.inspect(replaced, 0);
      image = page.objects.singleWhere((o) => o.kind == PdfObjectKind.image);
      final blue = img.decodePng(
        await engine.extractImage(replaced, 0, image),
      )!;
      expect(blue.getPixel(0, 0).b, greaterThan(240));
      final moved = await engine.moveImage(
        replaced,
        0,
        image,
        const Rect.fromLTWH(.1, .5, .6, .2),
      );
      page = await engine.inspect(moved, 0);
      image = page.objects.singleWhere((o) => o.kind == PdfObjectKind.image);
      expect(image.bounds.left, closeTo(.1, .002));
      expect(image.bounds.top, closeTo(.5, .002));
      expect(image.bounds.width, closeTo(.6, .002));
      final deleted = await engine.deleteImage(moved, 0, image);
      expect(
        (await engine.inspect(
          deleted,
          0,
        )).objects.where((o) => o.kind == PdfObjectKind.image),
        isEmpty,
      );
      expect(
        (await engine.inspect(
          original,
          0,
        )).objects.where((o) => o.kind == PdfObjectKind.image),
        isEmpty,
      );
    },
  );
  test(
    'Chinese replacement removes old text and keeps page text selectable',
    () async {
      final page = await engine.inspect(original, 0),
          font = File('assets/fonts/NotoSansSC-Regular.ttf').readAsBytesSync();
      final bytes = await engine.replaceText(
        original,
        0,
        page.objects.first,
        '新单据中文编辑 ABC 123',
        fontBytes: font,
        glyphs:
            (jsonDecode(
                      File(
                        'assets/fonts/NotoSansSC.cmap.json',
                      ).readAsStringSync(),
                    )
                    as Map<String, dynamic>)
                .map((k, v) => MapEntry(int.parse(k), v as int)),
      );
      final changed = await engine.inspect(bytes, 0);
      expect(
        changed.objects.where((o) => o.kind == PdfObjectKind.text).single.text,
        '新单据中文编辑 ABC 123',
      );
      expect(
        (await engine.inspect(bytes, 1)).objects.first.text,
        'UI TEST PAGE 2',
      );
    },
  );
  test(
    'copied page is independent of its source and original document',
    () async {
      final bytes = await engine.duplicatePage(original, 0);
      final copy = await engine.inspect(bytes, 1);
      expect(copy.pageCount, 4);
      expect(copy.objects.first.text, 'UI TEST PAGE 1');
      final withImage = await engine.insertImage(
        bytes,
        1,
        picture(0, 255, 0),
        const Rect.fromLTWH(.1, .3, .3, .2),
      );
      expect(
        (await engine.inspect(
          withImage,
          0,
        )).objects.where((o) => o.kind == PdfObjectKind.image),
        isEmpty,
      );
      expect(
        (await engine.inspect(
          withImage,
          1,
        )).objects.where((o) => o.kind == PdfObjectKind.image),
        hasLength(1),
      );
      expect((await engine.inspect(original, 0)).pageCount, 3);
    },
  );
  test(
    'image placement rejects invalid page coordinates without changing input',
    () async {
      expect(
        () => engine.insertImage(
          original,
          0,
          picture(0, 0, 0),
          const Rect.fromLTWH(.9, .9, .5, .5),
        ),
        throwsFormatException,
      );
      expect((await engine.inspect(original, 0)).pageCount, 3);
    },
  );
  test(
    'nested Form images can be extracted, replaced and repositioned',
    () async {
      final fixture = File('test/fixtures/editor.pdf').readAsBytesSync();
      var page = await engine.inspect(fixture, 1);
      var object = page.objects.firstWhere(
        (o) => o.kind == PdfObjectKind.image,
      );
      expect(object.nested, isTrue);
      expect(
        img.decodePng(await engine.extractImage(fixture, 1, object)),
        isNotNull,
      );
      final changed = await engine.replaceImage(
        fixture,
        1,
        object,
        picture(255, 0, 0),
      );
      page = await engine.inspect(changed, 1);
      object = page.objects.firstWhere((o) => o.kind == PdfObjectKind.image);
      expect(
        img
            .decodePng(await engine.extractImage(changed, 1, object))!
            .getPixel(0, 0)
            .r,
        greaterThan(240),
      );
      expect(
        () => engine.moveImage(
          changed,
          1,
          object,
          const Rect.fromLTWH(.2, .2, .4, .2),
        ),
        throwsFormatException,
      );
    },
  );
  test('rotated page image placement uses displayed coordinates', () async {
    final fixture = File('test/fixtures/editor.pdf').readAsBytesSync();
    final changed = await engine.insertImage(
      fixture,
      2,
      picture(255, 0, 0),
      const Rect.fromLTWH(.1, .1, .3, .2),
    );
    final object = (await engine.inspect(
      changed,
      2,
    )).objects.where((o) => o.kind == PdfObjectKind.image).last;
    expect(object.bounds.left, closeTo(.1, .002));
    expect(object.bounds.top, closeTo(.1, .002));
    final moved = await engine.moveImage(
      changed,
      2,
      object,
      const Rect.fromLTWH(.5, .4, .3, .2),
    );
    final again = (await engine.inspect(
      moved,
      2,
    )).objects.where((o) => o.kind == PdfObjectKind.image).last;
    expect(again.bounds.left, closeTo(.5, .002));
    expect(again.bounds.top, closeTo(.4, .002));
  });
  test('批量跨页修复保留页码和坐标，匹配旧图直接替换且保留文字', () async {
    final source = File('test/fixtures/editor.pdf').readAsBytesSync();
    final placements = <PdfImagePlacement>[];
    for (var index = 0; index < 3; index++) {
      final page = await engine.inspect(source, index);
      for (final object in page.objects.where(
        (o) => o.kind == PdfObjectKind.image,
      )) {
        placements.add(
          PdfImagePlacement(
            await engine.extractImage(source, index, object),
            index,
            object.bounds,
            page.size,
            basis: object.basis,
          ),
        );
      }
    }
    expect(placements.map((p) => p.page).toSet(), {0, 1, 2});
    final repaired = await engine.synchronizeImages(source, placements);
    final twice = await engine.synchronizeImages(repaired, placements);
    for (var index = 0; index < 3; index++) {
      final before = await engine.inspect(source, index),
          after = await engine.inspect(twice, index);
      final beforeImages = before.objects
          .where((o) => o.kind == PdfObjectKind.image)
          .toList();
      final afterImages = after.objects
          .where((o) => o.kind == PdfObjectKind.image)
          .toList();
      expect(afterImages.length, beforeImages.length);
      for (var i = 0; i < beforeImages.length; i++) {
        expect(
          afterImages[i].bounds.left,
          closeTo(beforeImages[i].bounds.left, .002),
        );
        expect(
          afterImages[i].bounds.top,
          closeTo(beforeImages[i].bounds.top, .002),
        );
        expect(
          afterImages[i].bounds.width,
          closeTo(beforeImages[i].bounds.width, .002),
        );
        expect(
          afterImages[i].bounds.height,
          closeTo(beforeImages[i].bounds.height, .002),
        );
        for (var j = 0; j < 3; j++) {
          expect(
            (afterImages[i].basis![j] - beforeImages[i].basis![j]).distance,
            lessThan(.002),
          );
        }
      }
      expect(
        after.objects
            .where((o) => o.kind == PdfObjectKind.text)
            .map((o) => o.text),
        before.objects
            .where((o) => o.kind == PdfObjectKind.text)
            .map((o) => o.text),
      );
    }
  });
  test('缺少目标页整批失败；新单据无图时在指定页插入', () async {
    final png = picture(0, 200, 0), page = await engine.inspect(original, 0);
    final first = PdfImagePlacement(
      png,
      0,
      const Rect.fromLTWH(.2, .3, .2, .1),
      page.size,
    );
    await expectLater(
      engine.synchronizeImages(original, [
        first,
        PdfImagePlacement(png, 99, first.bounds, page.size),
      ]),
      throwsFormatException,
    );
    expect(
      (await engine.inspect(
        original,
        0,
      )).objects.where((o) => o.kind == PdfObjectKind.image),
      isEmpty,
    );
    final repaired = await engine.synchronizeImages(original, [
      first,
      PdfImagePlacement(png, 2, const Rect.fromLTWH(.4, .5, .2, .1), page.size),
    ]);
    expect(
      (await engine.inspect(
        repaired,
        0,
      )).objects.where((o) => o.kind == PdfObjectKind.image),
      hasLength(1),
    );
    expect(
      (await engine.inspect(
        repaired,
        1,
      )).objects.where((o) => o.kind == PdfObjectKind.image),
      isEmpty,
    );
    final last = (await engine.inspect(
      repaired,
      2,
    )).objects.singleWhere((o) => o.kind == PdfObjectKind.image);
    expect(last.bounds.top, closeTo(.5, .002));
  });
}
