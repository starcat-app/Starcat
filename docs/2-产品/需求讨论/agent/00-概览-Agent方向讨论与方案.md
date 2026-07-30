# Starcat Agent 方向讨论与方案(总览)

> **文档定位**: 总览索引,记录 2026-06-27 与 dong4j 讨论的 Starcat Agent 化方向、生态调研、候选场景与决策点。
> **状态**: 讨论稿,等 dong4j 拍板落地项。
> **关联文档**:
> - [`01-Foundation-Models-可行性分析.md`](01-Foundation-Models-可行性分析.md)
> - [`02-替代品推荐-Agent方案.md`](02-替代品推荐-Agent方案.md)
> - [`03-Starred-Repo-周报-Agent方案.md`](03-Starred-Repo-周报-Agent方案.md)
> - [`04-AgentRunKit-Swarm-SwiftAgent-对比分析.md`](04-AgentRunKit-Swarm-SwiftAgent-对比分析.md)
> - [`10-Agent产品叙事-三条主线.md`](10-Agent产品叙事-三条主线.md)：整理 · 发现 · 消化 产品叙事与 IA
> - [`11-重叠扫描-Agent方案.md`](11-重叠扫描-Agent方案.md)
> - [`12-回忆搜索-Agent方案.md`](12-回忆搜索-Agent方案.md)
> - [`13-Untagged批量整理-Agent方案.md`](13-Untagged批量整理-Agent方案.md)
> - [`14-Unread激活-Agent方案.md`](14-Unread激活-Agent方案.md)
> - [`16-Agent底层平台技术方案.md`](16-Agent底层平台技术方案.md):统一 Agent Workspace / Runtime / Tool / Artifact 底层技术方案
> - [`17-GitHubWeeklyReportAgent技术实现方案.md`](17-GitHubWeeklyReportAgent技术实现方案.md):首个内置 Agent 的工程落地方案
> - [`18-SwiftAgentSDK调研报告.md`](18-SwiftAgentSDK调研报告.md):开源 Swift Agent SDK 实时调研与 runtime 选型建议
> - [`19-Cline-Agent设计学习心得.md`](19-Cline-Agent设计学习心得.md):Prompt、Tool Loop、Approval 与统一工作台边界
> - [`20-CLI-Agent作为AI-Provider初步方案.md`](20-CLI-Agent作为AI-Provider初步方案.md):Direct 版通过双向协议接入 Codex、Claude Code、Gemini CLI，以 Agent 工作台为主入口，并由 Starcat 统一承载动态审批与 RAG Tool 边界
> - [`../AI代理API设计.md`](../AI代理API设计.md):Starcat 现有 AI Proxy 协议
> - [`../CLAUDE.md`](../CLAUDE.md):项目铁律与 UI 规范
> - [`../功能清单.md`](../功能清单.md):P0/P1/P2 优先级矩阵

---

## 一、背景与动机

Starcat 已经是"GitHub Stars 管理 + 本地知识库"工具,2026 年大多数成熟产品都在做"AI Agent 化"。dong4j 提出:**在 Starcat 里做"技术选型 Agent"**(从 GitHub 找开源项目 → 分析 → 输出调研报告),并希望先调研生态 + 提场景建议,再决定是否立项。

本文档把那次讨论沉淀为可追溯的方案档案,作为后续 P1/P2 立项的依据。

> **后续 Agent 开发约束（2026-07-30）**：内置 Agent 继续以
> [`16-Agent底层平台技术方案.md`](16-Agent底层平台技术方案.md) 的 `LoopAgentRuntime`
> 为基线；需要接入 Codex、Claude Code、Gemini CLI 等外部执行后端时，不扩展
> `AIClientProtocol` 冒充普通模型 Provider，而是按
> [`20-CLI-Agent作为AI-Provider初步方案.md`](20-CLI-Agent作为AI-Provider初步方案.md)
> 新增 Direct-only 的外部 Runtime，并复用 Agent Workspace 的事件、审批、审计与产物展示。

---

## 二、生态调研结论

### 2.1 Swift/macOS 生态可用方案对比

| 方案 | 状态(2026-06) | 适配 Starcat? | 关键原因 |
|---|---|---|---|
| **Swarm** | 活跃,~490 stars,MIT | ⚠️ **形态最契合,dong4j 倾向** | Workflow / MCP / @Tool / Skills;但 **macOS 26+** 与 Starcat 15+ 冲突 |
| **AgentRunKit** | 活跃,MIT | ✅ **现网可接** | macOS 15+,OpenAI-compatible,MCP client,agent loop 开箱 |
| **SwiftAgent** | 活跃,~89 stars,MIT | ⚠️ 局部 | Step 管道 + FM 优先;同样 **macOS 26+** |
| **Apple Foundation Models** | 官方,WWDC25,macOS 26+ | ⚠️ 局部可用 | 3B 本地模型,支持 tool calling;但 Starcat 最低支持 macOS 15,冲突 |
| **Anthropic MCP(Model Context Protocol)** | 开放标准,官方 Swift SDK | ✅ 反向集成 | Starcat 当 MCP server 暴露 GitHub context;但**不**是 dong4j 想要的"Starcat 内嵌 agent" |
| **LangChain-Swift / LangGraph-Swift** | 仓库 404 / 半成品 | ❌ | 生态不成熟,生产不可用 |
| **OpenAI Function Calling / Anthropic Tool Use** | 一线模型原生能力 | ✅ **最稳** | 复用 Starcat 已有 `AIClient` / `OpenAIClient` 即可扩展 |
| **自研只读 Agent loop** | 未实现 | ✅ MVP 推荐 | 工具面 90% 已有;缺 tool calling + 报告 schema;详见 [`04-…对比分析.md`](04-AgentRunKit-Swarm-SwiftAgent-对比分析.md) |

> **详细三框架 + 自研对比** → [`04-AgentRunKit-Swarm-SwiftAgent-对比分析.md`](04-AgentRunKit-Swarm-SwiftAgent-对比分析.md)

### 2.2 核心判断（2026-06-27 修订）

> **Swift 生态已有可用 Agent 框架,但 none 能零妥协覆盖 Starcat macOS 15 基线 + Swarm 级 Workflow。** 推荐 **Phase 1 自研只读 loop（全量用户）→ Phase 2 Swarm（macOS 26 门控）**;AgentRunKit 作为「不想自研 loop」的 Plan B。详见 04 文档 Executive Summary。

---

## 三、Starcat 现状盘点(影响方案的硬约束)

| 维度 | 现状 | 对 agent 方案的影响 |
|---|---|---|
| 最低系统版本 | macOS 15 Sequoia(见 `CLAUDE.md` 技术栈) | 排除 Foundation Models 作为默认路径 |
| AI Provider | `AIClient` / `OpenAIClient` / `AIConfiguration` 已有,统一接 AI Proxy | 只需扩展 function calling 字段,无需新建调用层 |
| 工具能力 | GitHub API / `AnySearchWebProvider` / `RepoAIContextProvider` 已成熟 | agent 的"工具"几乎都是 Starcat 已有能力的薄包装 |
| 上下文打包 | `RepoContextPacker` 支持 token budget / tier rules | agent 多步循环里可以塞进完整 repo context |
| 批量调度 | `BatchAIQueueService` 已有队列、限速、并发控制 | 多 tool 串行/并行的基础已就位 |
| 付费墙 | `EntitlementGate` + `/api/v1/quota` 已落地 | agent 高消耗天然适合放 Pro 层 |
| 配额消耗 | 单次 AI 调用 = 1 quota(见 `AI代理API设计.md`) | agent 一次 run 消耗 5~15 quota,需重新定义粒度 |
| UI 容器 | `RepoAIWindowContentView` 已有 repo 级 chat / streaming / i18n 经验 | 长期应独立建设 Agent Workspace,只借鉴流式与输入框经验 |
| 保守策略铁律 | AI 输出**必须**用户确认才能写入(标签铁律) | agent 报告落地必须经过「预览 → 确认 → 写入」三段 |
| 已规划端点 | `/summarize` `/tags` `/embed` `/search` `/quota` `/health` | 都没有 tool calling 维度,agent 是**新能力**,不是补全 |

---

## 四、候选 agent 场景与 ROI 排序

### 4.1 总览

| # | 场景 | 触发频次 | 单次价值 | 数据闭环 | 推荐度 | 详细方案 |
|---|---|---|---|---|---|---|
| 1 | **替代品推荐 agent** | 高(每次浏览 stars 都能触发) | 中 | **最强**(基于用户 stars 库) | 🥇 | [`02-替代品推荐-Agent方案.md`](02-替代品推荐-Agent方案.md) |
| 2 | **批量打 tag agent** | 低(首次导入 / 整理时) | 中(降低新用户激活门槛) | 强 | 🥈 | [`13-Untagged批量整理-Agent方案.md`](13-Untagged批量整理-Agent方案.md) |
| 3 | **仓库健康度 + 维护活跃度分析** | 中 | 中 | 中(基于 GitHub API) | 🥉 | (待立项) |
| 4 | **技术选型 agent** | 低(一年 1~2 次) | **高** | 弱 | 4 | (dong4j 提的) |
| 5 | **Starred Repo 周报 agent** | 中(每周 1 次) | 中 | 强(基于本地 stars) | 5 | [`03-Starred-Repo-周报-Agent方案.md`](03-Starred-Repo-周报-Agent方案.md) |

### 4.2 推荐路径建议

> **第一个落地 = 替代品推荐 agent**(🥇),理由:
> 1. 数据闭环强(Starcat 已有 stars 库 + GitHub API 即可工作,不需要新增外部依赖)
> 2. 触发频次高,易被用户感知到价值
> 3. 是 GitHub Trending 等竞品**给不了**的差异化能力("基于用户历史的推荐")
> 4. 工具体量小,工具集只有 3-4 个,编排循环短(3-5 步),MVP 1 周内可出

> **Foundation Models 可行性需要单独评估**(macOS 26+ 限制 + 模型能力 + 成本),见 [`01-Foundation-Models-可行性分析.md`](01-Foundation-Models-可行性分析.md)。结论: **MVP 不做,等 v1.1 观察**。

---

## 五、Agent 编排器设计(自研,跨场景共用)

不管是替代品推荐还是技术选型,底层都共用同一个 `AgentOrchestrator`。**一次性写好,后面所有 agent 复用**。

### 5.1 核心循环(伪代码)

```swift
func run(userGoal: String) async throws -> AgentReport {
    var messages: [ChatMessage] = [
        .system("你是一个 Starcat Agent ... 具体指令随场景注入"),
        .user(userGoal)
    ]
    let maxSteps = 8   // 硬上限,防死循环
    for step in 0..<maxSteps {
        let response = try await llm.chat(messages, tools: toolDefs)
        if response.hasFinalAnswer {
            return response.toReport()
        }
        guard !response.toolCalls.isEmpty else { break }
        // 串行执行:避免 GitHub rate limit + 让 streaming UI 顺序展示
        for call in response.toolCalls {
            let result = try await executeTool(call)
            messages.append(.toolResult(call.id, result))
        }
    }
    throw AgentError.maxStepsExceeded(maxSteps)
}
```

### 5.2 Tool 协议

```swift
protocol AgentTool {
    var name: String { get }
    var description: String { get }   // 给 LLM 看的,必须清晰
    var schema: JSONSchema { get }    // 喂给 function calling 的参数定义
    func execute(_ args: [String: Any]) async throws -> ToolResult
}
```

### 5.3 关键约束(已踩坑边界)

- **Token 预算**:每步 tool result 必须截断到合理大小(参考 `RepoContextPacker` 的 tier rules),否则 5 步后 context 就爆
- **失败降级**:tool 失败不能让整个 run hang,必须返回结构化错误让 LLM 决定是否重试或换路径
- **用户可中断**:`Task` 包装 + `cancel()` 钩子,在 chat UI 给「停止」按钮
- **配额扣减**:每次 run 开始时按 `estimatedQuota = 5 + toolCount * 2` 预扣,失败回滚
- **流式输出**:每步 tool 执行结果推给 chat UI 作为"系统消息",让用户看到 agent 在干什么(不是黑盒)
- **i18n**:所有用户可见的 agent 提示词走 `String.l10n`,命名空间 `agent.<scene>.*`
- **可观测性**:`AIDebugLogger` 已有,agent 的每一步 tool call + 思考过程都打点(本地,不外发)

---

## 六、UI 落地（2026-06-27 修订：见产品叙事文档）

> **完整 IA / 分阶段 UI 策略** → [`10-Agent产品叙事-三条主线.md`](10-Agent产品叙事-三条主线.md) §六

**摘要**：

| 阶段 | 策略 |
|---|---|
| Phase 0~1 | 单场景嵌详情页（如 09）；共用 `AgentOrchestrator` |
| Phase 2 | Sidebar 一级 **「Agent」** 入口，内分 **整理 / 发现 / 消化** 三 Tab |
| 壳层 | 所有 run 共用进度、tool 步骤、报告渲染；详情页按钮 deep link 到 Agent 中心 |

MVP 可借鉴 `RepoAIWindowContentView` 的流式输入和渲染经验；长期 UI 底座以 [`16-Agent底层平台技术方案.md`](16-Agent底层平台技术方案.md) 的覆盖式 Agent Workspace 为准。

---

## 七、待 dong4j 拍板的决策点

1. **第一个落地的 agent 是哪个?**
   - A. 替代品推荐(🥇 推荐)
   - B. 批量打 tag
   - C. 仓库健康度分析
   - D. 技术选型(dong4j 提的)
   - E. 周报(作为长期订阅型 agent 的样例)

2. **Foundation Models 策略?**
   - A. MVP 不做(等 macOS 26 用户基数,推荐)
   - B. 作为"Apple Silicon 高配用户的可选加速器"先做 spike

3. **付费策略?**
   - A. agent 全 Pro(简单)
   - B. Free 每月 5 次 + Pro 不限(拉新友好)
   - C. 按单次 run 扣 N 配额(贴合现有 quota 模型)

4. **要不要写正式设计文档?**
   - 建议: 选定 1 号决策点后,把对应 agent 的方案文档升格为 `docs/3-设计/详细设计/07-Agent设计.md` 草案。

---

## 八、变更记录

| 日期 | 变更 | 作者 |
|---|---|---|
| 2026-06-27 | 初稿:与 dong4j 讨论的方案沉淀 | Claude |
| 2026-06-27 | 2.1/2.2 修订:纳入 Swarm/AgentRunKit/SwiftAgent 对比,链至 04 文档 | Claude |
| 2026-06-27 | §六 修订:链至 10 产品叙事;Sidebar Agent 三线 IA | Claude |
