# Starcat R-01 · starcat-weekly-api 改造方案

> 创建：2026-06-09 12:30（原 `R-01-后端改造方案.md` §5）
> 拆分：2026-06-09 12:50（独立成档）
> **v1.2 二次重构**：2026-06-09 13:55（删旧 endpoint 兼容 / 加 Bearer 鉴权 / Token Pool 必做 / .env）
> 状态：**设计稿（v1.2，待开工）**
> 上游：`R-01-总体设计.md` v1.2
> 适用范围：`supports/starcat-weekly-api`
> 阅读顺序：先读 `R-01-总体设计.md` 建立全局共识，再读本文档

⚠️ **本文档定位**：weekly-api 这一个 Go 服务的**具体改造方案**。重点是 SQLite migration 加 14 字段 + enricher 扩拉 + 接入 Token Pool + 加鉴权 + endpoint 改 `/api/v1/projects`。

**跨 API 共识层**（URL 版本化 / envelope / 错误响应 / API Key 鉴权 / Token Pool 设计 / .env / schema_version 演进 / 跨 API 共享代码 / 测试策略 / 风险权衡 / 实施步骤）**不在本文档**，去 `R-01-总体设计.md` 查。

---

## 文档版本

| 版本 | 日期 | 主要内容 |
|---|---|---|
| v1.0 | 2026-06-09 12:30 | 随 `R-01-后端改造方案.md` v1.0 一起冻结，作为该文档 §5 |
| v1.1 | 2026-06-09 12:50 | 拆分到独立文档；内容不变 |
| **v1.2** | **2026-06-09 13:55** | 删除旧 endpoint 兼容（`/api/weekly/*` 直接删，不再 Deprecation 头）+ 加 Bearer 鉴权 + Token Pool 必做（GITHUB_TOKEN → GITHUB_TOKENS）+ `.env` 配置规范 |

---

## 0. 与总体设计的关系

- **本文档**：weekly-api 服务的工程级改造方案，单一信任源
- **依赖**：`R-01-总体设计.md` 的 §3（统一接口契约 + API Key 鉴权 + .env + Token Pool）、§4（跨 API 共享）、§6（风险约束）
- **冲突仲裁**：若本文档与总体设计冲突 → 以**总体设计**为准

---

## 1. 现状缺口（再陈述）

- 结构完备，3 层架构（fetcher / parser / enricher / scheduler / store / handler / model）已就位
- 缺 14 个 GitHub repo metadata 字段：`gh_repo_id / forks / watchers / subscribers / owner_avatar / homepage / license_spdx / is_archived / is_fork / default_branch / open_issues / pushed_at / updated_at / created_at`
- enricher Rate Limit 是简易令牌桶，未拦 `X-RateLimit-Remaining` 头
- 单 PAT（`GITHUB_TOKEN`），无 Token Pool 冗余
- endpoint 路径 `/api/weekly/projects` 未版本化
- 响应未包 envelope
- 无任何鉴权（任意客户端可直调）

> 现状摘要详见总体设计 §2.2。

---

## 2. schema migration（最关键改动）

### 2.1 当前 `projects` 表

参见总体设计 §2.2 描述。当前 schema：

```sql
CREATE TABLE projects (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    repo_owner          TEXT NOT NULL,
    repo_name           TEXT NOT NULL,
    description         TEXT DEFAULT '',
    stars               INTEGER DEFAULT 0,
    language            TEXT DEFAULT '',
    topics              TEXT DEFAULT '',
    first_issue_number  INTEGER REFERENCES weekly_issues(number),
    enriched_at         TEXT,
    is_available        INTEGER DEFAULT 1,
    UNIQUE(repo_owner, repo_name)
);
```

### 2.2 迁移目标

`projects` 表追加 14 个列：

```sql
ALTER TABLE projects ADD COLUMN gh_repo_id        INTEGER;
ALTER TABLE projects ADD COLUMN forks             INTEGER DEFAULT 0;
ALTER TABLE projects ADD COLUMN watchers          INTEGER DEFAULT 0;
ALTER TABLE projects ADD COLUMN subscribers       INTEGER DEFAULT 0;
ALTER TABLE projects ADD COLUMN owner_avatar      TEXT;
ALTER TABLE projects ADD COLUMN homepage          TEXT;
ALTER TABLE projects ADD COLUMN license_spdx      TEXT;
ALTER TABLE projects ADD COLUMN is_archived       INTEGER NOT NULL DEFAULT 0;
ALTER TABLE projects ADD COLUMN is_fork           INTEGER NOT NULL DEFAULT 0;
ALTER TABLE projects ADD COLUMN default_branch    TEXT;
ALTER TABLE projects ADD COLUMN open_issues       INTEGER DEFAULT 0;
ALTER TABLE projects ADD COLUMN pushed_at         TEXT;
ALTER TABLE projects ADD COLUMN updated_at        TEXT;
ALTER TABLE projects ADD COLUMN created_at        TEXT;

CREATE INDEX IF NOT EXISTS idx_projects_gh_repo_id ON projects(gh_repo_id) WHERE gh_repo_id IS NOT NULL;
```

### 2.3 migration 落地方式

当前 weekly 的 `migrate()` 是「`CREATE TABLE IF NOT EXISTS` + 一次性 schema 字符串」，**不支持**多版本演进。R-01 内需要做：

**最小可行改动**：在 `internal/store/sqlite.go` 加 `migrateV2()` 函数，启动期串行跑：

```
NewSQLiteStore:
    db.Open
    migrateV1()  # 已有，CREATE TABLE IF NOT EXISTS（幂等）
    migrateV2()  # 新增，PRAGMA user_version 控制
    SetMaxOpenConns(1) ...
```

`migrateV2` 用 SQLite 内置的 `PRAGMA user_version`：

```
SELECT user_version FROM PRAGMA user_version;
if user_version < 2:
    BEGIN TRANSACTION
    -- 上面 14 个 ALTER TABLE
    -- 上面 1 个 CREATE INDEX
    PRAGMA user_version = 2
    COMMIT
```

> 注意：`ALTER TABLE ADD COLUMN` 在 SQLite 中是非常便宜的（不重写表），但**不支持** `ALTER TABLE ... DROP COLUMN`（除非用 `CREATE TABLE new + INSERT + DROP old + RENAME` 重写大法）。这是 §2.4 的「已知约束」。

### 2.4 已知约束

- ALTER TABLE 只能 ADD，不能 DROP / RENAME COLUMN（SQLite 3.35+ 才支持 DROP，但 R-01 不依赖）
- ALTER TABLE 不能加 `NOT NULL` 无默认值的列（已规避：所有非空都给 DEFAULT）
- ALTER TABLE 不能加外键（不需要）

### 2.5 数据回填策略

migrate 完成后，**所有已有行的 14 新列都是 NULL / 默认值**。需要 enricher 重新跑一轮：

```
EnrichAll:
    SELECT * FROM projects WHERE gh_repo_id IS NULL OR enriched_at IS NULL
    for each: enrichOne()
```

> 注意：当前 weekly `GetUnenrichedProjects` 是按 `enriched_at IS NULL` 过滤的，已经满足，但要把 `gh_repo_id IS NULL` 也加进去，保证存量数据被强制重 enrich 一遍。

实际回填规模：当前 weekly 库约 2000 个 project，每个 enrich ≈ 0.7s，总耗时 ≈ 25 分钟。可接受，作为一次性运维任务。

---

## 3. enricher 扩字段 + Token Pool

### 3.1 现状

`internal/enricher/github.go` 中 `githubRepoResponse` 只取 `full_name / description / stargazers_count / language / topics`。R-01 需要扩到与 trending 完全一致的 14+5 字段（详见 `R-01-trending-api-改造方案.md` §4.1）。

同时，enricher 当前直接 `os.Getenv("GITHUB_TOKEN")` 单 token，R-01 改用 Token Pool。

### 3.2 字段扩展

```go
// 改造前
type githubRepoResponse struct {
    FullName    string   `json:"full_name"`
    Description *string  `json:"description"`
    Stargazers  int      `json:"stargazers_count"`
    Language    *string  `json:"language"`
    Topics      []string `json:"topics"`
    Message     string   `json:"message"`
}

// 改造后（与 trending 共享）
type githubRepoResponse struct {
    ID            int64    `json:"id"`                 // ✨ 新增
    FullName      string   `json:"full_name"`
    Description   *string  `json:"description"`
    Stargazers    int      `json:"stargazers_count"`
    Forks         int      `json:"forks_count"`        // ✨
    Watchers      int      `json:"watchers_count"`     // ✨
    Subscribers   int      `json:"subscribers_count"`  // ✨
    Language      *string  `json:"language"`
    Topics        []string `json:"topics"`
    Homepage      *string  `json:"homepage"`           // ✨
    License       *struct { SpdxID *string `json:"spdx_id"` } `json:"license"`  // ✨
    Archived      bool     `json:"archived"`           // ✨
    Fork          bool     `json:"fork"`               // ✨
    Private       bool     `json:"private"`            // ✨
    DefaultBranch string   `json:"default_branch"`     // ✨
    OpenIssues    int      `json:"open_issues_count"`  // ✨
    PushedAt      string   `json:"pushed_at"`          // ✨
    UpdatedAt     string   `json:"updated_at"`         // ✨
    CreatedAt     string   `json:"created_at"`         // ✨
    Owner         *struct { AvatarURL *string `json:"avatar_url"` } `json:"owner"`  // ✨
    Message       string   `json:"message"`
}
```

`enrichOne()` 中相应地写所有新列到 DB。

### 3.3 Token Pool 接入（v1.2 新增）

`internal/tokenpool/tokenpool.go`（**与 trending byte-level 一致**，详见总体设计 §4.1）。

**初始化** in main.go：

```go
import "github.com/starcat-app/starcat-weekly-api/internal/tokenpool"

tokens := strings.Split(os.Getenv("GITHUB_TOKENS"), ",")
// 兼容：如果只配了旧的 GITHUB_TOKEN（单 token），自动迁移
if len(tokens) == 1 && tokens[0] == "" {
    if old := os.Getenv("GITHUB_TOKEN"); old != "" {
        tokens = []string{old}
        log.Println("[token-pool] migrating legacy GITHUB_TOKEN to GITHUB_TOKENS (single token)")
    } else {
        log.Fatal("GITHUB_TOKENS env required")
    }
}
pool := tokenpool.New(tokens)
log.Printf("[token-pool] loaded %d tokens", len(tokens))
```

**enrichOne 流程**：详见总体设计 §3.7.5「故障切换流程」。

### 3.4 Rate Limit 升级

当前 weekly 的 `rateLimiter` 是「请求间隔 ≥ 1 hour / 5000 = 720ms」的简单令牌桶，**不读** GitHub 响应头。R-01 升级到与 trending §4.4 一致的 `RateLimitHandler`：

```go
// 改造后（伪代码）
type RateLimitHandler struct {
    minInterval time.Duration  // 720ms 兜底
    lastReq     time.Time
}

func (rl *RateLimitHandler) Before(req *http.Request) {
    if elapsed := time.Since(rl.lastReq); elapsed < rl.minInterval {
        time.Sleep(rl.minInterval - elapsed)
    }
    rl.lastReq = time.Now()
}

// Token 状态由 TokenPool 维护，RateLimitHandler 只做请求间隔约束
// 429/403 处理在 enrichOne 主循环里：
//   if resp.StatusCode == 429 || (resp.StatusCode == 403 && remaining == 0):
//     pool.UpdateFromResponse() 已自动更新 resetAt
//     sleep(retry_after 或 reset_at - now)
//     return retry_this_repo
```

抽到 `internal/enricher/ratelimit.go`，**与 trending byte-level 一致复制粘贴**（详见总体设计 §4.1 跨项目共享代码登记表）。

---

## 4. endpoint 设计

### 4.1 业务 endpoint（`/api/v1/*`，需要 Bearer Token）

#### `GET /api/v1/weekly?page=&page_size=&issue=&issue_from=&issue_to=&lang=&sort=&include_unenriched=`

**鉴权**：必须带 `Authorization: Bearer <api-key>`。

**Query 参数**：与现状一致，路径变 `/api/v1/weekly`。

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
      "owner_avatar": "...",
      "description": "...",
      "language": "Rust",
      "stars": 5678,
      "forks": 234,
      "watchers": 56,
      "subscribers": 12,
      "topics": ["rust", "cli"],
      "homepage": "https://...",
      "license_spdx": "Apache-2.0",
      "is_archived": false,
      "is_fork": false,
      "is_private": false,
      "default_branch": "main",
      "open_issues": 5,
      "pushed_at": "2026-06-08T...",
      "updated_at": "2026-06-08T...",
      "created_at": "2024-01-01T...",
      "html_url": "https://github.com/owner/repo",
      "weekly": {
        "first_issue": 399,
        "issue_url": "https://github.com/ruanyf/weekly/blob/master/docs/issue-399.md"
      }
    }
  ],
  "meta": {
    "page": 1,
    "page_size": 50,
    "total": 2134,
    "next_page": 2,
    "generated_at": "2026-06-09T12:30:00Z"
  }
}
```

#### `GET /api/v1/weekly/{owner}/{repo}`（必做，前端 chain 用）

**鉴权**：必须带 `Authorization: Bearer <api-key>`。

**Query 参数**：无。

**响应（200）**：

```jsonc
{
  "schema_version": 1,
  "data": <StarcatRepoCardDTO>
}
```

**响应（404）**：

```jsonc
{
  "schema_version": 1,
  "error": {
    "code": "NOT_FOUND",
    "message": "Repo not found in weekly archive",
    "details": { "owner": "owner", "repo": "repo" }
  }
}
```

> R-01 内**必做**：前端 `BackendAggregateRepoSource` 依赖此 endpoint。实现成本仅 ~30 行 handler。

#### `GET /api/v1/issues`

返回所有期号列表。

```jsonc
{
  "schema_version": 1,
  "data": [
    { "number": 399, "published_at": "2026-06-06T...", "source_url": "...", "parsed_at": "..." },
    { "number": 398, ... }
  ],
  "meta": { "total": 399 }
}
```

#### `GET /api/v1/issues/{n}`

返回某期详情 + 该期所有 repo。

```jsonc
{
  "schema_version": 1,
  "data": {
    "issue":    { "number": 399, "published_at": "...", "source_url": "...", "parsed_at": "..." },
    "projects": [ <StarcatRepoCardDTO>, ... ]
  }
}
```

### 4.2 admin endpoint（`/internal/sync/*`，需要 Bearer Token）

#### `POST /internal/sync/weekly`

触发全量重同步周刊源 + 重新 enrich 队列。

**鉴权**：必须带 `Authorization: Bearer <api-key>`。

**异步执行**：接口立刻返回 `task_id`，实际后台跑（fire-and-forget）。

**响应（200）**：

```jsonc
{
  "schema_version": 1,
  "data": {
    "task_id": "task-2026-06-09T14:30:00Z-weekly-abc",
    "started_at": "2026-06-09T14:30:00Z",
    "status": "running"
  }
}
```

### 4.3 健康检查（不鉴权）

#### `GET /healthz`

**响应（200）**：

```
ok
```

> 给 fly.io health check 用，不需要鉴权。

### 4.4 删除的旧 endpoint（v1.2 新增）

以下路径在 R-01 中**直接删除**，不保留任何兼容：

- ❌ `GET /api/weekly/projects` → 用 `GET /api/v1/weekly`（v0.5.2 起，2026-06-10）
- ❌ `GET /api/weekly/issues` → 用 `GET /api/v1/issues`
- ❌ `GET /api/weekly/issues/{n}` → 用 `GET /api/v1/issues/{n}`

dong4j 在 13:10 明确「没上线，无兼容包袱」。客户端联调期间一次切换到新路径。

---

## 5. .env 配置规范

### 5.1 `.env.example` 模板（提交 git）

```bash
# ================================
# starcat-weekly-api .env.example
# ================================

# ──────────────── 服务端口 ────────────────
PORT=5003

# ──────────────── 存储 ────────────────
STORE_FILE=./weekly.db
# 生产环境：/data/weekly.db

REPO_DIR=./.weekly-repo
# 生产环境：/data/weekly-repo

# ──────────────── API 鉴权白名单（必填）────────────────
# 逗号分隔多个 key；用 supports/scripts/gen-api-key.sh 生成
API_KEYS=sk-starcat-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX

# ──────────────── GitHub PAT 池（必填）────────────────
# 逗号分隔多个 PAT；建议 2-3 个做冗余
# 注意：R-01 起从 GITHUB_TOKEN（单值）改为 GITHUB_TOKENS（多值）
GITHUB_TOKENS=ghp_XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
```

### 5.2 `.env`（本地开发实际值，git 忽略）

```bash
PORT=5003
STORE_FILE=./weekly.db
REPO_DIR=./.weekly-repo
API_KEYS=sk-starcat-7Y2K9F3P0XJTV5HW1MNCQR8BLZD4G6AE
GITHUB_TOKENS=ghp_yourActualGitHubPATHere
```

### 5.3 fly.io secrets（生产环境）

```bash
fly secrets set \
  API_KEYS="sk-starcat-prodKey1,sk-starcat-prodKey2" \
  GITHUB_TOKENS="ghp_token1,ghp_token2,ghp_token3" \
  STORE_FILE="/data/weekly.db" \
  REPO_DIR="/data/weekly-repo" \
  -a starcat-weekly-api

# 删除旧的单 token secret
fly secrets unset GITHUB_TOKEN -a starcat-weekly-api
```

---

## 6. 鉴权中间件接入

`internal/middleware/auth.go`（**与 trending / sharing byte-level 一致**，详见总体设计 §4.1）。

### 6.1 装配位置

```go
// main.go
import "github.com/starcat-app/starcat-weekly-api/internal/middleware"

apiKeys := strings.Split(os.Getenv("API_KEYS"), ",")
authMW := middleware.NewBearerAuth(apiKeys)

mux := http.NewServeMux()
mux.HandleFunc("GET /healthz", handler.Healthz)                          // 不鉴权
mux.Handle("GET /api/v1/weekly", authMW.Wrap(handler.ProjectsV1))      // 鉴权
mux.Handle("GET /api/v1/weekly/{owner}/{repo}", authMW.Wrap(handler.ProjectByOwnerRepoV1))
mux.Handle("GET /api/v1/issues", authMW.Wrap(handler.IssuesV1))
mux.Handle("GET /api/v1/issues/{n}", authMW.Wrap(handler.IssueV1))
mux.Handle("POST /internal/sync/weekly", authMW.Wrap(handler.AdminSync))
```

---

## 7. 改造清单（按文件级）

### 7.1 新建文件（共 6 个）

| 路径 | 职责 | 估代码量 |
|---|---|---|
| `internal/model/repo_card.go` | `StarcatRepoCardDTO` + 文件头硬边界规则 + Weekly 扩展段 | ~150 行 |
| `internal/model/envelope.go` | `Envelope[T]` + `Meta` + `ErrorResponse`（**与 trending / sharing byte-level 一致**） | ~50 行 |
| `internal/middleware/auth.go` | Bearer 鉴权中间件（**与 trending / sharing byte-level 一致**） | ~80 行 |
| `internal/tokenpool/tokenpool.go` | GitHub Token Pool（**与 trending byte-level 一致**） | ~150 行 |
| `internal/enricher/ratelimit.go` | RateLimitHandler 替代当前的简易 rateLimiter（**与 trending byte-level 一致**） | ~100 行 |
| `.env.example` | 配置模板 | ~25 行 |

### 7.2 改造文件（共 9 个）

| 路径 | 改造内容 |
|---|---|
| `internal/store/sqlite.go` | ① 加 `migrateV2()` 跑 14 ALTER + 1 INDEX ② `PRAGMA user_version` 控制版本 ③ `GetProjects` / `GetUnenrichedProjects` / `UpdateProjectMeta` 都扩字段读写 ④ 新增 `GetProjectByOwnerRepo(owner, repo)` |
| `internal/model/project.go` | `Project` struct 扩 14 字段 + `RepoCard()` 方法将 DB 行转 `StarcatRepoCardDTO` |
| `internal/enricher/github.go` | ① `githubRepoResponse` 扩字段 ② `enrichOne` 写入新字段 ③ **改用 tokenpool 拿 token** 替换 `os.Getenv("GITHUB_TOKEN")` ④ 用 `ratelimit.go` 的新 `RateLimitHandler` 替换旧 `rateLimiter` ⑤ `GetUnenrichedProjects` 查询加 `gh_repo_id IS NULL` 条件 |
| `internal/handler/weekly.go` | ① **删除**旧 handlers（`HandleProjects` `HandleIssues` `HandleIssue`，对应 `/api/weekly/*`）② 新加 `HandleProjectsV1` / `HandleIssuesV1` / `HandleIssueV1` / `HandleProjectByOwnerRepoV1` / `HandleAdminSync` ③ `writeJSON` 抽到 `internal/handler/handler.go`（包 envelope） |
| `cmd/server/main.go` | ① `godotenv.Load()` ② 装配 tokenpool / 鉴权中间件 ③ **只**注册 v1 路由（旧路径删） ④ 优雅关闭加 scheduler.Stop() ⑤ 兼容读 `GITHUB_TOKEN` → `GITHUB_TOKENS` |
| `go.mod` | 加 `github.com/joho/godotenv`（其他依赖已全） |
| `.gitignore` | 加 `.env` `.env.local` `.env.*.local` |
| `.dockerignore` | 加 `.env` |
| `README.md` | 更新 endpoint 列表（只列新 v1）+ .env 配置说明 |
| `CHANGELOG.md` | 追加 R-01 改造条目（含 break change：旧 endpoint 直接删 + GITHUB_TOKEN → GITHUB_TOKENS） |

### 7.3 fly.toml 改动

```toml
[env]
  PORT = '5003'

# 删除：STORE_FILE / REPO_DIR / GITHUB_TOKEN 都迁到 fly secrets
```

`STORE_FILE=/data/weekly.db` 与 `REPO_DIR=/data/weekly-repo` 改 secrets 是为了和 trending / sharing 配置策略统一（敏感配置不进 fly.toml）。

---

## 8. 部署步骤

### Phase 1：本地完成 + 测试

```bash
cd supports/starcat-weekly-api

# 1. 准备 .env
cp .env.example .env
bash ../scripts/gen-api-key.sh   # 生成新 API Key 填入 .env
# 编辑 .env 填 GITHUB_TOKENS

# 2. 跑 vet + build + 单测
go vet ./...
go build ./...
go test ./...

# 3. 用旧数据库测 migrate（如果有备份）
cp /backup/weekly.db /tmp/weekly-migrate-test.db
STORE_FILE=/tmp/weekly-migrate-test.db go run ./cmd/server/
# 看日志: [migrate] PRAGMA user_version 1 → 2, ALTER TABLE projects ADD COLUMN ...

# 4. smoke（带 Bearer Token）
API_KEY=$(grep API_KEYS .env | cut -d= -f2 | cut -d, -f1)
curl 'http://localhost:5003/healthz'
curl -H "Authorization: Bearer $API_KEY" \
  'http://localhost:5003/api/v1/weekly?page=1&page_size=3' | jq
curl -H "Authorization: Bearer $API_KEY" \
  'http://localhost:5003/api/v1/weekly/ruanyf/weekly' | jq

# 5. 无 key 应 401
curl -i 'http://localhost:5003/api/v1/weekly'
```

### Phase 2：Fly.io 部署

```bash
# 1. 进容器手动备份 SQLite（重要！migration 后无法回滚）
fly ssh console -a starcat-weekly-api -C "cp /data/weekly.db /data/weekly.db.pre-r01-$(date +%Y%m%d)"

# 2. 设置新 secrets
fly secrets set \
  API_KEYS="sk-starcat-prodKey1,sk-starcat-prodKey2" \
  GITHUB_TOKENS="ghp_token1,ghp_token2" \
  STORE_FILE="/data/weekly.db" \
  REPO_DIR="/data/weekly-repo" \
  -a starcat-weekly-api

# 3. 删除旧单 token secret
fly secrets unset GITHUB_TOKEN -a starcat-weekly-api

# 4. 部署
fly deploy -a starcat-weekly-api

# 5. 看日志确认 migrate 成功
fly logs -a starcat-weekly-api | grep migrate

# 6. smoke
API_KEY="sk-starcat-prodKey1"
curl -H "Authorization: Bearer $API_KEY" \
  'https://starcat-weekly-api.fly.dev/api/v1/weekly?page=1&page_size=3' | jq
curl -H "Authorization: Bearer $API_KEY" \
  'https://starcat-weekly-api.fly.dev/api/v1/weekly/owner/repo' | jq

# 7. enricher 全量回填（2000 repo × 0.7s ≈ 25 分钟）
fly logs -a starcat-weekly-api | grep enricher
# 期望看到 "EnrichAll 完成" + Token Pool 日志
```

### Phase 3：回滚（如果 migrate 出问题）

```bash
fly ssh console -a starcat-weekly-api -C "mv /data/weekly.db.pre-r01-YYYYMMDD /data/weekly.db"
fly deploy --image registry.fly.io/starcat-weekly-api:deployment-<previous-id> -a starcat-weekly-api
```

---

## 9. 测试范围（weekly 专属）

> 跨 API 共识层测试详见总体设计 §5。

### 9.1 单元测试目标

在现有 `parser/markdown_test.go` 基础上加：

- `internal/store/sqlite.go`：
  - `TestMigrateV2`：跑全 14 ALTER + index，验证 PRAGMA user_version = 2
  - `TestGetProjects_V2Fields`：插入带 14 新字段的 project，验证 SELECT 都拿到
  - `TestGetProjectByOwnerRepo_Found` / `TestGetProjectByOwnerRepo_NotFound`
- `internal/enricher/github.go`：
  - `TestEnrichOne_V2Fields`：mock 200 含全字段 → 验证 14 列写入
  - `TestEnrichOne_TokenPool_Switch`：mock 第一个 token 401 → 自动切第二个 token + 401 token 标 dead
- `internal/tokenpool/tokenpool.go`：与 trending 一致的 5 个测试（详见 trending §11.1）
- `internal/middleware/auth.go`：与 trending 一致的 4 个测试
- `internal/handler/weekly.go`：
  - `TestHandleProjectsV1_Envelope`：envelope 形态
  - `TestHandleProjectByOwnerRepoV1_NotFound`：404 + error code

### 9.2 部署阶段验收清单

部署运行 1 周期间每天检查：

- [ ] migrate 完成无异常（PRAGMA user_version = 2）
- [ ] enricher 回填 2000 项目完成（看到 "EnrichAll 完成"）
- [ ] `/api/v1/weekly` 返回字段齐全（jq 检查 gh_repo_id / forks 等）
- [ ] `fly logs` 无 panic / fatal
- [ ] `fly logs` 看到启动日志 `[env] .env loaded` `[token-pool] loaded N tokens` `[auth] N keys loaded`
- [ ] Token Pool 至少 1 个 alive
- [ ] GitHub Rate Limit 配额使用 < 4000/h 平均
- [ ] 鉴权失败 / 总请求 < 5%

---

*最后更新：2026-06-09 13:55（v1.2 二次重构：删旧 endpoint / 加 Bearer 鉴权 / Token Pool 必做 / .env）*

*上游：`R-01-总体设计.md` v1.2*
