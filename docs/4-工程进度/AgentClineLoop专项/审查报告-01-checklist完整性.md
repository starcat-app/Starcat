# Cline-style Agent Loop 专项 checklist 完整性审查

> 日期: 2026-07-07
> 审查范围: `checklist.md` 与 `docs/4-工程进度/AgentCline参考实现专项/Cline-Agent实现分析与Starcat落地方案.md`
> 审查目的: 创建 checklist 后立即验证是否遗漏 Cline runtime loop、VS Code prompt pipeline 和 Starcat 落地关键工作。

## 1. 审查结论

通过。

当前 checklist 已覆盖本专项第一版可交付所需的主要工作面:

1. Prompt Pipeline
2. Message Contract
3. Tool Schema
4. LLM Tool Call Adapter
5. Loop Runtime
6. Approval 闭环
7. GitHub Weekly Report 迁移
8. UI Timeline 与 Inspector
9. 文档、单测、工程进度、审查报告和结果报告

未发现需要立即补入 checklist 的关键遗漏。

## 2. 覆盖性对照

| Cline / Starcat 关键点 | checklist 覆盖位置 | 结论 |
| --- | --- | --- |
| Cline-style `model -> tool-call -> tool-result -> model` loop | §4.6 Loop Runtime | 已覆盖 |
| VS Code 层 Prompt Pipeline | §4.2 Prompt Pipeline | 已覆盖 |
| Plan / Act 类 mode guardrails | §4.2 Prompt Pipeline | 已覆盖 |
| `switch_to_act_mode` 对 Starcat 确认写入的启发 | §4.7 Approval 闭环 | 已覆盖 |
| messages 作为可回放事实源 | §4.3 Message Contract | 已覆盖 |
| tool schema: name / description / inputSchema / permission / completesRun | §4.4 Tool Schema | 已覆盖 |
| OpenAI-compatible tool call adapter | §4.5 LLM Tool Call Adapter | 已覆盖 |
| External Search 复用现有设置和 provider | §3 架构硬约束 / §4.8 Weekly 迁移 | 已覆盖 |
| External Search disabled / failed 降级 | §3 架构硬约束 / §4.8 Weekly 迁移 | 已覆盖 |
| 写入必须确认,拒绝回灌 error tool-result | §3 架构硬约束 / §4.7 Approval 闭环 | 已覆盖 |
| GitHub Weekly Report 首条迁移路径 | §4.8 GitHub Weekly Report 迁移 | 已覆盖 |
| Artifact 按执行顺序位于底部 | §3 架构硬约束 / §4.8 / §4.9 | 已覆盖 |
| UI 每步输入输出可审计 | §4.9 UI Timeline 与 Inspector | 已覆盖 |
| 不做通用 Coding Agent 和高权限工具 | §2 不做范围 | 已覆盖 |
| 最终多轮审查与结果报告 | §4.10 文档、审查与结果报告 | 已覆盖 |

## 3. 风险提示

1. 本专项跨度较大,后续实现时需要严格按 checklist 小步提交,不能把 Prompt Pipeline、Tool Schema 和 Runtime Loop 混成一个大提交。
2. `docs/功能实现总览.md` 尚未在本轮更新,但 checklist 已把它列为后续实施项;这符合本轮只创建并验证 checklist 的边界。
3. 旧专项中“闭环”表述修正尚未执行,已列入 §4.1 后续项。

## 4. 回填结果

- `checklist.md` 中“新增 Cline-style Agent Loop 专项 checklist”已回填为完成。
- `checklist.md` 中“对照 Cline 分析文档完成 checklist 覆盖性审查”已回填为完成。

