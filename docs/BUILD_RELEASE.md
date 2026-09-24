# 正式包自动发布

四端统一使用固定 Flutter 3.44.7、`--release -t lib/main.dart`，源码取对应版本标签。工作流见 `.github/workflows/release.yml`。

## 创建新版本

先提交并推送代码，再创建版本标签：

```bash
git tag -a v0.0.2 -m "发布 v0.0.2"
git push origin v0.0.2
```

推送 `v*` 标签自动触发；正式版本格式为 `v数字.数字.数字`。macOS 执行静态检查、全量 Flutter 测试；四端构建全部成功后汇集附件并发布 Release。失败时不发布不完整的新版本。

已有标签可手动补发，无需移动标签：

```bash
gh workflow run release.yml --ref main -f tag=v0.0.1
```

手动补发使用 main 的工作流定义，但业务源码仍取指定标签。相同标签附件会覆盖，请仅在修复构建流程后使用。

## 签名配置

Android 使用同一长期发布密钥，以下仓库 Actions Secrets 必须齐全，缺少时构建失败，不回退 Debug：

- `ANDROID_KEYSTORE_BASE64`：发布 JKS 的 Base64。
- `ANDROID_KEYSTORE_PASSWORD`：密钥库密码。
- `ANDROID_KEY_ALIAS`：密钥别名。
- `ANDROID_KEY_PASSWORD`：私钥密码。

密钥仅在 runner 临时目录还原，不进入 Git 或发布附件。本地 `.release-signing/` 与 `android/key.properties` 已忽略，请安全备份，后续更新沿用同一密钥。

macOS 使用 ad-hoc 签名且不启用 App Sandbox（沙盒会阻止应用内更新写盘与拉起安装），提供 Universal DMG；没有 Developer ID 或 Apple 公证，其他 Mac 可能阻止直接打开。

Windows 在 runner 生成自签名证书签署主程序，ZIP 仅附公钥证书。完整解压后运行 EXE，系统不会默认信任该证书，可能显示 SmartScreen。

iOS 提供真机 arm64 未签名 Release IPA，需有效 Apple 开发者证书和描述文件重签名后安装，自生成证书不能替代 Apple 签名。

## 产物与验证

发布 APK、DMG、Windows ZIP、未签名 IPA 四份安装包。不发布 Debug、模拟器包或 AAB。

全量测试在 macOS 正式构建后执行，以确保 PDFium 原生库可用。附件仅在 GitHub runner 汇集上传，临时 Actions artifact 保留 1 天；不下载到维护者电脑，不生成额外哈希文件。Release 附件正常保留。
