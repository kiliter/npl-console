import 'dart:math' as math;
import 'dart:ui';

import '../pdf_editor/pdf_engine.dart';

/// 签字区、抄录区、证件格的位置，取自模板 PDF 的表单字段（左上角原点，单位 pt）：
/// 爱知签字页模板 currency_agree_23.pdf（Signature2、4 个 0_99），
/// 风险抄录模板 copy_agree_new.pdf（copySign、Signature2）。按页面尺寸等比换算。
class RepairTemplates {
  static const signSize = Size(595.22, 842.0);
  static const signSignature = Rect.fromLTRB(161.32, 733.71, 341.47, 838.50);
  static const signSlots = [
    Rect.fromLTRB(66.76, 143.13, 319.33, 400.10), // 左上
    Rect.fromLTRB(325.02, 142.54, 577.59, 400.30), // 右上
    Rect.fromLTRB(66.28, 405.14, 318.85, 662.12), // 左下
    Rect.fromLTRB(324.54, 403.47, 577.11, 662.31), // 右下
  ];
  static const riskSize = Size(595.30, 841.90);
  static const riskCopySign = Rect.fromLTRB(152.92, 584.06, 199.17, 609.51);
  static const riskSignature = Rect.fromLTRB(152.92, 696.07, 287.14, 790.82);

  /// 模板区域换算到页面归一化坐标。
  static Rect normalize(Rect r, Size template) => Rect.fromLTRB(
    r.left / template.width,
    r.top / template.height,
    r.right / template.width,
    r.bottom / template.height,
  );
}

enum RepairElement {
  signature('签字图片'),
  copySign('抄录签字图片'),
  citySign('协议签字图片'),
  idSlot1('证件图片（左上）'),
  idSlot2('证件图片（右上）'),
  idSlot3('证件图片（左下）'),
  idSlot4('证件图片（右下）'),
  idSlot('证件图片');

  const RepairElement(this.label);
  final String label;
  static RepairElement slot(int n) =>
      values[RepairElement.idSlot1.index + n - 1];
}

/// 一份单据的分析结果。
class RepairDocument {
  final String caseNo;
  final String opTime;
  final List<RepairPageInfo> pages;
  const RepairDocument(this.caseNo, this.opTime, this.pages);
  Iterable<RepairPageInfo> kinds(PdfPageKind kind) =>
      pages.where((p) => p.kind == kind);
}

/// 一张要放进最新单据的图片：来源单据（历史单据下标）、来源页、对象路径，
/// 目标页上的归一化位置与方向。
class RepairPlacement {
  final int history;
  final int sourcePage;
  final List<int> path;
  final Rect sourceBounds;
  final Rect target;
  final List<Offset>? basis;
  const RepairPlacement({
    required this.history,
    required this.sourcePage,
    required this.path,
    required this.sourceBounds,
    required this.target,
    this.basis,
  });
}

class RepairItem {
  final String id;
  final int page;
  final PdfPageKind pageKind;
  final RepairElement element;
  final bool fixable;
  final String message;
  final String sourceCase;
  final int sourcePage;
  final List<RepairPlacement> placements;

  /// 目标页上的检查区域（归一化）；地市协议页没有固定区域。
  final Rect? region;
  const RepairItem({
    required this.id,
    required this.page,
    required this.pageKind,
    required this.element,
    required this.fixable,
    required this.message,
    this.sourceCase = '',
    this.sourcePage = -1,
    this.placements = const [],
    this.region,
  });
}

double _area(Rect r) => r.isEmpty ? 0 : r.width * r.height;

/// 图片有一半以上面积落在区域内。
bool _inside(RepairImageInfo image, Rect region) {
  final area = _area(image.bounds);
  if (area <= 0) return false;
  final cross = image.bounds.intersect(region);
  return cross.width > 0 && cross.height > 0 && _area(cross) / area >= .5;
}

List<RepairImageInfo> _filled(List<RepairImageInfo> images, Rect region) => [
  for (final i in images)
    if (!i.blank && _inside(i, region)) i,
];

/// 同一位置、同一张图只保留一份（单据里签名常被重复绘制）。
List<RepairImageInfo> _dedupe(List<RepairImageInfo> images) {
  final seen = <String>{}, out = <RepairImageInfo>[];
  for (final i in images) {
    final b = i.bounds;
    final key = [
      for (final v in [b.left, b.top, b.right, b.bottom]) (v * 2000).round(),
      i.thumb.fold<int>(0, (h, v) => (h * 31 + (v >> 3)) & 0x3fffffff),
    ].join(',');
    if (seen.add(key)) out.add(i);
  }
  return out;
}

/// 宽高比一致、缩略像素平均差不超过 6，视为同一张图（允许重新编码）。
bool samePicture(RepairImageInfo a, RepairImageInfo b) {
  if (a.blank || b.blank || a.pixelWidth == 0 || b.pixelWidth == 0) {
    return false;
  }
  final ra = a.pixelWidth / a.pixelHeight, rb = b.pixelWidth / b.pixelHeight;
  if ((ra - rb).abs() > .03 * ra) return false;
  var diff = 0;
  for (var i = 0; i < 256; i++) {
    diff += (a.thumb[i] - b.thumb[i]).abs();
  }
  return diff / 256 <= 6;
}

final _noise = RegExp(r'[\s0-9０-９]+');

/// 两页正文的相似度：去掉空白和数字后按字符三元组算 Dice 系数（0～1）。
double textSimilarity(String a, String b) {
  a = a.replaceAll(_noise, '');
  b = b.replaceAll(_noise, '');
  if (a.isEmpty || b.isEmpty) return 0;
  final la = a.length, lb = b.length;
  if (math.min(la, lb) / math.max(la, lb) < .8) return 0;
  Map<String, int> grams(String s) {
    final out = <String, int>{};
    for (var i = 0; i + 3 <= s.length; i++) {
      final g = s.substring(i, i + 3);
      out[g] = (out[g] ?? 0) + 1;
    }
    return out;
  }

  final ga = grams(a), gb = grams(b);
  var both = 0, total = 0;
  ga.forEach((g, n) {
    both += math.min(n, gb[g] ?? 0);
    total += n;
  });
  gb.forEach((_, n) => total += n);
  return total == 0 ? 0 : 2 * both / total;
}

/// 分析最新单据缺什么、从历史单据（从新到旧）哪里取。
List<RepairItem> analyzeRepair(
  RepairDocument target,
  List<RepairDocument> history,
) {
  final items = <RepairItem>[];
  var counter = 0;
  String nextId() => 'r${++counter}';

  Rect signRegion(RepairPageInfo page) => RepairTemplates.normalize(
    RepairTemplates.signSignature,
    RepairTemplates.signSize,
  );
  List<Rect> slotRegions(RepairPageInfo page) => [
    for (final s in RepairTemplates.signSlots)
      RepairTemplates.normalize(s, RepairTemplates.signSize),
  ];
  List<List<RepairImageInfo>> slotsOf(RepairPageInfo page) => [
    for (final r in slotRegions(page)) _filled(page.images, r),
  ];

  ({RepairPageInfo? page, bool shared, String reason}) matchSign(
    RepairPageInfo page,
    RepairDocument doc,
  ) {
    final ids = slotsOf(page).expand((s) => s).toList();
    RepairPageInfo? best;
    var bestShared = 0;
    for (final candidate in doc.kinds(PdfPageKind.signature)) {
      final theirs = slotsOf(candidate).expand((s) => s).toList();
      final shared = ids
          .where((a) => theirs.any((b) => samePicture(a, b)))
          .length;
      if (shared > bestShared) {
        best = candidate;
        bestShared = shared;
      }
    }
    if (best != null) {
      return (page: best, shared: true, reason: '共享 $bestShared 张证件图片');
    }
    final mine = target.kinds(PdfPageKind.signature).toList();
    final theirs = doc.kinds(PdfPageKind.signature).toList();
    if (mine.length == theirs.length && theirs.isNotEmpty) {
      final candidate = theirs[mine.indexOf(page)];
      if (textSimilarity(page.text, candidate.text) >= .9) {
        return (page: candidate, shared: false, reason: '签字页数量一致，按顺序对应');
      }
    }
    return (page: null, shared: false, reason: '');
  }

  /// 来源位置换算到目标页：保持左上角起的 pt 偏移和 pt 尺寸（同一模板）。
  Rect sameSpot(Rect source, Size from, Size to) => Rect.fromLTWH(
    source.left * from.width / to.width,
    source.top * from.height / to.height,
    source.width * from.width / to.width,
    source.height * from.height / to.height,
  );

  RepairPlacement place(
    int h,
    RepairPageInfo from,
    RepairImageInfo image,
    RepairPageInfo to, {
    Rect? srcRegion,
    Rect? dstRegion,
  }) {
    // 默认原位；给出区域时按区域间的比例平移缩放（证件补到另一格）。
    Offset map(Offset p) {
      final pt = Offset(p.dx * from.size.width, p.dy * from.size.height);
      if (srcRegion == null || dstRegion == null) {
        return Offset(pt.dx / to.size.width, pt.dy / to.size.height);
      }
      final s = Rect.fromLTRB(
        srcRegion.left * from.size.width,
        srcRegion.top * from.size.height,
        srcRegion.right * from.size.width,
        srcRegion.bottom * from.size.height,
      );
      final d = Rect.fromLTRB(
        dstRegion.left * to.size.width,
        dstRegion.top * to.size.height,
        dstRegion.right * to.size.width,
        dstRegion.bottom * to.size.height,
      );
      final x = d.left + (pt.dx - s.left) * d.width / s.width;
      final y = d.top + (pt.dy - s.top) * d.height / s.height;
      return Offset(x / to.size.width, y / to.size.height);
    }

    final b = image.bounds;
    final target = srcRegion == null
        ? sameSpot(b, from.size, to.size)
        : Rect.fromPoints(map(b.topLeft), map(b.bottomRight));
    return RepairPlacement(
      history: h,
      sourcePage: from.index,
      path: image.path,
      sourceBounds: b,
      target: target,
      basis: image.basis?.map(map).toList(),
    );
  }

  // ---- 爱知签字页 ----
  final present = [
    for (final p in target.kinds(PdfPageKind.signature))
      ...slotsOf(p).expand((s) => s),
  ];
  for (final page in target.kinds(PdfPageKind.signature)) {
    final signature = signRegion(page), slots = slotRegions(page);
    if (_filled(page.images, signature).isEmpty) {
      RepairItem? found;
      for (var h = 0; h < history.length && found == null; h++) {
        final doc = history[h];
        final matched = matchSign(page, doc).page;
        final ordered = [
          ?matched,
          ...doc.kinds(PdfPageKind.signature).where((p) => p != matched),
        ];
        for (final candidate in ordered) {
          final images = _dedupe(
            _filled(candidate.images, signRegion(candidate)),
          );
          if (images.isEmpty) continue;
          found = RepairItem(
            id: nextId(),
            page: page.index,
            pageKind: PdfPageKind.signature,
            element: RepairElement.signature,
            fixable: true,
            message:
                '签字区没有签字图片，从历史单据 ${doc.caseNo} 第 ${candidate.index + 1} 页复制',
            sourceCase: doc.caseNo,
            sourcePage: candidate.index,
            placements: [for (final i in images) place(h, candidate, i, page)],
            region: signature,
          );
          break;
        }
      }
      items.add(
        found ??
            RepairItem(
              id: nextId(),
              page: page.index,
              pageKind: PdfPageKind.signature,
              element: RepairElement.signature,
              fixable: false,
              message: '签字区没有签字图片，近三个月历史单据的签字页中也没有可用签字',
              region: signature,
            ),
      );
    }
    // 证件格：与历史签字页共享证件图片，且最新页的证件都在历史页中、历史页更多时，
    // 历史页多出的（最新单据任何签字页上都没有的）证件按顺序补进空格。
    final mine = slotsOf(page);
    for (var h = 0; h < history.length; h++) {
      final doc = history[h];
      final match = matchSign(page, doc);
      final matched = match.page;
      if (matched == null || !match.shared) continue;
      final myIds = mine.expand((s) => s).toList();
      final theirSlots = slotsOf(matched);
      final theirIds = theirSlots.expand((s) => s).toList();
      if (myIds.isEmpty ||
          theirIds.length <= myIds.length ||
          !myIds.every((a) => theirIds.any((b) => samePicture(a, b)))) {
        continue;
      }
      final missing = <(int, List<RepairImageInfo>)>[];
      for (var n = 0; n < 4; n++) {
        final old = _dedupe(
          theirSlots[n],
        ).where((i) => !present.any((p) => samePicture(i, p))).toList();
        if (old.isNotEmpty) missing.add((n, old));
      }
      final empty = [
        for (var n = 0; n < 4; n++)
          if (mine[n].isEmpty) n,
      ];
      final theirRegions = slotRegions(matched);
      for (var k = 0; k < math.min(missing.length, empty.length); k++) {
        final (from, old) = missing[k];
        final to = empty[k];
        // 补进来的证件计入“已有”，另一张签字页对上同一历史页时不再重复补。
        present.addAll(old);
        items.add(
          RepairItem(
            id: nextId(),
            page: page.index,
            pageKind: PdfPageKind.signature,
            element: RepairElement.slot(to + 1),
            fixable: true,
            message:
                '证件格 ${to + 1} 为空：历史单据 ${doc.caseNo} 第 ${matched.index + 1} 页（${match.reason}）'
                '${from == to ? '同一位置' : '第 ${from + 1} 格'}的证件图片在最新单据中没有，补到这一格',
            sourceCase: doc.caseNo,
            sourcePage: matched.index,
            placements: [
              for (final i in old)
                place(
                  h,
                  matched,
                  i,
                  page,
                  srcRegion: theirRegions[from],
                  dstRegion: slots[to],
                ),
            ],
            region: slots[to],
          ),
        );
      }
      if (missing.length > empty.length) {
        items.add(
          RepairItem(
            id: nextId(),
            page: page.index,
            pageKind: PdfPageKind.signature,
            element: RepairElement.idSlot,
            fixable: false,
            message:
                '历史单据 ${doc.caseNo} 还有 ${missing.length - empty.length} 张证件图片，最新签字页没有空格可放',
          ),
        );
      }
      break;
    }
  }

  // ---- 风险抄录页 ----
  for (final page in target.kinds(PdfPageKind.riskTranscript)) {
    for (final (element, rect, label) in [
      (RepairElement.copySign, RepairTemplates.riskCopySign, '抄录区'),
      (RepairElement.signature, RepairTemplates.riskSignature, '签字区'),
    ]) {
      final region = RepairTemplates.normalize(rect, RepairTemplates.riskSize);
      if (_filled(page.images, region).isNotEmpty) continue;
      RepairItem? found;
      outer:
      for (var h = 0; h < history.length; h++) {
        for (final candidate in history[h].kinds(PdfPageKind.riskTranscript)) {
          final images = _dedupe(_filled(candidate.images, region));
          if (images.isEmpty) continue;
          found = RepairItem(
            id: nextId(),
            page: page.index,
            pageKind: PdfPageKind.riskTranscript,
            element: element,
            fixable: true,
            message:
                '$label没有图片，从历史单据 ${history[h].caseNo} 第 ${candidate.index + 1} 页复制',
            sourceCase: history[h].caseNo,
            sourcePage: candidate.index,
            placements: [for (final i in images) place(h, candidate, i, page)],
            region: region,
          );
          break outer;
        }
      }
      items.add(
        found ??
            RepairItem(
              id: nextId(),
              page: page.index,
              pageKind: PdfPageKind.riskTranscript,
              element: element,
              fixable: false,
              message: '$label没有图片，近三个月历史单据的风险抄录页中也没有可用图片',
              region: region,
            ),
      );
    }
  }

  // ---- 地市协议页：与正文相同的历史协议页比对，同一位置缺的图片补上 ----
  for (final page in target.kinds(PdfPageKind.cityAgreement)) {
    final mine = page.images.where((i) => !i.blank).toList();
    for (var h = 0; h < history.length; h++) {
      RepairPageInfo? matched;
      var score = 0.0;
      for (final candidate in history[h].kinds(PdfPageKind.cityAgreement)) {
        final s = textSimilarity(page.text, candidate.text);
        if (s > score) {
          score = s;
          matched = candidate;
        }
      }
      if (matched == null || score < .9) continue;
      final pageArea = matched.size.width * matched.size.height;
      final extra = <RepairImageInfo>[];
      for (final image in matched.images) {
        if (image.blank || _area(image.bounds) * pageArea < 80) continue;
        if (image.bounds.bottom < .045) continue; // 页眉 Logo
        final spot = sameSpot(image.bounds, matched.size, page.size);
        final overlaps = mine.any((o) {
          final cross = spot.intersect(o.bounds);
          return cross.width > 0 &&
              cross.height > 0 &&
              _area(cross) > .3 * math.min(_area(spot), _area(o.bounds));
        });
        if (!overlaps && !mine.any((o) => samePicture(image, o))) {
          extra.add(image);
        }
      }
      final unique = _dedupe(extra);
      if (unique.isNotEmpty) {
        items.add(
          RepairItem(
            id: nextId(),
            page: page.index,
            pageKind: PdfPageKind.cityAgreement,
            element: RepairElement.citySign,
            fixable: true,
            message:
                '历史单据 ${history[h].caseNo} 第 ${matched.index + 1} 页同一协议有 ${unique.length} 处签字图片，最新单据缺失',
            sourceCase: history[h].caseNo,
            sourcePage: matched.index,
            placements: [for (final i in unique) place(h, matched, i, page)],
          ),
        );
      }
      break; // 只和最近一份能对上的历史单据比较
    }
  }
  int order(RepairItem i) => int.parse(i.id.substring(1));
  items.sort(
    (a, b) => a.page != b.page
        ? a.page.compareTo(b.page)
        : order(a).compareTo(order(b)),
  );
  return items;
}
