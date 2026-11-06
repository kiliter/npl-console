import 'support/pdfium_test_module.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdfrx/pdfrx.dart';
import 'package:npl_maintenance/core/pdf_editor/edit_session.dart';
import 'package:npl_maintenance/core/pdf_editor/page_kind.dart';
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

  group('渲染调度与文档缓存', () {
    late Uint8List fixture;
    setUpAll(
      () => fixture = File('test/fixtures/editor.pdf').readAsBytesSync(),
    );

    test('同一版本的多页预览与缩略图只打开一次文档，结果与逐页渲染一致', () async {
      final cached = PdfEditEngine();
      final count = (await cached.inspect(fixture, 0)).pageCount;
      expect(count, greaterThan(1));
      final pages = await Future.wait([
        for (var i = 0; i < count; i++) cached.inspect(fixture, i),
      ]);
      final thumbs = await Future.wait([
        for (var i = 0; i < count; i++) cached.thumbnail(fixture, i),
      ]);
      expect(cached.debugOpenCount, 1);
      for (var i = 0; i < count; i++) {
        final png = img.decodePng(pages[i].png)!;
        expect(png.width, greaterThan(500));
        expect(img.decodePng(thumbs[i])!.width, 100);
        expect(pages[i].pageCount, count);
      }
      // 新的字节版本单独打开；释放后再次渲染会重新打开。
      final copy = Uint8List.fromList(fixture);
      await cached.inspect(copy, 0);
      expect(cached.debugOpenCount, 2);
      await cached.releaseDocuments();
      await cached.inspect(copy, 0);
      expect(cached.debugOpenCount, 3);
      await cached.releaseDocuments();
    });

    test('缓存文档数量有界，最久未用的版本被淘汰', () async {
      final cached = PdfEditEngine();
      final revisions = [
        for (var i = 0; i <= PdfEditEngine.maxOpenDocuments; i++)
          Uint8List.fromList(fixture),
      ];
      for (final bytes in revisions) {
        await cached.thumbnail(bytes, 0);
      }
      expect(cached.debugOpenCount, revisions.length);
      // 最新的几个版本仍在缓存中，最早的版本已被淘汰需要重新打开。
      await cached.thumbnail(revisions.last, 0);
      expect(cached.debugOpenCount, revisions.length);
      await cached.thumbnail(revisions.first, 0);
      expect(cached.debugOpenCount, revisions.length + 1);
      await cached.releaseDocuments();
    });

    test('跳过的页面不发出任何原生调用，释放后已排队任务作废且不重新打开文档', () async {
      final cached = PdfEditEngine();
      await cached.inspect(fixture, 0);
      final native = cached.debugNativeCount;
      await expectLater(
        cached.inspect(fixture, 1, isNeeded: () => false),
        throwsA(isA<PdfRenderSkipped>()),
      );
      await expectLater(
        cached.pageKind(fixture, 1, isNeeded: () => false),
        throwsA(isA<PdfRenderSkipped>()),
      );
      expect(cached.debugNativeCount, native);
      // 先排一批低优先级任务，再释放：它们轮到时直接跳过。
      final queued = [
        for (var i = 0; i < 6; i++)
          cached
              .thumbnail(fixture, i % 3)
              .then<Object?>((v) => v, onError: (Object e) => e),
        for (var i = 0; i < 3; i++)
          cached
              .pageKind(fixture, i)
              .then<Object?>((v) => v, onError: (Object e) => e),
      ];
      await cached.releaseDocuments();
      final results = await Future.wait(queued);
      expect(results.whereType<PdfRenderSkipped>(), isNotEmpty);
      expect(cached.debugCachedDocuments, 0);
      // 释放后的新请求照常工作。
      expect(await cached.pageKind(fixture, 0), PdfPageKind.acceptance);
      await cached.releaseDocuments();
    });

    test('排队期间已不需要的页面跳过渲染，页面预览优先于缩略图', () async {
      final cached = PdfEditEngine();
      await cached.inspect(fixture, 0);
      await expectLater(
        cached.inspect(fixture, 1, isNeeded: () => false),
        throwsA(isA<PdfRenderSkipped>()),
      );
      // 同一帧内先发 8 张缩略图、后发页面预览：调度在微任务里才开始，
      // 轮到执行时按优先级取，页面预览排在全部缩略图之前。
      final order = <String>[];
      final thumbs = [
        for (var i = 0; i < 8; i++)
          cached.thumbnail(
            fixture,
            i % 3,
            isNeeded: () {
              order.add('缩略图');
              return true;
            },
          ),
      ];
      final page = cached.inspect(
        fixture,
        2,
        isNeeded: () {
          order.add('页面');
          return true;
        },
      );
      await Future.wait([...thumbs, page]);
      expect(order.first, '页面');
      expect(order, hasLength(9));
      await cached.releaseDocuments();
    });
  });

  group('页面类型识别', () {
    PdfEditObject text(String value, double top, {double height = .02}) =>
        PdfEditObject(
          const [0],
          PdfObjectKind.text,
          Rect.fromLTWH(.3, top, .4, height),
          text: value,
        );

    test('规则优先级：签字页 > 风险抄录页 > 业务受理单 > 地市协议页', () {
      expect(
        classifyPage(
          fullText: '本人已经阅读并理解以上\n业务受理单相关内容，同意办理以下业务：',
          objects: [text('业务受理单', .06)],
        ),
        PdfPageKind.signature,
      );
      expect(
        classifyPage(fullText: '本人同意所办理的业务采用电子协议模式。', objects: const []),
        PdfPageKind.signature,
      );
      expect(
        classifyPage(
          fullText: '反电信网络诈骗提示书 正文',
          objects: [for (final c in '反电信网络诈骗提示书'.split('')) text(c, .09)],
        ),
        PdfPageKind.riskTranscript,
      );
      expect(
        classifyPage(fullText: '业务 受理单', objects: [text('业务 受理单', .06)]),
        PdfPageKind.acceptance,
      );
      // 正文提到“业务受理单”但标题不是，属于协议页。
      expect(
        classifyPage(
          fullText: '甲方同意本《业务受理单》等相关协议',
          objects: [text('客户服务协议', .12), text('甲方同意本《业务受理单》', .3, height: .01)],
        ),
        PdfPageKind.cityAgreement,
      );
      expect(
        classifyPage(fullText: '', objects: const [], titleImageMatched: true),
        PdfPageKind.acceptance,
      );
      expect(
        classifyPage(fullText: '', objects: const []),
        PdfPageKind.cityAgreement,
      );
    });

    /// 渲染第 1 页标题区并转灰度。
    Future<({Uint8List gray, int width, int height})> band(
      Uint8List bytes,
      double scale,
    ) async {
      final doc = await PdfDocument.openData(bytes);
      try {
        final page = doc.pages.first;
        final fullWidth = page.width * scale,
            fullHeight = fullWidth * page.height / page.width;
        final rect = titleBandPixels(fullWidth.round(), fullHeight.round());
        final image = (await page.render(
          x: rect.x,
          y: rect.y,
          width: rect.width,
          height: rect.height,
          fullWidth: fullWidth,
          fullHeight: fullHeight,
          backgroundColor: 0xffffffff,
        ))!;
        try {
          return (
            gray: bgraToGray(image.pixels, image.width, image.height),
            width: image.width,
            height: image.height,
          );
        } finally {
          image.dispose();
        }
      } finally {
        await doc.dispose();
      }
    }

    /// 真实单据的标题是两张图片（“业务受”“理单”，只含标题字形），
    /// 按原位置贴到不含该标题的测试单据上，模拟图片标题。
    Future<Uint8List> imageTitle() async {
      var bytes = original;
      for (final (file, rect) in [
        (
          'acceptance_title_a.png',
          const Rect.fromLTRB(.4344, .0614, .5184, .0834),
        ),
        (
          'acceptance_title_b.png',
          const Rect.fromLTRB(.5149, .0615, .5718, .0833),
        ),
      ]) {
        bytes = await engine.insertImage(
          bytes,
          0,
          File('test/fixtures/$file').readAsBytesSync(),
          rect,
        );
      }
      return bytes;
    }

    test('标题是文字或图片都能识别为业务受理单，其他页面不误判', () async {
      final fixture = File('test/fixtures/editor.pdf').readAsBytesSync();
      expect(
        [for (var i = 0; i < 3; i++) await engine.pageKind(fixture, i)],
        [
          PdfPageKind.acceptance,
          PdfPageKind.cityAgreement,
          PdfPageKind.cityAgreement,
        ],
      );
      expect(await engine.pageKind(original, 0), PdfPageKind.cityAgreement);
      final pasted = await imageTitle();
      expect(await engine.pageKind(pasted, 0), PdfPageKind.acceptance);
      expect(await engine.pageKind(pasted, 1), PdfPageKind.cityAgreement);
    });

    test('标题区上方有横线、噪点，同一行远处有其他内容时仍能识别标题图片', () {
      final a = img.decodePng(
            File('test/fixtures/acceptance_title_a.png').readAsBytesSync(),
          )!,
          b = img.decodePng(
            File('test/fixtures/acceptance_title_b.png').readAsBytesSync(),
          )!;
      final canvas = img.Image(width: 900, height: 160)
        ..clear(img.ColorRgb8(255, 255, 255));
      // 页眉横线（2 像素高）与零星噪点。
      img.fillRect(
        canvas,
        x1: 0,
        y1: 4,
        x2: 899,
        y2: 5,
        color: img.ColorRgb8(0, 0, 0),
      );
      img.fillRect(
        canvas,
        x1: 40,
        y1: 14,
        x2: 42,
        y2: 16,
        color: img.ColorRgb8(0, 0, 0),
      );
      img.compositeImage(canvas, a, dstX: 300, dstY: 40);
      img.compositeImage(canvas, b, dstX: 300 + a.width - 6, dstY: 40);
      // 同一行右侧远处的流水号色块。
      img.fillRect(
        canvas,
        x1: 820,
        y1: 60,
        x2: 880,
        y2: 100,
        color: img.ColorRgb8(0, 0, 0),
      );
      final gray = bgraToGray(
        Uint8List.fromList(canvas.getBytes(order: img.ChannelOrder.bgra)),
        canvas.width,
        canvas.height,
      );
      expect(matchesAcceptanceTitle(gray, canvas.width, canvas.height), isTrue);
    });

    test('标题上方有单位名称小字、同一行有更高的二维码时仍能识别', () {
      final a = img.decodePng(
            File('test/fixtures/acceptance_title_a.png').readAsBytesSync(),
          )!,
          b = img.decodePng(
            File('test/fixtures/acceptance_title_b.png').readAsBytesSync(),
          )!;
      final canvas = img.Image(width: 900, height: 200)
        ..clear(img.ColorRgb8(255, 255, 255));
      // 标题上方一行 13 像素高的小字。
      for (var x = 300; x < 600; x += 16) {
        img.fillRect(
          canvas,
          x1: x,
          y1: 8,
          x2: x + 10,
          y2: 20,
          color: img.ColorRgb8(0, 0, 0),
        );
      }
      img.compositeImage(canvas, a, dstX: 300, dstY: 50);
      img.compositeImage(canvas, b, dstX: 300 + a.width - 6, dstY: 50);
      // 同一行右侧比标题更高的二维码色块。
      img.fillRect(
        canvas,
        x1: 780,
        y1: 30,
        x2: 880,
        y2: 180,
        color: img.ColorRgb8(0, 0, 0),
      );
      final gray = bgraToGray(
        Uint8List.fromList(canvas.getBytes(order: img.ChannelOrder.bgra)),
        canvas.width,
        canvas.height,
      );
      expect(matchesAcceptanceTitle(gray, canvas.width, canvas.height), isTrue);
    });

    test('预览渲染随附页面类型，与单独识别结果一致', () async {
      final fixture = File('test/fixtures/editor.pdf').readAsBytesSync();
      final cached = PdfEditEngine(), separate = PdfEditEngine();
      for (var i = 0; i < 3; i++) {
        // 另一个引擎、另一份字节：不命中预览带回的类型缓存，真正走单独识别路径。
        expect(
          (await cached.inspect(fixture, i)).kind,
          await separate.pageKind(Uint8List.fromList(fixture), i),
        );
      }
      await separate.releaseDocuments();
      // 预览过的页面直接读取快照，不再发起原生识别。
      final session = PdfEditSession(engine: cached);
      await session.load('NEW', fixture);
      final doc = session.target!;
      await doc.preview(cached, 1);
      final before = cached.debugNativeCount;
      expect(await doc.pageKind(cached, 0), PdfPageKind.acceptance);
      expect(await doc.pageKind(cached, 1), PdfPageKind.cityAgreement);
      expect(cached.debugNativeCount, before);
      session.dispose();
    });

    test('跨两行的高印章把上方小字与标题连成一段时，块内细分后仍能识别', () {
      final a = img.decodePng(
            File('test/fixtures/acceptance_title_a.png').readAsBytesSync(),
          )!,
          b = img.decodePng(
            File('test/fixtures/acceptance_title_b.png').readAsBytesSync(),
          )!;
      final canvas = img.Image(width: 900, height: 200)
        ..clear(img.ColorRgb8(255, 255, 255));
      for (var x = 300; x < 600; x += 16) {
        img.fillRect(
          canvas,
          x1: x,
          y1: 8,
          x2: x + 10,
          y2: 20,
          color: img.ColorRgb8(0, 0, 0),
        );
      }
      img.compositeImage(canvas, a, dstX: 300, dstY: 50);
      img.compositeImage(canvas, b, dstX: 300 + a.width - 6, dstY: 50);
      img.fillRect(
        canvas,
        x1: 780,
        y1: 5,
        x2: 880,
        y2: 180,
        color: img.ColorRgb8(0, 0, 0),
      );
      final gray = bgraToGray(
        Uint8List.fromList(canvas.getBytes(order: img.ChannelOrder.bgra)),
        canvas.width,
        canvas.height,
      );
      expect(matchesAcceptanceTitle(gray, canvas.width, canvas.height), isTrue);
    });

    test('释放文档时正在等预览的页面类型不回退识别，不重新加载旧文档', () async {
      final fixture = File('test/fixtures/editor.pdf').readAsBytesSync();
      final cached = PdfEditEngine();
      final session = PdfEditSession(engine: cached);
      await session.load('NEW', fixture);
      final doc = session.target!;
      final preview = doc.preview(cached, 1);
      final kind = doc.pageKind(cached, 1, isNeeded: () => true);
      final native = cached.debugNativeCount;
      final checks = Future.wait([
        expectLater(
          preview,
          throwsA(
            isA<PdfRenderSkipped>().having((e) => e.released, '释放', isTrue),
          ),
        ),
        expectLater(kind, throwsA(isA<PdfRenderSkipped>())),
      ]);
      await cached.releaseDocuments();
      await checks;
      expect(cached.debugNativeCount, native);
      expect(cached.debugCachedDocuments, 0);
      session.dispose();
    });

    test('页面类型与预览同页并发时只做一次原生调用，缩略图标签不阻止滚走页面跳过', () async {
      final fixture = File('test/fixtures/editor.pdf').readAsBytesSync();
      final cached = PdfEditEngine();
      final session = PdfEditSession(engine: cached);
      await session.load('NEW', fixture);
      final doc = session.target!;
      // 先识别再预览：识别轮到时预览已带回类型，跳过原生调用。
      final before = cached.debugNativeCount;
      final kind = doc.pageKind(cached, 1);
      final preview = doc.preview(cached, 1);
      expect((await preview).kind, PdfPageKind.cityAgreement);
      expect(await kind, PdfPageKind.cityAgreement);
      expect(cached.debugNativeCount, before + 1);
      // 页面组件已离开、只剩缩略图标签等待：预览照常跳过，标签回退到自己的识别。
      var pageVisible = true;
      final skipped = doc.preview(cached, 2, isNeeded: () => pageVisible);
      final badge = doc.pageKind(cached, 2, isNeeded: () => true);
      pageVisible = false;
      await expectLater(skipped, throwsA(isA<PdfRenderSkipped>()));
      expect(await badge, PdfPageKind.cityAgreement);
      session.dispose();
    });

    test('只有整行标题等于目标才命中，含“业务受理单”的其他标题不误判', () {
      PdfEditObject big(String value, double left) => PdfEditObject(
        const [0],
        PdfObjectKind.text,
        Rect.fromLTWH(left, .06, .05, .02),
        text: value,
      );
      expect(
        classifyPage(
          fullText: '',
          objects: [big('业务受理单', .3), big('补充协议', .5)],
        ),
        PdfPageKind.cityAgreement,
      );
      // 拆字排版、乱序输出的对象按左右位置还原成一行。
      expect(
        classifyPage(
          fullText: '',
          objects: [big('理单', .5), big('《业务受', .3), big('》', .6)],
        ),
        PdfPageKind.acceptance,
      );
      // 正文位置（页面中部）的大字不当作标题。
      expect(
        classifyPage(
          fullText: '',
          objects: [
            PdfEditObject(
              const [0],
              PdfObjectKind.text,
              const Rect.fromLTWH(.3, .5, .3, .02),
              text: '业务受理单',
            ),
          ],
        ),
        PdfPageKind.cityAgreement,
      );
    });

    test('标题字形比对不受渲染分辨率影响，空白与其他标题不命中', () async {
      final pasted = await imageTitle();
      for (final scale in [1.0, 1.8, 3.0]) {
        final title = await band(pasted, scale);
        expect(
          matchesAcceptanceTitle(title.gray, title.width, title.height),
          isTrue,
          reason: '渲染倍率 $scale',
        );
      }
      expect(
        matchesAcceptanceTitle(
          Uint8List(4000)..fillRange(0, 4000, 255),
          100,
          40,
        ),
        isFalse,
      );
      final other = await band(original, 1.8);
      expect(
        matchesAcceptanceTitle(other.gray, other.width, other.height),
        isFalse,
      );
    });
  });
}
