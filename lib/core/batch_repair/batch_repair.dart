import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' hide Category;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../contracts.dart';
import '../maintenance_controller.dart';
import '../pdf_editor/pdf_engine.dart';
import 'pdf_optimizer.dart';
import 'repair_rules.dart';

/// 订单号：CRM 受理流水，2 开头的 18 位数字。
final orderNumberPattern = RegExp(r'^2\d{17}$');

/// 从任意文本里取出订单号（去重，保持顺序）。
List<String> extractOrderNumbers(String text) {
  final seen = <String>{};
  return [
    for (final m in RegExp(r'(?<!\d)2\d{17}(?!\d)').allMatches(text))
      if (seen.add(m.group(0)!)) m.group(0)!,
  ];
}

String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

String _now() => DateTime.now().toIso8601String();

String _stamp([DateTime? time]) {
  final t = time ?? DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}';
}

/// 含当月在内往前 [count] 个月（YYYYMM，从旧到新）。
List<String> recentMonths(int count, [DateTime? today]) {
  final t = today ?? DateTime.now();
  final index = t.year * 12 + t.month - 1;
  return [
    for (var i = index - count + 1; i <= index; i++)
      '${(i ~/ 12).toString().padLeft(4, '0')}${(i % 12 + 1).toString().padLeft(2, '0')}',
  ];
}

/// 追加写 JSONL：串行、每行落盘后再写下一行，崩溃时最多丢最后一行。
class JsonlLog {
  final List<File> files;
  Future<void> _tail = Future.value();
  JsonlLog(this.files);

  Future<void> write(String event, [Map<String, Object?> fields = const {}]) {
    final line = '${jsonEncode({'time': _now(), 'event': event, ...fields})}\n';
    return _tail = _tail.then((_) async {
      for (final file in files) {
        try {
          await file.parent.create(recursive: true);
          await file.writeAsString(line, mode: FileMode.append, flush: true);
        } catch (_) {
          // 日志写入失败不影响流程。
        }
      }
    });
  }
}

enum BatchOrderStatus {
  pending('等待'),
  running('处理中'),
  repaired('可上传'),
  ok('无需修补'),
  unresolved('无法补齐'),
  notFound('未查到单据'),
  failed('失败');

  const BatchOrderStatus(this.label);
  final String label;
}

class BatchDocument {
  final Record work;
  final Uint8List bytes;
  final RepairDocument analysis;
  const BatchDocument(this.work, this.bytes, this.analysis);
  String get caseNo => '${work['caseNo']}';
  String get opTime => '${work['opTime'] ?? work['createTime'] ?? ''}';
}

class BatchOrder {
  final String order;
  BatchOrderStatus status = BatchOrderStatus.pending;
  String stage = '';
  String message = '';
  final List<String> failures = [];
  BatchDocument? target;
  List<BatchDocument> history = [];
  List<RepairItem> items = [];
  final Set<String> selected = {};

  /// 修复后、压缩前的字节（预览“修复后”用这份也可以，压缩后渲染一致）。
  Uint8List? repaired;
  OptimizeResult? output;
  String? outputPath;
  List<String> problems = [];
  double? renderDiff;

  /// 生成修复件的代次：勾选变化后重新生成，旧结果作废。
  int revision = 0;
  BatchOrder(this.order);

  bool get uploadable =>
      status == BatchOrderStatus.repaired &&
      output != null &&
      outputPath != null &&
      problems.isEmpty &&
      output!.fits;
  String get outputName => '${target?.caseNo}-$order.pdf';
  List<RepairItem> get fixable => [
    for (final i in items)
      if (i.fixable) i,
  ];
}

enum UploadFileStatus {
  ready('待上传'),
  blocked('不能上传'),
  skipped('无需上传'),
  uploading('上传中'),
  uploaded('已上传'),
  failed('失败'),
  cancelled('未上传');

  const UploadFileStatus(this.label);
  final String label;
}

class UploadFile {
  final BatchOrder order;
  UploadFileStatus status = UploadFileStatus.blocked;
  String reason = '';
  String result = '';
  String online = '';
  Record target = const {};
  String file = '';
  int size = 0;
  String sha = '';
  String backup = '';
  String backupSha = '';
  int backupSize = 0;
  int? httpStatus;
  int? durationMs;
  UploadFile(this.order);
  String get caseNo => order.target?.caseNo ?? '';
}

enum UploadRunState {
  preparing,
  ready,
  blocked,
  uploading,
  done,
  partial,
  stopped,
}

/// 一次上传批次：准备（备份）→ 确认 → 逐个上传 → 回读。
class UploadRun {
  final String id;
  final Directory dir;
  final JsonlLog log;
  final List<UploadFile> files;
  UploadRunState state = UploadRunState.preparing;
  bool stopRequested = false;
  String phrase = '';
  UploadRun(this.id, this.dir, this.log, this.files);
  File get logFile => File('${dir.path}/upload.jsonl');
  Directory get backups => Directory('${dir.path}/backups');
  List<UploadFile> get ready => [
    for (final f in files)
      if (f.status == UploadFileStatus.ready) f,
  ];
  int count(UploadFileStatus s) => files.where((f) => f.status == s).length;
}

/// 已上传成功（回读一致）的单据：单据号 → 记录。
typedef UploadedRecord = ({
  String batch,
  String time,
  String sha,
  String order,
});

class BatchRepairSession extends ChangeNotifier {
  final MaintenanceController controller;
  final PdfEditEngine engine;

  /// 工作根目录（默认“下载/单据批量修复”）；测试可注入。
  final Future<Directory> Function() rootProvider;
  final int months;
  final int concurrency;
  BatchRepairSession({
    required this.controller,
    PdfEditEngine? engine,
    Future<Directory> Function()? rootProvider,
    this.months = 3,
    this.concurrency = 2,
  }) : engine = engine ?? PdfEditEngine(),
       rootProvider = rootProvider ?? _defaultRoot;

  static Future<Directory> _defaultRoot() async {
    final downloads = await getDownloadsDirectory();
    final base = downloads ?? await getApplicationSupportDirectory();
    return Directory('${base.path}/单据批量修复');
  }

  final List<BatchOrder> orders = [];
  Directory? batchDir;
  JsonlLog? _repairLog;
  bool running = false;
  UploadRun? upload;
  http.Client? _client;
  bool _disposed = false;
  int revision = 0;

  http.Client get client => _client ??= controller.clientFactory();

  void _changed() {
    if (_disposed) return;
    revision++;
    notifyListeners();
  }

  File get historyFile => File('${batchDir!.parent.path}/上传历史.jsonl');

  // ---------------- 修复 ----------------

  /// 开始一批：建立工作目录，按 [concurrency] 并行处理各订单。
  Future<void> start(List<String> numbers) async {
    if (running) return;
    final unique = <String>[];
    for (final n in numbers) {
      final v = n.trim();
      if (orderNumberPattern.hasMatch(v) && !unique.contains(v)) unique.add(v);
    }
    if (unique.isEmpty) return;
    final root = await rootProvider();
    batchDir = Directory('${root.path}/${_stamp()}');
    await Directory('${batchDir!.path}/originals').create(recursive: true);
    await Directory('${batchDir!.path}/output').create(recursive: true);
    _repairLog = JsonlLog([File('${batchDir!.path}/repair.jsonl')]);
    orders
      ..clear()
      ..addAll(unique.map(BatchOrder.new));
    upload = null;
    running = true;
    _changed();
    await _repairLog!.write('batch_start', {
      'orders': unique,
      'months': recentMonths(months),
    });
    final queue = List.of(orders);
    Future<void> worker() async {
      while (queue.isNotEmpty && !_disposed) {
        await _process(queue.removeAt(0));
      }
    }

    await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);
    running = false;
    await _writeReport();
    await _repairLog!.write('batch_end', {
      for (final s in BatchOrderStatus.values)
        s.name: orders.where((o) => o.status == s).length,
    });
    _changed();
  }

  /// 手动重试一个失败（或任意）订单：从查询开始重新处理。
  Future<void> retry(BatchOrder order) async {
    if (order.status == BatchOrderStatus.running) return;
    await _process(order);
    await _writeReport();
    _changed();
  }

  Future<void> _process(BatchOrder o) async {
    o
      ..status = BatchOrderStatus.running
      ..message = ''
      ..failures.clear()
      ..target = null
      ..history = []
      ..items = []
      ..selected.clear()
      ..repaired = null
      ..output = null
      ..outputPath = null
      ..problems = []
      ..renderDiff = null;
    o.revision++;
    _changed();
    try {
      o.stage = '查询近 $months 个月单据';
      _changed();
      final works = <String, Record>{};
      for (final month in recentMonths(months)) {
        try {
          for (final row in await controller.batchQueryMonth(
            o.order,
            month,
            client,
          )) {
            if ('${row['sysAccept']}' == o.order &&
                '${row['caseNo'] ?? ''}'.isNotEmpty) {
              works['${row['caseNo']}'] = row;
            }
          }
        } catch (e) {
          o.failures.add('$month：${_error(e)}');
        }
      }
      String key(Record r) =>
          '${r['opTime'] ?? ''}|${r['createTime'] ?? ''}|${r['caseNo']}';
      final sorted = works.values.toList()
        ..sort((a, b) => key(b).compareTo(key(a)));
      await _repairLog?.write('query', {
        'order': o.order,
        'works': [
          for (final w in sorted)
            {'caseNo': w['caseNo'], 'opTime': w['opTime']},
        ],
        'failures': o.failures,
      });
      if (sorted.isEmpty) {
        o.status = o.failures.isEmpty
            ? BatchOrderStatus.notFound
            : BatchOrderStatus.failed;
        o.message = o.failures.isEmpty
            ? '近 $months 个月没有查到该订单号的单据'
            : '查询失败，请检查网络或接口记录后重试';
        return;
      }
      final docs = <BatchDocument>[];
      for (var i = 0; i < sorted.length; i++) {
        final work = sorted[i];
        o.stage = '下载单据 ${i + 1} / ${sorted.length}';
        _changed();
        final Uint8List bytes;
        try {
          bytes = await controller.batchDownloadPdf(work, client);
        } catch (e) {
          if (i == 0) {
            throw FormatException('最新单据 ${work['caseNo']} 下载失败：${_error(e)}');
          }
          o.failures.add('${work['caseNo']} 下载失败：${_error(e)}');
          continue;
        }
        await File(
          '${batchDir!.path}/originals/${work['caseNo']}.pdf',
        ).writeAsBytes(bytes, flush: true);
        o.stage = '分析单据 ${i + 1} / ${sorted.length}';
        _changed();
        final pages = await engine.analyzeDocument(bytes);
        docs.add(
          BatchDocument(
            work,
            bytes,
            RepairDocument(
              '${work['caseNo']}',
              '${work['opTime'] ?? ''}',
              pages,
            ),
          ),
        );
      }
      o.target = docs.first;
      o.history = docs.sublist(1);
      o.items = analyzeRepair(o.target!.analysis, [
        for (final d in o.history) d.analysis,
      ]);
      o.selected.addAll(o.fixable.map((i) => i.id));
      await _repairLog?.write('analysis', {
        'order': o.order,
        'target': o.target!.caseNo,
        'history': [for (final d in o.history) d.caseNo],
        'items': [
          for (final i in o.items)
            {
              'id': i.id,
              'page': i.page + 1,
              'element': i.element.name,
              'fixable': i.fixable,
              'message': i.message,
            },
        ],
      });
      if (o.fixable.isEmpty) {
        o.status = o.items.isEmpty
            ? BatchOrderStatus.ok
            : BatchOrderStatus.unresolved;
        o.message = _summary(o);
        return;
      }
      await _generate(o);
    } catch (e) {
      o.status = BatchOrderStatus.failed;
      o.message = _error(e);
      await _repairLog?.write('order_failed', {
        'order': o.order,
        'error': o.message,
      });
    } finally {
      o.stage = '';
      _changed();
    }
  }

  String _summary(BatchOrder o) {
    final fix = o.fixable.length, bad = o.items.length - fix;
    return [
      if (fix > 0) '$fix 项可修补',
      if (bad > 0) '$bad 项无法从历史单据补齐',
      if (o.history.isEmpty) '近 $months 个月只有这一份单据，没有可对照的历史单据',
      if (o.items.isEmpty && o.history.isNotEmpty) '未发现缺失',
    ].join('；');
  }

  /// 按当前勾选生成修复件：移植图片 → 压缩 → 逐页比对 → 复查修补位置 → 落盘。
  Future<void> _generate(BatchOrder o) async {
    final revision = ++o.revision;
    final target = o.target!;
    final chosen = [
      for (final i in o.items)
        if (i.fixable && o.selected.contains(i.id)) i,
    ];
    o
      ..repaired = null
      ..output = null
      ..outputPath = null
      ..problems = []
      ..renderDiff = null;
    if (chosen.isEmpty) {
      o.status = BatchOrderStatus.unresolved;
      o.message = '没有勾选修补项';
      return;
    }
    o.stage = '生成修复件';
    _changed();
    final placements = [
      for (final item in chosen)
        for (final p in item.placements)
          ImageTransplant(
            source: p.history,
            sourcePage: p.sourcePage,
            path: p.path,
            targetPage: item.page,
            target: p.target,
            basis: p.basis,
          ),
    ];
    final repaired = await engine.transplantImages(target.bytes, [
      for (final d in o.history) d.bytes,
    ], placements);
    if (revision != o.revision) return;
    o.stage = '压缩';
    _changed();
    final optimized = await optimizePdf(repaired);
    if (revision != o.revision) return;
    final problems = <String>[];
    Uint8List output;
    OptimizeResult result;
    if (optimized == null) {
      problems.add('文件结构无法整理，未压缩');
      output = repaired;
      result = OptimizeResult(repaired, 0, repaired.length);
    } else {
      output = optimized.bytes;
      result = optimized;
    }
    o.stage = '逐页比对';
    _changed();
    final before = await engine.pageDigests(repaired);
    final after = await engine.pageDigests(output);
    double? worst;
    if (before.length != after.length) {
      problems.add('页数不一致：修复后 ${before.length} 页，压缩后 ${after.length} 页');
    } else {
      worst = 0;
      for (var i = 0; i < before.length; i++) {
        final a = before[i], b = after[i];
        if (a.length != b.length) {
          problems.add('第 ${i + 1} 页尺寸变化');
          continue;
        }
        var sum = 0;
        for (var k = 0; k < a.length; k++) {
          sum += (a[k] - b[k]).abs();
        }
        final mean = sum / a.length;
        if (mean > worst!) worst = mean;
      }
      final limit = result.lossy ? 3.0 : .5;
      if (worst! > limit) {
        problems.add('压缩前后渲染差异偏大（平均 ${worst.toStringAsFixed(2)}）');
      }
    }
    if (target.analysis.pages.length != after.length) {
      problems.add('页数与原单据不一致');
    }
    // 复查：每个补入位置都有非空白图片。
    final check = await engine.analyzeDocument(output);
    for (final item in chosen) {
      final page = check[item.page];
      for (final p in item.placements) {
        final area = p.target.width * p.target.height;
        final hit = page.images.any((i) {
          if (i.blank) return false;
          final cross = i.bounds.intersect(p.target);
          return cross.width > 0 &&
              cross.height > 0 &&
              cross.width * cross.height > .8 * area;
        });
        if (!hit) {
          problems.add('第 ${item.page + 1} 页${item.element.label}复查未找到图片');
          break;
        }
      }
    }
    if (!result.fits) {
      problems.add('文件 ${result.bytes.length} 字节，超过上传接口 2MB 限制');
    }
    if (revision != o.revision) return;
    final path = '${batchDir!.path}/output/${o.outputName}';
    await File(path).writeAsBytes(output, flush: true);
    o
      ..repaired = repaired
      ..output = OptimizeResult(
        output,
        result.level,
        repaired.length,
        fontsSubset: result.fontsSubset,
        objectsMerged: result.objectsMerged,
      )
      ..outputPath = path
      ..problems = problems
      ..renderDiff = worst
      ..status = BatchOrderStatus.repaired
      ..message = problems.isEmpty
          ? '${_summary(o)}；修复件 ${_size(output.length)}（${result.label}）'
          : '修复件有问题：${problems.join('；')}';
    await _repairLog?.write('generated', {
      'order': o.order,
      'caseNo': target.caseNo,
      'items': [for (final i in chosen) i.id],
      'path': path,
      'repairedBytes': repaired.length,
      'outputBytes': output.length,
      'sha256': sha256Hex(output),
      'level': result.level,
      'levelLabel': result.label,
      'renderDiff': worst,
      'problems': problems,
    });
  }

  /// 勾选或取消一个修补项（已上传的单据不再改动）；调用方随后触发 [regenerate]。
  void select(BatchOrder o, String id, bool value) {
    if (uploaded(o) != null) return;
    value ? o.selected.add(id) : o.selected.remove(id);
    _changed();
  }

  /// 勾选变化后重新生成修复件。
  Future<void> regenerate(BatchOrder o) async {
    if (o.target == null || o.status == BatchOrderStatus.running) return;
    if (uploaded(o) != null) return;
    try {
      await _generate(o);
    } catch (e) {
      o
        ..status = BatchOrderStatus.failed
        ..message = '生成修复件失败：${_error(e)}';
    } finally {
      o.stage = '';
      await _writeReport();
      _changed();
    }
  }

  Future<void> _writeReport() async {
    final dir = batchDir;
    if (dir == null) return;
    final data = {
      'time': _now(),
      'orders': [
        for (final o in orders)
          {
            'order': o.order,
            'status': o.status.name,
            'message': o.message,
            'failures': o.failures,
            'target': o.target?.caseNo,
            'history': [for (final d in o.history) d.caseNo],
            'items': [
              for (final i in o.items)
                {
                  'id': i.id,
                  'page': i.page + 1,
                  'element': i.element.name,
                  'fixable': i.fixable,
                  'selected': o.selected.contains(i.id),
                  'message': i.message,
                },
            ],
            'output': o.outputPath,
            'problems': o.problems,
          },
      ],
    };
    try {
      await File('${dir.path}/report.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert(data),
        flush: true,
      );
    } catch (_) {}
  }

  // ---------------- 上传（生产写操作） ----------------

  /// 从全局上传历史中读出已上传成功（回读一致）的单据。
  Map<String, UploadedRecord> uploadedHistory() {
    final result = <String, UploadedRecord>{};
    if (batchDir == null || !historyFile.existsSync()) return result;
    for (final line in historyFile.readAsLinesSync()) {
      try {
        final r = jsonDecode(line) as Map<String, dynamic>;
        if (r['event'] == 'readback' &&
            r['match'] == true &&
            r['caseNo'] != null) {
          result['${r['caseNo']}'] = (
            batch: '${r['batch']}',
            time: '${r['time']}',
            sha: '${r['sha256']}',
            order: '${r['order']}',
          );
        }
      } catch (_) {}
    }
    return result;
  }

  UploadedRecord? uploaded(BatchOrder o) =>
      o.target == null ? null : uploadedHistory()[o.target!.caseNo];

  /// 第一步：为选中的订单重新下载线上当前文件作备份（只读），并检查能否上传。
  Future<UploadRun> prepareUpload(List<BatchOrder> picked) async {
    if (upload?.state == UploadRunState.uploading) {
      throw const FormatException('已有一批正在上传，请等待完成');
    }
    final id = '${_stamp()}-${DateTime.now().microsecond.toRadixString(16)}';
    final dir = Directory('${batchDir!.path}/uploads/$id');
    await Directory('${dir.path}/backups').create(recursive: true);
    final log = JsonlLog([File('${dir.path}/upload.jsonl'), historyFile]);
    final run = UploadRun(id, dir, log, [
      for (final o in picked) UploadFile(o),
    ]);
    upload = run;
    _changed();
    Future<void> write(String event, Map<String, Object?> fields) =>
        log.write(event, {'batch': id, ...fields});
    await write('prepare_start', {
      'orders': [for (final o in picked) o.order],
      'baseUrl': controller.settings.baseUrl,
      'loginNo': controller.settings.loginNo,
    });
    final done = uploadedHistory();
    for (final f in run.files) {
      final o = f.order;
      final target = o.target;
      if (target == null) {
        f.reason = '没有最新单据';
        continue;
      }
      final record = done[target.caseNo];
      if (record != null) {
        f
          ..status = UploadFileStatus.skipped
          ..reason =
              '已于 ${record.time.substring(0, 19).replaceFirst('T', ' ')} 上传成功并回读一致（批次 ${record.batch}），已剔除';
        continue;
      }
      if (!o.uploadable) {
        f.reason = o.problems.isNotEmpty
            ? '修复件有问题：${o.problems.join('；')}'
            : o.output != null && !o.output!.fits
            ? '修复件超过上传接口 2MB 限制'
            : '还没有可上传的修复件';
        continue;
      }
      final bytes = await File(o.outputPath!).readAsBytes();
      f
        ..file = o.outputPath!
        ..size = bytes.length
        ..sha = sha256Hex(bytes)
        ..target = controller.batchObsTarget(target.work);
      if (f.sha != sha256Hex(o.output!.bytes)) {
        f.reason = '修复件在生成后被改动过，请重新生成';
        continue;
      }
      if (bytes.length > fileLimit) {
        f.reason = '修复件 ${bytes.length} 字节，超过上传接口 2MB 限制';
        continue;
      }
      final Uint8List online;
      try {
        online = await controller.batchDownloadPdf(target.work, client);
      } catch (e) {
        f.reason = '备份失败，线上文件读取失败：${_error(e)}';
        await write('backup_failed', {
          'order': o.order,
          'caseNo': target.caseNo,
          'error': f.reason,
        });
        continue;
      }
      final backup = File(
        '${run.backups.path}/${target.caseNo}-线上原件-${_stamp().substring(9)}.pdf',
      );
      await backup.writeAsBytes(online, flush: true);
      final written = await backup.readAsBytes();
      f
        ..backup = backup.path
        ..backupSha = sha256Hex(online)
        ..backupSize = online.length;
      if (sha256Hex(written) != f.backupSha) {
        f.reason = '备份文件写盘校验失败';
        await write('backup_failed', {
          'order': o.order,
          'caseNo': target.caseNo,
          'error': f.reason,
        });
        continue;
      }
      final original = sha256Hex(target.bytes);
      await write('backup_saved', {
        'order': o.order,
        'caseNo': target.caseNo,
        'backup': backup.path,
        'sha256': f.backupSha,
        'size': online.length,
        'analyzedSha256': original,
      });
      if (f.backupSha == f.sha) {
        f
          ..status = UploadFileStatus.skipped
          ..reason = '线上文件已经是这份修复件，无需上传';
        continue;
      }
      if (f.backupSha != original) {
        f.reason = '线上文件和分析时下载的原件不一致（期间可能被修改或已上传过），请重试该订单后再上传';
        continue;
      }
      f.status = UploadFileStatus.ready;
    }
    run.phrase = '确认上传${run.ready.length}份';
    run.state = run.ready.isEmpty
        ? UploadRunState.blocked
        : UploadRunState.ready;
    await write('prepare_done', {
      'ready': run.ready.length,
      'files': [
        for (final f in run.files)
          {
            'order': f.order.order,
            'caseNo': f.caseNo,
            'status': f.status.name,
            'reason': f.reason,
          },
      ],
    });
    await _writeSummary(run);
    _changed();
    return run;
  }

  /// 第二步（三级确认之后）：逐个上传。[phrase] 必须与 [UploadRun.phrase] 一致。
  Future<void> startUpload(
    UploadRun run, {
    required bool targetsConfirmed,
    required bool backupConfirmed,
    required String phrase,
  }) async {
    if (!identical(run, upload) || run.state != UploadRunState.ready) {
      throw const FormatException('上传批次已失效，请重新准备');
    }
    if (!targetsConfirmed || !backupConfirmed) {
      throw const FormatException('请先完成目标核对与备份确认');
    }
    if (phrase.trim() != run.phrase) {
      throw FormatException('确认口令不正确，请输入“${run.phrase}”');
    }
    for (final f in run.ready) {
      if (!File(f.backup).existsSync()) {
        throw FormatException('${f.caseNo} 的备份文件不存在，拒绝上传');
      }
    }
    Future<void> write(String event, Map<String, Object?> fields) =>
        run.log.write(event, {'batch': run.id, ...fields});
    run.state = UploadRunState.uploading;
    await write('confirmed', {
      'phrase': run.phrase,
      'files': [for (final f in run.ready) f.caseNo],
    });
    _changed();
    try {
      for (final f in run.files) {
        if (f.status != UploadFileStatus.ready) continue;
        if (run.stopRequested) {
          f
            ..status = UploadFileStatus.cancelled
            ..result = '已停止，未上传';
          continue;
        }
        f.status = UploadFileStatus.uploading;
        _changed();
        final ok = await _uploadOne(run, f, write);
        if (!ok) await _checkAfterFailure(f, write);
        _changed();
      }
      final failed = run.files.any((f) => f.status == UploadFileStatus.failed);
      run.state = run.stopRequested
          ? UploadRunState.stopped
          : failed
          ? UploadRunState.partial
          : UploadRunState.done;
    } catch (e) {
      for (final f in run.files) {
        if (f.status == UploadFileStatus.uploading) {
          f
            ..status = UploadFileStatus.failed
            ..result = '程序异常，结果未知，请回读确认：${_error(e)}';
        } else if (f.status == UploadFileStatus.ready) {
          f
            ..status = UploadFileStatus.cancelled
            ..result = '程序异常，未上传';
        }
      }
      run.state = UploadRunState.partial;
      await write('batch_error', {'error': _error(e)});
    } finally {
      await write('batch_end', {
        'state': run.state.name,
        'results': [
          for (final f in run.files)
            {
              'order': f.order.order,
              'caseNo': f.caseNo,
              'status': f.status.name,
              'result': f.result,
            },
        ],
      });
      await _writeSummary(run);
      _changed();
    }
  }

  void stopUpload() {
    final run = upload;
    if (run == null || run.state != UploadRunState.uploading) return;
    run.stopRequested = true;
    run.log.write('stop_requested', {'batch': run.id});
    _changed();
  }

  Future<bool> _uploadOne(
    UploadRun run,
    UploadFile f,
    Future<void> Function(String, Map<String, Object?>) write,
  ) async {
    final bytes = await File(f.file).readAsBytes();
    if (sha256Hex(bytes) != f.sha) {
      f
        ..status = UploadFileStatus.failed
        ..result = '修复件在确认后被改动，未上传';
      await write('upload_refused', {
        'order': f.order.order,
        'caseNo': f.caseNo,
        'reason': f.result,
      });
      return false;
    }
    if (bytes.length > fileLimit) {
      f
        ..status = UploadFileStatus.failed
        ..result = '超过上传接口 2MB 限制，未发送';
      await write('upload_refused', {
        'order': f.order.order,
        'caseNo': f.caseNo,
        'reason': f.result,
      });
      return false;
    }
    final name = f.file.split(Platform.pathSeparator).last.split('/').last;
    await write('upload_request', {
      'order': f.order.order,
      'caseNo': f.caseNo,
      'endpoint': MaintenanceController.obsUploadEndpoint,
      'fileName': name,
      'size': bytes.length,
      'sha256': f.sha,
      'backup': f.backup,
      'backupSha256': f.backupSha,
      ...f.target,
    });
    final ({int status, String body, int ms}) response;
    try {
      response = await controller.batchUpload(name, bytes, f.target, client);
    } catch (e) {
      f
        ..status = UploadFileStatus.failed
        ..result = '上传请求失败：${_error(e)}';
      await write('upload_error', {
        'order': f.order.order,
        'caseNo': f.caseNo,
        'error': f.result,
        'restore': '用备份 ${f.backup} 上传可恢复',
      });
      return false;
    }
    f
      ..httpStatus = response.status
      ..durationMs = response.ms;
    await write('upload_response', {
      'order': f.order.order,
      'caseNo': f.caseNo,
      'httpStatus': response.status,
      'response': response.body.length > 2000
          ? response.body.substring(0, 2000)
          : response.body,
      'durationMs': response.ms,
    });
    if (response.status < 200 ||
        response.status >= 300 ||
        response.body.trim() != 'true') {
      f
        ..status = UploadFileStatus.failed
        ..result = response.status == 413
            ? '文件超过接口 2MB 限制，服务端拒收（HTTP 413）'
            : '服务端未返回 true（HTTP ${response.status}）：${_clip(response.body.trim(), 120)}';
      return false;
    }
    try {
      final back = await controller.batchDownloadPdf(
        f.order.target!.work,
        client,
      );
      final sha = sha256Hex(back);
      final match = sha == f.sha;
      await write('readback', {
        'order': f.order.order,
        'caseNo': f.caseNo,
        'sha256': sha,
        'size': back.length,
        'match': match,
      });
      if (!match) {
        f
          ..status = UploadFileStatus.failed
          ..result = '上传返回成功，但回读内容与修复件不一致';
        return false;
      }
    } catch (e) {
      f
        ..status = UploadFileStatus.failed
        ..result = '上传返回成功，但回读失败：${_error(e)}';
      await write('readback_failed', {
        'order': f.order.order,
        'caseNo': f.caseNo,
        'error': f.result,
      });
      return false;
    }
    f
      ..status = UploadFileStatus.uploaded
      ..result = '上传成功，回读一致';
    return true;
  }

  /// 失败后回读线上文件：仍是原件可直接重传；已是修复件按成功处理；都不是需人工核查。
  Future<void> _checkAfterFailure(
    UploadFile f,
    Future<void> Function(String, Map<String, Object?>) write,
  ) async {
    try {
      final online = await controller.batchDownloadPdf(
        f.order.target!.work,
        client,
      );
      final sha = sha256Hex(online);
      if (sha == f.backupSha) {
        f.online = '线上仍是上传前的原件，可以修正后重试';
      } else if (sha == f.sha) {
        f
          ..status = UploadFileStatus.uploaded
          ..result = '上传接口报错，但回读线上已是这份修复件，按成功处理';
        await write('readback', {
          'order': f.order.order,
          'caseNo': f.caseNo,
          'sha256': sha,
          'size': online.length,
          'match': true,
          'note': '失败后回读一致',
        });
      } else {
        f.online = '线上文件既不是原件也不是修复件，请人工核查';
      }
      await write('check_after_failure', {
        'order': f.order.order,
        'caseNo': f.caseNo,
        'sha256': sha,
        'unchanged': sha == f.backupSha,
        'note': f.online,
      });
    } catch (e) {
      f.online = '无法确认线上文件：${_error(e)}';
      await write('check_after_failure', {
        'order': f.order.order,
        'caseNo': f.caseNo,
        'error': f.online,
      });
    }
  }

  Future<void> _writeSummary(UploadRun run) async {
    final data = {
      'batch': run.id,
      'state': run.state.name,
      'log': run.logFile.path,
      'history': historyFile.path,
      'files': [
        for (final f in run.files)
          {
            'order': f.order.order,
            'caseNo': f.caseNo,
            'status': f.status.name,
            'reason': f.reason,
            'result': f.result,
            'online': f.online,
            ...f.target,
            'file': f.file,
            'size': f.size,
            'sha256': f.sha,
            'backup': f.backup,
            'backupSha256': f.backupSha,
            'httpStatus': f.httpStatus,
            'durationMs': f.durationMs,
          },
      ],
    };
    try {
      await File('${run.dir.path}/summary.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert(data),
        flush: true,
      );
    } catch (_) {}
  }

  static String _error(Object e) => e is FormatException
      ? e.message
      : e is SocketException
      ? '网络连接失败'
      : e is TimeoutException
      ? '请求超时'
      : '$e';

  static String _clip(String s, int n) =>
      s.length <= n ? s : '${s.substring(0, n)}…';

  static String _size(int n) => n >= 1048576
      ? '${(n / 1048576).toStringAsFixed(2)} MB'
      : '${(n / 1024).toStringAsFixed(0)} KB';

  @override
  void dispose() {
    _disposed = true;
    _client?.close();
    super.dispose();
  }
}
