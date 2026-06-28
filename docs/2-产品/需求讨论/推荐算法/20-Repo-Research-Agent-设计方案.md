# Starcat Repo Research Agent 设计方案

> 目标：在 Starcat 中实现一个面向 GitHub / 开源项目 / 技术选型的垂直 Agent。第一版不依赖 LangGraph、CrewAI、AutoGen 等外部 Agent 框架，而是优先使用 Swift 生态能力或自研一个简单、可控、可产品化的 MVP Runner。

---

## 1. 背景与定位

Starcat 当前已经具备 GitHub Repo 浏览、README 预览、Trending、AI 分析、第三方信息源接入等基础能力。Repo Research Agent 的价值不是再做一个通用聊天助手，而是把 Starcat 打造成一个更懂开源项目的开发者研究工具。

Repo Research Agent 的核心定位是：

> 用户输入一个技术方向、集成需求或选型问题，Starcat 自动从 GitHub 与外部搜索源中发现候选项目，分析项目质量、维护状态、集成成本、风险点，并生成结构化技术调研报告。

示例输入：

```text
我想为 Starcat 选择一个 macOS 本地全文搜索方案，要求支持 Swift 集成、本地索引、中文搜索、性能好、维护活跃。
```

示例输出：

```text
- 推荐候选项目
- 候选项目筛选依据
- 项目健康度分析
- 技术能力对比
- 集成成本评估
- 风险点
- 最终推荐方案
- 可下载 Markdown 报告
```

---

## 2. 为什么不建议第一版接入外部 Agent 框架

LangGraph、CrewAI、OpenAI Agents SDK、AutoGen 这类框架适合复杂多 Agent 编排，但 Starcat 的第一版需求更偏「固定流程 + 局部智能决策」。如果直接引入复杂框架，会带来几个问题：

1. **产品复杂度上升**：Agent 行为难以预测，前端进度展示困难。
2. **部署复杂度上升**：多数成熟框架以 Python / JS 为主，会引入额外运行时。
3. **调试成本上升**：多 Agent 对话、handoff、memory、retry 很容易失控。
4. **App Store 风险增加**：如果客户端内置过多脚本执行、动态工具加载、shell 调用，审核解释成本变高。
5. **不符合 MVP 目标**：第一版核心不是证明“Agent 框架很强”，而是证明“Starcat 能稳定产出高质量技术调研报告”。

因此第一版推荐：

```text
固定工作流 + Swift 自研 Agent Runner + LLM Tool Calling + GitHub/AnySearch/Starcat Tool
```

---

## 3. 可参考的 Swift 生态能力

### 3.1 Apple Foundation Models / Tool Calling

Apple 的 Foundation Models 框架支持开发者定义自定义 Tool，模型可以通过 Tool Calling 调用外部代码。Apple 文档中明确提到，开发者可以使用 `Tool` 扩展模型能力，Tool 需要满足并发安全要求，且模型可以连续执行工具调用。这对 Starcat 的本地 Agent 设计有启发意义：Tool 不一定要来自复杂 Agent 框架，也可以是应用内部的一组强类型 Swift 工具。  
参考：Apple Foundation Models 与 Tool 文档。  

### 3.2 SwiftAIAgent

`ShenghaiWang/SwiftAIAgent` 是一个 Swift Agent 框架，目标是用 Swift 构建简单的 AI Agent 系统。它可以作为 Starcat 研究 Swift Agent 抽象的参考，但不建议第一版直接强依赖，原因是成熟度、维护状态、API 稳定性都需要进一步验证。

### 3.3 AgentSDK-Swift

`AgentSDK-Swift` 是 OpenAI Agents SDK 的 Swift 实现，支持 tools、guardrails、多 Agent workflow 等概念，但项目自身标注仍处于 early development。它适合作为接口设计参考，不适合作为 Starcat 第一版核心依赖。

### 3.4 SwiftAI / SwiftAISDK

Swift 生态里也有一些更偏 LLM App 开发的库，例如 SwiftAI、SwiftAISDK，通常提供 streaming、structured output、tool/function calling、provider abstraction 等能力。它们比完整 Agent 框架更轻，更适合 Starcat 借鉴。

### 3.5 推荐结论

第一版建议：

```text
不直接依赖 Swift Agent 框架。
先自研一个轻量 Agent Runner。
LLM Provider 层可以抽象，后续再接 OpenAI、Anthropic、DeepSeek、Gemini、本地模型等。
Tool Calling 机制自己定义，保证强类型、可观测、可测试。
```

---

## 4. 总体架构

### 4.1 推荐 MVP 架构

```text
┌────────────────────────────────────┐
│ Starcat macOS App                   │
│ SwiftUI                             │
│                                    │
│ - 创建 Research Task                │
│ - 展示 Agent 执行步骤                │
│ - 展示候选 Repo                     │
│ - 展示分析过程                      │
│ - 展示 / 导出 Markdown 报告          │
└─────────────────┬──────────────────┘
                  │
                  ▼
┌────────────────────────────────────┐
│ RepoResearchAgentRunner             │
│ Swift                               │
│                                    │
│ - 状态机                            │
│ - Step 编排                         │
│ - Tool 调用                         │
│ - Retry / Cancel                    │
│ - Progress Event                    │
└─────────────────┬──────────────────┘
                  │
                  ▼
┌────────────────────────────────────┐
│ Tools                               │
│                                    │
│ - GitHubSearchTool                  │
│ - GitHubRepoTool                    │
│ - ReadmeTool                        │
│ - AnySearchTool                     │
│ - RepoScoringTool                   │
│ - LLMAnalysisTool                   │
│ - ReportGeneratorTool               │
└─────────────────┬──────────────────┘
                  │
                  ▼
┌────────────────────────────────────┐
│ Data Layer                          │
│                                    │
│ - GRDB / SQLite                     │
│ - Repo Cache                        │
│ - README Cache                      │
│ - Research Task                     │
│ - Research Report                   │
└────────────────────────────────────┘
```

### 4.2 后续增强架构

当 Starcat Agent 能力变复杂后，可以把 Agent Runtime 拆到本地 Helper 或后端服务：

```text
Starcat App
   │
   ├── Local Agent Runner，适合轻量任务
   │
   └── Remote Agent Service，适合重任务、批量分析、持续追踪
```

第一版建议全部放在客户端内完成，避免提前引入服务端复杂度。

---

## 5. MVP 目标范围

### 5.1 第一版只做一个 Agent

```text
Repo Research Agent
```

能力范围：

1. 用户输入研究主题。
2. Agent 生成 GitHub 搜索关键词。
3. 调用 GitHub Search API 获取候选项目。
4. 拉取 Repo 元信息、README、语言、License、Release 信息。
5. 对候选项目打分和排序。
6. 选择 Top N 项目进行 LLM 分析。
7. 生成技术调研 Markdown 报告。
8. 保存到 Starcat 本地数据库。
9. 支持导出 Markdown。

### 5.2 第一版不做的能力

| 能力 | 暂不做原因 |
|---|---|
| 自动 clone 所有候选项目 | 慢、占磁盘、复杂度高 |
| 自动运行代码 / 编译项目 | 安全风险高 |
| 自动 shell 执行 | App Store 与安全风险高 |
| 多 Agent 自由协作 | 难调试，MVP 没必要 |
| 长期自主后台运行 | 需要复杂任务调度和权限说明 |
| 自动发 Issue / PR | 产品边界过大 |

---

## 6. Agent 工作流设计

### 6.1 核心流程

```text
User Requirement
      ↓
Step 1. Parse Requirement
      ↓
Step 2. Generate Search Queries
      ↓
Step 3. Search GitHub Repositories
      ↓
Step 4. Fetch Repo Metadata
      ↓
Step 5. Fetch README / Releases / License / Languages
      ↓
Step 6. Score Candidates
      ↓
Step 7. Select Top Repos
      ↓
Step 8. Analyze Each Repo
      ↓
Step 9. Compare Repos
      ↓
Step 10. Generate Markdown Report
      ↓
Step 11. Save / Export Report
```

### 6.2 为什么使用固定流程

固定流程的好处：

1. 用户能看到清晰进度。
2. 失败后可以从某一步重试。
3. 成本可控。
4. 数据可缓存。
5. 结果可复现。
6. 便于后续接入更多工具。

这类 Agent 不应该让模型随意决定下一步，而应该让程序控制主流程，LLM 只负责：

```text
- 理解需求
- 生成搜索关键词
- 结构化分析项目
- 生成报告
```

程序负责：

```text
- 调用 GitHub API
- 控制候选项目数量
- 去重
- 缓存
- 评分
- 失败重试
- 进度事件
- 保存结果
```

---

## 7. Swift 自研 Agent Runner 设计

### 7.1 核心模型

```swift
struct ResearchTask: Identifiable, Codable, Sendable {
    let id: UUID
    var userQuery: String
    var status: ResearchTaskStatus
    var currentStep: ResearchStepKind?
    var steps: [ResearchStep]
    var candidates: [RepoCandidate]
    var selectedRepos: [RepoAnalysis]
    var report: ResearchReport?
    var createdAt: Date
    var updatedAt: Date
}

enum ResearchTaskStatus: String, Codable, Sendable {
    case pending
    case running
    case waitingForUser
    case completed
    case failed
    case cancelled
}

enum ResearchStepKind: String, Codable, Sendable {
    case parseRequirement
    case generateQueries
    case searchRepos
    case fetchMetadata
    case scoreCandidates
    case analyzeRepos
    case compareRepos
    case generateReport
    case saveReport
}

struct ResearchStep: Identifiable, Codable, Sendable {
    let id: UUID
    let kind: ResearchStepKind
    var title: String
    var status: StepStatus
    var message: String?
    var startedAt: Date?
    var finishedAt: Date?
}

enum StepStatus: String, Codable, Sendable {
    case pending
    case running
    case completed
    case failed
    case skipped
}
```

### 7.2 Runner 协议

```swift
protocol AgentRunner: Sendable {
    associatedtype Input: Sendable
    associatedtype Output: Sendable

    func run(input: Input) async throws -> AsyncThrowingStream<AgentEvent, Error>
    func cancel(taskID: UUID) async
}
```

### 7.3 Repo Research Runner

```swift
final actor RepoResearchAgentRunner {
    private let llm: LLMClient
    private let github: GitHubClient
    private let repository: ResearchRepository
    private let scorer: RepoScoringService
    private let reportGenerator: ReportGenerator

    init(
        llm: LLMClient,
        github: GitHubClient,
        repository: ResearchRepository,
        scorer: RepoScoringService,
        reportGenerator: ReportGenerator
    ) {
        self.llm = llm
        self.github = github
        self.repository = repository
        self.scorer = scorer
        self.reportGenerator = reportGenerator
    }

    func run(task: ResearchTask) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    continuation.yield(.stepStarted(.parseRequirement))
                    let requirement = try await parseRequirement(task.userQuery)
                    continuation.yield(.stepCompleted(.parseRequirement))

                    continuation.yield(.stepStarted(.generateQueries))
                    let queries = try await generateQueries(requirement)
                    continuation.yield(.stepCompleted(.generateQueries))

                    continuation.yield(.stepStarted(.searchRepos))
                    let repos = try await searchRepos(queries)
                    continuation.yield(.reposFound(repos))
                    continuation.yield(.stepCompleted(.searchRepos))

                    continuation.yield(.stepStarted(.scoreCandidates))
                    let scored = try await scorer.score(repos, requirement: requirement)
                    continuation.yield(.candidatesScored(scored))
                    continuation.yield(.stepCompleted(.scoreCandidates))

                    continuation.yield(.stepStarted(.analyzeRepos))
                    let analyses = try await analyzeTopRepos(scored, requirement: requirement)
                    continuation.yield(.repoAnalysesGenerated(analyses))
                    continuation.yield(.stepCompleted(.analyzeRepos))

                    continuation.yield(.stepStarted(.generateReport))
                    let report = try await reportGenerator.generate(
                        requirement: requirement,
                        analyses: analyses
                    )
                    continuation.yield(.reportGenerated(report))
                    continuation.yield(.stepCompleted(.generateReport))

                    try await repository.save(report)
                    continuation.yield(.completed(report))
                    continuation.finish()
                } catch {
                    continuation.yield(.failed(error.localizedDescription))
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
```

---

## 8. Tool 抽象设计

### 8.1 Tool 协议

```swift
protocol AgentTool: Sendable {
    associatedtype Input: Codable & Sendable
    associatedtype Output: Codable & Sendable

    var name: String { get }
    var description: String { get }

    func call(_ input: Input) async throws -> Output
}
```

### 8.2 GitHub 搜索 Tool

```swift
struct GitHubSearchReposInput: Codable, Sendable {
    let query: String
    let language: String?
    let minStars: Int?
    let sort: String?
    let perPage: Int
}

struct GitHubSearchReposOutput: Codable, Sendable {
    let items: [RepoCandidate]
}

struct GitHubSearchReposTool: AgentTool {
    let name = "github.searchRepos"
    let description = "Search public GitHub repositories by query, language, stars and sort options."

    private let client: GitHubClient

    func call(_ input: GitHubSearchReposInput) async throws -> GitHubSearchReposOutput {
        let repos = try await client.searchRepositories(
            query: input.query,
            language: input.language,
            minStars: input.minStars,
            sort: input.sort,
            perPage: input.perPage
        )
        return GitHubSearchReposOutput(items: repos)
    }
}
```

### 8.3 README Tool

```swift
struct FetchReadmeInput: Codable, Sendable {
    let owner: String
    let repo: String
}

struct FetchReadmeOutput: Codable, Sendable {
    let markdown: String?
    let html: String?
    let etag: String?
}

struct FetchReadmeTool: AgentTool {
    let name = "github.fetchReadme"
    let description = "Fetch README content for a GitHub repository."

    private let client: GitHubClient

    func call(_ input: FetchReadmeInput) async throws -> FetchReadmeOutput {
        try await client.fetchReadme(owner: input.owner, repo: input.repo)
    }
}
```

### 8.4 LLM 分析 Tool

```swift
struct AnalyzeRepoInput: Codable, Sendable {
    let requirement: ResearchRequirement
    let repo: RepoCandidate
    let readme: String?
    let metadata: RepoMetadata
}

struct AnalyzeRepoOutput: Codable, Sendable {
    let summary: String
    let strengths: [String]
    let weaknesses: [String]
    let integrationCost: String
    let risks: [String]
    let recommendation: String
    let score: Double
}

struct AnalyzeRepoTool: AgentTool {
    let name = "llm.analyzeRepo"
    let description = "Analyze whether a repository matches the user's technical requirement."

    private let llm: LLMClient

    func call(_ input: AnalyzeRepoInput) async throws -> AnalyzeRepoOutput {
        try await llm.structuredOutput(
            prompt: RepoAnalysisPrompt.build(input),
            schema: AnalyzeRepoOutput.self
        )
    }
}
```

---

## 9. GitHub 数据源设计

GitHub REST API 可用于创建集成、获取数据和自动化工作流；认证请求可以访问更多端点并获得更高的 rate limit。GitHub 官方文档显示，未认证 REST 请求的主要限制是每小时 60 次，认证请求拥有更高限制。因此 Starcat 应优先支持用户配置 GitHub Token，匿名模式只作为降级体验。

### 9.1 必要 API

| 数据 | API 类型 | 说明 |
|---|---|---|
| 搜索项目 | REST Search Repositories | 根据关键词、语言、stars、更新时间搜索 |
| Repo 基础信息 | REST Repositories | stars、forks、description、pushed_at、archived 等 |
| README | REST Contents / README | 分析项目说明与集成方式 |
| License | REST Repositories / License | 判断商用与集成风险 |
| Languages | REST Languages | 判断技术栈 |
| Releases | REST Releases | 判断发布活跃度 |
| Issues | REST Issues / Search | 判断维护状态与问题类型 |
| Contributors | REST Contributors | 粗略判断维护者数量 |

### 9.2 GraphQL 可作为后续优化

GitHub GraphQL API 的优势是查询更灵活，可以一次查询多个字段，减少 REST 多次请求。第一版可以先用 REST，后续再把 repo metadata 聚合查询迁移到 GraphQL。

### 9.3 缓存策略

建议缓存：

```text
repo_metadata: 6 小时
readme: ETag + 24 小时
releases: 12 小时
languages: 24 小时
license: 7 天
search_result: 1 小时
research_report: 永久保存，用户手动删除
```

---

## 10. 候选项目评分模型

MVP 阶段不要完全依赖 LLM 打分，应先用程序规则做基础评分，再让 LLM 解释原因。

### 10.1 评分维度

| 维度 | 权重 | 说明 |
|---|---:|---|
| 需求匹配度 | 30% | README、描述、topic 是否匹配 |
| 活跃度 | 20% | pushed_at、release、commit 活跃度 |
| 社区认可 | 15% | stars、forks、watchers |
| 可集成性 | 15% | 是否有 SDK、CLI、文档、示例 |
| 维护风险 | 10% | issue 响应、archived、deprecated |
| License 风险 | 10% | MIT/Apache 友好，GPL/AGPL 谨慎 |

### 10.2 示例评分结构

```swift
struct RepoScore: Codable, Sendable {
    let repoID: String
    let total: Double
    let requirementMatch: Double
    let activity: Double
    let community: Double
    let integration: Double
    let maintenanceRisk: Double
    let license: Double
    let reasons: [String]
}
```

### 10.3 评分规则示例

```text
如果 archived = true，直接降权。
如果 pushed_at 超过 18 个月，活跃度大幅降低。
如果最近 12 个月没有 release，发布活跃度降低。
如果 README 缺少安装、使用、示例，集成性降低。
如果 license 是 AGPL/GPL，商用集成风险提高。
如果 stars 高但近期无维护，不能直接推荐。
```

---

## 11. Prompt 设计

### 11.1 需求解析 Prompt

```text
你是 Starcat 的技术调研需求解析器。
请把用户输入解析为结构化 JSON。

要求：
- 不要生成报告。
- 不要虚构项目。
- 只提取搜索和评估所需信息。

用户输入：
{{user_query}}

输出 JSON：
{
  "topic": "",
  "targetPlatform": "",
  "preferredLanguages": [],
  "mustHave": [],
  "niceToHave": [],
  "avoid": [],
  "searchKeywords": [],
  "evaluationFocus": []
}
```

### 11.2 Repo 分析 Prompt

```text
你是 Starcat 的开源项目分析助手。
你的任务是判断某个 GitHub 项目是否适合用户的技术选型需求。

请基于输入数据分析，不要虚构 README 中没有的信息。
如果信息不足，请明确写“信息不足”。

用户需求：
{{requirement}}

项目元信息：
{{metadata}}

README：
{{readme}}

请输出 JSON：
{
  "summary": "",
  "matchReason": [],
  "strengths": [],
  "weaknesses": [],
  "integrationCost": "low|medium|high|unknown",
  "risks": [],
  "bestFor": [],
  "notSuitableFor": [],
  "score": 0,
  "recommendation": ""
}
```

### 11.3 报告生成 Prompt

```text
你是 Starcat 的技术调研报告生成器。
请根据候选项目分析结果，生成一份面向开发者和架构师的 Markdown 技术调研报告。

要求：
- 使用简体中文。
- 输出 Markdown。
- 不要输出闲聊内容。
- 不要虚构数据。
- 结论要明确。
- 需要包含对比表。
- 需要标注信息不足的地方。

报告结构：
1. 背景与目标
2. 需求拆解
3. 候选项目概览
4. 横向对比表
5. 项目逐项分析
6. 集成成本评估
7. 风险与限制
8. 最终推荐
9. 后续验证清单
```

---

## 12. UI / UX 设计建议

### 12.1 入口

可以在 Starcat 增加一个一级入口：

```text
Research
```

或者在搜索页增加：

```text
Ask Agent / 技术调研
```

### 12.2 任务创建页

字段：

```text
- 研究主题
- 目标平台，可选
- 首选语言，可选
- 最低 stars，可选
- 是否只看最近维护项目
- 报告深度：快速 / 标准 / 深度
```

### 12.3 运行中界面

建议用 Timeline：

```text
✅ 理解需求
✅ 生成搜索关键词
⏳ 搜索 GitHub 项目
○ 拉取项目元信息
○ 分析候选项目
○ 生成报告
```

每一步可以展开查看：

```text
- 搜索关键词
- 找到的项目数
- 被过滤的项目
- Top 候选项目
- 当前分析项目
```

### 12.4 报告页

报告页建议提供：

```text
- Markdown 预览
- 项目卡片
- 对比表
- 一键收藏 Repo
- 一键导出 Markdown
- 继续深度分析
```

---

## 13. 数据库设计

### 13.1 research_tasks

```sql
CREATE TABLE research_tasks (
    id TEXT PRIMARY KEY,
    user_query TEXT NOT NULL,
    status TEXT NOT NULL,
    current_step TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    completed_at INTEGER,
    error_message TEXT
);
```

### 13.2 research_steps

```sql
CREATE TABLE research_steps (
    id TEXT PRIMARY KEY,
    task_id TEXT NOT NULL,
    kind TEXT NOT NULL,
    title TEXT NOT NULL,
    status TEXT NOT NULL,
    message TEXT,
    started_at INTEGER,
    finished_at INTEGER,
    sort_order INTEGER NOT NULL
);
```

### 13.3 research_candidates

```sql
CREATE TABLE research_candidates (
    id TEXT PRIMARY KEY,
    task_id TEXT NOT NULL,
    repo_full_name TEXT NOT NULL,
    repo_url TEXT NOT NULL,
    stars INTEGER,
    forks INTEGER,
    language TEXT,
    license TEXT,
    pushed_at INTEGER,
    score REAL,
    reasons_json TEXT,
    raw_json TEXT
);
```

### 13.4 research_reports

```sql
CREATE TABLE research_reports (
    id TEXT PRIMARY KEY,
    task_id TEXT NOT NULL,
    title TEXT NOT NULL,
    markdown TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);
```

---

## 14. 并发、取消与重试

### 14.1 并发策略

建议：

```text
GitHub 搜索：串行或低并发
Repo metadata：最多 5 并发
README 拉取：最多 5 并发
LLM 分析：最多 1～2 并发
报告生成：串行
```

### 14.2 取消策略

用户点击 Cancel 后：

```text
- 停止后续步骤
- 当前网络请求允许自然结束
- 当前 LLM 请求尽量取消
- 保存已完成步骤
- 任务状态改为 cancelled
```

### 14.3 重试策略

```text
GitHub 429：读取 rate limit 信息，延迟重试或提示用户配置 Token
网络错误：最多重试 2 次
LLM JSON 解析失败：用 repair prompt 重试 1 次
单个 Repo 分析失败：跳过，不中断整个任务
报告生成失败：允许用户重试最后一步
```

---

## 15. 安全与边界

### 15.1 第一版不执行代码

Repo Research Agent 第一版只做信息分析，不执行仓库代码，不运行 shell，不自动 clone。这样可以降低安全风险，也更容易通过 App Store 审核。

### 15.2 GitHub Token 存储

如果支持用户配置 GitHub Token：

```text
- 存储到 Keychain
- 不写入日志
- 不进入 LLM Prompt
- 错误信息中脱敏
```

### 15.3 LLM 输入控制

发送给 LLM 的内容需要裁剪：

```text
- README 最多 N tokens
- 超长 README 先摘要
- 不发送用户 Token
- 不发送本地路径隐私信息
- 不发送无关缓存数据
```

---

## 16. 和 Starcat 现有能力的结合

### 16.1 与 GitHub 搜索结合

Research Agent 可以复用 Starcat 已有 GitHub 搜索入口，把普通搜索升级为：

```text
搜索 Repo → 分析 Repo → 生成调研报告
```

### 16.2 与 Trending 结合

可以新增：

```text
今日 Trending 研究报告
```

例如：

```text
分析今天 GitHub Trending 中值得关注的 AI Coding 项目
```

### 16.3 与收藏结合

报告中的项目可以一键收藏：

```text
- 收藏候选项目
- 加入对比集合
- 后续追踪 release
```

### 16.4 与 Repomix / CodeGraphContext 结合

MVP 阶段不自动 clone。后续可以做深度分析：

```text
用户手动选择 1～3 个项目
        ↓
Starcat clone 到本地
        ↓
Repomix 提取项目上下文
        ↓
CodeGraphContext 生成结构分析
        ↓
LLM 生成深度集成报告
```

---

## 17. 分阶段路线图

### Phase 1：MVP Research Workflow

目标：证明 Starcat 能稳定生成技术调研报告。

包含：

```text
- Research 入口
- 固定工作流 Runner
- GitHub Search
- Repo metadata 拉取
- README 分析
- 项目评分
- Markdown 报告
- 本地保存
```

不包含：

```text
- clone
- shell
- 多 Agent
- 后台长期任务
```

### Phase 2：深度 Repo 分析

包含：

```text
- 用户手动选择项目
- clone 到本地
- Repomix 分析
- CodeGraphContext 分析
- 深度技术报告
```

### Phase 3：持续追踪 Agent

包含：

```text
- 关注技术方向
- 定期发现新项目
- release 变化提醒
- star 增长异常提醒
- 周报 / 月报
```

### Phase 4：Agent 模板体系

内置多个 Agent 模板：

```text
- 技术选型 Agent
- Repo 健康度 Agent
- 开源替代品发现 Agent
- Trending 解读 Agent
- License 风险 Agent
- 集成方案 Agent
- README 可信度 Agent
```

---

## 18. 推荐目录结构

```text
Starcat/
  Features/
    Research/
      Views/
        ResearchHomeView.swift
        ResearchTaskView.swift
        ResearchReportView.swift
      ViewModels/
        ResearchViewModel.swift
      Agent/
        RepoResearchAgentRunner.swift
        ResearchTask.swift
        ResearchStep.swift
        AgentEvent.swift
      Tools/
        GitHubSearchReposTool.swift
        FetchRepoMetadataTool.swift
        FetchReadmeTool.swift
        AnalyzeRepoTool.swift
        GenerateReportTool.swift
      Services/
        RepoScoringService.swift
        ReportGenerator.swift
        PromptBuilder.swift
      Persistence/
        ResearchRepository.swift
        ResearchSchema.swift
```

---

## 19. MVP 开发任务拆分

### 任务 1：数据模型与数据库

```text
- ResearchTask
- ResearchStep
- RepoCandidate
- RepoAnalysis
- ResearchReport
- GRDB 表结构
```

### 任务 2：GitHub 数据工具

```text
- searchRepositories
- fetchRepoMetadata
- fetchReadme
- fetchLanguages
- fetchReleases
- fetchLicense
```

### 任务 3：LLM Client 抽象

```text
- streaming chat
- structured output
- provider abstraction
- retry
- json repair
```

### 任务 4：Agent Runner

```text
- step 编排
- progress event
- cancel
- retry
- error handling
```

### 任务 5：评分服务

```text
- 基础规则评分
- LLM 分析融合
- Top N 筛选
```

### 任务 6：报告生成

```text
- Markdown 模板
- 对比表
- 推荐结论
- 导出 Markdown
```

### 任务 7：UI

```text
- 创建任务页
- 执行进度页
- 候选项目列表
- 报告详情页
```

---

## 20. 最终建议

Starcat 的 Repo Research Agent 第一版不需要追求“通用智能体”，而应该追求“稳定、可控、可解释的技术调研工作流”。

最推荐的实现路线：

```text
Swift 自研 MVP Runner
    ↓
固定 Research Workflow
    ↓
强类型 Tool 抽象
    ↓
GitHub API + README + LLM 分析
    ↓
Markdown 技术调研报告
    ↓
后续再接 Repomix / CodeGraphContext 做深度分析
```

这一版做出来后，Starcat 的产品定位会从：

```text
GitHub 客户端 / Trending 浏览器
```

升级为：

```text
面向开发者的开源项目研究与技术选型工作台
```

这比简单做 AI 摘要更有壁垒，也更符合 Starcat 已有能力的演进方向。

---

## 21. 参考资料

- Apple Foundation Models Tool 文档：支持通过 Tool 扩展模型能力，并要求 Tool 满足并发安全约束。
- Apple Foundation Models 文档：支持通过自定义 Tool 扩展 on-device 模型能力。
- GitHub REST API 文档：用于创建集成、获取数据和自动化工作流。
- GitHub REST API Rate Limits 文档：未认证请求主要限制为每小时 60 次，认证请求拥有更高限制。
- GitHub GraphQL API 文档：相比 REST API，GraphQL 可以提供更精确和灵活的查询。
- GitHub REST Repository Contents 文档：可用于获取仓库内容与 README。
- SwiftAIAgent：Swift Agent 框架参考。
- AgentSDK-Swift：OpenAI Agents SDK 的 Swift 实现参考，当前仍处于 early development。
- SwiftAI / SwiftAISDK：Swift LLM App、tool/function calling、provider abstraction 方向的参考。
