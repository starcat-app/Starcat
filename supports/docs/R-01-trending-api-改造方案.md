# Starcat R-01 · starcat-trending-api 改造方案

> 创建：2026-06-09 12:30（原 `R-01-后端改造方案.md` §4）
> 拆分：2026-06-09 12:50（独立成档）
> **v1.2 二次重构**：2026-06-09 13:55（删旧 endpoint 兼容 / 加 Bearer 鉴权 / 加 admin endpoint / Token Pool 必做 / .env）
> 状态：**设计稿（v1.2，待开工）**
> 上游：`R-01-总体设计.md` v1.2
> 适用范围：`supports/starcat-trending-api`
> 阅读顺序：先读 `R-01-总体设计.md` 建立全局共识，再读本文档

⚠️ **本文档定位**：trending-api 这一个 Go 服务的**具体改造方案**。包含：现状缺口 / 目标三层结构 / SQL DDL / enricher 字段映射 / Token Pool 接入 / scheduler cron / admin endpoint / 鉴权中间件接入 / endpoint JSON 示例 / 改造清单（逐文件） / fly.toml 改动 / 部署 SOP。

**跨 API 共识层**（URL 版本化 / envelope / 错误响应 / API Key 鉴权 / Token Pool 设计 / .env / schema_version 演进 / 跨 API 共享代码 / 测试策略 / 风险权衡 / 实施步骤）**不在本文档**，去 `R-01-总体设计.md` 查。

---

## 文档版本

| 版本 | 日期 | 主要内容 |
|---|---|---|
| v1.0 | 2026-06-09 12:30 | 随 `R-01-后端改造方案.md` v1.0 一起冻结，作为该文档 §4 |
| v1.1 | 2026-06-09 12:50 | 拆分到独立文档；内容不变 |
| **v1.2** | **2026-06-09 13:55** | 删除旧 endpoint 兼容（`/lang` `/repo` `/user` 直接删，不再 Deprecation 头）+ 加 Bearer 鉴权 + 加 admin endpoint（`/internal/sync/{repos,languages,users}`）+ Token Pool 必做 + `.env` 配置规范 |

---

## 0. 与总体设计的关系

- **本文档**：trending-api 服务的工程级改造方案，单一信任源
- **依赖**：`R-01-总体设计.md` 的 §3（统一接口契约 + API Key 鉴权 + .env + Token Pool）、§4（跨 API 共享）、§6（风险约束）
- **冲突仲裁**：若本文档与总体设计冲突 → 以**总体设计**为准

---

## 1. 现状缺口（再陈述）

- 完全无状态 HTML 爬虫，无 store / enricher / scheduler
- `RepoItem` 字段严重不足，无 `gh_repo_id` / 无 owner+name 拆分
- 无 GitHub API Rate Limit 处理
- 无任何鉴权（任意客户端可直调）
- 无定时任务，无手动触发 admin endpoint
- `fly.toml` 已准备好持久卷 `/data`（但代码没用），改造时直接利用

> 现状摘要详见总体设计 §2.1。

---

## 2. 目标结构（三层 + 鉴权 + Token Pool）

改造后的目录树（**新增**目录 / 文件用 ✨ 标注）：

```
starcat-trending-api/
├── cmd/server/main.go                          # 装配三层 + handler + scheduler + 鉴权 + Token Pool + godotenv
├── internal/
│   ├── spider/                                 # 保留：HTML 爬虫（同 starcat-weekly-api 的 fetcher 角色）
│   │   ├── base.go
│   │   ├── lang.go
│   │   ├── repo.go
│   │   └── user.go
│   ├── enricher/  ✨                            # 新增：GitHub API 调用 + 字段补全
│   │   ├── github.go        ✨                  # 单个 repo 拉 /repos/{o}/{r}
│   │   ├── queue.go         ✨                  # 优先级队列 + worker pool
│   │   └── ratelimit.go     ✨                  # 拦 X-RateLimit-Remaining 头退避（与 weekly byte-level 一致）
│   ├── tokenpool/  ✨                           # 新增：GitHub Token Pool（与 weekly byte-level 一致）
│   │   └── tokenpool.go     ✨
│   ├── middleware/  ✨                          # 新增：Bearer 鉴权中间件（与 weekly / sharing byte-level 一致）
│   │   └── auth.go          ✨
│   ├── store/  ✨                               # 新增:SQLite 落库
│   │   ├── store.go         ✨                  # 接口定义(预留 mock 测试用)
│   │   ├── sqlite.go        ✨                  # SQLite 实现
│   │   └── migrations.go    ✨                  # CREATE TABLE / ALTER TABLE
│   ├── scheduler/  ✨                           # 新增：cron 定时刷榜单 + 增量 enrich
│   │   └── cron.go          ✨
│   ├── handler/  ✨                             # 新增：HTTP handlers
│   │   ├── handler.go       ✨                  # 公共：JSON helper / envelope wrapper / 错误响应
│   │   ├── repos.go         ✨                  # /api/v1/repos
│   │   ├── languages.go     ✨                  # /api/v1/languages
│   │   ├── users.go         ✨                  # /api/v1/users
│   │   └── admin.go         ✨                  # /internal/sync/*（手动触发）
│   ├── model/  ✨                               # 重命名/扩展：models → model（与 weekly 对齐）
│   │   ├── trending.go      ✨                  # TrendingRepo（DB 层 struct）
│   │   ├── repo_card.go     ✨                  # StarcatRepoCardDTO（响应层）+ 文件头硬边界规则
│   │   └── envelope.go      ✨                  # Envelope + Meta + ErrorResponse（与 weekly / sharing byte-level 一致）
│   └── version/version.go                      # 保留
├── pkg/utils/number.go                         # 保留
├── docs/
│   ├── DEPLOY_FLY.md                           # 保留
│   ├── DEPLOY_RENDER.md                        # 保留
│   └── R-01-改造说明.md  ✨                     # 新增（可选）：本 API 的实施日志
├── .env  ✨                                     # 新增（git 忽略）：实际配置
├── .env.example  ✨                             # 新增（提交 git）：配置模板
├── .gitignore                                  # 改：加 `.env`
├── .dockerignore                               # 改：加 `.env`
├── fly.toml                                    # 改：删 STORE_FILE 写死，secrets 走 fly secrets set
├── Dockerfile                                  # 保留
├── go.mod                                      # 改：加依赖 modernc.org/sqlite + robfig/cron/v3 + joho/godotenv
├── README.md                                   # 改：更新 endpoint 列表 + .env 配置说明
└── CHANGELOG.md                                # 追加 R-01 改造条目
```

> 注：原 `internal/models/models.go`（小写 s）建议在 R-01 改造中**改名为** `internal/model/`（与 weekly 对齐 + 与 supports/AGENTS.md §通用项目结构 一致）。改名是 Go 包路径变更，需要同步改 import，建议用 `gopls` 或 `goimports` 批量 rewrite。

---

## 3. schema 设计

### 3.1 `trending_repos` 表（新）

```sql
CREATE TABLE IF NOT EXISTS trending_repos (
    -- 业务主键 + GitHub 标识符
    full_name              TEXT PRIMARY KEY,         -- "owner/name"，与 GitHub trending HTML 主键一致
    owner                  TEXT NOT NULL,
    name                   TEXT NOT NULL,

    -- 爬虫原始字段（GitHub Trending 页面解析所得）
    desc_text              TEXT,                     -- description 文本（HTML stripped）
    stars                  INTEGER NOT NULL DEFAULT 0,
    forks                  INTEGER NOT NULL DEFAULT 0,
    language               TEXT,                     -- 主语言名
    change                 INTEGER NOT NULL DEFAULT 0,  -- 本期 stars 增量（"+321" 解析所得）
    build_by_json          TEXT,                     -- 贡献者头像数组 JSON（trending.contributors 扩展段用）

    -- enricher 补全字段（调用 GitHub /repos/{o}/{r} 补）
    gh_repo_id             INTEGER,                  -- GitHub 数字 id（CRITICAL：前端 N5 强约束）
    description            TEXT,                     -- 覆盖 desc_text，以 GitHub 官方为准
    homepage               TEXT,
    license_spdx           TEXT,
    topics_json            TEXT,                     -- JSON 数组
    watchers               INTEGER DEFAULT 0,
    subscribers            INTEGER DEFAULT 0,
    owner_avatar           TEXT,
    is_archived            INTEGER NOT NULL DEFAULT 0,  -- 0/1 boolean
    is_fork                INTEGER NOT NULL DEFAULT 0,
    is_private             INTEGER NOT NULL DEFAULT 0,
    default_branch         TEXT,
    open_issues            INTEGER DEFAULT 0,
    pushed_at              TEXT,                     -- RFC3339
    updated_at             TEXT,                     -- RFC3339
    created_at             TEXT,                     -- RFC3339

    -- 元数据
    since                  TEXT NOT NULL,            -- "daily" / "weekly" / "monthly"，本榜单维度
    captured_at            TEXT NOT NULL,            -- RFC3339，爬虫最后一次抓到此 repo 的时间
    enriched_at            TEXT,                     -- RFC3339，最后一次 enricher 成功补全的时间
    is_available           INTEGER NOT NULL DEFAULT 1,   -- 0/1，标记 404 等不可用
    enrich_priority        INTEGER NOT NULL DEFAULT 0    -- enricher 队列优先级（榜单 head 加分，详见 §4.2）
);

CREATE INDEX IF NOT EXISTS idx_trending_since_captured     ON trending_repos(since, captured_at DESC);
CREATE INDEX IF NOT EXISTS idx_trending_gh_repo_id         ON trending_repos(gh_repo_id) WHERE gh_repo_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_trending_unenriched         ON trending_repos(enriched_at) WHERE enriched_at IS NULL AND is_available = 1;
CREATE INDEX IF NOT EXISTS idx_trending_language_since     ON trending_repos(language, since, captured_at DESC);
```

### 3.2 `trending_languages` 表（可选，缓存语言列表）

```sql
CREATE TABLE IF NOT EXISTS trending_languages (
    key                    TEXT PRIMARY KEY,         -- url-encoded slug，如 "go" / "c%23"
    label                  TEXT NOT NULL,            -- 显示名，如 "Go" / "C#"
    captured_at            TEXT NOT NULL             -- RFC3339
);
```

> 实际上 dong4j 在 Q8 选 A，语言列表用「启动期爬一次 + 24h 内存缓存」即可，**不一定**要落 SQLite。这里给出表 schema 作为未来 P2 升级路径（持久化缓存抗冷启动）。R-01 内**先用内存缓存**实现，admin endpoint `/internal/sync/languages` 触发重新爬取并更新内存。

### 3.3 表结构关键决策

| 维度 | 决策 | 理由 |
|---|---|---|
| 主键 | `full_name` (PK) | 与 weekly 的 UNIQUE(repo_owner, repo_name) 等价，简化语义 |
| 数据保鲜 | 不删历史，靠 `captured_at` 取最新 | GitHub Trending 榜单上下午会变化，留历史给将来做趋势统计 |
| `since` 字段 | daily / weekly / monthly 三档同表 | 一个 repo 可能在三档榜单都出现，复合 query 按 `since` 过滤 |
| `is_available` | 404 标记不可用，不删行 | 避免 404 后再次出现榜单时反复爬 |
| `enrich_priority` | 整数，榜单 head 加分 | 榜单前 30 优先 enrich，长尾延后，与前端 §6.2.1 一致 |
| 时间字段格式 | RFC3339 TEXT | 与 weekly 一致；SQLite 用 TEXT 存比 INTEGER timestamp 更易读 |
| topics / build_by 存 JSON TEXT | 不开子表，SQLite JSON 操作够用 | 简化 schema，前端拿到反正也是数组 |
| 语言列表存储 | 内存缓存（24h TTL） | dong4j Q8 选 A；变动频率极低，启动期一次爬就够 |

### 3.4 SQLite 配置

与 weekly 一致：

```
?_journal_mode=WAL&_busy_timeout=5000
SetMaxOpenConns(1)
SetMaxIdleConns(1)
```

理由：SQLite 单写者，scheduler + handler 并发场景下 WAL + connection=1 是最稳的组合（weekly 已验证）。

---

## 4. enricher 设计

### 4.1 字段映射（GitHub API → DB 列）

调 `GET https://api.github.com/repos/{owner}/{name}`，期望 200 响应，将以下字段映射写入 `trending_repos`：

| GitHub API JSON path | DB 列 | 备注 |
|---|---|---|
| `id` | `gh_repo_id` | 数字 id，最重要字段 |
| `description` | `description` | 覆盖 trending 爬虫的 `desc_text` |
| `stargazers_count` | `stars` | 覆盖爬虫值（更新更频繁） |
| `forks_count` | `forks` | |
| `watchers_count` | `watchers` | |
| `subscribers_count` | `subscribers` | |
| `topics` | `topics_json` | `json.Marshal(topics)` 存 TEXT |
| `homepage` | `homepage` | 可能 null |
| `license.spdx_id` | `license_spdx` | 可能 null（license 整体 null） |
| `archived` | `is_archived` | bool → 0/1 |
| `fork` | `is_fork` | |
| `private` | `is_private` | 应该都是 false（trending 默认公开） |
| `default_branch` | `default_branch` | |
| `open_issues_count` | `open_issues` | |
| `pushed_at` | `pushed_at` | RFC3339 |
| `updated_at` | `updated_at` | RFC3339 |
| `created_at` | `created_at` | RFC3339 |
| `owner.avatar_url` | `owner_avatar` | |
| `language` | `language` | 覆盖爬虫值 |

> 取字段时所有 nil 包装走 Go 指针（`*string` / `*int`）+ nullable 处理，避免 panic。

### 4.2 优先级队列（核心 Rate Limit 策略 1）

enrich 时不是简单 FIFO，而是按 `enrich_priority` DESC 取下一个：

```
priority 计算（每次榜单刷新后批量重算）:
  ① 当前榜单 top 30:        priority += 100
  ② 当前榜单 top 31-100:    priority += 50
  ③ 当前榜单 100+:          priority += 10
  ④ 用户访问热度（未来）:    priority += visits_24h
```

实现方式：scheduler 完成榜单同步后调 `RecomputePriorities()`，更新所有未 enrich repo 的 priority。enricher worker 每次取 `SELECT ... WHERE enriched_at IS NULL ORDER BY enrich_priority DESC LIMIT N`。

> P2 优化：用户访问热度做完后再加 `visits_24h` 列，本次只算榜单位置即可。

### 4.3 Token Pool 集成（v1.2 新增，必做）

enricher 不再直接读 `GITHUB_TOKEN` 单 token，而是从 `tokenpool.TokenPool` 获取 token。

**初始化**：

```go
// main.go
tokens := strings.Split(os.Getenv("GITHUB_TOKENS"), ",")
pool := tokenpool.New(tokens)
log.Printf("[token-pool] loaded %d tokens", len(tokens))

enricher := enricher.New(store, pool, rateLimitHandler)
```

**enrichOne 流程**：详见总体设计 §3.7.5「故障切换流程」。每次 enrich 调用：

```
1. token = pool.PickBest()   // Quota-aware，详见总体设计 §3.7.3
2. 如果 nil → sleepUntilEarliestReset() 后重试
3. 调 GET /repos/{o}/{r} with token
4. pool.UpdateFromResponse(token, resp)   // 自动更新 remaining / resetAt / dead
5. 按 status code 处理
```

### 4.4 Rate Limit 主动退避（核心 Rate Limit 策略 2）

每次 HTTP 调用后**主动**读响应头：

```
X-RateLimit-Limit:       5000
X-RateLimit-Remaining:   1234
X-RateLimit-Reset:       1717920000
X-RateLimit-Used:        3766
X-RateLimit-Resource:    core      # 或 search
Retry-After:             60        # 仅 429 时存在
```

退避算法（伪代码）：

```
if status == 429 or (status == 403 and remaining == 0):
    sleep_seconds = max(retry_after_header, reset_at - now, 60)
    log.warn("rate limit, sleeping {sleep_seconds}s")
    sleep(sleep_seconds)
    return retry_this_repo_with_next_token

if remaining < 100 and now < reset_at - 10min:
    # 仅剩 < 100 次配额但 reset 还远，主动减速到 1 req/5s
    enricher.set_pause_until(reset_at)
    return retry_this_repo
```

> `RateLimitHandler` 与 weekly **byte-level 一致**复制粘贴（详见总体设计 §4.1）。Token Pool 状态由 `pool.UpdateFromResponse` 维护，RateLimitHandler 只负责 sleep / retry 决策。

### 4.5 Search API 独立桶（核心 Rate Limit 策略 3）

GitHub Search API 限制 30 req/min（与 `/repos` 5000/h 是**两个不同**桶）。当前 R-01 trending 只调 `/repos`，**不调** Search，但为未来扩展（如根据 topic 反查 repo）预留独立令牌桶接口。

---

## 5. scheduler 设计

### 5.1 cron 表达式

| 任务 | cron | 含义 |
|---|---|---|
| 全量爬 daily 榜单 + enrich head 30 | `7 * * * *` | 每小时第 7 分 |
| 全量爬 weekly 榜单 | `13 */6 * * *` | 每 6 小时第 13 分（00:13 / 06:13 / 12:13 / 18:13 UTC） |
| 全量爬 monthly 榜单 | `19 5 */2 * *` | 每 2 天 05:19 UTC（凌晨低峰） |
| 全量 enrich 长尾 | `0 3 * * *` | 每天 03:00 UTC（凌晨配额充足） |
| 标记过期榜单 (`captured_at < now - 7d` 的 repo 标 `is_available = 0`） | `0 4 * * *` | 每天 04:00 UTC |

> 取第 N 分而非整点，避免与 weekly 服务同时跑造成 Fly.io 资源争抢（weekly 用第 7 分，trending 用第 7 / 13 / 19 分错开）。

### 5.2 启动期行为

```
main.go bootstrap:
    1. godotenv.Load() 加载 .env
    2. 读 PORT / API_KEYS / GITHUB_TOKENS / STORE_FILE
    3. 打开 SQLite（migration 自动跑）
    4. 初始化 tokenpool.New(tokens)
    5. 启动 enricher worker pool（默认 2 worker，受 Rate Limit 约束）
    6. scheduler.Start() →
       6.1 立即跑一次 daily 爬虫（首次启动数据冷启动）
       6.2 立即跑一次语言列表爬虫（填内存缓存）
       6.3 启动 cron
    7. 装配鉴权中间件（读 API_KEYS 白名单）
    8. 启动 HTTP server
```

冷启动时 daily 100 repo，enricher 全部 enrich 完约 100 * 0.7s ≈ 70s（5000/h token + 主动退避后实际约 0.7s/req）。

### 5.3 数据保鲜 / 清理

- `captured_at < now - 30d` 的 repo：**不删**，只用于历史分析
- `is_available = 0` 的 repo：从 `/api/v1/repos` 默认响应剔除
- `enriched_at IS NULL` 的 repo：从 `/api/v1/repos` 默认响应剔除（与前端 N5 一致）

> 客户端可加 `?include_unenriched=true` query 强制返回未 enrich 的，调试用，正常不开放。

### 5.4 内存语言列表缓存

```go
type LanguageCache struct {
    mu        sync.RWMutex
    languages []model.Language
    fetchedAt time.Time
    ttl       time.Duration  // 24h
}

func (c *LanguageCache) Get() []model.Language {
    c.mu.RLock()
    defer c.mu.RUnlock()
    if time.Since(c.fetchedAt) > c.ttl {
        // 后台异步重新爬，但当下仍返回旧值
        go c.refreshAsync()
    }
    return c.languages
}

func (c *LanguageCache) ForceRefresh() error {
    // admin endpoint /internal/sync/languages 调用
}
```

---

## 6. endpoint 设计

### 6.1 业务 endpoint（`/api/v1/*`，需要 Bearer Token）

#### `GET /api/v1/repos?lang=&since=&limit=`

返回当前 `since` 维度的 trending repo 列表。

**鉴权**：必须带 `Authorization: Bearer <api-key>`。

**Query 参数**：
- `lang`（可选）：语言名，区分大小写跟 GitHub 一致，如 `Go` / `Python` / `Rust` / `C#`（注意 URL encode 为 `C%23`）
- `since`（可选）：`daily` / `weekly` / `monthly`，默认 `daily`
- `limit`（可选）：返回数量上限，默认 100，最大 100

**响应（200）**：

```jsonc
{
  "schema_version": 1,
  "data": [
    {
      "gh_repo_id": 12345678,
      "full_name": "owner/repo",
      "owner": "owner",
      "repo": "repo",
      "owner_avatar": "https://avatars.githubusercontent.com/u/...",
      "description": "...",
      "language": "Go",
      "stars": 1234,
      "forks": 56,
      "watchers": 12,
      "subscribers": 8,
      "topics": ["go", "cli"],
      "homepage": "https://...",
      "license_spdx": "MIT",
      "is_archived": false,
      "is_fork": false,
      "is_private": false,
      "default_branch": "main",
      "open_issues": 3,
      "pushed_at": "2026-06-08T12:00:00Z",
      "updated_at": "2026-06-08T12:00:00Z",
      "created_at": "2024-01-01T00:00:00Z",
      "html_url": "https://github.com/owner/repo",
      "trending": {
        "change": 321,
        "contributors": [
          { "avatar": "https://avatars.githubusercontent.com/u/...", "login": "user1" }
        ]
      }
    }
  ],
  "meta": {
    "since": "daily",
    "language": null,
    "total": 100,
    "generated_at": "2026-06-09T12:30:00Z",
    "cache_status": "fresh"
  }
}
```

#### `GET /api/v1/languages`

返回所有可选语言列表（GitHub Trending 支持的全部，从内存缓存读，24h TTL）。

**鉴权**：必须带 `Authorization: Bearer <api-key>`。

**响应（200）**：

```jsonc
{
  "schema_version": 1,
  "data": [
    { "key": "javascript", "label": "JavaScript" },
    { "key": "python",     "label": "Python" },
    { "key": "c%23",       "label": "C#" }
  ],
  "meta": {
    "fetched_at": "2026-06-09T10:00:00Z",
    "cache_status": "fresh"
  }
}
```

#### `GET /api/v1/users?lang=&since=&sponsorable=`

返回 trending 开发者列表。**本次 R-01 不属于 repo card 范围**，仅做契约升级（包 envelope），不补字段。

**鉴权**：必须带 `Authorization: Bearer <api-key>`。

### 6.2 admin endpoint（`/internal/sync/*`，需要 Bearer Token，dong4j Q8 补充要求）

每个有定时任务的 API 必须提供手动触发的 REST endpoint，给运维场景使用（数据脏了、需要立刻爬新数据等）。

#### `POST /internal/sync/repos`

触发全量重爬所有 lang × since 组合的 trending 榜单 + 重新 enrich 队列。

**异步执行**：接口立刻返回 `task_id`，实际后台跑（fire-and-forget，dong4j Q10 默认 A）。

**响应（200）**：

```jsonc
{
  "schema_version": 1,
  "data": {
    "task_id": "task-2026-06-09T14:30:00Z-abc123",
    "started_at": "2026-06-09T14:30:00Z",
    "status": "running"
  }
}
```

#### `POST /internal/sync/languages`

触发重新爬取语言列表 + 刷新内存缓存。

#### `POST /internal/sync/users`

触发重新爬取开发者榜单。

### 6.3 健康检查（不鉴权）

#### `GET /healthz`

**响应（200）**：

```
ok
```

> 给 fly.io health check 用，不需要鉴权，纯文本响应即可（与现状一致）。

### 6.4 错误响应示例

```http
GET /api/v1/repos
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer
Content-Type: application/json; charset=utf-8

{
  "schema_version": 1,
  "error": {
    "code": "UNAUTHORIZED",
    "message": "missing Authorization header",
    "details": null
  }
}
```

```http
GET /api/v1/repos?since=invalid
Authorization: Bearer sk-starcat-XXX
HTTP/1.1 400 Bad Request
Content-Type: application/json; charset=utf-8

{
  "schema_version": 1,
  "error": {
    "code": "BAD_REQUEST",
    "message": "since must be one of: daily, weekly, monthly",
    "details": { "param": "since", "got": "invalid", "allowed": ["daily", "weekly", "monthly"] }
  }
}
```

```http
GET /api/v1/repos
Authorization: Bearer sk-starcat-XXX
HTTP/1.1 502 Bad Gateway
Content-Type: application/json; charset=utf-8

{
  "schema_version": 1,
  "error": {
    "code": "UPSTREAM_UNAVAILABLE",
    "message": "GitHub Trending HTML fetch failed (last success: 2h ago), serving stale data",
    "details": { "stale_age_seconds": 7200, "fallback": "stale_cache" }
  }
}
```

> 注：上述场景下后端会**优先**返回 stale data + meta.cache_status = "stale" 而非直接 502，502 仅在冷启动 + 上游不可用时返回。

> 错误码完整 enum 详见总体设计 §3.3。

---

## 7. .env 配置规范

### 7.1 `.env.example` 模板（提交 git，作为开发者参考）

```bash
# ================================
# starcat-trending-api .env.example
# ================================
# 复制此文件为 .env 并填实际值
# .env 不会提交到 git（已在 .gitignore）
# fly.io 部署时用 `fly secrets set` 而非 .env

# ──────────────── 服务端口 ────────────────
PORT=5002

# ──────────────── 存储 ────────────────
STORE_FILE=./trending.db
# 生产环境（fly.io）应为 /data/trending.db

# ──────────────── API 鉴权白名单（必填）────────────────
# 逗号分隔多个 key；至少 1 个
# 用 supports/scripts/gen-api-key.sh 生成新 key
API_KEYS=sk-starcat-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX,sk-starcat-YYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYY

# ──────────────── GitHub PAT 池（必填）────────────────
# 逗号分隔多个 PAT；至少 1 个
# 建议 2-3 个做冗余（防 PAT 失效），优先用 Quota-aware 策略选最多余额的
# 创建 PAT：https://github.com/settings/tokens?type=beta（推荐 Fine-grained PAT 仅 public repo 读取权限）
GITHUB_TOKENS=ghp_XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
```

### 7.2 `.env`（本地开发实际值，git 忽略）

```bash
PORT=5002
STORE_FILE=./trending.db
API_KEYS=sk-starcat-7Y2K9F3P0XJTV5HW1MNCQR8BLZD4G6AE
GITHUB_TOKENS=ghp_yourActualGitHubPATHere
```

### 7.3 fly.io secrets（生产环境）

```bash
fly secrets set \
  API_KEYS="sk-starcat-prodKey1,sk-starcat-prodKey2" \
  GITHUB_TOKENS="ghp_token1,ghp_token2,ghp_token3" \
  STORE_FILE="/data/trending.db" \
  -a starcat-trending-api
```

> fly.toml 的 `[env]` 段**只保留 PORT**（公开值），敏感的 API_KEYS / GITHUB_TOKENS / STORE_FILE 走 secrets。

---

## 8. 鉴权中间件接入

`internal/middleware/auth.go`（**与 weekly / sharing byte-level 一致**，详见总体设计 §4.1）。

### 8.1 装配位置

```go
// main.go
import "github.com/starcat-app/starcat-trending-api/internal/middleware"

apiKeys := strings.Split(os.Getenv("API_KEYS"), ",")
authMW := middleware.NewBearerAuth(apiKeys)

mux := http.NewServeMux()
mux.HandleFunc("GET /healthz", handler.Healthz)                  // 不鉴权
mux.Handle("GET /api/v1/repos", authMW.Wrap(handler.ReposV1))    // 鉴权
mux.Handle("GET /api/v1/languages", authMW.Wrap(handler.LanguagesV1))
mux.Handle("GET /api/v1/users", authMW.Wrap(handler.UsersV1))
mux.Handle("POST /internal/sync/repos", authMW.Wrap(handler.AdminSyncRepos))
mux.Handle("POST /internal/sync/languages", authMW.Wrap(handler.AdminSyncLanguages))
mux.Handle("POST /internal/sync/users", authMW.Wrap(handler.AdminSyncUsers))
```

### 8.2 中间件行为

详见总体设计 §3.4.4 鉴权中间件实现要点。

---

## 9. 改造清单（按文件级）

### 9.1 新建文件（共 18 个）

| 路径 | 职责 | 估代码量 |
|---|---|---|
| `internal/store/store.go` | Store 接口定义（含 mock 测试用） | ~80 行 |
| `internal/store/sqlite.go` | SQLite 实现 | ~280 行 |
| `internal/store/migrations.go` | DDL 集中管理 | ~80 行 |
| `internal/enricher/github.go` | 单 repo enrich 逻辑（接入 Token Pool） | ~180 行 |
| `internal/enricher/queue.go` | 优先级队列 + worker pool | ~120 行 |
| `internal/enricher/ratelimit.go` | RateLimitHandler 退避 + Search 桶（**与 weekly byte-level 一致**） | ~100 行 |
| `internal/tokenpool/tokenpool.go` | GitHub Token Pool（**与 weekly byte-level 一致**） | ~150 行 |
| `internal/middleware/auth.go` | Bearer 鉴权中间件（**与 weekly / sharing byte-level 一致**） | ~80 行 |
| `internal/scheduler/cron.go` | cron 调度 + 启动期同步 + 语言缓存刷新 | ~200 行 |
| `internal/handler/handler.go` | envelope wrapper + 错误响应 + JSON helper | ~80 行 |
| `internal/handler/repos.go` | `/api/v1/repos` | ~120 行 |
| `internal/handler/languages.go` | `/api/v1/languages` | ~50 行 |
| `internal/handler/users.go` | `/api/v1/users` | ~80 行 |
| `internal/handler/admin.go` | `/internal/sync/{repos,languages,users}`（异步触发 + task_id） | ~120 行 |
| `internal/model/repo_card.go` | `StarcatRepoCardDTO` + 文件头硬边界规则 | ~150 行 |
| `internal/model/envelope.go` | `Envelope[T]` + `Meta` + `ErrorResponse`（**与 weekly / sharing byte-level 一致**） | ~50 行 |
| `internal/model/trending.go` | DB 层 struct `TrendingRepo`（与 DB 列对齐） | ~100 行 |
| `.env.example` | 配置模板 | ~25 行 |

### 9.2 改造文件（共 5 个）

| 路径 | 改造内容 |
|---|---|
| `cmd/server/main.go` | ① `godotenv.Load()` ② 装配 store / enricher / scheduler / tokenpool ③ 路由全部迁到 handler 包 + 装鉴权中间件 ④ **删除**旧 `/lang` `/repo` `/user` 路由 ⑤ 优雅关闭加 scheduler.Stop() |
| `go.mod` | ① 加 `modernc.org/sqlite` ② 加 `github.com/robfig/cron/v3` ③ 加 `github.com/joho/godotenv` ④ `go mod tidy` |
| `.gitignore` | 加 `.env` `.env.local` `.env.*.local` |
| `.dockerignore` | 加 `.env` |
| `README.md` | 更新 endpoint 列表（只列新 v1）+ .env 配置说明 + 鉴权方式说明 |
| `CHANGELOG.md` | 追加 R-01 改造条目（含 break change：旧 endpoint 直接删） |

### 9.3 删除文件（v1.2 新增）

`internal/spider/` 下的 base.go / lang.go / repo.go / user.go **保留**（HTML 爬虫核心逻辑还在用），但 `internal/models/models.go` 删除（迁移到 `internal/model/trending.go`）。

旧路由 `/lang` `/repo` `/user` 在 main.go 直接删除（无独立 handler 文件，是 main.go 里 inline 注册的）。

### 9.4 fly.toml 改动

```toml
# 改造后的 fly.toml [env] 段
[env]
  GOGC = '100'
  GOMAXPROCS = '1'
  PORT = '5002'

# 删除：[env] 不再放任何敏感值
# STORE_FILE、API_KEYS、GITHUB_TOKENS 都走 fly secrets set
```

其他段（[build] / [processes] / [[mounts]] / [http_service] / [[vm]]）**完全不动**。卷 `starcat_trending_data` 已经在 `[[mounts]]` 挂到 `/data`，本次直接利用。

---

## 10. 部署步骤

### Phase 1：本地开发完成 + CI 通过

```bash
cd supports/starcat-trending-api

# 1. 加依赖
go get modernc.org/sqlite@latest
go get github.com/robfig/cron/v3@latest
go get github.com/joho/godotenv@latest
go mod tidy

# 2. 跑 vet + build + 单测（CI 等价）
go vet ./...
go build ./...
go test ./...

# 3. 准备 .env（本地）
cp .env.example .env
# 编辑 .env，填入实际 API_KEYS / GITHUB_TOKENS
# 用 ../scripts/gen-api-key.sh 生成 API Key
bash ../scripts/gen-api-key.sh

# 4. 本地起服务
go run ./cmd/server/

# 5. smoke 测试（带 Bearer Token）
curl http://localhost:5002/healthz
curl -H "Authorization: Bearer $(grep API_KEYS .env | cut -d= -f2 | cut -d, -f1)" \
  'http://localhost:5002/api/v1/repos?since=daily&limit=10' | jq

# 6. 无 key 应返 401
curl -i http://localhost:5002/api/v1/repos
# 期望：HTTP/1.1 401 Unauthorized + WWW-Authenticate: Bearer
```

### Phase 2：Fly.io 部署

```bash
# 1. 设置 secrets（首次）
fly secrets set \
  API_KEYS="sk-starcat-prodKey1,sk-starcat-prodKey2" \
  GITHUB_TOKENS="ghp_token1,ghp_token2" \
  STORE_FILE="/data/trending.db" \
  -a starcat-trending-api

# 2. 部署
fly deploy -a starcat-trending-api

# 3. 看冷启动日志（首次会跑 enricher EnrichAll，预期 ~70s 跑完 daily 100 repo）
fly logs -a starcat-trending-api

# 4. 在线 smoke
API_KEY="sk-starcat-prodKey1"
curl 'https://starcat-trending-api.fly.dev/healthz'
curl -H "Authorization: Bearer $API_KEY" \
  'https://starcat-trending-api.fly.dev/api/v1/repos?since=daily&limit=3' | jq

# 5. 验证无 key 401
curl -i 'https://starcat-trending-api.fly.dev/api/v1/repos'

# 6. 验证 admin endpoint
curl -X POST -H "Authorization: Bearer $API_KEY" \
  'https://starcat-trending-api.fly.dev/internal/sync/repos' | jq
```

### Phase 3：回滚预案

如果新版有问题：

```bash
fly releases -a starcat-trending-api
fly deploy --image registry.fly.io/starcat-trending-api:deployment-<previous-id> -a starcat-trending-api
```

如果 SQLite 数据有损坏：

```bash
fly ssh console -a starcat-trending-api
# 进容器后:
rm /data/trending.db        # 直接删，scheduler 启动期会重新爬重建
exit
fly apps restart starcat-trending-api
```

> ⚠️ SQLite 文件损坏极少见但要预防：每次 deploy 前 `fly ssh console -a starcat-trending-api -C "cp /data/trending.db /data/trending.db.bak.$(date +%Y%m%d)"`。

---

## 11. 测试范围（trending 专属）

> 跨 API 共识层测试详见总体设计 §5。

### 11.1 单元测试目标

- `internal/store/sqlite.go`：
  - `TestUpsertTrendingRepo`：插入 / 更新 / 同 full_name 不同 since 共存
  - `TestGetTrendingRepos`：按 since / lang / limit 过滤
  - `TestGetUnenrichedRepos`：仅返回 `enriched_at IS NULL` 的
  - `TestRecomputePriorities`：榜单 head priority +100、长尾 +10
- `internal/enricher/github.go`：
  - `TestEnrichOne_Success`：mock 200 响应 + 验证所有字段写入
  - `TestEnrichOne_NotFound`：mock 404 + 验证 `is_available=0`
  - `TestEnrichOne_RateLimited`：mock 429 + 验证 RateLimitHandler 退避 + 切下一个 token
- `internal/enricher/ratelimit.go`：
  - `TestRateLimitHandler_Conservative`：mock remaining=5、reset 1h 后 → 验证主动暂停
  - `TestRateLimitHandler_RetryAfter`：mock Retry-After=30 → 验证 sleep 30s
- `internal/tokenpool/tokenpool.go`：
  - `TestTokenPool_PickBest_QuotaAware`：3 token remaining=[10, 50, 30] → PickBest 选 remaining=50
  - `TestTokenPool_Marks_Dead_On_401`：mock 401 后该 token 被标 dead，下次 PickBest 跳过
  - `TestTokenPool_All_Dead_Returns_Nil`：所有 token dead → PickBest 返回 nil
- `internal/middleware/auth.go`：
  - `TestAuthMiddleware_MissingHeader_401`
  - `TestAuthMiddleware_BadFormat_401`
  - `TestAuthMiddleware_NotInWhitelist_401`
  - `TestAuthMiddleware_Valid_PassThrough`
- `internal/scheduler/cron.go`：
  - `TestScheduler_SyncOnce`：mock spider 返回 100 repo → 验证全部 upsert + priority 重算
- `internal/handler/repos.go`：
  - `TestHandleReposV1_OK`：mock store 返回 3 repo → 验证 envelope 形态
  - `TestHandleReposV1_InvalidSince`：since=invalid → 验证 400 + error code BAD_REQUEST
- `internal/handler/admin.go`：
  - `TestAdminSyncRepos_Returns_TaskId`：POST /internal/sync/repos → 返回 task_id + status=running

### 11.2 部署阶段验收清单

部署运行 1 周期间每天检查：

- [ ] `fly logs` 无 panic / fatal
- [ ] `fly logs` 看到启动日志 `[env] .env loaded` `[token-pool] loaded N tokens` `[auth] N keys loaded`
- [ ] `fly logs` enricher 错误率 < 1%
- [ ] `fly status` machine restart 次数 ≤ 1 次/天
- [ ] GitHub Rate Limit `/repos` core 桶 used < 4000/h 平均（通过 Token Pool 监控日志）
- [ ] Token Pool 至少 1 个 alive（看 `[token-pool] tokens=N alive=M` 日志）
- [ ] SQLite 文件大小增长合理（< 10 MB/周）
- [ ] `/api/v1/repos` p95 延迟 < 200ms
- [ ] 鉴权失败 / 总请求 < 5%
- [ ] admin endpoint `/internal/sync/repos` 手动触发后能看到全量爬取日志

---

*最后更新：2026-06-09 13:55（v1.2 二次重构：删旧 endpoint / 加 Bearer 鉴权 / 加 admin endpoint / Token Pool 必做 / .env）*

*上游：`R-01-总体设计.md` v1.2*
