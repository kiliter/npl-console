import 'dart:convert';
import 'package:flutter/foundation.dart' hide Category;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'contracts.dart';
import 'jwt_signer.dart';
import 'query_cache.dart';
import 'key_vault.dart';

/// 内存接口记录，绝不记录认证头、密钥或文件字节。
class CallLog {
  final DateTime time = DateTime.now();
  final String url, requestBody;
  final bool binary;
  String state = '请求中', response = '';
  int? status;
  CallLog(this.url, this.requestBody, this.binary);
  String get detail =>
      '时间：$time\nURL：$url\n方法：POST\n'
      'Content-Type：${binary ? 'application/x-www-form-urlencoded' : 'application/json'}\n'
      '认证：kkk / agAuthorization（不展示凭据）\n\n请求：\n$requestBody\n\n'
      '状态：$state / HTTP ${status ?? '—'}\n响应：\n$response';
}

/// 业务状态集中管理；视图与平台 I/O 分离，桌面及手机共用只读查询链路。
class MaintenanceController extends ChangeNotifier {
  static const obsEndpoint = '/test/un_look';
  final http.Client Function() clientFactory;
  final String Function()? testToken;
  ConnectionSettings settings = const ConnectionSettings();
  JwtSigner? signer;
  final KeyVault keyVault;
  bool keyPersisted = false;
  int _keyRevision = 0;
  List<Record> works = [], linkedRecords = [];
  List<Asset> assets = [];
  List<GalleryItem> gallery = [];
  final QueryCache cache = QueryCache();
  final Map<String, Future<http.Response>> _pending = {};
  int cacheHits = 0;
  Record? work;
  Asset? asset;
  Uint8List? bytes;
  String contentType = '', message = '设置服务地址并导入密钥库，开始查询。';
  Category category = Category.work;
  final List<CallLog> logs = [];
  final List<String> failures = [];
  bool busy = false, querying = false, error = false;
  int completed = 0, total = 0, _generation = 0;
  http.Client? _client;
  MaintenanceController({
    http.Client Function()? clientFactory,
    this.testToken,
    this.keyVault = const KeyVault(),
  }) : clientFactory = clientFactory ?? http.Client.new;

  Future<void> restore() async {
    final revision = _keyRevision;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (revision != _keyRevision) return;
      final raw = prefs.getString('connection');
      if (raw != null) {
        settings = ConnectionSettings.fromJson(jsonDecode(raw) as Record);
      }
    } catch (_) {
      message = '无法读取旧设置，请重新配置服务地址。';
    }
    try {
      final saved = await keyVault.read();
      if (revision != _keyRevision) return;
      signer = saved;
      keyPersisted = saved != null;
      if (saved != null) message = '已从系统安全存储恢复密钥，可直接查询。';
    } catch (_) {
      if (revision != _keyRevision) return;
      error = true;
      message = '无法读取系统安全存储中的密钥，请解锁设备或在设置中重试；原密钥不会被删除。';
    }
    notifyListeners();
  }

  Future<void> configure(ConnectionSettings next, JwtSigner? key) async {
    next.validate();
    _keyRevision++;
    if (key != null) await keyVault.write(key);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('connection', jsonEncode(next.toJson()));
    _start();
    cache.clear();
    cacheHits = 0;
    settings = next;
    signer = key;
    keyPersisted = key != null;
    works = [];
    work = null;
    linkedRecords = [];
    assets = [];
    category = Category.work;
    busy = false;
    message = key == null ? '设置已保存，请导入密钥库。' : '设置已保存，密钥已存入系统安全存储，下次启动自动恢复。';
    notifyListeners();
  }

  /// 用户主动移除时先删除安全条目，再停止请求并释放当前签名器。
  Future<void> removeStoredKey() async {
    _keyRevision++;
    await keyVault.delete();
    _start();
    signer = null;
    keyPersisted = false;
    cache.clear();
    cacheHits = 0;
    busy = false;
    status('已移除保存的密钥；原始密钥库文件未修改。');
  }

  /// 发起新操作即终止前一条 HTTP 连接，并以代次阻止过期结果覆盖界面。
  int _start() {
    _generation++;
    _client?.close();
    _client = clientFactory();
    busy = true;
    querying = false;
    error = false;
    bytes = null;
    asset = null;
    contentType = '';
    gallery = [];
    return _generation;
  }

  void cancel() {
    _generation++;
    _client?.close();
    _client = null;
    busy = false;
    for (final item in gallery) {
      if (item.loading) {
        item.loading = false;
        item.error = '已取消读取，可重试';
      }
    }
    final wasQuery = querying;
    querying = false;
    message = wasQuery ? '查询已取消，保留 $completed / $total 个已完成月份的结果。' : '文件读取已取消。';
    notifyListeners();
  }

  void reset() {
    cancel();
    works = [];
    work = null;
    assets = [];
    gallery = [];
    linkedRecords = [];
    bytes = null;
    asset = null;
    category = Category.work;
    message = '已重置，请输入查询条件。';
    completed = total = 0;
    failures.clear();
    error = false;
    notifyListeners();
  }

  /// 刷新入口显式失效缓存，日常分类切换继续复用已查到的数据。
  void clearCache() {
    cache.clear();
    cacheHits = 0;
    status('会话缓存已清空，下次查询将重新请求接口。');
  }

  String _cacheKey(String endpoint, Record body, bool binary) {
    final keys = body.keys.toList()..sort();
    return jsonEncode([
      settings.toJson(),
      endpoint,
      binary,
      {for (final key in keys) key: body[key]},
    ]);
  }

  Future<http.Response> request(
    String endpoint,
    Record body,
    int ticket, {
    bool binary = false,
    bool forceRefresh = false,
  }) async {
    if (![
      ...Category.values.map((type) => type.endpoint),
      obsEndpoint,
    ].contains(endpoint)) {
      throw const FormatException('拒绝调用非查询接口');
    }
    if (ticket != _generation) throw const _Cancelled();
    final key = _cacheKey(endpoint, body, binary);
    if (forceRefresh) cache.remove(key);
    final saved = forceRefresh ? null : cache.get(key);
    if (saved != null) {
      cacheHits++;
      return saved;
    }
    final pendingKey = '$ticket:$key';
    final running = _pending[pendingKey];
    if (running != null) return running;
    final future = _networkRequest(endpoint, body, ticket, binary: binary);
    _pending[pendingKey] = future;
    try {
      final response = await future;
      if (ticket != _generation) throw const _Cancelled();
      if (!binary) {
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        if (decoded is! List || decoded.any((item) => item is! Map)) {
          throw const FormatException('接口未返回预期数组，请查看接口记录');
        }
      } else if (response.bodyBytes.isEmpty) {
        throw const FormatException('OBS 返回空文件');
      }
      cache.put(key, response);
      return response;
    } finally {
      _pending.remove(pendingKey);
    }
  }

  /// 出口白名单同时限制方法和路径；客户端使用原生 HTTP，不经过 WebView CORS。
  Future<http.Response> _networkRequest(
    String endpoint,
    Record body,
    int ticket, {
    bool binary = false,
  }) async {
    if (![
      ...Category.values.map((type) => type.endpoint),
      obsEndpoint,
    ].contains(endpoint)) {
      throw const FormatException('拒绝调用非查询接口');
    }
    settings.validate();
    if (signer == null && testToken == null) {
      throw const FormatException('请先在设置中导入 JKS 或 PKCS#8 私钥');
    }
    if (ticket != _generation) throw const _Cancelled();
    final token =
        testToken?.call() ?? signer!.token(settings.loginNo, settings.channel);
    final uri = Uri.parse(
      '${settings.baseUrl.replaceAll(RegExp(r'/+$'), '')}$endpoint',
    );
    final payload = binary
        ? body.entries
              .map(
                (e) =>
                    '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent('${e.value}')}',
              )
              .join('&')
        : jsonEncode(body);
    final log = CallLog(uri.toString(), payload, binary);
    logs.insert(0, log);
    notifyListeners();
    final client = _client!;
    try {
      final request = http.Request('POST', uri)
        ..followRedirects = false
        ..headers.addAll({
          'Content-Type': binary
              ? 'application/x-www-form-urlencoded;charset=UTF-8'
              : 'application/json',
          'kkk': token,
          'agAuthorization': token,
        })
        ..body = payload;
      final response = await http.Response.fromStream(
        await client.send(request),
      ).timeout(const Duration(seconds: 60));
      log.status = response.statusCode;
      log.response = binary && response.statusCode == 200
          ? '二进制文件 · ${response.bodyBytes.length} 字节 · ${response.headers['content-type'] ?? '未声明类型'}'
          : utf8.decode(response.bodyBytes, allowMalformed: true);
      if (ticket != _generation) throw const _Cancelled();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw FormatException('HTTP ${response.statusCode}：$endpoint，请查看接口记录');
      }
      log.state = '成功';
      return response;
    } catch (exception) {
      log.state = ticket != _generation ? '已取消' : '失败';
      if (log.response.isEmpty) log.response = '请求未完成：${exception.runtimeType}';
      if (ticket != _generation) throw const _Cancelled();
      rethrow;
    } finally {
      notifyListeners();
    }
  }

  Future<List<Record>> _list(
    String endpoint,
    Record body,
    int ticket, {
    bool forceRefresh = false,
  }) async {
    final response = await request(
      endpoint,
      body,
      ticket,
      forceRefresh: forceRefresh,
    );
    final value = jsonDecode(utf8.decode(response.bodyBytes));
    if (value is! List || value.any((item) => item is! Map)) {
      throw const FormatException('接口未返回预期数组，请查看接口记录');
    }
    return value.map((item) => Map<String, dynamic>.from(item as Map)).toList();
  }

  /// 范围内逐月请求，部分失败保留成功月份，首屏始终要求用户明确选择工单。
  Future<void> search(
    String field,
    String value,
    String start,
    String end,
    bool range,
  ) async {
    List<Record> bodies;
    try {
      bodies = queryBodies(field, value, start, end, range);
      settings.validate();
      if (signer == null && testToken == null) {
        throw const FormatException('请先导入密钥库');
      }
    } catch (exception) {
      _fail(exception);
      return;
    }
    final ticket = _start();
    works = [];
    work = null;
    assets = [];
    linkedRecords = [];
    category = Category.work;
    total = bodies.length;
    completed = 0;
    querying = true;
    failures.clear();
    for (final body in bodies) {
      if (ticket != _generation) return;
      final month = '${body['opMonth'] ?? '单据号'}';
      message = '正在查询 $month · $completed / $total';
      notifyListeners();
      try {
        final result = await _list(Category.work.endpoint, body, ticket);
        if (ticket != _generation) return;
        final known = works.map((row) => '${row['caseNo']}').toSet();
        for (final row in result) {
          if (known.add('${row['caseNo']}')) works.add(row);
        }
      } catch (exception) {
        if (ticket != _generation) return;
        failures.add('$month：${_errorText(exception)}');
      }
      completed++;
      notifyListeners();
    }
    if (ticket != _generation) return;
    busy = querying = false;
    error = failures.isNotEmpty;
    message = '查询完成 · ${works.length} 份工单 · ${failures.length} 个查询失败。请先选择工单。';
    notifyListeners();
  }

  void chooseWork(Record selected) {
    _start();
    work = selected;
    assets = [];
    linkedRecords = [];
    category = Category.work;
    busy = false;
    message = '已选择工单 ${selected['caseNo']}';
    notifyListeners();
  }

  void showWorks() {
    _start();
    work = null;
    assets = [];
    linkedRecords = [];
    category = Category.work;
    busy = false;
    message = '共 ${works.length} 份工单，请选择工单查看详情。';
    notifyListeners();
  }

  Future<void> selectCategory(
    Category type, {
    bool forceRefresh = false,
  }) async {
    if (busy && !querying && category == type && !forceRefresh) return;
    if (work == null) {
      message = '请先在工单列表中选择一份工单。';
      notifyListeners();
      return;
    }
    final ticket = _start();
    category = type;
    linkedRecords = [];
    assets = [];
    if (type == Category.work) {
      message = '当前工单详情';
      busy = false;
      notifyListeners();
      return;
    }
    message = '正在查询${type.label}…';
    notifyListeners();
    try {
      final rows = await _list(
        type.endpoint,
        {'caseNo': work!['caseNo'], 'opMonth': work!['opMonth']},
        ticket,
        forceRefresh: forceRefresh,
      );
      if (ticket != _generation) return;
      linkedRecords = rows;
      assets = Asset.fromRecords(type, rows, work!);
      if (assets.isEmpty) {
        busy = false;
        message = '当前工单没有${type.label}';
        notifyListeners();
        return;
      }
      if (type == Category.picture || type == Category.sign) {
        await loadGallery(forceRefresh: forceRefresh);
      } else {
        await loadAsset(assets.first, forceRefresh: forceRefresh);
      }
    } catch (exception) {
      if (ticket == _generation) _fail(exception);
    }
  }

  Future<void> showPdf() => work == null
      ? Future.value()
      : loadAsset(Asset.fromRecords(Category.work, [], work!).first);
  Future<void> loadAsset(Asset next, {bool forceRefresh = false}) async {
    if (busy && asset?.name == next.name && !forceRefresh) return;
    if (work == null) return;
    final ticket = _start();
    asset = next;
    message = '正在从 OBS 读取 ${next.name}…';
    notifyListeners();
    try {
      final response = await request(
        obsEndpoint,
        next.obsBody(work!, settings),
        ticket,
        binary: true,
        forceRefresh: forceRefresh,
      );
      if (ticket != _generation) return;
      if (response.bodyBytes.isEmpty) throw const FormatException('OBS 返回空文件');
      try {
        contentType = detectType(response.bodyBytes, next.kind);
      } catch (_) {
        cache.remove(
          _cacheKey(obsEndpoint, next.obsBody(work!, settings), true),
        );
        rethrow;
      }
      bytes = response.bodyBytes;
      busy = false;
      message =
          '读取完成 · ${next.name} · ${(bytes!.length / 1024).toStringAsFixed(1)} KB';
      notifyListeners();
    } catch (exception) {
      if (ticket == _generation) _fail(exception);
    }
  }

  /// 图片及签字全部放入同一画廊，最多三个并行读取，单个失败不影响其它图片。
  Future<void> loadGallery({bool forceRefresh = false}) async {
    if (work == null) return;
    final ticket = _start(), selectedWork = work!;
    final items = assets.map(GalleryItem.new).toList();
    gallery = items;
    var next = 0, done = 0;
    message = '正在读取图片 · 0 / ${items.length}';
    notifyListeners();
    Future<void> worker() async {
      while (next < items.length && ticket == _generation) {
        final item = items[next++];
        await _readGalleryItem(item, selectedWork, ticket, forceRefresh);
        if (ticket != _generation) return;
        done++;
        message = '正在读取图片 · $done / ${items.length}';
        notifyListeners();
      }
    }

    await Future.wait(
      List.generate(items.length < 3 ? items.length : 3, (_) => worker()),
    );
    if (ticket != _generation) return;
    busy = false;
    final failed = items.where((item) => item.error != null).length;
    message =
        '图片已加载 ${items.length - failed} / ${items.length} 份${failed == 0 ? '' : ' · $failed 份失败，可单独重试'}';
    notifyListeners();
  }

  Future<void> _readGalleryItem(
    GalleryItem item,
    Record selectedWork,
    int ticket,
    bool forceRefresh,
  ) async {
    try {
      final body = item.asset.obsBody(selectedWork, settings);
      final response = await request(
        obsEndpoint,
        body,
        ticket,
        binary: true,
        forceRefresh: forceRefresh,
      );
      if (ticket != _generation) return;
      item.bytes = response.bodyBytes;
      item.type = detectType(item.bytes!, 'image');
      if (item.type != 'image') item.error = '文件不是支持的图片格式，可下载后查看';
    } catch (exception) {
      if (ticket != _generation) return;
      item.error = _errorText(exception);
    } finally {
      if (ticket == _generation) item.loading = false;
    }
  }

  Future<void> retryImage(GalleryItem item) async {
    if (work == null || item.loading) return;
    item.loading = true;
    item.error = null;
    final ticket = _generation;
    _client ??= clientFactory();
    notifyListeners();
    await _readGalleryItem(item, work!, ticket, true);
    if (ticket == _generation) notifyListeners();
  }

  void _fail(Object exception) {
    busy = querying = false;
    error = true;
    message = _errorText(exception);
    notifyListeners();
  }

  String _errorText(Object exception) => exception is FormatException
      ? exception.message
      : '请求失败（${exception.runtimeType}），请检查网络、服务地址或查看接口记录。';
  void status(String value, {bool isError = false}) {
    message = value;
    error = isError;
    notifyListeners();
  }

  @override
  void dispose() {
    _generation++;
    _keyRevision++;
    _client?.close();
    cache.clear();
    super.dispose();
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}

/// 单张图片状态，失败与加载状态均按文件独立记录。
class GalleryItem {
  final Asset asset;
  Uint8List? bytes;
  String type = 'image';
  String? error;
  bool loading = true;
  GalleryItem(this.asset);
}
