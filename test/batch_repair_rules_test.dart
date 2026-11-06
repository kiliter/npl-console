import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:npl_maintenance/core/batch_repair/batch_repair.dart';
import 'package:npl_maintenance/core/batch_repair/repair_rules.dart';
import 'package:npl_maintenance/core/pdf_editor/pdf_engine.dart';

const _a4 = Size(595.22, 842);

/// 每个“图片编号”生成一张独特的 16×16 缩略图；同编号视为同一张图。
RepairImageInfo image(
  int picture,
  Rect pt, {
  bool blank = false,
  int w = 400,
  int h = 300,
  List<int>? path,
}) {
  final thumb = Uint8List(256);
  for (var i = 0; i < 256; i++) {
    thumb[i] = blank ? 255 : (picture * 37 + i * (picture + 3)) % 200;
  }
  return RepairImageInfo(
    path ?? [picture],
    Rect.fromLTRB(
      pt.left / _a4.width,
      pt.top / _a4.height,
      pt.right / _a4.width,
      pt.bottom / _a4.height,
    ),
    null,
    w,
    h,
    thumb,
    blank,
  );
}

RepairPageInfo page(
  int index,
  PdfPageKind kind,
  List<RepairImageInfo> images, {
  String text = '',
}) => RepairPageInfo(index, kind, _a4, text, images);

/// 签字区与证件格的典型位置（取自模板）。
const signArea = Rect.fromLTRB(161.3, 751.3, 248.7, 794.9);
const slots = [
  Rect.fromLTRB(116.6, 168.8, 269.5, 374.4),
  Rect.fromLTRB(370.2, 168.3, 532.4, 374.5),
  Rect.fromLTRB(111.7, 430.8, 273.4, 636.4),
  Rect.fromLTRB(378.3, 429.4, 523.4, 636.4),
];
const riskSign = Rect.fromLTRB(152.9, 696.1, 247.9, 743.5);
const riskCopy = Rect.fromLTRB(152.9, 585.2, 199.2, 608.3);
final agreement = '甲方签名或单位盖章乙方中国移动通信集团江苏有限公司本协议经双方签字盖章后生效' * 4;

void main() {
  test('签字页缺签字：从历史单据同一张签字页复制，位置与历史一致', () {
    final target = RepairDocument('NEW', '', [
      page(0, PdfPageKind.acceptance, []),
      page(1, PdfPageKind.signature, [
        image(10, slots[0]),
        image(11, slots[1]),
      ]),
    ]);
    final history = RepairDocument('OLD', '', [
      page(0, PdfPageKind.acceptance, []),
      page(1, PdfPageKind.signature, [
        image(10, slots[0]),
        image(11, slots[1]),
        image(99, signArea),
      ]),
    ]);
    final items = analyzeRepair(target, [history]);
    expect(items, hasLength(1));
    final item = items.single;
    expect(item.element, RepairElement.signature);
    expect(item.fixable, isTrue);
    expect(item.sourceCase, 'OLD');
    expect(
      item.placements.single.target.top * _a4.height,
      closeTo(signArea.top, .01),
    );
  });

  test('签字区已有签字、没有历史单据时不报缺失；缺签字又无历史时标为无法补齐', () {
    final signed = RepairDocument('NEW', '', [
      page(0, PdfPageKind.signature, [image(99, signArea)]),
    ]);
    expect(analyzeRepair(signed, []), isEmpty);
    final unsigned = RepairDocument('NEW', '', [
      page(0, PdfPageKind.signature, [image(10, slots[0])]),
    ]);
    final items = analyzeRepair(unsigned, []);
    expect(items.single.fixable, isFalse);
  });

  test('空白占位图不算签字', () {
    final target = RepairDocument('NEW', '', [
      page(0, PdfPageKind.signature, [image(1, signArea, blank: true)]),
    ]);
    expect(analyzeRepair(target, []).single.element, RepairElement.signature);
  });

  test('证件格：历史页多出、最新单据里没有的证件补进空格；只是换了位置的不算缺失', () {
    final target = RepairDocument('NEW', '', [
      page(0, PdfPageKind.signature, [
        image(10, slots[0]),
        image(99, signArea),
      ]),
      page(1, PdfPageKind.signature, [
        image(12, slots[0]),
        image(99, signArea),
      ]),
    ]);
    final history = RepairDocument('OLD', '', [
      // 历史页：10 共享；11 最新单据没有 → 补；12 在最新单据另一页上 → 不补。
      page(0, PdfPageKind.signature, [
        image(10, slots[0]),
        image(11, slots[3]),
        image(12, slots[2]),
        image(99, signArea),
      ]),
    ]);
    final items = analyzeRepair(target, [history]);
    expect(items, hasLength(1));
    final item = items.single;
    expect(item.element, RepairElement.idSlot2); // 第一个空格
    // 从右下格平移到右上格。
    final placed = item.placements.single.target;
    expect(placed.left * _a4.width, greaterThan(325));
    expect(placed.top * _a4.height, lessThan(400));
  });

  test('证件格：最新页的证件不全在历史页里（换了证件），不判缺失', () {
    final target = RepairDocument('NEW', '', [
      page(0, PdfPageKind.signature, [
        image(10, slots[0]),
        image(20, slots[1]),
        image(99, signArea),
      ]),
    ]);
    final history = RepairDocument('OLD', '', [
      page(0, PdfPageKind.signature, [
        image(10, slots[0]),
        image(11, slots[1]),
        image(12, slots[2]),
        image(99, signArea),
      ]),
    ]);
    expect(analyzeRepair(target, [history]), isEmpty);
  });

  test('风险抄录页：抄录区和签字区分别判断', () {
    final target = RepairDocument('NEW', '', [
      page(0, PdfPageKind.riskTranscript, [image(5, riskCopy)]),
    ]);
    final history = RepairDocument('OLD', '', [
      page(0, PdfPageKind.riskTranscript, [
        image(5, riskCopy),
        image(6, riskSign),
      ]),
    ]);
    final items = analyzeRepair(target, [history]);
    expect(items.single.element, RepairElement.signature);
    expect(items.single.pageKind, PdfPageKind.riskTranscript);
  });

  test('地市协议页：正文相同的历史协议页上有、最新页同位置没有的签字补上；页眉 Logo 忽略', () {
    const logo = Rect.fromLTRB(65, 2, 190, 32);
    const sign = Rect.fromLTRB(194.7, 254.4, 258.0, 286.0);
    final target = RepairDocument('NEW', '', [
      page(0, PdfPageKind.cityAgreement, [image(1, logo)], text: agreement),
    ]);
    final history = RepairDocument('OLD', '', [
      page(0, PdfPageKind.cityAgreement, [
        image(2, logo),
        image(7, sign),
      ], text: '$agreement 2026 10 21'),
    ]);
    final items = analyzeRepair(target, [history]);
    expect(items.single.element, RepairElement.citySign);
    expect(items.single.placements, hasLength(1));
    // 正文不同的协议不比对。
    final other = RepairDocument('OLD', '', [
      page(0, PdfPageKind.cityAgreement, [
        image(7, sign),
      ], text: '完全不同的另一份协议条款内容' * 8),
    ]);
    expect(analyzeRepair(target, [other]), isEmpty);
  });

  test('业务受理单页面不检查', () {
    final target = RepairDocument('NEW', '', [
      page(0, PdfPageKind.acceptance, []),
    ]);
    expect(analyzeRepair(target, []), isEmpty);
  });

  test('正文相似度：去掉数字与空白后比较', () {
    expect(
      textSimilarity('$agreement 2026年10月', '$agreement 2025年1月'),
      greaterThan(.95),
    );
    expect(textSimilarity(agreement, '另一份协议' * 20), lessThan(.5));
  });

  test('订单号识别：2 开头 18 位，去重，忽略更长的数字', () {
    expect(
      extractOrderNumbers(
        '200664218695020220,200664218695020220 1200664218695020220 200664217227727232',
      ),
      ['200664218695020220', '200664217227727232'],
    );
    expect(orderNumberPattern.hasMatch('986670036133367808'), isFalse);
    expect(recentMonths(3, DateTime(2026, 1, 15)), [
      '202511',
      '202512',
      '202601',
    ]);
  });
}
