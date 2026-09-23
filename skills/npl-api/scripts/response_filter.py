"""解析接口响应及嵌套报文，仅屏蔽 acceptContent 的值。"""
import json
import re
import xml.etree.ElementTree as ET

MASK = '[已屏蔽]'


class ResponseError(ValueError):
    """只携带安全诊断，不包含响应原文。"""


def decode_json(text):
    """兼容项目已发现的未转义内嵌对象；修复仅作用于解析副本。"""
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        repaired = text
        for _ in range(10):
            changed = False
            for match in re.finditer(r'"\s*:\s*"(?=[{\[])', repaired):
                start = match.end()
                try:
                    _, length = json.JSONDecoder().raw_decode(repaired[start:])
                except json.JSONDecodeError:
                    continue
                end = start + length
                if end < len(repaired) and repaired[end] == '"':
                    repaired = repaired[:start-1] + json.dumps(repaired[start:end], ensure_ascii=False) + repaired[end+1:]
                    changed = True
                    break
            try:
                return json.loads(repaired)
            except json.JSONDecodeError as error:
                if not changed:
                    raise ResponseError(f'JSON 解析失败，位置 {error.pos}；原文未输出') from None
        raise ResponseError('嵌套 JSON 修复超过十次；原文未输出')


def filter_value(value, depth=0):
    """递归保留完整结构，解开 JSON 字符串并屏蔽同名字段。"""
    if depth > 80:
        raise ResponseError('响应嵌套超过八十层；原文未输出')
    if isinstance(value, dict):
        return {key: MASK if key == 'acceptContent' else filter_value(item, depth+1)
                for key, item in value.items()}
    if isinstance(value, list):
        return [filter_value(item, depth+1) for item in value]
    if not isinstance(value, str):
        return value
    stripped = value.strip()
    if stripped.startswith(('{', '[', '"')):
        decoded = decode_json(stripped)
        if decoded == value:
            return value
        return filter_value(decoded, depth+1)
    if stripped.startswith('<') and ('acceptContent' in stripped or stripped.startswith('<?xml')):
        return filter_xml(stripped, depth+1)
    if 'acceptContent' in value or '\\u' in value:
        raise ResponseError('文本包含无法可靠识别的待屏蔽字段或转义序列；原文未输出')
    return value


def filter_xml(text, depth=0):
    """屏蔽 XML 同名元素或属性，其他文字仍递归检查嵌套报文。"""
    if '<!DOCTYPE' in text.upper() or '<!ENTITY' in text.upper():
        raise ResponseError('XML 含不支持的实体声明；原文未输出')
    try:
        root = ET.fromstring(text)
    except ET.ParseError:
        raise ResponseError('XML 解析失败；原文未输出') from None
    def visit(node):
        """逐节点处理，保留尾部文本及非目标属性。"""
        if node.tag.split('}')[-1] == 'acceptContent':
            for child in list(node):
                node.remove(child)
            node.text = MASK
        elif node.text:
            result = filter_value(node.text, depth+1)
            node.text = result if isinstance(result, str) else json.dumps(result, ensure_ascii=False)
        for key, value in list(node.attrib.items()):
            result = MASK if key.split('}')[-1] == 'acceptContent' else filter_value(value, depth+1)
            node.attrib[key] = result if isinstance(result, str) else json.dumps(result, ensure_ascii=False)
        for child in node:
            visit(child)
            if child.tail:
                result = filter_value(child.tail, depth+1)
                child.tail = result if isinstance(result, str) else json.dumps(result, ensure_ascii=False)
    visit(root)
    return ET.tostring(root, encoding='unicode')


def filter_response(raw, require_json=True):
    """所有响应在输出和写文件前经过此入口，禁止回退输出原文。"""
    try:
        text = raw.decode('utf-8-sig') if isinstance(raw, bytes) else raw
    except UnicodeError:
        raise ResponseError('响应不是有效 UTF-8 文本；原文未输出') from None
    if require_json:
        return filter_value(decode_json(text))
    if text.lstrip().startswith('<'):
        return filter_xml(text)
    return filter_value(text)
