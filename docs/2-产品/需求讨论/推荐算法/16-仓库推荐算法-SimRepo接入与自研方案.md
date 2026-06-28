# Starcat 接入 SimRepo 与自研相似仓库推荐系统方案

> 版本：v1.0  
> 适用项目：Starcat macOS App / Starcat Backend  
> 目标：在 Starcat 中快速实现「相似 GitHub 仓库推荐」，短期复用 SimRepo 非官方接口，中长期建设 Starcat 自研混合推荐系统。

---

## 1. 背景

Starcat 当前的核心方向是：

- GitHub 项目发现
- Trending / Explore / Activity 聚合
- README 预览
- AI 仓库分析
- 收藏、分类、跟踪
- 后续 Repo Research Agent

在这个产品方向下，「相似仓库推荐」是一个很强的功能点。用户打开一个仓库时，Starcat 可以推荐同类项目，帮助用户完成：

- 技术选型
- 替代品发现
- 同类项目对比
- 开源项目调研
- AI Summary / Repo Research Agent 的候选集扩展

例如用户打开：

```text
langchain-ai/langchain
```

Starcat 可以推荐：

```text
run-llama/llama_index
microsoft/semantic-kernel
crewAIInc/crewAI
stanfordnlp/dspy
haystack/deepset-ai
```

这类能力如果完全自研，需要抓取大量 GitHub star / repo metadata / README / topics，并构建推荐索引。短期可以先接入 SimRepo 的非官方接口作为 MVP 数据源。

---

## 2. SimRepo 项目介绍

### 2.1 项目定位

SimRepo 是一个浏览器扩展，用于增强 GitHub 页面，在仓库侧边栏显示「Similar Repositories」。

GitHub 仓库：

```text
https://github.com/Mubelotix/SimRepo
```

它的 README 描述为：

```text
Enhances GitHub by showing similar projects in a repository's sidebar
```

### 2.2 核心功能

根据 SimRepo README，当前功能包括：

1. 为 **100 stars 以上** 的仓库提供相似仓库推荐。
2. 在 GitHub 首页基于用户最近 star 的项目推荐仓库。
3. 为某个 star list 推荐新的项目。

也就是说，SimRepo 不只是单仓库相似推荐，还支持基于多个仓库作为 positive examples 的个性化推荐。

---

## 3. SimRepo 推荐算法理解

### 3.1 算法类型

SimRepo 的推荐算法本质上是：

```text
基于 GitHub star 用户行为的 item-item 协同过滤推荐
```

它不是基于：

- README 文本相似度
- description 关键词
- topics
- language
- license
- 更新时间

而是基于：

```text
哪些 GitHub 用户共同 star 了哪些仓库
```

也就是：

```text
如果大量用户同时 star 了 repo A 和 repo B，
那么 repo A 和 repo B 很可能相似。
```

### 3.2 数据来源

SimRepo README 说明，它的向量空间基于超过 **3 亿 GitHub stars** 的数据集训练。

可以抽象成一个 user-repo 交互矩阵：

| user | starred repo |
|---|---|
| userA | langchain |
| userA | llama_index |
| userA | crewai |
| userB | langchain |
| userB | semantic-kernel |
| userC | vue |
| userC | react |

然后通过共同 star 行为得到 repo 之间的相似关系。

### 3.3 Repo Embedding

SimRepo 将每个 GitHub repo 映射成一个向量：

```text
repo_id -> vector[dim]
```

例如：

```text
langchain      -> [0.12, -0.45, 0.33, ...]
llama_index    -> [0.10, -0.42, 0.36, ...]
vue            -> [-0.70, 0.22, 0.18, ...]
```

向量距离越近，说明两个 repo 的 stargazer pattern 越相似。

### 3.4 最近邻检索

SimRepo 最初在本地生成推荐，但用户机器性能受影响，所以后续迁移到了服务端 Qdrant。

当前流程可以理解为：

```text
GitHub stars 数据
        ↓
训练 repo embedding
        ↓
写入 Qdrant 向量数据库
        ↓
浏览器扩展读取当前 repo_id
        ↓
请求 Qdrant recommend endpoint
        ↓
返回最近邻 repo
        ↓
注入 GitHub sidebar
```

### 3.5 数据新鲜度

SimRepo README 中说明：

```text
To keep the model up-to-date, the dataset is refreshed incrementally — one-twelfth is updated each month.
```

也就是说，数据不是实时更新，而是分批增量刷新。对于刚火起来的新仓库，可能会查不到或推荐质量不稳定。

---

## 4. SimRepo API 调用方式

> 注意：SimRepo 没有明确提供正式第三方 API 文档。下面的接口来自其浏览器扩展源码中的调用方式，应当视为「非官方接口」。

### 4.1 接口地址

```text
POST https://simrepo.dera.page/collections/repos/points/recommend
```

这是一个 Qdrant recommend endpoint。

### 4.2 Header

```http
Accept: application/json
Content-Type: application/json
api-key: <SimRepo 源码中的只读 key>
```

当前源码中的 key 是一个只读 Qdrant API key。即使它已经公开，也不建议 Starcat 客户端直接硬编码。

### 4.3 请求参数

```json
{
  "limit": 10,
  "positive": [41881900],
  "filter": { "must": [] },
  "offset": 0,
  "with_payload": true,
  "with_vector": false
}
```

字段说明：

| 字段 | 说明 |
|---|---|
| `limit` | 返回数量 |
| `positive` | 正样本 repo id 列表 |
| `filter` | Qdrant 过滤条件，当前可为空 |
| `offset` | 分页偏移量 |
| `with_payload` | 是否返回 repo 元数据 |
| `with_vector` | 是否返回向量，Starcat 不需要 |

### 4.4 `positive` 不是 owner/repo

这是最重要的一点。

SimRepo 传入的是 GitHub 的数字 repo id，而不是：

```text
microsoft/vscode
```

GitHub REST API 的：

```text
GET /repos/{owner}/{repo}
```

会返回仓库信息，其中包含数字 `id` 字段。

例如：

```json
{
  "id": 41881900,
  "full_name": "microsoft/vscode"
}
```

Starcat 需要在 repo 表里保存 GitHub repo id。

---

## 5. 完整 curl 示例

下面以 `microsoft/vscode` 为例。它的 GitHub repo id 是：

```text
41881900
```

### 5.1 原始 curl

```bash
curl -X POST 'https://simrepo.dera.page/collections/repos/points/recommend' \
  -H 'Accept: application/json' \
  -H 'Content-Type: application/json' \
  -H 'api-key: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJhY2Nlc3MiOiJyIn0.drJ8F-oa_6UfCpmKdv4Mbng_E8p71UrZAR895gKOOAk' \
  -d '{
    "limit": 10,
    "positive": [41881900],
    "filter": { "must": [] },
    "offset": 0,
    "with_payload": true,
    "with_vector": false
  }'
```

### 5.2 带 jq 格式化

```bash
curl -s -X POST 'https://simrepo.dera.page/collections/repos/points/recommend' \
  -H 'Accept: application/json' \
  -H 'Content-Type: application/json' \
  -H 'api-key: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJhY2Nlc3MiOiJyIn0.drJ8F-oa_6UfCpmKdv4Mbng_E8p71UrZAR895gKOOAk' \
  -d '{
    "limit": 10,
    "positive": [41881900],
    "filter": { "must": [] },
    "offset": 0,
    "with_payload": true,
    "with_vector": false
  }' | jq
```

---

## 6. 返回数据结构

Qdrant recommend endpoint 返回结构大致如下：

```json
{
  "result": [
    {
      "id": 123456,
      "score": 0.87,
      "payload": {
        "full_name": "owner/repo",
        "description": "...",
        "language": "TypeScript",
        "stargazers_count": 12345,
        "forks_count": 123,
        "archived": false
      }
    }
  ],
  "status": "ok",
  "time": 0.002
}
```

Starcat 可以统一映射成：

```swift
struct SimilarRepo: Codable, Identifiable {
    let id: Int64
    let fullName: String
    let description: String?
    let language: String?
    let stars: Int
    let forks: Int
    let archived: Bool
    let similarity: Double
}
```

---

## 7. Starcat 接入 SimRepo 的推荐架构

### 7.1 不建议客户端直连

不要让 macOS 客户端直接调用 SimRepo：

```text
Starcat macOS App
        ↓
SimRepo Qdrant API
```

原因：

1. key 会暴露在客户端。
2. 无法统一限流。
3. 无法缓存。
4. 接口失败时不好熔断。
5. 非官方接口变化时需要发版客户端。
6. 商业产品直接打对方服务风险较高。

### 7.2 推荐架构

建议通过 Starcat Backend 中转：

```text
Starcat macOS App
        ↓
Starcat Backend
        ↓
SimilarRepoProvider
        ↓
SimRepo Unofficial Provider
        ↓
SimRepo Qdrant API
```

### 7.3 Starcat 后端 API

建议 Starcat 自己暴露稳定接口：

```http
GET /api/repos/{owner}/{repo}/similar
```

或者：

```http
GET /api/repos/{repoId}/similar
```

返回：

```json
{
  "source": "simrepo",
  "fallback": false,
  "repo_id": 41881900,
  "items": [
    {
      "id": 123456,
      "full_name": "owner/repo",
      "description": "...",
      "language": "TypeScript",
      "stars": 12345,
      "forks": 123,
      "archived": false,
      "similarity": 0.87
    }
  ]
}
```

失败时：

```json
{
  "source": "github_search",
  "fallback": true,
  "reason": "simrepo_unavailable",
  "items": []
}
```

---

## 8. Starcat Provider 抽象

建议后端定义统一 Provider 接口：

```go
type SimilarRepoProvider interface {
    SimilarRepos(ctx context.Context, input SimilarRepoInput) ([]SimilarRepo, error)
}

type SimilarRepoInput struct {
    RepoID   int64
    Owner    string
    Name     string
    FullName string
    Stars    int
    Limit    int
    Offset   int
}

type SimilarRepo struct {
    ID          int64   `json:"id"`
    FullName    string  `json:"full_name"`
    Description string  `json:"description,omitempty"`
    Language    string  `json:"language,omitempty"`
    Stars       int     `json:"stars"`
    Forks       int     `json:"forks"`
    Archived    bool    `json:"archived"`
    Similarity  float64 `json:"similarity"`
    Source      string  `json:"source"`
}
```

Provider 实现：

```text
SimRepoProvider
GitHubSearchProvider
MetadataSimilarityProvider
ReadmeEmbeddingProvider
StarcatBehaviorProvider
```

MVP 阶段只实现：

```text
SimRepoProvider + GitHubSearchProvider fallback
```

---

## 9. SimRepo Provider 实现逻辑

### 9.1 请求条件

建议满足以下条件才调用 SimRepo：

```text
repo_id 存在
stars >= 100
archived == false
不是 private repo
```

低 star 仓库可以直接走 fallback，因为 SimRepo README 明确说主要支持 100 stars 以上的仓库。

### 9.2 伪代码

```go
func (p *SimRepoProvider) SimilarRepos(ctx context.Context, input SimilarRepoInput) ([]SimilarRepo, error) {
    if input.RepoID <= 0 {
        return nil, ErrMissingRepoID
    }

    if input.Stars < 100 {
        return nil, ErrRepoTooSmall
    }

    cacheKey := fmt.Sprintf("similar:simrepo:%d:%d:%d", input.RepoID, input.Offset, input.Limit)
    if cached := p.cache.Get(cacheKey); cached != nil {
        return cached, nil
    }

    reqBody := map[string]any{
        "limit": input.Limit,
        "positive": []int64{input.RepoID},
        "filter": map[string]any{"must": []any{}},
        "offset": input.Offset,
        "with_payload": true,
        "with_vector": false,
    }

    resp, err := p.http.PostJSON(ctx, simrepoEndpoint, reqBody)
    if err != nil {
        return nil, err
    }

    items := mapQdrantResponse(resp)
    p.cache.Set(cacheKey, items, 7 * 24 * time.Hour)
    return items, nil
}
```

---

## 10. 缓存与限流策略

### 10.1 缓存时间建议

| 数据 | 缓存时间 |
|---|---:|
| 正常推荐结果 | 7 天 |
| 空结果 | 6 小时 |
| repo 不存在于 SimRepo 数据集 | 1 天 |
| 网络错误 | 10 分钟 |
| 低 star 不可用 | 1 天 |

### 10.2 限流建议

后端需要做：

```text
同一 repo_id：每 7 天最多刷新一次
同一 IP：每分钟最多请求 30 次 similar API
全局 SimRepo 调用：每秒最多 1~3 次
```

### 10.3 熔断建议

如果 SimRepo 连续失败：

```text
5 分钟内失败率 > 50%
        ↓
暂停调用 SimRepo 10 分钟
        ↓
自动走 fallback
```

---

## 11. 风险分析

| 风险 | 说明 | 建议 |
|---|---|---|
| 非官方接口 | SimRepo 没有公开 SLA/API 文档 | 只作为可替换 Provider |
| 授权不明确 | 扩展 GPL-3.0，不等于后端 API 可商用 | 联系作者确认 |
| 接口变更 | URL/key/payload/字段都可能变化 | 后端中转，避免客户端发版 |
| 限流/封禁 | Starcat 用户量增长后可能被限制 | 缓存、限流、熔断 |
| 数据不实时 | 每月刷新部分数据 | 对 Trending 新项目走 fallback |
| 低 star 不支持 | 100 stars 以下推荐质量差或不可用 | 自研内容相似 fallback |
| 隐私 | 多个 positive repo 可能暴露用户兴趣 | 仅传单 repo；个性化推荐需用户授权 |

---

## 12. 建议联系 SimRepo 作者

Starcat 是产品化应用，不建议长期依赖未授权接口。建议联系作者确认：

1. 是否允许第三方产品调用该接口；
2. 是否有速率限制；
3. 是否需要 attribution；
4. 是否可以提供正式 API key；
5. 是否可以商业合作；
6. 是否计划开放数据集或 self-host 版本。

建议 issue / email：

```text
Hi, I’m building Starcat, a macOS app for discovering and analyzing GitHub repositories.

I really like SimRepo’s recommendation quality and would love to integrate similar-repository recommendations into Starcat.

I noticed the extension calls the Qdrant recommend endpoint directly. Before using it in Starcat, I’d like to ask:

1. Is third-party usage of this endpoint allowed?
2. Are there any rate limits or attribution requirements?
3. Would you consider offering an official API or partnership?
4. Is there a recommended way to integrate SimRepo responsibly?

I’m happy to add attribution and cache results on my backend to reduce load.
```

---

# 13. 如果 Starcat 自己实现推荐算法

## 13.1 总体方向

Starcat 不建议一开始复刻 SimRepo 的 3 亿 stars 规模。更现实的路线是：

```text
先做内容相似推荐
再加入局部行为协同过滤
最后做混合推荐系统
```

目标不是简单替代 SimRepo，而是做更适合 Starcat 场景的推荐：

```text
发现 → 阅读 → AI 理解 → 对比 → 收藏 → 跟踪
```

---

## 14. 自研推荐系统分阶段方案

## 阶段 1：内容相似推荐 MVP

### 14.1 数据来源

先使用 Starcat 已经能拿到的数据：

- repo full_name
- description
- README
- topics
- language
- stars
- forks
- pushed_at
- license
- owner type
- archived
- homepage

### 14.2 推荐依据

构造 repo 文本：

```text
Repository: langchain-ai/langchain
Description: Build context-aware reasoning applications
Topics: llm, agents, rag, ai, python
Language: Python
README summary: ...
```

然后生成 embedding：

```text
repo_text -> embedding vector
```

存入：

```text
Qdrant / pgvector / LanceDB
```

查询时：

```text
当前 repo embedding
        ↓
向量近邻检索
        ↓
metadata 过滤
        ↓
排序
        ↓
返回相似 repo
```

### 14.3 优点

- 对新项目友好；
- 不需要爬 stargazers；
- 不需要大规模训练；
- 接入快；
- 适合 GitHub Trending / Show HN 新项目。

### 14.4 缺点

- 依赖 README/description 质量；
- 对“真实用户兴趣相似”的捕捉弱；
- 容易被关键词误导。

---

## 阶段 2：Metadata + 内容混合推荐

### 15.1 加入结构化特征

在向量相似基础上加入 metadata 分数：

| 特征 | 作用 |
|---|---|
| language 相同 | 加分 |
| topics 重合 | 加分 |
| license 兼容 | 加分 |
| stars 量级接近 | 加分 |
| 最近活跃 | 加分 |
| archived | 强降权 |
| fork repo | 降权或过滤 |
| pushed_at 太久 | 降权 |

### 15.2 排序公式

可以先用简单线性打分：

```text
score =
  0.55 * embedding_similarity
+ 0.15 * topic_overlap
+ 0.10 * language_match
+ 0.10 * activity_score
+ 0.05 * star_quality_score
+ 0.05 * license_score
- archived_penalty
- stale_penalty
```

### 15.3 activity_score

```text
activity_score = normalize(days_since_pushed)
```

建议：

```text
30 天内活跃：高分
90 天内活跃：中分
365 天以上未更新：降权
```

---

## 阶段 3：局部协同过滤

### 16.1 不需要全量 GitHub stars

Starcat 可以先做局部协同过滤，而不是抓全站。

数据来源：

- Starcat 用户收藏
- Starcat 用户浏览
- Starcat 用户搜索点击
- Starcat 用户 AI 分析过的 repo
- Trending repo 的 stargazers 采样
- Show HN / Product Hunt 项目集合

### 16.2 构建 item-item 共现

例如用户行为：

```text
user1 收藏 A, B, C
user2 收藏 A, B, D
user3 收藏 A, C, E
```

可以得到：

```text
A 和 B 共现 2 次
A 和 C 共现 2 次
A 和 D 共现 1 次
```

计算 item-item similarity：

```text
sim(A, B) = co_count(A, B) / sqrt(count(A) * count(B))
```

这是一个简单但有效的 item-item collaborative filtering。

### 16.3 行为权重

不同用户行为权重不同：

| 行为 | 权重 |
|---|---:|
| 收藏 repo | 5 |
| AI 分析 repo | 4 |
| 打开详情页超过 30 秒 | 3 |
| 点击 README | 2 |
| 普通浏览曝光 | 0.2 |
| 取消收藏 | -5 |

---

## 阶段 4：混合召回 + 排序

最终推荐系统可以拆成两层：

```text
召回层 Recall
        ↓
排序层 Ranking
```

### 17.1 召回层

召回多个候选集合：

| 召回器 | 说明 |
|---|---|
| SimRepoRecall | 非官方接口，短期使用 |
| EmbeddingRecall | README/description/topics 向量相似 |
| TopicRecall | topics/language overlap |
| GitHubSearchRecall | GitHub search API |
| BehaviorRecall | Starcat 用户行为协同过滤 |
| TrendingRecall | 同类 trending 项目 |
| HNRecall | Show HN 同类项目 |

### 17.2 排序层

统一排序：

```text
final_score =
  0.35 * simrepo_score
+ 0.25 * embedding_score
+ 0.15 * behavior_score
+ 0.10 * topic_score
+ 0.10 * activity_score
+ 0.05 * quality_score
- penalties
```

penalties：

```text
archived
stale
fork only
low quality README
too few stars
same owner duplicated
```

---

## 18. 推荐系统技术架构

```text
                    ┌────────────────────────┐
                    │ GitHub / Trending / HN │
                    └───────────┬────────────┘
                                │
                                ▼
                    ┌────────────────────────┐
                    │ Repo Ingestion Worker  │
                    └───────────┬────────────┘
                                │
           ┌────────────────────┼────────────────────┐
           ▼                    ▼                    ▼
┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐
│ Repo Metadata DB │ │ README Processor │ │ User Behavior DB │
└────────┬─────────┘ └────────┬─────────┘ └────────┬─────────┘
         │                    │                    │
         ▼                    ▼                    ▼
┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐
│ Metadata Feature │ │ Embedding Worker │ │ CF Co-occurrence │
└────────┬─────────┘ └────────┬─────────┘ └────────┬─────────┘
         │                    │                    │
         ▼                    ▼                    ▼
┌─────────────────────────────────────────────────────────────┐
│              Recommendation Index / Qdrant                  │
└──────────────────────────────┬──────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│              Similar Repo Recommendation API                │
└──────────────────────────────┬──────────────────────────────┘
                               │
                               ▼
                    ┌────────────────────┐
                    │ Starcat macOS App  │
                    └────────────────────┘
```

---

## 19. 数据表设计建议

### 19.1 repos

```sql
CREATE TABLE repos (
    id BIGINT PRIMARY KEY,
    full_name TEXT NOT NULL,
    owner TEXT NOT NULL,
    name TEXT NOT NULL,
    description TEXT,
    language TEXT,
    stars INTEGER DEFAULT 0,
    forks INTEGER DEFAULT 0,
    watchers INTEGER DEFAULT 0,
    open_issues INTEGER DEFAULT 0,
    license TEXT,
    archived BOOLEAN DEFAULT FALSE,
    fork BOOLEAN DEFAULT FALSE,
    pushed_at TIMESTAMP,
    created_at TIMESTAMP,
    updated_at TIMESTAMP,
    synced_at TIMESTAMP
);
```

### 19.2 repo_topics

```sql
CREATE TABLE repo_topics (
    repo_id BIGINT NOT NULL,
    topic TEXT NOT NULL,
    PRIMARY KEY (repo_id, topic)
);
```

### 19.3 repo_embeddings

```sql
CREATE TABLE repo_embeddings (
    repo_id BIGINT PRIMARY KEY,
    embedding_model TEXT NOT NULL,
    embedding_version TEXT NOT NULL,
    content_hash TEXT NOT NULL,
    updated_at TIMESTAMP NOT NULL
);
```

向量本身建议存 Qdrant 或 pgvector。

### 19.4 user_repo_events

```sql
CREATE TABLE user_repo_events (
    id BIGSERIAL PRIMARY KEY,
    user_id TEXT NOT NULL,
    repo_id BIGINT NOT NULL,
    event_type TEXT NOT NULL,
    weight DOUBLE PRECISION NOT NULL,
    created_at TIMESTAMP NOT NULL
);
```

### 19.5 repo_similar_cache

```sql
CREATE TABLE repo_similar_cache (
    repo_id BIGINT NOT NULL,
    source TEXT NOT NULL,
    items JSONB NOT NULL,
    expires_at TIMESTAMP NOT NULL,
    created_at TIMESTAMP NOT NULL,
    PRIMARY KEY (repo_id, source)
);
```

---

## 20. API 设计

### 20.1 查询相似仓库

```http
GET /api/repos/{owner}/{repo}/similar?limit=20&source=auto
```

source 可选：

```text
auto
simrepo
embedding
metadata
behavior
```

返回：

```json
{
  "repo": "microsoft/vscode",
  "source": "auto",
  "items": [
    {
      "id": 123,
      "full_name": "owner/repo",
      "description": "...",
      "language": "TypeScript",
      "stars": 1000,
      "similarity": 0.87,
      "reasons": [
        "Similar stargazer pattern",
        "Same language: TypeScript",
        "Shared topics: editor, ide"
      ]
    }
  ]
}
```

### 20.2 基于多个仓库推荐

```http
POST /api/recommend/repos
```

请求：

```json
{
  "positive": [41881900, 123456, 789012],
  "negative": [],
  "limit": 20,
  "source": "auto"
}
```

用途：

- 基于用户收藏推荐；
- 基于技术选型候选集扩展；
- 基于最近浏览历史推荐；
- 基于 AI Research Session 推荐更多候选项目。

---

## 21. Starcat UI 设计建议

### 21.1 Repo Detail 页面

在 README / AI Summary 附近添加：

```text
Similar Repositories
```

展示字段：

- repo name
- description
- language
- stars
- similarity
- 推荐原因
- 收藏按钮
- AI 分析按钮

### 21.2 技术选型场景

用户可以选择多个 repo：

```text
Add to Research Set
```

然后 Starcat 推荐更多候选：

```text
Find more alternatives
```

### 21.3 推荐原因

推荐结果最好可解释：

```text
推荐原因：
- 与当前项目用户兴趣相似
- 同为 TypeScript 项目
- 共享 topics: ai, agent, rag
- 最近 30 天仍活跃
```

---

## 22. MVP 落地计划

### 第 1 周：SimRepo Provider

- 后端实现 SimRepoProvider。
- 支持 repo_id 查询。
- 支持缓存。
- 支持错误处理。
- Repo Detail 页面展示 Similar Repositories。

### 第 2 周：Fallback

- 实现 GitHubSearchProvider。
- stars < 100 时走 fallback。
- SimRepo 错误时自动 fallback。
- 增加后台日志和失败率统计。

### 第 3 周：内容相似推荐

- 生成 repo_text。
- 接入 embedding 模型。
- 写入 Qdrant / pgvector。
- 实现 EmbeddingRecall。

### 第 4 周：混合排序

- 合并 SimRepo、Embedding、Metadata。
- 增加 activity score。
- 增加推荐原因。
- 支持多 repo positive 推荐。

---

## 23. Starcat 当前阶段建议

当前最推荐的路线：

```text
P0：接入 SimRepo 非官方 Provider
P0：后端缓存、限流、熔断
P0：低 star / 查不到时 fallback
P1：联系 SimRepo 作者确认授权
P1：自研 README/topics embedding fallback
P2：引入 Starcat 用户行为协同过滤
P3：完整混合推荐系统
```

也就是说：

```text
短期：借 SimRepo 的 300M stars 推荐能力，快速上线「相似项目」
中期：用 Starcat 自己的 metadata + README embedding 补足冷启动
长期：基于 Starcat 用户行为和技术选型场景做混合推荐系统
```

---

## 24. 最终结论

SimRepo 对 Starcat 很有价值，因为它已经解决了最难的一部分：

```text
基于大规模 GitHub stars 的 repo embedding 和最近邻推荐
```

Starcat 可以短期把它作为非官方推荐源接入，但必须做到：

1. 不客户端直连；
2. 后端统一中转；
3. 缓存、限流、熔断；
4. 低 star / 新项目 fallback；
5. 联系作者确认授权；
6. 自研推荐系统逐步替换或增强。

最终 Starcat 不应该只复刻 SimRepo，而是做更完整的：

```text
GitHub 项目发现 + 相似推荐 + AI 理解 + 技术选型对比 + 收藏跟踪
```

这会比单纯的浏览器扩展更适合 Starcat 的产品方向。

---

## 25. 参考资料

- SimRepo GitHub 仓库：`https://github.com/Mubelotix/SimRepo`
- SimRepo background.js：`https://raw.githubusercontent.com/Mubelotix/SimRepo/main/source/background.js`
- SimRepo content-repo.js：`https://raw.githubusercontent.com/Mubelotix/SimRepo/main/source/content-repo.js`
- SimRepo content-stars.js：`https://raw.githubusercontent.com/Mubelotix/SimRepo/main/source/content-stars.js`
- Qdrant Recommend Points API：`https://api.qdrant.tech/api-reference/search/recommend-points`
- Qdrant Recommendation API 说明：`https://qdrant.tech/articles/new-recommendation-api/`
- GitHub REST API Repositories：`https://docs.github.com/en/rest/repos/repos`
