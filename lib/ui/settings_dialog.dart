import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core/contracts.dart';
import '../core/jwt_signer.dart';
import '../core/maintenance_controller.dart';
import '../core/update_check.dart';

/// 密钥库输入仅存在弹窗内存，保存后释放密码文本与文件字节。
class SettingsDialog extends StatefulWidget {
  final MaintenanceController controller;
  const SettingsDialog({super.key, required this.controller});
  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  final base = TextEditingController(),
      bucket = TextEditingController(),
      login = TextEditingController(),
      channel = TextEditingController();
  final password = TextEditingController(),
      keyPassword = TextEditingController(),
      alias = TextEditingController();
  Uint8List? keyBytes;
  String fileName = '', error = '';
  bool saving = false, checkingUpdate = false;
  @override
  void initState() {
    super.initState();
    final value = widget.controller.settings;
    base.text = value.baseUrl;
    bucket.text = value.bucket;
    login.text = value.loginNo;
    channel.text = value.channel;
  }

  @override
  void dispose() {
    for (final field in [
      base,
      bucket,
      login,
      channel,
      password,
      keyPassword,
      alias,
    ]) {
      field.clear();
      field.dispose();
    }
    keyBytes?.fillRange(0, keyBytes!.length, 0);
    super.dispose();
  }

  Future<void> pick() async {
    try {
      final result = await FilePicker.pickFiles(
        // 使用通用文件选择器，避免手机把非标准 keystore 扩展名禁用。
        type: FileType.any,
      );
      if (!mounted || result.isEmpty) return;
      final file = result.single;
      final selectedBytes = await file.readAsBytes();
      if (!mounted) return;
      if (selectedBytes.isEmpty) throw const FormatException('无法读取所选密钥文件');
      setState(() {
        keyBytes?.fillRange(0, keyBytes!.length, 0);
        keyBytes = selectedBytes;
        fileName = file.name;
        error = '';
      });
    } catch (exception) {
      if (mounted) setState(() => error = '文件读取失败：$exception');
    }
  }

  Future<void> save() async {
    setState(() {
      saving = true;
      error = '';
    });
    try {
      final settings = ConnectionSettings(
        baseUrl: base.text.trim().replaceAll(RegExp(r'/+$'), ''),
        bucket: bucket.text.trim(),
        loginNo: login.text.trim(),
        channel: channel.text.trim(),
      );
      settings.validate();
      // 密钥解析放在 isolate，避免 JKS 运算阻塞弹窗动画。
      final key = keyBytes == null
          ? widget.controller.signer
          : await compute(_importKey, <String, Object>{
              'bytes': keyBytes!,
              'password': password.text,
              'keyPassword': keyPassword.text,
              'alias': alias.text.trim(),
            });
      if (!mounted) return;
      await widget.controller.configure(settings, key);
      if (mounted) Navigator.pop(context);
    } catch (exception) {
      if (mounted) {
        setState(() {
          saving = false;
          error = exception is FormatException
              ? exception.message
              : '设置保存失败，请检查系统钥匙串或安全存储访问权限。';
        });
      }
    }
  }

  /// 查询 GitHub 最新 Release；发现新版本时弹窗展示更新说明并可前往下载。
  Future<void> checkUpdate() async {
    setState(() => checkingUpdate = true);
    try {
      final update = await checkLatestRelease();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(update == null ? '已是最新版本' : '发现新版本 v${update.version}'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: SelectableText(
                update == null
                    ? '当前版本 v$appVersion 已是最新。'
                    : update.notes.isEmpty
                    ? '新版本已发布，可前往下载。'
                    : update.notes,
                style: const TextStyle(fontSize: 13, height: 1.7),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('关闭'),
            ),
            if (update != null)
              FilledButton.icon(
                onPressed: () => launchUrl(Uri.parse(update.url)),
                icon: const Icon(Icons.download_outlined, size: 18),
                label: const Text('前往下载'),
              ),
          ],
        ),
      );
    } catch (exception) {
      if (mounted) {
        setState(() {
          error = exception is FormatException
              ? exception.message
              : '检查更新失败，请检查网络后重试。';
        });
      }
    } finally {
      if (mounted) setState(() => checkingUpdate = false);
    }
  }

  /// 移除仅作用于系统保存项，不删除用户导入的原始文件。
  Future<void> removeKey() async {
    setState(() {
      saving = true;
      error = '';
    });
    try {
      await widget.controller.removeStoredKey();
      if (!mounted) return;
      keyBytes?.fillRange(0, keyBytes!.length, 0);
      setState(() {
        keyBytes = null;
        fileName = '';
        saving = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          saving = false;
          error = '移除密钥失败，请检查系统安全存储访问权限。';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
    title: const Text('连接与密钥设置'),
    content: SizedBox(
      width: 530,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '原生直连后台 · 所有接口仅用于查询',
              style: TextStyle(color: Color(0xff8090a5), fontSize: 12),
            ),
            const SizedBox(height: 20),
            _field(base, '服务地址 baseUrl', hint: 'https://服务地址/上下文'),
            _field(bucket, 'OBS 桶覆盖（可选）', hint: '留空按 receipt + regionCode'),
            Row(
              children: [
                Expanded(child: _field(login, 'JWT 工号')),
                const SizedBox(width: 12),
                Expanded(child: _field(channel, 'JWT 渠道')),
              ],
            ),
            OutlinedButton.icon(
              onPressed: saving ? null : pick,
              icon: const Icon(Icons.key_outlined, size: 18),
              label: Text(fileName.isEmpty ? '选择密钥文件（JKS / PEM）' : fileName),
            ),
            const SizedBox(height: 8),
            Text(
              widget.controller.signer == null
                  ? '尚未加载密钥'
                  : '${widget.controller.keyPersisted ? '已安全保存' : '已加载'}：${widget.controller.signer!.alias}',
              style: const TextStyle(fontSize: 12, color: Color(0xff8090a5)),
            ),
            if (widget.controller.signer != null ||
                widget.controller.keyPersisted)
              TextButton.icon(
                onPressed: saving ? null : removeKey,
                icon: const Icon(Icons.key_off_outlined),
                label: const Text('移除已保存密钥'),
              ),
            const SizedBox(height: 16),
            _field(password, 'JKS 密钥库密码', obscure: true),
            _field(keyPassword, '私钥密码（相同时留空）', obscure: true),
            _field(alias, '私钥别名（单个私钥时留空）'),
            const Text(
              '密钥安全保存在本机：Mac / iOS 使用钥匙串，Android 使用系统加密存储。下次启动自动恢复，不保存密钥库密码，不上传私钥。',
              style: TextStyle(
                fontSize: 12,
                color: Color(0xff8090a5),
                height: 1.6,
              ),
            ),
            const Divider(height: 28),
            Row(
              children: [
                const Text(
                  '当前版本 v$appVersion',
                  style: TextStyle(fontSize: 12, color: Color(0xff8090a5)),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: saving || checkingUpdate ? null : checkUpdate,
                  icon: const Icon(Icons.system_update_alt, size: 18),
                  label: Text(checkingUpdate ? '正在检查…' : '检查更新'),
                ),
              ],
            ),
            if (error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: SelectableText(
                  error,
                  style: const TextStyle(color: Colors.red),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: saving ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: saving ? null : save,
        child: Text(saving ? '正在加载…' : '保存设置'),
      ),
    ],
  );
  Widget _field(
    TextEditingController controller,
    String label, {
    String? hint,
    bool obscure = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextField(
      controller: controller,
      obscureText: obscure,
      enabled: !saving,
      enableSuggestions: !obscure,
      autocorrect: false,
      decoration: InputDecoration(labelText: label, hintText: hint),
    ),
  );
}

JwtSigner _importKey(Map<String, Object> value) => JwtSigner.import(
  value['bytes'] as Uint8List,
  password: value['password'] as String,
  keyPassword: value['keyPassword'] as String,
  alias: value['alias'] as String,
);
