# 无纸化维护中心 · NPL Console

基于 Flutter 的原生只读工单维护工具。通过工单关联查看 PDF、报文、签字和图片，支持 macOS、Windows、iOS、Android。客户端直接发起 HTTP 请求，不依赖浏览器跨域代理。

## 下载与安装

从 [Releases](https://github.com/kiliter/npl-console/releases) 下载对应平台的 **Release 正式模式**安装包。Release 模式与是否拥有平台信任签名是两回事，具体如下。

| 平台 | 文件 | 签名及安装 |
| --- | --- | --- |
| Windows x64 | `windows-x64-selfsigned.zip` | 完整解压后运行 `npl_maintenance.exe`；构建机生成自签名，非系统信任证书，可能出现 SmartScreen 提示。附带公钥证书仅供核对，无需导入系统信任根。 |
| macOS Apple Silicon / Intel | `macos-universal.dmg` | 打开后拖入应用程序；使用 CI ad-hoc 签名，未做 Developer ID 签名或 Apple 公证，其他 Mac 可能提示无法验证开发者。 |
| Android | `android-release.apk` | 使用独立 RSA 发布密钥签名，可侧载安装；支持 arm64、armv7 和 x86_64。旧版使用 Debug 签名，不能直接覆盖，卸载前请确认可重新导入业务密钥。 |
| iOS 真机 | `ios-unsigned.ipa` | 真机 Release 构建，未签名；需使用自己的 Apple 开发者证书和设备描述文件重新签名后安装，不是模拟器包，也不能直接安装。 |

四端安装包均由 GitHub Actions 构建并上传，无需在本机下载产物进行哈希校验。安装包不内置业务私钥、密码、服务地址或查询数据。具体系统最低版本以构建产物和平台配置为准。

## 首次使用

1. 打开应用，桌面点 **设置**，手机点 **更多操作 → 连接与密钥设置**。
2. 设置服务地址，包含实际部署上下文，不要额外拼上 `/api`；填写 JWT 工号与渠道。OBS 桶覆盖按环境需要填写。
3. 选择自己的 `.keystore` / `.jks` 密钥库并输入密码；也支持 PKCS#8 PEM / DER。私钥密码与库密码相同时可留空。
4. 点击搜索入口，选择 **手机号码、受理流水或单据号**。手机号/流水默认查单月，可切换范围；首尾合计最多 12 个月。
5. 从结果中选择工单，再查看单据信息、PDF、报文、签字或图片。范围查询展示进度，可取消并保留已完成月份。
6. 下载按钮通过系统文件选择器保存原始文件；接口记录可查看真实 URL、方法、请求与响应。

### 搜索历史与缓存

- 本地保留最近 **30 次合法提交**的查询条件，重启后恢复；失败或取消的查询也保留。点击历史回填条件，再点击查询；清空会同步删除本地历史。
- 接口请求完成后追加到系统应用数据目录的 `request-logs/requests-*.jsonl`，每次启动使用独立文件并立即刷新；实际路径在“接口调用记录”中展示。日志保留完整文本请求和响应以供分析，文件下载只记录大小和类型，不记录认证头、JWT 或密钥。历史文件不会自动删除。
- 历史包含查询号码和月份，只保存本机。接口成功响应在内存中缓存 5 分钟，最多 128 条 / 64 MiB；失败不缓存。
- 桌面缓存按钮或手机菜单可清空缓存；文件重新读取和关联列表刷新会主动请求。

### 单据信息与文件阅读

- 根据 `WO_INFO202610` 建表字段显示单据，排除额外 Bean 属性。
- 普通字段无数据（null、空白字符串、空集合）时隐藏；**EXT1～EXT10 全部保留**。0 与 false 属于有效值。
- 字段支持搜索、分组折叠、完整长值、复制和 JSON 导出。导出采用相同字段规则，接口日志保留原始响应。
- 桌面支持详情与 PDF 分栏、拖动分隔线；PDF 使用原生 PDFium 连续阅读，支持缩略图、页码跳转、适应宽度/整页和缩放。
- PDF、文本、图片的全屏仅覆盖 **App 内部**，不会切换 macOS 系统桌面；Esc 或退出按钮返回。
- 报文支持 JSON/XML 解析、字段折叠、Key/内容搜索，以及嵌套字符串与 CDATA 逐层专注；面包屑返回上层。
- 多张图片和签字在同一画廊连续展示，单图支持下载、全屏和读取失败重试。

### 密钥保存

首次导入后自动写入系统安全存储，后续启动恢复。macOS 使用登录钥匙串，iOS 使用仅本机钥匙串且不同步 iCloud，Android 使用 Keystore 加密存储，Windows 使用插件提供的 Windows 安全存储。密钥库密码和 JWT 不持久化，日志不记录认证头与私钥。

业务 JWT 密钥与给安装包签名的发布密钥是不同用途，不能混用。

## 接口契约

所有请求均为只读业务查询。当前客户端适配以下接口；服务端须实现相同契约。

| 内容 | POST 路径 | 请求 |
| --- | --- | --- |
| 工单 | `/api/wo/queryList` | `caseNo` 或 `sysAccept/phoneNo + opMonth` |
| 报文 | `/api/wobiz/queryList` | 选中工单的 `caseNo + opMonth` |
| 签字 | `/api/wosign/queryList` | 同上 |
| 图片 | `/api/wopic/queryList` | 同上 |
| 全量报文 | `/agapi/biz/downloadBiz` | `caseNo`，返回 `{result, data, desc}`，`result` 为 0 时 `data` 为报文内容 |
| OBS | `/test/un_look` | 表单 `bucketName + objectName + ext8` |

JWT 使用 RS256，有效期 20 分钟，通过 `kkk` 与 `agAuthorization` 请求头发送。HTTP 出口限制为上述路径，不包含新增、修改、删除和上传接口。默认保持系统 HTTPS 校验，不跟随重定向。

「数据查询」面板按物理表（WO_INFO / WO_BIZ_INFO / WO_SIGN_INFO / WO_PIC_INFO）直查数据，复用上表四个只读接口，不新增接口路径。请求体为按表组合的非空条件：`caseNo`、`sysAccept`、`opMonth`（`YYYYMM`，定位月份分表）、`picSeq`（仅图片表）；至少填写一个条件，按受理流水查询须搭配业务月份。结果以表格展示，点击行查看完整字段。

## 本地开发与构建

固定 Flutter **3.44.7** / Dart **3.12.2**，依赖版本见 `pubspec.lock`。macOS/iOS 使用 Xcode，Android 使用 Android SDK 与 JDK 17，Windows 使用 Visual Studio 2022 C++ 桌面开发工具和 Windows SDK。

```bash
flutter pub get
flutter analyze
# PDF 测试复用本机生成的原生库，macOS 首次先构建：
flutter build macos --release -t lib/main.dart
flutter test
```

PDF 原生控件测试在 macOS 默认读取 `build/native_assets/macos/libpdfium.dylib`，其他环境通过 `PDFIUM_PATH` 指定本机对应动态库。测试夹具的 `sample.jks` 是独立生成的测试密钥，密码公开仅为测试用途，严禁用于业务环境。

四端构建和签名步骤见 [发布构建说明](docs/BUILD_RELEASE.md)。推送 `v*` 版本标签自动触发[四端正式发布工作流](.github/workflows/release.yml)，全量测试和四端构建全部成功后自动发布。

## 目录

- `lib/core/`：查询、OBS 映射、缓存、JWT、系统安全存储。
- `lib/ui/`：双端布局、搜索历史、详情、PDF、报文与画廊。
- `design/maintenance-v2/`：已确认的双端 HTML 原型，使用演示数据。
- `test/`：单元和控件测试，不连接真实业务后台。
- `docs/releases/`：版本发布记录；[CHANGELOG](CHANGELOG.md)。

构建与自动化测试不等于真实设备上的全部功能验收；本轮发布不额外操作业务 UI。
