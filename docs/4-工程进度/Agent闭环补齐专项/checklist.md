# Agent 线性多任务基线专项进度

> 状态: 已归档(线性工具编排 v1)
> 创建: 2026-07-07
> 归档: 2026-07-10
> 前置专项: `docs/4-工程进度/Agent底层框架专项/checklist.md` / `docs/4-工程进度/AgentRun持久化专项/checklist.md`
> 后续专项: `docs/4-工程进度/AgentClineLoop专项/checklist.md`
> 边界说明: 本专项只完成固定工具序列下的第二个只读 Agent 和确认请求展示,不代表 LLM tool-calling、审批暂停恢复或消息事实源闭环。

## 1. 目标

把当前 “Agent Framework v1 + GitHub Weekly Report 首个可用 Agent” 推进到可复用的线性多 Agent 基线:

1. Runtime 不再只生成 Weekly 专用 plan / step / artifact 标题。
2. 新增第二个可运行只读 Agent,优先实现 `Repo Insight`。
3. 继续保留所有写操作禁用;后续写 tag / note / status / star 必须单独实现确认流。
4. 历史 run 仍保持只读恢复;resume / retry / schedule 另列后续项。
5. 每个小功能提交一次,不 push。

## 2. 本轮不做范围

- [x] 不自动 star / unstar。
- [x] 不写 tag / note / repo status。
- [x] 不做定时 Agent。
- [x] 不做失败点 resume / 单步 retry。
- [x] 不做真正 LLM tool-calling loop。
- [x] 不新增第二套 AI SDK 或网络搜索配置。
- [x] 不 push。

## 3. 实施 checklist

- [x] 新增 Agent 闭环补齐专项 checklist。
- [x] 修复既有专项文档状态残留。
- [x] 抽象 Agent execution profile,让 plan / step / artifact title 不再硬编码 Weekly。
- [x] 新增 Repo Insight Agent 定义并启用。
- [x] 新增 Repo Insight 只读工具链。
- [x] Runtime 支持 Repo Insight 生成 Markdown artifact。
- [x] 补 AgentDefinition / Tool / Runtime 单测。
- [x] 新增确认请求事件与工作台展示链路。
- [x] 在 `docs/功能实现总览.md` 回填线性 v1 的真实边界。
- [x] 完成文档、代码、测试和进度复核,确认本专项不包含真正 LLM tool-calling loop。
- [x] 将未完成的 Runtime Loop、Approval 和最终交付报告统一转入 Cline-style Agent 全量交付专项。

## 4. 验收标准

- [x] Agent 工作台至少有 Weekly Report 与 Repo Insight 两个可运行 Agent。
- [x] Repo Insight 使用真实 Starcat repo 快照,不显示 demo 数据。
- [x] Repo Insight 每步可展开 input / output / log。
- [x] Artifact 仍按执行顺序出现在底部。
- [x] 缺 AI 配置时明确失败,不生成假 artifact。
- [x] 现有 Weekly Agent 单测继续通过。
- [x] 新增 Repo Insight 单测覆盖成功和缺配置失败路径。
- [x] Runtime / ViewModel 可接收确认型工具请求,但不会自动执行写入。
