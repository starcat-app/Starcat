# RAG 双语关键词 OR 检索实施方案

> 状态：已完成；实现与验证见结果报告
> 日期：2026-07-17
> 范围：知识库 RAG Query Planner、SQLite FTS5 关键词召回、混合检索与 Inspector/Debug 可观测性
> 关联清单：`RAG双语关键词OR检索Checklist.md`

## 1. 背景与问题

Starcat 现有 `FTSQuery.sanitize` 最初服务于主界面由用户直接输入的短关键词搜索。它把空白分隔的 token 转为 FTS5 相邻短语，因此多词默认采用 AND，并仅为末词追加前缀通配。这个语义适合 `swift ui`、`react native` 一类精确筛选，但知识库 RAG 已经改变了查询输入契约：Query Planner 产出的 `semanticQuery` 是面向 embedding 的完整自然语言，包含介绍性词汇、同义表达，显式选择项目时还可能包含仓库 identity。

当前 Retriever 把同一个 `semanticQuery` 同时交给 FTS5 和向量分支。当 Planner 输出类似 `Introduction and overview of the repository owner/name` 时，FTS5 要求所有 token 同时出现在一个分片中，容易出现候选仓库正确、关键词召回为 0、向量后端不可用时最终无本地证据的问题。

本方案不改变普通搜索框的 AND 语义，而是为 RAG 建立独立查询协议：Planner 同时输出面向向量的 `semanticQuery` 和面向字面召回的 `keywordQueries`；FTS5 对经过本地校验的关键词采用 OR，候选仓库继续由结构化过滤和显式 repo scope 强制限定。

## 2. 目标与非目标

### 2.1 目标

- 向量查询与关键词查询使用不同字段和明确契约。
- 中文提问同时生成中文概念词与常见英文技术表达，覆盖中英文 README、笔记、摘要和 Metadata。
- FTS5 任一高信息关键词命中即可召回，由 BM25、混合融合和可选 Rerank 控制排序。
- 单仓库、多仓库、prefer 和 exclude 的范围继续由 repo id 强制执行，不依赖关键词文本。
- 旧会话、旧 Debug JSON 和旧自定义 Planner Prompt 保持可读取、可执行。
- 检索漏斗能区分零命中、分支失败和明确跳过，并可看到实际关键词与最终 FTS5 表达式。

### 2.2 非目标

- 不修改主窗口普通 FTS5 搜索的多词 AND 行为。
- 不更换 `rag_chunks_fts` tokenizer，不改已发布 `v7-knowledge-rag` schema。
- 不引入本地翻译模型、中文分词器或新的外部检索服务。
- 不把 repo 名称作为 FTS5 命中的必要条件。
- 不修改 `docs/功能实现总览.md`；仅在结果报告中提供拟同步内容，等待 dong4j 单独确认。

## 3. Query Plan 协议

`RAGQueryPlan` 新增兼容字段：

```swift
var keywordQueries: [String]
```

示例：

```json
{
  "mode": "semantic_only",
  "semanticQuery": "How to configure build targets in this VS Code Makefile extension",
  "keywordQueries": [
    "配置",
    "构建目标",
    "configuration",
    "build target",
    "makefile",
    "target"
  ]
}
```

字段职责固定为：

| 字段 | 用途 |
|---|---|
| `semanticQuery` | query embedding、向量检索、Rerank |
| `keywordQueries` | SQLite FTS5 / Meilisearch 关键词召回 |
| `filters`、显式 repo ids | 候选仓库范围与排序 |

`keywordQueries` 解码缺失时默认为 `[]`，保证旧计划和旧历史数据兼容。默认 Planner Prompt 升级到新协议；用户自定义 Prompt 原样保留。旧 Prompt 没有返回关键词时，执行层从 `semanticQuery` 构建有界、安全的 OR token 兜底，不回到旧 AND。

## 4. Planner 关键词规则

Planner Prompt 的目标是返回 3～8 个高信息量查询项：

- 保留提问语言中的 2～4 个核心概念；
- 补充 2～4 个常见英文技术表达，适配通常为英文的 README 和源码术语；
- 类名、函数名、文件名、配置项、错误码和命令保持原文；
- 短语可以作为一个查询项，例如 `build target`、`VS Code extension`；
- 删除“项目、仓库、介绍、如何、怎么、overview、repository”等低信息词；
- 显式选择 repo 时不把 `owner/name` 自动加入关键词；
- 不输出 FTS5 操作符或完整回答式自然语言。

Planner 只提出关键词，本地执行层始终负责最终校验和查询构造，不能信任模型直接生成的 FTS5 表达式。
本地执行层硬性限制最多 8 项；去空、去重、低信息词和 repo identity 过滤后允许少于 3 项，
不会为了凑数量补造低质量词。

## 5. RAG 专用 FTS5 OR 构造

新增 RAG 专用查询构造器，保留 `FTSQuery.sanitize` 的现有行为不变。构造器负责：

- trim 并删除空项；
- 忽略大小写稳定去重；
- 最多保留 8 项，并限制每项长度；
- 将双引号转义为 FTS5 规范的两个双引号；
- 把 `AND`、`OR`、`NOT`、`NEAR`、括号、前缀符号等模型文本当作普通字面内容，而非可执行语法；
- 单词和有意短语分别形成独立的安全子句；
- 子句之间显式使用 `OR`；
- 空数组时把 `semanticQuery` 的有界 token 作为 OR 兜底。

目标表达式示例：

```text
"配置"* OR "构建目标"* OR "configuration"* OR "build target"* OR "makefile"* OR "target"*
```

FTS5 只做字面匹配，不负责中英翻译。双语关键词用于同时覆盖英文 README/Metadata 与中文笔记/摘要；真正的跨语言语义召回仍由 embedding 分支负责。

## 6. 仓库范围

仓库选择与关键词完全解耦：

| 模式 | 执行语义 |
|---|---|
| 未显式选择 | Planner filters + 本地候选查询确定 repo ids，再执行 OR 召回 |
| `.only` 单仓库 | `repo_id = selectedID AND (keyword OR ...)` |
| `.only` 多仓库 | `repo_id IN (...) AND (keyword OR ...)` |
| `.prefer` | 在已有候选范围内保留 selected repo boost，不把 repo 名加入关键词 |
| `.exclude` | 本地候选层排除 repo ids，关键词无权恢复范围 |

所有 Provider 都只能接收已校验的候选 repo ids。选中 repo 有索引但无匹配时仍返回 `no_evidence`，不能擅自扩大范围。

## 7. 混合检索与降级

```text
用户问题
  -> Query Planner
       -> semanticQuery  -> query embedding / vector
       -> keywordQueries -> FTS5 OR / BM25
  -> RRF 混合融合
  -> 可选 Rerank（继续使用 semanticQuery）
  -> source / repo / token 上限
  -> 最终证据
```

- Keyword 与 Vector 继续并行执行。
- Vector 失败时，Keyword 命中仍可独立进入融合和最终证据。
- Keyword 失败时，Vector 命中仍可继续。
- 两路都失败才按现有错误语义向上传播。
- 单路正常执行但零命中属于 `0 hits`，不能显示成执行错误。

## 8. Inspector 与 Debug

“上下文－计划”展示经过校验的：

- 语义查询；
- 关键词查询列表；
- 仓库 scope 与候选数量。

检索漏斗继续展示候选仓库、关键词召回、语义召回、混合融合、重排和最终证据，并补充：

- Keyword / Vector 原始命中数；
- 各分支过滤后数量；
- Keyword / Vector 错误摘要；
- `执行成功但 0 命中`、`执行失败`、`已跳过` 三种状态。

Planner/Debug 记录原始问题与 `semanticQuery`；`RAGRetrievalTrace` 保存经过校验的
`keywordQueries` 和最终 FTS5 表达式，`RAGRetrievalSnapshot` 只保存安全 failure code 与命中
统计。原始 provider 错误仅保留在当前轮 Diagnostics/Debug；历史数据不复制外部错误或分片
正文，不新增隐私数据范围。

## 9. 兼容与数据边界

- `keywordQueries` 使用 `decodeIfPresent(... ) ?? []`，旧 JSON 无需迁移。
- 不修改 SQLite schema，也不要求用户重建数据库。
- Planner 官方默认模板按既有“只升级上一版官方默认值”机制迁移；自定义模板不覆盖。
- 旧自定义模板遗漏字段时使用本地 OR 兜底。
- Meilisearch Provider 接收同一组关键词语义，但本次优先保证 SQLite FTS5 默认路径和 fallback 路径正确。
- Debug、会话存储和 CloudKit 不新增分片正文副本。

## 10. 验证与交付

自动化至少覆盖：

1. 新旧 Query Plan JSON 解码；
2. Planner 双语关键词规范化、数量和长度约束；
3. 特殊字符安全转义与 OR 语义；
4. 任意一个关键词命中即可召回；
5. 单仓库、多仓库、prefer、exclude 范围不越界；
6. repo 名未出现在分片中不影响召回；
7. Vector 离线时 Keyword 仍可产生证据；
8. Keyword 失败时 Vector 仍可继续；
9. Inspector/Debug 能区分零命中、失败和跳过；
10. 旧会话和旧自定义 Prompt 路径兼容。

实施完成后执行定向测试、全量测试、`Starcat` / `StarcatDirect` Debug build、i18n 与静态检查。随后至少完成三轮审查；每轮先新增并提交审查报告，再修复报告发现的问题并独立提交。最后回填 Checklist，并新增结果报告。
