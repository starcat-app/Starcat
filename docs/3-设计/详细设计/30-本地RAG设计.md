# 30 — 知识库 RAG 详细设计

> 日期: 2026-07-03
> 状态: 设计方案, 尚未实现
> 范围: 基于 Starcat 知识库的本地 RAG 索引、召回、生成、引用、工作台 UI 与落地 checklist
>
> 关联文档:
> - `docs/2-产品/需求讨论/知识库RAG需求讨论.md`
> - `docs/2-产品/需求讨论/正式方案/知识库RAG正式方案.md`
> - `docs/3-设计/详细设计/29-关键词与全文检索设计.md`
> - `docs/3-设计/详细设计/38-Starred与知识库改造详细设计.md`
> - `docs/3-设计/详细设计/27-RepoContextPacker设计.md`

## 1. 设计目标

早期 RAG 设计以“已 star 仓库”为默认数据源。这个前提已经过期。

当前 Starcat 已经拆分出:

- `repos.is_starred`: GitHub 公开 Star 状态。
- `repo_notes.library_state = 'in_library'`: Starcat 私有知识库状态。

本设计把 RAG 调整为:

> 只基于 Starcat 知识库 repo 进行默认问答,并为每个回答提供可追溯引用和证据片段。

第一版目标:

1. 建立 chunk-level RAG 索引。
2. 默认只索引和召回 `libraryState == .inLibrary` repo。
3. 复用现有 AI Provider / Embedding / Chat 配置。
4. 提供独立知识库问答工作台。
5. 回答必须带 citation,并能打开对应 repo。
6. 第一版只读,不自动写 tags、notes、status、star 或 libraryState。

## 2. 当前代码基础

已存在能力:

| 能力 | 现状 | RAG 复用方式 |
|---|---|---|
| 知识库状态 | `LibraryState`, `repo_notes.library_state` 已落地 | RAG 默认候选范围 |
| 语义范围 | `SemanticIndexScope.starred/knowledge/all` 已存在 | RAG 使用 `.knowledge` |
| repo-level embedding | `repo_embeddings(repo_id, model)` | 普通语义搜索继续使用 |
| AI Client | `AIClientProtocol.embedding/embeddings/chatStream` | RAG embedding 与生成 |
| README 缓存 | `ReadmeRepository` / `ReadmeAPI` | chunk 来源之一 |
| 用户笔记 | `RepoNoteRepository` | chunk 来源之一 |
| AI 摘要 | `AISummaryRepository` | chunk 来源之一 |
| Agent Workspace | 覆盖式 workspace + timeline + inspector | RAG UI 可复用工作台设计语言 |
| DiskChatHistoryStore | 单仓 AI 会话历史 | RAG 会话可另建本地历史存储 |

关键差异:

- `repo_embeddings` 是 repo-level,只能回答“哪个 repo 相关”,不能定位证据段落。
- RAG 需要 chunk-level 索引,否则 citation 只能指向 repo,无法证明具体结论。
- RAG 默认范围比 `SemanticIndexScope.all` 更窄,必须固定为知识库。

## 3. 模块拆分

建议新增 `Starcat/Features/RAG`:

```text
Starcat/Features/RAG/
├── Core/
│   ├── KnowledgeRAGModels.swift
│   ├── KnowledgeRAGQueryPlanner.swift
│   ├── KnowledgeRAGService.swift
│   ├── KnowledgeRAGRetriever.swift
│   ├── RAGKeywordSearchProvider.swift
│   ├── RAGVectorSearchProvider.swift
│   ├── RAGHybridFusionEngine.swift
│   ├── RAGRerankProvider.swift
│   ├── RAGBackendConfiguration.swift
│   ├── KnowledgeRAGRemoteContextProvider.swift
│   ├── KnowledgeRAGPromptBuilder.swift
│   └── KnowledgeRAGCitationParser.swift
├── Indexing/
│   ├── RAGChunkBuilder.swift
│   ├── RAGIndexBuilder.swift
│   └── RAGIndexingStatus.swift
├── UI/
│   ├── KnowledgeRAGWorkspaceView.swift
│   ├── KnowledgeRAGWorkspaceViewModel.swift
│   ├── RAGCommandComposerView.swift
│   ├── RAGMentionPicker.swift
│   ├── RAGContextChip.swift
│   ├── RAGAnswerView.swift
│   ├── RAGEvidenceInspector.swift
│   └── RAGCitationChip.swift
└── Storage/
    ├── RAGChunkRepository.swift
    └── RAGConversationStore.swift
```

Repository 与数据库模型放到现有 Core 层:

```text
Starcat/Core/Database/Models/RAGChunk.swift
Starcat/Core/Sync/RAGChunkRepository.swift
```

原因:

- chunk 是跨 UI / service / indexing 的本地缓存,不是纯 Feature 私有状态。
- 后续 MCP 或 Agent 也可能读取 RAG chunk 证据。

## 4. 数据模型

### 4.1 RAG chunk 表

新增 `rag_chunks`:

```sql
CREATE TABLE rag_chunks (
    id                  INTEGER PRIMARY KEY,
    repo_id             INTEGER NOT NULL REFERENCES repos(id) ON DELETE CASCADE,
    source              TEXT NOT NULL,
    source_id           TEXT NOT NULL DEFAULT '',
    parent_type         TEXT NOT NULL DEFAULT 'repo',
    parent_key          TEXT NOT NULL,
    parent_title        TEXT NOT NULL DEFAULT '',
    chunk_key           TEXT NOT NULL,
    chunk_index         INTEGER NOT NULL,
    section_path        TEXT NOT NULL DEFAULT '',
    title               TEXT NOT NULL DEFAULT '',
    content             TEXT NOT NULL,
    content_hash        TEXT NOT NULL,
    token_count         INTEGER NOT NULL,
    embedding_model     TEXT,
    embedding_dim       INTEGER,
    embedding           BLOB,
    embedding_status    TEXT NOT NULL DEFAULT 'pending',
    embedding_error     TEXT,
    indexed_at          TEXT,
    created_at          TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (repo_id, source, source_id, chunk_key)
);

CREATE INDEX idx_rag_chunks_repo ON rag_chunks(repo_id);
CREATE INDEX idx_rag_chunks_parent ON rag_chunks(repo_id, parent_type, parent_key);
CREATE INDEX idx_rag_chunks_source ON rag_chunks(source);
CREATE INDEX idx_rag_chunks_model ON rag_chunks(embedding_model);
```

字段说明:

| 字段 | 说明 |
|---|---|
| `source` | `readme` / `notes` / `summary` / `metadata` |
| `source_id` | README 可为空; AI 摘要可存 summary id 或版本; notes 可为空 |
| `parent_type` | `repo` / `readme_section` / `notes` / `summary` / `metadata` |
| `parent_key` | child 命中的上级语义单元 key,如 `repo:groue/GRDB.swift` 或 `readme:installation` |
| `parent_title` | parent 展示名,如 `README > Installation` |
| `chunk_key` | 同 repo + source 内的稳定 diff key,例如 `readme:installation:0` |
| `chunk_index` | 同 repo + source 内的展示顺序,不用于判断内容是否同一段 |
| `section_path` | README heading path,如 `Installation > macOS` |
| `title` | chunk 展示标题,优先取 heading |
| `content_hash` | 用于 diff,未变化不重新 embedding |
| `embedding` | Float32 BLOB,与 `RepoEmbedding` 一致 |
| `embedding_status` | `pending` / `ready` / `failed` / `stale` |

不复用 `repo_embeddings`:

- repo-level embedding 的主键是 `(repo_id, model)`,不支持一 repo 多 chunk。
- RAG citation 需要 chunk id。
- RAG 索引的清理、覆盖率和重建节奏不同于语义搜索。

### 4.2 Repo-aware Parent-child 模型

Starcat 的 RAG 不按普通企业文档的 flat chunk 模型处理。repo 是天然完整对象: child chunk 命中某个 README 段落时,通常意味着整个 repo 进入候选,而不是只把孤立段落送给 LLM。

本设计采用 Repo-aware Parent-child:

```text
Repo Parent
  ├─ Readme Section Parent
  │   ├─ Child Chunk
  │   └─ Child Chunk
  ├─ Notes Parent
  ├─ Summary Parent
  └─ Metadata Parent
```

职责拆分:

| 层级 | 存储 / 构造 | 职责 |
|---|---|---|
| Child Chunk | `rag_chunks` | 用于 embedding、FTS、精确召回和 citation |
| Section Parent | 由 `parent_type/readme_section + parent_key` 动态聚合 | 给 LLM 提供命中章节的完整上下文 |
| Repo Parent | 由 repo metadata、notes、summary、matched children 动态打包 | 让答案按 repo 组织,不是按碎片组织 |

为什么不新增 `rag_parents` 表:

- section parent 可以从同一 `parent_key` 下的 readme chunks 重组。
- repo parent 需要混合 repo metadata、notes、summary、matched children,更像一次查询结果的打包产物。
- 第一版把 parent 设计为“虚拟 parent”,减少 schema 和更新复杂度。后续如果需要缓存 section 摘要或 parent 摘要,再新增 `rag_parents`。

检索原则:

```text
child chunks 负责找准
repo parent 负责讲完整
section parent 负责补上下文
```

因此 Retriever 不直接把 top chunks 交给 Generator,而是先聚合成 repo 命中,再输出 `RepoContextBundle`。

### 4.3 RAG 会话表

第一版可以先不做复杂历史。如果做历史,建议:

```sql
CREATE TABLE rag_conversations (
    id              TEXT PRIMARY KEY,
    title           TEXT NOT NULL,
    scope           TEXT NOT NULL DEFAULT 'knowledge',
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL
);

CREATE TABLE rag_messages (
    id                  TEXT PRIMARY KEY,
    conversation_id     TEXT NOT NULL REFERENCES rag_conversations(id) ON DELETE CASCADE,
    role                TEXT NOT NULL,
    content             TEXT NOT NULL,
    citation_ids_json   TEXT NOT NULL DEFAULT '[]',
    model               TEXT,
    created_at          TEXT NOT NULL
);

CREATE TABLE rag_message_citations (
    id              TEXT PRIMARY KEY,
    message_id      TEXT NOT NULL REFERENCES rag_messages(id) ON DELETE CASCADE,
    chunk_id        INTEGER NOT NULL REFERENCES rag_chunks(id) ON DELETE CASCADE,
    repo_id         INTEGER NOT NULL REFERENCES repos(id) ON DELETE CASCADE,
    rank            INTEGER NOT NULL,
    score           REAL NOT NULL,
    quote           TEXT NOT NULL DEFAULT ''
);
```

会话历史第一版只本地存储,不进 CloudKit。

## 5. Chunk 构建

### 5.1 输入来源

每个知识库 repo 生成以下 chunk:

| 来源 | 是否第一版 | 说明 |
|---|---:|---|
| README markdown | 是 | 主要知识源 |
| 用户 notes | 是 | 用户私有判断,权重高 |
| AI summary | 是 | 已生成则纳入,不为 RAG 临时生成 |
| repo metadata | 是 | fullName、description、topics、language、stars、forks、watchers、issues、license、archived/fork、是否 starred、status、tags、libraryUpdatedAt 等基础信息 |
| Repo Health / OpenSSF | 可后续 | 更适合结构化 filter,第一版不强制 |
| CodeFlow / Codebase memory | 不做 | 属于代码语义检索,另行设计 |

约束:

- RAG 索引不为了构建 chunk 临时触发 AI 摘要。
- README 缺失时可用 metadata + notes + summary 继续索引。
- 无权限私有 repo 如果已有本地 README 缓存,允许使用缓存;没有缓存则只用本地可用资料。

### 5.2 README 切分规则

README chunk 采用“Markdown 结构优先 + token 上限兜底”。不要直接按固定长度硬切,因为 README 本身通常是结构化文档;按章节切能让 citation 指向更清楚的 section。

```swift
struct RAGChunkBuilder {
    func build(repo: Repo, readme: String?, note: RepoNote?, summary: AISummaryRecord?) -> [RAGChunkDraft]
}
```

默认参数:

| 参数 | 默认 | 说明 |
|---|---:|---|
| target tokens | 700 | 普通 chunk 的目标大小 |
| min tokens | 180 | 小于该值的 section 优先合并 |
| max tokens | 1100 | 普通 section 超过后需要拆分 |
| overlap tokens | 80 | 只用于超长 section 拆分后的相邻 chunk |
| hard max tokens | 1600 | 单个超长代码块或表格的硬上限 |

处理顺序:

1. `#` / `##` / `###` 建立 section path。
2. 先清理 badge、纯图片、目录列表、重复链接引用等低价值内容。
3. 以 heading section 为基本单位生成候选 section。
4. 小于 `min tokens` 的相邻 section 合并,避免碎片 chunk。
5. 超过 `max tokens` 的 section 优先按子 heading 再拆。
6. 仍超过 `max tokens` 时按段落滑窗切分。
7. 只有被拆开的超长 section 使用 `overlap tokens`,普通 section 不加 overlap。
8. 代码块不在中间硬切;单个代码块超过 `hard max tokens` 时保留开头和结尾,中间用 `...` 标记。

拆分优先级:

```text
Markdown heading
  -> child heading
  -> paragraph
  -> sentence fallback
  -> hard truncate for oversized code/table
```

#### 5.2.1 5k tokens README 示例

假设一个 README 清洗后约 5k tokens:

```text
# Project                      400
## Features                    700
## Installation                900
## Quick Start                1300
## Configuration               800
## API Reference               600
## FAQ                         300
```

生成 chunks:

| chunk_index | section_path | tokens | chunk_key |
|---:|---|---:|---|
| 0 | Project | 400 | `readme:project:0` |
| 1 | Features | 700 | `readme:features:0` |
| 2 | Installation | 900 | `readme:installation:0` |
| 3 | Quick Start | 约 850 | `readme:quick-start:0` |
| 4 | Quick Start | 约 650 | `readme:quick-start:1` |
| 5 | Configuration | 800 | `readme:configuration:0` |
| 6 | API Reference | 600 | `readme:api-reference:0` |
| 7 | FAQ | 300 | `readme:faq:0` |

`Quick Start` 超过 `max tokens`,所以按段落拆成两个 chunk。第二个 chunk 可以带 80 tokens overlap,用于保留上下文连续性。

如果有很小的 section:

```text
## Requirements      80 tokens
## Installation     650 tokens
```

合并为:

| section_path | tokens | chunk_key |
|---|---:|---|
| Requirements + Installation | 730 | `readme:requirements-installation:0` |

如果某个章节特别长:

```text
## API Reference     2500 tokens
### Client
### Server
### Errors
```

先按 `###` 子标题切:

| section_path | tokens | chunk_key |
|---|---:|---|
| API Reference > Client | 950 | `readme:api-reference-client:0` |
| API Reference > Server | 880 | `readme:api-reference-server:0` |
| API Reference > Errors | 500 | `readme:api-reference-errors:0` |

如果 `Client` 自身仍超过上限,再按段落滑窗:

| section_path | tokens | chunk_key |
|---|---:|---|
| API Reference > Client | 950 | `readme:api-reference-client:0` |
| API Reference > Client | 900 | `readme:api-reference-client:1` |

#### 5.2.2 代码块与表格

代码块规则:

- 正常代码块跟随所在 section,不单独拆成 source。
- 不在 fenced code block 中间切 chunk。
- 单个代码块超过 `hard max tokens` 时,保留开头和结尾,中间用 `...` 标记。
- 被截断的 chunk 在 `title` 或 metadata 中标记 `truncated = true`,Inspector 需要显示“内容已截断”。

表格规则:

- 小表格完整保留。
- 大表格优先按行切分,但必须保留表头。
- 超过 `hard max tokens` 的表格保留表头 + 前 N 行 + 后 N 行,中间用 `...`。

这样 5k tokens README 通常会落在 6-10 个 readme chunks,既不会太碎,也不会让单个 chunk 过长导致相似度被稀释。

### 5.3 Notes 与 Summary

用户 notes:

- 独立成 source = `notes` 的 chunk。
- 权重高于 README。
- 为空则不生成。

AI summary:

- 独立成 source = `summary`。
- 只使用已存在摘要,不临时调用 LLM。
- 如果摘要 stale,仍可用,但 citation Inspector 标记“摘要缓存”。

metadata:

- source = `metadata`。
- 内容包含 repo 的基础信息: fullName、description、topics、language、stars、forks、watchers、openIssues、license、archived/fork、是否 starred、RepoStatus、tags、libraryUpdatedAt。
- 用于召回“我之前入库过哪个 Swift Markdown 渲染库”“知识库里 star 数最高的向量数据库是哪几个”“哪些已入库项目还没读”这类问题。
- metadata chunk 只表达结构化事实,不承载 README 正文。Retriever 中它的 source 权重低于 notes / summary / readme,避免“star 数高”压过真正内容相关性。

## 6. 索引构建

### 6.1 默认范围

RAG index builder 只取知识库:

```swift
let repos = try await repoRepository.fetchKnowledgeRepos()
```

不能默认取:

- `fetchAllStarred()`
- `SemanticIndexScope.all`

### 6.2 增量策略

流程:

```text
fetchKnowledgeRepos
  -> build chunk drafts
  -> diff by (repo_id, source, source_id, chunk_key, content_hash)
  -> delete stale chunks for repo/source
  -> embed changed chunks in batch
  -> upsert embedding + indexed_at
```

触发时机:

- 用户手动构建 RAG 索引。
- repo 加入知识库后,后台排队索引该 repo。
- repo 移出知识库后,不立即删除 chunk,但 RAG retrieve 不再召回它。
- README 缓存更新后,如果 repo 仍在知识库,排队更新 readme chunks。
- notes 保存后,如果 repo 在知识库,debounce 后更新 notes chunk。
- AI summary 生成后,如果 repo 在知识库,更新 summary chunk。
- repo metadata 更新后,如果 repo 在知识库,按 metadata 更新策略决定是否更新 metadata chunk。

为什么移出知识库不立即删除:

- 与现有 embedding/cache 策略一致,移出知识库不是删除缓存。
- 如果用户重新入库,可复用已有 chunk 和 embedding。
- 真正清理由 Storage 缓存策略处理。

### 6.3 分来源更新规则

RAG chunk 更新按 source 独立执行。一个来源变化不能顺手重建其它来源,否则 README、notes、summary、metadata 会互相放大索引成本。

| 变化 | 处理 |
|---|---|
| README 变了 | 只重建 `source = readme` drafts,按 `chunk_key + content_hash` diff |
| notes 变了 | 只重建 `source = notes`; notes 为空时删除或标记 stale notes chunk |
| 之前没有 AI summary,现在生成了 | 新增 `source = summary` chunk 并 embedding |
| AI summary 重新生成 | 只更新 `source = summary` |
| repo metadata 变了 | 只更新 `source = metadata`,且遵守数字字段 bucket / 节流规则 |
| repo 移出知识库 | 不删除 chunk,Retriever 不再召回 |
| repo 重新入库 | 复用旧 chunk,必要时补 pending / stale embedding |

### 6.4 chunk_key 与 chunk_index

`chunk_index` 不能作为 diff 的稳定身份。README 中间插入一个章节时,后续 index 会整体位移;如果按 `chunk_index` 对齐,大量没变的 chunk 会被误判为变化并重新 embedding。

因此需要区分:

- `chunk_key`: 稳定身份,用于 diff 与 upsert。
- `chunk_index`: 展示顺序,用于 Inspector 和 prompt 排序。

推荐 `chunk_key` 规则:

```text
chunk_key = source + ":" + normalized_section_path + ":" + ordinal_in_section
```

示例:

| source | section_path | ordinal | chunk_key |
|---|---|---:|---|
| readme | Installation > macOS | 0 | `readme:installation-macos:0` |
| notes | User Notes | 0 | `notes:user-notes:0` |
| summary | AI Summary | 0 | `summary:ai-summary:0` |
| metadata | Repo Metadata | 0 | `metadata:repo-metadata:0` |

如果 README 没有 heading,用 `readme:root:{ordinal}`。如果同名 heading 重复,`ordinal_in_section` 负责区分。

### 6.5 embedding_status

chunk 内容更新和 embedding 更新不是同一个瞬间完成。为了避免 Retriever 读到“新 content + 旧 embedding”的不一致状态,chunk 需要显式状态:

| 状态 | 含义 | Retriever 是否召回 |
|---|---|---:|
| `pending` | content 已写入,等待 embedding | 否 |
| `ready` | content 与 embedding 对应当前 model | 是 |
| `failed` | embedding 失败,保留错误信息 | 否 |
| `stale` | 内容或模型已过期,等待重建 | 否 |

更新流程:

```text
content_hash unchanged
  -> 保持 ready,复用 embedding

content_hash changed
  -> 写入新 content/hash
  -> embedding_status = pending
  -> embedding = NULL 或保留旧 embedding 但 Retriever 不读
  -> batch embedding 成功后 status = ready
  -> 失败后 status = failed + embedding_error
```

Retriever 默认只读:

```sql
embedding_status = 'ready'
AND embedding_model = current_model
AND embedding IS NOT NULL
```

UI 如果发现 pending / failed 数量不为 0,在工作台顶部显示“索引更新中,部分新内容暂未进入问答”。

### 6.6 README 更新

README 更新只影响 `source = readme`:

1. 用新的 README markdown 生成 readme drafts。
2. 查询旧 readme chunks。
3. 按 `chunk_key` 对齐。
4. `content_hash` 一致: 保留旧 row 与 embedding。
5. `content_hash` 不一致: 更新 content/hash,状态设为 `pending`。
6. 新 chunk: 插入,状态设为 `pending`。
7. 旧 chunk 不再存在: 第一版直接删除;如果未来要支持历史 citation 回看,再改为 `stale` 保留。

### 6.7 Notes 更新

Notes 更新只影响 `source = notes`:

- notes 为空: 删除或 stale notes chunk。
- notes 非空: 生成 1 个或少量 notes chunks。
- 保存 notes 后 debounce 1.5 秒再入队,避免用户连续输入时反复索引。
- `content_hash` 不变不重新 embedding。

### 6.8 AI Summary 更新

AI summary 更新只影响 `source = summary`:

- 之前没有 summary: 新增 summary chunk。
- 重新生成 summary: diff summary chunk。
- summary stale 但未重新生成: 仍可保留旧 summary chunk;Inspector 需要标记“摘要缓存”。
- RAG 索引不为了补 summary 主动调用 AI 摘要生成。

### 6.9 Metadata 更新

Metadata chunk 包含 stars / forks / watchers / openIssues 等数字字段,但这些字段不应该每次轻微变化都触发 embedding。

规则:

- `description/topics/language/license/archived/fork/status/tags/libraryUpdatedAt` 变化: 正常更新 metadata chunk。
- `stars/forks/watchers/openIssues` 变化: 转成 bucket 文本后比较,只有跨 bucket 才更新。
- 精确排序和筛选不要依赖 embedding 文本,应走 repo 结构化字段查询。

建议 bucket:

| 字段 | bucket 示例 |
|---|---|
| stars | `0-99` / `100-999` / `1k-9k` / `10k-49k` / `50k+` |
| forks | `0-49` / `50-499` / `500-4k` / `5k+` |
| openIssues | `0` / `1-19` / `20-99` / `100+` |

这样用户问“知识库里 star 数最高的向量数据库”时,RAG 可以知道项目大致热度;真正排序仍由结构化字段完成。

### 6.10 覆盖率统计

Settings 或 RAG 工作台需要展示:

| 指标 | 说明 |
|---|---|
| 知识库 repo 总数 | `library_state = in_library` |
| 已有 RAG chunk 的 repo 数 | 至少 1 个 chunk |
| 已有 embedding 的 chunk 数 | 当前 embedding model 下非空 |
| pending chunk 数 | 等待 embedding 的 chunk |
| failed chunk 数 | embedding 失败的 chunk |
| stale chunk 数 | content_hash 变化或 model 不一致 |
| 最近索引时间 | max(indexed_at) |

覆盖率按当前 embedding model 计算,换模型后应显示需要重建。

## 7. RAG Query Planner 与执行状态机

RAG 入口前需要一个小型 AI Query Planner。它不回答用户问题,只把自然语言问题改写成 Starcat 可执行的查询计划。

这个层的目的:

1. 判断用户问题是否包含 repo-level 结构化筛选。
2. 把用户问题改写成更适合 embedding 检索的 `semanticQuery`。
3. 区分语义问答、结构化列表、筛选后语义问答和需要追问。
4. 给 UI 输出可解释的 plan chips,让用户知道系统查了什么。

### 7.1 为什么用 AI Planner

不采用“大量本地规则”作为主路径。中文自然语言表达太多,例如“我已使用的”“最近开始关注的”“高星但没读过”“不要 archived”“2026.07.03 之后加进来的”。靠正则穷举会让本地 parser 迅速复杂化。

第一版采用 AI Planner:

- 输入: 用户问题 + Starcat 支持的筛选字段说明 + 输出 JSON schema。
- 输出: `RAGQueryPlan` JSON。
- 约束: 只能使用 schema 中列出的字段,不能创造新字段。
- 不确定: 返回 `needs_clarification`,不得擅自猜。

本地只保留轻量保护逻辑:

- JSON schema validation。
- enum / date / number 范围校验。
- invalid JSON 时重试一次。
- 仍失败时降级为 `semantic_only`。

### 7.2 Planner 输入

Planner prompt 必须告诉模型当前 Starcat 支持哪些字段:

| 字段 | 类型 | 含义 |
|---|---|---|
| `status` | `using/read/unread` | 用户私有阅读/使用状态 |
| `languages` | `[String]` | repo 主语言 |
| `tags` | `[String]` | Starcat 用户标签 |
| `minStars/maxStars` | `Int` | GitHub stars 数量 |
| `minForks/maxForks` | `Int` | forks 数量 |
| `license` | `[String]` | license key 或名称 |
| `includeArchived` | `Bool?` | 是否包含 archived repo |
| `includeForks` | `Bool?` | 是否包含 fork repo |
| `starredAfter/starredBefore` | `Date?` | GitHub star 时间 |
| `libraryUpdatedAfter/libraryUpdatedBefore` | `Date?` | 加入/移出知识库状态更新时间 |
| `repoCreatedAfter/repoCreatedBefore` | `Date?` | GitHub repo 创建时间 |
| `pushedAfter/pushedBefore` | `Date?` | GitHub repo 最近 push 时间 |

日期字段必须严格区分。用户只说“从 2026.07.03 开始”时,Planner 不能自行映射到 `libraryUpdatedAfter` 或 `starredAfter`,必须追问。

Planner 还会收到输入框解析出的 `RAGComposerContext`。这部分不是 AI 从自然语言中猜出来的,而是用户显式操作产生的确定上下文:

```swift
struct RAGServiceRequest: Sendable {
    var rawQuestion: String
    var composerContext: RAGComposerContext
    var conversationID: UUID?
}

struct RAGComposerContext: Sendable {
    var explicitRepoIDs: [Int64]
    var explicitRepoMode: RAGExplicitRepoMode
    var selectedModelID: String?
    var attachments: [RAGComposerAttachment]
    var pastedGitHubLinks: [RAGGitHubLinkReference]
}

enum RAGExplicitRepoMode: String, Sendable {
    case only
    case prefer
    case exclude
}

struct RAGComposerAttachment: Sendable {
    var id: UUID
    var filename: String
    var contentType: String
    var sizeInBytes: Int64
    var localURL: URL
    var handling: RAGAttachmentHandling
}

enum RAGAttachmentHandling: String, Sendable {
    case vision
    case textContext
    case unsupported
}

struct RAGGitHubLinkReference: Sendable {
    var url: URL
    var owner: String
    var repo: String
    var matchedRepoID: Int64?
    var relation: RAGGitHubLinkRelation
}

enum RAGGitHubLinkRelation: String, Sendable {
    case inKnowledge
    case knownButNotInKnowledge
    case external
}
```

规则:

- `@repo` 产生的 `explicitRepoIDs` 必须由执行层强制应用,不能只依赖 AI Planner 理解。
- 默认 `explicitRepoMode = .only`。用户直接指定 repo 时,表示“只在这些 repo 中分析/对比”。
- 如果用户说“以 @repo 为参考,再找类似项目”,才使用 `.prefer`。
- `selectedModelID` 只影响本轮或当前会话,不自动修改 Settings 全局模型。
- 附件是本轮临时上下文,不进入 RAG 索引。

### 7.3 Query Plan Schema

```swift
struct RAGQueryPlan: Codable, Sendable {
    var mode: RAGQueryMode
    var semanticQuery: String
    var filters: RAGRepoFilter
    var sort: RAGRepoSort?
    var candidateLimit: Int?
    var remoteContextRequests: [RAGRemoteContextRequest]
    var confidence: RAGQueryPlanConfidence
    var clarificationQuestion: String?
    var userVisiblePlan: RAGUserVisiblePlan
}

enum RAGQueryMode: String, Codable, Sendable {
    case semanticOnly = "semantic_only"
    case filteredSemantic = "filtered_semantic"
    case structuredOnly = "structured_only"
    case needsClarification = "needs_clarification"
}

struct RAGRepoFilter: Codable, Sendable {
    var status: RepoStatus?
    var languages: [String]
    var tags: [String]
    var minStars: Int?
    var maxStars: Int?
    var minForks: Int?
    var maxForks: Int?
    var license: [String]
    var includeArchived: Bool?
    var includeForks: Bool?
    var starredAfter: Date?
    var starredBefore: Date?
    var libraryUpdatedAfter: Date?
    var libraryUpdatedBefore: Date?
    var repoCreatedAfter: Date?
    var repoCreatedBefore: Date?
    var pushedAfter: Date?
    var pushedBefore: Date?
}

struct RAGRepoSort: Codable, Sendable {
    var field: RAGRepoSortField
    var direction: SortDirection
}

struct RAGRemoteContextRequest: Codable, Sendable {
    var resource: RAGRemoteContextResource
    var query: String
    var reason: String
    var maxRepos: Int
    var perRepoLimit: Int
}

enum RAGRemoteContextResource: String, Codable, Sendable {
    case githubIssues = "github_issues"
    case githubPullRequests = "github_pull_requests"
    case githubReleases = "github_releases"
    case githubContributors = "github_contributors"
    case githubCommitActivity = "github_commit_activity"
    case githubSecurityAdvisories = "github_security_advisories"
}

enum RAGRepoSortField: String, Codable, Sendable {
    case stars
    case forks
    case pushedAt
    case repoCreatedAt
    case libraryUpdatedAt
    case starredAt
}

enum RAGQueryPlanConfidence: String, Codable, Sendable {
    case high
    case medium
    case needsClarification = "needs_clarification"
}

struct RAGUserVisiblePlan: Codable, Sendable {
    var scope: String
    var chips: [String]
    var semantic: String
}
```

`candidateLimit` 默认:

| mode | 默认 |
|---|---:|
| `semantic_only` | 无额外 SQL limit,直接在知识库范围检索 |
| `filtered_semantic` | 200 |
| `structured_only` | 50 |

如果用户说“star 最多的项目里找向量数据库”,Planner 可以设置 `sort = stars desc` 和 `candidateLimit = 50`,先取高星候选 repo,再做语义检索。

### 7.4 Mode 语义

| mode | 使用场景 | 后续流程 |
|---|---|---|
| `semantic_only` | 用户没有结构化筛选语义 | 知识库全量 repo -> child retrieval |
| `filtered_semantic` | 用户同时有筛选和语义问题 | SQL 过滤 repo -> child retrieval |
| `structured_only` | 用户只要列表/排序/统计,没有语义问题 | SQL 过滤 + metadata/summary bundle -> 直接生成列表 |
| `needs_clarification` | 日期/字段/意图不明确 | UI 追问,不执行检索 |

#### 7.4.1 无筛选语义

用户问题:

```text
有哪些适合做本地 RAG 的 Swift 项目?
```

Planner:

```json
{
  "mode": "semantic_only",
  "semanticQuery": "适合做本地 RAG 的 Swift 项目",
  "filters": {},
  "sort": null,
  "candidateLimit": null,
  "remoteContextRequests": [],
  "confidence": "high",
  "clarificationQuestion": null,
  "userVisiblePlan": {
    "scope": "知识库",
    "chips": [],
    "semantic": "适合做本地 RAG 的 Swift 项目"
  }
}
```

执行时不额外加 SQL 条件,只保留知识库边界:

```sql
repo_notes.library_state = 'in_library'
```

#### 7.4.2 筛选 + 语义

用户问题:

```text
从我已使用的项目中找适合做本地 RAG 的 Swift 库
```

Planner:

```json
{
  "mode": "filtered_semantic",
  "semanticQuery": "适合做本地 RAG 的 Swift 库",
  "filters": {
    "status": "using",
    "languages": ["Swift"]
  },
  "sort": null,
  "candidateLimit": 200,
  "remoteContextRequests": [],
  "confidence": "high",
  "clarificationQuestion": null,
  "userVisiblePlan": {
    "scope": "知识库",
    "chips": ["正在使用", "Swift"],
    "semantic": "适合做本地 RAG 的 Swift 库"
  }
}
```

#### 7.4.3 只有结构化条件

用户问题:

```text
列出 star 大于 10000 的项目
```

Planner:

```json
{
  "mode": "structured_only",
  "semanticQuery": "",
  "filters": {
    "minStars": 10000
  },
  "sort": {
    "field": "stars",
    "direction": "desc"
  },
  "candidateLimit": 50,
  "remoteContextRequests": [],
  "confidence": "high",
  "clarificationQuestion": null,
  "userVisiblePlan": {
    "scope": "知识库",
    "chips": ["stars > 10000", "按 stars 降序"],
    "semantic": ""
  }
}
```

这种场景不应该硬做 child retrieval。直接用 SQL repo candidates + metadata/summary bundle 生成列表或表格。

#### 7.4.4 歧义问题

用户问题:

```text
从 2026.07.03 开始的项目中找 Swift 库
```

Planner:

```json
{
  "mode": "needs_clarification",
  "semanticQuery": "Swift 库",
  "filters": {},
  "sort": null,
  "candidateLimit": null,
  "remoteContextRequests": [],
  "confidence": "needs_clarification",
  "clarificationQuestion": "你说的“开始”是指加入知识库时间、Star 时间、项目创建时间，还是最近更新时间?",
  "userVisiblePlan": {
    "scope": "知识库",
    "chips": [],
    "semantic": "Swift 库"
  }
}
```

UI 追问,不进入 SQL / retrieval。

### 7.5 远程临时上下文意图

RAG 不是通用联网搜索,但可以在用户问题需要“当前 GitHub 现场信息”时,为候选 repo 临时补充远程上下文。例如 issues、PR、release、contributors、commit activity、安全公告等数据不进入本地 chunk 索引,只在本轮问答中作为 `remoteContextBlocks` 送给 Generator。

Planner 负责判断是否需要远程上下文,并输出 `remoteContextRequests`:

| 用户语义 | resource | 介入条件 |
|---|---|---|
| bug、crash、issue、用户反馈、已知问题 | `github_issues` | 问题明显依赖 issue 现场信息 |
| release、版本、更新、breaking change | `github_releases` | 需要 GitHub release/tag 信息 |
| PR、维护活跃度、最近合并 | `github_pull_requests` | 需要 PR 状态或合并记录 |
| 维护者、贡献者、社区活跃 | `github_contributors` / `github_commit_activity` | 需要贡献或提交活跃度 |
| 漏洞、安全、CVE、advisory | `github_security_advisories` | 需要安全公告或漏洞上下文 |

普通知识库问答必须返回空数组:

```json
"remoteContextRequests": []
```

issues 查询示例:

```text
这些本地数据库项目最近有没有比较集中的崩溃或兼容性问题?
```

Planner:

```json
{
  "mode": "semantic_only",
  "semanticQuery": "本地数据库 崩溃 兼容性 问题",
  "filters": {},
  "sort": null,
  "candidateLimit": null,
  "remoteContextRequests": [
    {
      "resource": "github_issues",
      "query": "crash OR compatibility OR regression",
      "reason": "用户询问最近已知问题,本地 README/notes 可能不足以反映 issue 现场状态",
      "maxRepos": 5,
      "perRepoLimit": 10
    }
  ],
  "confidence": "high",
  "clarificationQuestion": null,
  "userVisiblePlan": {
    "scope": "知识库",
    "chips": ["GitHub Issues 临时上下文"],
    "semantic": "本地数据库 崩溃 兼容性 问题"
  }
}
```

约束:

- Planner 只声明意图,不直接访问网络。
- 没有远程语义时必须返回空数组,不能为了“更完整”默认联网。
- 远程上下文必须受候选 repo 限制,不能从整个 GitHub 搜索后绕过知识库边界。
- `maxRepos` 默认 5,`perRepoLimit` 默认 10,本地校验时必须钳制上限。
- 远程上下文失败不改变本地 plan mode,只进入降级上下文。

### 7.6 Planner 校验与降级

Planner 输出必须做校验:

1. JSON decode。
2. enum 合法性。
3. date 格式合法性。
4. number 范围合法性。
5. mode 与字段一致性。
6. `remoteContextRequests` 的 resource、maxRepos、perRepoLimit 合法性。

mode 与字段约束:

| mode | 必须满足 |
|---|---|
| `semantic_only` | `semanticQuery` 非空,filters 为空或无有效字段 |
| `filtered_semantic` | `semanticQuery` 非空,filters 或 sort 至少有一个有效字段 |
| `structured_only` | `semanticQuery` 可空,filters 或 sort 至少有一个有效字段 |
| `needs_clarification` | `clarificationQuestion` 非空 |

失败处理:

```text
Planner JSON invalid
  -> retry once with "return valid JSON only"
  -> still invalid: fallback semantic_only(original question)

Planner references unsupported field
  -> drop unsupported field
  -> if plan still valid: continue
  -> otherwise fallback semantic_only(original question)

Planner confidence = medium
  -> execute, but UI 显示可删除/修改的 plan chips

Planner confidence = needs_clarification
  -> ask clarification, do not retrieve

Planner remote request exceeds limit
  -> clamp maxRepos/perRepoLimit to local policy

Planner remote resource unsupported
  -> drop that remote request
```

### 7.7 执行状态机

```text
user question
  -> AI Query Planner
    -> invalid JSON: retry once
    -> needs_clarification: ask user
    -> semantic_only
    -> filtered_semantic
    -> structured_only

semantic_only:
  -> candidate repos = all knowledge repos
  -> child retrieval
  -> if no ready chunks: no_index
  -> if no hits / low relevance: no_evidence
  -> repo bundle
  -> optional remote context for top repos
  -> answer

filtered_semantic:
  -> SQL repo filter
  -> if 0 repos: no_candidate_repos
  -> child retrieval within candidate repos
  -> if no ready chunks: no_index
  -> if no hits / low relevance: no_evidence
  -> repo bundle
  -> optional remote context for top repos
  -> answer

structured_only:
  -> SQL repo filter + sort
  -> if 0 repos: no_candidate_repos
  -> metadata/summary bundle
  -> optional remote context for candidate repos when requested
  -> answer as list/table
```

远程上下文介入顺序必须在候选 repo 确定之后:

```text
Query Planner
  -> SQL repo filter / semantic candidate scope
  -> local child retrieval and repo aggregation
  -> top RepoContextBundle
  -> remote ephemeral context fetch for selected repos
  -> final RepoContextBundle
  -> Generator
```

这样可以保证 issues / releases 等网络数据只补充“知识库候选 repo”的上下文,不会把 RAG 变成全网搜索。

### 7.8 Repo Candidate SQL

`filtered_semantic` 和 `structured_only` 先执行 repo-level SQL:

```sql
SELECT r.id
FROM repos r
JOIN repo_notes n ON n.repo_id = r.id
LEFT JOIN starred_repos s ON s.repo_id = r.id
WHERE n.library_state = 'in_library'
  -- optional: n.status = 'using'
  -- optional: r.language IN (...)
  -- optional: r.stargazers_count >= ?
  -- optional: s.starred_at >= ?
  -- optional: n.library_updated_at >= ?
ORDER BY ...
LIMIT ...
```

SQL filter 的结果是 `candidateRepoIDs`。后续 child retrieval 必须限制在这个集合内:

```sql
SELECT c.*
FROM rag_chunks c
WHERE c.repo_id IN candidateRepoIDs
  AND c.embedding_model = ?
  AND c.embedding_status = 'ready'
  AND c.embedding IS NOT NULL
```

### 7.9 无结果与错误返回

无结果不是一个统一错误,必须区分阶段:

| 阶段 | 状态 | UI / 回复 |
|---|---|---|
| Planner | `needs_clarification` | 显示追问,不执行检索 |
| SQL filter | `no_candidate_repos` | “知识库中没有符合筛选条件的项目” |
| Chunk index | `no_index` | “符合条件的项目还没有 RAG 索引”,引导构建索引 |
| Retrieval | `no_evidence` | “没找到足够相关的内容”,可展示候选 repo |
| Structured only | `no_candidate_repos` | 直接说明无符合条件 repo |
| API | `planner_failed` | 降级 semantic_only 或提示配置 AI |

示例: SQL 有候选但 child retrieval 没证据:

```text
在“正在使用”的知识库项目中没有找到足够相关的 GraphQL 客户端内容。

已应用筛选:
- 状态: 正在使用

你可以:
- 放宽筛选到整个知识库
- 去 GitHub 全网搜索 GraphQL client
- 先为这些项目构建或更新 RAG 索引
```

这种情况下不调用 Generator 编答案。UI 可以展示“候选但证据不足”的 repo 列表,但必须标注证据不足。

### 7.10 UI Query Plan Chips

RAG 工作台在回答前或回答顶部展示 plan:

```text
范围: 知识库
筛选: 正在使用 · Swift · stars > 10000
排序: stars desc
语义: 适合做本地 RAG 的库
```

交互规则:

- `confidence = high`: 直接执行,展示 chips。
- `confidence = medium`: 执行,但 chips 可删除/修改。
- `needs_clarification`: 不执行,显示追问。
- 用户删除 chip 后,重新生成 plan 或直接重跑后续流程。

### 7.11 显式上下文约束

`RAGComposerContext` 的显式上下文优先级高于 AI Planner 输出。

执行规则:

| explicitRepoMode | SQL candidate 行为 | 使用场景 |
|---|---|---|
| `.only` | `repo_id IN explicitRepoIDs` | 用户 `@repoA @repoB 对比...` |
| `.prefer` | 不收窄 SQL,但 retriever / repoScore 对 explicit repo 加权 | 用户“参考 @repoA 找类似项目” |
| `.exclude` | `repo_id NOT IN explicitRepoIDs` | 用户“不要考虑 @repoA” |

`.only` 模式下:

- candidate repo 必须限制在用户选中的 repo 内。
- 如果选中 repo 不在知识库,默认不进入 RAG,UI 提示用户先加入知识库或作为外部链接打开。
- 如果选中 repo 没有 ready chunks,返回 `no_index`,不要扩大到其他 repo。
- 如果选中 repo 有 chunks 但无相关证据,返回 `no_evidence`,不要让 Planner 自行放宽范围。

issues / releases 这类远程上下文不由输入框命令强制触发。执行层只根据 Query Planner 输出的 `remoteContextRequests` 进入远程上下文流程,并在 UI 中展示可删除的确认 chip;用户删除后本轮跳过对应远程上下文。

## 8. Retriever

Starcat 的 RAG 方向定义为 **面向 GitHub Repo 的 Local-First Hybrid RAG**。默认实现不依赖外部检索服务,但检索链路必须从一开始按 hybrid pipeline 设计,避免后续从“纯向量 topK”重写。

默认链路:

```text
query
  -> keyword search: SQLite FTS5
  -> vector search: local embedding table
  -> fusion: RRF / weighted score
  -> repo aggregation
  -> optional rerank
  -> parent context packing
  -> Generator
```

第一版可以不接 Meilisearch / Qdrant / reranker,但 provider 边界要保留。这样后续用户自行部署外部组件时,Starcat 只需要在 Settings 配置 endpoint 和凭据,再通过 API 调用对应 provider。

### 8.1 输入输出

```swift
struct RAGRetrievalQuery {
    var text: String
    var scope: RAGScope = .knowledge
    var keywordTopK: Int = 30
    var vectorTopK: Int = 30
    var fusionTopK: Int = 20
    var rerankTopK: Int = 8
    var topRepoLimit: Int = 5
    var perRepoLimit: Int = 3
}

protocol RAGKeywordSearchProvider {
    func search(_ query: RAGRetrievalQuery, candidates: RAGRepoCandidateSet) async throws -> [RAGRetrievalHit]
}

protocol RAGVectorSearchProvider {
    func search(_ query: RAGRetrievalQuery, candidates: RAGRepoCandidateSet) async throws -> [RAGRetrievalHit]
}

protocol RAGHybridFusionEngine {
    func fuse(keywordHits: [RAGRetrievalHit], vectorHits: [RAGRetrievalHit]) -> [RAGRetrievalHit]
}

protocol RAGRerankProvider {
    func rerank(_ hits: [RAGRetrievalHit], query: String) async throws -> [RAGRetrievalHit]
}

struct RAGRepoCandidateSet {
    var repoIDs: Set<Int64>
    var sourceTypes: Set<RAGChunkSource>
    var paths: Set<String>
    var languages: Set<String>
    var updatedAfter: Date?
}

struct RAGRetrievalHit {
    var chunk: RAGChunk
    var repo: Repo
    var score: Double
    var displayScore: Double
    var reason: RAGRetrievalReason
}

struct RepoContextBundle {
    var repo: Repo
    var repoScore: Double
    var matchedChildren: [RAGRetrievalHit]
    var sectionParents: [RAGSectionParent]
    var notesChunk: RAGChunk?
    var summaryChunk: RAGChunk?
    var metadataChunk: RAGChunk?
    var remoteContextBlocks: [RAGRemoteContextBlock]
    var tokenBudget: Int
}

struct RAGRemoteContextBlock {
    var repoID: Int64
    var resource: RAGRemoteContextResource
    var title: String
    var content: String
    var sourceURL: URL?
    var fetchedAt: Date
    var isEphemeral: Bool
    var degradation: RAGRemoteContextDegradation?
}

enum RAGRemoteContextDegradation: Sendable {
    case unauthenticated
    case forbidden
    case rateLimited(resetAt: Date?)
    case timeout
    case networkError(String)
    case unsupported
}

struct RAGSectionParent {
    var parentKey: String
    var title: String
    var chunks: [RAGChunk]
    var matchedChunkIDs: Set<Int64>
}
```

`RAGScope` 第一版只有 `.knowledge`。保留 enum 是为了避免后续调试范围把字符串散落到 UI。

### 8.2 候选过滤

SQL 必须 join 当前知识库状态:

```sql
SELECT c.*
FROM rag_chunks c
JOIN repo_notes n ON n.repo_id = c.repo_id
WHERE n.library_state = 'in_library'
  AND c.embedding_model = ?
  AND c.embedding_status = 'ready'
  AND c.embedding IS NOT NULL
```

如果 `repo_notes` 已按账号隔离,查询必须沿用当前账号过滤规则,不能跨账号读取。

### 8.3 Hybrid Search Provider

第一版 provider:

| Provider | 默认实现 | 后续可选实现 |
|---|---|---|
| `RAGKeywordSearchProvider` | SQLite FTS5 | Meilisearch |
| `RAGVectorSearchProvider` | SQLite embedding BLOB + 本地 cosine | Qdrant |
| `RAGHybridFusionEngine` | RRF 或 weighted score | 可按 provider 能力调整 |
| `RAGRerankProvider` | off | Cohere / Jina / BGE / local reranker |

默认参数:

| 参数 | 默认 |
|---|---:|
| keyword topK | 30 |
| vector topK | 30 |
| fusion topK | 20 |
| rerank topK | 8 |
| llm context chunks | 5-8 |

Keyword search 负责精确词、库名、API、文件路径、错误码等问题。例如“有没有用 GRDB”“哪里提到 WKWebView”。Vector search 负责语义相近问题。例如“适合做本地数据库的 Swift 项目”。两者不能互相替代。

Fusion 第一版建议用 RRF:

```text
score = Σ 1 / (k + rank_i)
k = 60
```

如果实现成本要更低,也可以先用 weighted score:

```text
score = keywordScore * keywordWeight + vectorScore * vectorWeight + sourceBoost + metadataBoost
```

但无论使用哪种融合方式,UI Inspector 都要保留命中方式: keyword / vector / hybrid。这样用户能理解为什么某个 chunk 被召回。

### 8.4 Metadata Filter

Hybrid search 前必须先生成候选过滤条件,避免上下文污染。

必须支持:

| filter | 来源 |
|---|---|
| `repo_id` | 知识库边界、`@repo` 显式上下文、SQL repo filter |
| `source_type` | readme / notes / summary / metadata,后续 code / release |
| `language` | repo 主语言或代码文件语言 |
| `path` | README section / 文件路径,后续 code RAG 使用 |
| `updated_at` | README / source 更新时间 |
| `embedding_model` | 当前可用向量空间 |
| `embedding_status` | 只召回 ready |

对于 repo 级问答,最重要的是 `repo_id` 过滤。用户显式指定 `@repoA` 时,不能做全库无约束向量检索。

### 8.5 排序信号

复用 29 文档的 A+B+C 思路,但在 chunk 层实现:

| 信号 | 作用 |
|---|---|
| 向量 cosine | 主排序 |
| 字面命中 | query 命中 title/section/content 时 boost |
| FTS 命中 | chunk 或 repo 命中时排序加权 |
| hybrid fusion | keyword/vector 双路融合 |
| source 权重 | notes > summary > readme > metadata |
| per-repo cap | 每个 repo 最多 3 个 chunk |

### 8.6 Repo 聚合

child chunk 排序后,必须聚合到 repo。原因是 Starcat 的知识对象是 repo,不是独立文档段落。一个 repo 里命中 2-3 个 child chunks,通常说明这个 repo 整体与问题相关。

聚合流程:

```text
query
  -> keyword retrieval
  -> vector retrieval
  -> fusion
  -> optional rerank
  -> top child hits
  -> group by repo_id
  -> compute repoScore
  -> pick top repos
  -> pack RepoContextBundle per repo
  -> Generator
```

repoScore 建议:

```text
repoScore =
  max(child.score) * 0.60
  + avg(top 3 child.score) * 0.25
  + sourceBoost * 0.10
  + metadataBoost * 0.05
```

sourceBoost:

| 命中来源 | boost |
|---|---:|
| notes | 高 |
| summary | 中高 |
| readme | 中 |
| metadata | 低 |

metadataBoost 只做轻量加权,用于“热门 / 维护状态 / 语言 / tag”这类问题。不能让 star 数高的 repo 在内容不相关时越级进入答案。

默认输出:

| 参数 | 默认 |
|---|---:|
| child retrieval topK | 48 |
| top repos | 5 |
| per repo matched children | 3 |
| per repo section parents | 2 |

### 8.7 Parent Context Packing

生成阶段不直接吃 flat top chunks,而是吃 `RepoContextBundle`。

每个 bundle 按优先级打包:

1. repo metadata parent: fullName、description、language、topics、stars bucket、license、status、tags、是否 starred。
2. notes parent: 如果有用户笔记,优先放入。
3. summary parent: 如果已有 AI 摘要,放入。
4. matched child chunks: 精确命中的 child。
5. section parent: 命中 child 所属 README section 的相邻/完整上下文。

不同命中强度使用不同 parent 大小:

| repo 排名 / 场景 | 打包内容 |
|---|---|
| Top 1-2 repo | metadata + notes + summary + matched children + section parent |
| Top 3-5 repo | metadata + summary + matched children |
| 低分候选 | metadata + 命中 reason,默认不送 LLM |
| 单 repo 深问 | 可扩大到更多 section parent,受 token budget 限制 |

token 预算按 repo 分配,避免一个 README 垄断上下文:

```text
total_context_budget = 12000
repo_budget = weighted_by_repoScore(topRepos)
per_repo_hard_cap = 4000
```

如果某个 section parent 太长,按当前 chunk 顺序选取:

1. matched child。
2. matched child 前后 sibling chunks。
3. section 开头 chunk。
4. 超预算截断并在 Inspector 标记。

### 8.8 Citation 语义

LLM 回答按 repo 组织,但 citation 仍指向 child chunk。这样既能回答“哪个 repo”,又能让用户看到具体证据。

UI 展示:

- citation chip 主体显示 repo。
- Inspector 中显示 matched child。
- Inspector 同时显示所属 section parent。
- Inspector 显示命中方式: keyword / vector / hybrid / rerank。

这避免 citation 退化成“整个 repo 都算引用”,也避免答案只围绕碎片展开。

### 8.9 Reranker

第一版默认不做 reranker,但保留 `RAGRerankProvider`。理由:

- 先验证知识库范围和 citation 闭环。
- child 召回 + repo 聚合 + parent packing 已经能解决大部分上下文不足问题。
- 外部 reranker 会增加一次模型调用和隐私暴露。

后续策略:

| 模式 | 说明 |
|---|---|
| Off | 默认,无额外成本 |
| Cloud reranker | Cohere / Jina 等,需要明确发送哪些 chunk |
| Local reranker | 用户自行部署或本地模型,延迟较高但隐私更好 |

默认流程不要把 top 100 全塞给 LLM。建议先 fusion top 20,再 rerank top 8,最终送 LLM 5-8 个 chunk。

### 8.10 可选自托管后端

Meilisearch 和 Qdrant 作为高级可选后端,不作为第一版默认依赖。

| 后端 | 角色 | 适用场景 | Starcat 责任 |
|---|---|---|---|
| Local SQLite + FTS5 | 默认 keyword provider | 普通用户、本地优先 | Starcat 内置 |
| Local SQLite embedding | 默认 vector provider | README / notes / summary 小规模 RAG | Starcat 内置 |
| Meilisearch | keyword / hybrid search provider | 用户已有自托管搜索服务,希望增强全局搜索与 RAG keyword 召回 | 通过 REST API 连接 |
| Qdrant | vector search provider | 大规模 repo、代码 chunk、模型迁移、payload filter | 通过 REST API 连接 |

Starcat 不负责默认安装、启动、升级这些服务。用户自行部署后,在 Settings 中配置 endpoint / API key / index / collection。连接失败时只影响对应 provider,不能破坏本地默认 RAG。

### 8.11 无命中处理

无命中分三类:

| 类型 | 判断 | UI |
|---|---|---|
| 无索引 | 知识库有 repo,但无 embedding chunk | 引导构建索引 |
| 低相关 | top score 低于阈值 | 说明知识库资料不足,可去 GitHub/AnySearch 搜索 |
| 知识库为空 | repo 数为 0 | 引导加入知识库 |

## 9. Remote Ephemeral Context

### 9.1 定位

远程临时上下文用于回答“本地索引不适合长期保存,但本轮问题确实需要”的信息。典型例子是 GitHub issues: Starcat 不存储 issues,也不把 issues 做成 RAG chunk,但用户问“最近有没有集中反馈的问题”时,issues 可以作为临时上下文给 LLM。

边界:

- 不进入 `rag_chunks`。
- 不生成 embedding。
- 不写入 notes / summary / tags / status。
- 不作为 CloudKit 同步数据。
- 只在用户主动提问后,对本轮候选 repo 拉取。
- 可以做短 TTL 缓存,但缓存是网络降噪层,不是 RAG 索引。

### 9.2 Provider

新增 `KnowledgeRAGRemoteContextProvider`:

```swift
protocol KnowledgeRAGRemoteContextProvider {
    func fetch(
        requests: [RAGRemoteContextRequest],
        bundles: [RepoContextBundle]
    ) async -> [Int64: [RAGRemoteContextBlock]]
}
```

Provider 输入已经是 Retriever 选出的 `RepoContextBundle`,而不是全量知识库 repo。这样 issues / releases 等远程信息只补充候选 repo,不会扩大 RAG 范围。

第一版支持的 resource:

| resource | 数据来源 | 典型用途 |
|---|---|---|
| `github_issues` | GitHub Issues search / repo issues API | bug、crash、兼容性、用户反馈、已知问题 |
| `github_pull_requests` | GitHub Pull Requests API | 维护活跃度、最近修复、合并状态 |
| `github_releases` | GitHub Releases API | 版本、breaking change、更新节奏 |
| `github_contributors` | GitHub Contributors API | 维护者与社区参与 |
| `github_commit_activity` | GitHub commit/activity API | 最近是否活跃 |
| `github_security_advisories` | GitHub Security Advisories API | 漏洞、安全公告 |

### 9.3 拉取策略

默认策略:

| 参数 | 默认 | 上限 |
|---|---:|---:|
| remote repos | top 5 | 10 |
| issues per repo | 10 | 20 |
| PRs per repo | 10 | 20 |
| releases per repo | 5 | 10 |
| per resource timeout | 8s | 15s |
| remote context budget | 3000 tokens | 5000 tokens |
| TTL cache | 15 min | 1 hour |

拉取顺序:

1. Query Planner 输出 `remoteContextRequests`。
2. SQL / Retriever 先确定候选 repo。
3. Provider 只对 top repo 拉取远程数据。
4. Provider 把 raw JSON 转成 LLM 友好的文本块。
5. Service 将 `RAGRemoteContextBlock` 合并回对应 `RepoContextBundle.remoteContextBlocks`。
6. Generator 在 prompt 中明确区分 local indexed context 与 remote ephemeral context。

`structured_only` 也可以使用远程上下文,但必须先有 SQL 候选 repo。例如“列出我知识库里最近 issue 很活跃的 Swift 项目”可以先用 SQL 找 Swift 知识库 repo,再对候选 repo 拉取 issues 统计。不能反过来先全网搜 issue 再生成 repo 列表。

### 9.4 Issues 上下文格式

Provider 不把 GitHub raw JSON 直接送给 LLM,而是输出稳定文本:

```text
<remote_context resource="github_issues" repo="owner/repo" fetched_at="2026-07-03T12:30:00Z" ephemeral="true">
query=crash OR compatibility OR regression
sampled_open_issues=10
source=https://github.com/owner/repo/issues?q=...

issue #123 open updated=2026-07-02 comments=8 labels=bug,regression
title=Crash when opening large SQLite database
body_excerpt=...

issue #118 closed updated=2026-06-30 comments=5 labels=compatibility
title=macOS 15 compatibility problem
body_excerpt=...

observed_themes:
- 多个 issue 提到大文件打开时崩溃
- 兼容性问题集中在 macOS 15
</remote_context>
```

`observed_themes` 第一版可以用本地规则生成: 按 title/body_excerpt/label 的关键词聚合,不要为了远程数据再引入一次额外 LLM summarizer。后续如果确实需要,可以把远程上下文摘要作为独立优化项。

### 9.5 降级与错误

远程上下文是增强项,不是主证据链。失败时不能让整次 RAG 失败:

| 场景 | 处理 |
|---|---|
| GitHub token 缺失 | 返回 `unauthenticated` degradation block |
| 私有 repo 无权限 | 返回 `forbidden` degradation block |
| rate limit | 返回 `rateLimited` degradation block,带 reset 时间 |
| timeout / network error | 返回 degradation block,继续本地答案 |
| resource 不支持 | 丢弃该 request,记录 debug log |

Generator 必须看到 degradation block,并在答案中说明“GitHub Issues 暂时无法获取,以下结论仅基于本地知识库”。UI Inspector 也要展示远程上下文失败原因。

### 9.6 与本地索引的关系

远程上下文不改变 chunk 更新逻辑:

- README 更新仍由 `source = readme` 重建 chunks。
- notes 更新仍由 `source = notes` 重建 chunks。
- AI summary 更新仍由 `source = summary` 重建 chunks。
- repo metadata 更新仍由 `source = metadata` 重建 chunks。
- issues / PR / releases 不触发 chunk 重建。

如果未来决定把某类远程数据长期索引,必须作为新的 source 重新设计存储、权限、同步和清理策略,不能直接复用临时上下文缓存。

## 10. Generator

### 10.1 Prompt 约束

System prompt 核心约束:

```text
你是 Starcat 的知识库问答助手。
你只能基于给定的 Starcat 知识库片段和本轮远程临时上下文回答。

硬性约束:
1. 只能引用上下文中出现的 repo 和片段。
2. 提到关键 repo 时必须使用 [owner/repo] 引用标记。
3. 不知道就说知识库资料不足,不要编造。
4. 如果片段之间冲突,说明冲突并引用来源。
5. 默认用中文回答,除非用户用英文提问。
6. 不输出任何自动写入 tags、notes、status、star 或知识库状态的承诺。
7. 远程临时上下文只能作为本轮补充证据,不能当成已写入知识库的资料。
```

### 10.2 Context 格式

送入 LLM 的上下文按 repo bundle 组织,不是 flat chunks:

```text
<knowledge_context>
<repo id="101" full_name="groue/GRDB.swift" score="0.92">
  <metadata>
  language=Swift
  stars_bucket=5k+
  status=using
  tags=database,sqlite,swift
  description=...
  </metadata>

  <notes chunk_id="124" score="0.88">
  ...
  </notes>

  <summary chunk_id="125" score="0.84">
  ...
  </summary>

  <matched_children>
    <chunk id="123" source="readme" section="Installation" parent_key="readme:installation" score="0.91">
    ...
    </chunk>
  </matched_children>

  <section_parent key="readme:installation" title="README > Installation">
    <chunk_ref id="123" matched="true" />
    <chunk_ref id="126" matched="false" />
    <content>
    ...
    </content>
  </section_parent>

  <remote_context resource="github_issues" fetched_at="2026-07-03T12:30:00Z" ephemeral="true">
  ...
  </remote_context>
</repo>
</knowledge_context>
```

XML-like 格式便于:

- 明确 chunk id。
- 明确 repo parent 和 section parent。
- 明确 local indexed context 与 remote ephemeral context。
- 降低 repo/source/section 混淆。
- 后续 citation parser 校验。

Generator 的回答要求:

- 先按 repo 给出结论。
- 每个关键 repo 用 `[owner/repo]` 标记。
- 每个 repo 的依据来自 matched child 或 section parent。
- 如果使用 issues / releases 等远程上下文,必须说明这是本轮临时获取的信息。
- 不把不同 repo 的证据混成一个无法追踪的结论。

### 10.3 引用解析

LLM 输出中的 `[owner/repo]` 是人类可读引用。最终 citation 仍以 bundle 内 matched child chunk id 为准。

解析步骤:

1. 正则提取 `[owner/repo]`。
2. 与本轮 `RepoContextBundle.repo.fullName` 匹配。
3. 只保留本轮上下文出现过的 repo。
4. 为该 repo 绑定本轮 matched children 中分数最高的 1-3 个 chunks。
5. 如果 LLM 引用了上下文外 repo,标记为 invalid citation 并在 UI 隐藏该 chip。
6. Inspector 显示 repo parent、section parent 和 matched child,不只显示孤立 chunk。

### 10.4 Streaming

RAGService 对外提供:

```swift
func ask(_ question: String, conversationID: UUID?) -> AsyncThrowingStream<RAGRunEvent, Error>
```

事件:

```swift
enum RAGRunEvent {
    case planningStarted
    case planCreated(RAGQueryPlan)
    case clarificationRequired(String)
    case noResult(RAGNoResultState)
    case retrievalStarted
    case retrievalCompleted([RepoContextBundle])
    case remoteContextStarted([RAGRemoteContextRequest])
    case remoteContextCompleted([RepoContextBundle])
    case remoteContextDegraded([RAGRemoteContextBlock])
    case generationStarted
    case answerDelta(String)
    case citationUpdated([RAGCitation])
    case completed(RAGAnswer)
    case failed(String)
}
```

```swift
enum RAGNoResultState: Sendable {
    case noCandidateRepos(RAGQueryPlan)
    case noIndex(candidateCount: Int, plan: RAGQueryPlan)
    case noEvidence(candidateCount: Int, plan: RAGQueryPlan)
}
```

UI 在 planning 阶段显示“正在理解问题”,retrieval 阶段显示“正在检索知识库”,remote context 阶段显示“正在获取 GitHub 上下文”,generation 阶段 streaming markdown。`clarificationRequired` / `noResult` 都是终止态,不会继续调用 Generator。

## 11. 工作台 UI 设计

### 11.1 入口

新增覆盖式 `KnowledgeRAGWorkspaceView`,与 `AgentWorkspaceView` 同级。

接入建议:

- `HomeView` 增加 `showKnowledgeRAGWorkspace`。
- toolbar 增加 `知识库问答` 按钮。
- 未稳定前使用 `DebugFlags.ragWorkspaceEntryKey` 控制入口。
- Smart Collections -> 知识库页顶部动作也可打开同一 workspace。

不建议把 RAG 放进 Agent rail 作为唯一入口。Agent 是任务工作台,RAG 是高频知识问答。

### 11.2 布局

```text
┌────────────────────────────────────────────────────────────────┐
│ 左侧 Rail                  │ 中间 Answer Surface  │ 右侧 Evidence │
│ - 新会话                   │ - 用户问题            │ - 引用 repo    │
│ - 历史                     │ - Starcat 回答        │ - chunk 原文   │
│ - 范围: 知识库             │ - 追问输入            │ - 召回原因     │
│ - 索引覆盖率               │ - 状态/错误           │ - 打开详情     │
└────────────────────────────────────────────────────────────────┘
```

与 Agent Workspace 保持一致:

- 覆盖主窗口。
- 顶部可返回主界面。
- 使用 restrained desktop UI。
- 右侧 Inspector 承载可审计信息。

与 Agent Workspace 区分:

- 不展示 Agent 分类。
- 不展示任务 step card 作为主线。
- 主体是问答流和证据。

### 11.3 组件

| 组件 | 职责 |
|---|---|
| `KnowledgeRAGWorkspaceView` | workspace 壳子 |
| `KnowledgeRAGWorkspaceViewModel` | 状态、提问、取消、历史 |
| `RAGConversationRail` | 新会话、历史、范围、覆盖率 |
| `RAGAnswerSurface` | 问答流、streaming markdown、Command Composer 容器 |
| `RAGCommandComposerView` | 用户输入、repo mention、模型下拉、附件 |
| `RAGMentionPicker` | `@` repo list / command list 弹层 |
| `RAGContextChip` | 本轮上下文 chip,支持删除 |
| `RAGEvidenceInspector` | citations、chunks、retrieval hits、remote context |
| `RAGCitationChip` | 引用 chip,点击打开证据 |

### 11.4 状态

```swift
enum RAGWorkspaceStatus {
    case idle
    case planning
    case clarificationRequired(String)
    case checkingIndex
    case retrieving
    case fetchingRemoteContext
    case generating
    case completed
    case noCandidateRepos
    case noIndex
    case noEvidence
    case failed(String)
}
```

UI 必须覆盖:

- idle。
- 正在理解问题。
- 需要追问。
- 知识库为空。
- 索引缺失。
- 符合筛选条件但没有候选 repo。
- 有候选 repo 但没有 ready chunks。
- 有候选 repo 和 chunks 但没有足够证据。
- API key 缺失。
- 检索中。
- 获取 GitHub 临时上下文中。
- 生成中。
- 用户取消。
- 失败重试。

### 11.5 打开 repo

Citation chip 点击后的行为:

1. 右侧 Inspector 展示 chunk。
2. “打开详情”按钮关闭 RAG workspace 并选中对应 repo。
3. 如果 repo 不在当前 Manage 列表,跳转到 Smart Collections -> 知识库并选中。

这要求 ViewModel 能把 repo id 交给 Home 层处理,不要在 RAG UI 内重新实现详情页。

### 11.6 Remote Context 展示

当本轮使用 issues / releases / PR 等远程临时上下文时,Inspector 需要单独展示 Remote Context 区域:

- 标明 resource: GitHub Issues / Releases / Pull Requests 等。
- 标明 fetchedAt 与“本轮临时获取”。
- 展示 query、样本数量、source URL。
- 展示失败降级原因,例如 rate limit、无权限、网络超时。
- 不把 remote context 展示成已索引 chunk,也不提供“打开 chunk”动作。

Answer Surface 顶部的 Query Plan chips 可以显示“GitHub Issues 临时上下文”等 chip。用户删除该 chip 后重新执行,Planner 或本地执行层应跳过对应 `remoteContextRequests`。

### 11.7 Command Composer

RAG 输入框不应只是普通多行文本框,而应是 `RAGCommandComposerView`。它负责把用户的显式操作转成结构化上下文,再交给 `KnowledgeRAGService.ask(...)`。

布局建议:

```text
┌────────────────────────────────────────────────────────────┐
│ Context chips: @repoA  @repoB  GitHub Issues  Model: GPT-4.1 │
├────────────────────────────────────────────────────────────┤
│ 输入: @GRDB 和 @SQLite.swift 对比本地数据库能力...          │
├────────────────────────────────────────────────────────────┤
│ + 附件   模型下拉   发送                                    │
└────────────────────────────────────────────────────────────┘
```

#### 11.7.1 `@repo` mention

输入 `@` 弹出 repo picker:

- 默认只列知识库 repo。
- 支持搜索 `owner/name`、description、topics、language、tags、status。
- 支持键盘上下选择、Enter 插入、Esc 关闭。
- 支持多选 repo。
- 被选中的 repo 在输入框上方展示为 context chip。

执行语义:

- `@repoA @repoB 对比...` -> `explicitRepoIDs = [repoA, repoB]`, `explicitRepoMode = .only`。
- `参考 @repoA,再找类似项目` -> `explicitRepoMode = .prefer`。
- `不要考虑 @repoA` -> `explicitRepoMode = .exclude`。
- `.only` 模式下,SQL candidate 必须限制到这些 repo,即使 Query Planner 生成了更宽的筛选条件也不能越界。
- 如果 mention 的 repo 已不在知识库,UI 必须提示“不在知识库,默认不参与 RAG”,并让用户选择“打开详情”或“作为本轮临时外部链接”,不能静默加入 RAG。

#### 11.7.2 模型切换

Composer 内提供模型下拉:

- 默认使用 Settings -> AI 的 RAG chat model。
- 本轮切换只写入 `selectedModelID`,不修改全局设置。
- 模型不可用时直接标注原因: 缺 API key、不支持 vision、不支持附件、余额/订阅不可用。
- 如果用户上传图片但当前模型不支持 vision,发送前阻断并提示切换模型或移除图片。

#### 11.7.3 远程上下文确认

issues / releases / PR 等远程临时上下文由 Query Planner 根据自然语言判断,不是通过输入框命令触发。

交互流程:

1. 用户正常输入问题。
2. Planner 输出 `remoteContextRequests`。
3. UI 在 Query Plan chips 中显示“GitHub Issues 临时上下文”等 chip。
4. 用户可删除 chip。
5. 执行层只对保留下来的 remote request 拉取远程上下文。

这样用户不需要记命令,也能在真正联网前看到本轮会额外查什么。

#### 11.7.4 附件与图片

附件是本轮临时上下文,不进入 `rag_chunks`。

第一版交互:

- 支持拖拽或点击上传。
- 图片附件进入 `handling = .vision`。
- Markdown / txt / small PDF 可进入 `handling = .textContext`。
- 不支持的格式展示为 disabled chip,不能发送。
- 每个附件 chip 展示文件名、类型、大小、是否会发送给模型。
- 附件总大小和 token 预算必须有本地上限,超出时要求用户删除或压缩。

实现优先级可以分阶段:

1. 先做 UI 与数据结构。
2. 再支持图片 vision。
3. 再支持文本/PDF 提取。

#### 11.7.5 GitHub 链接识别

输入框和回答区都要识别 GitHub repo 链接。

输入框粘贴 GitHub 链接时:

| 链接状态 | UI | RAG 行为 |
|---|---|---|
| 已存在且已入库 | 转成 repo chip | 加入 `explicitRepoIDs` |
| 已存在但未入库 | 显示 known repo chip | 默认不参与 RAG,可打开详情或提示入库 |
| Starcat 未知 | 显示 external link chip | 默认只作为外部链接,点击打开 GitHub |

回答区展示 GitHub 链接时:

- 如果链接对应 Starcat 已有 repo,点击优先打开 Starcat repo 详情。
- 如果链接不是 Starcat 已有 repo,点击打开 GitHub。
- 对于已 star 未入库 repo,可以展示“加入知识库”动作,但 RAG 本轮回答不能自动修改 libraryState。

#### 11.7.6 上下文 chip

Composer 上方展示本轮上下文 chips:

- `Repo: owner/name`
- `Mode: only/prefer/exclude`
- `GitHub Issues`
- `GitHub Releases`
- `Model: ...`
- `Attachment: ...`

用户删除 chip 后,ViewModel 必须同步更新 `RAGComposerContext`,并重新生成 Query Plan 或重新执行。不能只删除 UI 展示。

## 12. 与 Agent 的联动

第一版不合并,但保留后续联动点:

- Agent 可调用 RAG retriever 作为 tool。
- RAG 回答中的“生成对比报告”可以转成 Agent 任务。
- Agent Artifact 可引用 RAG citations。
- RAG 不直接执行写入动作;如果需要“创建 tag / 加 notes”,转为 Agent suggested action,仍需用户确认。

## 13. Settings 与 Storage

Settings -> AI 建议增加:

- RAG 索引状态。
- 构建 / 暂停 / 重建按钮。
- 当前 embedding model。
- 知识库 repo 覆盖率。
- RAG Backend: Local / Custom。
- Keyword Search Provider: FTS5 / Meilisearch。
- Vector Store Provider: SQLite / Qdrant。
- Reranker: Off / Cloud / Local。
- Provider 连接测试。
- Provider 切换后的索引重建提示。

配置模型:

```swift
struct RAGBackendConfiguration: Codable, Sendable {
    var backendMode: RAGBackendMode
    var keywordProvider: RAGKeywordProviderKind
    var vectorProvider: RAGVectorProviderKind
    var rerankProvider: RAGRerankProviderKind
    var meilisearch: RAGMeilisearchConfiguration?
    var qdrant: RAGQdrantConfiguration?
    var privacyMode: RAGPrivacyMode
}

enum RAGBackendMode: String, Codable, Sendable {
    case local
    case custom
}

enum RAGKeywordProviderKind: String, Codable, Sendable {
    case fts5
    case meilisearch
}

enum RAGVectorProviderKind: String, Codable, Sendable {
    case sqlite
    case qdrant
}

enum RAGRerankProviderKind: String, Codable, Sendable {
    case off
    case cloud
    case local
}

struct RAGMeilisearchConfiguration: Codable, Sendable {
    var endpoint: URL
    var apiKeyReference: String?
    var indexName: String
    var semanticRatio: Double?
}

struct RAGQdrantConfiguration: Codable, Sendable {
    var endpoint: URL
    var apiKeyReference: String?
    var collectionName: String
    var vectorName: String
}

enum RAGPrivacyMode: String, Codable, Sendable {
    case localOnly
    case allowCloudEmbedding
    case allowRemoteRAGProviders
}
```

交互规则:

- 默认 `backendMode = local`,普通用户不需要配置外部服务。
- Meilisearch / Qdrant 放在高级设置,用户自行部署后填写 endpoint 和 key。
- API key 只存 Keychain,配置里只保存 reference。
- 点击“测试连接”必须检查 endpoint、认证、index/collection 是否存在、维度是否匹配。
- provider 切换后,如果索引不可复用,Settings 显示“需要重建 RAG 索引”。
- 私有 repo 安全模式默认 `localOnly`,不上传代码内容到云 embedding 或远程 RAG provider。
- 如果用户启用远程 provider,UI 必须提示哪些内容会被发送到该服务。

Settings -> Storage 建议增加:

- RAG chunk cache 大小。
- RAG conversation history 大小。
- 清除 RAG 索引。
- 清除 RAG 会话历史。

清除 RAG 索引只删除 `rag_chunks` embedding/cache,不影响:

- repo metadata。
- README cache。
- notes。
- AI summaries。
- repo-level semantic embeddings。
- libraryState。

## 14. 权限与隐私

- RAG 使用 BYOK 配置的 embedding/chat provider。
- 送到 embedding provider 的内容包括知识库 README/notes/summary chunk。
- 送到 chat provider 的内容包括用户问题、retrieved chunks、本轮远程临时上下文和用户主动添加的附件上下文。
- UI 需要明确这是用户主动使用 AI 问答时发生的外部模型调用。
- 本轮模型切换只影响当前 request 或当前会话,不修改全局 AI 设置。
- 用户上传的图片/附件只作为本轮临时上下文,不进入 RAG 索引、repo notes、AI summary 或 CloudKit。
- issues / PR / releases 等远程上下文只在用户提问触发后拉取,不做后台常驻抓取。
- 远程上下文只对候选 repo 拉取,不绕过知识库边界做全网搜索。
- 远程上下文短 TTL 缓存仅用于减少重复网络请求,不进入 RAG 索引或 CloudKit。
- 无权限私有 repo 不做远程拉取,只使用本地缓存,并在 Inspector 中展示降级原因。
- GitHub rate limit / 网络失败不能导致本地 RAG 失败,只能降级为“仅基于本地知识库回答”。
- 未登录态不允许读取用户私有知识库 RAG 范围。

## 15. 测试策略

### 15.1 Repository tests

- `rag_chunks` upsert / fetch / delete stale。
- 同 repo 多 source 多 chunk。
- child chunk 保存 parent_type / parent_key / parent_title。
- content_hash 不变时复用 embedding。
- 换 embedding model 后覆盖率变 stale。
- embedding_model / embedding_dim / provider / version 不匹配时不召回。
- 移出知识库后 chunk 保留但 retrieve 不召回。

### 15.2 Chunk builder tests

- README heading 切分。
- 小 section 合并。
- 大 section 按段落拆分。
- notes / summary / metadata chunk 生成。
- badge/image/table of contents 清理。

### 15.3 Query Planner tests

- 无筛选语义的问题返回 `semantic_only`。
- 筛选 + 语义问题返回 `filtered_semantic`。
- 只有筛选/排序的问题返回 `structured_only`。
- 模糊日期问题返回 `needs_clarification`。
- Planner invalid JSON 时重试一次。
- 重试仍失败时降级为 `semantic_only(original question)`。
- unsupported field 被丢弃;丢弃后 plan 无效则降级。
- 普通知识库问答返回空 `remoteContextRequests`。
- issues / release / PR 语义能返回对应 `remoteContextRequests`。
- remote request 超过本地上限时被钳制。
- SQL filter 0 repo 返回 `no_candidate_repos`。
- 候选 repo 无 ready chunks 返回 `no_index`。
- 有 chunks 但低相关返回 `no_evidence`。

### 15.4 Retriever tests

- 只召回 `libraryState == .inLibrary`。
- 已 star 但未入库 repo 不召回。
- 未 star 已入库 repo 可以召回。
- 只在 Query Planner 给出的 candidate repo ids 中检索。
- `explicitRepoMode = .only` 时只在 explicit repo ids 中检索。
- `explicitRepoMode = .exclude` 时排除 explicit repo ids。
- `.only` 模式下 explicit repo 无 ready chunks 返回 `no_index`,不扩大范围。
- keyword provider 能召回精确关键词。
- vector provider 能召回语义相近内容。
- fusion engine 能合并 keyword/vector 双路结果并去重。
- Inspector 所需命中方式包含 keyword / vector / hybrid。
- per repo limit 生效。
- source 权重生效。
- FTS boost 不改变 display score 语义。
- child hits 能按 repo_id 聚合。
- repoScore 使用 max child、top children average、source boost 和 metadata boost。
- `RepoContextBundle` 包含 metadata / notes / summary / matched children / section parents。
- top repo 的 section parent 能带入 sibling chunks。
- token budget 不允许单个 repo 吞掉全部上下文。

### 15.5 Backend configuration tests

- 默认 backend 是 Local。
- Meilisearch 配置缺 endpoint / index 时 validation 失败。
- Qdrant 配置缺 endpoint / collection / vectorName 时 validation 失败。
- provider API key 只保存 Keychain reference。
- health check 失败时回退本地 provider。
- provider 切换后索引状态进入 needs_rebuild。
- privacyMode = localOnly 时禁止把代码内容发送到远程 provider。

### 15.6 Remote Context tests

- 没有 remote request 时不调用 `KnowledgeRAGRemoteContextProvider`。
- remote provider 只接收 Retriever 选出的 top repo bundles。
- issues provider 输出 LLM 友好的文本块,不透传 raw JSON。
- issues provider 遵守 maxRepos / perRepoLimit / token budget。
- rate limit / timeout / forbidden 返回 degradation block,不抛出整轮失败。
- degradation block 能合并回对应 `RepoContextBundle.remoteContextBlocks`。
- remote context 不写入 `rag_chunks`。
- structured_only + remote request 必须先有 SQL 候选 repo。

### 15.7 Generator tests

- prompt 包含知识库边界约束。
- prompt 按 repo bundle 输出 context,不是 flat chunk 列表。
- prompt 区分 local indexed context 与 remote ephemeral context。
- 使用 remote context 时答案说明其为本轮临时获取的信息。
- remote degradation 时答案说明对应远程数据不可用。
- citation parser 只接受本轮 bundle 中的 repo。
- citation 能绑定到该 repo 的 matched child chunks。
- 上下文外 repo 引用被过滤。
- 无命中时不调用 chat 或返回明确不足状态。

### 15.8 UI/ViewModel tests

- 空知识库状态。
- 索引缺失状态。
- Query Plan chips 展示范围 / 筛选 / 排序 / 语义。
- Query Plan chips 展示远程临时上下文。
- `needs_clarification` 展示追问,不执行检索。
- `no_candidate_repos` / `no_index` / `no_evidence` 展示不同空状态。
- retrieval -> remote context -> generation -> completed 状态流。
- Remote Context 区域展示 fetchedAt / source URL / degradation。
- `@repo` mention 能生成 repo context chip。
- 多个 `@repo` 默认形成 `explicitRepoMode = .only`。
- 删除 repo context chip 后,执行上下文同步移除 repo id。
- Planner 提议 issues / releases 远程上下文时,UI 能展示可删除确认 chip。
- 删除远程上下文 chip 后,执行层跳过对应 remote request。
- 模型切换只影响本轮 request,不修改全局 Settings。
- 图片附件遇到不支持 vision 的模型时阻断发送。
- GitHub 链接已入库时转成 repo chip,未入库时不自动进入 RAG。
- 回答区 GitHub 链接命中 Starcat 已有 repo 时打开内部详情,否则打开外部 GitHub。
- cancel 能停止 streaming。
- citation 点击回调 repo id。

## 16. 实施切片

实施优先级:

- MVP 必做: PR-1、PR-2、PR-3 基础 planner、PR-4、PR-6、PR-7 基础工作台。
- MVP 后置: PR-5、PR-8、PR-7 中附件真实解析和远程上下文确认流程。
- 高级增强: PR-9、PR-10。

### PR-1: DB 与 chunk repository [MVP 必做]

- 新增 `RAGChunk` model。
- 新增 `rag_chunks` migration。
- 新增 `RAGChunkRepository`。
- 覆盖 upsert/fetch/delete/coverage tests。

### PR-2: Chunk builder 与索引器 [MVP 必做]

- 新增 `RAGChunkBuilder`。
- 新增 `RAGIndexBuilder`。
- 只处理知识库 repo。
- Settings 显示索引状态。

### PR-3: Query Planner 与执行状态机 [MVP 必做 / 远程上下文后置]

- 新增 `KnowledgeRAGQueryPlanner`。
- AI Planner 输出 `RAGQueryPlan` JSON。
- schema validation / retry / fallback。
- 支持 semantic_only / filtered_semantic / structured_only / needs_clarification。
- 输出 userVisiblePlan chips。
- 单测覆盖 planner mode、降级和无结果状态。

### PR-4: Retriever [MVP 必做]

- 新增 `KnowledgeRAGRetriever`。
- 新增 `RAGKeywordSearchProvider` / `RAGVectorSearchProvider` / `RAGHybridFusionEngine`。
- 接收 Query Planner 输出的 candidate repo ids。
- FTS5 keyword search + local vector search + hybrid fusion + source weight。
- child hits 按 repo 聚合并计算 repoScore。
- 输出 `RepoContextBundle`,而不是直接把 flat top chunks 交给 Generator。
- 单测覆盖知识库边界。

### PR-5: Remote Ephemeral Context [MVP 后置]

- 新增 `KnowledgeRAGRemoteContextProvider`。
- 支持 GitHub issues / PR / releases 的第一批 provider。
- Provider 只接收 top `RepoContextBundle`,不访问全量知识库。
- raw GitHub response 转成 LLM 友好的 `RAGRemoteContextBlock`。
- 支持 TTL cache、timeout、rate limit、permission 降级。
- 将 remote blocks 合并回 `RepoContextBundle.remoteContextBlocks`。
- 单测覆盖 issues 格式化、预算限制和降级。

### PR-6: Generator [MVP 必做]

- 新增 `KnowledgeRAGPromptBuilder`。
- 新增 `KnowledgeRAGService` streaming。
- 新增 citation parser。
- Prompt context 使用 repo bundle: metadata / notes / summary / matched children / section parent / remote context。
- 无命中 / API key 缺失 / 取消处理。

### PR-7: Workspace UI [MVP 必做 / 部分后置]

- 新增 `KnowledgeRAGWorkspaceView`。
- 新增 `RAGCommandComposerView`。
- 新增 `RAGMentionPicker`。
- 新增 `RAGContextChip`。
- 接入 toolbar / Debug gate。
- 展示 Query Plan chips 和 clarification / no result 状态。
- 支持 `@repo` mention 和多 repo context chips。
- 支持输入框模型下拉。
- 支持 Planner 远程上下文确认 chips。
- 支持附件 chip 的第一版 UI 和模型能力校验。
- 支持 GitHub 链接识别: 已有 repo 打开内部详情,外部 repo 打开 GitHub。
- 中间问答流 + 右侧 evidence inspector。
- 展示 Remote Context 区域和远程降级原因。
- citation chip 打开 repo。

### PR-8: 历史、Storage 与 polish [MVP 后置]

- 本地会话历史。
- 复制/导出回答。
- Settings 增加 RAG Backend / Provider 配置。
- Storage 清理入口。
- 覆盖率与错误文案完善。

### PR-9: 自托管检索 Provider [高级增强]

- 新增 Meilisearch keyword provider。
- 新增 Qdrant vector provider。
- Settings 支持 endpoint / API key / index / collection / vectorName。
- Provider health check。
- 连接失败回退本地 provider。
- provider 切换后标记索引需要重建。

### PR-10: Agent / MCP 后续联动 [高级增强]

- Agent runtime 可把 `KnowledgeRAGRetriever` 作为只读 tool。
- Agent Artifact 可引用 RAG citations。
- RAG 回答中的“生成对比报告”可转入 Agent Workspace。
- MCP 可暴露只读 RAG evidence 查询能力。
- 所有写入建议仍必须走用户确认。

## 17. 不做范围

第一版不做:

- 不做 starred/all 范围的正式 RAG UI。
- 不做通用联网 web RAG;只允许对本轮候选 repo 拉取受控的远程临时上下文。
- 不要求用户必须部署 Meilisearch / Qdrant。
- 不在第一版内置或托管 Meilisearch / Qdrant 进程。
- 不做本地 reranker 模型。
- 不做自动写 tags/notes/status/libraryState。
- 不做 CloudKit 同步 RAG 会话。
- 不把 RAG 合并进 Agent Workspace 作为唯一入口。
- 不把 repo-level semantic search 迁移为 chunk-level。

## 18. Swift 学习提示

后续实现时会涉及这些 Swift / SwiftUI / Concurrency 概念。dong4j 可以在 `docs/7-工具与脚本/Swift-学习索引.md` 查关键词:

- `AsyncThrowingStream`: `KnowledgeRAGService.ask(...)` streaming 事件。
- `@Observable`: `KnowledgeRAGWorkspaceViewModel` 状态驱动 UI。
- `GRDB Transaction`: `RAGChunkRepository.upsert(...)` 批量写入。
- `Codable`: RAG 会话 citation JSON。
- `Task.cancel`: 用户停止 RAG 生成。
