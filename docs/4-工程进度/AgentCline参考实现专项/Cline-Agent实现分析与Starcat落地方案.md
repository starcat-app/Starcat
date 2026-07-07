# Cline Agent 实现分析与 Starcat 落地方案

> 日期: 2026-07-07
> 目的: 先把 Cline 的 Agent 实现拆清楚,再明确 Starcat 应该参考什么、不能照搬什么、以及后续如何落地真正的 LLM tool-calling loop。

## 1. 结论先行

当前 Starcat Agent 只能算“线性工具编排 v1”,还不是 Cline 式 Agent loop。

核心差异如下:

| 维度 | Cline | Starcat 当前实现 |
| --- | --- | --- |
| 工具选择权 | 模型在每轮输出 `tool-call`,Runtime 解析并执行 | Runtime 按 `AgentDefinition.toolIDs` 固定顺序执行 |
| 工具描述 | 每个工具有 `name`、`description`、`inputSchema` | 只有 `id`、`displayName`、`permission`,没有模型可读 schema |
| 会话状态 | `messages` 是单一事实源,包含 user / assistant / tool-result | 主要是 step / trace / tool output / artifact,不是模型对话消息链 |
| 循环方式 | `model -> tool-call -> tool-result -> model` 多轮迭代 | `Swift tools -> draftMarkdown -> LLM final markdown` 单次模型润色 |
| 许可控制 | tool policy + approval callback,未批准则返回错误结果进入消息链 | 有 `confirmationAction` 展示,但未形成“暂停-确认-继续执行”闭环 |
| 终止条件 | 无工具调用、达到终止工具、超过 maxIterations、abort / failure | 固定工具序列结束后生成 artifact |

因此 Starcat 应参考 Cline 的是“运行时契约和循环模型”,不是直接照搬 VS Code UI 或文件编辑工具。

## 2. Cline 实现的关键结构

本次参考 Cline 仓库 HEAD: `6f7cc4907f3d750ccd42dcca789f4079cecb667b`。

主要参考文件:

- [`sdk/packages/agents/src/agent-runtime.ts`](https://github.com/cline/cline/blob/6f7cc4907f3d750ccd42dcca789f4079cecb667b/sdk/packages/agents/src/agent-runtime.ts)
- [`sdk/packages/shared/src/agent.ts`](https://github.com/cline/cline/blob/6f7cc4907f3d750ccd42dcca789f4079cecb667b/sdk/packages/shared/src/agent.ts)
- [`sdk/packages/shared/src/llms/tools.ts`](https://github.com/cline/cline/blob/6f7cc4907f3d750ccd42dcca789f4079cecb667b/sdk/packages/shared/src/llms/tools.ts)
- [`sdk/packages/core/src/extensions/tools/definitions.ts`](https://github.com/cline/cline/blob/6f7cc4907f3d750ccd42dcca789f4079cecb667b/sdk/packages/core/src/extensions/tools/definitions.ts)
- [`sdk/packages/core/docs/messages-contract-v1.md`](https://github.com/cline/cline/blob/6f7cc4907f3d750ccd42dcca789f4079cecb667b/sdk/packages/core/docs/messages-contract-v1.md)

### 2.1 AgentRuntime 是 loop,不是任务脚本

Cline 的 `AgentRuntime.execute` 在 run 开始后进入 `while maxIterations` 循环。每一轮:

1. 发送 `turn-started` 事件。
2. 调用 `generateAssistantMessage()`。
3. 从 assistant message 中提取 `tool-call`。
4. 如果没有 tool-call,则 run 完成。
5. 如果有 tool-call,执行工具并生成 tool-result message。
6. 把 tool-result 写回 messages。
7. 进入下一轮 model call。

这个 loop 的关键不是“有工具”,而是“工具调用由模型决定,工具结果回灌给模型”。对应 Cline 源码中 `execute` 的循环、tool-call 判断和 tool-result 回灌逻辑集中在 `agent-runtime.ts` 604-711 行。

### 2.2 messages 是可回放的事实源

Cline 的消息结构定义了:

- `AgentMessageRole = user | assistant | tool`
- `AgentMessagePart` 包含 `text`、`reasoning`、`tool-call`、`tool-result` 等类型
- `AgentRuntimeStateSnapshot` 持有 `messages`、`iteration`、`pendingToolCalls`、`usage`、`lastError`

这意味着审计不是靠额外日志拼出来的,而是从会话消息链就能重放:

```text
user: 用户目标
assistant: 思考文本 + tool-call(read_files)
tool: tool-result(read_files)
assistant: tool-call(search_codebase)
tool: tool-result(search_codebase)
assistant: 最终回答
```

Cline 还把持久化消息契约单独写成 `messages-contract-v1.md`,明确 `tool_use` 和 `tool_result` 的关联 ID。Starcat 当前虽然有 trace / tool output / artifact,但还缺这种“模型对话消息链作为事实源”的层。

### 2.3 Tool 是模型可见 schema + 宿主执行器

Cline 的 `AgentToolDefinition` 包含:

- `name`
- `description`
- `inputSchema`
- `lifecycle.completesRun`

`AgentTool` 在此基础上增加:

- `timeoutMs`
- `retryable`
- `maxRetries`
- `execute(input, context)`

Runtime 发给模型的是 tool definition,真正执行的是宿主侧 `execute`。这点对 Starcat 很关键:工具 schema 是给模型看的,工具实现仍然由本地 Swift 控制。

### 2.4 Tool approval 是 runtime policy,不是 UI 按钮

Cline 的 `ToolPolicy` 至少包含:

- `enabled`
- `autoApprove`

当某个工具策略 `autoApprove == false` 时,Runtime 调 `requestToolApproval(...)`。批准后执行,拒绝后把错误结果作为 tool-result 回灌给模型。也就是说,确认流属于 Agent loop 的一部分,不是右侧面板的静态操作。

Starcat 当前有 `AgentToolPermission.requiresConfirmation` 和 `AgentConfirmationAction`,但它只是展示了确认请求,没有把“等待用户确认后继续执行同一个 tool-call”纳入 loop。

### 2.5 事件流服务于 UI,但不替代 messages

Cline 事件包括:

- `run-started`
- `message-added`
- `turn-started`
- `assistant-text-delta`
- `assistant-reasoning-delta`
- `assistant-message`
- `tool-started`
- `tool-updated`
- `tool-finished`
- `usage-updated`
- `turn-finished`
- `run-finished` / `run-failed`

UI 可以用这些事件实时渲染,但最终可审计数据仍然来自 messages。Starcat 现在的 `AgentRunEvent` 可以继续保留,但应补一个更底层的 `AgentMessage` / `AgentTurn` / `AgentToolCall` 模型,否则“可审计”会停留在 UI 事件级别。

### 2.6 Cline 的默认工具体系不能直接照搬

Cline 默认工具包括:

- `read_files`
- `search_codebase`
- `run_commands`
- `fetch_web_content`
- `editor`
- `apply_patch`
- `skills`
- `ask_question`
- `submit_and_exit`
- subagent / teams 相关工具

Starcat 第一阶段不能照搬这些高权限工具。原因:

1. Starcat 是用户 GitHub Star 管理产品,不是通用代码编辑器。
2. 当前产品原则是本地优先、AI 保守、用户确认后写入。
3. 文件编辑、shell、apply_patch 这类能力和 Starcat 核心场景不匹配,风险过高。

Starcat 应该先提供领域工具:

- `context.resolve_repos`
- `external.search`
- `artifact.build_markdown`
- `repo.inspect`
- `tag.suggest`
- `note.suggest`
- `star.unstar.request`
- `status.suggest`
- `user.ask_confirmation`
- `run.submit_artifact`

## 3. Starcat 当前实现对照

### 3.1 当前 Runtime 是固定工具序列

当前 `DefaultAgentRuntime.run` 在启动后:

1. 从 `definition.toolIDs` 找到工具数组。
2. `for (index, tool) in tools.enumerated()` 顺序执行。
3. 每个工具执行后发 step / toolOutput / trace。
4. 工具全部结束后调用 `textGenerator.generateAgentMarkdown(...)`。
5. 生成 Markdown artifact。

这说明工具执行顺序不是模型选择的,而是 AgentDefinition 预设的。代码证据:

- `Starcat/Features/Agents/Core/AgentRuntime.swift` 175-178 行: 通过 `definition.toolIDs` 解析工具。
- `Starcat/Features/Agents/Core/AgentRuntime.swift` 204-298 行: 固定 `for` 循环执行工具。
- `Starcat/Features/Agents/Core/AgentRuntime.swift` 300-321 行: 工具结束后才调用 LLM 生成最终 Markdown。

### 3.2 当前 Tool 缺少模型 schema

当前 `AgentTool` 只有:

- `id`
- `displayName`
- `permission`
- `execute(_ input:)`

代码证据: `Starcat/Features/Agents/Core/AgentTools.swift` 99-106 行。

缺少:

- 给模型看的 `description`
- JSON schema 参数
- tool call ID
- structured input decoder
- tool result message envelope
- completesRun 生命周期标记

因此现有工具只能被 Runtime 调用,不能被模型可靠选择。

### 3.3 当前 LLM 接口只输出文本

当前 `AgentTextGenerating` 的核心接口是:

- `generateAgentMarkdown(definition:prompt:context:draftMarkdown:)`
- `generateWeeklyReport(prompt:context:draftMarkdown:)`

`OpenAIAgentTextGenerator` 构造 `AIChatRequest` 时 `responseFormat: .text`,返回 `response.content`。代码证据: `Starcat/Features/Agents/Core/AgentTextGenerationService.swift` 13-25 行、83-103 行。

这说明 LLM 目前只负责“最终文本生成”,不是“每轮决定下一步工具调用”。

### 3.4 当前审计 UI 已经接近,但数据模型还不够

Starcat 现有 trace / tool output / artifact 已经能支撑中栏展开查看每一步输入输出,这是可继续使用的 UI 层资产。但它还不是 Cline 的 messages contract。

下一步应该把 trace / tool output 改成由底层 `AgentMessage` 派生:

- assistant text / reasoning -> 中栏 AI 消息块
- assistant tool-call -> 中栏“准备调用工具”步骤
- tool result -> 中栏“工具输出”详情
- final artifact -> 右侧或底部 artifact

这样 UI 和持久化不会分叉。

## 4. Starcat 应该如何参考 Cline 落地

### 4.1 第一阶段: 建立 Cline-style 核心契约

新增或改造以下模型:

```swift
enum AgentMessageRole: String, Sendable, Codable {
    case user
    case assistant
    case tool
}

enum AgentMessagePart: Sendable, Codable {
    case text(String)
    case reasoning(String)
    case toolCall(AgentToolCall)
    case toolResult(AgentToolResultMessage)
}

struct AgentToolDefinition: Sendable, Codable {
    var name: String
    var description: String
    var inputSchema: AgentJSONSchema
    var permission: AgentToolPermission
    var completesRun: Bool
}

struct AgentToolCall: Sendable, Codable {
    var id: String
    var name: String
    var input: AgentJSONValue
}

struct AgentToolResultMessage: Sendable, Codable {
    var toolCallID: String
    var toolName: String
    var output: AgentJSONValue
    var isError: Bool
}
```

原则:

- `AgentRunEvent` 可以继续给 UI 用。
- `AgentMessage` 必须成为可回放事实源。
- `AgentTraceSpan` / `AgentToolOutput` 应从 tool-call / tool-result 派生或关联,不要反过来成为事实源。

### 4.2 第二阶段: 改造模型接口

新增 `AgentLoopModelClient`,不要直接塞进现有 `generateAgentMarkdown`。

建议接口:

```swift
protocol AgentLoopModelClient: Sendable {
    func streamTurn(_ request: AgentModelTurnRequest) async throws -> AsyncThrowingStream<AgentModelStreamEvent, Error>
}

struct AgentModelTurnRequest: Sendable {
    var systemPrompt: String
    var messages: [AgentMessage]
    var tools: [AgentToolDefinition]
    var maxOutputTokens: Int
}

enum AgentModelStreamEvent: Sendable {
    case textDelta(String)
    case reasoningDelta(String)
    case toolCallDelta(AgentToolCallDelta)
    case usage(AgentUsage)
    case finish(AgentModelFinishReason)
}
```

这里不需要新增第二套 provider 设置。实现层仍然复用 Starcat 现有 AI Provider / OpenAI-compatible client,但要支持 tool schema / tool calls。若当前 `AIClientProtocol` 不支持 tool calls,则先扩展它,不要绕开设置页另建 SDK。

### 4.3 第三阶段: Runtime 从 fixed sequence 改为 model-driven loop

目标流程:

```text
run started
append user message
while iteration < maxIterations:
  emit turn started
  model.stream(messages, tools)
  append assistant message
  if no tool call:
    finish run
  for toolCall in assistant.toolCalls:
    validate tool exists
    validate input schema
    check tool policy
    if approval required:
      pause and emit confirmation requested
      wait for user decision
    execute tool
    append tool-result message
  continue
```

这个 loop 是 Cline 的核心。Starcat 可以保留现有 `AgentWorkspaceViewModel` 和 UI,但底层 `DefaultAgentRuntime` 必须拆分:

- `LinearAgentRuntime` 或旧实现用于短期 fallback / 测试迁移。
- `LoopAgentRuntime` 作为新主路径。
- `AgentRuntime` facade 负责选择实现,避免一次性重写 UI。

### 4.4 第四阶段: 权限和确认闭环

Starcat 的权限建议分四类:

| 权限 | 是否自动执行 | 示例 |
| --- | --- | --- |
| `readOnly` | 是 | resolve repos、repo inspect、本地检索 |
| `externalRead` | 根据设置页网络搜索开关 | external.search |
| `highCost` | 可配置,默认确认 | 大量网页读取、多 repo 深度分析 |
| `requiresConfirmation` | 必须确认 | tag 写入、note 写入、status 变更、unstar |

确认流不能只做 UI 弹出。Runtime 需要有暂停态:

```swift
enum AgentRunStatus {
    case running
    case waitingForConfirmation(AgentPendingApproval)
    case completed
    case failed
    case cancelled
}
```

确认后:

- approved: 继续执行原 tool-call。
- rejected: 写入一个 `tool-result(isError: true)` 给模型,让模型解释替代方案或结束。

### 4.5 第五阶段: 先迁移 GitHub Weekly Report

GitHub Weekly Report 是第一条验证路径,但不能再用固定顺序硬编码。

建议给模型开放这些工具:

1. `context.resolve_repos`
   - 输入: repo 范围、语言、数量、排序目标
   - 输出: repo snapshot 列表
2. `external.search`
   - 输入: query、maxResults、allowedDomains、recency
   - 输出: source 摘要、URL、provider、cache 状态
3. `repo.cluster_topics`
   - 输入: repo IDs、external context、风格
   - 输出: topic 列表
4. `artifact.build_weekly_report`
   - 输入: topics、引用、风格
   - 输出: Markdown 草稿
   - `completesRun = true`

模型可以按需调用,但 system prompt 要约束:

- 必须先解析用户目标。
- 必须使用真实 Starcat 本地 repo snapshot。
- 网络搜索关闭时不得伪造外部来源。
- 最终必须调用 `artifact.build_weekly_report` 或输出最终 Markdown。
- 写操作不允许自动执行。

### 4.6 第六阶段: 持久化和 UI 映射

当前 `AgentRunRepository` 应扩展存储:

- run
- messages
- tool calls
- tool results
- approvals
- artifacts
- usage

UI 映射:

- 中栏按 messages 渲染,而不是按预设 plan 渲染。
- assistant text / reasoning 在左侧。
- user message 在右侧。
- tool-call 显示为可展开步骤。
- tool-result 显示输入、输出、错误、耗时、来源。
- artifact 永远按执行顺序放到底部,不能默认放最上面。
- 右侧 Inspector 只展示当前选中 artifact / run summary / pending approval,不要为每个 Agent 写一套假面板。

## 5. 与 Cline 的差异化边界

Starcat 不应该复制这些能力到第一阶段:

1. `run_commands`
   - 风险过高,且和 Starcat 产品目标不匹配。
2. `editor` / `apply_patch`
   - Starcat 不是代码编辑器,写文件不是核心场景。
3. subagent / teams
   - 可以后置,先把单 Agent loop 做正确。
4. browser automation
   - 先复用已有 External Search,不要引入浏览器自动化。
5. 用户自定义工具插件
   - 后置;先稳定内置领域工具和权限模型。

Starcat 第一阶段必须保留:

1. 复用现有 AI Provider 设置。
2. 复用现有 External Search 设置和 API Key 管理。
3. 所有写入 Starcat 用户数据的操作必须确认。
4. Run 必须可审计、可恢复、可导出。
5. 不生成 demo 默认内容。

## 6. 推荐实施顺序

### 6.1 文档与 checklist 修正

1. 新建 “Cline-style Agent Loop 专项” checklist。
2. 把现有 “Agent 底层框架与网络搜索工具” 表述纠正为“线性工具编排 v1”。
3. 明确 Cline-style loop 未完成,避免验收误判。

### 6.2 核心模型

1. 新增 `AgentMessage` / `AgentMessagePart` / `AgentToolCall` / `AgentToolResultMessage`。
2. 新增 `AgentToolDefinition` 和轻量 `AgentJSONSchema` / `AgentJSONValue`。
3. 扩展 `AgentTool`:
   - `definition`
   - `decodeInput`
   - `execute(callInput:context:)`
4. 保留现有 `AgentToolOutput` / `AgentTraceSpan`,但增加关联字段。

### 6.3 LLM tool call 适配

1. 扩展 `AIChatRequest` 支持 tools。
2. 扩展 `AIChatResponse` 或新增 stream event 支持 tool calls。
3. 实现 OpenAI-compatible tool-call parser。
4. 单测覆盖:
   - text only
   - one tool call
   - multiple tool calls
   - invalid JSON input
   - unknown tool

### 6.4 Loop Runtime

1. 新增 `LoopAgentRuntime`。
2. 支持 maxIterations。
3. 支持 tool policy。
4. 支持 approval pause / resume。
5. 支持 cancel。
6. 支持 persistence。
7. 将 run events 适配到现有 UI。

### 6.5 工具迁移

1. `context.resolve_repos`
2. `external.search`
3. `repo.cluster_topics`
4. `artifact.build_weekly_report`
5. `repo.inspect`
6. `run.submit_artifact`

### 6.6 UI 调整

1. 中栏改为 message timeline。
2. 每个 tool-call 可展开查看:
   - tool name
   - input
   - output
   - error
   - elapsed
   - source/citations
3. pending approval 作为 timeline 节点展示,右侧只辅助展示详情。
4. artifact 按执行顺序位于底部。

### 6.7 审查与验收

1. 文档审查: checklist、技术方案、验收步骤和结果报告一致。
2. 代码审查: 不存在第二套 AI Provider / 第二套 External Search 设置。
3. 单测审查: tool-call loop、approval、network search、persistence 覆盖。
4. UI 审查: 无默认 demo 内容,可展开审计每一步输入输出。
5. 工程进度审查: `docs/功能实现总览.md` checkbox 和实现说明回填。

## 7. 验收标准

第一版 Cline-style Agent loop 完成后,至少满足:

1. 模型可以主动调用 `external.search`,不是 Runtime 固定执行。
2. 模型可以根据 tool-result 决定下一步工具。
3. 中栏能按执行顺序看到 user / assistant / tool-call / tool-result / artifact。
4. 每个 tool-call 都能展开看到输入和输出。
5. 写工具会暂停等待确认,确认后继续执行,拒绝后把拒绝结果回灌给模型。
6. Run 退出后可以从历史恢复完整 messages 和 artifacts。
7. Weekly Report 产物出现在执行顺序底部。
8. 没有 demo 默认内容。
9. 单测覆盖 loop 的正常、失败、取消、确认、网络搜索关闭和网络搜索失败场景。

## 8. 风险和约束

1. OpenAI-compatible provider 的 tool-call 格式不完全一致。
   - 处理: 先实现 Starcat 当前 OpenAIClient 的标准 tool_calls,再按 provider 差异补 adapter。
2. Swift 中 JSON schema / JSON value 类型容易过度设计。
   - 处理: 第一版只支持 object/string/number/boolean/array/enum/required。
3. 审计数据可能重复。
   - 处理: messages 是事实源,trace/tool output 是 UI 投影。
4. approval resume 容易和 AsyncStream 生命周期冲突。
   - 处理: Runtime 内部维护 pending approval continuation 或 command channel,不要依赖 UI 重新发起 run。
5. 网络搜索成本和隐私边界。
   - 处理: 继续复用 External Search 设置页,关闭时返回 skipped tool-result。

## 9. 对当前状态的修正说明

之前文档和汇报里“Agent 底层框架与网络搜索工具”可以保留为已完成,但它的准确边界应是:

> 已完成 Tool Registry + 线性工具编排 + 外部搜索工具接入 + 可审计 trace/artifact。

不能再把它表述为:

> 已完成 Cline-style LLM tool-calling loop。

真正的交付目标应新增为:

> Cline-style Agent Loop: 模型驱动工具调用、tool-result 回灌、approval pause/resume、message contract 持久化和 UI 可审计映射。

