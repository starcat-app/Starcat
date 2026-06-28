# Starcat 接入 Meilisearch 调研与本地部署技术方案

> 版本：v1.0  
> 日期：2026-06-28  
> 适用项目：Starcat macOS App / Starcat Backend  
> 目标：评估 Meilisearch 是否适合接入 Starcat 搜索，并给出本地部署 + Go 后端服务 + 数据构建的可落地方案。

---

## 1. 背景

Starcat 目前的核心方向是：

- GitHub Trending / Explore / Activity 聚合
- README 预览
- AI Repo Summary
- AI 分类频道
- 相似仓库推荐
- 技术选型调研

随着 Starcat 收录的仓库、AI 摘要、Activity、用户收藏和分析报告增多，单纯依赖本地 SQLite/GRDB 关键词搜索会逐渐不够：

- 搜索体验不够接近现代应用的“输入即搜索”
- 拼写错误、前缀搜索、模糊匹配能力有限
- 多字段排序、过滤、分面统计实现复杂
- AI 摘要、Activity、Repo 等多数据源难以统一检索
- 将来后端需要提供统一搜索能力，而不是只在 macOS 本地查缓存

因此可以考虑引入 **Meilisearch** 作为 Starcat 的“站内搜索引擎”。

---

## 2. Meilisearch 是什么？

Meilisearch 是一个开源搜索引擎，定位是面向应用内搜索体验的搜索服务。官方文档中说明，Meilisearch 会索引你的内容，使其可以通过搜索、对话接口和 API 被用户与 AI 系统访问；它存储 documents 和 embeddings，并提供快速全文搜索、语义搜索和会话接口。

更通俗地说：

```text
你的数据
  ↓
写入 Meilisearch Index
  ↓
用户输入关键词
  ↓
Meilisearch 返回相关结果
```

它不是 Google 这种全网搜索引擎，也不是 GitHub 全站搜索的替代品，而是你把自己的数据写进去后，它帮你提供快速、容错、可过滤、可排序的搜索体验。

---

## 3. Meilisearch 适合解决 Starcat 的哪些问题？

### 3.1 适合

| Starcat 需求 | Meilisearch 是否适合 | 说明 |
|---|---:|---|
| 搜索 Starcat 已收录 repo | 适合 | 按 name、full_name、description、topics、README 摘要搜索 |
| 搜索 Activity / AI 频道 | 适合 | Show HN、Product Hunt、GitHub Trending、AI 分类等 |
| 搜索 AI 分析报告 | 适合 | Summary、技术栈、优缺点、适用场景 |
| 搜索即输入即返回 | 适合 | Meilisearch 主打 search-as-you-type |
| 拼写容错 | 适合 | 可处理用户输入错误 |
| 分类过滤 | 适合 | language、license、stars、source、category |
| 分面统计 | 适合 | 用于 UI 左侧筛选栏 |
| 排序 | 适合 | stars、forks、pushed_at、updated_at |
| 统一后端搜索 API | 适合 | Go 后端封装搜索逻辑 |

### 3.2 不适合

| 需求 | 更合适的方案 |
|---|---|
| GitHub 全站搜索 | GitHub Search API |
| 相似仓库推荐 | Qdrant / SimRepo / 自研推荐 |
| Repo 语义相似检索 | Qdrant 更合适 |
| 全网搜索 | AnySearch / Web Search |
| 代码图谱搜索 | CodeGraphContext |
| 私有本地离线搜索 | SQLite FTS / GRDB |

---

## 4. Meilisearch 与 Qdrant 的关系

Starcat 后续很可能同时用 Meilisearch 和 Qdrant，但它们负责的场景不同。

| 项目 | 主定位 | Starcat 用途 |
|---|---|---|
| Meilisearch | 关键词 / 全文搜索 | 搜 repo、README 摘要、topics、AI 分析、Activity |
| Qdrant | 向量数据库 / 相似检索 | 相似仓库推荐、语义召回、推荐系统 |
| PostgreSQL | 主数据存储 | Repo、Activity、Analysis、索引状态 |
| SQLite / GRDB | 本地缓存 | 收藏、最近浏览、离线数据 |
| GitHub Search API | 外部搜索 | Starcat 没收录时搜索 GitHub 全站 |
| AnySearch | 网络搜索 | AI 摘要上下文和联网搜索 |

建议定位：

```text
Meilisearch = Starcat 已沉淀数据的主搜索引擎
Qdrant       = 相似推荐 / 语义向量召回
GitHub API   = GitHub 全站兜底
SQLite FTS   = 本地离线搜索
```

---

## 5. Cloud 与自托管选择

### 5.1 Meilisearch Cloud

Meilisearch Cloud 提供托管服务，官方定价页显示 Cloud 起步价为 20 美元/月，并支持 usage-based 或 resource-based billing；页面示例中 usage-based base plan 为 30 美元/月，resource-based XS instance 为 23 美元/月。企业版提供自定义基础设施、专用资源、最高 99.999% SLA、SSO SAML、SOC 2 等能力。

适合：

- 不想运维
- 需要团队协作
- 需要稳定 SLA
- 需要 Cloud 监控与备份
- 商业化后有稳定收入

### 5.2 自托管 Meilisearch

Meilisearch 可以使用 Docker 自托管。官方 Docker 文档说明可以通过 `docker pull getmeili/meilisearch:latest` 下载镜像，并通过挂载 `meili_data` 目录实现数据持久化。官方也提醒不要在生产环境固定使用 `latest` 标签，因为不同机器部署时间不同可能拉到不同版本。

适合 Starcat 当前阶段：

- 成本低
- 易调试
- 可以本地或服务器部署
- 与 Go 后端部署在同一内网
- 不需要把搜索服务暴露给 Starcat macOS 客户端

### 5.3 建议

Starcat 初期建议：

```text
本地开发：Docker 自托管 Meilisearch
早期生产：自托管 Meilisearch + Go Backend 封装
后期增长：视运维成本考虑 Meilisearch Cloud
```

---

## 6. Starcat 接入原则

用户特别强调：

> 不是让 Starcat macOS App 直接对接自托管 Meilisearch 服务，而是需要新开一个 Golang 后端服务。

这是正确的。推荐架构如下：

```text
Starcat macOS App
        │
        ▼
Starcat Search Backend（Go）
        │
        ├── PostgreSQL / SQLite / Repo 主数据
        ├── Meilisearch Admin API（只在后端使用）
        ├── Meilisearch Search API
        ├── GitHub Search API 兜底
        └── Qdrant Similar Repo API（后续）
```

不要这样：

```text
Starcat macOS App
        ↓
Meilisearch
```

原因：

- Meilisearch API Key 不应暴露到客户端
- 搜索策略后续会变化，需要后端统一封装
- 可以做缓存、限流、鉴权、日志、埋点
- 可以合并本地库、Meilisearch、GitHub Search、Qdrant 结果
- 可以统一返回 Starcat UI 所需格式
- 可以隐藏 Meilisearch 的索引结构

---

## 7. 本地部署方案

### 7.1 Docker Compose

建议使用固定版本，不要使用 `latest`。

```yaml
version: "3.9"

services:
  meilisearch:
    image: getmeili/meilisearch:v1.15
    container_name: starcat-meilisearch
    restart: unless-stopped
    ports:
      - "127.0.0.1:7700:7700"
    environment:
      MEILI_MASTER_KEY: "${MEILI_MASTER_KEY}"
      MEILI_ENV: "production"
      MEILI_DB_PATH: "/meili_data"
    volumes:
      - ./meili_data:/meili_data
```

`.env`：

```env
MEILI_MASTER_KEY=replace-with-a-secure-random-key-at-least-16-bytes
```

注意：

- 只绑定 `127.0.0.1:7700`，不要直接暴露公网
- 生产环境通过 Go 后端访问 Meilisearch
- 如果 Meilisearch 和 Go 后端在不同机器，建议走内网 / VPN / 防火墙白名单
- Master key 只用于创建 API Key，不用于普通搜索和写入

### 7.2 启动

```bash
docker compose up -d
```

### 7.3 获取 API Keys

当自托管实例设置 master key 后，Meilisearch 会生成默认 API keys。官方文档说明，可以用 master key 查询 `/keys` endpoint 查看实例的 API keys，并且明确建议：**master key 只用于管理 API keys，不要用于搜索等普通操作**。

```bash
curl -X GET 'http://127.0.0.1:7700/keys' \
  -H "Authorization: Bearer ${MEILI_MASTER_KEY}"
```

推荐创建两类 key：

| Key | 用途 | 存放位置 |
|---|---|---|
| Admin API Key | 后端索引构建、文档写入、settings 更新 | Go 后端环境变量 |
| Search API Key | 搜索请求 | 原则上也只放 Go 后端，不给客户端 |

---

## 8. Go 后端服务设计

### 8.1 服务名称

```text
starcat-search-service
```

或者如果 Starcat 已有后端，可以新增模块：

```text
starcat-backend/search
```

### 8.2 模块划分

```text
starcat-search-service
├── cmd/server
├── internal/config
├── internal/http
│   ├── search_handler.go
│   ├── index_handler.go
│   └── health_handler.go
├── internal/meili
│   ├── client.go
│   ├── repo_index.go
│   ├── activity_index.go
│   └── analysis_index.go
├── internal/indexer
│   ├── repo_indexer.go
│   ├── activity_indexer.go
│   ├── analysis_indexer.go
│   └── sync_state.go
├── internal/model
│   ├── repo_document.go
│   ├── activity_document.go
│   └── search_result.go
├── internal/store
│   ├── postgres.go
│   └── repo_repository.go
└── internal/job
    ├── scheduler.go
    └── rebuild_index_job.go
```

### 8.3 环境变量

```env
STARCAT_SEARCH_PORT=8088

MEILI_HOST=http://127.0.0.1:7700
MEILI_ADMIN_KEY=xxx
MEILI_SEARCH_KEY=xxx

DATABASE_URL=postgres://user:pass@localhost:5432/starcat?sslmode=disable

GITHUB_TOKEN=ghp_xxx
```

### 8.4 Go SDK

Meilisearch 有官方 Go SDK：`github.com/meilisearch/meilisearch-go`。

初始化：

```go
package meili

import (
    meilisearch "github.com/meilisearch/meilisearch-go"
)

func NewClient(host string, apiKey string) *meilisearch.ServiceManager {
    return meilisearch.New(host, meilisearch.WithAPIKey(apiKey))
}
```

---

## 9. Meilisearch Index 设计

建议 Starcat 至少建立三个 index：

```text
repos
activities
repo_analyses
```

如果后续加入用户私有数据，再单独处理：

```text
user_collections
```

但用户私有数据建议优先保留在本地 SQLite / GRDB，不要轻易上传。

---

## 10. Index 1：repos

### 10.1 用途

用于搜索 Starcat 已收录的 GitHub 仓库，包括：

- Trending 历史
- GitHub Explore / Activity
- Show HN 中提取的 GitHub repo
- Product Hunt 中提取的 GitHub repo
- 用户收藏 / 最近打开的公开 repo
- AI 分类频道 repo
- 后端通过 GitHub Search 拉回并确认收录的 repo

### 10.2 Document Schema

```json
{
  "id": 41881900,
  "full_name": "microsoft/vscode",
  "owner": "microsoft",
  "name": "vscode",
  "description": "Visual Studio Code",
  "topics": ["editor", "typescript", "electron"],
  "language": "TypeScript",
  "stars": 170000,
  "forks": 30000,
  "watchers": 170000,
  "open_issues": 5000,
  "license": "MIT",
  "archived": false,
  "disabled": false,
  "is_fork": false,
  "source": ["github", "trending"],
  "ai_categories": ["Developer Tool", "Editor"],
  "readme_summary": "A lightweight but powerful source code editor...",
  "tech_stack": ["TypeScript", "Electron", "Monaco"],
  "pushed_at": 1782000000,
  "updated_at": 1782000000,
  "created_at": 1441000000,
  "indexed_at": 1782600000
}
```

### 10.3 searchableAttributes

```json
[
  "full_name",
  "name",
  "owner",
  "topics",
  "description",
  "readme_summary",
  "ai_categories",
  "tech_stack"
]
```

设计原则：

- `full_name`、`name` 优先级最高
- `topics` 和 `description` 次之
- `readme_summary` 作为扩展召回，不要高于 repo 名称
- 不建议把完整 README 原文写入 Meilisearch，太大且噪音高

### 10.4 filterableAttributes

```json
[
  "language",
  "license",
  "archived",
  "disabled",
  "is_fork",
  "source",
  "ai_categories",
  "topics",
  "stars",
  "forks",
  "pushed_at",
  "updated_at"
]
```

Meilisearch 文档说明，`filterableAttributes` 用于配置可以作为 filter 和 facet 的字段，默认没有 filterable attributes；字段必须提前设置，Meilisearch 才会处理这些字段以便搜索时过滤和分面。

### 10.5 sortableAttributes

```json
[
  "stars",
  "forks",
  "watchers",
  "pushed_at",
  "updated_at",
  "created_at"
]
```

### 10.6 rankingRules

第一版可以先用默认 ranking rules，后续再微调。

建议后端做业务二次排序，不要一开始过度调 Meilisearch ranking rules。

后端二次排序可以参考：

```text
final_score =
  meili_relevance_score
+ exact_name_match_boost
+ full_name_prefix_boost
+ log_stars_boost
+ recent_activity_boost
+ ai_category_boost
- archived_penalty
- fork_penalty
```

---

## 11. Index 2：activities

### 11.1 用途

用于搜索 Starcat 的 Activity 数据：

- GitHub Trending
- Hacker News Show HN
- Product Hunt
- AI 频道
- 自定义活动源

### 11.2 Document Schema

```json
{
  "id": "showhn_20260628_123456",
  "title": "Show HN: Example AI Agent Framework",
  "source": "show_hn",
  "url": "https://news.ycombinator.com/item?id=123456",
  "repo_full_name": "owner/repo",
  "repo_id": 123456789,
  "summary": "An AI agent framework for building...",
  "category": "AI Agent",
  "tags": ["agent", "llm", "workflow"],
  "score": 231,
  "comments": 58,
  "published_at": 1782600000,
  "indexed_at": 1782603000
}
```

### 11.3 searchableAttributes

```json
[
  "title",
  "repo_full_name",
  "summary",
  "category",
  "tags"
]
```

### 11.4 filterableAttributes

```json
[
  "source",
  "category",
  "tags",
  "published_at",
  "score"
]
```

### 11.5 sortableAttributes

```json
[
  "published_at",
  "score",
  "comments"
]
```

---

## 12. Index 3：repo_analyses

### 12.1 用途

用于搜索 AI 分析报告：

- repo 摘要
- 技术栈
- 核心功能
- 优缺点
- 适用场景
- 集成成本
- 风险点

### 12.2 Document Schema

```json
{
  "id": "analysis_41881900",
  "repo_id": 41881900,
  "full_name": "microsoft/vscode",
  "summary": "VS Code is a cross-platform code editor...",
  "tech_stack": ["TypeScript", "Electron", "Monaco"],
  "features": ["editor", "extensions", "debugging"],
  "pros": ["large ecosystem", "cross-platform"],
  "cons": ["Electron resource usage"],
  "suitable_for": ["developer tools", "editor platforms"],
  "risk_points": ["large codebase", "extension compatibility"],
  "ai_categories": ["Developer Tool"],
  "created_at": 1782600000,
  "updated_at": 1782600000
}
```

### 12.3 searchableAttributes

```json
[
  "full_name",
  "summary",
  "tech_stack",
  "features",
  "pros",
  "cons",
  "suitable_for",
  "risk_points",
  "ai_categories"
]
```

### 12.4 filterableAttributes

```json
[
  "repo_id",
  "ai_categories",
  "tech_stack",
  "created_at",
  "updated_at"
]
```

---

## 13. 数据从哪里来？

### 13.1 repos index 数据源

| 字段 | 数据来源 |
|---|---|
| id | GitHub REST API `/repos/{owner}/{repo}` |
| full_name | GitHub REST API |
| owner/name | GitHub REST API |
| description | GitHub REST API |
| topics | GitHub REST API topics |
| language | GitHub REST API |
| stars/forks/watchers | GitHub REST API |
| license | GitHub REST API |
| archived/disabled/fork | GitHub REST API |
| README summary | Starcat AI Summary / README 解析 |
| tech_stack | AI Summary / 规则提取 / Repomix |
| ai_categories | Starcat 分类器 |
| source | Starcat 数据源标记 |
| pushed_at/updated_at | GitHub REST API |

### 13.2 activities index 数据源

| 来源 | 构建方式 |
|---|---|
| GitHub Trending | Starcat 已有 trending API |
| Show HN | 抓取 Show HN 页，提取 GitHub URL |
| Product Hunt | 如果能拿到 GitHub URL，则入库 |
| AI 频道 | 基于 repo 分类器生成 |
| 用户手动收藏 | 如果是公开 repo，可进入 repos index；私有标签不建议上传 |

### 13.3 repo_analyses index 数据源

| 字段 | 数据来源 |
|---|---|
| summary | AI Repo Summary |
| tech_stack | AI 分析 / README / package files |
| pros/cons | AI 分析 |
| suitable_for | AI 分析 |
| risk_points | AI 分析 |
| ai_categories | AI 分类器 |

---

## 14. 数据构建流程

### 14.1 总体流程

```text
GitHub / Activity 数据源
        ↓
Starcat Backend 入库 PostgreSQL
        ↓
清洗 / 规范化 / 去重
        ↓
构建 Meilisearch Document
        ↓
批量写入 Meilisearch
        ↓
记录 index_sync_state
```

### 14.2 为什么 PostgreSQL 作为主数据源？

不要把 Meilisearch 当主库。Meilisearch 是搜索索引，不是业务主库。

推荐：

```text
PostgreSQL = source of truth
Meilisearch = search index
Qdrant = vector index
```

原因：

- Meilisearch index 可以重建
- Meilisearch document 是搜索视图，不等于完整业务对象
- PostgreSQL 负责事务、历史、状态、外键和索引构建状态

---

## 15. 数据库表设计

### 15.1 repos

```sql
CREATE TABLE repos (
    id BIGINT PRIMARY KEY,
    full_name TEXT NOT NULL UNIQUE,
    owner TEXT NOT NULL,
    name TEXT NOT NULL,
    description TEXT,
    language TEXT,
    stars INTEGER DEFAULT 0,
    forks INTEGER DEFAULT 0,
    watchers INTEGER DEFAULT 0,
    open_issues INTEGER DEFAULT 0,
    license_key TEXT,
    archived BOOLEAN DEFAULT FALSE,
    disabled BOOLEAN DEFAULT FALSE,
    is_fork BOOLEAN DEFAULT FALSE,
    html_url TEXT,
    pushed_at TIMESTAMP,
    updated_at TIMESTAMP,
    created_at TIMESTAMP,
    collected_at TIMESTAMP NOT NULL DEFAULT NOW()
);
```

### 15.2 repo_topics

```sql
CREATE TABLE repo_topics (
    repo_id BIGINT NOT NULL REFERENCES repos(id),
    topic TEXT NOT NULL,
    PRIMARY KEY (repo_id, topic)
);
```

### 15.3 repo_sources

```sql
CREATE TABLE repo_sources (
    repo_id BIGINT NOT NULL REFERENCES repos(id),
    source TEXT NOT NULL,
    source_ref TEXT,
    first_seen_at TIMESTAMP NOT NULL DEFAULT NOW(),
    last_seen_at TIMESTAMP NOT NULL DEFAULT NOW(),
    PRIMARY KEY (repo_id, source)
);
```

### 15.4 repo_ai_summaries

```sql
CREATE TABLE repo_ai_summaries (
    repo_id BIGINT PRIMARY KEY REFERENCES repos(id),
    summary TEXT,
    tech_stack JSONB,
    ai_categories JSONB,
    pros JSONB,
    cons JSONB,
    suitable_for JSONB,
    risk_points JSONB,
    model_name TEXT,
    content_hash TEXT,
    updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);
```

### 15.5 activities

```sql
CREATE TABLE activities (
    id TEXT PRIMARY KEY,
    source TEXT NOT NULL,
    title TEXT NOT NULL,
    url TEXT NOT NULL,
    repo_id BIGINT,
    repo_full_name TEXT,
    summary TEXT,
    category TEXT,
    tags JSONB,
    score INTEGER,
    comments INTEGER,
    published_at TIMESTAMP,
    indexed_at TIMESTAMP NOT NULL DEFAULT NOW()
);
```

### 15.6 search_index_state

```sql
CREATE TABLE search_index_state (
    entity_type TEXT NOT NULL,
    entity_id TEXT NOT NULL,
    index_uid TEXT NOT NULL,
    source_updated_at TIMESTAMP,
    indexed_at TIMESTAMP,
    content_hash TEXT,
    status TEXT NOT NULL DEFAULT 'pending',
    error_message TEXT,
    PRIMARY KEY (entity_type, entity_id, index_uid)
);
```

---

## 16. Index 初始化

### 16.1 创建 indexes

```go
func EnsureIndexes(client *meilisearch.ServiceManager) error {
    indexes := []struct {
        UID        string
        PrimaryKey string
    }{
        {"repos", "id"},
        {"activities", "id"},
        {"repo_analyses", "id"},
    }

    for _, idx := range indexes {
        _, err := client.CreateIndex(&meilisearch.IndexConfig{
            Uid:        idx.UID,
            PrimaryKey: idx.PrimaryKey,
        })
        if err != nil {
            // 如果 index 已存在，则忽略
        }
    }

    return nil
}
```

### 16.2 配置 repos settings

```go
func ConfigureReposIndex(index *meilisearch.Index) error {
    settings := &meilisearch.Settings{
        SearchableAttributes: []string{
            "full_name",
            "name",
            "owner",
            "topics",
            "description",
            "readme_summary",
            "ai_categories",
            "tech_stack",
        },
        FilterableAttributes: []string{
            "language",
            "license",
            "archived",
            "disabled",
            "is_fork",
            "source",
            "ai_categories",
            "topics",
            "stars",
            "forks",
            "pushed_at",
            "updated_at",
        },
        SortableAttributes: []string{
            "stars",
            "forks",
            "watchers",
            "pushed_at",
            "updated_at",
            "created_at",
        },
    }

    _, err := index.UpdateSettings(settings)
    return err
}
```

注意：

Meilisearch 的 settings 变更会触发重建内部索引结构。官方规格说明中提到，修改 `searchableAttributes`、`filterableAttributes`、`sortableAttributes` 等设置会导致 documents 重新索引。因此 Starcat 应该尽量在初始阶段把字段设计好，不要频繁改 settings。

---

## 17. 文档构建策略

### 17.1 RepoDocument

```go
type RepoDocument struct {
    ID            int64    `json:"id"`
    FullName      string   `json:"full_name"`
    Owner         string   `json:"owner"`
    Name          string   `json:"name"`
    Description   string   `json:"description,omitempty"`
    Topics        []string `json:"topics,omitempty"`
    Language      string   `json:"language,omitempty"`
    Stars         int      `json:"stars"`
    Forks         int      `json:"forks"`
    Watchers      int      `json:"watchers"`
    OpenIssues    int      `json:"open_issues"`
    License       string   `json:"license,omitempty"`
    Archived      bool     `json:"archived"`
    Disabled      bool     `json:"disabled"`
    IsFork        bool     `json:"is_fork"`
    Source        []string `json:"source,omitempty"`
    AICategories  []string `json:"ai_categories,omitempty"`
    ReadmeSummary string   `json:"readme_summary,omitempty"`
    TechStack     []string `json:"tech_stack,omitempty"`
    PushedAt      int64    `json:"pushed_at,omitempty"`
    UpdatedAt     int64    `json:"updated_at,omitempty"`
    CreatedAt     int64    `json:"created_at,omitempty"`
    IndexedAt     int64    `json:"indexed_at"`
}
```

### 17.2 文档构建原则

- 不写完整 README，只写 `readme_summary`
- `topics`、`ai_categories`、`tech_stack` 用字符串数组
- 时间字段用 Unix timestamp，方便排序和过滤
- `source` 用数组，例如 `["trending", "show_hn"]`
- stars/forks/watchers 使用整数，支持排序和范围过滤
- archived / disabled / is_fork 使用 bool，便于过滤

### 17.3 content_hash

为每个 document 计算 hash，避免无意义重复写入。

```text
content_hash = hash(
  full_name
  description
  topics
  language
  stars
  forks
  archived
  readme_summary
  ai_categories
  tech_stack
  updated_at
)
```

如果 hash 没变，不需要重新写 Meilisearch。

---

## 18. 索引同步模式

### 18.1 全量重建

适合：

- 首次部署
- settings 大改
- schema 大改
- 搜索质量异常
- Meilisearch 数据损坏

流程：

```text
1. 创建临时 index：repos_v2
2. 配置 settings
3. 从 PostgreSQL 批量读取 repos
4. 构建 documents
5. 批量写入 repos_v2
6. 验证文档数量与搜索质量
7. 用 alias 或后端配置切换到新 index
8. 删除旧 index
```

### 18.2 增量同步

适合日常运行。

流程：

```text
1. 扫描 source_updated_at > last_indexed_at 的 repo
2. 构建 RepoDocument
3. 计算 content_hash
4. hash 变化则 AddOrUpdateDocuments
5. 写入 search_index_state
```

### 18.3 软删除

如果 repo 被删除、不可访问或违规：

```text
方案 A：从 Meilisearch 删除 document
方案 B：保留 document，但设置 deleted=true / available=false
```

第一版建议直接删除或设置 `archived=true` 降权，避免结果里出现不可访问项目。

---

## 19. 批量写入策略

不要一条一条写 Meilisearch。

推荐：

| 数据量 | batch size |
|---:|---:|
| 小数据 | 500 |
| 中等数据 | 1000 |
| 大数据 | 2000～5000 |

Go 伪代码：

```go
func IndexRepos(ctx context.Context, index *meilisearch.Index, docs []RepoDocument) error {
    const batchSize = 1000

    for start := 0; start < len(docs); start += batchSize {
        end := start + batchSize
        if end > len(docs) {
            end = len(docs)
        }

        task, err := index.AddDocuments(docs[start:end])
        if err != nil {
            return err
        }

        // 可选：等待 task 完成，或只记录 task uid 由后台任务检查
        _ = task
    }

    return nil
}
```

建议：

- 在线增量可以等待 task 完成
- 全量重建不要同步等待每个 task，可以异步检查 task 状态
- 写入失败记录到 `search_index_state.error_message`

---

## 20. 搜索 API 设计

### 20.1 Repo 搜索

```http
GET /api/search/repos?q=rag&language=Python&min_stars=1000&category=AI%20RAG&sort=stars:desc&limit=20&offset=0
```

响应：

```json
{
  "query": "rag",
  "hits": [
    {
      "repo_id": 123,
      "full_name": "owner/repo",
      "description": "...",
      "language": "Python",
      "stars": 12345,
      "forks": 123,
      "topics": ["rag", "llm"],
      "ai_categories": ["AI RAG"],
      "source": ["trending"],
      "highlight": {
        "description": "...",
        "readme_summary": "..."
      }
    }
  ],
  "facets": {
    "language": {
      "Python": 120,
      "TypeScript": 60
    },
    "ai_categories": {
      "AI RAG": 80,
      "AI Agent": 20
    }
  },
  "limit": 20,
  "offset": 0,
  "estimated_total_hits": 238
}
```

### 20.2 Activity 搜索

```http
GET /api/search/activities?q=agent&source=show_hn&category=AI%20Agent
```

### 20.3 全局搜索

```http
GET /api/search?q=qdrant&scope=all
```

返回分组：

```json
{
  "repos": [],
  "activities": [],
  "analyses": []
}
```

### 20.4 搜索兜底

如果 Meilisearch 搜不到：

```text
1. 返回空结果
2. UI 展示：搜索 GitHub 全站
3. 用户点击后后端调用 GitHub Search API
4. 命中结果入库 PostgreSQL
5. 异步写入 Meilisearch
```

---

## 21. Meilisearch 查询示例

### 21.1 基础搜索

```go
res, err := index.Search("rag agent", &meilisearch.SearchRequest{
    Limit: 20,
    Offset: 0,
})
```

### 21.2 带过滤

```go
res, err := index.Search("rag", &meilisearch.SearchRequest{
    Limit: 20,
    Filter: "archived = false AND stars >= 1000 AND language = Python",
})
```

### 21.3 带排序

```go
res, err := index.Search("agent", &meilisearch.SearchRequest{
    Limit: 20,
    Sort: []string{"stars:desc"},
})
```

### 21.4 带 facets

```go
res, err := index.Search("ai", &meilisearch.SearchRequest{
    Limit: 20,
    Facets: []string{"language", "ai_categories", "source"},
})
```

Meilisearch 文档说明，filtering、sorting、faceting 是互补能力；filters 用于缩小结果，sorting 用字段排序，facets 返回字段值分布，适合 UI 构建筛选栏。

---

## 22. Starcat UI 接入建议

### 22.1 顶部全局搜索

输入：

```text
qdrant
```

展示分组：

```text
Repositories
- qdrant/qdrant
- qdrant/fastembed

Activities
- Show HN: xxx

Analyses
- Qdrant 技术分析报告
```

### 22.2 Repo 列表页搜索

支持：

- 关键词
- language filter
- stars range
- source filter
- AI category filter
- sort by stars / updated_at / pushed_at

### 22.3 AI 频道搜索

用户可以在 AI 频道内搜索：

```text
mcp server
rag framework
coding agent
```

并按分类过滤：

- AI Agent
- AI Coding
- AI MCP
- AI RAG
- AI Infra
- AI Model
- AI Skill

### 22.4 搜索结果操作

结果上可以直接提供：

- 打开 repo 详情
- 收藏
- AI 分析
- 加入技术选型对比
- 查看相似项目

---

## 23. 安全设计

### 23.1 Meilisearch 不暴露公网

推荐：

```text
Meilisearch 只监听 127.0.0.1 或内网
Starcat Go Backend 访问 Meilisearch
Starcat App 访问 Go Backend
```

### 23.2 API Key 管理

- Master key 只用于 key 管理
- Admin key 只放 Go 后端
- Search key 也不直接给 macOS App
- 后端对外使用自己的鉴权方案
- 后端限制搜索请求频率

官方文档明确说明：master key 暴露会让攻击者完全控制 Meilisearch 实例，只应在管理 API key 时使用，不要用于普通操作。

### 23.3 私有用户数据

第一版不建议把用户私有数据写入公共 Meilisearch index。

如果未来要支持用户私有收藏同步：

方案：

```text
public indexes:
  repos
  activities
  repo_analyses

private search:
  本地 SQLite FTS / GRDB
  或者服务端 user-scoped index / tenant token
```

更简单的第一版：

```text
公开 repo 搜索：Meilisearch
用户收藏/备注：本地 SQLite FTS
```

---

## 24. 监控与运维

### 24.1 需要监控的指标

| 指标 | 说明 |
|---|---|
| 搜索 QPS | 用户查询压力 |
| 搜索 P95 延迟 | UI 体验 |
| 索引写入任务失败数 | 数据同步健康 |
| Meilisearch task backlog | 是否写入堆积 |
| index document count | 是否和 PostgreSQL 一致 |
| disk usage | Meilisearch 数据目录 |
| memory usage | 搜索和索引性能 |
| failed search count | 查询错误 |

### 24.2 定期任务

| 任务 | 频率 |
|---|---|
| repo metadata sync | 6 小时 / 1 天 |
| Meilisearch 增量同步 | 5～30 分钟 |
| Activity index sync | 5～30 分钟 |
| AI analysis index sync | 生成报告后实时写 |
| index consistency check | 每天 |
| snapshot / backup | 每天 |

---

## 25. 成本估算

### 25.1 自托管

Meilisearch 自托管软件本身免费，成本主要来自：

- 服务器
- SSD
- 内存
- 备份
- 运维

Starcat MVP 数据规模假设：

```text
repos：100 万
activities：100 万以内
analyses：10 万～100 万
平均 document：1KB～5KB
```

大致：

| 数据规模 | Meilisearch 数据目录估算 | 建议机器 |
|---|---:|---|
| 10 万 docs | 1GB～5GB | 1C/1GB 可试 |
| 100 万 docs | 5GB～30GB | 2C/4GB 起 |
| 1000 万 docs | 50GB～300GB | 4C/16GB 起，视字段和 QPS |
| 5000 万 docs | 数百 GB～TB | 需要更认真压测 |

如果 Starcat 初期只搜索 repo 元数据和摘要，成本很低。

### 25.2 Cloud

Meilisearch Cloud 官方定价页显示：

- Cloud 起步价 20 美元/月
- usage-based 示例 base plan 30 美元/月
- resource-based XS 示例 23 美元/月
- Enterprise 为自定义报价

因此早期如果只是开发和小规模生产，自托管更省钱；商业化后再考虑 Cloud。

---

## 26. 与 Starcat 现有能力的整合

### 26.1 与 README 缓存

Starcat 现有 README 渲染走 GitHub HTML + WKWebView + ETag 缓存。

Meilisearch 不替代 README 缓存，只索引：

```text
readme_summary
readme_keywords
tech_stack
```

完整 README HTML 仍由 Starcat 原链路展示。

### 26.2 与 AI Summary

AI Summary 生成后：

```text
AI Summary 写 PostgreSQL
    ↓
构建 RepoAnalysisDocument
    ↓
写 repo_analyses index
    ↓
部分字段回写 repos index
```

### 26.3 与 Qdrant 推荐

搜索和推荐分开：

```text
用户明确输入关键词：
  Meilisearch

用户打开 repo 看相似项目：
  Qdrant / SimRepo / 自研推荐

用户搜索意图不明确：
  Meilisearch 召回 + Qdrant 语义召回，后端融合
```

### 26.4 与 GitHub Search API

如果 Meilisearch 没搜到：

```text
用户点击“搜索 GitHub 全站”
    ↓
后端调用 GitHub Search API
    ↓
展示临时结果
    ↓
用户打开/收藏后正式入库
    ↓
异步写入 Meilisearch
```

---

## 27. MVP 落地计划

### 第 1 阶段：本地部署与基础搜索

目标：

```text
Go 后端接入 Meilisearch
repos index 可搜索
Starcat App 通过后端搜索 repo
```

任务：

- Docker Compose 部署 Meilisearch
- Go 后端接入 meilisearch-go
- 创建 `repos` index
- 配置 searchable/filterable/sortable attributes
- 从 PostgreSQL 构建 RepoDocument
- 批量写入 repos index
- 实现 `/api/search/repos`
- Starcat UI 接入搜索结果

### 第 2 阶段：Activity 与 AI 分析搜索

任务：

- 创建 `activities` index
- 创建 `repo_analyses` index
- AI Summary 生成后写索引
- 支持全局搜索 `/api/search?q=xxx&scope=all`
- UI 分组展示 repos / activities / analyses

### 第 3 阶段：增量同步和运维

任务：

- `search_index_state`
- content_hash 去重
- 增量同步 job
- 索引一致性检查
- Meilisearch health check
- 搜索日志
- 请求限流

### 第 4 阶段：搜索质量优化

任务：

- synonyms
- stop words
- ranking rules
- 业务二次排序
- facets UI
- 搜索无结果兜底 GitHub Search
- Query analytics

---

## 28. 风险与注意事项

| 风险 | 说明 | 应对 |
|---|---|---|
| settings 频繁变更导致重索引 | searchable/filterable/sortable 改动会触发重索引 | 初期设计好 schema |
| 文档过大 | 完整 README 写入会增大索引和噪音 | 只写摘要 |
| key 泄露 | 客户端直连会暴露 key | 只让 Go 后端访问 |
| 私有数据混入公共索引 | 用户备注/收藏可能有隐私 | 私有数据本地搜索 |
| Meilisearch 不是主库 | index 可能丢失或需要重建 | PostgreSQL 做 source of truth |
| 搜索结果与业务状态不一致 | repo 删除、归档后还可搜到 | 增量同步 + 定期一致性检查 |
| Cloud 成本增长 | docs/searches 增加后费用上升 | 自托管起步，后期评估 Cloud |

---

## 29. 最终建议

Meilisearch 值得接入 Starcat，但定位要清楚：

```text
Meilisearch 不是 GitHub Search 替代品；
Meilisearch 也不是 Qdrant 替代品；
它应该成为 Starcat 已收录数据的统一搜索引擎。
```

推荐最终架构：

```text
Starcat macOS App
        ↓
Starcat Go Backend
        ↓
Search Orchestrator
        ├── Local/Recent/Favorite metadata
        ├── Meilisearch：站内搜索
        ├── GitHub Search：全站兜底
        └── Qdrant：相似/语义推荐
```

第一版最务实的落地方式：

```text
1. 自托管 Meilisearch
2. 新增 Go Search Backend
3. 只索引 repos
4. 只索引 README summary，不索引完整 README
5. 支持关键词搜索 + filters + sort
6. 后续再加 activities / repo_analyses / global search
```

如果 Starcat 后续持续沉淀 GitHub repo、AI 摘要和 Activity 数据，Meilisearch 会成为一个非常有价值的“搜索中台”。

---

## 30. 参考资料

- Meilisearch 官方概览文档：`https://www.meilisearch.com/docs/getting_started/overview`
- Meilisearch Docker 自托管文档：`https://meilisearch.com/docs/resources/self_hosting/getting_started/docker`
- Meilisearch 安全文档：`https://meilisearch.com/docs/resources/self_hosting/security/basic_security`
- Meilisearch Master key / API keys 文档：`https://meilisearch.com/docs/resources/self_hosting/security/master_api_keys`
- Meilisearch Pricing：`https://www.meilisearch.com/pricing`
- Meilisearch Filterable Attributes 规格：`https://specs.meilisearch.dev/specifications/text/0123-filterable-attributes-setting-api.html`
- Meilisearch Settings API 规格：`https://specs.meilisearch.dev/specifications/text/0123-settings-api.html`
- Meilisearch Search API：`https://meilisearch.com/docs/reference/api/search/search-with-post`
- Meilisearch Filtering / Sorting / Faceting：`https://meilisearch.com/docs/capabilities/filtering_sorting_faceting/overview`
- Meilisearch Go SDK：`https://pkg.go.dev/github.com/meilisearch/meilisearch-go`
