import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;

import 'font_subset.dart';
import 'pdf_objects.dart';

/// 上传接口只接受 2MiB 以内的请求（超过返回 HTTP 413）；为 multipart 表头留 8KiB。
const uploadLimit = 2 * 1024 * 1024;
const fileLimit = uploadLimit - 8 * 1024;

/// 压缩档位：0 无损；1 起逐级有损，只在无损仍超过上传限制时使用。
const optimizeLevels = <String>[
  '无损（去重 + 字体精简）',
  '非 JPEG 图片转高质量 JPEG',
  '图片长边降到 2000 像素',
  '图片长边降到 1500 像素',
  '图片长边降到 1100 像素',
];

class OptimizeResult {
  final Uint8List bytes;
  final int level;
  final int before;
  final int fontsSubset;
  final int objectsMerged;
  const OptimizeResult(
    this.bytes,
    this.level,
    this.before, {
    this.fontsSubset = 0,
    this.objectsMerged = 0,
  });
  String get label => optimizeLevels[level];
  bool get lossy => level > 0;
  bool get fits => bytes.length <= fileLimit;
}

/// 在后台 isolate 中按档位依次尝试，返回第一份不超过 [limit] 的结果；
/// 都超过时返回最小的一份。文件无法解析（加密、结构损坏）时返回 null。
Future<OptimizeResult?> optimizePdf(
  Uint8List bytes, {
  int limit = fileLimit,
  int startLevel = 0,
}) => Isolate.run(
  () => optimizePdfSync(bytes, limit: limit, startLevel: startLevel),
);

OptimizeResult? optimizePdfSync(
  Uint8List bytes, {
  int limit = fileLimit,
  int startLevel = 0,
}) {
  OptimizeResult? best;
  for (var level = startLevel; level < optimizeLevels.length; level++) {
    final result = optimizeOnce(bytes, level);
    if (result == null) return best;
    if (best == null || result.bytes.length < best.bytes.length) best = result;
    if (result.bytes.length <= limit) return result;
  }
  return best;
}

/// 单个档位的整理。每次都从原始字节重新解析，档位之间互不影响。
OptimizeResult? optimizeOnce(Uint8List bytes, int level) {
  final PdfDocumentModel doc;
  try {
    doc = PdfDocumentModel.parse(bytes);
  } on Object {
    return null;
  }
  if (doc.encrypted) return null;
  final merged = _dedupe(doc);
  final fonts = _subsetFonts(doc);
  // 字体精简后各字体的映射表可能相同，再去重一次。
  final mergedAgain = fonts > 0 ? _dedupe(doc) : 0;
  if (level > 0) _recompressImages(doc, level);
  final out = writeDocument(doc);
  return OptimizeResult(
    out,
    level,
    bytes.length,
    fontsSubset: fonts,
    objectsMerged: merged + mergedAgain,
  );
}

// ---------------- 去重 ----------------

const _keepTypes = {
  'Catalog',
  'Pages',
  'Page',
  'Annot',
  'Sig',
  'OCG',
  'OCMD',
  'Outlines',
  'StructTreeRoot',
  'StructElem',
  'MCR',
  'OBJR',
  'Action',
};
const _keepKeys = {
  'Parent',
  'Kids',
  'Rect',
  'FT',
  'P',
  'Next',
  'Prev',
  'First',
  'Last',
};

/// 页面、页面树、批注、表单域等带身份或双向链接的对象不合并（合并后结构会出错）；
/// 字体、字体文件、图片、表单 XObject、资源字典等内容相同即可合并。
bool _mergeable(Object? value) {
  final dict = value is PdfStream
      ? value.dict
      : value is PdfDict
      ? value
      : null;
  if (dict == null) return value is List;
  final type = dict['Type'];
  if (type is PdfName && _keepTypes.contains(type.value)) return false;
  if (value is PdfDict && dict.keys.any(_keepKeys.contains)) return false;
  return true;
}

/// 分区细化：先按自身内容分组，再把引用替换为目标所在组反复细化，直到组数不变，
/// 能正确处理互相引用的对象。返回被合并掉的对象数。
int _dedupe(PdfDocumentModel doc) {
  final ids = doc.objects.keys.toList()..sort();
  final mergeable = {for (final id in ids) id: _mergeable(doc.objects[id])};
  final dataHash = <int, String>{};
  for (final id in ids) {
    final v = doc.objects[id];
    if (v is PdfStream) dataHash[id] = md5.convert(v.data).toString();
  }
  var cls = <int, int>{};
  String signature(int id, String Function(PdfRef) ref) {
    if (!mergeable[id]!) return 'U$id';
    final v = doc.objects[id];
    final out = BytesBuilder(copy: false);
    if (v is PdfStream) {
      writeValue(out, pdfDict(v.dict)..remove('Length'), ref: ref);
      out.add(latin1.encode('S${dataHash[id]}'));
    } else {
      writeValue(out, v, ref: ref);
    }
    return md5.convert(out.toBytes()).toString();
  }

  Map<int, int> classify(String Function(PdfRef) ref) {
    final groups = <String, int>{};
    return {
      for (final id in ids)
        id: groups.putIfAbsent(signature(id, ref), () => groups.length),
    };
  }

  cls = classify((_) => 'R');
  for (var round = 0; round < 32; round++) {
    final previous = cls;
    final next = classify((r) => 'C${previous[r.id] ?? 'x${r.id}'}');
    final before = previous.values.toSet().length,
        after = next.values.toSet().length;
    cls = next;
    if (after == before) break;
  }
  final representative = <int, int>{};
  final replace = <int, int>{};
  for (final id in ids) {
    final c = cls[id]!;
    final rep = representative.putIfAbsent(c, () => id);
    if (rep != id) replace[id] = rep;
  }
  if (replace.isEmpty) return 0;
  Object? remap(Object? v) {
    if (v is PdfRef) {
      final to = replace[v.id];
      return to == null ? v : PdfRef(to);
    }
    if (v is List) return [for (final x in v) remap(x)];
    if (v is PdfDict) {
      return pdfDict({for (final e in v.entries) e.key: remap(e.value)});
    }
    if (v is PdfStream) return PdfStream(remap(v.dict) as PdfDict, v.data);
    return v;
  }

  for (final id in replace.keys) {
    doc.objects.remove(id);
  }
  for (final id in doc.objects.keys.toList()) {
    doc.objects[id] = remap(doc.objects[id]);
  }
  final trailer = remap(doc.trailer) as PdfDict;
  doc.trailer
    ..clear()
    ..addAll(trailer);
  return replace.length;
}

// ---------------- 字体 ----------------

String? _name(Object? v) => v is PdfName ? v.value : null;

/// 只精简满足条件的字体文件：被 CIDFontType2 引用、CIDToGIDMap 为 Identity、
/// 上层 Type0 字体是横排 Identity-H，且没有被简单 TrueType 字体共用。
/// 返回精简的字体文件数。
int _subsetFonts(PdfDocumentModel doc) {
  final users = <int, List<int>>{}; // 字体文件 → CIDFont
  final unsafe = <int>{};
  final cidFonts = <int>{};
  for (final e in doc.objects.entries) {
    final v = e.value;
    if (v is! PdfDict || _name(v['Type']) != 'Font') continue;
    final subtype = _name(v['Subtype']);
    final descriptor = doc.resolve(v['FontDescriptor']);
    final file = descriptor is PdfDict ? descriptor['FontFile2'] : null;
    if (subtype == 'Type0') {
      final encoding = _name(doc.resolve(v['Encoding']));
      final descendants = doc.resolve(v['DescendantFonts']);
      if (descendants is List) {
        for (final d in descendants) {
          if (d is PdfRef && encoding != 'Identity-H') unsafe.add(-d.id);
        }
      }
      continue;
    }
    if (file is! PdfRef) continue;
    if (subtype == 'CIDFontType2') {
      final map = v['CIDToGIDMap'];
      if (map != null && _name(map) != 'Identity') unsafe.add(file.id);
      users.putIfAbsent(file.id, () => []).add(e.key);
      cidFonts.add(e.key);
    } else {
      unsafe.add(file.id); // 简单 TrueType 字体按字符码查 cmap，不能去掉 cmap
    }
  }
  // 竖排等非 Identity-H 的 Type0 下的 CIDFont：其字体文件不精简。
  for (final entry in users.entries) {
    if (entry.value.any((cid) => unsafe.contains(-cid))) unsafe.add(entry.key);
  }
  var done = 0;
  for (final entry in users.entries) {
    if (unsafe.contains(entry.key)) continue;
    final stream = doc.objects[entry.key];
    if (stream is! PdfStream) continue;
    final Uint8List? raw;
    try {
      raw = decodeStream(stream, doc);
    } on Object {
      continue;
    }
    if (raw == null) continue;
    final TrueTypeSubset? subset;
    try {
      subset = subsetTrueType(raw);
    } on Object {
      continue;
    }
    if (subset == null) continue;
    final fontData = deflate(subset.font);
    final mapData = deflate(subset.cidToGid);
    if (fontData.length + mapData.length >= stream.data.length) continue;
    final dict = pdfDict(stream.dict)
      ..remove('DecodeParms')
      ..['Filter'] = const PdfName('FlateDecode')
      ..['Length1'] = subset.font.length;
    doc.objects[entry.key] = PdfStream(dict, fontData);
    final mapRef = doc.add(
      PdfStream(pdfDict({'Filter': const PdfName('FlateDecode')}), mapData),
    );
    for (final cid in entry.value) {
      final font = doc.objects[cid] as PdfDict;
      doc.objects[cid] = pdfDict(font)..['CIDToGIDMap'] = mapRef;
    }
    done++;
  }
  return done;
}

// ---------------- 图片（仅超限时） ----------------

int? _components(PdfDocumentModel doc, Object? colorSpace) {
  final cs = doc.resolve(colorSpace);
  final name = _name(cs);
  if (name == 'DeviceRGB' || name == 'RGB') return 3;
  if (name == 'DeviceGray' || name == 'G') return 1;
  if (cs is List &&
      cs.isNotEmpty &&
      _name(cs.first) == 'ICCBased' &&
      cs.length > 1) {
    final icc = doc.resolve(cs[1]);
    final n = icc is PdfStream ? doc.resolve(icc.dict['N']) : null;
    if (n == 1 || n == 3) return n as int;
  }
  return null;
}

void _recompressImages(PdfDocumentModel doc, int level) {
  final maxSide = switch (level) {
    2 => 2000,
    3 => 1500,
    4 => 1100,
    _ => 1 << 30,
  };
  final quality = level == 1 ? 92 : 88;
  // 被当作 SMask 的图片保持无损（透明边缘对有损压缩很敏感）。
  final masks = <int>{};
  for (final v in doc.objects.values) {
    if (v is PdfStream && v.dict['SMask'] is PdfRef) {
      masks.add((v.dict['SMask'] as PdfRef).id);
    }
  }
  for (final id in doc.objects.keys.toList()) {
    final v = doc.objects[id];
    if (v is! PdfStream ||
        _name(v.dict['Subtype']) != 'Image' ||
        masks.contains(id)) {
      continue;
    }
    final dict = v.dict;
    if (dict['ImageMask'] == true ||
        dict['Decode'] != null ||
        dict['Mask'] != null) {
      continue;
    }
    final width = doc.resolve(dict['Width']),
        height = doc.resolve(dict['Height']);
    if (width is! int || height is! int || width * height < 10000) continue;
    if (doc.resolve(dict['BitsPerComponent']) != 8) continue;
    final n = _components(doc, dict['ColorSpace']);
    if (n == null) continue;
    final filters = doc.resolve(dict['Filter']);
    final filter = filters is List
        ? (filters.length == 1 ? _name(filters.first) : null)
        : _name(filters);
    final hasMask = dict['SMask'] != null;
    final needsResize = !hasMask && (width > maxSide || height > maxSide);
    img.Image? image;
    try {
      if (filter == 'DCTDecode' || filter == 'DCT') {
        if (!needsResize) continue; // 原有 JPEG 只在需要降分辨率时才重编码
        image = img.decodeJpg(v.data);
      } else if (filter == 'FlateDecode' || filter == 'Fl') {
        final raw = decodeStream(v, doc);
        if (raw == null || raw.length < width * height * n) continue;
        image = img.Image.fromBytes(
          width: width,
          height: height,
          bytes: raw.buffer,
          bytesOffset: raw.offsetInBytes,
          numChannels: n,
        );
      }
    } on Object {
      continue;
    }
    if (image == null) continue;
    if (needsResize) {
      final scale = maxSide / (width > height ? width : height);
      image = img.copyResize(
        image,
        width: (width * scale).round(),
        height: (height * scale).round(),
        interpolation: img.Interpolation.average,
      );
    }
    final jpeg = img.encodeJpg(image, quality: quality);
    if (jpeg.length >= v.data.length && !needsResize) continue;
    final next = pdfDict(dict)
      ..remove('DecodeParms')
      ..['Filter'] = const PdfName('DCTDecode')
      ..['Width'] = image.width
      ..['Height'] = image.height
      ..['BitsPerComponent'] = 8
      ..['ColorSpace'] = n == 1
          ? const PdfName('DeviceGray')
          : const PdfName('DeviceRGB');
    doc.objects[id] = PdfStream(next, jpeg);
  }
}
