# Agent Runtime 执行过程产品化专项

> 状态：代码与自动化验证已完成，等待三种 Runtime 的真实任务人工验收。本文记录 Agent 工作台从 POC 转向可交付产品时，三种 Runtime 的事件接入、展示、安全与验收约束。它不替代 `docs/功能实现总览.md`，也不在未验收前改写主进度。

## 1. 目标

Starcat Agent 工作台必须展示 Runtime 实际产生的执行过程，不使用固定的“分析、检索、生成”阶段模拟 Agent 行为。

统一层只负责四件事：

1. 把不同 Runtime 的原生事件归一化为 `AgentTraceEvent`。
2. 用稳定事件 ID 合并 started、delta、completed 生命周期。
3. 对 JSON、Markdown、代码、错误和表格采用统一的结构化 renderer。
4. 对超长内容和敏感字段做展示预算与脱敏，不把协议帧直接暴露给普通用户。

## 2. 产品边界

- 展示 Provider 明确返回的 reasoning summary、reasoning block、plan 与 commentary。
- 不伪造思考过程，不从工具参数或最终答案反推“模型在想什么”。
- 不展示隐藏 system prompt、环境变量、凭据、Cookie、Authorization 或原始 JSON-RPC 信封。
- 普通 UI 展示可读的业务事件；未知扩展事件保留有界、脱敏后的 `data`，便于新版本向前兼容。
- Runtime 没有返回 reasoning 时，明确显示“未提供可展示的思考摘要”，不能生成占位内容冒充模型输出。

## 3. 公共事件模型

公共模型位于：

- `Starcat/Features/Agents/Core/AgentTraceEvent.swift`
- `Starcat/Features/Agents/Core/AgentTraceDetailPresentation.swift`
- `Starcat/Features/Agents/Core/AgentMessageTimelineView.swift`

关键约束：

- `providerEventID` / `id` 是生命周期合并键。
- `parentID` 只表达 Runtime 已知的层级，例如 DeepSeek `turn → step → request/tool/reasoning`。
- `sequence` 只决定首次出现位置；delta 更新不能让列表跳动。
- `details` 才触发 disclosure。结构事件若有原始字段，也应提供脱敏后的结构化详情。
- Markdown、代码、raw payload、集合数量和递归深度均有 UI 预算；持久化层既有的有界 Trace 不因 UI 预算被再次改写。

## 4. Runtime 事件覆盖

### 4.1 DeepSeek Harness

权威来源：

- [Session subsystem](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/subsystems/session.md)
- [Framework events](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/user/develop/framework/events.md)
- [LLM streaming](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/llm/llm/README.md)

| 原生事件 | Starcat 投影 | 合并策略 |
|---|---|---|
| `turn/start`, `turn/end` | lifecycle / waiting / warning / error | `turn:{n}`；按官方 end reason 收口 |
| `step/start`, `step/end` | lifecycle | `turn:{n}:step:{n}` |
| `assistant/chunk` | text/reasoning delta、usage | chunk 不创建独立空行 |
| `assistant/message` | final text + reasoning block | message ID；最终组装事件为权威 |
| `user/message`, `steering/message` | message | message/event ID |
| `tool/call`, `tool/result` | tool lifecycle | `callId` |
| `request/header`, `request/context` | request | 同一步 request 合并两个详情 |
| `todo/write` | todo | 单行持续更新 |
| `compaction/start/summary/end` | compaction | `compactionId`，终态保留 summary |
| `hook/*`, `agent/inbox/spliced`, `session/end-seed` | lifecycle | 原生 ID 或 seq |
| 插件扩展事件 | unknown | 原生 ID 或 seq，保留脱敏 data |

DeepSeek `ReasoningBlock` 是 Runtime 明确返回的 `{ type: "reasoning", text }` 内容。只有该内容或 Runtime 明确提供的同类可见摘要进入可恢复 Trace；不存在时不补写。

`turn/end` 的 `completed`、`aborted`、`blocked`、`error`、`max-tokens`、`interrupted` 按官方语义分别映射为完成、取消、等待、失败、上限警告和中断失败。`blocked` 本身不是终态，不能被误报成成功或失败。

### 4.2 Codex App Server

Starcat 以本机 `codex app-server generate-json-schema --experimental` 生成的当前安装版本 schema 为协议事实来源。公开产品说明以 [Codex documentation](https://developers.openai.com/codex/) 为入口。

| 原生事件 | Starcat 投影 |
|---|---|
| `item/started`, `item/completed` | command、fileChange、MCP、webSearch、reasoning 等生命周期 |
| `item/agentMessage/delta` | commentary 或 final answer delta |
| `item/reasoning/summary*` | reasoning summary |
| `item/commandExecution/outputDelta` | 同一 command 行增量输出 |
| `item/fileChange/outputDelta`, `patchUpdated` | 同一 fileChange 行增量详情 |
| `item/mcpToolCall/progress` | 同一 MCP 行进度 |
| `item/plan/delta`, `turn/plan/updated` | plan |
| `hook/started`, `hook/completed` | lifecycle |
| `thread/compacted` | compaction |
| `turn/diff/updated` | fileChange |
| `thread/tokenUsage/updated` | usage |
| `warning`, `configWarning`, `error` | warning、retry、error |
| `hookPrompt`, `collabAgentToolCall`, `subAgentActivity` | message、tool、lifecycle |
| `imageView`, `imageGeneration`, `sleep` | tool、tool、lifecycle |
| `enteredReviewMode`, `exitedReviewMode`, `contextCompaction` | lifecycle、lifecycle、compaction |

Codex raw reasoning delta 只用于瞬时运行状态；历史 Trace 只保存 App Server 明确标记的 summary 或模型主动发送的 commentary。

### 4.3 Built-in Loop

内置 Loop 直接消费 Starcat 自己的 `AgentMessagePart`：

- `.reasoning` → reasoning summary。
- `.toolCall` → running tool trace，展示结构化输入。
- `.toolResult` → 同一 tool trace 的终态、输出、耗时与每次尝试。
- retry 详情合并进 tool trace；approval 继续使用可交互审批卡片，并在 Trace 区启用时一并展示；run error 生成失败 Trace。

内置标题与尝试次数必须走 `Localizable.xcstrings`，不能把 `Tool call`、`Attempt` 固定为英文。

## 5. 展开与滚动性能

2026-08-23 的 hang sample 显示主线程持续停留在 SwiftUI `sizeThatFits`、`LayoutEngineBox`、`ScrollViewLayoutComputer`。触发条件是展开包含大段 Markdown、JSON 或表格的步骤后，对动态高度执行动画并反复测量。

固定措施：

- Trace 详情展开不做高度动画。
- Runtime Trace 总区展开不做高度动画，避免一次测量整条长时间线。
- 普通文本不使用无界 `.fixedSize`。
- Markdown、代码、raw payload、对象字段、集合项与递归深度设置展示预算。
- 超出预算时显示本地化截断说明；需要完整原始载荷时转到 Runtime 自身日志。
- 同一事件的 delta 必须 upsert，禁止每个 chunk 新建一行。

自动化验收：

- 超长 Markdown 和 raw payload 会裁剪。
- 大型集合只生成有界结构化节点。
- started/delta/completed 使用同一事件 ID。
- 后续生命周期事件不会清空前一阶段详情。

人工验收：

1. 分别运行 Built-in、Codex、DeepSeek 任务。
2. 执行包含多次 tool call、reasoning、错误重试和大结果集的任务。
3. 连续展开、折叠并滚动 20 次，窗口仍可响应，CPU 不持续占满。
4. 切换历史 Run 后，已完成 Trace 可恢复，标题随当前语言显示。
5. 检查未知事件详情不包含 token、key、authorization、cookie、system 或环境变量。

## 6. 当前验证矩阵

| 项目 | 自动化状态 | 仍需人工验收 |
|---|---|---|
| Trace 大内容预算 | 已有专项测试 | 真实长周报展开滚动 |
| DeepSeek 官方核心事件 | fixture 已覆盖 | 0.1.1rc1 真实长任务 |
| DeepSeek MCP 工具链 | 已有真实 smoke 入口 | 使用本机配置重跑并观察 UI |
| Codex schema 事件 | fixture 已覆盖主要执行事件 | 当前 Codex 版本真实任务 |
| Built-in Loop | 既有 Runtime 测试 | 多次 retry / approval 交互 |
| 明暗主题与 i18n | Catalog key 已补齐 | 中文、英文界面目测 |

## 7. 后续审计原则

- Runtime 升级时先生成或读取该版本官方事件定义，再更新映射与 fixture。
- 新事件默认进入有界脱敏 fallback，确认语义后再升级为专用 kind。
- 任何“空 disclosure”“同一调用出现多行”“completed 覆盖 running 详情”均视为映射缺陷。
- 性能优化不能静默改写既有持久化记录；普通时间线只限制参与布局的预览规模。
