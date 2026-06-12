# weekly-api 3 源聚合改造方案 (R-04)

> **状态**: 设计中（2026-06-12，待 dong4j 拍板施工）
> **影响范围**: 仅 weekly-api 后端（`supports/starcat-weekly-api/` 独立 Go 服务）
> **客户端影响**: 现有 `WeeklyAPI` 三个 endpoint 调用全部废弃，客户端在独立 PR (R-05) 单独对接
> **数据迁移**: **无**——项目未上线，删 db 直接重建
> **兼容性**: **不保留**——schema/接口/DTO 全部破坏性重写

---

## 0. TL;DR

把 weekly-api 现在的 **3 张孤岛表 + 3 个独立 endpoint** 重构为：

```
┌─────────────────── github_repos (主表) ──────────────────┐
│ PRIMARY KEY: gh_repo_id (int64, GitHub 不可变 ID)        │
│ 包含：所有 GitHub API repo 字段 + source_types 聚合     │
└─────────┬───────────────┬───────────────┬───────────────┘
          ▼               ▼               ▼
   weekly_extras   zread_extras   discovery_extras
                                  + discovery_submissions
```

对外只暴露 1 个聚合接口 `GET /api/v1/repos`（+ 2 个辅助接口）。

**核心收益**：
1. 同一 repo 跨多源收录时 GitHub API 只调 1 次（配额省 50%+）
2. 主表 `gh_repo_id` 唯一键彻底解决 owner/name 在 rename/transfer 后断裂的问题
3. 客户端调 1 个接口拿到去重 + 聚合 + 分页结果，不再做数据清洗
4. `source_types: ["weekly", "zread"]` 让客户端能在详情页"来源时间线"准确渲染

---

## 1. 背景与现状

### 1.1 当前 schema：3 张孤岛表

| 表 | 唯一键 | 行数 | 时间维度 | 1:N |
|---|---|---:|---|---|
| `projects` | `(repo_owner, repo_name)` | 3077（已 enrich 1648）| 无（仅 `enriched_at`） | 否（每 repo 一行）|
| `zread_trending` | `(week_start, owner, name)` | 0（cron 周一 06:00 UTC）| `week_start` | 是（按周）|
| `discovery_repos` + `discovery_submissions` | `(owner, repo)` + `hn_id` | 0（需 `LLM_API_KEY`）| `published_at`（HN 投稿）| 是（按投稿）|

### 1.2 当前 3 个 endpoint

```
GET /api/v1/weekly?page=&page_size=&issue=&lang=&sort=    阮一峰列表
GET /api/v1/weekly/{owner}/{repo}                         阮一峰单详情
GET /api/v1/issues / GET /api/v1/issues/{number}          阮一峰期号
GET /api/v1/zread?week=this|last|YYYY-MM-DD&limit=        zread 周列表
GET /api/v1/discovery?category=&page=&page_size=          Show HN AI 发现
GET /api/v1/discovery/{owner}/{repo}                      Show HN 单详情
```

### 1.3 当前 DTO 形态不一致

```go
// trending / weekly 用平级 extension：
type StarcatRepoCardDTO struct {
    GhRepoID int64 ...
    Trending *TrendingExtension `json:"trending,omitempty"`
    Weekly   *WeeklyExtension   `json:"weekly,omitempty"`
}

// discovery 用套娃：
type DiscoveryItemDTO struct {
    Repo      StarcatRepoCardDTO `json:"repo"`
    Discovery DiscoveryExtension `json:"discovery"`
}
```

### 1.4 三大痛点

1. **GitHub API 配额浪费**：同一 repo（如 `microsoft/markitdown`）同时上阮一峰 + zread → 两个 spider 各调一次 `GET /repos/{o}/{r}` 配额翻倍
2. **owner/name 唯一键不可靠**：repo rename 或 transfer 后老 (owner, name) 数据成孤儿，新数据被当成"新 repo"重复入库
3. **前端聚合负担**：Starcat 客户端要调 3 个接口、按 owner/name 自行去重、合并 source 标识

---

## 2. 设计决策

### 2.1 主键选择：`gh_repo_id`

GitHub API 返回的 `id` 是不可变 int64。无论 rename / transfer / fork 重命名，ID 不变。spider 拿到 (owner, name) 后**必然要调 GitHub API enrich**，所以 `gh_repo_id` 一定有，没有额外成本。

二级唯一约束 `UNIQUE(owner, name)` 保留，配合 `ON CONFLICT(gh_repo_id) DO UPDATE` 处理 rename：旧 owner/name 自动被覆盖。

### 2.2 主表 vs 附表拆分原则

| 字段类型 | 归属 |
|---|---|
| GitHub API 原生字段（stars, language, license_spdx, topics, ...） | 主表 `github_repos` |
| 跨源聚合字段（source_types, first_seen_at, last_seen_at, enriched_at） | 主表 |
| 数据源专属字段（issue_number / week_start / hn_id） | 各自附表 |
| 数据源 1:N 事件（zread 多周、HN 多次投稿） | 附表带 AUTOINCREMENT id 主键 |

### 2.3 spider 改造原则

每个 spider 改 2 阶段：

```
阶段 A：从源站点抓取，提取 (owner, name) + 源专属字段（issue / week / hn_id）
阶段 B：调统一 enricher.EnsureRepo(owner, name, source) → 拿到 gh_repo_id → 写主表 + 写附表
```

**关键约束**：所有 spider 共用 `enricher.EnsureRepo`，内部带"短期 enrich 去抖"——同一 repo 在 30 分钟内已 enrich 过则直接复用主表数据，不重复打 GitHub API。

### 2.4 schema 演进策略

项目未上线 → **不写迁移**。`createSchema(db)` 单文件一次性建好所有表；任何字段变更直接改 `createSchema` 函数，本地 `rm weekly.db` 重建即可。与 4 backend 当前"全新服务语态"一致（详见 §3.9.4）。

---

## 3. 主表 schema

```sql
CREATE TABLE github_repos (
    -- 主键（GitHub 不可变 ID）
    gh_repo_id          INTEGER PRIMARY KEY,

    -- 仓库标识
    owner               TEXT NOT NULL,
    name                TEXT NOT NULL,
    full_name           TEXT NOT NULL,         -- "owner/name" 冗余，便于直接查询

    -- GitHub API enrich 字段
    description         TEXT,
    homepage            TEXT,
    language            TEXT,                  -- GitHub 标注的 primary language（最权威）
    stars               INTEGER NOT NULL DEFAULT 0,
    forks               INTEGER NOT NULL DEFAULT 0,
    watchers            INTEGER NOT NULL DEFAULT 0,
    subscribers         INTEGER NOT NULL DEFAULT 0,
    open_issues         INTEGER NOT NULL DEFAULT 0,
    owner_avatar        TEXT,
    default_branch      TEXT,
    license_spdx        TEXT,
    topics_json         TEXT NOT NULL DEFAULT '[]',  -- JSON array
    pushed_at           TEXT,
    updated_at          TEXT,
    created_at          TEXT,
    is_archived         INTEGER NOT NULL DEFAULT 0,
    is_fork             INTEGER NOT NULL DEFAULT 0,
    is_private          INTEGER NOT NULL DEFAULT 0,

    -- 跨源聚合字段
    source_types_json   TEXT NOT NULL DEFAULT '[]',  -- ["weekly", "zread", "discovery"]
    first_seen_at       TEXT NOT NULL,               -- 首次入库时间
    last_seen_at        TEXT NOT NULL,               -- 最近一次被任意源命中
    enriched_at         TEXT,                        -- 最近一次 GitHub API 补全
    is_available        INTEGER NOT NULL DEFAULT 1,  -- GitHub 404/已删除时置 0

    UNIQUE(owner, name)
);

CREATE INDEX idx_github_repos_lang        ON github_repos(language);
CREATE INDEX idx_github_repos_stars       ON github_repos(stars DESC);
CREATE INDEX idx_github_repos_pushed      ON github_repos(pushed_at DESC);
CREATE INDEX idx_github_repos_first_seen  ON github_repos(first_seen_at DESC);
CREATE INDEX idx_github_repos_last_seen   ON github_repos(last_seen_at DESC);
```

**字段语义说明**：
- `first_seen_at` = 该 repo 第一次被任何 spider 收录的时间；用作"最近发现"语义的排序键
- `last_seen_at` = 该 repo 最近一次被任意 spider 命中（不限源）；用作"还在持续受关注"语义
- `enriched_at` = 最近一次成功调 GitHub API 时间；enricher 用此字段做"30 分钟内不重复 enrich"判断
- `source_types_json` = 该 repo 命中过的所有源；UI 详情页"来源时间线"chip 列表的总开关



---

## 4. 附表 schema

### 4.1 weekly_extras（阮一峰）

```sql
CREATE TABLE weekly_extras (
    gh_repo_id          INTEGER PRIMARY KEY REFERENCES github_repos(gh_repo_id),
    first_issue_number  INTEGER REFERENCES weekly_issues(number),
    issue_url           TEXT,                   -- 派生字段：可在查询时拼，存一份方便
    recommendation      TEXT,                   -- 阮一峰原文中的中文推荐语（parser 解析）
    parsed_at           TEXT NOT NULL
);

CREATE INDEX idx_weekly_extras_issue ON weekly_extras(first_issue_number DESC);
```

**1:1 关系**：每个 repo 在阮一峰只有一个"首次收录的期号"。

### 4.2 zread_extras（zread 周 trending）

```sql
CREATE TABLE zread_extras (
    -- AUTOINCREMENT 因为 1:N（同一 repo 多周复现）
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    gh_repo_id          INTEGER NOT NULL REFERENCES github_repos(gh_repo_id),
    week_start          TEXT NOT NULL,
    week_end            TEXT NOT NULL,
    week_label          TEXT NOT NULL,          -- "This Week" / "Last Week" / 历史空串
    rank_in_week        INTEGER NOT NULL,
    description_zh      TEXT,                   -- zread 的中文描述（阮一峰没有）
    zread_repo_id       TEXT,                   -- zread 内部 UUID
    wiki_id             TEXT,
    -- v0.4.1 跨年回溯字段（保留）
    zread_week_start_raw TEXT,
    zread_week_end_raw   TEXT,
    zread_year_inferred  INTEGER,
    fetched_at          TEXT NOT NULL,

    UNIQUE(gh_repo_id, week_start)
);

CREATE INDEX idx_zread_extras_repo ON zread_extras(gh_repo_id);
CREATE INDEX idx_zread_extras_week ON zread_extras(week_start DESC);
```

**1:N 关系**：同一 repo 跨多周复现 → 多行；UI 详情页时间线渲染。

### 4.3 discovery_extras + discovery_submissions（Show HN）

```sql
-- repo 维度的分类状态（1:1）
CREATE TABLE discovery_extras (
    gh_repo_id          INTEGER PRIMARY KEY REFERENCES github_repos(gh_repo_id),

    -- AI 分类
    category            TEXT NOT NULL DEFAULT 'unknown',
    classify_status     TEXT NOT NULL DEFAULT 'pending',
    classify_confidence REAL,
    classify_reason     TEXT,
    classify_method     TEXT,
    classify_model      TEXT,
    classify_attempts   INTEGER NOT NULL DEFAULT 0,
    classify_next_retry_at TEXT,
    classify_error      TEXT,
    classified_at       TEXT,

    -- README 分类原料（不放主表，因为只 Show HN 用）
    readme_excerpt      TEXT NOT NULL DEFAULT ''
);

CREATE INDEX idx_discovery_extras_classify
    ON discovery_extras(classify_status, classify_next_retry_at, category);

-- 投稿事实表（1:N，同一 repo 多次 HN 投稿）
CREATE TABLE discovery_submissions (
    hn_id           INTEGER PRIMARY KEY,
    gh_repo_id      INTEGER NOT NULL REFERENCES github_repos(gh_repo_id),
    title           TEXT NOT NULL,
    hn_url          TEXT NOT NULL,
    source_url      TEXT,
    score           INTEGER NOT NULL DEFAULT 0,
    comments        INTEGER NOT NULL DEFAULT 0,
    published_at    TEXT NOT NULL,
    first_seen_at   TEXT NOT NULL,
    last_seen_at    TEXT NOT NULL
);

CREATE INDEX idx_discovery_submissions_repo
    ON discovery_submissions(gh_repo_id, published_at DESC);
CREATE INDEX idx_discovery_submissions_published
    ON discovery_submissions(published_at DESC, score DESC);
```

**为什么 Show HN 拆 2 表**：分类状态是 repo 级别的（一个 repo 只属于一个 category），但投稿是事件级别的（同 repo 可有多次投稿，每次有独立 hn_id / score / 投稿时间）。

### 4.4 weekly_issues（保留，不改）

```sql
CREATE TABLE weekly_issues (
    number       INTEGER PRIMARY KEY,
    published_at TEXT,
    source_url   TEXT,
    parsed_at    TEXT
);
```

---

## 5. enricher 统一入口

### 5.1 接口

```go
// internal/enricher/repo.go

// EnsureRepo 是所有 spider 写主表前的统一入口。
//
// 流程：
//   1. 查主表是否已有该 (owner, name)；若有且 enriched_at 在 30 分钟内，直接返回 gh_repo_id
//   2. 否则调 GitHub API 拿完整 repo 数据
//   3. UPSERT 主表（ON CONFLICT(gh_repo_id) DO UPDATE 全字段覆盖 + source_types 追加）
//   4. 返回 gh_repo_id 给调用方写附表
//
// 短期去抖（30 分钟）保证：阮一峰 cron + zread cron 在同一小时内跑、命中同一 repo 时只调 1 次 GitHub API。
type Enricher interface {
    EnsureRepo(ctx context.Context, owner, name, source string) (ghRepoID int64, err error)
}
```

### 5.2 主表 UPSERT 实现

```go
func (s *SQLiteStore) UpsertGitHubRepo(repo model.GitHubRepo, source string) error {
    now := time.Now().UTC().Format(time.RFC3339)

    // 1. 先查现有 source_types
    var existingSourcesJSON string
    err := s.db.QueryRow(
        `SELECT source_types_json FROM github_repos WHERE gh_repo_id = ?`,
        repo.GhRepoID,
    ).Scan(&existingSourcesJSON)

    var sources []string
    if err == nil {
        json.Unmarshal([]byte(existingSourcesJSON), &sources)
    }

    // 2. 追加新 source 并去重
    sources = appendUnique(sources, source)
    sourcesJSON, _ := json.Marshal(sources)

    // 3. UPSERT（ON CONFLICT 全字段覆盖 + source_types 用 Go 计算后传入）
    _, err = s.db.Exec(`
        INSERT INTO github_repos (
            gh_repo_id, owner, name, full_name,
            description, homepage, language, stars, forks, watchers, subscribers,
            open_issues, owner_avatar, default_branch, license_spdx, topics_json,
            pushed_at, updated_at, created_at,
            is_archived, is_fork, is_private,
            source_types_json, first_seen_at, last_seen_at, enriched_at, is_available
        ) VALUES (?, ?, ?, ?,  ?, ?, ?, ?, ?, ?, ?,  ?, ?, ?, ?, ?,  ?, ?, ?,  ?, ?, ?,  ?, ?, ?, ?, ?)
        ON CONFLICT(gh_repo_id) DO UPDATE SET
            owner = excluded.owner,                        -- 处理 rename / transfer
            name = excluded.name,
            full_name = excluded.full_name,
            description = excluded.description,
            homepage = excluded.homepage,
            language = excluded.language,
            stars = excluded.stars,
            forks = excluded.forks,
            watchers = excluded.watchers,
            subscribers = excluded.subscribers,
            open_issues = excluded.open_issues,
            owner_avatar = excluded.owner_avatar,
            default_branch = excluded.default_branch,
            license_spdx = excluded.license_spdx,
            topics_json = excluded.topics_json,
            pushed_at = excluded.pushed_at,
            updated_at = excluded.updated_at,
            -- created_at 不覆盖（GitHub 不变量，已有值更可靠）
            is_archived = excluded.is_archived,
            is_fork = excluded.is_fork,
            is_private = excluded.is_private,
            source_types_json = excluded.source_types_json,  -- Go 已合并好
            -- first_seen_at 不覆盖（保留首次入库时间）
            last_seen_at = excluded.last_seen_at,
            enriched_at = excluded.enriched_at,
            is_available = excluded.is_available
    `, repo.GhRepoID, repo.Owner, repo.Name, repo.FullName,
        repo.Description, repo.Homepage, repo.Language, repo.Stars, repo.Forks, repo.Watchers, repo.Subscribers,
        repo.OpenIssues, repo.OwnerAvatar, repo.DefaultBranch, repo.LicenseSpdx, repo.TopicsJSON,
        repo.PushedAt, repo.UpdatedAt, repo.CreatedAt,
        boolToInt(repo.IsArchived), boolToInt(repo.IsFork), boolToInt(repo.IsPrivate),
        string(sourcesJSON), now, now, now, 1,
    )
    return err
}
```

> ⚠️ `source_types_json` 用 Go 层合并而不是 SQL `json_each`，避免 SQLite JSON1 扩展依赖问题；性能差异可忽略（每次 enrich 一次查询 + 一次写入）。



### 5.3 spider 调用样例

```go
// 阮一峰 spider:
for _, item := range issueParser.Items() {
    ghRepoID, err := enricher.EnsureRepo(ctx, item.Owner, item.Name, "weekly")
    if err != nil { /* skip & log */ continue }
    store.UpsertWeeklyExtras(model.WeeklyExtras{
        GhRepoID:         ghRepoID,
        FirstIssueNumber: item.IssueNumber,
        IssueURL:         item.IssueURL,
        Recommendation:   item.RecText,
    })
}

// zread spider:
for _, t := range zreadResp.Trending {
    ghRepoID, err := enricher.EnsureRepo(ctx, t.Owner, t.Name, "zread")
    if err != nil { continue }
    store.UpsertZreadExtras(model.ZreadExtras{
        GhRepoID: ghRepoID, WeekStart: t.WeekStart, WeekEnd: t.WeekEnd,
        WeekLabel: t.WeekLabel, RankInWeek: t.Rank, DescriptionZh: t.Desc,
    })
}

// discovery service:
for _, hn := range hnRepos {
    ghRepoID, err := enricher.EnsureRepo(ctx, hn.Owner, hn.Repo, "discovery")
    if err != nil { continue }
    store.UpsertDiscoveryExtras(model.DiscoveryExtras{ GhRepoID: ghRepoID, ReadmeExcerpt: ... })
    store.UpsertDiscoverySubmission(model.DiscoverySubmission{ HnID: hn.ID, GhRepoID: ghRepoID, ... })
}
```

---

## 6. 接口设计

### 6.1 GET `/api/v1/repos`（主接口）

| 参数 | 默认 | 说明 |
|---|---|---|
| `source` | 不传 = 全部 | 逗号分隔过滤：`weekly,zread,discovery`；只返回 `source_types_json` 中**包含任意指定 source** 的 repo |
| `lang` | 不传 = 全部 | 语言过滤；`__uncategorized__` 表示 `language IS NULL OR language = ''` |
| `sort` | `first_seen_at` | `first_seen_at` / `last_seen_at` / `stars` / `pushed_at` |
| `order` | `desc` | `asc` / `desc` |
| `page` | 1 | 1-based |
| `page_size` | 30 | max 50（防恶意分页）|

**SQL 关键片段**：

```sql
-- source 过滤：JSON1 like 匹配（每源独立 OR）
WHERE (source_types_json LIKE '%"weekly"%' OR source_types_json LIKE '%"zread"%')

-- lang 过滤
AND ( language = ?  OR  (? = '__uncategorized__' AND (language IS NULL OR language = '')) )

-- 排序
ORDER BY first_seen_at DESC

-- 分页
LIMIT 30 OFFSET 0
```

> 主接口走主表单表查询，附表通过额外的 IN 查询批量装填（详见 6.2）。

**响应**：

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
      "description": "Python tool for converting files...",
      "homepage": "https://...",
      "language": "Python",
      "stars": 130672,
      "forks": 8421,
      "watchers": 410,
      "license_spdx": "MIT",
      "topics": ["markdown", "converter"],
      "pushed_at": "2026-06-10T...",
      "updated_at": "2026-06-10T...",
      "created_at": "2024-11-01T...",
      "owner_avatar": "https://...",
      "default_branch": "main",
      "is_archived": false,
      "is_fork": false,
      "is_private": false,
      "source_types": ["weekly", "zread"],
      "first_seen_at": "2026-04-15T...",
      "last_seen_at": "2026-06-08T...",

      "weekly": {
        "issue_number": 342,
        "issue_url": "https://github.com/ruanyf/weekly/blob/master/docs/issue-342.md",
        "recommendation": "很实用的文档转换工具"
      },
      "zread": {
        "week_label": "This Week",
        "week_start": "2026-06-08",
        "rank_in_week": 6,
        "description_zh": "文件转 Markdown 的 Python 工具"
      },
      "discovery": null
    }
  ]
}
```

**关键约定**：
- 客户端**不**用 `weekly/zread/discovery` 三个字段判断"该 repo 是否命中过该源"；要看 `source_types`
- 上面三个 ext 字段**只填一份"代表数据"**：weekly = 首次收录的期号；zread = 最新一周；discovery = 当前的 category + 最新投稿。完整时间线走 6.2 详情接口
- ext 字段为 null 表示该 repo 不在该 source（或未 enrich）

### 6.2 GET `/api/v1/repos/{owner}/{repo}`（详情 + 时间线）

返回该 repo 的完整聚合数据 + **所有源的事件时间线**（按时间倒序）：

```json
{
  "schema_version": 1,
  "data": {
    "repo": {
      "gh_repo_id": 123456,
      "owner": "microsoft",
      "name": "markitdown",
      ... // 同 6.1 单条全字段
      "source_types": ["weekly", "zread", "discovery"]
    },
    "events": [
      {
        "source": "zread",
        "occurred_at": "2026-06-08T00:00:00Z",
        "zread": { "week_start": "2026-06-08", "week_end": "2026-06-14",
                   "week_label": "This Week", "rank_in_week": 3,
                   "description_zh": "..." }
      },
      {
        "source": "discovery",
        "occurred_at": "2026-05-25T14:30:00Z",
        "discovery": { "submission": {
          "hn_id": 39812345, "title": "Show HN: Markitdown",
          "score": 234, "comments": 87, "hn_url": "..."
        } }
      },
      {
        "source": "zread",
        "occurred_at": "2026-05-25T00:00:00Z",
        "zread": { "week_start": "2026-05-25", "rank_in_week": 7, ... }
      },
      {
        "source": "weekly",
        "occurred_at": "2026-04-15T00:00:00Z",
        "weekly": { "issue_number": 342, "recommendation": "..." }
      }
    ]
  }
}
```

**时间归一**：
- `weekly` event → 用 `weekly_issues.published_at`（期号发布日）
- `zread` event → 用 `week_start`（00:00:00Z）
- `discovery` event → 用 `discovery_submissions.published_at`（HN 投稿时间，精确到秒）

### 6.3 GET `/api/v1/repos/languages`（语言聚合）

```json
{
  "schema_version": 1,
  "meta": { "total": 1648, "generated_at": "..." },
  "data": [
    { "key": "Python", "label": "Python", "count": 318 },
    { "key": "TypeScript", "label": "TypeScript", "count": 226 },
    { "key": "Go", "label": "Go", "count": 142 },
    { "key": "Rust", "label": "Rust", "count": 89 },
    { "key": "__uncategorized__", "label": "Uncategorized", "count": 7 }
  ]
}
```

仿 trending-api 的 `GetAggregatedLanguages` 实现（详见 `supports/starcat-trending-api/internal/handler/languages.go`）。**支持 `?source=...` 过滤**——客户端选了 `source=weekly,zread` 后，语言下拉应只显示这两源中实际存在的语言。

```sql
SELECT
    COALESCE(NULLIF(language, ''), '__uncategorized__') AS key,
    COUNT(*) AS count
FROM github_repos
WHERE is_available = 1
  AND (source_types_json LIKE '%"weekly"%' OR source_types_json LIKE '%"zread"%')
GROUP BY key
ORDER BY count DESC, key ASC;
```

### 6.4 旧接口全部删除

```diff
- GET /api/v1/weekly                  ✗ 删
- GET /api/v1/weekly/{owner}/{repo}   ✗ 删
- GET /api/v1/issues                  ✗ 删
- GET /api/v1/issues/{number}         ✗ 删
- GET /api/v1/zread                   ✗ 删
- GET /api/v1/discovery               ✗ 删
- GET /api/v1/discovery/{owner}/{repo} ✗ 删
+ GET /api/v1/repos                            ✓ 新
+ GET /api/v1/repos/{owner}/{repo}             ✓ 新
+ GET /api/v1/repos/languages                  ✓ 新
```

> 项目未上线：直接删除路由 + handler 文件；不写 deprecation 标记。

### 6.5 admin / internal 接口

```
POST /internal/sync/weekly       触发阮一峰 spider
POST /internal/sync/zread        触发 zread spider
POST /internal/sync/discovery    触发 Show HN spider
POST /internal/rebuild           重建主表 source_types_json（修复用，扫所有附表重算）
```

`/internal/rebuild` 是兜底命令：当主表 `source_types_json` 因 bug 漂移时，扫 weekly_extras / zread_extras / discovery_extras 三表，对每个 gh_repo_id 重算 source_types。



---

## 7. cron 调度

保留现有调度表（验证过的稳定时间点），只把内部实现改写：

| Cron 表达式 (UTC) | Job | 改造前 | 改造后 |
|---|---|---|---|
| `0 0 * * 1` 周一 00:00 | 阮一峰 fetch | 写 `projects` | 写 `github_repos` + `weekly_extras` |
| `0 0 * * 1` 周一 00:00 | 阮一峰 enrich（剩余）| `projects.enriched_at` 未填的批量补 | 同左，但走 `enricher.EnsureRepo` |
| `0 6 * * 1` 周一 06:00 | zread fetch | 写 `zread_trending` | 写 `github_repos` + `zread_extras` |
| `0 * * * *` 每小时 | discovery collect | 写 `discovery_repos` + submissions | 写 `github_repos` + `discovery_extras` + `discovery_submissions` |
| `*/15 * * * *` | discovery classify retry | 扫 `pending` 重试 | 改查 `discovery_extras.classify_status` |

---

## 8. 实施 PR 拆分

| PR | 范围 | 工作量 | 依赖 |
|---|---|---:|---|
| **PR-1 schema 重写** | `internal/store/sqlite.go::createSchema` 重写：删 5 张旧表，建 `github_repos` + 4 附表 | 0.5 天 | - |
| **PR-2 model 层** | `internal/model/repo.go` 新增 `GitHubRepo` / `WeeklyExtras` / `ZreadExtras` / `DiscoveryExtras` / `DiscoverySubmission` 5 个 struct | 0.5 天 | PR-1 |
| **PR-3 store 层** | `UpsertGitHubRepo` + 4 个 `Upsert*Extras*` + `QueryRepos` / `QueryRepoDetail` / `AggregateLanguages` | 1.5 天 | PR-2 |
| **PR-4 enricher 抽取** | `internal/enricher/repo.go` 新建；统一 GitHub Client + 30 分钟去抖 | 1 天 | PR-3 |
| **PR-5 spider 改造** | `internal/parser/weekly` / `internal/spider/zread` / `internal/discovery` 三处改造，分别接 `enricher.EnsureRepo` + 写 extras | 1.5 天 | PR-4 |
| **PR-6 handler 重写** | 新建 `handler/repos.go`（list/detail/languages 3 个）；删 `handler/weekly.go` `zread.go` `discovery.go` `issues.go`；改 `cmd/server/main.go` 路由 | 1 天 | PR-3 |
| **PR-7 测试 + e2e** | unit test（store / enricher / handler 各一组）+ 本地 curl 三源端到端联调 | 1 天 | PR-6 |
| **PR-8 文档** | `CHANGELOG.md` v1.0.0 + `README.md` 接口文档 + 同步本设计文档勾选标记 | 0.5 天 | PR-7 |
| **总计** | | **~7.5 天** | |

> 客户端对接（`Starcat/Core/Network/RepoAPI.swift` 替换 `WeeklyAPI`）单独 R-05 PR，预计 +2.5 天。

---

## 9. 风险与未决项

### 9.1 已识别风险

1. **Repo rename / transfer**
   - **场景**：repo 改 owner（个人转组织）后，原 (owner, name) 失效，新 (owner, name) 生效但 `gh_repo_id` 不变
   - **行为**：下次 enrich 时 `ON CONFLICT(gh_repo_id) DO UPDATE` 自动覆盖 owner/name
   - **副作用**：旧 `(old_owner, old_name)` 的 web 链接会 404；GitHub 自身也有 redirect，影响可接受
   - **未决**：是否要存历史 owner/name？现阶段不做

2. **GitHub API 配额**
   - **冷启动**：首次跑要 enrich 所有历史 repo，3077 个 + zread 增量 → 单次最多 ~3500 calls
   - **配额上限**：5000 calls/h（带 token），完全在限内
   - **稳态**：每周一双 spider 共触发约 100~200 calls，可忽略

3. **Show HN 依赖 LLM_API_KEY**
   - **场景**：未配置 LLM_API_KEY 时，所有 discovery_extras 卡在 `classify_status='pending'`
   - **handler 行为**：默认 `/api/v1/repos?source=discovery` **只返回 status='classified' 的**；增加 `?include_pending=true` 给 debug 用
   - **未决**：是否给 pending 加默认 category="unknown" 让前端能看到？倾向不加，避免污染列表

4. **enricher 短期去抖窗口**
   - **当前设计**：30 分钟内同 repo 不重 enrich
   - **风险**：阮一峰 cron + zread cron 跨时段命中同 repo 时，第二次想刷新 stars/topics 会被去抖跳过
   - **缓解**：去抖只在"主动调 EnsureRepo"路径生效；admin `/internal/sync` 强制刷新带 `?force=true` 参数

### 9.2 未决项（请 dong4j 拍板）

| ID | 议题 | 倾向方案 |
|---|---|---|
| Q1 | enricher 调用模式：spider 同步阻塞 vs 异步队列 | **同步阻塞**——简单、可观测；若日后量级上来再切异步 |
| Q2 | 主接口路径：`/api/v1/repos` vs `/api/v1/feed` | **`/api/v1/repos`**——语义最准确，feed 偏新闻流语境 |
| Q3 | 主接口默认 sort | **`first_seen_at desc`**——"最近发现"语义最贴 weekly 现状 |
| Q4 | discovery 未分类 repo 是否参与 list | **不参与**（默认）；带 `?include_pending=true` 时进 |
| Q5 | DTO 字段命名风格 | **snake_case**（与 trending-api / 当前 weekly-api 一致）|
| Q6 | `events` 时间归一精度 | **保留各源原生精度**（weekly 日级、zread 周级 00:00:00Z、discovery 秒级）|

---

## 10. 与其他文档的关系

- **本文档** = `weekly-api` 后端改造方案（独立施工）
- 客户端对接方案（`WeeklyAPI` → `RepoAPI`）= **R-05** 单独编写
- 与 `docs/详细设计/05-GitHub API设计.md` 共用 GitHub Client 接口
- 与 `supports/starcat-trending-api/` 共用语言聚合模式（不共享代码，仿写）
- 进度同步：`docs/工程进度/功能实现总览.md` → 在 §3.9 ZRead 章节追加 R-04 任务

---

## 11. CHANGELOG

```
weekly-api v1.0.0 (2026-06-XX)
==============================
BREAKING CHANGES
- DB schema 完全重写：projects / zread_trending / discovery_repos / discovery_submissions 五表合并为
  github_repos 主表 + weekly_extras / zread_extras / discovery_extras / discovery_submissions 四附表
- 旧 endpoint 全部删除：/api/v1/weekly, /api/v1/zread, /api/v1/discovery, /api/v1/issues
- 新 endpoint：/api/v1/repos, /api/v1/repos/{owner}/{repo}, /api/v1/repos/languages
- 主键统一为 gh_repo_id (int64)，owner+name 降为二级唯一约束
- 项目首次上线版本，无数据迁移、无兼容逻辑

新增
- 三源（阮一峰 / zread / Show HN）数据在 DB 层去重聚合
- 同一 repo 跨源命中时 GitHub API 只调 1 次（30 分钟去抖窗口）
- 时间线接口暴露 repo 在所有源的命中事件
- 语言聚合接口支持按 source 过滤
```

---

## 12. 后续 TODO（出 v1.0 后再考虑）

- [ ] 本地缓存层：handler 加 in-memory cache（5min TTL）+ stampede 锁，减少高频列表查询的 SQL 压力
- [ ] 全文搜索：基于 SQLite FTS5 给 `description / topics / weekly.recommendation / zread.description_zh` 建索引
- [ ] watch / subscribers 增量曲线：单独时序表 `repo_metrics`，每天采样一次（区分这里是用 enricher 实时 vs 历史快照）
- [ ] 历史 owner/name 表：`github_repo_aliases`，rename / transfer 时记录，给老链接 redirect
