# GitHub Weekly Report Agent 技术实现方案

> **文档定位**: `GitHub Weekly Report Agent` 作为 Starcat Agent 底层平台的首个接入实例的技术实现方案。本文只写该 Agent 的场景实现事实；底层 Runtime、Workspace、统一仓库目录、RAG/MCP/CLI 与权限边界以 [`../../../3-设计/详细设计/57-Agent工作台与统一能力层详细设计.md`](../../../3-设计/详细设计/57-Agent工作台与统一能力层详细设计.md) 为准，旧版 [`16-Agent底层平台技术方案.md`](16-Agent底层平台技术方案.md) 仅供历史追溯。
> **状态**: Cline-style 正式版本已于 2026-07-11 落地。
> **实现状态**: 已接入模型驱动 tool-calling loop、冻结的本地仓库上下文、可选 External Search、消息链审计和单 Markdown artifact;AI 未配置时明确失败,不生成 sample artifact。写 tag / note / status / star 操作仍不在本轮范围。
> **关联文档**:
> - [`08-Weekly-Trending解读方案.md`](08-Weekly-Trending解读方案.md):产品与交互方案
> - [`16-Agent底层平台技术方案.md`](16-Agent底层平台技术方案.md):Agent 底层平台方案
> - [`00-概览-Agent方向讨论与方案.md`](00-概览-Agent方向讨论与方案.md)

---

## 当前正式实现(2026-07-11)

本节是本文的当前事实源。后续章节保留 2026-06 的原始产品设想和目录草案;如有冲突,以本节与 [`AgentClineLoop专项/checklist.md`](../../../4-工程进度/AgentClineLoop专项/checklist.md) 为准。

### GitHub Weekly Report

- 正式工具 allowlist 为 `agent_parse_goal`、`context_resolve_repos`、`external_search`、`repo_cluster_topics`、`artifact_build_weekly_report`。
- 模型自主决定工具调用顺序和参数,Runtime 负责 schema、allowlist、权限、重试、超时与预算校验;不存在固定 Trending / Weekly 工具链。
- run 启动时冻结用户选择和本地仓库快照,避免执行中数据库变化导致上下文漂移。
- `external_search` 复用设置页 Provider、API Key、隐私开关和缓存;关闭时返回 skipped tool-result,搜索失败时把错误作为可审计结果回灌给模型,本地链路仍可继续。
- `artifact_build_weekly_report` 是终止工具,输出一份 Markdown 周刊并持久化;结果位于执行时间线底部,可在 Inspector 预览、复制和导出。
- 未手选仓库时，默认业务上下文是最近 7 天由 Weekly 数据源采集到的项目，不是“最近 7 天新增 Star”。没有项目时输出合法空周报。
- 手选仓库来自 Agent 统一目录：按 repo ID 合并本地 `repos`、Weekly、Trending 与 Discovery。Star、知识库和各公共来源只是可多选筛选维度，任何一项都不是准入条件。
- 目录按 6,000+ 全量已知仓库设计；最多上屏 80 条只是选择器展示窗口，搜索和筛选仍覆盖全量目录。

### Repo Insight 复用

Repo Insight 使用同一套 Prompt、Message、Tool、Loop、Approval、Repository 和 Workspace,其 allowlist 为 `agent_parse_repo_insight_goal`、`context_select_repo`、`external_search`、`artifact_build_repo_insight`。它不是第二套 Agent Runtime。

### 当前不做

多产物继续对话、小红书卡片、HTML、视频文案、图片生成、定时运行、自动发布和自动写用户数据均未交付,不在本次正式版本范围。

---

## 一、原始实现目标(历史提案)

`GitHub Weekly Report Agent` 的目标不是单独建一个周刊页面,而是在 Agent 底层平台上验证第一条完整链路:

```text
用户 prompt / 定时任务 / repo 选择
  ↓
AgentRuntime
  ↓
Trending / Weekly / Selection / Repo Overview tools
  ↓
Canonical Weekly Report
  ↓
Markdown / 小红书 / HTML / 视频文案 / 图片 prompt Artifacts
  ↓
用户确认、局部修改、复制、导出、保存历史
```

首版成功标准:

- 能从 Agent Workspace 运行 `GitHub Weekly Report Agent`
- 能基于 `trending-api` 或用户选中 repo 生成一份 Markdown 周刊
- 能展示步骤时间线,包括数据读取、筛选、聚类、生成、产出物创建
- 能继续对话做局部修改
- 能复制 / 导出 Markdown artifact
- 不依赖 macOS 26-only 能力

首版不做:

- 自动发布到任何平台
- 自动生成 mp4
- 默认自动调用图片生成 API
- 在 Agent loop 内自动写 Note / 打 tag / 修改 repo 状态

---

## 二、工程落点

建议新增目录:

```text
Starcat/Features/Agents/
  Core/
    AgentDefinition.swift
    AgentRuntime.swift
    AgentRunEvent.swift
    AgentTool.swift
    AgentToolRegistry.swift
    AgentArtifact.swift
    AgentWorkspaceView.swift
  WeeklyReport/
    GitHubWeeklyReportAgentDefinition.swift
    WeeklyReportRunContextBuilder.swift
    WeeklyReportPromptBuilder.swift
    WeeklyReportSchemas.swift
    WeeklyReportArtifactBuilders.swift
    Tools/
      FetchTrendingReposTool.swift
      FetchWeeklyFeedTool.swift
      ResolveSelectedReposTool.swift
      GetRepoOverviewTool.swift
      ClusterWeeklyTopicsTool.swift
      GenerateWeeklyReportTool.swift
      BuildWeeklyMarkdownArtifactTool.swift
      BuildXHSCardsArtifactTool.swift
      BuildVideoScriptArtifactTool.swift
      BuildImagePromptsTool.swift
```

测试目录:

```text
StarcatTests/Agents/
  WeeklyReport/
    WeeklyReportRunContextBuilderTests.swift
    WeeklyReportPromptBuilderTests.swift
    WeeklyReportSchemasTests.swift
    FetchTrendingReposToolTests.swift
    FetchWeeklyFeedToolTests.swift
    ClusterWeeklyTopicsToolTests.swift
    BuildWeeklyMarkdownArtifactToolTests.swift
    GitHubWeeklyReportAgentRuntimeTests.swift
```

实现约束:

- 新增 Swift 文件后必须跑 `xcodegen generate`
- UI 文字走 i18n,命名空间建议 `agent.weekly.*`
- 复杂 tool / runtime 代码必须写“为什么 + 关键约束”注释
- 不做旧 schema 兼容或迁移兜底

---

## 三、AgentDefinition

### 3.1 定义

```swift
enum BuiltInAgentID {
    static let githubWeeklyReport = "github-weekly-report"
}

enum GitHubWeeklyReportAgentDefinition {
    static let definition = AgentDefinition(
        id: BuiltInAgentID.githubWeeklyReport,
        titleKey: "agent.weekly.title",
        descriptionKey: "agent.weekly.description",
        category: .content,
        iconSystemName: "newspaper",
        defaultPromptKey: "agent.weekly.defaultPrompt",
        capabilities: [
            .readGitHub,
            .readTrending,
            .readWeekly,
            .generateText,
            .generateImagePrompt,
            .export,
            .schedule
        ],
        toolIDs: [
            WeeklyReportToolID.fetchTrendingRepos,
            WeeklyReportToolID.fetchWeeklyFeed,
            WeeklyReportToolID.resolveSelectedRepos,
            WeeklyReportToolID.getRepoOverview,
            WeeklyReportToolID.clusterTopics,
            WeeklyReportToolID.generateReport,
            WeeklyReportToolID.buildMarkdownArtifact,
            WeeklyReportToolID.buildXHSCardsArtifact,
            WeeklyReportToolID.buildVideoScriptArtifact,
            WeeklyReportToolID.buildImagePrompts,
            WeeklyReportToolID.exportArtifacts
        ],
        artifactTypes: [
            .markdown,
            .xhsCards,
            .html,
            .videoScript,
            .imagePrompt,
            .image
        ],
        confirmationPolicy: .defaultSafe,
        quotaPolicy: .estimated(base: 4)
    )
}
```

### 3.2 能力边界

| 能力 | P0 | 后续 |
|---|---|---|
| trending-api 热门 repo | 做 | 扩展 topic / stars growth |
| 用户手选 repo | 做 | 支持混合来源去重 |
| Weekly feed | 做 | 支持 issue / source 更细筛选 |
| Markdown artifact | 做 | 增加模板 |
| 小红书文案 | P1 | P1 接真实卡片预览 |
| HTML artifact | P1 | P2 增加主题模板 |
| 视频文案 | P1 | P2 增加字幕导出 |
| 图片 prompt | P1 | P2 接图片生成 API |
| 定时任务 | P2 | P2/P3 后台调度 |

---

## 四、上下文注入

### 4.1 来源

Weekly Agent 支持五类入口:

| 入口 | `AgentRunContext.source` | 注入内容 |
|---|---|---|
| Agent Workspace 直接运行 | `.agentHome` | 无 repo,由 prompt 决定 |
| Trending 多选后运行 | `.trendingSelection` | `SelectionSnapshot[]` + since / language |
| Weekly 多选后运行 | `.weeklySelection` | `SelectionSnapshot[]` + Weekly filter |
| Manage 多选后运行 | `.manageSelection` | `SelectionSnapshot[]` + current filters |
| Repo 详情页运行 | `.repoDetail` | 当前 repo snapshot |

现有 `WeeklyContentView` 已在多选时使用 `SelectionSnapshot(ghRepoId:owner:name:)`,Weekly Agent 直接消费同一类快照,不要引入第二套 selection model。

### 4.2 Builder

```swift
struct WeeklyReportRunContextBuilder {
    func build(
        source: AgentContextSource,
        selectedRepos: [SelectionSnapshot],
        currentRepo: SelectionSnapshot?,
        filters: WeeklyReportSourceFilters,
        settings: AppSettings
    ) -> AgentRunContext
}
```

关键约束:

- run 开始时立即冻结上下文
- 后续列表筛选变化不影响当前 run
- context 中只存必要字段,不要把完整 `WeeklyFeedItem` / `TrendingRepo` 全量塞入
- 详情获取由 tool 再按 owner/name/repoID 拉取

### 4.3 输入框预填

当用户从选择上下文进入 Agent Workspace:

```text
已选中 8 个 repo。你可以说:
「基于这些 repo 生成一期本周 AI Agent 开源项目周刊,风格参考阮一峰 Weekly」
```

这只是 prompt suggestion,不自动执行。

---

## 五、数据源工具

### 5.1 `FetchTrendingReposTool`

复用: `TrendingAPI.fetchTrending(since:language:)`

输入:

```json
{
  "since": "weekly",
  "language": "Swift",
  "top": 30
}
```

输出:

```json
{
  "items": [
    {
      "ghRepoId": 123,
      "owner": "owner",
      "name": "repo",
      "description": "...",
      "language": "Swift",
      "stars": 12345,
      "url": "https://github.com/owner/repo"
    }
  ],
  "summary": "Fetched 30 weekly trending repos"
}
```

实现说明:

- `TrendingAPI.fetchTrending` 当前支持 `since` 和 `language`
- `top` 首版在客户端截断,除非后端已有对应 query
- tool result 给 LLM 的 compact 版本只保留 top N 核心字段
- 完整 source snapshot 存 artifact / run context,不要全部塞回 prompt

### 5.2 `FetchWeeklyFeedTool`

复用: `WeeklyAPI.fetchRepos(query:)`

输入:

```json
{
  "source": "all",
  "language": "Swift",
  "starsRange": "1000+",
  "pageSize": 50
}
```

实现说明:

- 复用 `WeeklyFeedQuery`
- 不把 Weekly 远端数据强行并入 ActivityViewModel
- 如果用户从 Weekly 页面进入,优先使用上下文里的筛选条件构造 query

### 5.3 `ResolveSelectedReposTool`

输入:

```json
{
  "selectionIDs": ["..."]
}
```

输出: `WeeklyReportRepoSeed[]`

作用:

- 把 UI 快照转为 Agent 可用的 repo seed
- 只负责解析 owner/name/ghRepoId
- 不做 README 深读,深读交给 `GetRepoOverviewTool`

### 5.4 `GetRepoOverviewTool`

复用:

- repo 本地缓存
- GitHub fallback
- README cache / prefetch
- `RepoContextPacker` 的 token budget 经验

输出结构:

```json
{
  "repo": {
    "owner": "owner",
    "name": "repo",
    "description": "...",
    "language": "Swift",
    "topics": ["macos", "agent"],
    "stars": 12345,
    "license": "MIT",
    "homepage": "..."
  },
  "readmeSummary": "...",
  "recentSignals": [
    "release in last 14 days",
    "stars increased this week"
  ],
  "evidence": [
    {
      "type": "readme",
      "label": "README",
      "url": "https://github.com/owner/repo"
    }
  ]
}
```

约束:

- README 原文不直接完整回传给 LLM
- 先在 tool 内做摘要和证据字段
- source evidence 必须保留,供最终报告引用与 UI 展示

---

## 六、生成工具

### 6.1 两阶段生成

Weekly Agent 不应该每个输出形态各自理解 repo。统一流程:

```text
Repo seeds
  ↓
Repo overviews
  ↓
clusterTopics
  ↓
generateCanonicalReport
  ↓
buildArtifacts
```

### 6.2 `ClusterWeeklyTopicsTool`

输入: `WeeklyReportRepoOverview[]`

输出:

```json
{
  "topics": [
    {
      "id": "ai-agent-tools",
      "title": "AI Agent 工具链",
      "summary": "本周多个项目集中在 Agent 编排、工具调用和本地运行体验。",
      "repoRefs": ["owner/repo", "owner2/repo2"]
    }
  ]
}
```

实现:

- 首版可用 `AgentLLMClient` structured output
- 如果 LLM 失败,降级为按 language/topics 简单分组
- topic 数量建议 3-5 个

### 6.3 `GenerateWeeklyReportTool`

输入:

- repo overviews
- topics
- style guide
- artifact request
- source snapshot

输出: `WeeklyReportDraft`

Schema:

```swift
struct WeeklyReportDraft: Codable, Sendable {
    var title: String
    var subtitle: String?
    var intro: String
    var trendSummary: [String]
    var sections: [WeeklyReportSection]
    var closing: String
    var sourceSnapshot: WeeklyReportSourceSnapshot
    var imagePlan: [WeeklyReportImagePlan]
}
```

每个 repo 段落:

```swift
struct WeeklyReportRepoEntry: Codable, Sendable {
    var owner: String
    var name: String
    var url: String
    var oneLine: String
    var whatItIs: String
    var whyTrending: String
    var highlights: [String]
    var bestFor: String?
    var caveats: String?
    var evidence: [WeeklyReportEvidence]
}
```

关键 prompt 约束:

- 不夸大 repo 能力
- 不把 README 文案整段照搬
- 每个 repo 至少给一个“为什么值得关注”
- 不把 Starcat 用户个人数据写入公开周刊,除非用户明确要求
- 中文表达接近技术周刊,避免营销腔

### 6.4 `BuildMarkdownArtifactTool`

输入: `WeeklyReportDraft`

输出: `AgentArtifact(type: .markdown)`

Markdown 结构:

```markdown
# 本周 GitHub 热门项目观察

> 本期基于 YYYY-MM-DD 至 YYYY-MM-DD 的 trending-api / Weekly 数据生成。

## 本周趋势

## 主题一：AI Agent 工具链

### owner/repo

- 是什么：
- 为什么值得关注：
- 亮点：
- 适合：
- 注意：

## 总结
```

P0 只要求 Markdown。

### 6.5 多形态 Artifact

后续 artifact builder 从 `WeeklyReportDraft` 派生:

| Tool | 输出 |
|---|---|
| `BuildXHSCardsArtifactTool` | 9 张卡文案 + 配文 + 标签 |
| `BuildHTMLArtifactTool` | 静态 HTML 内容模型 |
| `BuildVideoScriptArtifactTool` | 口播稿 / 分镜 / 字幕 |
| `BuildImagePromptsTool` | cover / repo concept / card background prompts |

---

## 七、Artifact Schema

### 7.1 Markdown

```swift
struct WeeklyMarkdownArtifactContent: Codable, Sendable {
    var markdown: String
    var sourceSnapshotID: String
    var generatedFromDraftVersion: Int
}
```

### 7.2 小红书

```swift
struct XHSCardsArtifactContent: Codable, Sendable {
    var caption: String
    var hashtags: [String]
    var cards: [XHSCard]
}

struct XHSCard: Codable, Sendable {
    var index: Int
    var title: String
    var body: String
    var imagePrompt: String?
    var imageArtifactID: UUID?
}
```

### 7.3 视频文案

```swift
struct VideoScriptArtifactContent: Codable, Sendable {
    var title: String
    var durationSeconds: Int
    var scenes: [VideoScriptScene]
    var srt: String?
    var externalVideoPrompt: String
}
```

### 7.4 图片 prompt

```swift
struct WeeklyImagePromptArtifactContent: Codable, Sendable {
    var prompts: [WeeklyImagePrompt]
}

struct WeeklyImagePrompt: Codable, Sendable {
    var target: String
    var prompt: String
    var size: String
    var style: String
    var requiresApproval: Bool
}
```

图片 prompt 生成不等于图片生成。真实图片 API 调用必须走确认点。

---

## 八、UI 接入

### 8.1 Agent Rail

`GitHub Weekly Report` 在左侧 Agent Rail 作为首个 enabled item:

```text
GitHub Weekly Report
整理热门开源项目并生成周刊
tags: trending / report / image / schedule
status: Ready
```

其它 Agent 可先 disabled / coming soon,但不要影响首个 Agent 闭环。

### 8.2 Run Header

Weekly run header 展示:

- Agent: GitHub Weekly Report
- 来源: Trending weekly / 8 selected repos / Weekly feed
- 输出: Markdown
- 状态: Planning / Running / Waiting confirmation / Completed
- 成本: text quota estimate

### 8.3 Timeline Steps

P0 默认步骤:

1. 解析任务目标
2. 拉取数据源
3. 解析 / 补齐 repo 概览
4. 聚类主题
5. 生成周刊母稿
6. 创建 Markdown artifact

每一步可以展开:

```text
工具: trending.fetchRepos
输入: since=weekly, language=all, top=30
输出: 30 repos
耗时: 1.2s
```

### 8.4 Artifact Preview

P0 artifact tabs:

```text
[Markdown] [Run Log]
```

P1 增加:

```text
[小红书图文] [HTML] [视频文案] [图片 Prompt]
```

Markdown preview 支持:

- 复制全文
- 导出 `.md`
- 局部重生成选中段落
- 继续对话修改

### 8.5 继续对话

用户输入:

```text
第 2 个项目写得太像广告,改得更客观一点。
```

Runtime 做法:

- 找到当前 artifact 的目标段落
- 新建 artifact version
- 不重跑数据源 tools
- Timeline 追加一个 `Revise artifact section` step

---

## 九、运行时流程

### 9.1 P0 手动运行

```text
AgentWorkspaceView.send(prompt)
  ↓
AgentRuntime.run(definition: githubWeeklyReport, context)
  ↓
WeeklyReportRunContextBuilder.freeze()
  ↓
Planner creates steps
  ↓
FetchTrendingReposTool or ResolveSelectedReposTool
  ↓
GetRepoOverviewTool fan-out with concurrency limit
  ↓
ClusterWeeklyTopicsTool
  ↓
GenerateWeeklyReportTool
  ↓
BuildMarkdownArtifactTool
  ↓
AgentRunStore.save()
  ↓
UI receives artifactCreated
```

### 9.2 并发限制

`GetRepoOverviewTool` 可能对多个 repo fan-out。建议:

- P0 最大 8 个并发
- 单 run 最大 repo 数默认 30
- 用户手选超过 30 时先确认或提示裁剪
- tool result compact 后再回传给 LLM

### 9.3 取消

取消时:

- 当前网络请求不强行杀死也可以,但后续 step 不再执行
- run 标记为 `.cancelled`
- 已生成 artifact 保留
- UI 可选择继续或丢弃

### 9.4 失败恢复

| 失败 | 行为 |
|---|---|
| trending-api 失败 | 提示重试或改用手选 repo |
| repo overview 失败 | 单 repo 标记缺失,整体继续 |
| 聚类失败 | 降级按 language/topics 分组 |
| report 生成失败 | 保留 source snapshot,允许重试当前 step |
| markdown builder 失败 | 不重跑数据源,只重试 artifact step |

---

## 十、存储

### 10.1 复用底层表

复用 `16` 中的:

- `agent_run`
- `agent_run_step`
- `agent_artifact`
- `agent_schedule`

Weekly 不新增独立 run 表。

### 10.2 Weekly 专属 JSON

`agent_artifact.content_json` 保存:

- `WeeklyReportDraft`
- `WeeklyMarkdownArtifactContent`
- `XHSCardsArtifactContent`
- `VideoScriptArtifactContent`
- `WeeklyImagePromptArtifactContent`

`agent_run.context_json` 保存:

```json
{
  "source": "trendingSelection",
  "period": "weekly",
  "language": "all",
  "selectedRepos": [
    {
      "ghRepoId": 123,
      "owner": "owner",
      "name": "repo"
    }
  ],
  "style": "technicalWeekly"
}
```

### 10.3 文件目录

```text
Application Support/Starcat/AgentRuns/{runID}/
  artifacts/
    weekly-report.md
    xhs-cards.json
    video-script.md
    image-prompts.json
```

P0 只导出 Markdown。

---

## 十一、配额与确认

### 11.1 P0 配额

P0 只生成 Markdown:

```text
base run: 1 quota
topic clustering: 1 quota
report generation: 2 quota
artifact revision: 1 quota / 次
```

运行前展示估算:

```text
预计消耗 4 quota。不会生成图片,不会写入文件,除非你点击导出。
```

### 11.2 确认点

P0 需要确认:

- 导出文件
- 保存到 Note
- 创建定时任务

P1/P2 增加:

- 图片生成
- 批量深读超过阈值
- 外部图片 provider 调用

---

## 十二、Prompt 设计

### 12.1 System Prompt 约束

核心要求:

- 你是 Starcat 的 GitHub Weekly Report Agent
- 只基于 tool 提供的事实写作
- 不编造 stars、release、license、维护状态
- 输出中文技术周刊风格
- 每个 repo 必须解释“是什么”和“为什么本周值得关注”
- 不自动执行写入或导出

### 12.2 Style Guide

```swift
enum WeeklyReportStyle: String, Codable {
    case technicalWeekly
    case explainer
    case criticalReview
    case contentPlatform
    case custom
}
```

P0 默认 `technicalWeekly`。

### 12.3 Artifact Revision Prompt

局部修改必须带:

- 原 artifact version
- 目标 section id
- 用户修改要求
- 原 source evidence

不要重新查询数据源,除非用户明确要求“重新拉数据”。

---

## 十三、测试策略

### 13.1 单测

| 测试 | 覆盖 |
|---|---|
| `WeeklyReportRunContextBuilderTests` | 从不同入口冻结上下文 |
| `FetchTrendingReposToolTests` | query 映射、top 截断、错误处理 |
| `FetchWeeklyFeedToolTests` | WeeklyFeedQuery 映射 |
| `ClusterWeeklyTopicsToolTests` | LLM 成功 / 降级分组 |
| `GenerateWeeklyReportToolTests` | schema 解码、缺字段失败 |
| `BuildWeeklyMarkdownArtifactToolTests` | Markdown 结构 |
| `WeeklyReportRevisionTests` | 局部重写生成新 version |

### 13.2 Runtime 集成测试

使用 mock LLM:

1. 第一次返回 tool call: `trending.fetchRepos`
2. 第二次返回 tool call: `repo.getOverview`
3. 第三次返回 `WeeklyReportDraft`
4. Runtime 生成 Markdown artifact

断言:

- step 顺序正确
- artifact 创建成功
- tool 失败可重试
- cancel 后不继续执行

### 13.3 UI 验证

- 直接从 Agent Workspace 运行
- 从 Weekly 多选进入
- 从 Trending 多选进入
- 运行中取消
- Markdown 复制 / 导出
- 深色 / 浅色
- reduce motion

### 13.4 命令

```bash
xcodegen generate
xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' \
  -only-testing:StarcatTests/WeeklyReportRunContextBuilderTests \
  -only-testing:StarcatTests/GitHubWeeklyReportAgentRuntimeTests test
```

跑测前关闭 Xcode IDE。

---

## 十四、实施分期

### Phase 1: Markdown P0

- AgentDefinition
- run context builder
- trending / weekly / selection tools
- repo overview tool
- report draft schema
- markdown artifact builder
- Agent Workspace 中运行和预览
- 复制 / 导出 Markdown

### Phase 2: 多形态文本

- 小红书 9 卡文案
- 视频文案
- HTML content model
- artifact tabs 扩展
- 局部重生成

### Phase 3: 图片 prompt

- image prompt artifact
- prompt 审核 UI
- image provider 设置入口占位

### Phase 4: 图片生成

- `AgentImageClient`
- 图片生成确认点
- 图片 artifact
- 小红书 zip 导出

### Phase 5: 定时运行

- Weekly Agent schedule preset
- 每周自动生成草稿
- 通知与历史
- 基于上期配置复跑

---

## 十五、开放问题

1. P0 是否只支持 `technicalWeekly` 风格,还是同时支持自定义风格输入?
2. P0 最大 repo 数是否固定 30,超过后让用户确认裁剪?
3. `GetRepoOverviewTool` 首版是否读取 README,还是只用已有 card DTO + description?
4. Markdown 导出是否需要同时导出 source snapshot JSON?
5. P1 小红书卡片是否先只做文案,不做真实 PNG?

---

## 十六、变更记录

| 日期 | 变更 | 作者 |
|---|---|---|
| 2026-06-28 | 初稿:GitHub Weekly Report Agent 技术实现方案 | Codex |
