# Agent 平台专项进度

> 状态: 实施完成, 审查中
> 创建: 2026-07-06
> 需求讨论: `docs/2-产品/需求讨论/agent/00-概览-Agent方向讨论与方案.md`
> 底层方案: `docs/2-产品/需求讨论/agent/16-Agent底层平台技术方案.md`
> 首个 Agent: `docs/2-产品/需求讨论/agent/17-GitHubWeeklyReportAgent技术实现方案.md`

## 1. 目标

在现有 Agent Workspace P0 基础上补齐一个可审查、可测试、可继续演进的最小 Agent 平台闭环:

1. 明确当前仍是 deterministic runtime,不伪装成完整 tool-calling Agent。
2. Runtime 事件流包含计划、工具输出、Artifact 与运行日志。
3. GitHub Weekly Report Agent 能展示可追溯的执行步骤和 Markdown 产出。
4. 单测锁住事件顺序、Artifact 内容、取消行为与 ViewModel 状态转换。
5. 文档、进度索引、专项 checklist、审查报告和结果报告保持一致。

## 2. 不做范围

- [x] 不接入 macOS 26-only 的 Foundation Models / Swarm 默认路径。
- [x] 不自动 star / unstar / 写 tag / 写 note / 修改 repo 状态。
- [x] 不新增外部服务端或 Python / JS Agent runtime。
- [x] 不把 RAG 工作台合并进 Agent Workspace。
- [x] 不把当前 deterministic runtime 宣称为真实 LLM tool-calling runtime。

## 3. 实施 checklist

- [x] 新增 Agent 平台专项目录与 checklist。
- [x] 扩展 Agent 共享模型,支持 plan / tool output / run log。
- [x] 扩展 DefaultAgentRuntime,输出可审计的 Weekly Agent 执行闭环。
- [x] 补 AgentRuntime 单测,覆盖事件流、artifact、run log 与取消。
- [x] 补 AgentWorkspaceViewModel 单测,覆盖 run / cancel / artifact 状态转换。
- [x] Agent Workspace UI 展示计划、工具输出和运行日志 artifact。
- [x] 更新 `docs/功能实现总览.md` 的 Agent 高级功能条目与变更日志。
- [ ] 第一轮审查: 文档与 checklist 一致性。
- [ ] 第二轮审查: 代码实现与设计方案一致性。
- [ ] 第三轮审查: 单元测试与工程进度一致性。
- [ ] 根据审查发现完成修复并补充提交。
- [ ] 新增 Agent 平台专项结果报告。

## 4. 验收标准

- [x] `StarcatTests/AgentRuntimeTests.swift` 覆盖新增 runtime 契约。
- [x] Agent Workspace 可以从事件流展示 plan、step、tool output、artifact。
- [x] Markdown artifact 明确标注当前数据来源和 deterministic runtime 边界。
- [x] `docs/功能实现总览.md` checkbox 与本 checklist 状态一致。
- [ ] 每轮审查报告落在 `docs/4-工程进度/Agent平台专项/`。
- [ ] 最终结果报告落在 `docs/4-工程进度/Agent平台专项/结果报告.md`。
