# Agent 闭环补齐专项进度

> 状态: 进行中
> 创建: 2026-07-07
> 目标分支: `feature/agent`
> 前置专项: `docs/4-工程进度/Agent底层框架专项/checklist.md` / `docs/4-工程进度/AgentRun持久化专项/checklist.md`

## 1. 目标

把当前 “Agent Framework v1 + GitHub Weekly Report 首个可用 Agent” 继续推进到可交付的多 Agent 闭环:

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
- [ ] 新增 Repo Insight Agent 定义并启用。
- [ ] 新增 Repo Insight 只读工具链。
- [ ] Runtime 支持 Repo Insight 生成 Markdown artifact。
- [ ] 补 AgentDefinition / Tool / Runtime 单测。
- [ ] 更新 `docs/功能实现总览.md`。
- [ ] 第一轮审查: 文档、代码、测试、进度一致性。
- [ ] 根据审查结果修复。
- [ ] 新增结果报告。

## 4. 验收标准

- [ ] Agent 工作台至少有 Weekly Report 与 Repo Insight 两个可运行 Agent。
- [ ] Repo Insight 使用真实 Starcat repo 快照,不显示 demo 数据。
- [ ] Repo Insight 每步可展开 input / output / log。
- [ ] Artifact 仍按执行顺序出现在底部。
- [ ] 缺 AI 配置时明确失败,不生成假 artifact。
- [ ] 现有 Weekly Agent 单测继续通过。
- [ ] 新增 Repo Insight 单测覆盖成功和缺配置失败路径。
