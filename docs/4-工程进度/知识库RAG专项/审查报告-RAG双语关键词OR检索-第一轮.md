# RAG 双语关键词 OR 检索第一轮审查报告

> 审查日期：2026-07-17
> 审查范围：Query Plan 协议、Planner 兼容升级、FTS5 查询安全、repo scope 与基础测试
> 审查基线：`531764b6`
> 结论：发现 4 项需要修复的问题，先记录本报告，再进入修复提交

## 1. 已核验证据

- `RAGQueryPlan.keywordQueries` 使用缺省解码，旧 JSON 可恢复为 `[]`。
- 官方默认 Planner Prompt 通过“只升级上一版官方默认值”迁移，自定义 Prompt 不覆盖。
- `semanticQuery` 只进入 embedding/vector/Rerank，`keywordQueries` 只进入 keyword provider。
- 普通搜索仍使用 `FTSQuery.sanitize` 的 AND；RAG 通过独立构造器生成安全 OR。
- repo scope 仍在候选层和 provider 的 `repoIDs` 参数中强制执行，关键词不能扩大范围。
- `build-for-testing` 与 RAG 定向 Suite 命令退出码为 0；测试宿主仅出现既有系统服务日志。

## 2. 发现的问题

### R1-1：空关键词查询缺少 Provider 短路

严重度：P1

`RAGKeywordQueryBuilder` 在关键词和语义降级词都被过滤后会生成空表达式，但 SQLite、
Meilisearch 和 fallback provider 入口没有统一 `terms.isEmpty` 守卫。SQLite 可能收到空
`MATCH`，外部后端也可能把空 query 解释为全量匹配；这与“无高信息关键词即零命中”的边界
不一致。

修复要求：在所有 keyword provider 的共同协议边界短路为空结果，并补 SQLite 与 fallback
回归测试，确保不会访问下游 provider。

### R1-2：显式 repo scope 的回归测试不完整

严重度：P2

现有测试覆盖单仓库 `.only` 候选收窄和公私仓库 provider 分流，但没有同时覆盖多仓库
`.only`、`.prefer` 与 `.exclude` 在新 OR 查询协议下的 repo id 集合。代码路径未发现越界，
但本次契约变更缺少足够门禁。

修复要求：补充候选层与 Retriever provider 录制测试，证明关键词内容和 repo 名均不能改变
单仓库、多仓库、prefer、exclude 的确定范围。

### R1-3：漏斗三态只有实现，没有直接 read-model 测试

严重度：P2

`localizedRetrievalBranch` 已区分正常 0 命中、失败和跳过，但当前测试只覆盖历史快照字段，
没有直接断言三种展示值。Checklist 已把 Inspector read model 测试标为完成，证据不足。

修复要求：把三态映射收敛为可独立测试的纯值读模型，覆盖 0、失败、`sourcesDisabled` 与
`skippedStructured`。

### R1-4：文档把 Trace 与 Snapshot 的职责写混

严重度：P2

实际实现由 `RAGRetrievalTrace.keywordQuery` 保存最终 FTS5 表达式，由
`RAGRetrievalSnapshot` 保存 keyword/vector 分支错误；方案与 Checklist 中“Trace 保存表达式
和两路分支状态”的写法会让维护者误以为错误字段也在 Trace 内。

修复要求：文档改为“Trace 保存安全查询，Snapshot 保存分支状态”，不调整当前隐私边界。

## 3. 本轮未发现的问题

- 未发现 schema 修改、v7 回写或要求删库重建。
- 未发现 repo 名被自动加入执行层 FTS5 查询。
- 未发现 FTS5 操作符注入路径；每项均按双引号字面转义。
- 未发现单路 provider 失败会抹掉另一分支有效命中的回归。
- 未发现新增固定文案缺少 en / zh-Hans。

## 4. 修复后复核门禁

- 空 terms 不调用 SQLite、Meilisearch 或 fallback 下游。
- 单仓库、多仓库、prefer、exclude 的实际 provider repo ids 有直接断言。
- 漏斗 0 / failed / skipped 三态有纯值测试。
- 方案、正式设计、Checklist 与代码中的 Trace/Snapshot 职责一致。
- 重跑 `FTSQueryTests`、`KnowledgeRAGCoreTests`、`RAGChunkRepositoryTests` 和
  `RAGLocalizationTests`。
