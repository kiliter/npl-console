import 'dart:math' as math;
import 'dart:typed_data';
import 'pdf_engine.dart';

/// 单据页面类型。
enum PdfPageKind {
  acceptance('业务受理单', '受理'),
  signature('爱知签字页', '签字'),
  riskTranscript('风险抄录页', '抄录'),
  cityAgreement('地市协议页', '协议');

  const PdfPageKind(this.label, this.short);
  final String label;

  /// 缩略图下方的短标签。
  final String short;
}

/// 标题区域：页面顶部（排除页眉横线和页码）。归一化坐标，原点在左上。
const pageTitleBand = (left: .25, top: .05, right: .80, bottom: .16);

/// 识别标题时认为是“大号字”的最小字高（占页面高度的比例）。
/// 正文约 0.010～0.013，标题约 0.017～0.025。
const _headingHeight = .015;

/// 标题文字的纵向范围：页眉（页码、受理日期）之下、正文之前。
/// 与图片标题区同一范围，再向下放宽，容纳“反电信网络诈骗提示书”这类在页眉 Logo
/// 下方的标题（实测约 0.09）。
const _headingTop = .03, _headingBottom = .2;

String _compact(String text) => text.replaceAll(RegExp(r'\s+'), '');

/// 去掉空白和常见标点后比较标题，排版拆字、书名号不影响识别。
String _normalize(String text) =>
    text.replaceAll(RegExp(r'[\s《》〈〉“”"『』「」【】（）()·•:：]'), '');

/// 标题区内的大号文字按行拼接：纵向位置相近的对象归为一行，行内按左右排序。
List<String> pageHeadingLines(List<PdfEditObject> objects) {
  final items =
      objects
          .where(
            (o) =>
                o.kind == PdfObjectKind.text &&
                o.bounds.height >= _headingHeight &&
                o.bounds.center.dy >= _headingTop &&
                o.bounds.center.dy <= _headingBottom,
          )
          .toList()
        ..sort((a, b) => a.bounds.center.dy.compareTo(b.bounds.center.dy));
  final lines = <List<PdfEditObject>>[];
  for (final item in items) {
    final last = lines.isEmpty ? null : lines.last;
    if (last != null &&
        (item.bounds.center.dy - last.first.bounds.center.dy).abs() <
            math.max(item.bounds.height, last.first.bounds.height) * .5) {
      last.add(item);
    } else {
      lines.add([item]);
    }
  }
  return [
    for (final line in lines)
      _normalize(
        (line..sort((a, b) => a.bounds.left.compareTo(b.bounds.left)))
            .map((o) => o.text)
            .join(),
      ),
  ]..removeWhere((line) => line.isEmpty);
}

/// 按文字层识别页面类型；业务受理单的标题若是图片，由 [titleImageMatched] 补充判断。
///
/// 规则（按优先级）：
/// 1. 爱知签字页：含“本人已经阅读并理解以上业务受理单相关内容”或“本人同意所办理的业务采用电子协议模式”；
/// 2. 风险抄录页：标题为“反电信网络诈骗提示书”；
/// 3. 业务受理单：标题为“业务受理单”（文字或图片）；
/// 4. 其余均为地市协议页。
///
/// 签字页正文、协议条款中也会出现“业务受理单”字样，第 2、3 条只按整行标题等值匹配，
/// “××业务受理单补充协议”这类标题不会命中。
PdfPageKind classifyPage({
  required String fullText,
  required List<PdfEditObject> objects,
  bool titleImageMatched = false,
}) {
  final text = _compact(fullText);
  if (text.contains('本人已经阅读并理解以上业务受理单相关内容') ||
      text.contains('本人同意所办理的业务采用电子协议模式')) {
    return PdfPageKind.signature;
  }
  final lines = pageHeadingLines(objects);
  if (lines.contains('反电信网络诈骗提示书')) return PdfPageKind.riskTranscript;
  if (lines.contains('业务受理单') || titleImageMatched) {
    return PdfPageKind.acceptance;
  }
  return PdfPageKind.cityAgreement;
}

/// 文字层未识别出类型时，是否还需要渲染标题区做图片比对：
/// 标题区有图片，或标题区没有任何大号文字（可能是整页扫描件）。
bool needsTitleImage(PdfPageKind kind, List<PdfEditObject> objects) =>
    kind == PdfPageKind.cityAgreement &&
    (hasTitleImage(objects) || pageHeadingLines(objects).isEmpty);

/// 标题区域内是否有图片对象：只有这种页面才需要渲染标题做图片比对。
bool hasTitleImage(List<PdfEditObject> objects) => objects.any(
  (o) =>
      o.kind == PdfObjectKind.image &&
      o.bounds.bottom > pageTitleBand.top &&
      o.bounds.top < pageTitleBand.bottom &&
      o.bounds.right > pageTitleBand.left &&
      o.bounds.left < pageTitleBand.right,
);

/// 标题区域在给定整页渲染尺寸下的像素矩形。
({int x, int y, int width, int height}) titleBandPixels(
  int pageWidth,
  int pageHeight,
) {
  final x = (pageTitleBand.left * pageWidth).floor(),
      y = (pageTitleBand.top * pageHeight).floor();
  return (
    x: x,
    y: y,
    width: (pageTitleBand.right * pageWidth).ceil() - x,
    height: (pageTitleBand.bottom * pageHeight).ceil() - y,
  );
}

/// BGRA 像素转灰度；[stride] 为每行字节数（默认紧密排列）。
Uint8List bgraToGray(Uint8List bgra, int width, int height, {int? stride}) {
  final rowBytes = stride ?? width * 4;
  final gray = Uint8List(width * height);
  for (var y = 0; y < height; y++) {
    var i = y * rowBytes;
    for (var x = 0; x < width; x++, i += 4) {
      gray[y * width + x] =
          (bgra[i] * 29 + bgra[i + 1] * 150 + bgra[i + 2] * 77) >> 8;
    }
  }
  return gray;
}

/// 标题指纹网格尺寸。
const fingerprintColumns = 64, fingerprintRows = 16;

/// 标题区内各文字行的指纹：裁到墨迹外框后缩放成
/// [fingerprintColumns]×[fingerprintRows] 的黑白网格。与分辨率、图片拆分方式、
/// 编码格式无关，只取决于字形。
///
/// 自上而下逐段查找足够高的文字行（跳过页眉横线、扫描噪点等过矮的墨迹），
/// 每行按列投影取墨迹最多的连续文字块（字间空隙不超过一个行高），再在该块内
/// 重新收紧上下边界，同一行更高的二维码、印章等不计入外框。
/// 标题上方可能还有单位名称等小字，所以返回全部候选，由调用方逐个比对。
Iterable<({List<bool> bits, double aspect})> titleFingerprints(
  Uint8List gray,
  int width,
  int height, {
  bool Function(double aspect)? accept,
}) sync* {
  // 递归切分（X-Y cut）：先按行切出文字段，段内按列切出块，块内再按行细分；
  // 跨行的二维码、印章会把上下两行连成一段，块内细分后各行仍能单独比对。
  final candidates = <({int left, int right, int top, int bottom})>[];
  void split(int left, int right, int top, int bottom, int depth) {
    for (final row in _rowSegments(gray, width, left, right, top, bottom)) {
      if (row.bottom - row.top + 1 < 8) continue;
      final runs = _runs(gray, width, left, right, row.top, row.bottom);
      for (final run in runs) {
        if (run.right - run.left < 8) continue;
        final rows = _rowSegments(
          gray,
          width,
          run.left,
          run.right,
          row.top,
          row.bottom,
        );
        if (rows.length > 1 && depth < 3) {
          split(run.left, run.right, row.top, row.bottom, depth + 1);
        } else if (rows.isNotEmpty) {
          // 块内收紧上下边界。
          final top = rows.first.top, bottom = rows.last.bottom;
          if (bottom - top + 1 >= 8) {
            candidates.add((
              left: run.left,
              right: run.right,
              top: top,
              bottom: bottom,
            ));
          }
        }
      }
    }
  }

  split(0, width - 1, 0, height - 1, 0);
  for (final c in candidates) {
    // 先按外框宽高比筛选，再生成网格：候选很多时大部分可直接排除。
    final aspect = (c.right - c.left + 1) / (c.bottom - c.top + 1);
    if (accept != null && !accept(aspect)) continue;
    yield _grid(gray, width, c.left, c.right, c.top, c.bottom);
  }
}

/// 在 [left]～[right] 列范围内按行投影切分文字段；
/// 允许字形内部有不超过 3 像素的空行。
List<({int top, int bottom})> _rowSegments(
  Uint8List gray,
  int width,
  int left,
  int right,
  int top,
  int bottom,
) {
  bool inked(int y) {
    var n = 0;
    for (var x = left; x <= right; x++) {
      if (gray[y * width + x] < 140 && ++n >= 2) return true;
    }
    return false;
  }

  final segments = <({int top, int bottom})>[];
  int? start, end;
  var gap = 0;
  for (var y = top; y <= bottom; y++) {
    if (inked(y)) {
      start ??= y;
      end = y;
      gap = 0;
    } else if (start != null && ++gap > 3) {
      segments.add((top: start, bottom: end!));
      start = end = null;
    }
  }
  if (start != null) segments.add((top: start, bottom: end!));
  return segments;
}

/// 第一个候选行的指纹（生成模板与调试用）。
({List<bool> bits, double aspect})? titleFingerprint(
  Uint8List gray,
  int width,
  int height,
) {
  for (final print in titleFingerprints(gray, width, height)) {
    return print;
  }
  return null;
}

/// 行内按列投影切出的连续墨迹块。字间空隙不超过行高的 1/3 视为同一块；
/// 同一行更高的二维码会拉高行高，离标题足够远（大于新行高的 1/3）时仍能分开。
/// 已知限制：紧贴标题（空隙小于该阈值）的高物体会与标题并成一块而漏判；
/// 标题区右界为页宽 80%，右上角二维码通常在区外。
List<({int left, int right})> _runs(
  Uint8List gray,
  int width,
  int from,
  int to,
  int top,
  int bottom,
) {
  final limit = math.max(4, (bottom - top + 1) ~/ 3);
  final runs = <({int left, int right})>[];
  int? left, right;
  var gap = 0;
  for (var x = from; x <= to; x++) {
    var ink = false;
    for (var y = top; y <= bottom; y++) {
      if (gray[y * width + x] < 140) {
        ink = true;
        break;
      }
    }
    if (ink) {
      left ??= x;
      right = x;
      gap = 0;
    } else if (left != null && ++gap > limit) {
      runs.add((left: left, right: right!));
      left = right = null;
    }
  }
  if (left != null) runs.add((left: left, right: right!));
  return runs;
}

({List<bool> bits, double aspect}) _grid(
  Uint8List gray,
  int width,
  int left,
  int right,
  int top,
  int bottom,
) {
  final w = right - left + 1, h = bottom - top + 1;
  final bits = List<bool>.filled(fingerprintColumns * fingerprintRows, false);
  for (var row = 0; row < fingerprintRows; row++) {
    final y0 = top + row * h ~/ fingerprintRows,
        y1 = top + ((row + 1) * h / fingerprintRows).ceil();
    for (var col = 0; col < fingerprintColumns; col++) {
      final x0 = left + col * w ~/ fingerprintColumns,
          x1 = left + ((col + 1) * w / fingerprintColumns).ceil();
      var ink = 0, total = 0;
      for (var y = y0; y < y1 && y <= bottom; y++) {
        for (var x = x0; x < x1 && x <= right; x++) {
          total++;
          if (gray[y * width + x] < 140) ink++;
        }
      }
      bits[row * fingerprintColumns + col] = total > 0 && ink / total > .25;
    }
  }
  return (bits: bits, aspect: w / h);
}

/// 两个指纹的相似度：墨迹格子的交并比（Jaccard），空白不计入，避免大片空白抬高分数。
double fingerprintSimilarity(List<bool> a, List<bool> b) {
  var both = 0, any = 0;
  for (var i = 0; i < a.length; i++) {
    if (a[i] && b[i]) both++;
    if (a[i] || b[i]) any++;
  }
  return any == 0 ? 0 : both / any;
}

/// “业务受理单”标题模板，由真实单据第 1 页的标题图片按 [titleFingerprint] 生成
/// （仅含标题五个字的字形，不含任何业务数据）。每行 64 位，以十六进制存储。
const _acceptanceTitleTemplate = <String>[
  '0980600078000118',
  '0d80fc0ff83fc198',
  '0d80fe1ff9ffe1f4',
  '0d81ec0d39fbc7fe',
  'cdb1fc0df0dfc7fe',
  '4db3381ff8dfc7fe',
  '6df27c1ffdfbc7fe',
  '7de0ff3039ffc66e',
  '3de3f7fff0dfc7fe',
  '3dc7ff8ff0cfc7fc',
  '3dc1fe03e0ffcfff',
  '1d806603c0ffffff',
  '0d906603c3c30060',
  'fff8fe07f99fe060',
  'fffb9c1e7c3fe060',
  '00030c38183fe060',
];
const _acceptanceTitleAspect = 5.071;

List<bool> _decodeTemplate(List<String> rows) => [
  for (final row in rows)
    for (var i = 0; i < fingerprintColumns; i++)
      (int.parse(row[i ~/ 4], radix: 16) >> (3 - i % 4)) & 1 == 1,
];

final _acceptanceBits = _decodeTemplate(_acceptanceTitleTemplate);

/// 指纹编码成模板常量的十六进制行，供生成模板使用。
List<String> encodeFingerprint(List<bool> bits) => [
  for (var row = 0; row < fingerprintRows; row++)
    [
      for (var nibble = 0; nibble < fingerprintColumns ~/ 4; nibble++)
        [
          for (var bit = 0; bit < 4; bit++)
            bits[row * fingerprintColumns + nibble * 4 + bit] ? 1 : 0,
        ].fold<int>(0, (n, b) => n << 1 | b).toRadixString(16),
    ].join(),
];

/// 标题区域渲染图是否为“业务受理单”标题。
bool matchesAcceptanceTitle(Uint8List gray, int width, int height) {
  if (_acceptanceTitleTemplate.isEmpty) return false;
  // 宽高比相差超过 25% 的行（如“客户服务协议”）直接排除，任一候选行匹配即命中。
  return titleFingerprints(
    gray,
    width,
    height,
    accept: (aspect) => (aspect / _acceptanceTitleAspect - 1).abs() <= .25,
  ).any(
    (found) =>
        fingerprintSimilarity(found.bits, _acceptanceBits) >=
        acceptanceTitleThreshold,
  );
}

/// 判定为“业务受理单”标题的最低相似度。实测真实标题 0.81～1.00
/// （含 1.0～2.5 倍不同渲染分辨率），其他页面标题区最高 0.49。
const acceptanceTitleThreshold = .65;
