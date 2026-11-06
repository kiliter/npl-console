import 'dart:typed_data';

/// TrueType 字形重编号（用于 CIDToGIDMap 为 Identity 的 CIDFontType2）。
///
/// 单据里的嵌入字体已经只保留了用到的字形轮廓，但 loca、hmtx、cmap 仍按整套
/// 字库（6 万多个字形）保留，每份字体七八百 KB。这里只保留有轮廓的字形（及其
/// 组合字形引用的部件）并重新编号，同时生成 CID → 新字形号的映射表。
/// 页面内容里的字符码（CID）不变，宽度（/W）、ToUnicode 也不变，所以显示和文字
/// 提取都与原来完全一致；被丢弃的空字形（如空格）统一映射到末尾新增的空字形，
/// 不会落到可能画成方框的 .notdef 上。
class TrueTypeSubset {
  final Uint8List font;

  /// 2 字节一项的 CID → 字形号映射，长度为原字形数 × 2。
  final Uint8List cidToGid;
  final int glyphs;
  const TrueTypeSubset(this.font, this.cidToGid, this.glyphs);
}

class FontSubsetError implements Exception {
  final String message;
  const FontSubsetError(this.message);
  @override
  String toString() => message;
}

int _u16(Uint8List b, int o) => (b[o] << 8) | b[o + 1];
int _i16(Uint8List b, int o) {
  final v = _u16(b, o);
  return v >= 0x8000 ? v - 0x10000 : v;
}

int _u32(Uint8List b, int o) =>
    (b[o] << 24 | b[o + 1] << 16 | b[o + 2] << 8 | b[o + 3]) & 0xffffffff;

void _put16(Uint8List b, int o, int v) {
  b[o] = (v >> 8) & 0xff;
  b[o + 1] = v & 0xff;
}

void _put32(Uint8List b, int o, int v) {
  b[o] = (v >> 24) & 0xff;
  b[o + 1] = (v >> 16) & 0xff;
  b[o + 2] = (v >> 8) & 0xff;
  b[o + 3] = v & 0xff;
}

int _checksum(Uint8List data) {
  var sum = 0;
  final padded = data.length + ((4 - data.length % 4) % 4);
  for (var i = 0; i < padded; i += 4) {
    var word = 0;
    for (var j = 0; j < 4; j++) {
      word = (word << 8) | (i + j < data.length ? data[i + j] : 0);
    }
    sum = (sum + word) & 0xffffffff;
  }
  return sum;
}

/// 返回 null 表示不需要（或不能安全地）精简：不是 glyf 轮廓字体、
/// 表结构异常、精简后不会更小。
TrueTypeSubset? subsetTrueType(Uint8List font) {
  if (font.length < 12) return null;
  final version = _u32(font, 0);
  if (version != 0x00010000 && version != 0x74727565) {
    return null; // 非 TrueType（如 CFF、TTC）
  }
  final count = _u16(font, 4);
  final tables = <String, Uint8List>{};
  for (var i = 0; i < count; i++) {
    final at = 12 + i * 16;
    if (at + 16 > font.length) return null;
    final tag = String.fromCharCodes(font.sublist(at, at + 4));
    final offset = _u32(font, at + 8), length = _u32(font, at + 12);
    if (offset + length > font.length) return null;
    tables[tag] = Uint8List.sublistView(font, offset, offset + length);
  }
  final head = tables['head'], maxp = tables['maxp'], hhea = tables['hhea'];
  final loca = tables['loca'], glyf = tables['glyf'], hmtx = tables['hmtx'];
  if (head == null ||
      maxp == null ||
      hhea == null ||
      loca == null ||
      glyf == null ||
      hmtx == null) {
    return null;
  }
  if (head.length < 54 || maxp.length < 6 || hhea.length < 36) return null;
  final numGlyphs = _u16(maxp, 4);
  final longLoca = _i16(head, 50) == 1;
  int offsetOf(int gid) =>
      longLoca ? _u32(loca, gid * 4) : _u16(loca, gid * 2) * 2;
  if (loca.length < (numGlyphs + 1) * (longLoca ? 4 : 2)) return null;

  Uint8List glyph(int gid) {
    final start = offsetOf(gid), end = offsetOf(gid + 1);
    if (end <= start || end > glyf.length) return Uint8List(0);
    return Uint8List.sublistView(glyf, start, end);
  }

  // 有轮廓的字形 + 组合字形的部件（递归）。
  final keep = <int>{0};
  final pending = <int>[];
  for (var gid = 1; gid < numGlyphs; gid++) {
    if (glyph(gid).isNotEmpty) pending.add(gid);
  }
  while (pending.isNotEmpty) {
    final gid = pending.removeLast();
    if (!keep.add(gid)) continue;
    final data = glyph(gid);
    if (data.length >= 10 && _i16(data, 0) < 0) {
      for (final component in _components(data)) {
        if (component.gid < numGlyphs && !keep.contains(component.gid)) {
          pending.add(component.gid);
        }
      }
    }
  }
  final kept = keep.toList()..sort();
  final emptyGid = kept.length; // 末尾新增的空字形
  final total = kept.length + 1;
  if (total >= numGlyphs) return null;
  final newId = <int, int>{for (var i = 0; i < kept.length; i++) kept[i]: i};

  // glyf + loca（长格式）
  final glyfOut = BytesBuilder(copy: false);
  final locaOut = Uint8List((total + 1) * 4);
  for (var i = 0; i < kept.length; i++) {
    _put32(locaOut, i * 4, glyfOut.length);
    final data = Uint8List.fromList(glyph(kept[i]));
    if (data.length >= 10 && _i16(data, 0) < 0) {
      for (final component in _components(data)) {
        final mapped = newId[component.gid];
        if (mapped == null) throw const FontSubsetError('组合字形引用缺失');
        _put16(data, component.at, mapped);
      }
    }
    glyfOut.add(data);
    while (glyfOut.length % 4 != 0) {
      glyfOut.addByte(0);
    }
  }
  _put32(locaOut, kept.length * 4, glyfOut.length); // 空字形
  _put32(locaOut, total * 4, glyfOut.length);

  // hmtx：全部写成长度量
  final numberOfHMetrics = _u16(hhea, 34);
  if (numberOfHMetrics == 0 || hmtx.length < numberOfHMetrics * 4) return null;
  ({int advance, int lsb}) metric(int gid) {
    if (gid < numberOfHMetrics) {
      return (advance: _u16(hmtx, gid * 4), lsb: _i16(hmtx, gid * 4 + 2));
    }
    final lsbAt = numberOfHMetrics * 4 + (gid - numberOfHMetrics) * 2;
    return (
      advance: _u16(hmtx, (numberOfHMetrics - 1) * 4),
      lsb: lsbAt + 2 <= hmtx.length ? _i16(hmtx, lsbAt) : 0,
    );
  }

  final hmtxOut = Uint8List(total * 4);
  for (var i = 0; i < kept.length; i++) {
    final m = metric(kept[i]);
    _put16(hmtxOut, i * 4, m.advance);
    _put16(hmtxOut, i * 4 + 2, m.lsb & 0xffff);
  }

  final headOut = Uint8List.fromList(head);
  _put16(headOut, 50, 1); // indexToLocFormat = long
  _put32(headOut, 8, 0); // checkSumAdjustment，最后回填
  final maxpOut = Uint8List.fromList(maxp);
  _put16(maxpOut, 4, total);
  final hheaOut = Uint8List.fromList(hhea);
  _put16(hheaOut, 34, total);

  // 最小 cmap（3,1 格式 4，只有结束段）：CID 字体按 CIDToGIDMap 取字形，不依赖 cmap；
  // 保留一个合法的空表，兼容要求 cmap 存在的解析器。
  final cmap = Uint8List.fromList([
    0, 0, 0, 1, // version, numTables
    0, 3, 0, 1, 0, 0, 0, 12, // platform 3, encoding 1, offset 12
    0, 4, 0, 24, 0, 0, // format 4, length 24, language
    0,
    2,
    0,
    2,
    0,
    0,
    0,
    0, // segCountX2=2, searchRange=2, entrySelector=0, rangeShift=0
    0xff, 0xff, // endCode
    0, 0, // reservedPad
    0xff, 0xff, // startCode
    0, 1, // idDelta
    0, 0, // idRangeOffset
  ]);
  // post 格式 3：不含字形名。
  final post = Uint8List(32);
  _put32(post, 0, 0x00030000);
  final oldPost = tables['post'];
  if (oldPost != null && oldPost.length >= 32) {
    post.setRange(4, 32, oldPost.sublist(4, 32));
    for (var i = 16; i < 32; i++) {
      post[i] = 0; // 内存用量字段清零
    }
  }

  final out = <String, Uint8List>{
    'head': headOut,
    'hhea': hheaOut,
    'maxp': maxpOut,
    'loca': locaOut,
    'glyf': glyfOut.toBytes(),
    'hmtx': hmtxOut,
    'cmap': cmap,
    'post': post,
    // 字形指令依赖的表与字体信息原样保留；依赖原字形号的表（GSUB/GPOS/kern/vmtx 等）
    // 对 CID 字体渲染无用，直接去掉。
    for (final tag in const ['OS/2', 'name', 'cvt ', 'fpgm', 'prep', 'gasp'])
      if (tables[tag] != null) tag: tables[tag]!,
  };
  final tags = out.keys.toList()..sort();
  final numTables = tags.length;
  var power = 1, log2 = 0;
  while (power * 2 <= numTables) {
    power *= 2;
    log2++;
  }
  final headerLength = 12 + numTables * 16;
  final header = Uint8List(headerLength);
  _put32(header, 0, 0x00010000);
  _put16(header, 4, numTables);
  _put16(header, 6, power * 16);
  _put16(header, 8, log2);
  _put16(header, 10, numTables * 16 - power * 16);
  final body = BytesBuilder(copy: false);
  var offset = headerLength;
  var headOffset = 0;
  for (var i = 0; i < tags.length; i++) {
    final data = out[tags[i]]!;
    final at = 12 + i * 16;
    header.setRange(at, at + 4, tags[i].codeUnits);
    _put32(header, at + 4, _checksum(data));
    _put32(header, at + 8, offset);
    _put32(header, at + 12, data.length);
    if (tags[i] == 'head') headOffset = offset;
    body.add(data);
    final pad = (4 - data.length % 4) % 4;
    for (var p = 0; p < pad; p++) {
      body.addByte(0);
    }
    offset += data.length + pad;
  }
  final result = Uint8List.fromList([...header, ...body.toBytes()]);
  final adjustment = (0xB1B0AFBA - _checksum(result)) & 0xffffffff;
  _put32(result, headOffset + 8, adjustment);

  final map = Uint8List(numGlyphs * 2);
  for (var gid = 0; gid < numGlyphs; gid++) {
    _put16(map, gid * 2, newId[gid] ?? emptyGid);
  }
  return TrueTypeSubset(result, map, total);
}

/// 组合字形里各部件的字形号及其在字形数据中的位置。
List<({int gid, int at})> _components(Uint8List data) {
  final found = <({int gid, int at})>[];
  var p = 10;
  while (p + 4 <= data.length) {
    final flags = _u16(data, p);
    found.add((gid: _u16(data, p + 2), at: p + 2));
    p += 4;
    p += (flags & 0x0001) != 0 ? 4 : 2; // ARG_1_AND_2_ARE_WORDS
    if ((flags & 0x0008) != 0) {
      p += 2; // WE_HAVE_A_SCALE
    } else if ((flags & 0x0040) != 0) {
      p += 4; // WE_HAVE_AN_X_AND_Y_SCALE
    } else if ((flags & 0x0080) != 0) {
      p += 8; // WE_HAVE_A_TWO_BY_TWO
    }
    if ((flags & 0x0020) == 0) break; // MORE_COMPONENTS
  }
  return found;
}
