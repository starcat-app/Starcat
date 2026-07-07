# Agent Run 持久化专项进度

> 状态: 已完成
> 创建: 2026-07-07
> 目标分支: `feature/agent`
> 前置专项: `docs/4-工程进度/Agent底层框架专项/checklist.md`

## 1. 目标

把 Agent Run 从内存态推进到可复盘的持久化 v1:

1. 新增 Agent run / step / trace / artifact 的本地 SQLite 存储。
2. Runtime 事件写入持久化 store,保证完成、失败、取消的 run 都可复查。
3. Agent 工作台左侧接入真实历史列表,不再依赖假历史。
4. 点击历史 run 可只读查看 prompt、steps、trace、artifact。
5. 单测、主进度、审查报告、验收步骤和结果报告一致。

## 2. 不做范围

- [x] 不做继续执行 / resume。
- [x] 不做单步重试。
- [x] 不做定时 Agent。
- [x] 不做 tag / note / status / star 写入。
- [x] 不 push。

## 3. 实施 checklist

- [x] 新增 Agent Run 持久化专项 checklist。
- [x] 设计 `AgentRunRecord` / `AgentRunStepRecord` / `AgentTraceRecord` / `AgentArtifactRecord`。
- [x] 新增数据库迁移,创建 agent run 相关表与索引。
- [x] 新增 `AgentRunRepository` 协议和 GRDB 实现。
- [x] Runtime 事件写入 `AgentRunRepository`。
- [x] ViewModel 加载真实历史 run 列表。
- [x] 点击历史 run 只读恢复 run 快照。
- [x] UI 清理: 历史列表无数据时显示真实空态。
- [x] 补 Repository 单测。
- [x] 补 ViewModel 历史加载 / 恢复单测。
- [x] 补 Runtime 持久化事件单测。
- [x] 更新 `docs/功能实现总览.md`。
- [x] 新增验收步骤说明。
- [x] 第一轮审查: 文档、checklist、主进度一致性。
- [x] 第二轮审查: 代码、单测、数据库迁移一致性。
- [x] 第三轮审查: UI 行为、验收步骤、结果报告一致性。
- [x] 根据审查发现修复问题,每个修复点单独提交。
- [x] 新增结果报告。

## 4. 验收标准

- [x] 运行 Agent 后,run / step / trace / artifact 写入本地数据库。
- [x] 重新打开 Agent 工作台后,左侧历史列表显示真实 run。
- [x] 点击历史 run 后,中栏和右栏恢复该 run 的只读快照。
- [x] 新 run 不会覆盖历史 run。
- [x] 失败或取消的 run 也可在历史中查看。
- [x] 单测覆盖迁移、Repository、Runtime 写入和 ViewModel 恢复。
- [x] `docs/功能实现总览.md`、专项 checklist、审查报告、结果报告状态一致。

## 5. 提交要求

- [x] 每完成一个小功能 commit 一次。
- [x] commit message 使用中文。
- [x] 不 push。
- [x] 不提交无关工作区改动。
