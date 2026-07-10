# Cline-style Agent 全量交付 checklist 复审报告

> 日期: 2026-07-10
> 审查轮次: checklist 第 2 轮
> 审查范围: Cline 参考分析、当前 Agent 代码、旧专项状态、功能总览和重构后的全量交付 checklist
> 审查目标: 验证 checklist 能否支撑一次性完成全部 Agent 需求,而不是再次停留在线性工具编排或 UI 演示阶段。

## 1. 审查结论

通过,可以作为本次 Agent 全量交付的唯一主 checklist。

第一轮报告只验证了模块名称是否覆盖,没有深入到运行会话控制、统一顺序、流式 tool-call 聚合、硬预算和事务一致性。第二轮已把这些实现级阻断项补入清单,并明确新 Runtime 完成后直接删除旧线性路径。

## 2. 当前代码事实

| 审查点 | 当前事实 | checklist 对应位置 |
| --- | --- | --- |
| Runtime | 按 `AgentDefinition.toolIDs` 固定顺序执行,最后单次调用 LLM | §5.6 / §6 |
| AI Client | 请求不带 tools,响应不表达 tool-call;tool-call-only 会被视为空响应 | §5.5 |
| Tool | 只有 id/displayName/permission,没有模型 schema 和参数校验 | §5.4 |
| Approval | 只有事件与展示,没有暂停、批准、拒绝、恢复 | §5.8 |
| Persistence | 保存 step/trace/tool output/artifact 投影,没有 messages 事实源 | §5.3 / §5.7 |
| External Search | 复用现有 provider,但固定处理前 3 个 repo,不是模型参数驱动 | §5.9 |
| Workspace | 可展开 trace,但不是 user/assistant/tool message timeline | §5.10 |
| 占位行为 | Runtime 有演示延迟,附件按钮为空 action | §5.6 / §5.10 |

## 3. 第二轮新增的关键约束

1. 新增稳定 runID 和 `AgentRunSession` actor/命令通道,避免 Approval 与 AsyncStream 生命周期脱节。
2. 新增全局单调 `sequence`,保证 messages、tool results、approval 和 artifact 在实时 UI 与历史恢复中顺序一致。
3. 新增流式 tool-call accumulator,按 choice/index/callID 聚合 name 和 JSON arguments delta。
4. 新增 provider tool-calling 能力检测,不支持时明确失败,禁止静默回退旧 Runtime。
5. 新增 max iterations、tool calls、tokens、duration、context 和单工具 timeout 硬预算。
6. 新增 Tool timeout/retryPolicy,并限制只有无副作用工具可以自动重试。
7. 新增 message/approval/run 状态事务一致性要求,避免 App 重启后出现已执行但未记录或已批准但未执行。
8. 新增直接删除旧线性路径和旧投影事实表的要求,符合项目未上线、不做兼容迁移的约束。
9. 新增空附件按钮、演示延迟、固定 step kind 猜测等占位清理要求。
10. 新增至少六轮实现后审查,每轮先写报告再修复。

## 4. Cline 对照复核

| Cline / Starcat 能力 | 覆盖位置 | 结论 |
| --- | --- | --- |
| Prompt environment、mode、rules、tool visibility | §5.2 | 已覆盖 |
| messages 是事实源 | §3 / §5.3 / §5.7 | 已覆盖 |
| 模型可见 tool schema | §5.4 | 已覆盖 |
| tool-call delta 和多调用解析 | §5.5 | 已覆盖 |
| model -> tool -> result -> model loop | §5.6 | 已覆盖 |
| cancel/approval command channel | §5.6 / §5.8 | 已覆盖 |
| token/context/iteration/time budget | §3 / §5.2 / §5.6 | 已覆盖 |
| External Search 复用现有产品能力 | §5.9 | 已覆盖 |
| message timeline 与通用 Inspector | §5.10 | 已覆盖 |
| persistence/recovery/audit | §5.7 | 已覆盖 |
| 测试、验收、多轮审查和结果报告 | §5.12 / §5.13 | 已覆盖 |

## 5. 边界检查

- 没有引入 shell、文件编辑、apply_patch 或通用 Coding Agent 能力。
- 没有新增 AI Provider 或 External Search 配置体系。
- 没有允许未确认写入。
- 没有保留旧 Runtime 兼容层。
- 没有把分批开发误写成分批交付。
- 没有把测试、文档和最终报告留作专项外 TODO。

## 6. 风险与实施要求

1. AI Adapter、Loop Runtime 和 Persistence 互相依赖,但仍需按 checklist 小步提交,每个提交保持可编译或有明确的测试边界。
2. Approval 必须由 Runtime session 持有 continuation/command state,不能由 ViewModel 重新发起一次 run。
3. OpenAI-compatible provider 的流式 tool-call 格式可能有差异,解析器必须使用 SDK 已暴露结构并用 fixture 覆盖缺字段情况。
4. External Search 工具结果可能较大,必须在进入下一轮模型前经过预算器,完整来源保存在持久化记录或 artifact。
5. 只有全部最终验收项、审查修复和结果报告完成后,才能把专项状态改为完成。

## 7. 回填结果

- 主 checklist 已升级为全量交付口径。
- 旧“Agent 闭环补齐专项”已归档为线性多任务基线。
- `docs/功能实现总览.md` 已新增进行中的 Cline-style Agent 全量交付条目。
- 本轮未发现需要继续补入 checklist 的关键功能面。
