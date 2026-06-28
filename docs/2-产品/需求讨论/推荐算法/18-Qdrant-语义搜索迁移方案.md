# Starcat：从本地 SQLite 向量检索迁移到 Qdrant 的技术方案

> 目标：说明 Starcat 现有“本地 SQLite 存储向量 + 本地语义检索”的方案，后续如何演进为“Go 后端 + Qdrant 公共语义检索/推荐服务”，同时保留本地私有数据检索能力。

---

## 1. 背景

Starcat 当前已有一套本地语义检索链路：

```text
Starcat macOS App
    ↓
调用服务商 Embedding API
    ↓
拿到 embedding vector
    ↓
写入用户本地 SQLite 数据表
    ↓
语义检索时在本地做 vector similarity 查询
```

这个方案本质是一个 **本地轻量向量检索方案**。

它的优点是：

| 优点 | 说明 |
|---|---|
| 离线可用 | 用户本地缓存和私有数据可以直接检索 |
| 隐私较好 | 向量和文档默认留在用户机器 |
| 架构简单 | Starcat App 自己完成 embedding 写入和检索 |
| 成本低 | 不需要后端向量数据库 |

它的限制是：

| 限制 | 说明 |
|---|---|
| 不适合大规模公共数据 | SQLite 中做向量检索，数据量大后性能和索引能力有限 |
| 重复计算 | 每个用户都可能对同一个公开 repo 重复计算 embedding |
| 跨用户不可复用 | Trending、Show HN、AI 频道等公共数据无法沉淀成统一服务 |
| 不适合推荐系统 | 相似仓库、positive/negative recommend、多路召回更适合 Qdrant |
| 过滤和排序能力有限 | Qdrant 的 payload filter、payload index、named vectors、hybrid search 更适合服务端检索 |

---

## 2. Qdrant 能不能承接现在 SQLite 中的向量数据？

可以。

Qdrant 的核心数据模型是：

```text
Collection
  └── Point
        ├── id
        ├── vector
        └── payload
```

也就是说，Starcat 现在 SQLite 中的向量记录，可以迁移成 Qdrant 的 point。

例如当前 SQLite 表可能是：

```sql
repo_embeddings
- id
- repo_id
- chunk_id
- embedding_model
- embedding_dim
- vector
- text
- metadata
- content_hash
- created_at
- updated_at
```

迁移到 Qdrant 后可以变成：

```json
{
  "id": "repo_41881900_readme_0001",
  "vector": [0.012, -0.031, 0.087],
  "payload": {
    "repo_id": 41881900,
    "full_name": "microsoft/vscode",
    "doc_type": "readme",
    "chunk_id": "readme_0001",
    "text": "...",
    "language": "TypeScript",
    "stars": 170000,
    "archived": false,
    "source": "github",
    "embedding_model": "text-embedding-xxx",
    "embedding_dim": 1536,
    "content_hash": "sha256...",
    "updated_at": 1782000000
  }
}
```

Qdrant 支持 point 的 upsert、update、delete、retrieve；point 可以包含 vector 和 JSON payload，payload 又可以用于过滤、补充结果展示和业务排序。

---

## 3. 术语澄清：这不是“全文检索”，而是“语义检索”

如果把 SQLite 中的向量迁移到 Qdrant，它主要解决的是：

```text
用户输入自然语言 query
    ↓
生成 query embedding
    ↓
在 Qdrant 中查找向量最相似的 repo / chunk
```

这更准确地叫：

> 语义检索 / 向量相似度检索

不要把它和传统“全文检索”混在一起。

| 检索类型 | 推荐组件 | 查询方式 | 典型场景 |
|---|---|---|---|
| 关键词全文检索 | Meilisearch / SQLite FTS | 按词匹配、拼写容错、过滤、分面 | 搜 repo 名、关键词、topics、README 关键词 |
| 语义检索 | Qdrant | query → embedding → vector similarity | 搜“适合 SwiftUI 的 GitHub 客户端” |
| 相似推荐 | Qdrant | positive repo id / vector → similar repo | 相似仓库、技术选型候选扩展 |
| 混合搜索 | Meilisearch + Qdrant，或 Qdrant dense+sparse | 关键词 + 语义融合 | 搜索体验增强 |

Qdrant 也支持 dense + sparse 的 hybrid search，但 Starcat 早期更建议职责拆开：

```text
Meilisearch = 关键词 / 全文搜索
Qdrant      = 语义检索 / 相似推荐
SQLite FTS  = 本地离线关键词搜索
SQLite Vec  = 本地私有语义检索
```

---

## 4. Starcat 是否应该把本地向量全部迁移到 Qdrant？

不建议一刀切。

更推荐按数据属性拆分：

```text
公共数据 → 服务端 Qdrant
用户私有数据 → 本地 SQLite 向量表
```

---

## 5. 哪些数据适合迁移到服务端 Qdrant？

适合迁移的主要是 **公共 repo 数据**。

包括：

```text
GitHub Trending repo
GitHub Search 已收录 repo
Show HN 中抓取到的 GitHub repo
Product Hunt 中关联的 GitHub repo
Starcat AI 频道项目
公开 README 摘要
公开 AI Summary
公开 repo analysis
公开技术栈标签
公开相似仓库推荐向量
```

这些数据适合服务端统一构建 embedding 并写入 Qdrant。

原因：

| 原因 | 说明 |
|---|---|
| 避免重复计算 | 同一个公开 repo 不需要每个用户都算一次 embedding |
| 统一搜索体验 | 所有用户共享 Starcat 的公共语义索引 |
| 推荐系统基础 | 相似仓库、技术选型推荐、相关项目发现都依赖公共向量库 |
| 方便更新 | README / AI Summary 变化后服务端统一重新 embedding + upsert |
| 方便和 Meilisearch 融合 | 后端可以同时查关键词搜索和语义搜索 |

---

## 6. 哪些数据不建议默认迁移到服务端 Qdrant？

用户私有数据建议继续留在本地，除非后续明确做云同步，并且在产品隐私策略中告知用户。

包括：

```text
用户收藏
用户备注
用户自定义标签
用户自己的 repo 分析记录
用户私有 GitHub repo
用户本地 clone 的代码摘要
用户对话上下文
用户技术选型草稿
用户本地导入的文档
```

推荐策略：

| 数据 | 推荐存储位置 |
|---|---|
| 公共 repo 信息 | PostgreSQL + Meilisearch + Qdrant |
| 公共 README summary | PostgreSQL + Qdrant |
| 公共 AI Summary | PostgreSQL + Meilisearch + Qdrant |
| 用户收藏 | 本地 SQLite，后续可选云同步 |
| 用户备注 | 本地 SQLite |
| 私有 repo 分析 | 本地 SQLite |
| 最近浏览缓存 | 本地 SQLite |
| 私有向量 | 本地 SQLite 向量表 |

---

## 7. 推荐的 Starcat 搜索架构

不要让 Starcat macOS App 直接连接自托管 Qdrant。

推荐新增一个 Go Search Backend：

```text
Starcat macOS App
    ↓
Starcat Search Backend（Go）
    ├── Meilisearch：关键词 / 全文搜索
    ├── Qdrant：语义检索 / 相似推荐
    ├── PostgreSQL：repo 主数据
    ├── Redis：缓存
    └── Embedding Provider：OpenAI / Jina / Voyage / 本地模型
```

这样设计的好处：

| 好处 | 说明 |
|---|---|
| API key 不暴露 | Qdrant key、Embedding Provider key 不放客户端 |
| 方便切换模型 | 后端统一控制 embedding model version |
| 方便缓存 | query embedding 和搜索结果都可以缓存 |
| 方便融合搜索 | 后端可以合并 Meilisearch、Qdrant、GitHub Search、AnySearch |
| 方便权限控制 | 公共索引和用户私有索引分开处理 |
| 方便灰度 | 新 collection、新 embedding model 可以在后端切换 |
| 方便运维 | Qdrant/Meilisearch 只暴露给内网或后端服务 |

---

## 8. Qdrant Collection 设计

不建议把所有向量混在一个 collection。应按用途拆分。

---

### 8.1 `repo_content_v1`

用途：仓库级语义搜索和相似仓库召回。

一个 repo 一个向量。

构造文本：

```text
Repository: owner/repo
Description: ...
Topics: ...
Language: ...
README Summary: ...
AI Summary: ...
```

适合查询：

```text
macOS GitHub client
AI agent framework
RAG evaluation tool
SwiftUI developer tool
open source search engine
```

Point 示例：

```json
{
  "id": 41881900,
  "vector": [0.01, -0.02, 0.03],
  "payload": {
    "repo_id": 41881900,
    "full_name": "microsoft/vscode",
    "owner": "microsoft",
    "name": "vscode",
    "language": "TypeScript",
    "topics": ["editor", "typescript", "electron"],
    "stars": 170000,
    "archived": false,
    "doc_level": "repo",
    "embedding_model": "text-embedding-xxx",
    "embedding_dim": 1536,
    "content_hash": "sha256...",
    "updated_at": 1782000000
  }
}
```

---

### 8.2 `repo_chunks_v1`

用途：README / AI 分析报告 chunk 级语义检索。

一个 repo 多个 chunk。

适合：

```text
AI 问答
README 片段召回
项目安装方式检索
项目技术栈检索
功能细节检索
```

Point 示例：

```json
{
  "id": "41881900:readme:0001",
  "vector": [0.01, -0.02, 0.03],
  "payload": {
    "repo_id": 41881900,
    "full_name": "microsoft/vscode",
    "doc_type": "readme",
    "chunk_index": 1,
    "section_title": "Installation",
    "text": "...",
    "language": "TypeScript",
    "stars": 170000,
    "archived": false,
    "embedding_model": "text-embedding-xxx",
    "content_hash": "sha256..."
  }
}
```

---

### 8.3 `repo_behavior_v1`

用途：后期推荐模型训练之后的行为向量。

一个 repo 一个行为向量。

来源：

```text
GitHub star 共现
Starcat 收藏
Starcat 点击
Starcat AI 分析
Starcat 加入对比
ALS / LightFM 训练产物
```

适合：

```text
相似仓库推荐
喜欢 A 的人也喜欢 B
技术选型候选扩展
用户兴趣推荐
```

---

### 8.4 `user_private_chunks`（后期可选）

如果未来做云同步和云端私有语义检索，可以为用户私有数据单独建 collection，或者在 payload 中加入 `user_id` 并强制 filter。

但早期不建议做。默认继续使用本地 SQLite 向量表。

---

## 9. 不同 embedding model 不能混用

这是最重要的坑。

如果本地 SQLite 中现在混用了不同模型生成的向量，比如：

```text
text-embedding-3-small，1536 维
bge-m3，1024 维
jina-embeddings-v3，1024 维
```

不能直接混入同一个 Qdrant collection。

应该按模型和维度拆 collection：

```text
repo_chunks_openai_1536_v1
repo_chunks_bge_m3_1024_v1
repo_chunks_jina_1024_v1
```

原因：

```text
不同 embedding 模型产生的向量空间不同。
即使维度一样，也不能直接比较距离。
```

如果后续 Starcat 需要切换 embedding 模型，应采用新建 collection + 灰度 + alias 切换。

---

## 10. SQLite 向量迁移到 Qdrant 的步骤

### 10.1 准备阶段

1. 确认当前 SQLite 向量表结构。
2. 统计使用了哪些 embedding model。
3. 统计每种 model 的 vector dim。
4. 按 model/dim 设计 Qdrant collection。
5. 明确哪些数据是公共数据，哪些是用户私有数据。

---

### 10.2 Collection 创建

以 repo chunk 为例：

```text
collection_name = repo_chunks_openai_1536_v1
vector_size = 1536
distance = Cosine
```

Qdrant 中同一个 collection 内的向量需要符合相同的向量配置。若使用 named vectors，也要明确每个 named vector 的 size 和 distance。

---

### 10.3 分批读取 SQLite

不要一次性加载全部向量。

建议：

```text
batch_size = 500 ~ 2000
```

迁移流程：

```text
for each batch from SQLite:
    parse vector
    build Qdrant points
    upsert points to Qdrant
    update migration checkpoint
```

---

### 10.4 payload 字段设计

迁移时不要只迁 vector。至少要带：

```json
{
  "repo_id": 41881900,
  "full_name": "owner/repo",
  "doc_type": "readme",
  "chunk_id": "readme_001",
  "text": "...",
  "embedding_model": "text-embedding-xxx",
  "embedding_dim": 1536,
  "content_hash": "...",
  "language": "Go",
  "stars": 1000,
  "archived": false,
  "created_at": 1782000000,
  "updated_at": 1782000000
}
```

---

### 10.5 创建 payload index

如果搜索时需要按字段过滤，建议给这些字段创建 payload index：

```text
repo_id
full_name
language
archived
source
doc_type
stars_bucket
ai_category
embedding_model
```

不要盲目给所有字段建索引。

推荐原则：

| 字段 | 是否建议建索引 | 原因 |
|---|---:|---|
| `repo_id` | 是 | repo 过滤、补详情常用 |
| `language` | 是 | 搜索过滤常用 |
| `archived` | 是 | 几乎所有搜索都需要过滤 |
| `source` | 是 | 区分 GitHub、Trending、Show HN 等来源 |
| `doc_type` | 是 | readme / analysis / summary 区分 |
| `stars` | 视情况 | 如果直接 range filter，可建；也可改为 stars_bucket |
| `text` | 否 | 不适合作为 Qdrant payload index |
| `description` | 否 | 关键词搜索交给 Meilisearch |

---

### 10.6 切换查询路径

迁移完成后，Go Backend 逐步切换：

```text
旧路径：Starcat App → SQLite 本地向量检索
新路径：Starcat App → Go Backend → Qdrant
```

建议先只对公共数据切换。

用户私有数据仍保留本地 SQLite 路径。

---

## 11. Go 后端语义搜索 API 设计

### 11.1 API

```http
GET /api/search/semantic?q=swift github client&limit=20
```

支持参数：

```text
q: 查询文本
limit: 返回数量
language: 可选，语言过滤
min_stars: 可选，最低 stars
source: 可选，来源过滤
include_archived: 可选，是否包含 archived
scope: repo / chunk / all
```

---

### 11.2 后端流程

```text
1. 接收 query
2. 归一化 query
3. 查询 query embedding cache
4. 未命中则调用 Embedding Provider 生成 query vector
5. 请求 Qdrant search
6. 带 payload filter 过滤 archived、language、source 等
7. 从 PostgreSQL 补充 repo 详情
8. 执行业务排序
9. 返回 Starcat App
```

---

### 11.3 Qdrant filter 示例

只搜索未归档 Python 项目：

```json
{
  "vector": [0.01, -0.02, 0.03],
  "limit": 20,
  "filter": {
    "must": [
      {
        "key": "archived",
        "match": { "value": false }
      },
      {
        "key": "language",
        "match": { "value": "Python" }
      }
    ]
  },
  "with_payload": true
}
```

---

## 12. Go 后端相似仓库 API 设计

### 12.1 单仓库相似推荐

```http
GET /api/repos/{owner}/{repo}/similar?limit=20
```

流程：

```text
1. 根据 owner/repo 查 repo_id
2. 查询 repo_content_v1 中对应 point
3. 使用 Qdrant recommend / search 找相似 repo
4. 过滤自身、archived、低质量 repo
5. 补充 PostgreSQL repo 详情
6. 返回相似仓库列表
```

---

### 12.2 多仓库技术选型扩展

```http
POST /api/repos/similar
Content-Type: application/json

{
  "positive": ["langchain-ai/langchain", "run-llama/llama_index"],
  "negative": ["some/irrelevant-repo"],
  "limit": 30,
  "filters": {
    "language": ["Python", "TypeScript"],
    "min_stars": 100,
    "archived": false
  }
}
```

适合：

```text
用户做技术选型时，已经选了几个候选项目，希望 Starcat 推荐更多同类项目。
```

---

## 13. Meilisearch 与 Qdrant 的融合搜索

Starcat 最终搜索建议采用并发多路召回：

```text
用户输入 query
    ↓
Go Search Backend 并发执行：
    ├── SQLite 本地搜索：用户私有 / 收藏 / 最近浏览
    ├── Meilisearch：关键词全文搜索
    └── Qdrant：语义搜索
    ↓
融合排序
    ↓
返回 Starcat App
```

---

### 13.1 搜索类型选择

| 用户输入 | 推荐引擎 |
|---|---|
| `qdrant/qdrant` | Meilisearch 优先 |
| `langchain` | Meilisearch + Qdrant |
| `mcp server` | Meilisearch + Qdrant |
| `适合 SwiftUI 的 GitHub 客户端` | Qdrant 优先 |
| `类似 langchain 的项目` | Qdrant / SimRepo / behavior vector |
| 用户收藏中的关键词 | SQLite FTS |
| 用户私有备注语义搜索 | SQLite 本地向量 |
| GitHub 全站搜索 | GitHub Search API / AnySearch |

---

### 13.2 融合排序示例

```text
final_score =
  0.45 * semantic_score
+ 0.35 * keyword_score
+ 0.10 * stars_score
+ 0.05 * activity_score
+ 0.05 * category_match_score
- 0.30 * archived_penalty
```

初期可以手写规则，后期有用户行为数据后再训练排序模型。

---

## 14. 数据构建方案

### 14.1 Repo 级 embedding input

```text
Repository: owner/repo
Description: ...
Topics: topic1, topic2, topic3
Language: Go
License: MIT
README Summary: ...
AI Summary: ...
```

用于：

```text
repo_content_v1
```

---

### 14.2 Chunk 级 embedding input

```text
Repo: owner/repo
Document Type: README
Section: Installation
Content:
...
```

用于：

```text
repo_chunks_v1
```

---

### 14.3 更新策略

```text
repo_metadata_sync_job
    ↓
发现 README / description / topics / AI Summary 变化
    ↓
计算 content_hash
    ↓
如果 hash 变化：
    重新生成 embedding
    upsert 到 Qdrant
    更新 PostgreSQL embedding state
```

只更新 stars/forks 时，不一定需要重新 embedding，只更新 payload 即可。

---

## 15. PostgreSQL 状态表设计

### 15.1 `repo_embedding_state`

```sql
CREATE TABLE repo_embedding_state (
    repo_id BIGINT NOT NULL,
    doc_type TEXT NOT NULL,
    embedding_model TEXT NOT NULL,
    embedding_dim INTEGER NOT NULL,
    qdrant_collection TEXT NOT NULL,
    content_hash TEXT NOT NULL,
    status TEXT NOT NULL, -- pending, indexed, failed
    last_error TEXT,
    updated_at TIMESTAMP NOT NULL DEFAULT NOW(),
    PRIMARY KEY (repo_id, doc_type, embedding_model)
);
```

---

### 15.2 `search_query_embedding_cache`

```sql
CREATE TABLE search_query_embedding_cache (
    query_hash TEXT PRIMARY KEY,
    query_text TEXT NOT NULL,
    embedding_model TEXT NOT NULL,
    embedding_dim INTEGER NOT NULL,
    vector BYTEA NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    last_used_at TIMESTAMP NOT NULL DEFAULT NOW()
);
```

也可以放 Redis。

---

## 16. 为什么 App 不应该直接连 Qdrant？

| 原因 | 说明 |
|---|---|
| 安全 | Qdrant API key 不应该放到 macOS 客户端 |
| 模型一致性 | query embedding 必须和 collection embedding model 保持一致 |
| 缓存 | 后端能缓存 query embedding 和检索结果 |
| 融合排序 | App 直连 Qdrant 无法方便合并 Meilisearch / GitHub Search / AnySearch |
| 灰度升级 | 后端可以切换 collection alias，App 无感知 |
| 权限控制 | 公共数据、用户私有数据、订阅权限都应在后端处理 |

---

## 17. 本地 SQLite 向量还要不要保留？

建议保留。

最终推荐架构：

```text
公共索引：Qdrant 服务端
用户私有索引：SQLite 本地
关键词公共搜索：Meilisearch 服务端
关键词私有搜索：SQLite FTS 本地
```

查询时：

```text
Starcat App
    ├── 本地 SQLite：收藏 / 私有 / 最近浏览 / 离线
    └── Go Backend：公共 repo 语义检索 / 相似推荐
```

这样可以兼顾：

```text
隐私
离线
成本
公共数据复用
推荐系统能力
```

---

## 18. MVP 落地路线

### 第 1 阶段：保持本地 SQLite，新增服务端公共 Qdrant

```text
1. 新增 Go Search Backend
2. 部署 Qdrant
3. 为公开 repo 构建 repo_content_v1
4. 实现 /api/search/semantic
5. Starcat App 调用后端语义搜索
6. 本地私有语义检索继续走 SQLite
```

---

### 第 2 阶段：接入 Meilisearch + Qdrant 融合搜索

```text
1. Meilisearch 负责关键词搜索
2. Qdrant 负责语义搜索
3. 后端融合排序
4. 搜索结果中标识 source：local / keyword / semantic
```

---

### 第 3 阶段：相似仓库推荐

```text
1. 基于 repo_content_v1 做相似 repo
2. 接入 SimRepo provider 作为外部增强
3. 记录用户点击 / 收藏 / AI 分析行为
4. 后续训练 repo_behavior_v1
```

---

### 第 4 阶段：用户云同步（可选）

```text
1. 用户明确开启云同步
2. 私有数据加密或隔离存储
3. 私有 Qdrant collection / user_id filter
4. 权限校验和数据删除机制
```

---

## 19. 风险点

| 风险 | 说明 | 建议 |
|---|---|---|
| embedding model 混用 | 不同模型向量空间不同 | 按模型和维度拆 collection |
| 客户端直连 Qdrant | key 暴露、权限难管 | 必须走 Go Backend |
| 私有数据上传 | 隐私和合规风险 | 默认本地，云同步需用户授权 |
| payload 过大 | Qdrant payload 不是文档库 | 长文本只存必要 chunk，完整内容放 PG/对象存储 |
| 全部搜索都交给 Qdrant | 关键词体验可能不如搜索引擎 | Meilisearch + Qdrant 分工 |
| 查询 embedding 成本 | 每次 query 都调用 API 成本高 | query cache + 限流 |
| Qdrant collection 升级 | 模型切换不能覆盖旧数据 | 新 collection + alias 灰度切换 |

---

## 20. 最终建议

Starcat 后续可以把当前 SQLite 中用于公共数据的向量迁移到 Qdrant，但不要把所有本地向量都迁走。

推荐结论：

```text
1. Qdrant 承接公共 repo 的语义检索和相似推荐。
2. SQLite 继续承接用户私有数据、本地缓存和离线检索。
3. Meilisearch 负责关键词全文搜索。
4. Go Search Backend 作为统一搜索入口，不让 App 直连 Qdrant / Meilisearch。
5. 不同 embedding model / dim 使用不同 Qdrant collection。
6. README / AI Summary 更新时重新 embedding + upsert。
7. 后期训练出的行为向量单独写入 repo_behavior_v1。
```

一句话：

> Qdrant 可以替代 Starcat 当前“公共数据语义检索”的 SQLite 向量表，但不应该替代所有本地数据；最合理的方案是公共语义检索服务端化，私有语义检索本地化。

---

## 21. 参考资料

- Qdrant GitHub：Qdrant 是 vector similarity search engine 和 vector database，支持存储、搜索和管理带 payload 的 vectors。
- Qdrant Collections 文档：collection 是带 payload 的 points 集合，同一 collection 内向量需要统一维度和距离度量，也支持 named vectors。
- Qdrant Points / Payload / Filtering 文档：points 可以包含 vector 和 JSON payload，搜索和 retrieve 时可以按 payload 条件过滤。
- Qdrant Indexing 文档：vector index 加速向量搜索，payload index 加速过滤；过滤场景下二者配合很重要。
- Qdrant Hybrid Queries 文档：支持 dense 与 sparse vectors 的混合查询和结果融合。
- Meilisearch Filtering / Sorting / Faceting 文档：适合关键词搜索、过滤、排序和分面。
