# 正式包构建与签名

所有发布命令使用 `--release -t lib/main.dart`。禁止把 `tool/keychain_probe.dart`、模拟器包或 Debug 包作为正式发布附件。

## Android

生成长期使用的发布 JKS，保存在仓库外或被忽略的 `.release-signing/`。将以下字段写入被忽略的 `android/key.properties`，不要提交真实内容：`storeFile`（绝对路径）、`storePassword`、`keyAlias`、`keyPassword`。Gradle 已配置独立 Release 签名，不回退到 Debug 签名。

```bash
flutter build apk --release -t lib/main.dart
```

发布 APK 位于 `build/app/outputs/flutter-apk/app-release.apk`。请在安全位置备份发布 JKS 和密码，后续升级必须沿用。发布签名改变后，旧 Debug 签名安装无法覆盖升级。

## macOS

```bash
flutter build macos --release -t lib/main.dart
codesign --verify --deep --strict 'build/macos/Build/Products/Release/NPL Maintenance.app'
```

当前工程固定包标识 `cn.agilestar.nplMaintenance`，使用本机 Apple Development 签名。新环境需在 Xcode 选择自己的团队。没有对应证书时，可通过 Xcode 的 `CODE_SIGNING_ALLOWED=NO` 构建并明确标注未签名，不能假装已公证。

把 `.app` 和指向 `/Applications` 的快捷方式放入临时目录，用 `hdiutil create -srcfolder` 制作 DMG。开发签名不等于 Developer ID 分发与 Apple 公证，本次没有公证。

## iOS 真机

```bash
flutter build ios --release --no-codesign -t lib/main.dart
mkdir -p dist/ios-stage/Payload
cp -R build/ios/iphoneos/Runner.app dist/ios-stage/Payload/
(cd dist/ios-stage && zip -qry ../NPL-Console-v1.0.0-ios-unsigned.ipa Payload)
```

未签名 IPA 不能直接安装到 iPhone。用户需用有效开发者证书、App ID 和设备描述文件重签名；自行生成自签名证书不能替代 Apple 的签名体系。本次提供真机 arm64 Release IPA，不提供模拟器包。

## Windows

在 Windows 上执行 `flutter build windows --release -t lib/main.dart`。完整打包 `build/windows/x64/runner/Release/`，必须保留 DLL 和 data 目录。

仓库工作流使用固定 Flutter 版本构建，通过 Windows SDK 的 `signtool` 为主程序添加构建机生成的自签名。随包仅附公钥证书，不附私钥；Windows 不会默认信任该证书。它不是付费受信代码签名证书，也不会消除 SmartScreen 提示。

## 发布检查

1. 运行 `flutter analyze` 和 `flutter test`，修复失败后再构建。
2. 四端正式包必须全部构建成功；核对架构和签名状态。
3. 将源码提交到指定仓库，确保 Windows 工作流构建相同提交。
4. Release 先建草稿，上传各包、说明与 `SHA256SUMS.txt` 后发布。
5. 不提交 `.release-signing/`、`android/key.properties`、本机配置、构建目录或真实业务凭据。
