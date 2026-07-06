# Agent 可用版本专项进度

> 状态: 进行中
> 创建: 2026-07-07
> 需求讨论: `docs/2-产品/需求讨论/agent/16-Agent底层平台技术方案.md`
> 首个 Agent: `docs/2-产品/需求讨论/agent/17-GitHubWeeklyReportAgent技术实现方案.md`
> 前置专项: `docs/4-工程进度/Agent平台专项/checklist.md`

## 1. 目标

把 Agent Workspace 从 deterministic demo 推进到可用的 `GitHub Weekly Report Agent` 首版:

1. Run 使用 Starcat 当前真实仓库数据快照,不再伪造固定 repo 数量。
2. Runtime 输出真实可审计 trace,每一步包含 input / output / summary / log。
3. 首个 Agent 通过 read-only tools 生成 Markdown 周刊 artifact。
4. 配置了 AI Provider 时调用现有 AI Chat 能力生成正文;未配置时明确失败并提示配置,不生成假内容。
5. 所有写操作保持禁用,后续写 tag / note / status 必须另走确认策略。
6. 文档、测试、主进度索引、专项 checklist、审查报告和结果报告一致。

## 2. 不做范围

- [x] 不自动 star / unstar / 写 tag / 写 note / 修改 repo 状态。
- [x] 不自动发布到外部平台。
- [x] 不接图片生成、视频生成或小红书卡片真实渲染。
- [x] 不新增外部服务端或第二套 AI SDK。
- [x] 不把 deterministic sample 当成可用 Agent 输出。

## 3. 实施 checklist

- [x] 新增 Agent 可用版本专项目录与 checklist。
- [x] 扩展 Agent run / trace 模型,让事件流携带真实 input / output / log。
- [x] 构建真实 `AgentRunContext`,从 Starcat 仓库数据生成快照。
- [x] 实现 read-only Weekly Agent tools: 解析目标、读取候选 repo、构建上下文、聚类主题、生成 artifact。
- [x] Runtime 复用现有 AI Provider / Keychain / OpenAIClient 生成真实 Markdown。
- [x] 未配置 AI Provider 时输出明确错误状态,不生成假内容。
- [x] Agent Workspace UI 使用真实 trace 数据展示每一步可展开输入输出。
- [x] 补 context / tools / runtime / ViewModel 单元测试。
- [x] 更新 `docs/功能实现总览.md` 的 Agent 可用版本条目与变更日志。
- [x] 第一轮审查: 文档与 checklist 一致性。
- [x] 第二轮审查: 代码实现与设计方案一致性。
- [x] 第三轮审查: 单元测试与工程进度一致性。
- [x] 根据审查发现完成修复并补充提交。
- [x] 新增 Agent 可用版本专项结果报告。

## 4. 验收标准

- [x] Agent Workspace 运行 Weekly Agent 时读取真实 Starcat repo 数据。
- [x] 每个 step / tool / AI response 都能展开看到输入与输出。
- [x] AI 配置完整时生成真实 Markdown 周刊 artifact。
- [x] AI 未配置时不会落入 sample 文案,而是给出可理解错误。
- [x] 单测覆盖新增 runtime 契约和失败路径。
- [x] `docs/功能实现总览.md` checkbox 与本 checklist 状态一致。
- [x] 每轮审查报告落在 `docs/4-工程进度/Agent可用版本专项/`。
- [x] 最终结果报告落在 `docs/4-工程进度/Agent可用版本专项/结果报告.md`。
