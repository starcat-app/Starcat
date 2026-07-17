# RAG 双语关键词 OR 检索结果报告

> 完成日期：2026-07-17
> 分支：`codex/rag-bilingual-keyword-or`
> 基线：`dev@eeaffc49`
> 状态：已完成；未 push

## 1. 最终结果

本次改造已完整实现：RAG 不再把面向 embedding 的完整自然语言直接按普通搜索 AND 交给
FTS5。Planner 现在分别产出 `semanticQuery` 与双语 `keywordQueries`；关键词经本地校验、
限长和安全转义后以 OR 召回，向量与 Rerank 继续使用语义查询。

选择一个或多个 repo 时，项目名不会加入分词。单仓库、多仓库、`.prefer`、`.exclude` 均由
确定的 repo id scope 强制执行：选择 repo 只限制检索范围，不会关闭分片召回，也不会要求
repo 名出现在 README/笔记/摘要分片中。

检索漏斗的含义已经明确：

- `召回 0 → 保留 0`：分支实际执行成功，但没有匹配分片；
- `执行失败 · 检索服务不可用`：该分支 provider 失败，另一分支仍可独立降级；
- `已跳过`：结构化问题、无候选、无就绪索引或来源全部关闭，分支没有执行。

## 2. 实现清单

| 领域 | 完成内容 |
|---|---|
| Query Plan | 新增兼容 `keywordQueries`；默认 Prompt 目标 3～8 个中英文高信息词 |
| 本地校验 | trim、忽略大小写去重、低信息词过滤、repo identity 排除、80 字符/8 项上限 |
| FTS5 | 新增 RAG 专用安全 OR 构造；普通 `FTSQuery.sanitize` AND 保持不变 |
| Provider | SQLite/Meilisearch/fallback 共用 typed query；空 terms 统一零命中短路 |
| Retriever | Service 透传双查询；Keyword/Vector 并行且双向独立降级；Rerank 继续用语义查询 |
| Scope | 单/多 repo `.only`、`.prefer`、`.exclude` 继续由候选 id 和 provider repo ids 约束 |
| Inspector | 展示优化问题、实际关键词、查询轨迹与 0/failed/skipped 三态漏斗 |
| 历史/Debug | Trace 保存安全查询；Snapshot 只保存 failure code；原始错误和 chunk 正文不进历史 |
| 构建 | Direct Debug 在干净 worktree 缺独立 changelog 时回退根资源，Release 仍严格阻断 |

## 3. 自动化证据

| 验证 | 结果 |
|---|---|
| Query Plan / Planner / Prompt migration | 通过 |
| FTS5 OR / 转义 / 空查询 / SQLite 集成 | 通过 |
| 单仓库、多仓库、prefer、exclude | 通过 |
| Keyword/Vector 双向降级 | 通过 |
| 漏斗三态纯值读模型 | 通过 |
| 旧 Plan/Trace/Snapshot/Diagnostics 解码 | 通过 |
| RAG 定向 Suite | 通过 |
| 全量测试 | 1547 项：1538 通过、8 跳过、1 预期失败、0 失败 |
| `Starcat` Debug build | 通过 |
| `StarcatDirect` Debug build | 通过 |
| xcstrings / i18n / whitespace | 通过 |

## 4. 五轮审查

| 轮次 | 重点 | 结果 |
|---|---|---|
| 第一轮 | 协议、FTS 安全、repo scope | 4 项问题全部关闭 |
| 第二轮 | 独立降级、漏斗真实值、历史隐私 | 3 项问题全部关闭 |
| 第三轮 | 正式设计、工程进度、双 target 门禁 | 3 项问题全部关闭 |
| 第四轮 | 旧会话/Debug 兼容测试证据 | 1 项问题关闭 |
| 第五轮 | 代码、文档、测试、Git 最终一致性 | 通过，无遗留功能缺口 |

审查报告均位于本目录，且每轮遵循“先提交报告，再修复，再回填”。

## 5. 提交记录

所有提交均使用中文 message，并按小功能拆分：

| 提交 | 内容 |
|---|---|
| `0853e02` | 方案与 Checklist |
| `b535c6a` | 双查询协议与 Planner |
| `4c760e7` | 安全 OR 召回 |
| `b02cf73` | Service、Trace、漏斗与 i18n |
| `531764b` | 正式设计与专项进度 |
| `198d4be` / `1d8c2ed` | 第一轮报告与回填 |
| `1728b4c` / `0b2fd30` / `ebe5072` | 第一轮三组代码/测试修复 |
| `7e0e39e` / `1a2cd1c` | 第二轮报告与回填 |
| `d915baf` / `72ee0de` / `89dfb9f` | 第二轮三组代码/测试修复 |
| `a47129d` / `f58b143` / `099f7cd` | 第三轮报告、门禁补充与回填 |
| `42bee00` / `86cb951` / `e6742f0` | 第三轮文档与构建修复 |
| `eea8201` / `2d35454` | 第四轮报告与回填 |
| `c712086` | 旧 Snapshot/Diagnostics 兼容测试 |
| `cf6399b` | 第五轮无问题终审 |
| 本文件所在提交 | 最终结果报告与 Checklist 收口 |

## 6. 已知边界

- FTS5 是字面检索，不自动翻译。默认双语关键词覆盖中文内容和常见英文 README；真正跨语言
  同义召回仍依赖 embedding。
- Prompt 目标是 3～8 项；本地只硬限制最多 8 项，过滤后允许少于 3 项，不补造低质量词。
- 旧自定义 Prompt 不会被覆盖；未返回关键词时从 `semanticQuery` 做有界 OR fallback。
- 真实中英混合问答质量评测仍是 RAG 专项的持续评测项，没有用合成单测冒充真实数据结论。
- 自动化审查没有伪造真实 Provider + 本地知识库的人工 UI 点选；建议合并后做一次实际体验验收。

## 7. `docs/功能实现总览.md` 已同步内容

经 dong4j 明确授权，已在 2026-07-17 23:32 同步以下内容：

```markdown
- [x] **RAG 双语关键词 OR 检索** — Planner 拆分语义查询与双语关键词，RAG FTS5 使用安全 OR，并补齐检索漏斗三态 — `KnowledgeRAGQueryPlanner.swift`、`RAGSearchProviders.swift`、`RAGWorkspaceInspector.swift` — 2026-07-17
> 实现：普通搜索继续 AND；RAG 关键词经本地去重、限长和转义后 OR 召回，repo 范围仅由 id 强制限定；Trace/Snapshot 不复制分片正文或原始外部错误。
```

同时更新进度仪表盘：P2 从 15/40 更新为 16/41（39%），总计从 117/151 更新为 118/152（78%），并在变更日志顶部登记本次完成项。

## 8. 交付状态

- worktree：`/Users/dong4j/orca/workspaces/Starcat/rag-bilingual-keyword-or`
- 分支没有 upstream，未 push。
- 未执行打包、发布、上传或部署。
- 除 dong4j 人工体验验收外，本次约定工作已全部完成，功能总览已同步。
