# 审查报告 04:第二轮 Prompt 与工具契约

> 审查时间: 2026-07-11
> 审查范围: Prompt Pipeline、Message Contract、JSON Schema、Tool Registry、上下文预算和消息压缩
> 审查结论:核心契约完整,发现 1 项旧权限状态和 1 处关联注释漂移

## 1. 已核对证据

- `AgentPromptBuilder` 是 system prompt、execution mode、语言、External Search 边界、冻结上下文和附件注入的唯一入口。
- 首轮 user message 持久化完整目标与冻结上下文,后续轮次只回放压缩后的消息链,没有重复拼接上下文。
- `AgentMessageContract` 校验 runID、消息 sequence、role/part 组合、tool-call ID 唯一性及 tool-result 关联。
- `AgentMessageCompactor` 只压缩发送给模型的副本,保留首个目标和最近完整 tool turn,不会修改数据库事实。
- `AgentJSONSchema` 支持 object/array/enum/required/additionalProperties 与 JSON path 错误;`AgentToolRegistry` 在执行前统一校验。
- Tool name 在 Registry 和 Provider adapter 之间共享 OpenAI-compatible 命名约束。

## 2. 发现项

### P1-1 工具执行结果仍保留旧版 requiresConfirmation 状态

`AgentToolStatus.requiresConfirmation` 表达“工具执行后再请求确认”,而当前正式契约由 `AgentToolPermission` 和 `ApprovalCoordinator` 在工具执行前暂停、持久化并等待用户决策。继续保留该状态会给后续写入工具提供错误用法,Runtime 目前还会把它映射为 rejected,但此时工具已经执行。

修复:删除 `AgentToolStatus.requiresConfirmation` 及对应 switch 分支,确认请求只能由 Runtime 基于工具 permission 创建。

### P2-1 权限注释仍称当前只实现只读工具

`AgentTools.swift` 的注释没有反映 `requiresConfirmation`、`highCost`、Approval 暂停恢复和测试已经落地的事实。

修复:更新注释,明确正式产品 Agent 当前只注册只读工具,但框架权限闭环已经实现。

## 3. 无问题项

- Prompt 没有按 Agent 散落成多套 system prompt。
- 模型只看到当前 mode 与 definition 共同允许的工具。
- 工具参数错误会作为可审计 error tool-result 回灌,不会静默修正或直接执行。
- 没有引入 Cline 的 shell、文件编辑或浏览器工具 schema。
- Prompt/Message/Tool/JSON 单测覆盖当前核心边界。

## 4. 修复顺序

1. 删除旧版 post-execution confirmation 状态。
2. 更新权限边界注释并运行相关专项测试。
