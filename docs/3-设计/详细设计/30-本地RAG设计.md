# 30 — 已 star 仓库本地 RAG 设计（探索性方案）

> 状态：探索性方案 v0.1（2026-06-15 dong4j 提议）
>
> 优先级：**P2 远期**——MVP 与 P1 不实现，本文档作为产品愿景与技术 roadmap 锚点。
>
> 关联文档：`29-关键词与全文检索设计.md` / `26-向量搜索改进.md` / `27-RepoContextPacker设计.md` / `28-搜索增强最终方案.md` / `14-AI集成落地记录.md` / `00-提示词设计.md`

---

## 1. 命题与价值

### 1.1 一句话定位

> 让用户**用自然语言提问**，从自己**已 star 的所有仓库**里检索答案，并由 LLM 生成**带引用**的回答。

### 1.2 解决的问题

dong4j 的 starred 项目超过 1810 个，传统问题：

- **数量已超过人脑容量**：星标只是收藏动作，不等于"用过 / 记得"。一个项目两年前 star 过，两年后想用时已经记不清是哪个 repo。
- **搜索是关键词驱动**：现有 FTS / 语义搜索是"列表式回忆"——用户得知道大致关键词。当用户只记得"我去年 star 过一个做 SSR 的"，搜索就吃力。
- **对比 / 综合 / 教学需求**：用户想问"我 star 过的项目里，哪几个是做向量数据库的，分别什么定位"，搜索给不出答案——它给的是**列表**，需要用户自己读 description 综合。
- **跨语言 / 跨术语**：用户用中文搜，但 README / description 都是英文；现有向量搜索可以缓解，但不能直接给出"用中文写的总结"。

### 1.3 典型问答场景

| 用户问题 | 期望答案形态 |
|---|---|
| "我 star 过的项目里，哪几个是做向量数据库的？" | 列出 3-5 个 repo + 一句话定位 + 引用链接 |
| "react 状态管理我 star 过哪些方案？分别什么定位？" | 对比表（Redux / Zustand / Jotai / Recoil 等），引用各 repo |
| "我去年想用但忘了的 SSR 框架是哪个？" | "你 2025 年 star 过 nuxt / next / fresh / sveltekit，根据你的笔记里提到 'edge function' 的关键词，最可能是 fresh"|
| "教我怎么用 starred 项目里那个 grpc-gateway" | 引用 grpc-gateway README 的 Hooks 章节 + 用户自己的笔记，给出步骤 |
| "我 star 过的 macOS 工具里，哪个支持 Liquid Glass？" | 跨 README + 用户笔记 + topics 综合，定位 1-2 个候选 |

### 1.4 不解决的问题

- **不是通用 ChatGPT**：不回答与 starred 仓库无关的问题。
- **不替代 LLM 知识库**：用户问"什么是 React Hooks"，应回去问 ChatGPT；本系统的价值是"用户自己 star 的项目集合"作为限定知识源。
- **不是代码生成器**：本系统不生成代码，只引用已有 README / 笔记内容回答。


## 2. 与现有搜索的差异

| 维度 | 现有搜索（29 文档）| 本地 RAG（本文档）|
|---|---|---|
| 输入 | 关键词 / 短句 | 自然语言问题（"哪个项目..." / "怎么用..."）|
| 输出 | repo 列表 + 评分徽标 | 自然语言回答 + 引用列表 |
| 模型调用 | 1 次 embedding（query 向量化） | 1 次 embedding + 1 次 long-context LLM |
| 时延 | ms~s 级 | 5-30 秒（含 LLM streaming）|
| 单次成本 | ~$0.0001（embedding） | $0.005-0.05（取决于 context 长度 + 模型）|
| 用户心智 | "找到 X 个相关 repo" | "我得到一个答案"|
| 缓存粒度 | embedding 已落库 | LLM 答案需另存（可选）|
| 隐私边界 | embedding API 见 query + 候选元数据 | embedding API 见 query；LLM 见 query + retrieved chunks（含私仓 README） |

**关键观察**：RAG 的检索阶段（retrieve）实际上**完全复用**现有向量搜索 + FTS5，所以**本地 RAG 是搜索的"加生成层"延伸**，不是另起炉灶。


## 3. 系统架构

### 3.1 三层管线

```
┌─────────────────────────────────────────────────────┐
│ Retriever 层 — 召回                                   │
│   - chunk-level 向量召回（D 方案）                     │
│   - FTS5 关键词召回                                    │
│   - 排序信号融合（A+B+C+RRF？）                         │
│ 产出：candidate_chunks (top-K, K ≈ 20-30)             │
└─────────────────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────┐
│ Reranker 层（可选） — 精排                             │
│   - cross-encoder / 便宜 LLM 打分                     │
│   - 把 top-30 缩到 top-5~10                          │
│ 产出：reranked_chunks (top-N)                         │
└─────────────────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────┐
│ Generator 层 — 长上下文 LLM 生成                       │
│   - prompt 注入 chunks + 引用约束                      │
│   - streaming 输出                                    │
│   - 解析内联引用 [owner/repo]                         │
│ 产出：assistant_message + cited_repos[]                │
└─────────────────────────────────────────────────────┘
                         │
                         ▼
                    UI 渲染
                  （markdown + 引用 chip）
```

### 3.2 数据流时序

```
用户提问
  │
  ├─ embed(query) → queryVector                   [Embedding API]
  ├─ searchFTS(query) → ftsHitIDs                  [本地 SQL]
  │
  ▼
对所有 candidate_repos 的所有 chunks 算 cosine
  ↓ 聚合 + B 字面 boost + C FTS 加权 + RRF
top-K chunks (20-30) [候选池]
  │
  ▼
（可选）reranker 精排
  ↓
top-N chunks (5-10) [送 LLM]
  │
  ▼
拼 prompt + streaming LLM call             [LLM API]
  ↓
streaming markdown 回答
  ↓
UI 增量渲染 + 末尾解析 [owner/repo] 内联引用 → chip 列表
  ↓
用户点 chip → 滑出 repo detail card
```

### 3.3 与现有模块复用关系

| 现有模块 | 在 RAG 里的角色 |
|---|---|
| `RepoEmbeddingRepository` | 升级为 `RepoChunkRepository`，多对一关联 repo |
| `IndexedTextBuilder` | 升级为 `ChunkBuilder`，按 markdown header 切段 |
| `IndexedTextDiff` | chunk-level diff，触发逐 chunk 重建 |
| `SemanticSearchService.search()` | retrieve 阶段直接复用（候选输入改为 chunks） |
| `FTSQuery.sanitize` + `searchFTS` | 关键词召回信号注入排序 |
| `RepoContextPacker`（详见 27） | LLM prompt 上下文打包，已有的 token 预算控制可以复用 |
| `AIService` chat / chatStream | LLM 调用（已 BYOK） |
| `Settings → AI → 阈值滑杆` | 复用为 retrieve 阈值 |


## 4. Retriever 层 — chunk-level 召回

### 4.1 chunk 拆分策略

输入：sanitize 后的 README markdown / AI 摘要 / 用户笔记 markdown。

**按 markdown 标题层级切**：

```
chunks = []
seen   = ""
header = ""

for line in markdown.lines:
    if line matches /^##+ /:
        if seen.tokenCount > MIN_CHUNK_SIZE: flush(seen, header)
        header = line.parsed_section_path     // "## Hooks > ### useState"
        seen   = line + "\n"
    else:
        seen   += line + "\n"
        if seen.tokenCount >= MAX_CHUNK_SIZE:
            flush(seen, header); seen = ""

flush(seen, header)
```

**参数**：

| 参数 | 默认 | 备注 |
|---|---|---|
| `MIN_CHUNK_SIZE` | 200 token | 太小的章节合并到下个 chunk |
| `MAX_CHUNK_SIZE` | 1000 token | embedding 模型 input 上限留余量 |
| 重叠（overlap）| 0 token | 简单切段不滑窗，节省 embedding 成本；后续可加 |

**特殊情况**：

- README 不到 1000 token：整个 README 作为 1 个 chunk，`section_path = ""`（根）
- 没有 `##` 标题：滑窗切（每 800 token 一段）作为 fallback
- 代码块（` ``` `内）：不在中间切，整段保留即使超过 MAX

### 4.2 chunk 数据 schema

新表 `repo_chunks`：

```sql
CREATE TABLE repo_chunks (
    id              INTEGER PRIMARY KEY,
    repo_id         INTEGER NOT NULL REFERENCES repos(id) ON DELETE CASCADE,
    chunk_index     INTEGER NOT NULL,        -- 同 repo 内序号 0-based
    section_path    TEXT NOT NULL DEFAULT '', -- 如 "## Installation > ### macOS"
    source          TEXT NOT NULL,           -- 'readme' | 'summary' | 'notes' | 'description'
    content         TEXT NOT NULL,
    content_hash    TEXT NOT NULL,           -- 用于精确 diff（chunk 内变了才重 embed）
    token_count     INTEGER NOT NULL,
    vector          BLOB,                    -- nullable，等待异步索引
    embedding_model TEXT,
    dim             INTEGER,
    indexed_at      TIMESTAMP,
    created_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (repo_id, chunk_index)
);

CREATE INDEX idx_repo_chunks_repo ON repo_chunks(repo_id);
```

### 4.3 召回流程

```
queryVector = embed(query)
ftsHitIDs   = searchFTS(query)

# 候选 chunks：所有有向量的 chunks
chunks = SELECT * FROM repo_chunks WHERE vector IS NOT NULL

scored = []
for c in chunks:
    cosine = cosine(queryVector, c.vector)
    literalHit = hasLiteralMatch(c.content, query)
    effective  = literalHit ? max(cosine, 0.95) : cosine
    ftsHit     = ftsHitIDs.contains(c.repo_id)
    sortScore  = effective + (ftsHit ? 0.10 : 0)            # FTS 信号在 chunk 层稍弱
    scored.append((c, sortScore, effective))

# 按 repo 聚合 + 跨 repo 排序
top_chunks_by_repo = take_top_per_repo(scored, max=3)        # 每 repo 最多 3 chunk
top_chunks_global  = sorted(top_chunks_by_repo, by=sortScore)[:RETRIEVE_TOP_K]
```

**RETRIEVE_TOP_K** 默认 **20**（约 20 chunks × 平均 600 token ≈ 12000 token，留 LLM 输出空间）。可在 Settings 暴露。

### 4.4 与 repo-level 索引的过渡

短期：repo-level 索引（当前）与 chunk-level 索引可**共存** — RAG 走 chunk，普通搜索走 repo。

中期：当 chunk 索引覆盖率 > 80% 时，普通向量搜索也切到 chunk 召回 + repo 聚合（取 max-cosine），retire repo-level 索引。

### 4.5 索引重建成本

| 项 | 估算 |
|---|---|
| repo 数 | 1810 |
| 平均 chunks / repo | 5 |
| 总 chunks | ~9000 |
| 平均 token / chunk | 600 |
| 总 input token | ~5.4M |
| OpenAI embedding-3-small 单价 | $0.02 / 1M token |
| **总成本（一次性）** | **~$0.11** |
| 时长（含限流，估算）| 30-60 分钟 |

成本可控。给用户的 UI 说明：「首次启用 RAG 需重建语义索引（约 $0.10，30-60 分钟），之后只在 README / 笔记变化时增量更新。」

### 4.6 增量更新

每次 README sanitize 后产出新版本：

```
1. 重新切 chunks
2. 与旧 chunks 按 chunk_index 对齐（不存在的 chunk 删除，新增的 INSERT）
3. 对齐位置上比较 content_hash：
   - 一致：vector / embedding_model 复用，不调 API
   - 不一致：mark for re-embed，加入待办队列
4. 后台 SemanticIndexCoordinator 处理待办
```


## 5. Reranker 层（可选）

### 5.1 何时需要

Retriever 召回 top-20 后，前 5 名内的精排有时不准——特别是 query 比较抽象（"我去年想用的 SSR 框架"）。Reranker 用更精细的模型对 top-K 重新打分。

### 5.2 三个候选方案

#### 方案 R1 — 跳过（不做精排）

直接把 top-20 送 LLM。**首选 MVP**。LLM 自己会从 chunks 里挑最相关的回答，相当于 LLM 兼任 reranker。

#### 方案 R2 — Cross-Encoder

用 `bge-reranker-base` 等模型本地推理，对 (query, chunk) pair 打分。

| 项 | 评估 |
|---|---|
| 模型大小 | 200-500 MB |
| 部署 | CoreML / ONNX 本地推理 |
| 推理时延 | 20 chunks × ~50ms = 1s |
| 隐私 | 完全本地 |
| 成本 | 0 |

**主要难点**：把 cross-encoder 转 CoreML 并集成到 macOS App，工程量大。

#### 方案 R3 — 便宜 LLM 打分

用 Haiku / Flash / Qwen-mini 做 batch scoring：

```
SYSTEM: 给下面 20 段文本对查询的相关度打分（0-100）。只输出 JSON 数组。
QUERY: <query>
CHUNKS:
[
  {"id": 0, "repo": "react", "section": "Hooks", "preview": "..."},
  ...
]

输出: [{"id": 0, "score": 85}, ...]
```

| 项 | 评估 |
|---|---|
| 单次成本 | ~$0.001 / 查询 |
| 时延 | ~2-5s |
| 隐私 | 见外部 LLM API |
| 成本 | 低 |

**优点**：实现简单，复用现有 `AIService` chat 通道。

### 5.3 推荐路径

P2 阶段 → R1（不做）  
P3 实验 → R3（便宜 LLM）  
长期目标 → R2（cross-encoder 本地化），与隐私第一原则对齐


## 6. Generator 层 — LLM 生成 + 引用约束

### 6.1 prompt 设计

```
SYSTEM:
你是 Starcat 用户的 starred 仓库知识库助手。
基于以下上下文片段回答用户问题。

【硬性约束】
1. 只引用上下文里出现的 repo，绝不编造仓库名、URL、API。
2. 每次提到一个 repo 时，用方括号引用语法 [owner/repo] 内联标注（紧贴 repo 名后）。
3. 上下文不足以回答时，明确说"在你 starred 的仓库里没找到相关信息"——不要瞎猜。
4. 用中文回答（除非用户用英文提问）。
5. 回答要简洁，能用列表 / 表格表达对比时优先用 markdown 表格。

【上下文】
[chunk 1] repo=facebook/react  section=## Hooks
{content}

[chunk 2] repo=vuejs/vue  section=## Reactivity
{content}

...

USER:
{用户问题}
```

### 6.2 引用解析

LLM 输出例：

```
你 star 过的状态管理方案有：

| 方案 | 定位 | 简评 |
|---|---|---|
| Redux [reduxjs/redux] | 老牌，FLUX 模式 | API 多，新项目慎选 |
| Zustand [pmndrs/zustand] | 极简，hooks-only | 推荐用于中小型应用 |
| Jotai [pmndrs/jotai] | atomic 模型 | React 友好 |

需要更详细的对比可以追问。
```

UI 渲染层用正则 `\[([\w.-]+/[\w.-]+)\]` 提取所有引用，渲染成可点击的 `RepoCitationChip`。点击 chip → 滑出该 repo 的 detail card。

### 6.3 上下文长度控制

`RepoContextPacker`（详见 27 文档）已经做了 token 预算控制。RAG 复用该模块：

```swift
let packer = RepoContextPacker(
    budget: model.maxContextTokens - SYSTEM_TOKENS - QUERY_TOKENS - REPLY_RESERVE,
    chunks: rerankedChunks
)
let context = packer.pack()                     // 自动按相关度截断
```

**典型预算**（以 GPT-4o 128k context 为例）：

| 段 | tokens |
|---|---|
| system prompt | 500 |
| query | 50-200 |
| reply reserve | 4000 |
| **chunks 余量** | **~123000** |

实际不会用满，避免成本爆炸。**软上限 12000 tokens / 请求**（Settings 可调），约 20 个平均 chunk。

### 6.4 streaming

复用现有 `AIService.chatStream` 接口。RAG 阶段：

- retrieve / rerank 是非 streaming（毫秒到秒级，UI 显示"思考中..." spinner）
- LLM 生成是 streaming，markdown 渐进渲染
- 引用 chip 在 streaming 完成后做一次性 parse + 展开

### 6.5 答案缓存

可选：相同 query hash + 相同 retrieved chunks hash 的请求 24h 内复用上次答案。

```sql
CREATE TABLE rag_answer_cache (
    query_hash       TEXT NOT NULL,
    chunks_hash      TEXT NOT NULL,
    model            TEXT NOT NULL,
    answer           TEXT NOT NULL,
    cited_repos_json TEXT NOT NULL,
    created_at       TIMESTAMP NOT NULL,
    PRIMARY KEY (query_hash, chunks_hash, model)
);
```

TTL 24h，超过失效。命中时跳过 LLM 调用，UI 显示"缓存答案"小标签。


## 7. UI / UX 设计

### 7.1 入口位置（三个候选）

| 候选 | 优点 | 缺点 |
|---|---|---|
| **A. 主搜索框 mode 三档**：默认 / AI 搜索 / **AI 问答** | 入口统一，复用 `SmartSearchField` 切换 | 三档 UI 拥挤；"搜索" vs "问答"心智差异大 |
| **B. 侧边栏顶部独立"问助手"按钮** | 心智清晰：搜索是搜索，问答是问答 | 多一个入口，新功能可见性中等 |
| **C. 独立 ChatView 标签页 / 窗口** | 完全沉浸式，多轮对话最舒服 | 与主列表割裂，跳出"管理 starred" 的使用流 |

> **推荐 B**：与现有列表心智正交，给 RAG 独立心智空间，又不脱离主窗口。

### 7.2 整体布局（候选 B 落地）

```
┌─────────────────────────────────────────────────────────────┐
│ ╔══════════╗ ┌───────────────────────────────────────────┐ │
│ ║          ║ │ 主列表（现有）                              │ │
│ ║ Sidebar  ║ │                                            │ │
│ ║          ║ │                                            │ │
│ ║ ─ All    ║ │                                            │ │
│ ║ ─ Tags   ║ │                                            │ │
│ ║ ─ Lang   ║ │                                            │ │
│ ║ ─ ...    ║ │                                            │ │
│ ║          ║ │                                            │ │
│ ║ ──────   ║ │                                            │ │
│ ║ 💬 问助手 ║ │                                            │ │
│ ║   3 个会话 ║ │                                            │ │
│ ╚══════════╝ └───────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

点击「问助手」进入 RAG 视图（替换主列表区域，不打开新窗口）。

### 7.3 RAG 视图布局

```
┌─────────────────────────────────────────────────────────────┐
│ ← 返回列表    │   问助手    │ + 新会话 │ 历史 ▾              │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│   ┌─────────────────────────────────────────────────────┐   │
│   │ 用户：我 star 过的项目里，哪几个做向量数据库？        │   │
│   └─────────────────────────────────────────────────────┘   │
│                                                              │
│   ┌─────────────────────────────────────────────────────┐   │
│   │ 助手：你 star 过的向量数据库相关项目主要有：           │   │
│   │                                                      │   │
│   │ | 项目 | 定位 |                                       │   │
│   │ |------|------|                                       │   │
│   │ | Qdrant [qdrant/qdrant] | Rust 写，开源高性能 |     │   │
│   │ | Chroma [chroma-core/chroma] | Python，AI 应用友好 | │   │
│   │ | Milvus [milvus-io/milvus] | 企业级，分布式 |        │   │
│   │                                                      │   │
│   │ 引用：3 个仓库                                        │   │
│   │ ┌─[qdrant/qdrant]─┐ ┌─[chroma-core/chroma]─┐ ┌─...─┐ │   │
│   │ │  ★★★★ 92%      │ │  ★★★★ 88%             │ │     │ │   │
│   │ └─────────────────┘ └─────────────────────┘ └─────┘ │   │
│   └─────────────────────────────────────────────────────┘   │
│                                                              │
│   [你想接着问什么...]  [继续问] [换一组] [导出 markdown]      │
└─────────────────────────────────────────────────────────────┘
```

### 7.4 引用 chip 交互

- **悬停**：显示 chunk preview（section_path + 前 3 行）
- **点击**：右侧滑出 repo detail card（同详情页 hero 区，含 description / topics / language / 用户笔记）
- **detail card 上的"在主列表打开"按钮**：跳回主列表并选中该 repo
- **chip 上的★评分**：来自 retrieve 阶段的 displayScore，与列表语义一致

### 7.5 流式渲染

LLM 输出 streaming，markdown 增量渲染：

- 表格 / 代码块 / 列表 在边界完整后渲染（避免半行表格闪烁）
- `[owner/repo]` 引用在出现时立即识别，但 chip 列表延迟到一段消息完成后展开
- 进度指示：retrieve 中显示"正在召回 starred 仓库..."；LLM 生成中显示打字光标

### 7.6 多轮对话

- 同一会话内的后续问题携带前面 N 条消息上下文
- 默认**不重新 retrieve**：上一轮已检索到的 chunks 复用（节省成本 + 让多轮聚焦同一主题）
- 用户点「换一组」按钮 → 强制重新 retrieve（query 用最近一条 user message）
- 默认携带最多 4 轮对话历史，超出滚动 oldest first 截断

### 7.7 知识盲点处理

LLM 答不出（"我没在你 star 的仓库里找到相关信息..."）→ UI 自动给两个跳转建议：

```
┌─────────────────────────────────────────────────────┐
│ 在你的 starred 里没找到相关项目。要不要：             │
│                                                      │
│   [ 在 GitHub 全网搜索 ]   [ 在 AnySearch 中搜索 ]    │
└─────────────────────────────────────────────────────┘
```

第一个跳到 `SearchCenter`（已有 GitHub 搜索集成），第二个跳到 AnySearch web 搜索（已有集成）。

### 7.8 历史会话

会话列表存 SQLite（不进 CloudKit，本地隐私优先）：

```sql
CREATE TABLE rag_sessions (
    id          INTEGER PRIMARY KEY,
    title       TEXT NOT NULL,            -- 自动从首问生成（首 30 字符）
    created_at  TIMESTAMP NOT NULL,
    updated_at  TIMESTAMP NOT NULL,
    message_count INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE rag_messages (
    id          INTEGER PRIMARY KEY,
    session_id  INTEGER NOT NULL REFERENCES rag_sessions(id) ON DELETE CASCADE,
    role        TEXT NOT NULL,            -- 'user' | 'assistant'
    content     TEXT NOT NULL,
    cited_repos_json TEXT,                -- assistant 消息的引用列表 snapshot
    chunks_used_json TEXT,                -- assistant 消息用的 chunks (id list)
    created_at  TIMESTAMP NOT NULL
);
```

侧边栏「问助手」按钮下展开会话列表（最近 10 条），更多走 `历史 ▾` 弹窗。

### 7.9 Token / 成本透明化

每次提问前在输入框下方显示估算：

```
[输入框：问个问题...]
   预估：$0.008 / 12k tokens
```

LLM 完成后实际消耗显示在消息下方：

```
助手回答（实际消耗：$0.012 / 14.2k in / 1.8k out）
```

让用户对成本有感。Settings 可设月度预算上限，超出弹警告。

### 7.10 隐私提示

- 私仓 README 进 RAG context 前 → 弹一次性确认（"私仓内容会发送给你配置的 LLM provider"）
- Settings 提供"私仓默认不进 RAG"开关（默认开）


## 8. 功能列表（按优先级）

### 8.1 P0 — 核心可用（MVP of RAG）

| 功能 | 说明 |
|---|---|
| 单轮 QA | 用户问 → retrieve → LLM 答 → 引用 chip |
| chunk-level 索引重建（D 方案）| 一次性后台跑完，复用现有 SemanticIndexCoordinator 异步骨架 |
| 引用 chip 跳详情 | `[owner/repo]` 解析 + chip 渲染 + 点击滑出 detail card |
| BYOK 复用 | 沿用现有 AI 配置 |
| 隐私提示 | 私仓默认不进 context；首次启用引导 |
| 流式渲染 | LLM streaming + 打字光标 |
| Token / 成本透明 | 输入预估 + 答后实际 |

### 8.2 P1 — 体验增强

| 功能 | 说明 |
|---|---|
| 多轮对话 | 携带前 4 轮历史；默认复用上轮 retrieve |
| 历史会话保存 | sqlite 本地，不进 CloudKit |
| 引用 hover preview | chunk 前 3 行预览，避免每次都点开 |
| "继续问" / "换一组" 快捷按钮 | 区分追问与重新检索意图 |
| 答案缓存 | 相同 query+chunks hash 24h 复用 |
| 知识盲点跳转 | 跳 GitHub 搜索 / AnySearch |
| 月度预算上限 | Settings 配置 + 超出警告 |
| 多语言切换 | 中 / 英 / 跟随系统 |

### 8.3 P2 — 高级

| 功能 | 说明 |
|---|---|
| 答案对比模式 | "X 和 Y 哪个更适合 macOS App"——retrieve 时强制各召回 ≥3 chunk |
| 自动追问建议 | 答完后 LLM 给 3 个 follow-up 问题，点击直接发送 |
| 答案导出 markdown | 一键复制 + 含引用 |
| 答案分享 share card | 渲染含 starred 标识的图片，可保存 / 分享 |
| 跨语言 query 改写 | F 方案的 RAG 版：自动加同义改写 |
| reranker（R3 LLM 打分）| 可选打开，提升 top-K 精度 |
| 多模型对比 | 同一问题多 provider 并行答，UI 横向对比 |

### 8.4 P3 — 远期 / 实验

| 功能 | 说明 |
|---|---|
| LLM 自动给 starred 打类目标签 | 与现有 AI 标签整合，做"语义簇" 视图 |
| 主动提醒 | "你 star 过 X 但 6 个月没看，README 最近有大更新"（结合 status / lastViewed） |
| voice input / TTS output | macOS Speech API |
| 跨用户知识共享 | 去标识化的"用户群体常 star 的向量数据库 top-3"——产品化大跨度 |
| 自托管 LLM 路径 | 本地 Ollama / LM Studio 默认 + 隐私首选 |
| reranker（R2 cross-encoder）| 完全本地化的精排 |
| 主动学习 | 用户对 RAG 答案点赞 / 反馈，调整 retrieve 排序权重 |


## 9. 隐私 / 成本 / 风险

### 9.1 数据外发清单（必须告知用户）

| 数据 | 发往 | 频率 |
|---|---|---|
| 用户 query 文本 | embedding API + LLM API | 每次提问 |
| retrieve 出来的 chunks（含 README / 笔记 / 私仓内容）| LLM API | 每次提问 |
| repo metadata（fullName / topics / language）| LLM API（嵌在 chunks 里）| 每次提问 |
| 不发：tags 数据 / 状态 / 浏览记录 / 邮箱 / 用户 ID | — | — |

### 9.2 隐私机制

| 机制 | 默认 |
|---|---|
| 私仓 README / 笔记不进 RAG context | **开**（用户可关闭，需明确确认）|
| 用户笔记不进 RAG context | 默认进（笔记本来就是用户写的，且对个性化回答价值高）；可在 Settings 单独关 |
| 答案缓存仅本地 | 一律本地，不进 CloudKit |
| 历史会话仅本地 | 一律本地，不进 CloudKit |
| BYOK | 沿用现有，自带 endpoint / key（用户 vs LLM provider 之间，Starcat 不中转）|

### 9.3 成本风险

| 场景 | 单次成本（USD）|
|---|---|
| 普通搜索（embedding 1 次）| ~$0.0001 |
| RAG 单轮（GPT-4o-mini, ~12k context, 1k 输出）| ~$0.005 |
| RAG 单轮（GPT-4o, ~12k context, 1k 输出） | ~$0.05 |
| RAG 单轮（Claude 3.5 Sonnet）| ~$0.04 |
| **首次 chunk 索引重建**（一次性）| ~$0.10 |

**建议默认**：

- 默认 LLM = `gpt-4o-mini` 或 `qwen-flash` 等便宜模型
- 设置月度上限默认 $5
- 首次启用 RAG 时弹一次成本说明 + 用户确认

### 9.4 LLM hallucination 风险

即使有"硬性约束 1：只引用上下文里出现的 repo"，LLM 仍可能：

- 编造不存在的 owner/repo
- 张冠李戴（把 A 仓库的特性归给 B 仓库）
- 拒绝回答时态度不好（"这个问题超出我的能力"）

**缓解机制**：

1. **引用解析后做存在性校验**：UI 渲染前先把 `[owner/repo]` 与 cited_repos 与 retrieved chunks 中的 repo_id 对齐，对不上的 chip 标灰 + 显示警告
2. **chunks 中带 repo 标签**：prompt 里每段开头 `[chunk N] repo=X/Y section=Z`，让 LLM 复述时对齐
3. **Reply reserve token 不要太小**：截断让 LLM 编造的概率上升

### 9.5 已知风险点 / 待解决问题

| 风险 | 缓解 |
|---|---|
| LLM context window 不够（16k / 32k 模型）| 软上限 12k chunks，超出时缩 K + 截 chunk |
| chunk 切分破坏代码块语义 | 切段时遇到 ` ``` ` 块整段保留 |
| 首次重建索引时间过长 | 后台异步 + 进度条 + 可暂停 / 恢复 |
| 用户问与 starred 完全无关 | 拒绝回答 + 跳转外部搜索 |
| 多轮对话耗 token | 配置最多保留 N 轮 + 旧轮转 summary 压缩 |
| OpenAI / Anthropic 模型涨价 | UI 显式价格 + 用户可换 provider |


## 10. 落地路线

### 10.1 阶段拆分（推荐路径）

```
Phase 0：基础设施（现状）
  ├─ FTS5 双表 + BM25 ✓                         [29 文档已落]
  ├─ 向量索引 repo-level + A+B+C 重排序 ✓        [29 文档已落]
  └─ RepoContextPacker 上下文打包 ✓              [27 文档已落]

Phase 1：chunk-level 索引（D 方案）           — 4-6 周
  ├─ 新表 repo_chunks + 触发器
  ├─ ChunkBuilder (markdown header 切段 + 滑窗 fallback)
  ├─ 索引重建队列 + 进度 UI
  ├─ chunk-level 召回（与 repo-level 共存）
  └─ 测试：chunk 切段稳定性 / 索引膨胀监控

Phase 2：RAG MVP（P0 功能）                  — 6-8 周
  ├─ 「问助手」入口 + RAG 视图
  ├─ 单轮 QA（retrieve + LLM + 引用 chip）
  ├─ 流式渲染 + cost 透明
  ├─ 隐私确认流
  └─ 测试：hallucination 防护 / 引用对齐校验

Phase 3：体验增强（P1 功能）                 — 4-6 周
  ├─ 多轮对话 + 历史会话
  ├─ "继续问" / "换一组" 按钮
  ├─ 答案缓存
  ├─ hover preview
  └─ 月度预算上限

Phase 4：高级功能（P2 / P3 选做）            — 随产品迭代
  ├─ 答案对比模式
  ├─ 自动追问建议
  ├─ reranker（R3 → R2）
  ├─ 多模型对比
  └─ 跨语言 query 改写
```

### 10.2 短路路径（最快验证产品价值）

如果想跳过 Phase 1 chunk 切分这层（工程量较大），快速验证 RAG 是否有产品价值：

```
Phase 1' (短路，2-3 周)
  ├─ 复用现有 repo-level 向量索引
  ├─ retrieve 阶段直接拿 top-K repos（K=5-8）
  ├─ context = 这些 repo 的整段 README（每条限 5K token）
  ├─ 不做 chunk 切分，整段送 LLM
  └─ 接受语义稀释问题，看用户真实使用反馈
```

**优点**：极快上线（工程量减半），早期验证 dong4j 的产品假设。
**代价**：

- 长 README 的语义稀释问题，retrieve 准确度降低
- 单次 context 贵（8 个 repo × 5K = 40K token / 请求 → ~$0.20 GPT-4o）
- 后续切到 chunk-level 时数据迁移成本

> **建议**：先做 Phase 1 标准路径（chunk-level）。短路路径只在 dong4j 想"两周内拿到 demo 走通效果" 时考虑。

### 10.3 决策点（dong4j 拍板）

本文档定位是产品愿景与 roadmap 锚点，进入 Phase 1 实施前需要 dong4j 确认下列决策：

1. **入口形态**：候选 A / B / C（推荐 B：侧边栏「问助手」按钮）
2. **首次索引重建成本承受度**：~$0.10 一次性 + 30-60 分钟后台
3. **默认 LLM**：`gpt-4o-mini` / `qwen-flash` / 用户自己选
4. **私仓策略**：默认禁 / 默认允许 + 提示
5. **路线选择**：标准路径（Phase 1 → 2 → 3）/ 短路路径（直接 RAG MVP）
6. **是否进入 P1 计划**：MVP 上线后 vs 拖到 Phase 2 完整 release

### 10.4 与现有产品的整合

| 现有功能 | 与 RAG 的关系 |
|---|---|
| **AI 摘要**（单仓库摘要）| RAG 把多个 AI 摘要作为 chunk 来源之一（高质量信号）|
| **AI 标签推荐** | RAG 会问"这个项目可能的标签"——已经有 AI 标签时直接拼进 prompt 减召回 |
| **Release 订阅追踪** | RAG 答案可参考最新 release notes（chunk 来源扩展）|
| **AnySearch web 搜索** | RAG 答不出时跳转兜底；RAG 上下文与 web 搜索相互补 |
| **GitHub 全网搜索** | 同上，作为外跳兜底 |
| **CloudKit 同步** | RAG 历史会话**不进** CloudKit（隐私敏感）|

---

## 11. 文档关系与终态

本文档与 `26 / 27 / 28 / 29` 形成完整搜索 → 语义 → RAG 三阶段：

```
26 — 向量搜索改进         [基础：indexedText 三段 + diff 阈值]
27 — RepoContextPacker    [基础：长上下文打包 + token 预算]
28 — 搜索增强最终方案      [整合：FTS + 向量 + UI 阈值]
29 — 关键词与全文检索设计  [实施完成 2026-06-14]
30 — 本地 RAG 设计 (本)   [探索性，P2 远期]
```

文档保持探索性定位 —— 落地实施时再单独建 `XX-RAG MVP 实施记录.md` 记录具体决策与代码位置。

