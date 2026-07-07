# Agent 底层框架专项进度

> 状态: 已实现,审查中
> 创建: 2026-07-07
> 目标分支: `feature/agent`
> 前置专项: `docs/4-工程进度/Agent平台专项/checklist.md`
> 当前问题: 现有 Agent 已有 Weekly 可运行闭环,但 Runtime、Tool、网络搜索、审计与 UI 仍未形成可交付的通用底层框架。

## 1. 目标

把 Agent 从 `GitHub Weekly Report` 专用流程推进到可交付的 Agent Framework v1:

1. 建立通用 Agent Tool 协议和 Tool Registry,让 Agent 通过 tool id 执行能力,不再在 Runtime 中硬编码 Weekly 专用流程。
2. Runtime 按统一事件流执行 plan / tool / LLM / artifact,每一步都可审计 input / output / log / status。
3. 网络搜索工具必须复用项目现有 External Search 体系,包括设置页 provider、API key、匿名模式、聚合搜索、缓存和私有仓库隐私边界。
4. `GitHub Weekly Report Agent` 迁移为框架上的首个 Agent,而不是独立 demo。
5. UI 不展示假数据、假按钮、假 tab;中栏只展示真实执行过程,右栏只展示真实 artifact。
6. 单测、文档、工程进度、审查报告和结果报告全部一致。

## 2. 不做范围

- [x] 不自动 star / unstar。
- [x] 不写 tag / note / repo status。
- [x] 不新增第二套网络搜索设置或第二套 provider 抽象。
- [x] 不绕过设置页直接读取网络搜索 API key。
- [x] 不做图片、小红书、视频 artifact。
- [x] 不做开放式 autonomous coding agent。
- [x] 不 push。

## 3. 架构硬约束

- [x] Agent 网络搜索工具必须复用 `ExternalSearchRegistry` / `ExternalSearchProvider` / `ExternalSearchContextProvider`。
- [x] Agent 网络搜索必须读取 `AppSettings` 中现有 External Search 配置:
  - `externalContextEnabled`
  - `externalContextProviderSelection`
  - `aggregateExternalContextSearchEnabled`
  - `externalSearchProviderSettings`
  - provider API key / anonymous mode / verified state
  - `externalSearchAllowPrivateRepos`
- [x] 网络搜索关闭时,Agent tool 返回 `skipped` trace,不得失败或伪造结果。
- [x] Provider 失败时,Agent tool 返回 failed/degraded trace,Weekly Agent 可基于本地上下文继续降级生成。
- [x] 所有网络搜索 query、provider、source URL、cache 状态必须进入中栏 trace。
- [x] 给 LLM 的网络搜索输出必须预算受控,不得把网页全文无上限塞进 prompt。

## 4. 实施 checklist

- [x] 新增 Agent 底层框架专项 checklist。
- [x] 定义 `AgentTool` / `AgentToolInput` / `AgentToolResult` / `AgentToolPermission`。
- [x] 定义 tool status,支持 `completed` / `skipped` / `failed` / `requiresConfirmation`。
- [x] 新增 `AgentToolRegistry`,支持按 `AgentDefinition.toolIDs` 查找工具。
- [x] 扩展 `AgentDefinition`,让每个 Agent 声明 tool id、artifact types 和执行策略。
- [x] 把 Weekly 本地工具迁移为 Agent tool:
  - `agent.parseGoal`
  - `context.resolveRepos`
  - `report.clusterTopics`
  - `artifact.buildMarkdown`
- [x] 重构 `DefaultAgentRuntime`,按 tool registry 和执行计划驱动工具,不再硬编码静态工具数组。
- [x] 新增 Agent 网络搜索工具 `external.search`,复用现有 External Search provider 栈。
- [x] 为 `external.search` 输出 `AgentToolOutput` 与 `AgentTraceSpan`,包含 query、provider、结果数、source URL、错误和 cache 状态。
- [x] Weekly Agent 接入 `external.search`:
  1. parse goal
  2. resolve local repos
  3. external.search 补充外部来源
  4. cluster topics
  5. build markdown draft
  6. LLM generate
  7. artifact create
- [x] 外部搜索关闭时,Weekly Agent 明确记录 skipped trace 并继续本地生成。
- [x] 外部搜索 provider 失败时,Weekly Agent 明确记录 failed/degraded trace 并继续本地生成。
- [x] Artifact 生成必须处于执行顺序底部,结果不得显示在工具过程之前。
- [x] 中栏只展示真实 run 数据,不得出现默认 demo prompt / 默认 plan / 默认 tool / 默认 artifact。
- [x] 右栏只展示真实 artifact,不得展示 Agent 专用硬编码卡片或不可点击占位操作。
- [x] 补 Tool Registry 单测。
- [x] 补 Weekly tool 迁移单测。
- [x] 补 `external.search` Agent tool 单测,使用 stub provider。
- [x] 补 Runtime 执行顺序单测,确认网络搜索在聚类前、artifact 在最后。
- [x] 补外部搜索关闭 skipped 单测。
- [x] 补 provider 失败降级单测。
- [x] 更新 `docs/功能实现总览.md` Agent 底层框架条目与变更日志。
- [ ] 第一轮审查: 文档、checklist、主进度索引一致性。
- [ ] 第二轮审查: 代码架构与 `16-Agent底层平台技术方案.md` 一致性。
- [ ] 第三轮审查: 单测、验收步骤与工程进度一致性。
- [ ] 根据审查发现修复问题,每个修复点单独提交。
- [ ] 新增 Agent 底层框架专项结果报告。

## 5. 验收标准

- [x] Agent Runtime 不再依赖 Weekly 专用静态工具流程。
- [x] Weekly Agent 是通过 Tool Registry 执行的首个 Agent。
- [x] 网络搜索工具复用现有 External Search 设置页配置,没有第二套 API key / provider 设置。
- [x] 关闭 External Search 时,Agent trace 显示 skipped,并可继续本地生成。
- [x] Provider 失败时,Agent trace 显示 failed/degraded,并保留本地上下文输出。
- [x] 每个 tool 调用都能在中栏展开看到 input / output / log。
- [x] Artifact 始终在执行顺序底部生成。
- [x] 右侧 Artifact Inspector 只展示真实产出物。
- [x] 单测覆盖工具注册、网络搜索适配、执行顺序和降级策略。
- [ ] `docs/功能实现总览.md`、专项 checklist、审查报告、结果报告状态一致。

## 6. 提交要求

- [ ] 每完成一个小功能 commit 一次。
- [ ] commit message 使用中文。
- [ ] 不 push。
- [ ] 不提交无关工作区改动。
