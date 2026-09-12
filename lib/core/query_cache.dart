import 'package:http/http.dart' as http;

/// 会话内缓存：五分钟有效，最多 128 条 / 64 MiB，退出应用即释放。
/// 只接收成功且已验证的响应，不落盘，不包含请求头或 JWT。
class QueryCache {
  final Duration ttl;
  final int maxBytes, maxEntries;
  final DateTime Function() now;
  final _items = <String, _Entry>{};
  int _bytes = 0;
  QueryCache({
    this.ttl = const Duration(minutes: 5),
    this.maxBytes = 64 * 1024 * 1024,
    this.maxEntries = 128,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;
  http.Response? get(String key) {
    final entry = _items.remove(key);
    if (entry == null) return null;
    if (!now().isBefore(entry.expires)) {
      _bytes -= entry.response.bodyBytes.length;
      return null;
    }
    _items[key] = entry;
    return entry.response;
  }

  void put(String key, http.Response response) {
    remove(key);
    if (response.bodyBytes.length > maxBytes) return;
    // 去除原响应持有的 request，缓存不保留认证头。
    final saved = http.Response.bytes(
      response.bodyBytes,
      response.statusCode,
      headers: response.headers,
    );
    _items[key] = _Entry(saved, now().add(ttl));
    _bytes += response.bodyBytes.length;
    while (_bytes > maxBytes || _items.length > maxEntries) {
      remove(_items.keys.first);
    }
  }

  void remove(String key) {
    final value = _items.remove(key);
    if (value != null) _bytes -= value.response.bodyBytes.length;
  }

  void clear() {
    _items.clear();
    _bytes = 0;
  }
}

class _Entry {
  final http.Response response;
  final DateTime expires;
  _Entry(this.response, this.expires);
}
