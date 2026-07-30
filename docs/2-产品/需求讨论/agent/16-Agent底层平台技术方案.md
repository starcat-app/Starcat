# Agent 底层平台技术方案

> **文档定位**: Starcat 内置 Agent 底层平台方案。本文设计的是后续所有 Agent 共用的运行时、工具系统、AI 接入、UI/UX、存储、权限与扩展边界；`GitHub Weekly Report Agent` 仅作为首个接入实例验证这套底座。
> **状态**: Cline-style Agent 底层平台已于 2026-07-11 落地;当前正式启用 GitHub Weekly Report 和 Repo Insight 两个只读 Agent。
> **关联文档**:
> - [`00-概览-Agent方向讨论与方案.md`](00-概览-Agent方向讨论与方案.md)
> - [`04-AgentRunKit-Swarm-SwiftAgent-对比分析.md`](04-AgentRunKit-Swarm-SwiftAgent-对比分析.md)
> - [`08-Weekly-Trending解读方案.md`](08-Weekly-Trending解读方案.md)
> - [`17-GitHubWeeklyReportAgent技术实现方案.md`](17-GitHubWeeklyReportAgent技术实现方案.md)
> - [`18-SwiftAgentSDK调研报告.md`](18-SwiftAgentSDK调研报告.md)
> - [`15-Agent框架讨论记录与补充场景.md`](15-Agent框架讨论记录与补充场景.md)
> - [`19-Cline-Agent设计学习心得.md`](19-Cline-Agent设计学习心得.md)
> - [`20-CLI-Agent作为AI-Provider初步方案.md`](20-CLI-Agent作为AI-Provider初步方案.md)

---

## 当前实现基线(2026-07-11)

本节是本文的当前事实源。后续章节保留 2026-06 的原始方案和演进设想;如有冲突,以本节与 [`AgentClineLoop专项/checklist.md`](../../../4-工程进度/AgentClineLoop专项/checklist.md) 为准。

- `LoopAgentRuntime` 是唯一正式运行时,按 `model -> tool-call -> tool-result -> model` 循环执行,支持流式输出、多工具调用、取消、超时、重试和预算上限。
- `AgentPromptBuilder` 统一构建 system prompt、运行模式、上下文、附件和工具规则;`AgentMessage` 是 UI 审计与模型回放的共同事实源。
- `AgentTool` 向模型暴露 name、description、JSON schema、permission、retry policy 和终止语义,Runtime 在宿主侧再次校验 allowlist、参数和权限。
- Approval 持久化为 pending / approved / rejected / expired,应用重启后可以恢复待确认工具调用;当前正式 Agent 只开放只读工具,不会制造演示审批。
- `GRDBAgentRunRepository` 持久化 run、message、approval 和 artifact;不再维护独立 step/log 事实表,时间线与 Inspector 从消息链投影。
- Workspace 使用独立 macOS window,复用项目已有 AI Provider、Keychain、External Search、仓库快照和领域服务,不新增第二套设置。
- 当前正式产物是单个 Markdown artifact。shell、任意文件编辑、浏览器自动化、subagent、自动写标签/笔记/状态和自动取消 star 均不在交付范围。
- 后续 Codex、Claude Code、Gemini CLI 接入属于 **Direct-only 外部 Agent Runtime**，与当前
  `LoopAgentRuntime` 并列，不塞进 `AIClientProtocol` 或 `AgentLoopModelClient`。统一入口仍是
  Agent Workspace，详细的双向协议、动态审批、进程隔离和 RAG Tool 边界以
  [`20-CLI-Agent作为AI-Provider初步方案.md`](20-CLI-Agent作为AI-Provider初步方案.md) 为准。

---

## 一、目标

Starcat Agent 平台要解决的不是单个场景的表单生成,而是一套可持续扩展的内置 Agent 运行体系。

目标:

- 提供独立 macOS window 的 `Agent Workspace`,承载所有内置 Agent
- 支持自然语言输入、Agent 自主规划、工具调用、步骤展示、产出物管理
- 把 Starcat 已有能力包装成可复用工具: GitHub / Trending / Weekly / RepoContext / README / Notes / Tags / Search / Export
- 让每个 Agent 以插件式定义接入,避免每个场景重新写一套 UI 和运行流程
- 保留 Starcat AI 保守策略: 写入、导出、高成本操作必须用户确认
- 第一版在 macOS 15 + Swift 5 语言模式下可落地,不依赖 macOS 26-only 框架

非目标:

- 不做完全开放的 autonomous coding agent
- 不让 Agent 默认执行破坏性写操作
- 不把所有 Agent 做成固定 wizard
- 不把 `RepoAIWindowContentView` 继续扩展成长期 Agent 容器

---

## 二、总体架构

### 2.1 分层

```text
┌─────────────────────────────────────────────────────────────┐
│ Agent Workspace UI                                          │
│ Agent 列表 / 对话输入 / 步骤时间线 / Artifact 预览 / 配置   │
├─────────────────────────────────────────────────────────────┤
│ Agent Runtime                                               │
│ Planner / Tool Loop / Run State / Cancellation / Streaming  │
├─────────────────────────────────────────────────────────────┤
│ Agent Registry + Tool Registry                              │
│ Built-in Agent 定义 / Tool 定义 / 权限 / Schema / 版本       │
├─────────────────────────────────────────────────────────────┤
│ AI Execution Layer                                          │
│ API Loop Model / Direct-only External CLI Agent Runtime      │
├─────────────────────────────────────────────────────────────┤
│ Starcat Domain Services                                     │
│ GitHub / Trending / Weekly / RepoContext / Search / Notes   │
├─────────────────────────────────────────────────────────────┤
│ Persistence                                                 │
│ agent_run / message / approval / artifact                   │
└─────────────────────────────────────────────────────────────┘
```

核心原则:

- UI 只订阅 `AgentRunEvent`,不直接知道每个 Agent 内部步骤
- Runtime 只认识 `AgentDefinition` 和 `AgentTool`,不绑定 Weekly 等具体业务
- Tool 是 Starcat 领域服务的薄包装,不在 tool 里重写业务逻辑
- Artifact 是所有 Agent 的统一产出物模型

### 2.2 当前代码现实

| 现状 | 对方案的影响 |
|---|---|
| `OpenAIClient` 与 `AIClientProtocol` 已支持 tool schema、tool call、流式增量和普通响应 | 直接复用现有模型配置与 OpenAI-compatible Provider |
| `AgentPromptBuilder`、`LoopAgentRuntime`、`AgentRunRepository` 已落地 | Prompt、loop、审批恢复和消息审计已有统一契约 |
| CLI Agent 需要工作目录、双向审批、进程取消、Provider session 和原生工具事件 | 后续新增 `CLIExternalAgentRuntime`，不把 CLI 降格成 `OpenAIClient` 的一种配置 |
| `RepoAIWindowContentView` 是 repo 级 AI 窗口 | 不作为 Agent Workspace 长期底座 |
| Weekly / Trending / Manage 已有多选上下文 | 适合注入 Agent run context |
| `BatchAIQueueService` 已有队列、暂停、取消、Pro gate 经验 | 可借鉴,但 Agent run 需要更通用的 step/event 模型 |
| `EntitlementGate` / quota 已存在 | Agent 可复用付费墙,但需要重新定义 run 级消耗 |
| macOS 15 + Swift 5 语言模式 | Swarm / Foundation Models 只能作为远期门控增强 |

---

## 三、核心概念

### 3.1 AgentDefinition

Agent 是一个可运行能力定义,不是一个 View。

```swift
struct AgentDefinition: Identifiable, Codable, Sendable {
    let id: String
    let titleKey: String
    let descriptionKey: String
    let category: AgentCategory
    let iconSystemName: String
    let defaultPromptKey: String
    let capabilities: Set<AgentCapability>
    let toolIDs: [String]
    let artifactTypes: [AgentArtifactType]
    let confirmationPolicy: AgentConfirmationPolicy
    let quotaPolicy: AgentQuotaPolicy
}
```

示例:

```swift
AgentDefinition(
    id: "github-weekly-report",
    titleKey: "agent.weekly.title",
    descriptionKey: "agent.weekly.description",
    category: .content,
    iconSystemName: "newspaper",
    defaultPromptKey: "agent.weekly.defaultPrompt",
    capabilities: [.readGitHub, .readTrending, .generateText, .generateImagePrompt, .schedule],
    toolIDs: [
        "trending.fetchRepos",
        "weekly.fetchFeed",
        "repo.getOverview",
        "report.clusterTopics",
        "report.generate",
        "artifact.export"
    ],
    artifactTypes: [.markdown, .xhsCards, .html, .videoScript, .image],
    confirmationPolicy: .defaultSafe,
    quotaPolicy: .estimated(base: 4)
)
```

### 3.2 AgentRun

一次用户请求或一次定时任务触发形成一个 run。

```swift
struct AgentRun: Identifiable, Codable, Sendable {
    let id: UUID
    let agentID: String
    var title: String
    var userPrompt: String
    var context: AgentRunContext
    var status: AgentRunStatus
    var steps: [AgentRunStep]
    var artifacts: [AgentArtifact]
    var createdAt: Date
    var updatedAt: Date
}
```

### 3.3 AgentRunContext

上下文是 Agent 与当前 App 状态之间的桥。

```swift
struct AgentRunContext: Codable, Sendable {
    var source: AgentContextSource
    var selectedRepos: [RepoSelectionSnapshot]
    var currentRepo: RepoSelectionSnapshot?
    var filters: [String: String]
    var userPreferences: [String: String]
    var localeIdentifier: String
}
```

上下文只存快照,不存 live binding。这样 run 可复盘、可复跑,也避免列表筛选变化后污染历史任务。

### 3.4 AgentTool

Tool 是 Agent 访问 Starcat 能力的唯一边界。

```swift
protocol AgentTool: Sendable {
    var id: String { get }
    var displayNameKey: String { get }
    var description: String { get }
    var inputSchema: AgentJSONSchema { get }
    var permission: AgentToolPermission { get }

    func execute(
        input: AgentToolInput,
        context: AgentToolContext
    ) async throws -> AgentToolResult
}
```

约束:

- Tool 输入输出必须可 Codable
- Tool result 必须有摘要字段,避免完整结果无限塞回 LLM context
- Tool 不直接更新 UI,只返回 event / result
- 写类 tool 默认 `requiresConfirmation`

### 3.5 Artifact

Artifact 是 Agent 最终交付给用户的产出物。

```swift
struct AgentArtifact: Identifiable, Codable, Sendable {
    let id: UUID
    let runID: UUID
    let type: AgentArtifactType
    var title: String
    var content: AgentArtifactContent
    var filePath: String?
    var version: Int
    var createdAt: Date
    var updatedAt: Date
}
```

Artifact 类型:

- `.markdown`
- `.json`
- `.xhsCards`
- `.html`
- `.videoScript`
- `.imagePrompt`
- `.image`
- `.table`
- `.checklist`
- `.log`

---

## 四、Agent Runtime

### 4.1 Runtime 职责

`AgentRuntime` 负责:

- 根据 AgentDefinition 构造 system prompt 和工具清单
- 把用户 prompt + context 转成执行计划
- 驱动 LLM / tool calling loop
- 发送 `AgentRunEvent` 给 UI
- 持久化 step / artifact / error
- 处理中断、重试、确认点
- 统一扣配额和记录成本

### 4.2 协议

```swift
protocol AgentRuntime: Sendable {
    func run(
        definition: AgentDefinition,
        prompt: String,
        context: AgentRunContext
    ) -> AsyncThrowingStream<AgentRunEvent, Error>

    func cancel(runID: UUID) async
    func resume(runID: UUID) -> AsyncThrowingStream<AgentRunEvent, Error>
}
```

### 4.3 事件流

UI 不直接读 runtime 内部状态,只消费事件。

```swift
enum AgentRunEvent: Sendable {
    case runStarted(AgentRunSnapshot)
    case planCreated([AgentPlanStep])
    case stepStarted(AgentRunStepSnapshot)
    case toolStarted(AgentToolCallSnapshot)
    case toolOutput(AgentToolOutputSnapshot)
    case confirmationRequested(AgentConfirmationRequest)
    case assistantDelta(String)
    case artifactCreated(AgentArtifactSnapshot)
    case artifactUpdated(AgentArtifactSnapshot)
    case stepFinished(AgentRunStepSnapshot)
    case runFinished(AgentRunSnapshot)
    case runFailed(AgentRunErrorSnapshot)
}
```

### 4.4 执行循环

```swift
func runAgent(...) async throws {
    let run = try await store.createRun(...)
    yield(.runStarted(run.snapshot))

    let toolDefs = toolRegistry.tools(for: definition.toolIDs)
    var transcript = AgentTranscript.system(definition.systemPrompt)
    transcript.appendUser(prompt, context: context)

    for index in 0..<definition.maxSteps {
        try Task.checkCancellation()

        let response = try await llm.complete(
            transcript: transcript,
            tools: toolDefs.map(\.llmToolDefinition),
            responseMode: .toolCallingOrFinal
        )

        if let final = response.finalAnswer {
            let artifact = try await artifactBuilder.build(from: final)
            yield(.artifactCreated(artifact.snapshot))
            break
        }

        for toolCall in response.toolCalls {
            let tool = try toolRegistry.resolve(toolCall.name)
            if tool.permission.requiresConfirmation {
                yield(.confirmationRequested(...))
                try await confirmationCenter.waitForApproval(...)
            }
            let result = try await tool.execute(input: toolCall.input, context: toolContext)
            transcript.appendToolResult(result.compactedForLLM)
            yield(.toolOutput(result.snapshot))
        }
    }
}
```

第一版可以用自研 loop。`AgentRuntime` 协议必须先抽好,未来 macOS 26 门控接 Swarm 时只替换 runtime 实现,不动 Tool / UI / Artifact。

---

## 五、AI 接入层

### 5.1 文本模型

现有 `AIClientProtocol` 保留给普通摘要、聊天、embedding。Agent 需要新增 tool-capable 层:

```swift
protocol AgentLLMClient: Sendable {
    func complete(
        transcript: AgentTranscript,
        tools: [AgentLLMToolDefinition],
        responseMode: AgentLLMResponseMode
    ) async throws -> AgentLLMResponse

    func stream(
        transcript: AgentTranscript,
        tools: [AgentLLMToolDefinition],
        responseMode: AgentLLMResponseMode
    ) -> AsyncThrowingStream<AgentLLMStreamEvent, Error>
}
```

实现路线:

1. **P0**: 扩展 OpenAI-compatible Chat Completions,支持 `tools` / `tool_choice` / `tool_calls`
2. **P1**: 支持 Responses API 风格事件
3. **P2**: macOS 26 门控接 Foundation Models / Swarm provider

不要把 tool calling 硬塞进 `AIChatRequest.userPrompt` 的文本协议里。那样短期能跑,但无法可靠处理 schema、tool_call_id、并发 tool result 和恢复。

### 5.2 Structured Output

Agent 关键节点必须优先走结构化输出:

- plan schema
- artifact schema
- confirmation request schema
- run summary schema

如果模型不支持 JSON schema,降级到 `responseFormat: .jsonObject` + 本地校验 + 失败重试一次。

### 5.3 图片生成

图片生成单独抽象,不要混在文本 `AIClient`。

```swift
protocol AgentImageClient: Sendable {
    func generate(
        prompt: String,
        options: AgentImageGenerationOptions
    ) async throws -> AgentGeneratedImage
}
```

策略:

- P0 可只生成 image prompt,不接真实图片 API
- 接入真实图片 API 前,必须有独立 provider 设置、费用预估和用户确认点
- 图片文件存磁盘,SQLite 只存 artifact metadata 和 file path

### 5.4 Provider 与 BYOK

文本模型优先复用现有 AI Provider 配置。图片 provider 独立配置,因为:

- 图片模型和文本模型通常不是同一个 endpoint
- 配额单位不同
- 费用和确认策略不同

### 5.5 外部 CLI Agent Runtime

Codex、Claude Code、Gemini CLI 等工具提供的是完整 Agent 执行环境，不只是 Text LLM。
后续接入时，运行时关系固定为：

```text
AgentRuntime
├── LoopAgentRuntime
│   └── AgentLoopModelClient
│       └── OpenAIClient / OpenAI-compatible API
└── CLIExternalAgentRuntime                    # Direct-only
    └── CLIProviderAdapter + CLIProcessHost
        └── Codex / Claude Code / Gemini CLI
```

两条 Runtime 复用：

- `AgentRunEvent` 与 Workspace timeline / Inspector；
- run、message、approval、artifact 的持久化与审计；
- Starcat 领域 Tool 的权限和用户确认原则；
- 取消、超时、敏感信息脱敏和最终产物展示。

但不能错误复用：

- CLI 原生文件、Shell、联网和浏览器请求必须经 Provider 双向协议暂停，并由新的
  `CLIApprovalBroker` 映射到 Starcat 审批 UI；现有内置 Tool approval 不能假装已经
  把决定回写外部进程。
- CLI 的工作目录、session、capability probe、进程组终止和 Provider sandbox / policy
  属于 `CLIProcessHost` / Adapter 职责，不进入 `AgentLoopModelClient`。
- CLI 不提供 Embedding；RAG 索引和检索继续使用现有 API Provider。完整 CLI Agent
  只能通过 run-scoped `starcat.knowledge.*` Tool 使用 RAG，不能直接读取 SQLite 或
  替换受控 Evidence Pipeline。
- 该能力只进入 Direct 构建；App Store 构建不展示、不配置、也不能启动外部 CLI。

具体协议、权限档位、动态审批状态机、Run Capsule、分阶段实施与验收标准统一引用
[`20-CLI-Agent作为AI-Provider初步方案.md`](20-CLI-Agent作为AI-Provider初步方案.md)，
本文不再维护第二份 CLI 细节。

---

## 六、Tool 系统

### 6.1 Tool 分类

| 分类 | 示例 | 默认权限 |
|---|---|---|
| Read Tool | fetch trending、读取 README、搜索 stars | 自动执行 |
| Analyze Tool | 聚类、评分、生成 report draft | 自动执行 |
| Generate Tool | 文本 artifact、image prompt | 自动执行 |
| Costly Tool | 图片生成、大批量 LLM fan-out | 需要确认 |
| Write Tool | 写 note、打 tag、导出文件、开启定时 | 需要确认 |
| External Tool | 调外部 MCP / CLI / Web API | 按 tool 配置 |

### 6.2 Tool 权限

```swift
enum AgentToolPermission: Codable, Sendable {
    case readOnly
    case costly(estimatedCostKey: String)
    case write(scope: AgentWriteScope)
    case external(serviceID: String)
}
```

### 6.3 Tool Registry

```swift
@MainActor
@Observable
final class AgentToolRegistry {
    private var tools: [String: AgentTool] = [:]

    func register(_ tool: AgentTool)
    func resolve(_ id: String) throws -> AgentTool
    func tools(for ids: [String]) -> [AgentTool]
}
```

注册来源:

- App 启动时注册内置 tools
- 每个 Feature module 暴露自己的 `AgentToolProvider`
- 远期可从 MCP server 动态注册外部 tools

### 6.4 首批内置 Tools

| Tool ID | 复用能力 | 用途 |
|---|---|---|
| `trending.fetchRepos` | trending-api | 拉本周热门 repo |
| `weekly.fetchFeed` | WeeklyAPI | 拉 Weekly feed |
| `repo.resolveSelection` | MultiSelectionStore 快照 | 解析用户选中 repo |
| `repo.getOverview` | Repo / GitHub / README cache | 生成 repo 事实卡 |
| `repo.getReadmeContext` | RepoContextPacker | 提供 README / 代码上下文摘要 |
| `search.localStars` | 本地 FTS / semantic | 搜用户 stars |
| `report.clusterTopics` | LLM structured output | 聚类主题 |
| `artifact.buildMarkdown` | ArtifactBuilder | 生成 Markdown |
| `artifact.buildXHSCards` | ArtifactBuilder | 生成小红书卡片 |
| `artifact.buildHTML` | ArtifactBuilder | 生成 HTML |
| `artifact.export` | File exporter | 导出文件 |
| `image.buildPrompts` | LLM structured output | 生成图片 prompt |
| `image.generate` | Image provider | 生成图片 |

---

## 七、UI/UX 设计

### 7.1 工作台形态

`Agent Workspace` 是主窗口内的覆盖式 mode,不是 sheet,不是新窗口首选。

原因:

- Agent 是 Starcat 的一级工作模式
- 需要承载长任务、历史、多个 artifact 和继续对话
- 从详情页 / 列表页进入时仍需保留“返回主界面”的明确路径

### 7.2 页面结构

```text
┌────────────────────────────────────────────────────────────┐
│ Agent Workspace                                  返回主界面 │
├─────────────────┬──────────────────────────────────────────┤
│ Agent Rail      │ Run Surface                              │
│                 │                                          │
│ Built-in        │ Header: Agent / Run / Status / Cost       │
│ - Weekly Report │                                          │
│ - Repo Insight  │ Timeline: plan + tool calls + approvals   │
│ - Release Watch │                                          │
│                 │ Artifacts: tabs + preview + actions       │
│ Schedules       │                                          │
│ History         │ Composer: user prompt + attachments       │
└─────────────────┴──────────────────────────────────────────┘
```

### 7.3 Agent Rail

左侧 rail 分三组:

- `Built-in Agents`: 官方内置 Agent
- `Schedules`: 已启用定时任务
- `History`: 最近 run

Agent item 展示:

- SF Symbol 图标
- 名称
- 一句话描述
- 状态 badge
- 最近运行时间

禁止用 emoji 作为图标。使用 SF Symbols,并遵守现有颜色规范: 图标 / 文字默认 `.primary` / `.secondary`,不使用 `.tertiary`。

### 7.4 Run Surface

右侧主体分四块:

1. **Run Header**
   - 当前 Agent
   - Run 标题
   - 来源上下文
   - 状态
   - 预计 / 实际 quota
   - 停止按钮

2. **Timeline**
   - step card 列表
   - 每个 step 可展开
   - tool call 显示工具名、输入摘要、输出摘要、耗时
   - `需要确认` 状态使用明确的确认按钮

3. **Artifacts**
   - tabs: Markdown / Cards / HTML / Video Script / Images / Logs
   - 每个 artifact 有复制、导出、重生成、保存入口
   - 局部重生成通过选中 artifact 节点 + 底部输入实现

4. **Composer**
   - 多行输入
   - 支持上下文 chip: `8 repos selected`、`Weekly #42`、`Current repo`
   - 支持附件式 artifact 引用
   - 支持 stop / send

### 7.5 交互状态

| 状态 | UI |
|---|---|
| Idle | 显示 Agent 能力、示例 prompt、最近 run |
| Planning | Timeline 出现计划 skeleton |
| Running | 当前 step 高亮,显示 spinner 和流式摘要 |
| Waiting Confirmation | 当前 step 停住,显示确认卡 |
| Completed | Artifacts 自动聚焦最新产出 |
| Failed | 保留已完成 steps,错误 step 可重试 |
| Cancelled | 保留 run 草稿,可继续或丢弃 |

### 7.6 可访问性与动效

- 所有 icon button 必须有 tooltip / accessibility label
- `.buttonStyle(.plain)` 必须加 `.focusEffectDisabled()`
- 动效遵守 `reduceMotion`
- hover 不改变布局尺寸
- 大段输出采用虚拟化或分块渲染,避免 AI 流式时卡顿

---

## 八、存储设计

### 8.1 表

```sql
CREATE TABLE agent_definition (
    id TEXT PRIMARY KEY,
    title_key TEXT NOT NULL,
    description_key TEXT NOT NULL,
    category TEXT NOT NULL,
    icon_system_name TEXT NOT NULL,
    capabilities_json TEXT NOT NULL,
    tool_ids_json TEXT NOT NULL,
    artifact_types_json TEXT NOT NULL,
    is_builtin INTEGER NOT NULL DEFAULT 1,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);
```

```sql
CREATE TABLE agent_run (
    id TEXT PRIMARY KEY,
    agent_id TEXT NOT NULL,
    title TEXT NOT NULL,
    user_prompt TEXT NOT NULL,
    context_json TEXT NOT NULL,
    status TEXT NOT NULL,
    quota_estimate INTEGER NOT NULL DEFAULT 0,
    quota_actual INTEGER NOT NULL DEFAULT 0,
    image_cost_estimate INTEGER NOT NULL DEFAULT 0,
    image_cost_actual INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    finished_at INTEGER
);
CREATE INDEX idx_agent_run_agent ON agent_run(agent_id, created_at DESC);
```

```sql
CREATE TABLE agent_run_step (
    id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL,
    step_index INTEGER NOT NULL,
    title TEXT NOT NULL,
    status TEXT NOT NULL,
    tool_id TEXT,
    input_summary TEXT,
    output_summary TEXT,
    error_message TEXT,
    started_at INTEGER,
    finished_at INTEGER
);
CREATE INDEX idx_agent_run_step_run ON agent_run_step(run_id, step_index);
```

```sql
CREATE TABLE agent_artifact (
    id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL,
    type TEXT NOT NULL,
    title TEXT NOT NULL,
    content_json TEXT,
    file_path TEXT,
    version INTEGER NOT NULL DEFAULT 1,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);
CREATE INDEX idx_agent_artifact_run ON agent_artifact(run_id, created_at);
```

```sql
CREATE TABLE agent_schedule (
    id TEXT PRIMARY KEY,
    agent_id TEXT NOT NULL,
    title TEXT NOT NULL,
    prompt_template TEXT NOT NULL,
    schedule_rule TEXT NOT NULL,
    context_preset_json TEXT NOT NULL,
    confirmation_policy_json TEXT NOT NULL,
    is_enabled INTEGER NOT NULL DEFAULT 1,
    last_run_at INTEGER,
    next_run_at INTEGER,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);
```

### 8.2 文件

建议目录:

```text
Application Support/Starcat/AgentRuns/
  {runID}/
    artifacts/
      weekly.md
      xhs-cards.json
      page.html
      images/
        cover.png
    logs/
      tool-calls.jsonl
```

原则:

- SQLite 存结构化 metadata 和可编辑 JSON
- 大文件、图片、HTML assets 存磁盘
- run 删除时删除对应文件目录
- 未上线项目不写旧 schema 兼容逻辑

---

## 九、配额、权限与确认

### 9.1 配额模型

Agent run 不能简单等于一次 AI 调用。

建议:

```text
run quota = base + text_model_calls + costly_tool_calls
image quota = image generation count
```

运行前显示预估:

```text
预计消耗:
- 文本: 4 quota
- 图片: 0 image credits
- 外部 API: 免费
```

运行中记录实际消耗。失败时:

- 已完成 LLM 调用不回滚
- 未执行的 costly tool 不扣
- 图片生成失败按 provider 是否计费决定

### 9.2 权限确认

确认点分三类:

| 类型 | 示例 |
|---|---|
| 高成本 | 图片生成、批量 repo 深读、大量外部搜索 |
| 写入 | 写 Note、打 tag、导出文件、创建 schedule |
| 外部 | 调第三方 API、打开网页、使用外部 MCP |

确认卡需要展示:

- Agent 想做什么
- 为什么需要
- 会消耗什么
- 可选操作: `确认` / `跳过` / `取消任务`

### 9.3 Pro Gate

Agent 平台层统一接 `EntitlementGate`。

建议策略:

- Agent Workspace 可对所有用户可见
- 高价值 Agent run 受 Pro / quota 限制
- Free 可给少量试用 run
- 图片生成默认 Pro + image credits

---

## 十、扩展接入规范

后续新增 Agent 必须只做三件事:

1. 定义 `AgentDefinition`
2. 注册所需 `AgentTool`
3. 定义 Artifact schema / renderer

不允许:

- 为单个 Agent 新建独立工作台
- 直接绕过 ToolRegistry 调领域服务
- 在 Agent 内部直接写数据库
- 把高成本调用藏在普通 text generation 里

### 10.1 新 Agent 模板

```swift
enum BuiltInAgents {
    static let githubWeekly = AgentDefinition(...)
    static let repoInsight = AgentDefinition(...)
}

struct GitHubWeeklyAgentToolProvider: AgentToolProvider {
    func makeTools(dependencies: AppDependencies) -> [AgentTool] {
        [
            FetchTrendingReposTool(api: dependencies.trendingAPI),
            FetchWeeklyFeedTool(api: dependencies.weeklyAPI),
            GetRepoOverviewTool(...),
            BuildMarkdownArtifactTool(...)
        ]
    }
}
```

### 10.2 Artifact Renderer

```swift
protocol AgentArtifactRenderer {
    var type: AgentArtifactType { get }
    associatedtype Content: Codable

    func renderPreview(_ content: Content) -> AnyView
    func export(_ content: Content, to directory: URL) async throws -> [URL]
}
```

Renderer 是 UI 与 artifact 内容解耦的关键。Weekly 的小红书卡、技术选型的对比表、本地文档整理的目录树都可以走同一套 tabs / preview / export 容器。

---

## 十一、GitHub Weekly Report Agent 验证路径

Weekly Agent 是底层平台的首个用例,不做特权实现。

### 11.1 接入项

| 底层能力 | Weekly 验证方式 |
|---|---|
| Context 注入 | 从 Trending / Weekly / Manage 选中 repo 进入 |
| Tool loop | 拉 trending、读 repo overview、聚类主题 |
| Artifact | 生成 Markdown、小红书卡片、视频文案 |
| Confirmation | 图片生成、导出文件前确认 |
| History | 查看上周 run 并继续修改 |
| Schedule | 每周一生成草稿 |

### 11.2 P0 验证闭环

最小闭环:

1. 打开 Agent Workspace
2. 选择 `GitHub Weekly Report`
3. 输入「生成本周热门 AI Agent 项目周刊」
4. Runtime 拉取 trending-api
5. Runtime 调 LLM 生成计划和 Markdown artifact
6. UI 展示步骤时间线和 Markdown
7. 用户继续输入「改得更像阮一峰 Weekly」
8. Agent 局部重写 artifact
9. 用户复制 / 导出 Markdown

P0 不要求:

- 真实图片生成
- 定时后台自动运行
- HTML 动画
- 多 Agent 并行协作

---

## 十二、实施阶段

### Phase 0: 技术 spike

- 验证 OpenAI-compatible `tools` / `tool_calls` 在现有 provider 下可用
- 给 `AgentLLMClient` 做 mock 和 OpenAI 实现草案
- 跑通一个假的 `echo` tool loop

### Phase 1: Agent Workspace 骨架

- 主窗口 mode 切换
- 左侧 Agent rail
- 右侧 Run surface
- Composer
- Step timeline
- Artifact tabs
- Run store 基础表

### Phase 2: Runtime + Tool Registry

- `AgentRuntime`
- `AgentToolRegistry`
- `AgentRunEvent`
- cancellation / retry / confirmation
- text artifact builder

### Phase 3: Weekly Agent P0

- `GitHub Weekly Report` definition
- trending / weekly / selection tools
- Markdown artifact
- history / export

### Phase 4: 多 Artifact 与图片

- 小红书卡片 artifact
- HTML artifact
- 视频文案 artifact
- image prompt
- image provider

### Phase 5: Schedule

- `agent_schedule`
- 后台触发
- 通知
- 失败恢复

### Phase 6: 第二个 Agent 接入

选择一个与 Weekly 差异明显的 Agent 验证平台泛化能力,例如:

- Repo Insight: 单 repo 深度解读
- Local Docs Organizer: 本地文档整理
- Release Watcher: 版本影响分析

---

## 十三、测试策略

### 13.1 单测

- `AgentToolRegistryTests`
- `AgentRuntimeLoopTests`
- `AgentConfirmationPolicyTests`
- `AgentRunStoreTests`
- `AgentArtifactRendererTests`
- `AgentQuotaPolicyTests`

### 13.2 集成测试

- mock LLM 返回 tool call → runtime 执行 tool → 生成 artifact
- tool 失败 → step failed → 支持 retry
- confirmation required → runtime 暂停 → approve 后继续
- cancel run → 不再执行后续 tool

### 13.3 UI 验证

- Agent workspace idle / running / failed / completed
- 长 artifact 滚动性能
- 深色 / 浅色
- reduce motion
- keyboard focus

### 13.4 运行命令

新增 Swift 文件后:

```bash
xcodegen generate
xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' test
```

跑测前按项目约定关闭 Xcode IDE,避免 `testmanagerd` 抢占。

---

## 十四、开放决策

1. P0 是否允许 Free 用户试用 1-2 次 Agent run?
2. 图片生成是否首版只做 prompt,真实图片 API 放 Phase 4?
3. Agent Workspace 是完全覆盖主窗口内容区,还是保留当前主窗口 toolbar?
4. Tool calling 第一版是否只支持 OpenAI Chat Completions,Responses API 放 P1?
5. 第二个验证 Agent 选 `Repo Insight` 还是 `Local Docs Organizer`?

---

## 十五、结论

推荐路线:

> 先自研 `AgentRuntime` + `AgentToolRegistry` + `Agent Workspace`,用 `GitHub Weekly Report Agent` 验证底座。底层协议预留 Swarm / Foundation Models / 外部 MCP 的替换点,但 P0 不依赖 macOS 26-only 方案。

这样做的收益:

- Starcat 现有服务可以快速变成 Agent tools
- 每个后续 Agent 只需要定义工具、prompt、artifact,不用重写 UI
- 用户看到的是现代 Agent 工作台,不是一堆固定表单
- Weekly Report 既能验证定时 / 多产物 / 图片 prompt / 导出,又不会把底层绑死在内容创作场景

---

## 十六、变更记录

| 日期 | 变更 | 作者 |
|---|---|---|
| 2026-06-28 | 初稿:Agent 底层平台技术方案 | Codex |
