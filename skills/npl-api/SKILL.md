---
name: npl-api
description: 调用 NPL 无纸化维护接口，查询工单、报文、签字、图片，读取 OBS 文件或下载全量报文以排查问题。通过脚本解析 data 和 reqData 的 JSON 转义字符串，完整保留其他字段，只屏蔽各接口响应中所有层级的 acceptContent。适用于 NPL 业务数据查询和报文分析，不用于修改或删除业务数据。
---

# NPL 接口调用

使用本技能 `scripts/npl_api.py` 的六个子命令。优先使用技能目录 `.venv/bin/python`；未安装依赖时，用独立虚拟环境安装 `scripts/requirements.txt`。路径按当前 SKILL.md 所在目录解析，不依赖项目工作目录。

## 执行流程

1. 按用户提供的单据号或条件选择命令；默认读取 `~/.config/npl-api/auth.json`，无需额外环境变量。缺少配置时检查该文件或用户指定的配置，不查找或输出密钥、密码内容。keyFile 相对于配置文件所在目录解析。
2. 工单定位用 `work-query`；主要排查输入用 `message-download`，保留展开后的全部 `data.reqData`。记录或文件问题再调用其余命令。
3. 所有文本响应只通过脚本输出。不要直接使用 curl 或打印原始日志绕过屏蔽。不要为节省上下文自行删除其他字段、空值、重复结果或截断 reqData。
4. 各接口响应单独处理：递归替换 `acceptContent` 为 `[已屏蔽]`；解析包括 data、reqData 在内的嵌套 JSON 字符串。解析失败报告错误，不回显原文。
5. 将 HTTP 失败、业务失败、解析失败分别说明，不把离线测试说成真实业务联调成功。命令非零退出码表示失败或跨月部分失败。

接口参数、配置及每个命令的输出见 [接口约定](references/api-contracts.md)。每个子命令支持 `--help`，显示中文参数说明。

## 六个命令

```bash
# 将此处 python 替换为技能目录 .venv/bin/python，入口使用技能目录的绝对路径。
python scripts/npl_api.py work-query --case-no 单据号
python scripts/npl_api.py message-query --case-no 单据号 --month 2026-08
python scripts/npl_api.py sign-query --case-no 单据号 --month 2026-08
python scripts/npl_api.py picture-query --case-no 单据号 --month 2026-08
python scripts/npl_api.py file-download --bucket 桶名 --object-name 对象名 --ext8 0 --kind text
python scripts/npl_api.py message-download --case-no 单据号
```

## 输出边界

- 仅 `acceptContent` 的值被屏蔽；字段名保留，包括原值为 null 的情形。不提供原文输出开关。
- 文本 `--output` 保存同一份处理后的完整 JSON；已有文件不覆盖。
- 图片和 PDF 保存到 `--output`，返回路径、类型、大小，不输出 Base64。下载文件不是文本排查输入，不能通过转换下载文件绕过字段屏蔽。
- 不修改应用、原始请求日志或服务器数据。技能不包含真实配置、账号、密钥、JWT 或业务样本。
