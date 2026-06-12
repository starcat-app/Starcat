# weekly-api 3 源聚合改造方案（R-04）

> **状态**：关键契约已拍板（2026-06-12，待施工）
> **影响范围**：`supports/starcat-weekly-api/` 独立 Go 服务
> **客户端影响**：现有 `WeeklyAPI` 接口由 R-05 一次性切换到聚合接口
> **数据迁移**：项目未上线，不保留旧 schema；删除本地数据库后重建
> **兼容性**：不保留旧列表和详情接口

---

## 0. 结论

weekly-api 当前已经同时承载三类公共发现数据：

1. 阮一峰科技爱好者周刊项目；
2. ZRead 周趋势项目；
3. Show HN GitHub 项目。

三条数据链目前分别落在 `projects`、`zread_trending`、`discovery_repos + discovery_submissions` 中，对外接口和 DTO 也互不统一。本方案把三源重构为一套以 GitHub 不可变仓库 ID 为核心的聚合模型：

```text
                          github_repos
                    PK: gh_repo_id (Int64)
             GitHub 元数据 + 聚合时间 + 来源集合
                  /             |              \
                 /              |               \
        weekly_extras     zread_events     discovery_submissions
           1 : 1             1 : N                 1 : N
```

对客户端提供三个接口：

```text
GET /api/v1/repos
GET /api/v1/repos/{gh_repo_id}
GET /api/v1/repos/languages
```

核心约束：

- `gh_repo_id` 是 repo 身份唯一信任源；`owner/name` 只是可更新属性。
- 列表按后端聚合出的 `latest_event_at` 排序；客户端不得用 `weekly/zread/discovery` 快照自行推导时间。
- GitHub enrich 可以去抖，但来源登记和事件写入绝不能被去抖跳过。
- Discovery 只保留最新代码中的“收集 + GitHub enrichment”流程，不恢复已删除的 LLM 分类体系。
- 客户端不做跨源去重、时间归一或排序。
- 项目尚未上线，R-04 直接替换 schema、DTO 和公开路由；不写数据迁移，不保留老版本兼容逻辑。

---

## 1. 最新代码现状

### 1.1 当前存储模型

| 数据源 | 当前表 | 当前身份键 | 时间事实 |
|---|---|---|---|
| 阮一峰周刊 | `projects`、`weekly_issues` | `(repo_owner, repo_name)` | 首次收录期号及期号发布时间 |
| ZRead | `zread_trending` | `(week_start, owner, name)` | `week_start` / `week_end` |
| Show HN | `discovery_repos`、`discovery_submissions` | `(owner, repo)`、`hn_id` | 投稿 `published_at` |

最新 weekly-api `c2a97bc` 已删除 Discovery 的 LLM 分类阶段。当前 Discovery repo 只维护：

- GitHub enrichment 状态：`pending / ready / retryable / unavailable`；
- GitHub repo 元数据；
- Show HN 投稿事实。

因此新聚合 schema 不再包含 `category`、`classify_status`、`classify_model` 等字段，也不依赖 `LLM_API_KEY`。

### 1.2 当前接口

```text
GET /api/v1/weekly?page=&page_size=&issue=&lang=&sort=
GET /api/v1/weekly/{owner}/{repo}
GET /api/v1/issues
GET /api/v1/issues/{number}
GET /api/v1/zread?week=&limit=
GET /api/v1/discovery?page=&page_size=
GET /api/v1/discovery/{owner}/{repo}
```

### 1.3 主要问题

1. 同一 repo 在多个来源中重复保存 GitHub 元数据，并可能重复消耗 GitHub API 配额。
2. `(owner, name)` 无法稳定识别 rename / transfer 后的同一仓库。
3. 三源时间精度不同，客户端无法可靠地统一排序。
4. 客户端需要理解三套接口和三套 DTO，违背“重后端、轻客户端”的边界。

---

## 2. 核心设计决策

### 2.1 Repo 身份统一为 `gh_repo_id`

GitHub API 的仓库 `id` 在 rename 和 transfer 后保持不变。主表使用：

```sql
gh_repo_id INTEGER PRIMARY KEY
```

`owner`、`name`、`full_name` 由最近一次成功 enrichment 覆盖。详情接口直接按 `gh_repo_id` 查询，避免客户端拿旧 owner/name 请求详情时产生 404。

`UNIQUE(owner, name)` 只用于发现异常重复和快速反查，不承担跨时间身份语义。

### 2.2 列表排序使用来源事件时间

必须区分三类时间：

| 字段 | 语义 | 是否用于默认列表排序 |
|---|---|---|
| `first_event_at` | 最早一次来源事件发生时间 | 否 |
| `latest_event_at` | 最近一次来源事件发生时间 | 是 |
| `record_updated_at` | 本服务最近一次写记录时间 | 否 |
| `enriched_at` | 最近一次成功请求 GitHub API 的时间 | 否 |

来源事件时间定义：

- weekly：`weekly_issues.published_at`；
- zread：`week_start 00:00:00Z`；
- discovery：`discovery_submissions.published_at`。

冷启动导入历史数据时，所有 repo 的 `record_updated_at` 可能相近，因此绝不能用“入库时间”代替来源事件时间。

`latest_event_at` 是客户端可见的唯一“最近更新 / 最近来源事件”字段。客户端列表排序、详情首帧展示、相对时间提示都直接使用后端返回值，不再按三源快照自行比较或重算。

### 2.3 来源事实由附表推导

`source_types_json` 可以保留为主表冗余字段，方便列表返回；但来源事实的真源是附表：

- 存在 `weekly_extras` 行 → `weekly`；
- 存在 `zread_events` 行 → `zread`；
- 存在 `discovery_submissions` 行 → `discovery`。

每次写附表后，在同一事务中重算并更新：

- `source_types_json`；
- `first_event_at`；
- `latest_event_at`。

这样即使 GitHub enrich 命中去抖快路径，也不会漏记第二个来源。

### 2.4 Enrichment 与来源登记分离

每条 spider 数据都经过两个独立步骤：

```text
1. EnsureGitHubRepo(owner, name)
   - 获取或复用 gh_repo_id
   - 只负责 GitHub 元数据
   - 允许 30 分钟去抖

2. AttachSourceEvent(gh_repo_id, event)
   - 写来源附表
   - 重算 source_types / first_event_at / latest_event_at
   - 每次都执行，禁止被 enrich 去抖跳过
```

### 2.5 不恢复 Discovery 分类系统

Show HN 只表达“某个 GitHub repo 在 HN 被投稿”这一事实。首期不提供 category filter，不设计 pending/classified，也不增加客户端“显示未分类项目”开关。

---

## 3. 数据库设计

### 3.1 `github_repos`

```sql
CREATE TABLE github_repos (
    gh_repo_id          INTEGER PRIMARY KEY,

    owner               TEXT NOT NULL,
    name                TEXT NOT NULL,
    full_name           TEXT NOT NULL,

    description         TEXT,
    homepage            TEXT,
    language            TEXT,
    stars               INTEGER NOT NULL DEFAULT 0,
    forks               INTEGER NOT NULL DEFAULT 0,
    watchers            INTEGER NOT NULL DEFAULT 0,
    subscribers         INTEGER NOT NULL DEFAULT 0,
    open_issues         INTEGER NOT NULL DEFAULT 0,
    owner_avatar        TEXT,
    default_branch      TEXT,
    license_spdx        TEXT,
    topics_json         TEXT NOT NULL DEFAULT '[]',
    pushed_at           TEXT,
    updated_at          TEXT,
    created_at          TEXT,
    is_archived         INTEGER NOT NULL DEFAULT 0,
    is_fork             INTEGER NOT NULL DEFAULT 0,
    is_private          INTEGER NOT NULL DEFAULT 0,

    source_types_json   TEXT NOT NULL DEFAULT '[]',
    first_event_at      TEXT NOT NULL,
    latest_event_at     TEXT NOT NULL,
    enriched_at         TEXT,
    record_updated_at   TEXT NOT NULL,
    is_available        INTEGER NOT NULL DEFAULT 1,

    UNIQUE(owner, name)
);

CREATE INDEX idx_github_repos_language
    ON github_repos(language);
CREATE INDEX idx_github_repos_latest_event
    ON github_repos(latest_event_at DESC, gh_repo_id DESC);
CREATE INDEX idx_github_repos_stars
    ON github_repos(stars DESC, gh_repo_id DESC);
CREATE INDEX idx_github_repos_pushed
    ON github_repos(pushed_at DESC, gh_repo_id DESC);
```

`first_event_at/latest_event_at` 在首次 `EnsureGitHubRepo` 占位时可暂用当前时间，随后必须在写入第一个来源事件的同一事务中改成真实事件时间。对外列表只返回已经拥有来源附表的 repo。

### 3.2 `weekly_issues`

```sql
CREATE TABLE weekly_issues (
    number       INTEGER PRIMARY KEY,
    published_at TEXT NOT NULL,
    source_url   TEXT NOT NULL,
    parsed_at    TEXT NOT NULL
);
```

### 3.3 `weekly_extras`

```sql
CREATE TABLE weekly_extras (
    gh_repo_id          INTEGER PRIMARY KEY
                        REFERENCES github_repos(gh_repo_id) ON DELETE CASCADE,
    first_issue_number  INTEGER NOT NULL
                        REFERENCES weekly_issues(number),
    issue_url           TEXT NOT NULL,
    recommendation      TEXT,
    parsed_at           TEXT NOT NULL
);

CREATE INDEX idx_weekly_extras_issue
    ON weekly_extras(first_issue_number DESC);
```

每个 repo 只保存首次进入阮一峰周刊的期号。事件时间从 `weekly_issues.published_at` 获取。

### 3.4 `zread_events`

```sql
CREATE TABLE zread_events (
    id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    gh_repo_id           INTEGER NOT NULL
                         REFERENCES github_repos(gh_repo_id) ON DELETE CASCADE,
    week_start           TEXT NOT NULL,
    week_end             TEXT,
    week_label           TEXT,
    rank_in_week         INTEGER NOT NULL,
    description_zh       TEXT,
    zread_repo_id        TEXT,
    wiki_id              TEXT,
    zread_week_start_raw TEXT,
    zread_week_end_raw   TEXT,
    zread_year_inferred  INTEGER,
    fetched_at           TEXT NOT NULL,

    UNIQUE(gh_repo_id, week_start)
);

CREATE INDEX idx_zread_events_repo_time
    ON zread_events(gh_repo_id, week_start DESC);
```

同一 repo 可以连续多周出现，每周是一条独立事件。

### 3.5 `discovery_submissions`

```sql
CREATE TABLE discovery_submissions (
    hn_id           INTEGER PRIMARY KEY,
    gh_repo_id      INTEGER NOT NULL
                    REFERENCES github_repos(gh_repo_id) ON DELETE CASCADE,
    title           TEXT NOT NULL,
    hn_url          TEXT NOT NULL,
    source_url      TEXT,
    score           INTEGER NOT NULL DEFAULT 0,
    comments        INTEGER NOT NULL DEFAULT 0,
    published_at    TEXT NOT NULL,
    first_seen_at   TEXT NOT NULL,
    last_seen_at    TEXT NOT NULL
);

CREATE INDEX idx_discovery_submissions_repo_time
    ON discovery_submissions(gh_repo_id, published_at DESC);
CREATE INDEX idx_discovery_submissions_time
    ON discovery_submissions(published_at DESC, hn_id DESC);
```

不再单独保留 `discovery_extras`。当前代码中的 enrichment 状态属于旧的分阶段落库实现；统一主表后，GitHub 元数据和可用状态由 `github_repos` 承担，投稿事实由本表承担。

---

## 4. 统一写入流程

### 4.1 Enricher 接口

```go
type RepoEnricher interface {
    EnsureGitHubRepo(
        ctx context.Context,
        owner string,
        name string,
        force bool,
    ) (model.GitHubRepo, error)
}
```

行为：

1. 先按规范化后的 `(owner, name)` 查询主表。
2. 若存在且 `enriched_at` 距当前不足 30 分钟，直接返回主表数据。
3. 否则调用共享 `internal/github.Client` 获取最新 repo 数据。
4. 按 `gh_repo_id` UPSERT 主表，覆盖 owner/name 和 GitHub 元数据。
5. GitHub 返回 404 时，把已知 repo 标记为 `is_available = 0`；来源历史事实不删除。

### 4.2 来源写入必须事务化

```go
func (s *SQLiteStore) AttachSourceEvent(
    repoID int64,
    source model.SourceType,
    eventAt time.Time,
    writeExtra func(tx *sql.Tx) error,
) error
```

单个事务内完成：

1. UPSERT 对应附表；
2. 根据三张附表重算 `source_types_json`；
3. 计算该 repo 所有来源事件的最小、最大时间；
4. 更新主表的 `first_event_at/latest_event_at/record_updated_at`；
5. 提交事务。

禁止使用“先 SELECT JSON、Go 合并、再无条件 UPDATE”的跨事务读改写方式，否则并发 spider 可能互相覆盖来源集合。

### 4.3 Spider 调用顺序

```go
repo, err := enricher.EnsureGitHubRepo(ctx, owner, name, false)
if err != nil {
    // 当前事件无法获得 gh_repo_id，记录日志并进入既有重试机制。
    continue
}

err = store.AttachSourceEvent(repo.GhRepoID, source, occurredAt, func(tx *sql.Tx) error {
    return upsertSourceSpecificRow(tx, sourcePayload)
})
```

`EnsureGitHubRepo` 命中去抖缓存时，`AttachSourceEvent` 仍然执行。

---

## 5. 查询接口

### 5.1 `GET /api/v1/repos`

参数：

| 参数 | 默认值 | 说明 |
|---|---|---|
| `source` | 全部 | 可选，逗号分隔；语义为命中任一来源 |
| `lang` | 全部 | `__uncategorized__` 表示空语言 |
| `sort` | `latest_event_at` | `latest_event_at / stars / pushed_at` |
| `order` | `desc` | `asc / desc` |
| `page` | `1` | 1-based |
| `page_size` | `30` | 最大 50 |

默认排序必须稳定：

```sql
ORDER BY latest_event_at DESC, gh_repo_id DESC
LIMIT ? OFFSET ?
```

当用户按 stars 或 pushed_at 排序时，也追加 `gh_repo_id DESC` 作为稳定次级排序键，避免翻页期间同值记录漂移。

列表项返回扁平的完整 Repo Card 字段，以及用于首帧渲染的 feed fields。客户端会把同一个 JSON object 解码为 `StarcatRepoCardDTO + feed fields`，因此后端不要嵌套 `card` 对象，也不要把 `source_types/latest_event_at/weekly/zread/discovery` 塞进通用 `StarcatRepoCardDTO`。

```json
{
  "schema_version": 1,
  "meta": {
    "total": 420,
    "page": 1,
    "page_size": 30,
    "next_page": 2,
    "generated_at": "2026-06-12T00:00:00Z"
  },
  "data": [
    {
      "gh_repo_id": 123456,
      "owner": "microsoft",
      "name": "markitdown",
      "full_name": "microsoft/markitdown",
      "html_url": "https://github.com/microsoft/markitdown",
      "description": "Python tool for converting files...",
      "homepage": "https://example.com",
      "language": "Python",
      "stars": 130672,
      "forks": 8421,
      "watchers": 410,
      "subscribers": 120,
      "open_issues": 88,
      "owner_avatar": "https://avatars.githubusercontent.com/...",
      "default_branch": "main",
      "license_spdx": "MIT",
      "topics": ["markdown", "converter"],
      "pushed_at": "2026-06-10T12:00:00Z",
      "updated_at": "2026-06-10T12:00:00Z",
      "created_at": "2024-11-01T00:00:00Z",
      "is_archived": false,
      "is_fork": false,
      "is_private": false,
      "is_available": true,
      "source_types": ["weekly", "zread"],
      "first_event_at": "2026-04-15T00:00:00Z",
      "latest_event_at": "2026-06-08T00:00:00Z",
      "weekly": {
        "issue_number": 342,
        "issue_url": "https://github.com/ruanyf/weekly/blob/master/docs/issue-342.md",
        "recommendation": "很实用的文档转换工具"
      },
      "zread": {
        "week_start": "2026-06-08",
        "week_end": "2026-06-14",
        "week_label": "This Week",
        "rank_in_week": 6,
        "description_zh": "文件转 Markdown 的 Python 工具"
      },
      "discovery": null
    }
  ]
}
```

约定：

- `source_types` 是来源集合的唯一判断依据。
- `latest_event_at` 是列表最近时间的唯一真源；客户端不得从 `weekly/zread/discovery` 快照反推最近时间。
- `weekly/zread/discovery` 是列表首帧代表快照：`weekly` 固定使用首次收录记录，`zread` 使用该 repo 最新一周事件，`discovery` 使用该 repo 最新一次 HN 投稿。
- `is_available = 0` 的 repo 默认不返回。

### 5.2 `GET /api/v1/repos/{gh_repo_id}`

详情接口按不可变 ID 查询，返回完整 Repo Card 和完整事件时间线。`repo` 字段必须包含与列表相同的 Repo Card 字段、`is_available`、`source_types`、`first_event_at`、`latest_event_at` 和三源代表快照；客户端会用它增量更新 hero 公共字段。

```json
{
  "schema_version": 1,
  "data": {
    "repo": {
      "gh_repo_id": 123456,
      "owner": "microsoft",
      "name": "markitdown",
      "full_name": "microsoft/markitdown",
      "html_url": "https://github.com/microsoft/markitdown",
      "description": "Python tool for converting files...",
      "homepage": "https://example.com",
      "language": "Python",
      "stars": 130672,
      "forks": 8421,
      "watchers": 410,
      "subscribers": 120,
      "open_issues": 88,
      "owner_avatar": "https://avatars.githubusercontent.com/...",
      "default_branch": "main",
      "license_spdx": "MIT",
      "topics": ["markdown", "converter"],
      "pushed_at": "2026-06-10T12:00:00Z",
      "updated_at": "2026-06-10T12:00:00Z",
      "created_at": "2024-11-01T00:00:00Z",
      "is_archived": false,
      "is_fork": false,
      "is_private": false,
      "is_available": true,
      "source_types": ["weekly", "zread", "discovery"],
      "first_event_at": "2026-04-15T00:00:00Z",
      "latest_event_at": "2026-06-08T00:00:00Z",
      "weekly": {
        "issue_number": 342,
        "issue_url": "https://github.com/ruanyf/weekly/blob/master/docs/issue-342.md",
        "recommendation": "很实用的文档转换工具"
      },
      "zread": {
        "week_start": "2026-06-08",
        "week_end": "2026-06-14",
        "week_label": "This Week",
        "rank_in_week": 3,
        "description_zh": "文件转 Markdown 的 Python 工具"
      },
      "discovery": {
        "hn_id": 39812345,
        "title": "Show HN: Markitdown",
        "score": 234,
        "comments": 87,
        "published_at": "2026-05-25T14:30:00Z"
      }
    },
    "events": [
      {
        "id": "zread:2026-06-08",
        "source": "zread",
        "occurred_at": "2026-06-08T00:00:00Z",
        "url": "https://zread.ai/repos/microsoft/markitdown",
        "zread": {
          "week_start": "2026-06-08",
          "week_end": "2026-06-14",
          "rank_in_week": 3,
          "description_zh": "..."
        }
      },
      {
        "id": "discovery:39812345",
        "source": "discovery",
        "occurred_at": "2026-05-25T14:30:00Z",
        "url": "https://news.ycombinator.com/item?id=39812345",
        "discovery": {
          "hn_id": 39812345,
          "title": "Show HN: Markitdown",
          "score": 234,
          "comments": 87
        }
      },
      {
        "id": "weekly:342",
        "source": "weekly",
        "occurred_at": "2026-04-15T00:00:00Z",
        "url": "https://github.com/ruanyf/weekly/blob/master/docs/issue-342.md",
        "weekly": {
          "issue_number": 342,
          "recommendation": "..."
        }
      }
    ]
  }
}
```

事件排序固定为：

```sql
ORDER BY occurred_at DESC, event_id DESC
```

`is_available = 0` 的 repo 详情仍返回 200，携带完整可用的历史来源事实和 `repo.is_available = false`。只有 `gh_repo_id` 从未建立或没有任何来源事件时才返回 404。这样客户端可以保留列表首帧、展示历史时间线，并明确提示仓库当前不可用。

### 5.3 `GET /api/v1/repos/languages`

语言接口只统计三源合并后的 `github_repos` 可见集合，不支持 `source` 参数。统计范围等同于默认列表：至少拥有一个来源附表、`is_available = 1` 的 repo；`__uncategorized__` 表示 `language IS NULL OR language = ''`。

```json
{
  "schema_version": 1,
  "meta": { "total": 1648, "generated_at": "2026-06-12T00:00:00Z" },
  "data": [
    { "key": "Python", "label": "Python", "count": 318 },
    { "key": "TypeScript", "label": "TypeScript", "count": 226 },
    { "key": "__uncategorized__", "label": "Uncategorized", "count": 7 }
  ]
}
```

### 5.4 删除旧公开接口

```diff
- GET /api/v1/weekly
- GET /api/v1/weekly/{owner}/{repo}
- GET /api/v1/issues
- GET /api/v1/issues/{number}
- GET /api/v1/zread
- GET /api/v1/discovery
- GET /api/v1/discovery/{owner}/{repo}
+ GET /api/v1/repos
+ GET /api/v1/repos/{gh_repo_id}
+ GET /api/v1/repos/languages
```

周刊期号数据仍保存在 `weekly_issues`，但不再作为客户端独立浏览入口。详情事件直接携带期号 URL。

### 5.5 内部接口

```text
POST /internal/sync/weekly
POST /internal/sync/zread
POST /internal/sync/discovery
POST /internal/rebuild-aggregates
```

`rebuild-aggregates` 从三张来源附表重算主表的 `source_types_json`、`first_event_at`、`latest_event_at`，用于修复冗余聚合字段漂移。

---

## 6. 缓存与分页

首期不增加 handler 级业务内存分页缓存。理由：

1. SQLite 单表索引分页足以支撑当前数千条规模；
2. 带 source/lang/sort/page 组合后，缓存键和失效条件明显变复杂；
3. spider 写入后的缓存一致性会增加额外风险。

保留标准 HTTP 缓存能力：

- 根据查询参数和数据库聚合版本生成 `ETag`；
- 支持 `If-None-Match` 返回 304；
- 每次来源事务提交后更新数据库级 aggregate revision。

如果上线后观测到 SQL 查询成为瓶颈，再增加 1~5 分钟 TTL 的查询缓存和 singleflight，不在首期提前实现。

OFFSET 分页在当前规模可接受。所有排序都必须带 `gh_repo_id` 次级排序，避免同值记录造成跨页重复或遗漏。

---

## 7. 调度

| Cron（UTC） | Job | 聚合后行为 |
|---|---|---|
| 周一 00:00 | weekly fetch | 解析期号和 repo，ensure GitHub repo，写 `weekly_extras` |
| 周一 06:00 | zread fetch | ensure GitHub repo，逐周写 `zread_events` |
| 每小时 | discovery collect | 抓 Show HN，ensure GitHub repo，写 submissions |

删除 Discovery classify retry cron。GitHub enrichment 重试继续沿用当前 `pending / ready / retryable / unavailable` 的容错语义，但最终统一落到主表的 `is_available/enriched_at`。

---

## 8. 实施顺序

| 阶段 | 工作内容 | 验证 |
|---|---|---|
| 1 | 重写 schema 与 model | 空库建表测试、外键测试 |
| 2 | 实现主表 UPSERT 和来源事务 | 并发来源写入不丢 source、时间聚合正确 |
| 3 | 抽取统一 enricher | 30 分钟内复用 GitHub 元数据，但仍写入第二来源 |
| 4 | 改造 weekly / zread / discovery 三条 pipeline | 三源各自可独立同步，重复 repo 聚合为一条 |
| 5 | 实现 list / detail / languages handler | handler 单测覆盖筛选、稳定排序、分页、unavailable 详情、404 |
| 6 | 删除旧公开 handler 和路由 | `rg` 确认无旧路由残留 |
| 7 | 本地端到端验证 | 空库同步三源，curl 验证列表、详情、时间线、语言 |
| 8 | 更新 README / CHANGELOG | 接口示例与真实响应一致 |

后端接口和 fixture 稳定后，再开始 R-05 客户端施工。

---

## 9. 测试要求

至少覆盖：

1. 同 repo 先写 weekly、30 分钟内再写 zread，最终 `source_types` 包含两者。
2. 历史 weekly 数据导入时，排序使用期号发布时间而不是导入时间。
3. 同一 repo 多周 zread 事件全部保留，详情按时间倒序。
4. 同一 repo 多次 Show HN 投稿全部保留。
5. rename / transfer 后按同一 `gh_repo_id` 更新 owner/name，ID 详情接口仍命中。
6. 并发写两个来源时不发生 source JSON 丢失。
7. `latest_event_at` 相同时按 `gh_repo_id` 稳定分页。
8. `source/lang/sort/order` 非法参数返回明确 400，不拼接未校验 SQL。
9. GitHub 404 标记不可用，但历史来源事件仍可通过内部数据检查。
10. `rebuild-aggregates` 重算结果与在线写入结果一致。
11. `GET /api/v1/repos/{gh_repo_id}` 对 `is_available = 0` 的 repo 返回 200 + 完整历史 events，而不是 404。
12. `GET /api/v1/repos/languages` 统计三源合并后的可见 `github_repos`，不接受 `source` 过滤。

---

## 10. 风险与取舍

### 10.1 冷启动 GitHub 配额

历史 weekly 数据超过 3000 条，首次 enrich 可能接近单 token 小时配额。实现必须复用当前共享 GitHub Client 的 rate-limit 处理，并允许任务跨窗口继续，不能假设一次任务必然跑完。

### 10.2 `(owner, name)` 首次解析仍依赖 GitHub

历史来源只有 owner/name，没有 `gh_repo_id` 时，首次统一必然需要请求 GitHub。仓库已删除或私有化时无法建立主表身份，这类记录记录日志并跳过公开 feed，不伪造 ID。

### 10.3 冗余聚合字段漂移

`source_types_json` 和事件时间是查询优化字段，不是真源。通过来源事务和 `rebuild-aggregates` 双重约束控制漂移。

### 10.4 不提前实现复杂缓存

当前量级下，正确的时间语义、原子写入和稳定分页比内存缓存更重要。缓存必须基于观测结果再引入。

---

## 11. 最终验收标准

- 三源相同 `gh_repo_id` 在列表中只出现一次。
- 默认列表严格按最近来源事件倒序，而不是按导入时间倒序。
- 详情接口以 `gh_repo_id` 查询，rename / transfer 不破坏导航身份。
- 详情 `repo` 返回完整 Repo Card 字段；客户端不需要再调用 GitHub `/repos` 补 hero。
- 不可用 repo 的详情返回 `repo.is_available=false` 和历史 events，而不是直接 404。
- 详情时间线完整展示 weekly、zread、discovery 的全部事件。
- Discovery 不包含任何已删除的 LLM 分类字段和任务。
- 客户端只需消费统一列表、ID 详情和语言接口。
- 删除数据库重建后，后端测试与本地三源端到端验证全部通过。
