# AgentRunKit / Swarm / SwiftAgent 对比分析 & 自研只读调研 Agent

> **文档定位**：Starcat Agent 运行时选型调研；对比三个 Swift Agent 框架，并与「自研只读调研 Agent」方案做横向评估。
> **状态**：讨论稿（2026-06-27），供 dong4j 拍板技术路线。
> **dong4j 倾向**：更偏好 **Swarm**（Workflow 编排、@Tool 宏、MCP 一等公民、AGENTS.md/SKILL.md 生态）。
> **关联文档**：
> - [`00-概览-Agent方向讨论与方案.md`](00-概览-Agent方向讨论与方案.md)：Agent 方向总览与共用编排器草案
> - [`01-Foundation-Models-可行性分析.md`](01-Foundation-Models-可行性分析.md)：macOS 26 / FM 约束
> - [`../详细设计/34-StarcatCLI与外部MCP桥接设计.md`](../详细设计/34-StarcatCLI与外部MCP桥接设计.md)：MCP 已落地能力
> - [`../详细设计/30-本地RAG设计.md`](../详细设计/30-本地RAG设计.md)：带引用生成层（与调研报告同族）

---

## 一、Executive Summary

| 维度 | 结论 |
|------|------|
| **三框架里谁最「像 Starcat 想要的 Agent」** | **Swarm** — 多 Agent Workflow、原生 MCP、记忆层、可 checkpoint 的长任务，和「技术选型调研」多步检索 → 深读 → 写报告高度契合 |
| **三框架里谁最「现在就能接进 Starcat」** | **AgentRunKit** — 唯一明确支持 **macOS 15+**，且 OpenAI-compatible 与 Starcat 现有 BYOK / `OpenAIClient` 同族 |
| **Swarm 的最大 blocker** | 官方要求 **macOS 26+ / Swift 6.2+**，与 Starcat 当前 **macOS 15+** 最低版本 **硬冲突**（与 FM 问题同构，见 `01-Foundation-Models-可行性分析.md`） |
| **自研 vs 引库** | 只读调研 Agent 的工具面 **90% 已是 Starcat 现有 Service**；缺的是 **tool-calling loop + 报告 schema**，自研约 **300~600 行** 可控；引库省 loop 样板，但引入 OS 版本 / 依赖维护成本 |
| **综合建议（在偏好 Swarm 前提下）** | **分阶段**：MVP 用 **自研只读 loop**（macOS 15 全量用户）→ 抽象 `AgentRuntime` 协议 → **macOS 26 用户群达标后** 再切 Swarm 实现同一套 Tool 接口；AgentRunKit 作为「若等不及 Swarm、又不想自研 loop」的 **Plan B** |

---

## 二、评估维度说明

本文从 Starcat 真实约束出发，不用「框架功能清单」做孤立排名：

1. **平台对齐**：能否在 macOS 15 上编译、运行（Starcat 当前 shipping 基线）。
2. **与现有 AI 栈融合**：BYOK、`AIClient`、AI Proxy、流式 UI、`EntitlementGate`。
3. **与 Starcat 领域工具融合**：GitHub API、AnySearch、本地 FTS/semantic、README 缓存、Repo Health。
4. **MCP 协同**：Starcat **已是 MCP Server**；Agent 侧是否需要 MCP Client 调外部工具。
5. **只读调研场景 fit**：多步检索、并行 fan-out、token 预算、结构化 Markdown 报告、用户可中断。
6. **长期维护**：社区活跃度、版本节奏、与 Swift 6 Strict Concurrency 的契合度。
7. **AI 保守策略**：写操作（star/tag/note）必须「建议 → 确认」；框架是否容易做 human-in-the-loop。

---

## 三、三框架总览对比

> 数据截止 **2026-06-27**（以各项目 README / GitHub 为准；版本号随上游变化）。

| 维度 | **Swarm** | **AgentRunKit** | **SwiftAgent** |
|------|-----------|-----------------|----------------|
| **仓库** | [christopherkarani/Swarm](https://github.com/christopherkarani/Swarm) | [Tom-Ryder/AgentRunKit](https://github.com/Tom-Ryder/AgentRunKit) | [1amageek/SwiftAgent](https://github.com/1amageek/SwiftAgent) |
| **Stars（约）** | ~490+ | 较小众 | ~89 |
| **License** | MIT | MIT | MIT |
| **最低 macOS** | **26.0+** | **15.0+** | **26.0+** |
| **最低 Swift** | 6.2+ | 6.0+ | 6.2+ |
| **核心抽象** | `Agent` + `Workflow` DAG | `Agent` + type-safe `Tool` | `Step` 声明式管道（类 SwiftUI） |
| **Agent 循环** | ✅ 原生多步 tool loop | ✅ 可配置 iteration / token budget | ⚠️ 偏 **确定性 Pipeline**，自治 loop 非主路径 |
| **Tool 定义** | `@Tool` / `@Parameter` 宏 | `Tool<P, R, C>` 泛型 + JSON Schema 编译期校验 | `AgentTools` 包 + MCP 工具名 |
| **MCP** | ✅ Client + Server | ✅ Client（stdio） | ✅ SwiftAgentMCP 子模块 |
| **Workflow** | ✅ sequential / parallel / route / repeatUntil / timeout | ✅ Sub-agent + depth 控制 | ✅ Parallel / Race / Loop（Step 级） |
| **Memory** | conversation / vector / slidingWindow / summary / hybrid | context compaction / checkpoint | Conversation FIFO + 多种 Step |
| **Provider** | FM、Anthropic、OpenAI、Ollama、Gemini、OpenRouter、MLX(Conduit) | OpenAI、Anthropic、Gemini、Vertex、Responses API、FM(26+)、MLX | **FoundationModels 优先**；可选 OpenFoundationModels trait |
| **Streaming** | AsyncThrowingStream | AsyncThrowingStream + `@Observable` SwiftUI | Step 级流式 |
| **Human-in-the-loop** | Guard / 可扩展 | ✅ Tool approval 策略 | Permission / Sandbox / Guardrail |
| **Checkpoint / 恢复** | ✅ durable workflow | ✅ per-iteration snapshot | 部分（Session 级） |
| **Skills / AGENTS.md** | ✅ 原生支持 workspace layout | ❌ | ✅ Skill 系统 |
| **与 Starcat macOS 15 冲突** | ❌ **致命** | ✅ 无 | ❌ **致命** |

---

## 四、分项深度分析

### 4.1 Swarm（dong4j 倾向项）

**为什么吸引人**

1. **Workflow 一等公民**：技术选型天然是「检索 Agent → 深读 Agent → 报告 Agent」流水线，Swarm 的 `.step().parallel().route()` 比手写 state machine 可读性高。
2. **MCP 双向**：Starcat 已暴露 `starcat.*` tools；Swarm 作 Client 还可接 AnySearch MCP、未来 CLI bridge，**协议层不重复造轮子**。
3. **@Tool 宏 + Strict Concurrency**：Swift 6.2 数据竞争在编译期卡住，和 Starcat 长期 Swift 6 方向一致。
4. **记忆与 checkpoint**：长调研任务（10+ 步、多候选 repo）可中断恢复，适合 App 被杀 / 用户切窗口。
5. **AGENTS.md / SKILL.md**：和 Starcat 已有 `AGENTS.md` 工作流、未来 `starcat` skill 化路线同频。

**主要风险**

| 风险 | 说明 | 缓解思路 |
|------|------|----------|
| **macOS 26+ 硬门槛** | 2026 年中 Starcat 用户绝大多数仍在 macOS 15~25 | 功能门控 `#available(macOS 26, *)`；或推迟集成到 v1.x |
| **框架年轻** | 2025-12 创建，API 仍快速迭代（0.4 → 0.6） | 锁 minor 版本；Tool 接口与 Swarm 解耦 |
| **依赖闭包** | Conduit / swift-syntax / 多 Provider 适配层 | SPM 依赖审计 + About 页登记 |
| **与 Starcat AIClient 重复** | Swarm 自带 InferenceProvider | 封装 `StarcatInferenceProvider` 走现有 Proxy/quota |

**Swarm 示例（调研 Workflow 伪代码）**

```swift
// 仅示意 API 形态，非 Starcat 生产代码
let research = Agent(
    instructions: "从 GitHub、网页、用户 stars 中收集候选…",
    inferenceProvider: .openAICompatible(baseURL: starcatProxy, key: byokKey)
) {
    GitHubSearchTool()
    AnySearchTool()
    StarredSemanticSearchTool()
    GetReadmeTool()
    RepoHealthTool()
}

let writer = Agent(instructions: "输出 Markdown 调研报告，带引用…") { /* 无 tool 或仅格式化 */ }

let report = try await Workflow()
    .step(research)
    .step(writer)
    .run(userQuery)
```

---

### 4.2 AgentRunKit

**定位**：偏 **SDK / runtime**，少 opinionated 工作流语法，多 **工程化 agent loop 能力**（iteration 上限、token budget、approval、checkpoint）。

**优势（对 Starcat）**

- **macOS 15+ 立刻可用**，无需动最低系统版本。
- **OpenAI-compatible 一等公民**，与 `OpenAIClient` / 各 BYOK Provider 路径一致。
- **MCP Client** 内置，可复用 Starcat 对外 MCP 或接 AnySearch MCP。
- **Tool approval**：契合「AI 保守策略」——写类 tool 可强制用户确认（只读调研 MVP 可先全开 approval-free）。
- **Examples/AgentCode**：有终端 coding agent 参考，但调研 Agent 更接近「多 search tool + 单次 report tool」。

**劣势**

- **无 Swarm 级 Workflow DSL**；多 Agent 靠 sub-agent 组合，编排可读性弱于 Swarm。
- **无 AGENTS.md / SKILL.md** 开箱工作区约定。
- 社区体量小于 Swarm，长期维护需自行评估。

**适用判断**：若 dong4j 希望 **3 个月内出只读调研 MVP** 且 **不抬 OS 版本**，AgentRunKit 是三个框架里 **唯一不妥协的选项**。

---

### 4.3 SwiftAgent

**定位**：**声明式 Step 管道**（`Transform` / `Generate` / `Parallel` / `Race`），哲学上更接近「可测试的数据流」而非「LLM 自主决定下一步调哪个 tool」。

**优势**

- Step 组合 **类型安全、可单测**；ResearchPipeline 示例与调研场景语义接近。
- 内置 Permission / Sandbox / Guardrail，安全模型清晰。
- MCP 子模块、Distributed Actor（Symbio）适合远期多 Agent 协作。

**劣势（对 Starcat 当前阶段）**

| 点 | 说明 |
|----|------|
| **macOS 26+** | 与 Swarm 相同 blocker |
| **FoundationModels 优先** | 默认路径绑 Apple 端侧模型；BYOK 需 OpenFoundationModels trait，集成路径绕 |
| **自治 Agent loop 非核心** | 更擅长 **预定 Pipeline**；「模型自己决定再搜一次 GitHub 还是读 README」需额外 Loop Step 或 override `run` |
| **学习曲线** | Step / Session / Conversation 概念多，和 Starcat 现有 `AIClient` 心智差异大 |

**适用判断**：若 Starcat 未来做 **macOS 26 专属、强 FM 本地化** 的 Agent，SwiftAgent 值得再看；**作为 2026 年只读调研 MVP 主 runtime 优先级低于 Swarm / 自研 / AgentRunKit**。

---

## 五、与「自研只读调研 Agent」的对比

### 5.1 自研方案定义（Scope）

**目标**：用户输入调研主题（如「macOS 本地向量数据库选型」）→ Agent 只读调用工具 → 输出 **Markdown 调研报告**（含引用）。

**工具集（MVP）**

| Tool | 底层复用 | 作用 |
|------|----------|------|
| `github_search` | `GitHubRepositorySearchProvider` / `GitHubAPIClient.searchRepositories` | 全网发现候选 repo |
| `search_starred_semantic` | 本地 embedding + semantic index | 「我收藏里有没有同类」 |
| `search_starred_keyword` | `LocalKeywordSearchProvider` / FTS5 | 关键词召回已 star |
| `web_search` | `AnySearchWebProvider` / `AnySearchClient` | 博客、对比文、HN |
| `get_repo` | `RepoRepository` + GitHub fallback | 元数据（stars、license、archived…） |
| `get_readme` | README 缓存 / GitHub API | 深读项目定位 |
| `get_repo_health` | `RepoHealthCalculator` + OpenSSF 缓存 | 成熟度 / 安全信号 |
| `list_related_starred` | tag + semantic 组合 | 与用户收藏库交叉分析 |

**明确不做（MVP）**：`star` / `upsert_note` / `apply_tags` —— 报告落地走「复制 / 导出 / 用户手动操作」。

### 5.2 四维对比表

| 维度 | 自研只读 Agent | Swarm | AgentRunKit | SwiftAgent |
|------|----------------|-------|-------------|------------|
| **macOS 15 可交付** | ✅ | ❌ | ✅ | ❌ |
| **接入 Starcat 现有 Service** | ✅ 直接调 | ⚠️ 需 `@Tool` 包装 | ⚠️ 需 `Tool<>` 包装 | ⚠️ 需 `Step` 包装 |
| **开发量（MVP 估算）** | 300~600 行 loop + 8 tools | 200~400 行 tools + 集成 | 150~350 行 + SPM | 400+ 行（Pipeline 设计） |
| **tool-calling 能力** | 需扩展 `AIClient` | ✅ 内置 | ✅ 内置 | ⚠️ 间接 |
| **多步并行检索** | 手写 `TaskGroup` | ✅ `Workflow.parallel` | ✅ 并行 tool | ✅ `Parallel` Step |
| **长任务恢复** | 需自研 snapshot | ✅ checkpoint | ✅ checkpoint | 部分 |
| **MCP 复用** | 可调现有 `StarcatMCPFacade` 逻辑 | ✅ Client/Server | ✅ Client | ✅ MCP 模块 |
| **流式 UI** | 复用 `RepoAIWindowContentView` | ✅ stream | ✅ `@Observable` | Step 级 |
| **Quota / Pro 门控** | 与现有 `EntitlementGate` 一体 | 需 adapter | 需 adapter | 需 adapter |
| **vendor lock-in** | 无 | 中 | 中 | 中高（FM 倾向） |
| **与 dong4j Swarm 偏好** | 可预留 `AgentRuntime` 协议后换 Swarm | ✅ 最契合 | 次选 | 低 |

### 5.3 自研并不「重复造 Swarm」的部分

Starcat 真正缺的不是 Workflow 语法，而是：

1. **`AIClient` 扩展 tool_call / tool_result 消息形态**（当前只有 `role + content`，见 `AIClient.swift` 注释）。
2. **领域 Tool 实现**（GitHub / AnySearch / semantic —— 无论用哪个框架都要写）。
3. **报告 schema + UI**（Markdown 渲染、复制、导出、引用跳转 repo detail）。

因此：**自研 loop ≠ 放弃 Swarm**；合理做法是 **Tool 层与 Runtime 层分离**，便于日后把 loop 换成 Swarm `Workflow` 而不重写 GitHub/AnySearch 包装。

---

## 六、自研只读调研 Agent — 简要实现架构

### 6.1 模块划分

```text
Starcat/Features/Agent/
├── AgentRuntime.swift          // 协议：run(goal:) -> AgentReport
├── SelfHostedAgentRuntime.swift // MVP：自研 loop
├── SwarmAgentRuntime.swift     // 远期：#available(macOS 26) 实现
├── AgentToolRegistry.swift     // 注册只读 tools
├── Tools/
│   ├── GitHubSearchAgentTool.swift
│   ├── StarredSemanticAgentTool.swift
│   ├── AnySearchAgentTool.swift
│   ├── RepoReadmeAgentTool.swift
│   └── RepoHealthAgentTool.swift
├── AgentOrchestrator.swift   // messages 管理、step 上限、取消
├── AgentReport.swift           // 结构化报告 + Markdown 渲染
└── ResearchAgentViewModel.swift // 复用 RepoAI 流式 UI 模式
```

### 6.2 核心循环（与 `00-概览` 共用，略扩展）

```swift
/// 只读调研 Agent：最多 8 步，防止 runaway cost。
func runResearch(userGoal: String) async throws -> AgentReport {
    var transcript: [AIChatMessage] = [.system(researchSystemPrompt), .user(userGoal)]
    let tools = AgentToolRegistry.readOnlyResearchTools

    for step in 0..<8 {
        try Task.checkCancellation()
        let response = try await aiClient.chatWithTools(
            messages: transcript,
            tools: tools.map(\.definition),
            stream: true  // 推 UI：thinking / tool_call 事件
        )

        if let report = response.finalReport {
            return report
        }

        for call in response.toolCalls {
            let result = try await tools.execute(call)  // 失败 → 结构化 error，不 throw 整 run
            transcript.append(.toolResult(id: call.id, content: result.truncatedJSON))
        }
    }
    throw AgentError.maxStepsExceeded
}
```

### 6.3 典型执行轨迹（技术选型）

```text
Step 0  LLM → github_search("vector database swift macos")
Step 1  LLM → search_starred_semantic("vector database embedding")
Step 2  LLM → web_search("sqlite-vec vs chromadb comparison 2026")
Step 3  LLM → get_repo + get_readme (top 3 候选，可并行 TaskGroup)
Step 4  LLM → get_repo_health (top 3)
Step 5  LLM → 生成 final Markdown（或调用 emit_report tool 强制 schema）
```

### 6.4 与现有代码的挂载点

| 现有模块 | 挂载方式 |
|----------|----------|
| `GitHubRepositorySearchProvider` | Tool 内构造 provider，不走 SearchCoordinator UI 状态 |
| `AnySearchContextProvider` | 复用 `allowsExternalContext` 门控与 quota 逻辑 |
| `RepoAIContextProvider` | README 截断规则对齐摘要 tier |
| `RepoHealthCalculator` | 只读 health badge 数据 |
| `RepoAIWindowContentView` | 新增「调研模式」或独立 sheet；tool 步骤以 system 消息展示 |
| `StarcatMCPToolRegistry` | Tool 实现可共享 `StarcatMCPFacade` 查询逻辑，避免双份业务规则 |
| `BatchAIQueueService` | 远期：后台批量「Weekly 调研」队列 |

---

## 七、自研方案的主要挑战

### 7.1 技术挑战

| # | 挑战 | 严重度 | 说明与对策 |
|---|------|--------|------------|
| T1 | **`AIClient` 无 tool calling** | 🔴 高 | 扩展 `AIChatRequest` / stream 解析 `tool_calls`；MacPaw OpenAI SDK 底层应支持，需在 adapter 层暴露 |
| T2 | **Token 爆炸** | 🔴 高 | 每个 tool result 硬截断（README 走 `RepoContextPacker` tier；web 只留 title+snippet）；参考 insight 管线 |
| T3 | **GitHub / AnySearch 限流** | 🟠 中 | 串行执行 tool 或限制并行度；复用 search session cache（GitHub 5min TTL） |
| T4 | **流式 UX** | 🟠 中 | 需新事件类型：`toolCallStarted` / `toolCallFinished` / `partialReport`；不能只有 assistant delta |
| T5 | **报告结构化** | 🟠 中 | 纯 Markdown 难解析 UI；建议 `@Generable` 或 JSON schema + Markdown body 双字段 |
| T6 | **取消与超时** | 🟡 低 | `Task.cancel` + 单步 timeout；用户点停止后保留 partial report |
| T7 | **测试** | 🟡 低 | Tool 单测 mock GitHub/AnySearch；loop 集成测用 stub LLM 固定 tool 序列 |

### 7.2 产品 / 运营挑战

| # | 挑战 | 说明 |
|---|------|------|
| P1 | **Quota 模型** | 一次调研 ≈ 5~15 次 LLM + N 次 GitHub/AnySearch；需定义「1 run = ? quota」 |
| P2 | **Pro 门控** | 高成本天然适合 Pro；Free 限次需产品拍板 |
| P3 | **报告存储** | 新表 vs 挂 note vs 仅会话内；涉及 CloudKit 同步范围 |
| P4 | **幻觉与引用** | 必须强制「主张 → repo URL / README 片段」绑定；UI 展示引用可点击 |
| P5 | **i18n** | 系统 prompt / tool description / 报告模板 双语；遵守 `docs/i18n军规.md` |

### 7.3 若选 Swarm 的迁移挑战（自研 → Swarm）

| # | 挑战 | 对策 |
|---|------|------|
| M1 | macOS 15 用户无法使用 Swarm 路径 | `#available` 双 runtime；设置页展示「增强 Agent（需 macOS 26）」 |
| M2 | 两套 runtime 行为不一致 | 共用 `AgentToolRegistry` + golden test（同一输入 tool 序列应一致） |
| M3 | Swarm 版本升级 | 锁 `from: "0.6.0"`，升级走 changelog 审查 |
| M4 | 依赖登记 | `project.yml` + `AboutView.swift` Credits |

---

## 八、决策矩阵与推荐路径

### 8.1 场景 × 选型

| 场景 | 推荐 |
|------|------|
| **现在就要 macOS 15 用户可用的只读调研 MVP** | **自研 loop**（或 AgentRunKit 若不想写 loop） |
| **6~12 个月后，macOS 26 占比 >40%，要 Workflow + MCP + Skills** | **Swarm**（dong4j 倾向合理） |
| **强 FM 本地化、Pipeline 可测试性优先** | SwiftAgent（与 Swarm 二选一，均要 OS 26） |
| **最小外部依赖、完全掌控 quota/stream** | 自研 |

### 8.2 推荐分阶段路线（兼顾 Swarm 偏好）

```text
Phase 0（1~2 周）Spike
  ├── 扩展 AIClient tool calling（单测 + 一个 fake tool）
  └── 自研 loop 跑通「github_search → get_readme → Markdown」

Phase 1（MVP，macOS 15+）
  ├── 完整只读 tool 集 + Research Agent UI
  ├── AgentRuntime 协议 + SelfHostedAgentRuntime
  └── Pro 门控 + quota 规则

Phase 2（macOS 26 门控）
  ├── 引入 Swarm SPM
  ├── SwarmAgentRuntime 实现同一 AgentRuntime 协议
  └── Workflow：research → analyze → write

Phase 3（可选）
  ├── Swarm checkpoint：长调研可恢复
  ├── AGENTS.md 导出 Starcat 调研 skill
  └── CLI `starcat research`（见 34 文档）
```

### 8.3 对「更倾向 Swarm」的直接回应

Swarm **在产品形态上是最对的选择**（Workflow、MCP、Skills、记忆、checkpoint 都指向「调研型 Agent」），但 **不能作为 Starcat 2026 年唯一的 Agent 交付路径**，除非接受以下之一：

- **A.** 抬高 App 最低版本到 macOS 26（与现有「macOS 15+」战略冲突，不推荐短期做）；
- **B.** Agent 功能 **仅 macOS 26+ 可用**（可接受，但 MVP 覆盖半衰期长）；
- **C.** **Phase 1 自研 + Phase 2 Swarm**（**推荐**：不耽误 MVP，也不放弃 Swarm 路线）。

AgentRunKit 的定位：**Swarm 因 OS 暂时进不来时的 loop 外包**；若团队愿意自研 loop，AgentRunKit 非必须。

---

## 九、附录：快速参考链接

| 项目 | 文档 | 备注 |
|------|------|------|
| Swarm | https://christopherkarani.github.io/Swarm/ | Workflow / MCP / @Tool |
| AgentRunKit | https://swiftpackageindex.com/Tom-Ryder/AgentRunKit/documentation/agentrunkit | macOS 15+ |
| SwiftAgent | https://1amageek.github.io/SwiftAgent/documentation/swiftagent/ | Step DSL / FM |
| Starcat MCP | `Starcat/Features/MCP/StarcatMCPToolRegistry.swift` | 已有 tool schema 可参考 |
| MCP Swift SDK | `project.yml` → MCPSwiftSDK 0.12.1 | Starcat 已依赖 |

---

## 十、变更记录

| 日期 | 变更 | 作者 |
|------|------|------|
| 2026-06-27 | 初稿：三框架对比 + 自研只读调研 Agent 实现与挑战 | Claude |
