# 记录格式与操作示例

所有输入是 UTF-8 JSON。示例只是字段格式，不代表已确认业务规则。生成临时输入文件时不要写入凭据。脚本返回 `ok` 与 `result`，失败时非零退出码。

## 开始排查

`start --input 输入文件`：

```json
{
  "title": "本次异常现象简述",
  "symptom": "用户观察到的实际现象及预期结果",
  "environment": "用户确认的环境；未知则写待确认",
  "tags": ["业务关键词", "相关字段"],
  "sources": []
}
```

sources 可填写检索到的案例或流程 ID。返回的 run ID 用于后续 check。

## 追加检查步骤

`check --id run-ID --input 输入文件`：

```json
{
  "step": "步骤编号及名称",
  "action": "实际调用的 npl-api 命令及必要查询条件",
  "expected": "根据已确认规则应观察到什么；无规则则明确待确认",
  "observed": "接口实际表现，不能填推测",
  "evidence": "接口路径、字段路径、关键结果及可选的处理后响应文件路径",
  "result": "待验证",
  "next": "下一步检查什么及原因"
}
```

result 只允许：通过、异常、待验证、不适用。每次独立接口失败也应记录，不能把未取得响应写成字段缺失。

## 保存案例草稿

`save-case --input 输入文件`：

```json
{
  "runId": "实际排查 ID",
  "title": "案例标题",
  "symptom": "用户现象",
  "environment": "实际环境",
  "tags": ["检索关键词"],
  "hypothesis": "证据支持的原因或尚未确认的假设",
  "resolution": "已实际验证的处理结果；未验证则明确说明",
  "limitations": "仍缺少哪些证据以及结论适用范围"
}
```

脚本快照保存来源 run 的检查记录。初始为待确认；须用户明确确认后执行 confirm，并保留其确认原话。不把待验证处理建议写成已解决。

## 提炼流程草稿

`promote --input 输入文件`，caseId 必须为已确认案例：

```json
{
  "caseId": "实际已确认案例 ID",
  "title": "场景名称",
  "symptom": "可用于检索的现象",
  "environment": "经确认的适用环境",
  "tags": ["业务关键词"],
  "applicability": "什么时候使用此流程",
  "exclusions": "什么情况不适用；没有验证的范围应明确列出",
  "conclusionCriteria": "必须满足哪些证据才能下结论",
  "steps": [
    {
      "id": "S1",
      "action": "需要哪个接口以及查看哪些字段",
      "expected": "来自已确认案例或规则的预期",
      "onPass": "通过后检查什么",
      "onFail": "异常后检查什么，何种证据允许结束",
      "onUnknown": "缺少证据时如何补充或停止"
    }
  ]
}
```

分支是中文排查指引，不是自动执行的代码。AI 必须对照实际结果逐步执行，不能直接运行 action 内的任意文字。流程需要独立确认，不能因源案例已确认就自动批准流程。

## 反例与修订

`flag --id ID --input 输入文件`：

```json
{"reason": "指出本次哪条证据与原结论矛盾，并引用排查 ID"}
```

`revise --id ID --input 输入文件`：

```json
{
  "reason": "为何需要修改，以及新的证据来源",
  "changes": {"limitations": "修订后的适用范围与限制"}
}
```

案例可修订 title、symptom、environment、tags、hypothesis、resolution、limitations；流程可修订 title、symptom、environment、tags、applicability、exclusions、conclusionCriteria、steps。流程 steps 修改需提交完整步骤数组。修订后重新待确认，历史保留修改前字段。

## 文件组织

```text
/Users/zhangjialin/IdeaProjects/agilestar/npl-js/.troubleshoot/
├── index.json        # 自动生成的轻量索引
├── runs/             # 本次排查的 JSON 及中文 Markdown 阅读副本
├── cases/            # 案例、确认信息与历史
└── procedures/       # 适用范围、分支步骤与历史
```

JSON 是事实源；Markdown 为阅读副本，修改请通过 revise 命令。init 可重新生成索引。目录和文件只对当前用户开放；库未自动删除历史，不会同步到其他服务。此库独立于 Codex 的内置记忆。

该目录随 npl-js 代码版本管理；锁文件 `.lock` 和原子写入临时文件 `.write-*` 不纳入 Git。案例、流程、排查记录与 index.json 可正常提交；提交、推送遵循项目规则及用户授权。跨机器或工作树通过 `--root` 指定该克隆下的 `.troubleshoot`。认证文件留在用户配置目录，不跟随迁移。
