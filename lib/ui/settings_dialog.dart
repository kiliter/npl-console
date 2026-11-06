import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../core/app_update.dart';
import '../core/contracts.dart';
import '../core/jwt_signer.dart';
import '../core/maintenance_controller.dart';
import '../core/update_check.dart';
import 'update_dialog.dart';

/// 密钥库输入仅存在弹窗内存，保存后释放密码文本与文件字节。
class SettingsDialog extends StatefulWidget {
  final MaintenanceController controller;
  const SettingsDialog({super.key, required this.controller});
  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  final bucket = TextEditingController(),
      login = TextEditingController(),
      channel = TextEditingController();
  final password = TextEditingController(),
      keyPassword = TextEditingController(),
      alias = TextEditingController();
  // GitHub 加速站前缀，输入即持久化，应用内更新下载时使用。
  final proxy = TextEditingController();
  final proxyStore = GithubProxyStore();
  // 界面和检查更新共用安装包版本来源；重绘时复用同一次读取。
  late final Future<String> appVersion = readAppVersion();

  /// 可切换的环境列表与当前选中下标。
  final List<_EnvFields> envs = [];
  int active = 0;
  Uint8List? keyBytes;
  String fileName = '', error = '';
  bool saving = false, checkingUpdate = false;
  @override
  void initState() {
    super.initState();
    final value = widget.controller.settings;
    envs.addAll(value.environments.map(_EnvFields.new));
    if (envs.isEmpty) envs.add(_EnvFields(const Environment(name: '默认环境')));
    active = value.active.clamp(0, envs.length - 1);
    bucket.text = value.bucket;
    login.text = value.loginNo;
    channel.text = value.channel;
    proxy.addListener(() => proxyStore.save(proxy.text));
    proxyStore.load().then((saved) {
      if (mounted) proxy.text = saved;
    });
  }

  @override
  void dispose() {
    for (final env in envs) {
      env.dispose();
    }
    for (final field in [
      bucket,
      login,
      channel,
      password,
      keyPassword,
      alias,
      proxy,
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
      final settings = ConnectionSettings.multi(
        environments: [for (final env in envs) env.value],
        active: active,
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
              : '设置保存失败，请检查本地 .config 目录访问权限。';
        });
      }
    }
  }

  /// 查询 GitHub 最新 Release；发现新版本时进入统一更新流程（应用内下载或浏览器下载）。
  Future<void> checkUpdate() async {
    setState(() => checkingUpdate = true);
    try {
      final version = await readAppVersion();
      final update = await checkLatestRelease(currentVersion: version);
      if (!mounted) return;
      if (update != null) {
        await showUpdateDialog(context, update);
      } else {
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('已是最新版本'),
            content: Text(
              '当前版本 v$version 已是最新。',
              style: const TextStyle(fontSize: 13, height: 1.7),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('关闭'),
              ),
            ],
          ),
        );
      }
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
          error = '移除密钥失败，请检查本地配置目录访问权限。';
        });
      }
    }
  }

  Widget _sectionHeader(IconData icon, String title, {Widget? trailing}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          children: [
            Icon(icon, size: 15, color: const Color(0xff2563eb)),
            const SizedBox(width: 6),
            Text(
              title,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
                color: Color(0xff0f1e36),
              ),
            ),
            if (trailing != null) ...[const Spacer(), trailing],
          ],
        ),
      );

  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: Colors.white,
    surfaceTintColor: Colors.transparent,
    insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: const BorderSide(color: Color(0xffdde6f1)),
    ),
    titlePadding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
    contentPadding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
    actionsPadding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
    title: Row(
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: const Color(0xffeaf2ff),
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: const Color(0xffbfdbfe)),
          ),
          child: const Icon(
            Icons.tune_rounded,
            size: 18,
            color: Color(0xff2563eb),
          ),
        ),
        const SizedBox(width: 12),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '连接与密钥设置',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: Color(0xff0f1e36),
                ),
              ),
              SizedBox(height: 2),
              Text(
                '原生直连后台 · 所有接口仅用于查询',
                style: TextStyle(
                  color: Color(0xff64748b),
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          onPressed: saving ? null : () => Navigator.pop(context),
          icon: const Icon(Icons.close, size: 18, color: Color(0xff475569)),
        ),
      ],
    ),
    content: SizedBox(
      width: 580,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            environments(),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xfff8fafd),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xffe4ecf6)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sectionHeader(Icons.verified_user_outlined, '鉴权与存储参数'),
                  Row(
                    children: [
                      Expanded(child: _field(login, 'JWT 工号', bottom: 10)),
                      const SizedBox(width: 10),
                      Expanded(child: _field(channel, 'JWT 渠道', bottom: 10)),
                    ],
                  ),
                  _field(
                    bucket,
                    'OBS 桶覆盖（可选）',
                    hint: '留空按 receipt + regionCode',
                    bottom: 0,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xfff8fafd),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xffe4ecf6)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sectionHeader(
                    Icons.vpn_key_outlined,
                    '密钥库与签名证书',
                    trailing: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: widget.controller.signer == null
                            ? const Color(0xfff1f5f9)
                            : const Color(0xffecfdf5),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: widget.controller.signer == null
                              ? const Color(0xffe2e8f0)
                              : const Color(0xffa7f3d0),
                        ),
                      ),
                      child: Text(
                        widget.controller.signer == null
                            ? '尚未加载密钥'
                            : '${widget.controller.keyPersisted ? '已安全保存' : '已加载'}：${widget.controller.signer!.alias}',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: widget.controller.signer == null
                              ? const Color(0xff64748b)
                              : const Color(0xff047857),
                        ),
                      ),
                    ),
                  ),
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      OutlinedButton.icon(
                        onPressed: saving ? null : pick,
                        icon: const Icon(Icons.key_outlined, size: 16),
                        label: Text(
                          fileName.isEmpty ? '选择密钥文件（JKS / PEM）' : fileName,
                        ),
                        style: OutlinedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: const Color(0xff2563eb),
                          side: const BorderSide(color: Color(0xffbfdbfe)),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(9),
                          ),
                          textStyle: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (widget.controller.signer != null ||
                          widget.controller.keyPersisted)
                        TextButton.icon(
                          onPressed: saving ? null : removeKey,
                          icon: const Icon(Icons.key_off_outlined, size: 16),
                          label: const Text('移除已保存密钥'),
                          style: TextButton.styleFrom(
                            foregroundColor: const Color(0xffdc2626),
                            textStyle: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      if (constraints.maxWidth < 460) {
                        return Column(
                          children: [
                            _field(
                              password,
                              'JKS 密钥库密码',
                              obscure: true,
                              bottom: 10,
                            ),
                            _field(
                              keyPassword,
                              '私钥密码（相同时留空）',
                              obscure: true,
                              bottom: 10,
                            ),
                            _field(alias, '私钥别名（单个私钥时留空）', bottom: 8),
                          ],
                        );
                      }
                      return Column(
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: _field(
                                  password,
                                  'JKS 密钥库密码',
                                  obscure: true,
                                  bottom: 10,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: _field(
                                  keyPassword,
                                  '私钥密码（相同时留空）',
                                  obscure: true,
                                  bottom: 10,
                                ),
                              ),
                            ],
                          ),
                          _field(alias, '私钥别名（单个私钥时留空）', bottom: 8),
                        ],
                      );
                    },
                  ),
                  const Text(
                    '配置和业务密钥保存在本机 .config/npl-maintenance 目录（桌面位于用户目录，手机位于应用目录）。密钥文件不另设密码，macOS 文件权限为 600；迁移成功后清理旧钥匙串副本。下次启动直接恢复，不保存导入密码。',
                    style: TextStyle(
                      fontSize: 11,
                      color: Color(0xff64748b),
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xfff8fafd),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xffe4ecf6)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sectionHeader(
                    Icons.cloud_download_outlined,
                    '更新与网络加速',
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        FutureBuilder<String>(
                          future: appVersion,
                          builder: (context, snapshot) => Text(
                            snapshot.hasData
                                ? '当前版本 v${snapshot.data}'
                                : snapshot.hasError
                                ? '当前版本读取失败'
                                : '正在读取版本…',
                            style: const TextStyle(
                              fontFamily: 'Menlo',
                              fontSize: 11,
                              color: Color(0xff64748b),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        TextButton.icon(
                          onPressed: saving || checkingUpdate
                              ? null
                              : checkUpdate,
                          icon: const Icon(Icons.system_update_alt, size: 15),
                          label: Text(checkingUpdate ? '正在检查…' : '检查更新'),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            textStyle: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  _field(
                    proxy,
                    'GitHub 加速站（可选）',
                    hint: 'https://ghproxy.net/ （留空直连，仅影响更新下载）',
                    bottom: 0,
                  ),
                ],
              ),
            ),
            if (error.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(top: 12),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xfffef2f2),
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: const Color(0xfffecaca)),
                ),
                child: SelectableText(
                  error,
                  style: const TextStyle(
                    color: Color(0xffb91c1c),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
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
      FilledButton.icon(
        onPressed: saving ? null : save,
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xff2563eb),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          textStyle: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
        icon: Icon(
          saving ? Icons.hourglass_top_rounded : Icons.check_rounded,
          size: 16,
        ),
        label: Text(saving ? '正在加载…' : '保存设置'),
      ),
    ],
  );

  /// 每个环境一组服务地址与 web 地址；左侧圆点选择当前环境。
  Widget environments() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          const Icon(Icons.dns_outlined, size: 15, color: Color(0xff2563eb)),
          const SizedBox(width: 6),
          const Text(
            '环境',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
              color: Color(0xff0f1e36),
            ),
          ),
          const Spacer(),
          TextButton.icon(
            onPressed: saving
                ? null
                : () => setState(
                    () => envs.add(
                      _EnvFields(Environment(name: '环境${envs.length + 1}')),
                    ),
                  ),
            icon: const Icon(Icons.add, size: 16),
            label: const Text('新增环境'),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      for (var i = 0; i < envs.length; i++)
        Container(
          key: ObjectKey(envs[i]),
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.fromLTRB(6, 10, 8, 2),
          decoration: BoxDecoration(
            color: i == active
                ? const Color(0xfff2f7ff)
                : const Color(0xfff8fafd),
            border: Border.all(
              color: i == active
                  ? const Color(0xff2563eb)
                  : const Color(0xffdde6f1),
              width: i == active ? 1.4 : 1,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IconButton(
                tooltip: i == active ? '当前环境' : '设为当前环境',
                onPressed: saving ? null : () => setState(() => active = i),
                icon: Icon(
                  i == active
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 20,
                  color: i == active
                      ? const Color(0xff2563eb)
                      : const Color(0xff94a3b8),
                ),
              ),
              Expanded(
                child: Column(
                  children: [
                    _field(envs[i].name, '环境名称', bottom: 8),
                    _field(
                      envs[i].base,
                      '服务地址 baseUrl',
                      hint: 'https://服务地址/上下文',
                      bottom: 8,
                    ),
                    _field(
                      envs[i].web,
                      'web 地址（可选，仅日志文件使用）',
                      hint: 'https://web地址/上下文',
                      bottom: 8,
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '删除环境',
                onPressed: saving || envs.length == 1
                    ? null
                    : () => removeEnv(i),
                icon: const Icon(Icons.delete_outline, size: 19),
              ),
            ],
          ),
        ),
    ],
  );

  void removeEnv(int index) {
    final removed = envs[index];
    setState(() {
      envs.removeAt(index);
      if (active > index || active >= envs.length) active--;
      if (active < 0) active = 0;
    });
    // 等本帧重建完成、输入框解除绑定后再释放控制器。
    WidgetsBinding.instance.addPostFrameCallback((_) => removed.dispose());
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    String? hint,
    bool obscure = false,
    double bottom = 12,
  }) => Padding(
    padding: EdgeInsets.only(bottom: bottom),
    child: TextField(
      controller: controller,
      obscureText: obscure,
      enabled: !saving,
      enableSuggestions: !obscure,
      autocorrect: false,
      style: const TextStyle(fontSize: 12.5, color: Color(0xff0f1e36)),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        fillColor: Colors.white,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 11,
        ),
      ),
    ),
  );
}

JwtSigner _importKey(Map<String, Object> value) => JwtSigner.import(
  value['bytes'] as Uint8List,
  password: value['password'] as String,
  keyPassword: value['keyPassword'] as String,
  alias: value['alias'] as String,
);

/// 单个环境的输入框组。
class _EnvFields {
  final TextEditingController name, base, web;
  _EnvFields(Environment value)
    : name = TextEditingController(text: value.name),
      base = TextEditingController(text: value.baseUrl),
      web = TextEditingController(text: value.webBaseUrl);
  Environment get value => Environment(
    name: name.text.trim(),
    baseUrl: base.text.trim().replaceAll(RegExp(r'/+$'), ''),
    webBaseUrl: web.text.trim().replaceAll(RegExp(r'/+$'), ''),
  );
  void dispose() {
    name.dispose();
    base.dispose();
    web.dispose();
  }
}
