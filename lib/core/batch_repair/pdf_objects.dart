import 'dart:collection';
import 'dart:convert';
import 'dart:io' show ZLibDecoder, ZLibEncoder;
import 'dart:math' as math;
import 'dart:typed_data';

/// 极简 PDF 对象模型：只为“整理并重写文件”服务（去重、替换字体与图片流），
/// 不解释页面内容。读取支持 xref 表、xref 流（含 PNG 预测）、对象流与混合 xref，
/// xref 损坏时整文件扫描“N G obj”兜底。写出统一为对象流 + xref 流（PDF 1.7）。
///
/// 值的表示：null、bool、int、double、[PdfName]、[PdfString]、[PdfRef]、
/// List（数组）、[PdfDict]（字典，键不带斜杠）、[PdfStream]。
class PdfName {
  final String value;
  const PdfName(this.value);
  @override
  bool operator ==(Object other) => other is PdfName && other.value == value;
  @override
  int get hashCode => value.hashCode;
  @override
  String toString() => '/$value';
}

class PdfString {
  final Uint8List bytes;
  final bool hex;
  const PdfString(this.bytes, {this.hex = false});
}

class PdfRef {
  final int id;
  final int gen;
  const PdfRef(this.id, [this.gen = 0]);
  @override
  bool operator ==(Object other) =>
      other is PdfRef && other.id == id && other.gen == gen;
  @override
  int get hashCode => Object.hash(id, gen);
  @override
  String toString() => '$id $gen R';
}

typedef PdfDict = LinkedHashMap<String, Object?>;

PdfDict pdfDict([Map<String, Object?>? entries]) =>
    LinkedHashMap<String, Object?>.of(entries ?? const {});

class PdfStream {
  final PdfDict dict;

  /// 编码后的原始数据（与 /Filter 对应）。
  Uint8List data;
  PdfStream(this.dict, this.data);
}

class PdfFormatError implements Exception {
  final String message;
  const PdfFormatError(this.message);
  @override
  String toString() => 'PDF 结构错误：$message';
}

/// 关键字（obj、endobj、stream、R 以外的裸词），解析内部使用。
class _Keyword {
  final String value;
  const _Keyword(this.value);
}

bool _isWhite(int c) =>
    c == 0 || c == 9 || c == 10 || c == 12 || c == 13 || c == 32;
bool _isDelimiter(int c) =>
    c == 0x28 || // (
    c == 0x29 || // )
    c == 0x3c || // <
    c == 0x3e || // >
    c == 0x5b || // [
    c == 0x5d || // ]
    c == 0x7b || // {
    c == 0x7d || // }
    c == 0x2f || // /
    c == 0x25; // %
bool _isRegular(int c) => !_isWhite(c) && !_isDelimiter(c);
bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

class _Lexer {
  final Uint8List b;
  int p;
  _Lexer(this.b, [this.p = 0]);

  void skipWhite() {
    while (p < b.length) {
      final c = b[p];
      if (_isWhite(c)) {
        p++;
      } else if (c == 0x25) {
        while (p < b.length && b[p] != 10 && b[p] != 13) {
          p++;
        }
      } else {
        break;
      }
    }
  }

  /// 读一个值；遇到裸词返回 [_Keyword]。[resolveRefs] 为 false 时不识别“N G R”。
  Object? value() {
    skipWhite();
    if (p >= b.length) throw const PdfFormatError('文件意外结束');
    final c = b[p];
    if (c == 0x2f) return _name();
    if (c == 0x28) return _literal();
    if (c == 0x3c) {
      if (p + 1 < b.length && b[p + 1] == 0x3c) return _dict();
      return _hex();
    }
    if (c == 0x5b) {
      p++;
      final list = <Object?>[];
      while (true) {
        skipWhite();
        if (p >= b.length) throw const PdfFormatError('数组未结束');
        if (b[p] == 0x5d) {
          p++;
          return list;
        }
        final item = value();
        if (item is _Keyword) throw PdfFormatError('数组中出现 ${item.value}');
        list.add(item);
      }
    }
    if (_isDigit(c) || c == 0x2b || c == 0x2d || c == 0x2e) return _number();
    if (_isRegular(c)) {
      final start = p;
      while (p < b.length && _isRegular(b[p])) {
        p++;
      }
      final word = latin1.decode(b.sublist(start, p));
      if (word == 'true') return true;
      if (word == 'false') return false;
      if (word == 'null') return null;
      return _Keyword(word);
    }
    // 孤立的分隔符（如 ')' '>'），跳过并报错。
    p++;
    throw PdfFormatError('意外字符 0x${c.toRadixString(16)}');
  }

  PdfName _name() {
    p++;
    final out = BytesBuilder(copy: false);
    while (p < b.length && _isRegular(b[p])) {
      final c = b[p];
      if (c == 0x23 && p + 2 < b.length) {
        final hex = int.tryParse(
          latin1.decode(b.sublist(p + 1, p + 3)),
          radix: 16,
        );
        if (hex != null) {
          out.addByte(hex);
          p += 3;
          continue;
        }
      }
      out.addByte(c);
      p++;
    }
    return PdfName(utf8.decode(out.toBytes(), allowMalformed: true));
  }

  PdfString _literal() {
    p++;
    final out = BytesBuilder(copy: false);
    var depth = 1;
    while (p < b.length) {
      final c = b[p++];
      if (c == 0x5c) {
        if (p >= b.length) break;
        final e = b[p++];
        switch (e) {
          case 0x6e:
            out.addByte(10);
          case 0x72:
            out.addByte(13);
          case 0x74:
            out.addByte(9);
          case 0x62:
            out.addByte(8);
          case 0x66:
            out.addByte(12);
          case 0x0d:
            if (p < b.length && b[p] == 0x0a) p++;
          case 0x0a:
            break;
          default:
            if (e >= 0x30 && e <= 0x37) {
              var v = e - 0x30;
              for (var i = 0; i < 2 && p < b.length; i++) {
                final d = b[p];
                if (d < 0x30 || d > 0x37) break;
                v = v * 8 + d - 0x30;
                p++;
              }
              out.addByte(v & 0xff);
            } else {
              out.addByte(e);
            }
        }
        continue;
      }
      if (c == 0x28) depth++;
      if (c == 0x29 && --depth == 0) break;
      out.addByte(c);
    }
    return PdfString(out.toBytes());
  }

  PdfString _hex() {
    p++;
    final digits = <int>[];
    while (p < b.length && b[p] != 0x3e) {
      final c = b[p++];
      final v = c >= 0x30 && c <= 0x39
          ? c - 0x30
          : c >= 0x41 && c <= 0x46
          ? c - 55
          : c >= 0x61 && c <= 0x66
          ? c - 87
          : -1;
      if (v >= 0) digits.add(v);
    }
    p++;
    if (digits.length.isOdd) digits.add(0);
    return PdfString(
      Uint8List.fromList([
        for (var i = 0; i < digits.length; i += 2)
          digits[i] * 16 + digits[i + 1],
      ]),
      hex: true,
    );
  }

  PdfDict _dict() {
    p += 2;
    final dict = pdfDict();
    while (true) {
      skipWhite();
      if (p >= b.length) throw const PdfFormatError('字典未结束');
      if (b[p] == 0x3e && p + 1 < b.length && b[p + 1] == 0x3e) {
        p += 2;
        return dict;
      }
      final key = value();
      if (key is! PdfName) throw const PdfFormatError('字典键不是名称');
      skipWhite();
      if (p < b.length &&
          b[p] == 0x3e &&
          p + 1 < b.length &&
          b[p + 1] == 0x3e) {
        dict[key.value] = null;
        continue;
      }
      final v = value();
      if (v is _Keyword) throw PdfFormatError('字典值出现 ${v.value}');
      dict[key.value] = v;
    }
  }

  Object _number() {
    final start = p;
    p++;
    while (p < b.length) {
      final c = b[p];
      if (_isDigit(c) || c == 0x2e || c == 0x2d) {
        p++;
      } else {
        break;
      }
    }
    final text = latin1.decode(b.sublist(start, p));
    if (!text.contains('.')) {
      final n = int.tryParse(text) ?? 0;
      // 尝试“N G R”。
      if (n >= 0 && !text.startsWith('+') && !text.startsWith('-')) {
        final save = p;
        skipWhite();
        if (p < b.length && _isDigit(b[p])) {
          final g0 = p;
          while (p < b.length && _isDigit(b[p])) {
            p++;
          }
          final gen = int.parse(latin1.decode(b.sublist(g0, p)));
          skipWhite();
          if (p < b.length &&
              b[p] == 0x52 &&
              (p + 1 >= b.length || !_isRegular(b[p + 1]))) {
            p++;
            return PdfRef(n, gen);
          }
        }
        p = save;
      }
      return n;
    }
    // “--1”“1.2.3”之类不规范写法按 0 处理。
    return double.tryParse(text.replaceFirst(RegExp(r'^-+'), '-')) ?? 0.0;
  }

  int? integer() {
    final v = value();
    return v is int ? v : null;
  }

  bool keyword(String word) {
    skipWhite();
    final bytes = latin1.encode(word);
    if (p + bytes.length > b.length) return false;
    for (var i = 0; i < bytes.length; i++) {
      if (b[p + i] != bytes[i]) return false;
    }
    if (p + bytes.length < b.length && _isRegular(b[p + bytes.length])) {
      return false;
    }
    p += bytes.length;
    return true;
  }
}

int _indexOf(Uint8List b, List<int> pattern, int from, [int? to]) {
  final end = math.min(to ?? b.length, b.length) - pattern.length;
  outer:
  for (var i = math.max(0, from); i <= end; i++) {
    for (var j = 0; j < pattern.length; j++) {
      if (b[i + j] != pattern[j]) continue outer;
    }
    return i;
  }
  return -1;
}

int _lastIndexOf(Uint8List b, List<int> pattern, [int? before]) {
  for (
    var i = math.min(before ?? b.length, b.length) - pattern.length;
    i >= 0;
    i--
  ) {
    var ok = true;
    for (var j = 0; j < pattern.length; j++) {
      if (b[i + j] != pattern[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return i;
  }
  return -1;
}

/// 解码流数据。只支持整理所需的过滤器：FlateDecode（含 PNG/TIFF 预测）。
/// 其他过滤器返回 null，由调用方保留原样。
Uint8List? decodeStream(PdfStream stream, PdfDocumentModel? doc) {
  final filters = _asList(
    doc?.resolve(stream.dict['Filter']) ?? stream.dict['Filter'],
  );
  final parmsRaw =
      doc?.resolve(stream.dict['DecodeParms']) ?? stream.dict['DecodeParms'];
  final parms = _asList(parmsRaw);
  var data = stream.data;
  for (var i = 0; i < filters.length; i++) {
    final f = filters[i];
    if (f is! PdfName) return null;
    if (f.value != 'FlateDecode' && f.value != 'Fl') return null;
    data = inflate(data);
    final p = i < parms.length ? (doc?.resolve(parms[i]) ?? parms[i]) : null;
    if (p is PdfDict) data = _unpredict(data, p, doc);
  }
  return data;
}

List<Object?> _asList(Object? v) => v == null
    ? const []
    : v is List
    ? v
    : [v];

Uint8List inflate(Uint8List data) {
  try {
    return Uint8List.fromList(ZLibDecoder().convert(data));
  } catch (_) {
    // 部分生成器写出不带 zlib 头的原始 deflate，或流尾多余字节。
    try {
      return Uint8List.fromList(ZLibDecoder(raw: true).convert(data));
    } catch (_) {
      throw const PdfFormatError('Flate 数据损坏');
    }
  }
}

Uint8List deflate(Uint8List data) =>
    Uint8List.fromList(ZLibEncoder(level: 9).convert(data));

Uint8List _unpredict(Uint8List data, PdfDict parms, PdfDocumentModel? doc) {
  int intOf(String key, int fallback) {
    final v = doc?.resolve(parms[key]) ?? parms[key];
    return v is int ? v : fallback;
  }

  final predictor = intOf('Predictor', 1);
  if (predictor < 2) return data;
  final colors = intOf('Colors', 1), bpc = intOf('BitsPerComponent', 8);
  final columns = intOf('Columns', 1);
  final bpp = math.max(1, (colors * bpc + 7) ~/ 8);
  final rowBytes = (colors * bpc * columns + 7) ~/ 8;
  if (predictor == 2) {
    if (bpc != 8) return data;
    final out = Uint8List.fromList(data);
    for (var row = 0; row + rowBytes <= out.length; row += rowBytes) {
      for (var i = bpp; i < rowBytes; i++) {
        out[row + i] = (out[row + i] + out[row + i - bpp]) & 0xff;
      }
    }
    return out;
  }
  final rows = data.length ~/ (rowBytes + 1);
  final out = Uint8List(rows * rowBytes);
  final prev = Uint8List(rowBytes);
  for (var r = 0; r < rows; r++) {
    final type = data[r * (rowBytes + 1)];
    final src = r * (rowBytes + 1) + 1, dst = r * rowBytes;
    for (var i = 0; i < rowBytes; i++) {
      final x = data[src + i];
      final a = i >= bpp ? out[dst + i - bpp] : 0;
      final b = prev[i];
      final c = i >= bpp ? prev[i - bpp] : 0;
      int v;
      switch (type) {
        case 1:
          v = x + a;
        case 2:
          v = x + b;
        case 3:
          v = x + ((a + b) >> 1);
        case 4:
          final p = a + b - c;
          final pa = (p - a).abs(), pb = (p - b).abs(), pc = (p - c).abs();
          v =
              x +
              (pa <= pb && pa <= pc
                  ? a
                  : pb <= pc
                  ? b
                  : c);
        default:
          v = x;
      }
      out[dst + i] = v & 0xff;
    }
    prev.setAll(0, out.sublist(dst, dst + rowBytes));
  }
  return out;
}

/// 已解析的整份 PDF：对象表 + 尾部字典。
class PdfDocumentModel {
  final Map<int, Object?> objects;
  final PdfDict trailer;
  PdfDocumentModel(this.objects, this.trailer);

  Object? resolve(Object? value) {
    var v = value;
    for (var i = 0; i < 32 && v is PdfRef; i++) {
      v = objects[v.id];
    }
    return v;
  }

  bool get encrypted => trailer['Encrypt'] != null;

  int get nextId =>
      (objects.keys.isEmpty ? 0 : objects.keys.reduce(math.max)) + 1;

  PdfRef add(Object? value) {
    final id = nextId;
    objects[id] = value;
    return PdfRef(id);
  }

  static PdfDocumentModel parse(Uint8List bytes) {
    try {
      return _XrefReader(bytes).read();
    } on Object {
      return _XrefReader(bytes).scan();
    }
  }
}

class _Entry {
  final int offset; // type 1：文件偏移；type 2：对象流编号
  final int index; // type 2：对象流内序号；type 1 为 -1
  const _Entry(this.offset, this.index);
}

class _XrefReader {
  final Uint8List b;
  _XrefReader(this.b);
  final entries = <int, _Entry>{};
  PdfDict? trailer;

  PdfDocumentModel read() {
    final at = _lastIndexOf(b, latin1.encode('startxref'));
    if (at < 0) throw const PdfFormatError('缺少 startxref');
    final lexer = _Lexer(b, at + 9);
    var offset = lexer.integer();
    final seen = <int>{};
    while (offset != null &&
        offset > 0 &&
        offset < b.length &&
        seen.add(offset)) {
      final section = _section(offset);
      trailer ??= section;
      final stm = section['XRefStm'];
      if (stm is int && seen.add(stm)) _section(stm);
      final prev = section['Prev'];
      offset = prev is int ? prev : null;
    }
    if (trailer == null || trailer!['Root'] == null || entries.isEmpty) {
      throw const PdfFormatError('xref 无效');
    }
    return _load();
  }

  /// 读一个 xref 段，已有的（更新的）条目不覆盖；返回该段尾部字典。
  PdfDict _section(int offset) {
    final lexer = _Lexer(b, offset);
    if (lexer.keyword('xref')) {
      while (true) {
        lexer.skipWhite();
        if (lexer.keyword('trailer')) break;
        final start = lexer.integer(), count = lexer.integer();
        if (start == null || count == null) {
          throw const PdfFormatError('xref 表损坏');
        }
        for (var i = 0; i < count; i++) {
          final off = lexer.integer();
          lexer.integer();
          final kind = lexer.value();
          if (off == null || kind is! _Keyword) {
            throw const PdfFormatError('xref 表项损坏');
          }
          if (kind.value == 'n' && off > 0) {
            entries.putIfAbsent(start + i, () => _Entry(off, -1));
          }
        }
      }
      final dict = lexer.value();
      if (dict is! PdfDict) throw const PdfFormatError('trailer 损坏');
      return dict;
    }
    // xref 流
    final obj = _objectAt(offset, null);
    final stream = obj.value;
    if (stream is! PdfStream) throw const PdfFormatError('xref 流损坏');
    final dict = stream.dict;
    final data = decodeStream(stream, null);
    if (data == null) throw const PdfFormatError('xref 流过滤器不支持');
    final w = (dict['W'] as List).cast<int>();
    final size = dict['Size'] as int;
    final index = (dict['Index'] as List?)?.cast<int>() ?? [0, size];
    final rowLen = w.fold<int>(0, (n, x) => n + x);
    var pos = 0;
    int field(int width, int fallback) {
      if (width == 0) return fallback;
      var v = 0;
      for (var i = 0; i < width; i++) {
        v = (v << 8) | data[pos++];
      }
      return v;
    }

    for (var k = 0; k + 1 < index.length; k += 2) {
      for (var i = 0; i < index[k + 1]; i++) {
        if (pos + rowLen > data.length) break;
        final type = field(w[0], 1), f2 = field(w[1], 0), f3 = field(w[2], 0);
        final id = index[k] + i;
        if (type == 1 && f2 > 0) entries.putIfAbsent(id, () => _Entry(f2, -1));
        if (type == 2) entries.putIfAbsent(id, () => _Entry(f2, f3));
      }
    }
    final result = pdfDict(dict)..remove('Length');
    return result;
  }

  /// 在偏移处解析“N G obj … endobj”。[lengthOf] 用于解析间接的 /Length。
  ({int id, Object? value}) _objectAt(
    int offset,
    int? Function(PdfRef)? lengthOf,
  ) {
    final lexer = _Lexer(b, offset);
    final id = lexer.integer();
    lexer.integer();
    if (id == null || !lexer.keyword('obj')) {
      throw PdfFormatError('偏移 $offset 处不是对象');
    }
    final value = lexer.value();
    if (value is PdfDict) {
      lexer.skipWhite();
      if (lexer.keyword('stream')) {
        var start = lexer.p;
        if (start < b.length && b[start] == 13) start++;
        if (start < b.length && b[start] == 10) start++;
        var length = value['Length'];
        if (length is PdfRef) length = lengthOf?.call(length);
        int end;
        if (length is int &&
            length >= 0 &&
            start + length <= b.length &&
            _endstreamNear(start + length)) {
          end = start + length;
        } else {
          final found = _indexOf(b, latin1.encode('endstream'), start);
          if (found < 0) throw const PdfFormatError('流未结束');
          end = found;
          // 去掉 endstream 前的换行。
          if (end > start && b[end - 1] == 10) end--;
          if (end > start && b[end - 1] == 13) end--;
        }
        return (
          id: id,
          value: PdfStream(value, Uint8List.sublistView(b, start, end)),
        );
      }
    }
    if (value is _Keyword) throw PdfFormatError('对象 $id 内容无效');
    return (id: id, value: value);
  }

  bool _endstreamNear(int pos) {
    final lexer = _Lexer(b, pos);
    return lexer.keyword('endstream');
  }

  PdfDocumentModel _load() {
    final objects = <int, Object?>{};
    final lengths = <int, int?>{};
    int? lengthOf(PdfRef ref) {
      if (lengths.containsKey(ref.id)) return lengths[ref.id];
      final entry = entries[ref.id];
      int? v;
      if (entry != null && entry.index < 0) {
        try {
          final value = _objectAt(entry.offset, null).value;
          if (value is int) v = value;
        } catch (_) {}
      }
      return lengths[ref.id] = v;
    }

    final streams = <int, List<Object?>>{};
    List<Object?> objStm(int id) => streams.putIfAbsent(id, () {
      final entry = entries[id];
      if (entry == null || entry.index >= 0) return const [];
      final stm = _objectAt(entry.offset, lengthOf).value;
      if (stm is! PdfStream) return const [];
      final data = decodeStream(stm, null);
      if (data == null) return const [];
      final n = stm.dict['N'] as int? ?? 0,
          first = stm.dict['First'] as int? ?? 0;
      final head = _Lexer(data);
      final offsets = <int>[];
      for (var i = 0; i < n; i++) {
        head.integer();
        offsets.add(head.integer() ?? 0);
      }
      return [
        for (final off in offsets)
          () {
            try {
              final v = _Lexer(data, first + off).value();
              return v is _Keyword ? null : v;
            } catch (_) {
              return null;
            }
          }(),
      ];
    });

    for (final e in entries.entries) {
      final entry = e.value;
      try {
        if (entry.index < 0) {
          final parsed = _objectAt(entry.offset, lengthOf);
          objects[e.key] = parsed.value;
        } else {
          final list = objStm(entry.offset);
          if (entry.index < list.length) objects[e.key] = list[entry.index];
        }
      } on PdfFormatError {
        // 个别对象损坏：留空，按 null 处理（与阅读器行为一致）。
      }
    }
    final t = pdfDict(trailer!)
      ..remove('Prev')
      ..remove('XRefStm')
      ..remove('Size')
      ..remove('Type')
      ..remove('W')
      ..remove('Index')
      ..remove('Filter')
      ..remove('DecodeParms');
    return PdfDocumentModel(objects, t);
  }

  /// xref 不可用时整文件扫描对象。
  PdfDocumentModel scan() {
    entries.clear();
    final text = latin1.decode(b);
    final pattern = RegExp(r'(?:^|[\r\n\s])(\d+)\s+(\d+)\s+obj\b');
    for (final m in pattern.allMatches(text)) {
      final id = int.parse(m.group(1)!);
      entries[id] = _Entry(m.start + m.group(0)!.indexOf(m.group(1)!), -1);
    }
    // 对象流中的对象：先读出全部对象流，按其中的编号补录。
    final objects = <int, Object?>{};
    for (final e in entries.entries.toList()) {
      try {
        final v = _objectAt(e.value.offset, null).value;
        objects[e.key] = v;
        if (v is PdfStream && (v.dict['Type'] as PdfName?)?.value == 'ObjStm') {
          final data = decodeStream(v, null);
          if (data == null) continue;
          final n = v.dict['N'] as int? ?? 0,
              first = v.dict['First'] as int? ?? 0;
          final head = _Lexer(data);
          for (var i = 0; i < n; i++) {
            final id = head.integer(), off = head.integer();
            if (id == null || off == null || objects.containsKey(id)) continue;
            try {
              final value = _Lexer(data, first + off).value();
              if (value is! _Keyword) objects[id] = value;
            } catch (_) {}
          }
        }
      } catch (_) {}
    }
    PdfDict? found;
    final at = _lastIndexOf(b, latin1.encode('trailer'));
    if (at >= 0) {
      try {
        final v = _Lexer(b, at + 7).value();
        if (v is PdfDict && v['Root'] != null) found = v;
      } catch (_) {}
    }
    if (found == null) {
      for (final e in objects.entries) {
        final v = e.value;
        if (v is PdfStream &&
            (v.dict['Type'] as PdfName?)?.value == 'XRef' &&
            v.dict['Root'] != null) {
          found = pdfDict(v.dict);
        }
      }
    }
    if (found == null) {
      for (final e in objects.entries) {
        final v = e.value;
        if (v is PdfDict && (v['Type'] as PdfName?)?.value == 'Catalog') {
          found = pdfDict({'Root': PdfRef(e.key)});
        }
      }
    }
    if (found == null) throw const PdfFormatError('找不到文档目录');
    objects.removeWhere(
      (_, v) =>
          v is PdfStream &&
          const {
            'XRef',
            'ObjStm',
          }.contains((v.dict['Type'] as PdfName?)?.value),
    );
    trailer = found;
    final t = pdfDict(found)
      ..remove('Prev')
      ..remove('XRefStm')
      ..remove('Size')
      ..remove('Type')
      ..remove('W')
      ..remove('Index')
      ..remove('Filter')
      ..remove('DecodeParms')
      ..remove('Length');
    return PdfDocumentModel(objects, t);
  }
}

// ---------------- 写出 ----------------

void _writeName(BytesBuilder out, String name) {
  out.addByte(0x2f);
  for (final c in utf8.encode(name)) {
    if (c < 0x21 || c > 0x7e || c == 0x23 || _isDelimiter(c)) {
      out.add(latin1.encode('#${c.toRadixString(16).padLeft(2, '0')}'));
    } else {
      out.addByte(c);
    }
  }
}

String _number(num v) {
  if (v is int) return '$v';
  final d = v.toDouble();
  if (!d.isFinite) return '0';
  if (d == d.roundToDouble() && d.abs() < 1e15) return d.toInt().toString();
  var s = d.toStringAsFixed(6);
  s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  return s == '-0' ? '0' : s;
}

/// 序列化单个值（不含“N 0 obj”包装）。[ref] 用于在写出时改写引用编号。
void writeValue(BytesBuilder out, Object? v, {String Function(PdfRef)? ref}) {
  if (v == null) {
    out.add(latin1.encode('null'));
  } else if (v is bool) {
    out.add(latin1.encode(v ? 'true' : 'false'));
  } else if (v is num) {
    out.add(latin1.encode(_number(v)));
  } else if (v is PdfName) {
    _writeName(out, v.value);
  } else if (v is PdfString) {
    if (v.hex) {
      out.addByte(0x3c);
      for (final c in v.bytes) {
        out.add(latin1.encode(c.toRadixString(16).padLeft(2, '0')));
      }
      out.addByte(0x3e);
    } else {
      out.addByte(0x28);
      for (final c in v.bytes) {
        if (c == 0x28 || c == 0x29 || c == 0x5c) {
          out.addByte(0x5c);
          out.addByte(c);
        } else if (c == 13) {
          out.add(latin1.encode(r'\r'));
        } else {
          out.addByte(c);
        }
      }
      out.addByte(0x29);
    }
  } else if (v is PdfRef) {
    out.add(latin1.encode(ref != null ? ref(v) : '${v.id} ${v.gen} R'));
  } else if (v is List) {
    out.addByte(0x5b);
    for (var i = 0; i < v.length; i++) {
      if (i > 0) out.addByte(0x20);
      writeValue(out, v[i], ref: ref);
    }
    out.addByte(0x5d);
  } else if (v is PdfDict) {
    out.add(latin1.encode('<<'));
    for (final e in v.entries) {
      _writeName(out, e.key);
      out.addByte(0x20);
      writeValue(out, e.value, ref: ref);
    }
    out.add(latin1.encode('>>'));
  } else if (v is PdfStream) {
    throw const PdfFormatError('流只能作为间接对象写出');
  } else {
    throw PdfFormatError('无法写出 ${v.runtimeType}');
  }
}

/// 把文档写成 PDF 1.7：从尾部字典出发只保留可达对象并重新编号，
/// 非流对象打包进对象流，最后写 xref 流。
Uint8List writeDocument(PdfDocumentModel doc) {
  // 可达对象（广度优先，保持稳定顺序）。
  final order = <int>[];
  final seen = <int>{};
  final queue = Queue<Object?>()..add(doc.trailer);
  void visit(Object? v) {
    if (v is PdfRef) {
      if (doc.objects.containsKey(v.id) && seen.add(v.id)) {
        order.add(v.id);
        queue.add(doc.objects[v.id]);
      }
    } else if (v is List) {
      v.forEach(visit);
    } else if (v is PdfDict) {
      v.values.forEach(visit);
    } else if (v is PdfStream) {
      // /Length 写出时按实际数据重算，旧的间接长度对象不再保留。
      for (final e in v.dict.entries) {
        if (e.key != 'Length') visit(e.value);
      }
    }
  }

  while (queue.isNotEmpty) {
    visit(queue.removeFirst());
  }
  final number = <int, int>{
    for (var i = 0; i < order.length; i++) order[i]: i + 1,
  };
  String ref(PdfRef r) => number[r.id] == null ? 'null' : '${number[r.id]} 0 R';

  final out = BytesBuilder(copy: false)
    ..add(latin1.encode('%PDF-1.7\n'))
    ..add([0x25, 0xe2, 0xe3, 0xcf, 0xd3, 0x0a]);
  final offsets = <int, int>{}; // 新编号 → 偏移（type 1）
  final inStream = <int, (int, int)>{}; // 新编号 → (对象流编号, 序号)

  final plain = <int>[];
  for (final old in order) {
    final value = doc.objects[old];
    if (value is PdfStream) {
      final id = number[old]!;
      offsets[id] = out.length;
      final dict = pdfDict(value.dict)..['Length'] = value.data.length;
      out.add(latin1.encode('$id 0 obj\n'));
      writeValue(out, dict, ref: ref);
      out.add(latin1.encode('\nstream\n'));
      out.add(value.data);
      out.add(latin1.encode('\nendstream\nendobj\n'));
    } else {
      plain.add(old);
    }
  }
  var nextId = order.length + 1;
  const perStream = 100;
  for (var start = 0; start < plain.length; start += perStream) {
    final chunk = plain.sublist(
      start,
      math.min(start + perStream, plain.length),
    );
    final streamId = nextId++;
    final body = BytesBuilder(copy: false);
    final head = StringBuffer();
    for (var i = 0; i < chunk.length; i++) {
      final id = number[chunk[i]]!;
      head.write('$id ${body.length} ');
      writeValue(body, doc.objects[chunk[i]], ref: ref);
      body.addByte(0x0a);
      inStream[id] = (streamId, i);
    }
    final headBytes = latin1.encode(head.toString());
    final data = deflate(Uint8List.fromList([...headBytes, ...body.toBytes()]));
    offsets[streamId] = out.length;
    out.add(latin1.encode('$streamId 0 obj\n'));
    writeValue(
      out,
      pdfDict({
        'Type': const PdfName('ObjStm'),
        'N': chunk.length,
        'First': headBytes.length,
        'Filter': const PdfName('FlateDecode'),
        'Length': data.length,
      }),
    );
    out.add(latin1.encode('\nstream\n'));
    out.add(data);
    out.add(latin1.encode('\nendstream\nendobj\n'));
  }
  final xrefId = nextId++;
  final size = nextId;
  final xrefOffset = out.length;
  offsets[xrefId] = xrefOffset;
  final rows = BytesBuilder(copy: false);
  for (var id = 0; id < size; id++) {
    final placed = inStream[id];
    if (id == 0) {
      rows.add([0, 0, 0, 0, 0, 0xff, 0xff]);
    } else if (placed != null) {
      final (sid, index) = placed;
      rows.add([
        2,
        sid >> 24,
        sid >> 16 & 0xff,
        sid >> 8 & 0xff,
        sid & 0xff,
        index >> 8 & 0xff,
        index & 0xff,
      ]);
    } else {
      final off = offsets[id] ?? 0;
      rows.add([
        1,
        off >> 24 & 0xff,
        off >> 16 & 0xff,
        off >> 8 & 0xff,
        off & 0xff,
        0,
        0,
      ]);
    }
  }
  final xrefData = deflate(rows.toBytes());
  final xrefDict = pdfDict({
    'Type': const PdfName('XRef'),
    'Size': size,
    'W': [1, 4, 2],
    'Filter': const PdfName('FlateDecode'),
    'Length': xrefData.length,
  });
  for (final key in ['Root', 'Info', 'ID']) {
    if (doc.trailer[key] != null) xrefDict[key] = doc.trailer[key];
  }
  out.add(latin1.encode('$xrefId 0 obj\n'));
  writeValue(out, xrefDict, ref: ref);
  out.add(latin1.encode('\nstream\n'));
  out.add(xrefData);
  out.add(
    latin1.encode('\nendstream\nendobj\nstartxref\n$xrefOffset\n%%EOF\n'),
  );
  return out.toBytes();
}
