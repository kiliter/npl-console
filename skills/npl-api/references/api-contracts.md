# 接口与返回约定

依据 npl-maintenance 当前客户端 contracts.dart、maintenance_controller.dart、jwt_signer.dart 及已确认的响应处理规则整理。后端新增能力不在此范围。

## 配置

默认读取 `~/.config/npl-api/auth.json`，也可用 `--config /绝对路径/配置.json` 或环境变量 `NPL_CONFIG` 覆盖。外部配置字段：`baseUrl`（可带上下文路径）、`loginNo`、`channel`、`keyFile`、`storePassword`、`keyPassword`、可选 `bucket`、`keyAlias`。按照用户要求，密码集中保存在该外部文件中，文件权限应为 0600，不纳入 Git 或技能包，不打印文件内容。keyFile 支持相对于 auth.json 所在目录的路径，例如 `agilestar.keystore`。keyPassword 留空时沿用 JKS 的 storePassword。

环境变量仍可覆盖配置：`NPL_BASE_URL`、`NPL_LOGIN_NO`、`NPL_CHANNEL`、`NPL_BUCKET`、`NPL_KEY_FILE`、`NPL_KEY_ALIAS`、`NPL_STORE_PASSWORD`、`NPL_KEY_PASSWORD`；也可直接提供临时 `NPL_TOKEN`。日常使用无需配置环境变量。不自动读取应用钥匙串，不内置真实业务连接。

PKCS#8 PEM/DER 与 JKS 均支持。JKS 有多个私钥时指定别名。JWT 为 RS256，声明包括 loginNo、channelCode、iss=channel、sub=token、aud=az、iat、exp=iat+1200；同一个 JWT 放入 kkk 和 agAuthorization 两个请求头。程序不打印认证头。依赖通过技能虚拟环境安装。

## 命令和接口

可在 auth.json 中设置 `"verifyTls": false`，按用户明确要求跳过此 Skill 的 HTTPS 证书和主机名校验；不影响系统或其他应用。未配置时为 true，使用 certifi 可信 CA。

所有接口使用 POST。前四项和全量报文使用 JSON，OBS 使用 URL 编码表单。禁止自动跳转，默认请求超时六十秒。

| 命令 | 路径 | 参数 | response 内容 |
|---|---|---|---|
| work-query | /api/wo/queryList | caseNo；或 phoneNo/sysAccept 加 opMonth | 完整工单数组 |
| message-query | /api/wobiz/queryList | caseNo、sysAccept、opMonth | 完整报文记录数组 |
| sign-query | /api/wosign/queryList | caseNo、sysAccept、opMonth | 完整签字数组 |
| picture-query | /api/wopic/queryList | caseNo、sysAccept、opMonth，可加 picSeq | 完整图片数组 |
| file-download | /test/un_look | bucketName、objectName、ext8 | 处理后的文本；或二进制文件路径、类型和字节数 |
| message-download | /agapi/biz/downloadBiz | caseNo | 完整信封，data 和 reqData 解析展开，其他字段保留 |

四类查询至少提供一个条件；单独按 sysAccept 查询需月份。月份输入 YYYY-MM，发送 YYYYMM。手机号查询仅工单支持，不能混用其他标识；需月份。工单跨月可用 `--start-month`、`--end-month`，最多十二个月，每月独立返回，不去重。按单据号可不传月份，由服务端解析。

返回共同字段：`ok`、`endpoint`、`httpStatus`、`durationMs`、`responseBytes`（原始响应字节数）、`request`、`response`；查询数组附 `count`。跨月返回 `ok` 和 `results`。网络等异常返回安全错误类型，HTTP 错误仍返回经过过滤的正文。全量报文根据外层 result 是否为 0 判断业务成功，内层信封不丢弃。过滤或解析失败返回 error，不返回原文。退出码 0 为成功，1 为失败或部分失败，参数语法错误为 2。

## OBS 对象命名

- 桶名优先使用显式 bucket，否则可根据工单 regionCode 手工构造 `receipt{regionCode}`。
- 工单 PDF：`{caseNo}.pdf`。
- 留存报文：`{caseNo}_{cmdCode}.txt`、`{caseNo}_{cmdCode}_oprInfo.txt`、`{caseNo}_{cmdCode}_h5.txt`。
- 签字和图片：分别取 signPath 或 picPath，统一路径分隔符后取最后一段。
- ext8 使用工单字段，缺失时为字符串 0。
- `--kind text` 返回 JSON/XML/文本，按结构屏蔽 acceptContent；无法可靠处理的文本不回显。
- `--kind pdf/image --output /绝对路径/文件` 按魔数校验后保存。JSON 错误页不会当成文件保存。

## 响应过滤

所有 JSON 字符串按结构递归解析，保留原本普通字符串类型。acceptContent 在解析嵌套值之前直接替换，避免处理庞大的受理正文。服务端若将 JSON 对象未转义放入字符串，限定修复该已知模式。JSON/XML 解析失败不回显未经处理的文本。XML 同名元素或属性同样屏蔽；XML 序列化可能改变空白或命名空间前缀，但保留其余语义内容。

不屏蔽 reqData，不省略证件字段、扩展参数、null、空数组或其他字段；不输出整包转义字符串，不自动截断，不对重复响应进行合并。
