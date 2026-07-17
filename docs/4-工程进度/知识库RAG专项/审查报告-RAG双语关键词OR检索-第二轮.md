# RAG 双语关键词 OR 检索第二轮审查报告

> 审查日期：2026-07-17
> 审查范围：Retriever 独立降级、Plan/漏斗/Debug 真实值、历史回放与隐私边界
> 审查基线：`1d8c2ed`
> 结论：发现 3 项需要修复的问题，先记录本报告，再进入修复提交
> 修复回填：3 项均已修复，相关定向测试通过

## 1. 已核验证据

- `KnowledgeRAGService` 已把 Planner 的 `keywordQueries` 传给 Retriever，Vector/Rerank 仍用
  `semanticQuery`。
- Keyword 与 Vector 通过 `async let` 并行执行；单路失败不会立即取消另一分支。
- Query Trace 保存有界 terms 与安全 FTS5 表达式，不保存 chunk 正文。
- Snapshot 保存候选、两路计数、融合、重排和最终证据数量，历史 JSON 缺少新增 optional
  字段时可解码。
- Plan 展示 Planner 关键词；旧自定义 Prompt 缺少字段时回退到实际 Query Trace。

## 2. 发现的问题

### R2-1：无候选与无就绪索引被误显示为 0 命中

严重度：P1

`RAGRetrievalBranchStatus.resolve` 只把 `sourcesDisabled` 和 `skippedStructured` 映射为
`skipped`。当 outcome 为 `noCandidates` 或 `noReadyChunks` 时，Retriever 同样没有执行
Keyword/Vector，但 Plan 仍显示“召回 0 → 保留 0”，与真实执行状态不符，也会复现用户最初
看到的歧义。

修复要求：`noCandidates`、`noReadyChunks` 一并显示“已跳过”；只有实际运行后零命中才显示
0 → 0，并补四类未执行 outcome 的直接测试。

### R2-2：历史快照持久化了原始 provider 错误字符串

严重度：P1

`RAGRetrievalSnapshot` 当前把 `localizedDescription` 原样写入 `execution_trace_json`。自托管
后端错误可能包含内网 endpoint、路径或系统描述，超出了“历史只保存安全摘要”的边界。
当前轮 Debug 可以保留完整错误用于排障，但长期会话不应复制原始外部错误。

修复要求：历史 Snapshot 只保存稳定、可本地化的 failure code；Plan 显示通用安全摘要。
完整错误继续仅存在当前轮 `RAGRetrievalDiagnostics` / Debug，不进入会话历史。

### R2-3：独立降级测试只覆盖 Vector 失败方向

严重度：P2

现有 `embeddingFailureKeepsKeywordResults` 证明 Vector 失败时保留 Keyword，但没有反向证明
Keyword 失败时 Vector 命中仍能进入最终证据，也没有断言对应的分支 failure 状态。

修复要求：新增 Keyword provider 失败 + Vector 有效命中的 Retriever 测试，并断言命中类型、
诊断错误和历史安全 failure code。

## 3. 本轮未发现的问题

- 未发现 Keyword/Vector 串行化回归。
- 未发现 Rerank 改用关键词查询；仍使用 `semanticQuery`。
- 未发现漏斗计数从 UI 推测或重新计算；均来自执行 Snapshot。
- 未发现 Query Trace、Snapshot 或 Debug 新增分片正文副本。
- 未发现旧会话新增字段缺失导致的解码失败。

## 4. 修复后复核门禁

- `noCandidates`、`noReadyChunks`、`sourcesDisabled`、`skippedStructured` 均显示 skipped。
- `noEvidence + 0 hits` 保持 completed(0, 0)。
- 历史 JSON 不含原始 provider 错误字符串，只含安全 failure code。
- Keyword 失败时 Vector 证据仍可进入最终结果。
- 重跑 `KnowledgeRAGCoreTests`、`RAGLocalizationTests` 与历史持久化相关测试。

## 5. 修复回填

| 问题 | 修复证据 | 状态 |
|---|---|---|
| R2-1 | `d915baf` 将 `noCandidates`、`noReadyChunks` 与其它未执行 outcome 统一映射为 skipped | 已关闭 |
| R2-2 | `72ee0de` 以 `RAGRetrievalBranchFailure.providerError` 替代历史原始错误字符串，并补 JSON 反向断言 | 已关闭 |
| R2-3 | `89dfb9f` 增加 Keyword 失败、Vector 命中仍保留的 Retriever 回归测试 | 已关闭 |

修复后 `KnowledgeRAGCoreTests` 多次通过，包含历史 Snapshot、漏斗状态和双向独立降级；
`RAGLocalizationTests` 与 catalog JSON 校验通过。历史编码断言确认不再包含测试用原始 provider
错误字符串，只包含稳定的 `provider_error` code。
