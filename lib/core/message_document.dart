import 'dart:convert';
import 'package:xml/xml.dart';

/// 可独立解析的字段节点。保留原始值，专注时无需向后台重新请求。
class MessageNode {
  final String name, path;
  final Object? value;
  const MessageNode(this.name, this.path, this.value);
  String get source {
    final data = value;
    if (data is XmlNode) return data.toXmlString();
    if (data is String) return data;
    return const JsonEncoder.withIndent('  ').convert(data);
  }

  List<MessageNode> get children {
    final data = value;
    if (data is Map) {
      return data.entries
          .map(
            (e) => MessageNode(
              '${e.key}',
              '$path/${_escape('${e.key}')}',
              e.value,
            ),
          )
          .toList();
    }
    if (data is List) {
      return [
        for (var i = 0; i < data.length; i++)
          MessageNode('[$i]', '$path/$i', data[i]),
      ];
    }
    if (data is XmlDocument) {
      return [
        MessageNode(
          data.rootElement.name.qualified,
          '$path/${data.rootElement.name.qualified}',
          data.rootElement,
        ),
      ];
    }
    if (data is XmlElement) {
      final nodes = <MessageNode>[
        for (final a in data.attributes)
          MessageNode(
            '@${a.name.qualified}',
            '$path/@${a.name.qualified}',
            a.value,
          ),
      ];
      var index = 0;
      for (final child in data.children) {
        if (child is XmlElement) {
          nodes.add(
            MessageNode(
              child.name.qualified,
              '$path/${child.name.qualified}[${index++}]',
              child,
            ),
          );
        } else if (child is XmlText || child is XmlCDATA) {
          final text = child.value ?? '';
          if (text.trim().isNotEmpty) {
            nodes.add(MessageNode('#text', '$path/#text[${index++}]', text));
          }
        }
      }
      return nodes;
    }
    return const [];
  }

  bool get isBranch => children.isNotEmpty;
  String get summary {
    final data = value;
    if (data is Map) return '{ ${data.length} 个字段 }';
    if (data is List) return '[ ${data.length} 个元素 ]';
    if (data is XmlDocument) return 'XML 文档';
    if (data is XmlElement) {
      return '<${data.name.qualified}> · ${children.length} 个节点';
    }
    final text = data == null ? 'null' : '$data';
    return text.length > 180 ? '${text.substring(0, 180)}…' : text;
  }

  /// XML 叶元素优先专注其文本/CDATA，方便直接解析内嵌 JSON 或 XML。
  Object? get focusValue {
    final data = value;
    if (data is XmlElement && data.childElements.isEmpty) return data.innerText;
    return data;
  }

  static String _escape(String value) =>
      value.replaceAll('~', '~0').replaceAll('/', '~1');
}

class MessageDocument {
  final String format, source;
  final MessageNode root;
  final String? error;
  const MessageDocument(this.format, this.source, this.root, [this.error]);
  bool get structured => format != 'text';
}

/// 从 start 处的 { 或 [ 开始按 JSON 词法做括号配平（尊重字符串与转义），
/// 返回配对闭合符的下标；配平失败返回 -1。
int _jsonBraceEnd(String s, int start) {
  var depth = 0, i = start;
  var inString = false, escaped = false;
  while (i < s.length) {
    final c = s[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (c == r'\') {
        escaped = true;
      } else if (c == '"') {
        inString = false;
      }
    } else {
      if (c == '"') {
        inString = true;
      } else if (c == '{' || c == '[') {
        depth++;
      } else if (c == '}' || c == ']') {
        depth--;
        if (depth == 0) return i;
      }
    }
    i++;
  }
  return -1;
}

/// 修复服务端把 JSON 原文未转义直接嵌进字符串值的非法 JSON，
/// 如 {"reqData":"{...}"}：找到 "key":"{ 形态的嵌入点，括号配平后整段转义为合法字符串。
/// 每次修复后重新扫描，最多处理 10 处；原文不会被修改，仅用于解析。
String repairEmbeddedJson(String input) {
  var text = input;
  final pattern = RegExp(r'"\s*:\s*"(?=[{\[])');
  for (var n = 0; n < 10; n++) {
    final match = pattern.firstMatch(text);
    if (match == null) break;
    final quote = match.end - 1; // 值的开头引号
    final end = _jsonBraceEnd(text, match.end);
    if (end < 0 || end + 1 >= text.length || text[end + 1] != '"') break;
    text = text.replaceRange(
      quote,
      end + 2,
      jsonEncode(text.substring(match.end, end + 1)),
    );
  }
  return text;
}

/// 自动识别 JSON/XML；显式选择格式时返回解析错误，原文始终可查看。
MessageDocument parseMessage(Object? input, {String mode = 'auto'}) {
  final raw = MessageNode('根节点', '', input).source;
  if (mode == 'text') {
    return MessageDocument('text', raw, MessageNode('文本', '', raw));
  }
  Object? data = input;
  if (data is XmlNode && mode != 'json') {
    return MessageDocument('xml', raw, MessageNode('根节点', '', data));
  }
  if ((data is Map || data is List) && mode != 'xml') {
    return MessageDocument('json', raw, MessageNode('根节点', '', data));
  }
  if (mode != 'xml') {
    try {
      data = jsonDecode(raw);
      // 字符串字段可能包裹转义后的 JSON，仅自动解开有限层数避免异常输入循环。
      for (var i = 0; i < 3 && data is String; i++) {
        final value = data.trim();
        if (mode == 'auto' && value.startsWith('<')) {
          return MessageDocument(
            'xml',
            raw,
            MessageNode('根节点', '', XmlDocument.parse(value)),
          );
        }
        if (!value.startsWith('{') && !value.startsWith('[')) break;
        data = jsonDecode(value);
      }
      return MessageDocument('json', raw, MessageNode('根节点', '', data));
    } catch (error) {
      // 服务端常见缺陷：把 JSON 原文未转义嵌进字符串值（如 reqData）。
      // 修复后再解析一次，结构化视图不受影响，原文仍按 source 原样展示。
      if (mode == 'auto') {
        final repaired = repairEmbeddedJson(raw);
        if (repaired != raw) {
          try {
            return MessageDocument(
              'json',
              raw,
              MessageNode('根节点', '', jsonDecode(repaired)),
            );
          } catch (_) {}
        }
      }
      if (mode == 'json') {
        return MessageDocument(
          'text',
          raw,
          MessageNode('文本', '', raw),
          'JSON 解析失败：$error',
        );
      }
    }
  }
  if (mode != 'json') {
    try {
      return MessageDocument(
        'xml',
        raw,
        MessageNode('根节点', '', XmlDocument.parse(raw)),
      );
    } catch (error) {
      if (mode == 'xml') {
        return MessageDocument(
          'text',
          raw,
          MessageNode('文本', '', raw),
          'XML 解析失败：$error',
        );
      }
    }
  }
  return MessageDocument('text', raw, MessageNode('文本', '', raw));
}

/// 字段名和内容关键字同时过滤；返回匹配节点及路径，不改动原报文结构。
List<MessageNode> searchMessage(
  MessageNode root, {
  String key = '',
  String keyword = '',
}) {
  final result = <MessageNode>[], pending = <MessageNode>[root];
  final keyQuery = key.toLowerCase(), valueQuery = keyword.toLowerCase();
  while (pending.isNotEmpty) {
    final node = pending.removeLast(), children = node.children;
    final value = children.isEmpty
        ? node.source
        : node.value is XmlElement
        ? (node.value as XmlElement).innerText
        : '';
    if (node.name.toLowerCase().contains(keyQuery) &&
        (valueQuery.isEmpty || value.toLowerCase().contains(valueQuery))) {
      result.add(node);
    }
    pending.addAll(children.reversed);
  }
  return result;
}
