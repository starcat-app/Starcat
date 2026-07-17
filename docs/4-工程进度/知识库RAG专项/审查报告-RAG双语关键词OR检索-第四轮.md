# RAG 双语关键词 OR 检索第四轮审查报告

> 审查日期：2026-07-17
> 审查范围：旧会话兼容证据、提交完整性、受保护文档与收口条件
> 审查基线：`099f7cd`
> 结论：实现与工程门禁无新缺陷；发现 1 项兼容测试证据缺口，先记录后补齐

## 1. 已核验证据

- 21 个任务提交均为中文 message，方案、功能、测试、审查报告和修复分离。
- 变更文件不包含 `docs/功能实现总览.md`，总览只在第三轮报告中提供待确认草稿。
- 全量测试与双 Debug target build 已通过，xcstrings、i18n 与 whitespace 静态检查通过。
- Git diff 不包含 `.tertiary` 或新的 plain button，UI 改动未破坏颜色/Focus Ring 契约。
- Checklist 仅剩最终无问题审查、结果报告、未 push 与 clean worktree 等收口项。

## 2. 发现的问题

### R4-1：旧 Snapshot / Diagnostics 缺少新增字段的解码没有直接测试

严重度：P2

现有兼容测试已覆盖旧 `RAGQueryPlan` 缺少 `keywordQueries`、旧
`RAGRetrievalTrace` 缺少 `keywordQuery`，以及整个旧 `RAGExecutionStep` 没有 Snapshot 的路径；
但没有直接构造“存在旧 Snapshot/Diagnostics、仅缺少本次新增 failure/query 字段”的 JSON。
Swift optional 合成解码理论上可行，仍不足以支撑 Checklist 中“历史会话与 Debug JSON 缺少
新增字段时仍可恢复”的完成结论。

修复要求：新增编码后移除新增 key 的旧 JSON 回归，直接解码
`RAGRetrievalSnapshot` 与 `RAGRetrievalDiagnostics`，断言 failure/query 为 nil 且原有计数不变。

## 3. 本轮未发现的问题

- 未发现新的功能缺口、scope 越界、查询注入或双路降级错误。
- 未发现文档仍把普通搜索写成 OR，或把 RAG 关键词写成 AND。
- 未发现工程进度把真实中英混合质量评测误标为完成。
- 未发现新增 migration、发布脚本执行、push 或外部写入。

## 4. 修复后门禁

- 新增旧 Snapshot / Diagnostics JSON 兼容测试并运行 `KnowledgeRAGCoreTests`。
- 再跑 `git diff --check` 与工作树状态检查。
- 增加最终无问题审查报告；只有该轮无遗留后才生成结果报告并全部勾选 Checklist。
