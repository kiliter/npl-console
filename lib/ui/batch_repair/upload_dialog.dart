import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/batch_repair/batch_repair.dart';
import '../listenable_selector.dart';

const _ink = Color(0xff0f1e36),
    _muted = Color(0xff7f91ab),
    _line = Color(0xffdde6f1),
    _seal = Color(0xffc8372d),
    _ok = Color(0xff0d8a6a),
    _warn = Color(0xffc66908);
const _mono = 'Menlo';

/// 生产写操作：把修复件上传到 OBS，覆盖原单据。
/// 选择订单 → 下载线上原件备份并核对目标（1/3）→ 确认备份（2/3）→
/// 手动输入口令并再次确认（3/3）→ 逐个上传，失败的可单独重试。
Future<void> showUploadDialog(
  BuildContext context,
  BatchRepairSession session,
) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => UploadDialog(session: session),
);

class UploadDialog extends StatefulWidget {
  final BatchRepairSession session;
  const UploadDialog({super.key, required this.session});
  @override
  State<UploadDialog> createState() => _UploadDialogState();
}

enum _Step { pick, targets, backups, confirm, progress }

class _UploadDialogState extends State<UploadDialog> {
  BatchRepairSession get session => widget.session;
  _Step step = _Step.pick;
  late final Set<String> picked = {
    for (final o in session.orders)
      if (o.uploadable && session.uploaded(o) == null) o.order,
  };
  bool targetsChecked = false, backupsChecked = false, busy = false;
  final phrase = TextEditingController();
  String? error;
  UploadRun? run;

  @override
  void dispose() {
    phrase.dispose();
    super.dispose();
  }

  Future<void> prepare(List<BatchOrder> orders) async {
    setState(() {
      busy = true;
      error = null;
      targetsChecked = backupsChecked = false;
      phrase.clear();
    });
    try {
      final next = await session.prepareUpload(orders);
      if (!mounted) return;
      setState(() {
        run = next;
        step = _Step.targets;
      });
    } catch (e) {
      if (mounted) {
        setState(() => error = e is FormatException ? e.message : '$e');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> start() async {
    final r = run;
    if (r == null) return;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('最后确认'),
        content: Text('现在开始把 ${r.ready.length} 份修复件上传到生产 OBS，覆盖原单据？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('upload-final-confirm'),
            style: FilledButton.styleFrom(backgroundColor: _seal),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('开始上传'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      error = null;
      step = _Step.progress;
    });
    try {
      await session.startUpload(
        r,
        targetsConfirmed: targetsChecked,
        backupConfirmed: backupsChecked,
        phrase: phrase.text,
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e is FormatException ? e.message : '$e';
          step = _Step.confirm;
        });
      }
    }
  }

  bool get uploading => run?.state == UploadRunState.uploading;

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(24),
    clipBehavior: Clip.antiAlias,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1100, maxHeight: 760),
      child: ListenableSelector<int>(
        listenable: session,
        selector: () => session.revision,
        builder: (context, _) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(height: 5, color: _seal),
            header(),
            const Divider(height: 1, color: _line),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(22, 16, 22, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    body(),
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          error!,
                          style: const TextStyle(
                            color: Color(0xff7a2b25),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
              decoration: const BoxDecoration(
                color: Color(0xfff7f8fa),
                border: Border(top: BorderSide(color: _line)),
              ),
              child: footer(),
            ),
          ],
        ),
      ),
    ),
  );

  Widget header() {
    const labels = ['核对目标', '确认备份', '最终确认', '逐个上传'];
    final index = switch (step) {
      _Step.pick || _Step.targets => 0,
      _Step.backups => 1,
      _Step.confirm => 2,
      _Step.progress => 3,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 14, 22, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '生产写操作 · 覆盖 OBS 原单据',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: _seal,
                ),
              ),
              Text(
                '上传修复件',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const Spacer(),
          for (var i = 0; i < labels.length; i++)
            Container(
              margin: const EdgeInsets.only(left: 6),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: i < index
                    ? const Color(0xffdcefeb)
                    : i == index
                    ? _seal
                    : const Color(0xffeef1f4),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '${i + 1} ${labels[i]}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: i == index ? FontWeight.w700 : FontWeight.w500,
                  color: i < index
                      ? _ok
                      : i == index
                      ? Colors.white
                      : _muted,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget table(
    List<String> columns,
    List<List<Widget>> rows, {
    List<Color?>? colors,
  }) => Table(
    defaultVerticalAlignment: TableCellVerticalAlignment.top,
    border: const TableBorder(
      horizontalInside: BorderSide(color: Color(0xffedf0f3)),
    ),
    children: [
      TableRow(
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: _line)),
        ),
        children: [
          for (final c in columns)
            Padding(
              padding: const EdgeInsets.all(6),
              child: Text(
                c,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: _muted,
                ),
              ),
            ),
        ],
      ),
      for (var i = 0; i < rows.length; i++)
        TableRow(
          decoration: BoxDecoration(color: colors?[i]),
          children: [
            for (final cell in rows[i])
              Padding(padding: const EdgeInsets.all(6), child: cell),
          ],
        ),
    ],
  );

  Widget mono(String text, {Color? color}) => SelectableText(
    text,
    style: TextStyle(fontFamily: _mono, fontSize: 12, color: color ?? _ink),
  );

  Widget status(UploadFileStatus s) => Text(
    s.label,
    style: TextStyle(
      fontWeight: FontWeight.w700,
      fontSize: 12,
      color: switch (s) {
        UploadFileStatus.ready || UploadFileStatus.uploading => _warn,
        UploadFileStatus.uploaded => _ok,
        UploadFileStatus.failed ||
        UploadFileStatus.blocked => const Color(0xff7a2b25),
        _ => _muted,
      },
    ),
  );

  Widget check(
    String text,
    bool value,
    ValueChanged<bool> onChanged,
    Key key,
  ) => Padding(
    padding: const EdgeInsets.only(top: 14),
    child: Material(
      color: const Color(0xfffff8e8),
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: Color(0xffecd39b)),
        borderRadius: BorderRadius.circular(6),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: CheckboxListTile(
          key: key,
          value: value,
          onChanged: (v) => onChanged(v ?? false),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(
            text,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ),
    ),
  );

  Widget body() => switch (step) {
    _Step.pick => pickBody(),
    _Step.targets => targetsBody(),
    _Step.backups => backupsBody(),
    _Step.confirm => confirmBody(),
    _Step.progress => progressBody(),
  };

  Widget pickBody() {
    final rows = [
      for (final o in session.orders)
        if (o.target != null && o.output != null || session.uploaded(o) != null)
          o,
    ];
    String? why(BatchOrder o) {
      final done = session.uploaded(o);
      if (done != null) {
        return '已于 ${done.time.substring(0, 19).replaceFirst('T', ' ')} 上传成功（批次 ${done.batch}），已剔除';
      }
      if (o.problems.isNotEmpty) return '修复件有问题，不能上传：${o.problems.join('；')}';
      if (!o.uploadable) return '没有可上传的修复件';
      return null;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '选择要上传的修复件。下一步会先用只读接口把每份单据的线上当前文件重新下载一份作为备份，'
          '并检查它和分析时的原件是否一致。',
        ),
        const SizedBox(height: 10),
        table(
          ['', '订单号', 'OBS 对象', '修复件', '大小'],
          [
            for (final o in rows)
              [
                Checkbox(
                  key: ValueKey('upload-pick-${o.order}'),
                  value: picked.contains(o.order),
                  onChanged: why(o) != null
                      ? null
                      : (v) => setState(
                          () => v == true
                              ? picked.add(o.order)
                              : picked.remove(o.order),
                        ),
                ),
                mono(o.order),
                mono('${o.target?.caseNo}.pdf'),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    mono(o.outputName),
                    if (o.output?.lossy == true)
                      Text(
                        '压缩：${o.output!.label}',
                        style: const TextStyle(fontSize: 11, color: _muted),
                      ),
                    if (why(o) != null)
                      Text(
                        why(o)!,
                        style: TextStyle(
                          fontSize: 12,
                          color: session.uploaded(o) != null
                              ? _ok
                              : const Color(0xff7a2b25),
                        ),
                      ),
                  ],
                ),
                Text(
                  o.output == null ? '—' : _size(o.output!.bytes.length),
                  style: const TextStyle(fontSize: 12),
                ),
              ],
          ],
          colors: [
            for (final o in rows)
              session.uploaded(o) != null
                  ? const Color(0xffeef7f5)
                  : why(o) != null
                  ? const Color(0xfffff7f2)
                  : null,
          ],
        ),
      ],
    );
  }

  Widget targetsBody() {
    final r = run!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('逐行核对上传目标。标红的行不会上传。批次 ${r.id}'),
        const SizedBox(height: 10),
        table(
          ['状态', '订单号', 'bucketName', 'objectName', 'ext8', '修复件'],
          [
            for (final f in r.files)
              [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    status(f.status),
                    if (f.reason.isNotEmpty)
                      Text(f.reason, style: const TextStyle(fontSize: 12)),
                  ],
                ),
                mono(f.order.order),
                mono('${f.target['bucketName'] ?? ''}'),
                mono('${f.target['objectName'] ?? ''}'),
                mono('${f.target['ext8'] ?? ''}'),
                f.file.isEmpty
                    ? const Text('—')
                    : mono(
                        '${f.file.split(RegExp(r'[\\/]')).last}\n${_size(f.size)}',
                      ),
              ],
          ],
          colors: [
            for (final f in r.files)
              f.status == UploadFileStatus.blocked
                  ? const Color(0xfffff7f2)
                  : f.status == UploadFileStatus.skipped
                  ? const Color(0xffeef7f5)
                  : null,
          ],
        ),
        if (r.ready.isNotEmpty)
          check(
            '我已逐行核对订单号、单据号和 OBS 目标（bucketName / objectName / ext8），确认无误',
            targetsChecked,
            (v) => setState(() => targetsChecked = v),
            const ValueKey('upload-check-targets'),
          )
        else
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text(
              '没有可以上传的文件。',
              style: TextStyle(
                color: Color(0xff7a2b25),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
      ],
    );
  }

  Widget paths(UploadRun r) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: DefaultTextStyle(
      style: const TextStyle(fontSize: 12, color: _muted),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('备份目录 '),
              Expanded(child: mono(r.backups.path)),
            ],
          ),
          Row(
            children: [
              const Text('上传日志 '),
              Expanded(child: mono(r.logFile.path)),
            ],
          ),
          Row(
            children: [
              const Text('批次汇总 '),
              Expanded(
                child: mono(
                  '${r.dir.path}${Platform.pathSeparator}summary.json',
                ),
              ),
            ],
          ),
          Row(
            children: [
              const Text('上传历史 '),
              Expanded(child: mono(session.historyFile.path)),
            ],
          ),
        ],
      ),
    ),
  );

  Widget backupsBody() {
    final r = run!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '上传会覆盖线上文件。下面是刚从线上读取的当前文件备份；出问题时，'
          '把备份文件按同样的 bucketName / objectName / ext8 重新上传即可恢复。',
        ),
        const SizedBox(height: 10),
        table(
          ['单据号', '备份文件', '大小', 'SHA-256'],
          [
            for (final f in r.ready)
              [
                mono(f.caseNo),
                mono(f.backup),
                Text(_size(f.backupSize), style: const TextStyle(fontSize: 12)),
                mono('${f.backupSha.substring(0, 16)}…'),
              ],
          ],
        ),
        paths(r),
        check(
          '我确认以上 ${r.ready.length} 份备份文件都已保存在本机，可用于恢复',
          backupsChecked,
          (v) => setState(() => backupsChecked = v),
          const ValueKey('upload-check-backups'),
        ),
      ],
    );
  }

  Widget confirmBody() {
    final r = run!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xfffbecea),
            border: Border.all(color: const Color(0xffe7b5af)),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            '即将覆盖生产 OBS 中的 ${r.ready.length} 个对象，覆盖后不可撤销。\n'
            '将按顺序一个一个上传：每份上传后立即回读校验；某一份失败只标记这一份，'
            '并回读确认线上文件状态，其余文件继续上传。上传中可以点“停止后续上传”。',
            style: const TextStyle(color: Color(0xff7a2b25), height: 1.6),
          ),
        ),
        const SizedBox(height: 12),
        for (var i = 0; i < r.ready.length; i++)
          mono(
            '${i + 1}. ${r.ready[i].target['objectName']} ← ${r.ready[i].file.split(RegExp(r'[\\/]')).last}',
          ),
        const SizedBox(height: 14),
        Text.rich(
          TextSpan(
            text: '请手动输入 ',
            children: [
              TextSpan(
                text: r.phrase,
                style: const TextStyle(
                  fontFamily: _mono,
                  color: _seal,
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
              const TextSpan(text: ' 以确认'),
            ],
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          width: 280,
          // 屏蔽粘贴（快捷键与右键菜单），口令必须手动输入。
          child: Shortcuts(
            shortcuts: const {
              SingleActivator(LogicalKeyboardKey.keyV, meta: true):
                  DoNothingAndStopPropagationTextIntent(),
              SingleActivator(LogicalKeyboardKey.keyV, control: true):
                  DoNothingAndStopPropagationTextIntent(),
              SingleActivator(LogicalKeyboardKey.insert, shift: true):
                  DoNothingAndStopPropagationTextIntent(),
            },
            child: TextField(
              key: const ValueKey('upload-phrase'),
              controller: phrase,
              enableInteractiveSelection: false,
              autocorrect: false,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(fontFamily: _mono, fontSize: 15),
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget progressBody() {
    final r = run!;
    final title = switch (r.state) {
      UploadRunState.uploading => '正在逐个上传…',
      UploadRunState.done => '全部上传完成',
      UploadRunState.partial =>
        '部分失败：成功 ${r.count(UploadFileStatus.uploaded)} 份，失败 ${r.count(UploadFileStatus.failed)} 份',
      UploadRunState.stopped => '已停止',
      _ => r.state.name,
    };
    final shown = [
      for (final f in r.files)
        if (f.status != UploadFileStatus.blocked &&
            f.status != UploadFileStatus.skipped)
          f,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (uploading) ...[
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
            ],
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          ],
        ),
        const SizedBox(height: 10),
        table(
          ['状态', '单据号', '结果', 'HTTP', '耗时', '备份（恢复用）', ''],
          [
            for (final f in shown)
              [
                status(f.status),
                mono(f.caseNo),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(f.result, style: const TextStyle(fontSize: 12)),
                    if (f.online.isNotEmpty)
                      Text(
                        f.online,
                        style: const TextStyle(fontSize: 11, color: _muted),
                      ),
                  ],
                ),
                Text(
                  '${f.httpStatus ?? '—'}',
                  style: const TextStyle(fontSize: 12),
                ),
                Text(
                  f.durationMs == null ? '—' : '${f.durationMs} ms',
                  style: const TextStyle(fontSize: 12),
                ),
                mono(f.backup.split(RegExp(r'[\\/]')).last),
                !uploading &&
                        (f.status == UploadFileStatus.failed ||
                            f.status == UploadFileStatus.cancelled)
                    ? OutlinedButton(
                        key: ValueKey('upload-retry-${f.order.order}'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: _seal,
                          side: const BorderSide(color: _seal),
                        ),
                        onPressed: busy ? null : () => prepare([f.order]),
                        child: const Text('重试'),
                      )
                    : const SizedBox(),
              ],
          ],
        ),
        paths(r),
      ],
    );
  }

  Widget footer() {
    final r = run;
    Widget cancel([String text = '取消']) => TextButton(
      onPressed: uploading || busy ? null : () => Navigator.pop(context),
      child: Text(text),
    );
    switch (step) {
      case _Step.pick:
        return Row(
          children: [
            const Expanded(
              child: Text(
                '这一步只读取，不会上传。',
                style: TextStyle(fontSize: 12, color: _muted),
              ),
            ),
            cancel(),
            const SizedBox(width: 8),
            FilledButton(
              key: const ValueKey('upload-prepare'),
              style: FilledButton.styleFrom(backgroundColor: _seal),
              onPressed: busy || picked.isEmpty
                  ? null
                  : () => prepare([
                      for (final o in session.orders)
                        if (picked.contains(o.order)) o,
                    ]),
              child: Text(busy ? '正在下载线上文件备份…' : '下载备份并核对（${picked.length} 份）'),
            ),
          ],
        );
      case _Step.targets:
        return Row(
          children: [
            const Spacer(),
            cancel(),
            const SizedBox(width: 8),
            FilledButton(
              key: const ValueKey('upload-next-backups'),
              style: FilledButton.styleFrom(backgroundColor: _seal),
              onPressed: targetsChecked && r!.ready.isNotEmpty
                  ? () => setState(() => step = _Step.backups)
                  : null,
              child: const Text('下一步：确认备份'),
            ),
          ],
        );
      case _Step.backups:
        return Row(
          children: [
            TextButton(
              onPressed: () => setState(() => step = _Step.targets),
              child: const Text('上一步'),
            ),
            const Spacer(),
            cancel(),
            const SizedBox(width: 8),
            FilledButton(
              key: const ValueKey('upload-next-confirm'),
              style: FilledButton.styleFrom(backgroundColor: _seal),
              onPressed: backupsChecked
                  ? () => setState(() => step = _Step.confirm)
                  : null,
              child: const Text('下一步：最终确认'),
            ),
          ],
        );
      case _Step.confirm:
        return Row(
          children: [
            TextButton(
              onPressed: () => setState(() => step = _Step.backups),
              child: const Text('上一步'),
            ),
            const Spacer(),
            cancel(),
            const SizedBox(width: 8),
            FilledButton(
              key: const ValueKey('upload-start'),
              style: FilledButton.styleFrom(backgroundColor: _seal),
              onPressed: phrase.text.trim() == r!.phrase ? start : null,
              child: Text('确认上传 ${r.ready.length} 份'),
            ),
          ],
        );
      case _Step.progress:
        final failed = [
          for (final f in r!.files)
            if (f.status == UploadFileStatus.failed ||
                f.status == UploadFileStatus.cancelled)
              f.order,
        ];
        return Row(
          children: [
            Expanded(
              child: Text(
                uploading
                    ? '上传中请勿关闭本窗口。'
                    : '日志已写入。重试会重新备份线上文件，并重新走一遍三步确认；已成功的会自动剔除。',
                style: const TextStyle(fontSize: 12, color: _muted),
              ),
            ),
            if (uploading)
              OutlinedButton(
                key: const ValueKey('upload-stop'),
                onPressed: r.stopRequested ? null : session.stopUpload,
                child: Text(r.stopRequested ? '当前这份完成后停止' : '停止后续上传'),
              )
            else ...[
              if (failed.isNotEmpty)
                OutlinedButton(
                  key: const ValueKey('upload-retry-all'),
                  onPressed: busy ? null : () => prepare(failed),
                  child: Text('重试全部失败的（${failed.length}）'),
                ),
              const SizedBox(width: 8),
              cancel('关闭'),
            ],
          ],
        );
    }
  }
}

String _size(int n) => n >= 1048576
    ? '${(n / 1048576).toStringAsFixed(2)} MB'
    : '${(n / 1024).toStringAsFixed(0)} KB';
