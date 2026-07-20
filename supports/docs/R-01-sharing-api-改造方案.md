# Starcat R-01 · starcat-sharing-api 改造方案

> 创建：2026-06-09 12:30（原 `R-01-后端改造方案.md` §6）
> 拆分：2026-06-09 12:50（独立成档）
> **v1.2 重写**：2026-06-09 13:55（**改造范围大幅扩大**：删 JSON 文件改 SQLite / 加 Bearer 鉴权 / 删旧 endpoint / .env）
> 状态：**设计稿（v1.2，待开工）**
> 上游：`R-01-总体设计.md` v1.2
> 适用范围：`supports/starcat-sharing-api`
> 阅读顺序：先读 `R-01-总体设计.md` 建立全局共识，再读本文档

⚠️ **本文档定位**：sharing-api 这一个 Go 服务的**具体改造方案**。**v1.2 起改造范围扩大**：① 持久化层从「内存 + JSON 文件」换成 SQLite ② 删除旧 endpoint 不做兼容 ③ 加 Bearer Token 鉴权 ④ 升级契约层（v1 + envelope）。`GET /s/{id}` HTML 渲染**不动**。

**跨 API 共识层**（URL 版本化 / envelope / 错误响应 / API Key 鉴权 / .env / schema_version 演进 / 跨 API 共享代码 / 测试策略 / 风险权衡 / 实施步骤）**不在本文档**，去 `R-01-总体设计.md` 查。

---

## 文档版本

| 版本 | 日期 | 主要内容 |
|---|---|---|
| v1.0 | 2026-06-09 12:30 | 随 `R-01-后端改造方案.md` v1.0 一起冻结，作为该文档 §6（仅契约层升级） |
| v1.1 | 2026-06-09 12:50 | 拆分到独立文档；内容不变 |
| **v1.2** | **2026-06-09 13:55** | **大幅扩大改造范围**：① **存储改 SQLite**（替换 JSON 文件 `data.json`）② 删旧 endpoint `/api/share`（不做兼容）③ **加 Bearer 鉴权** ④ `.env` 配置规范 ⑤ 升级契约层（v1 + envelope）。HTML 渲染 `/s/{id}` 仍**不动**。 |

---

## 0. 与总体设计的关系

- **本文档**：sharing-api 服务的工程级改造方案，单一信任源
- **依赖**：`R-01-总体设计.md` 的 §3（统一接口契约 + API Key 鉴权 + .env）、§4（跨 API 共享）、§6（风险约束）
- **冲突仲裁**：若本文档与总体设计冲突 → 以**总体设计**为准
- **特殊性**：sharing 不参与前端 RepoResolver chain，本次升级**主要**是为了「3 个 API 协议层 + 鉴权层 + 存储层完全一致」（dong4j 在 13:10 + 13:55 拍板）

---

## 1. 现状摘要（再陈述）

- 内存 + JSON 文件持久化，无外部依赖（store/memory.go + 异步 SaveAsync 写 `/data/data.json`）
- 业务流：`POST /api/share` 接受 repo + AI summary，生成 8 字符短链，`GET /s/{id}` 渲染 HTML
- 与 R-01 repo card 体系**关系弱**：sharing 不参与 RepoResolver chain，仅是个独立功能
- 无任何鉴权
- 无 .env 文件机制

> 现状摘要详见总体设计 §2.3。

---

## 2. 改造范围（v1.2 大幅扩大）

| 改造项 | v1.0 (单文件) | v1.1 (拆分) | **v1.2 (本次)** | 备注 |
|---|---|---|---|---|
| URL 升级到 `/api/v1/*` | ✅ 灰度共存 | ✅ 灰度共存 | ✅ **直接替换** | 删旧路径 |
| envelope 包响应 | ✅ | ✅ | ✅ | 不变 |
| 错误响应统一形态 | ✅ | ✅ | ✅ | 不变 |
| **存储改 SQLite** | ❌ | ❌ | ✅ **新增** | 淘汰 JSON 文件 |
| **Bearer 鉴权** | ❌ | ❌ | ✅ **新增** | 与 trending / weekly 一致 |
| **.env 配置** | ❌ | ❌ | ✅ **新增** | godotenv |
| **旧 endpoint 直接删** | ❌（灰度保留 6 个月） | ❌（灰度保留 6 个月） | ✅ **新增**（直接删） | dong4j 13:10 「无兼容包袱」 |
| 旧 data.json 数据迁移 | — | — | ❌ **不做**（dong4j 13:55 选 A） | 没上线无数据 |
| `GET /s/{id}` HTML 渲染 | ❌ 不动 | ❌ 不动 | ❌ 不动 | 不属于 JSON 契约 |

---

## 3. schema 设计（v1.2 新增）

### 3.1 `shares` 表（新）

```sql
CREATE TABLE IF NOT EXISTS shares (
    -- 业务主键
    id              TEXT PRIMARY KEY,             -- 8 字符短链 ID（base62，与现状一致）

    -- 业务数据
    repo_json       TEXT NOT NULL,                -- ShareRepoDTO JSON 序列化
    ai_summary_json TEXT NOT NULL,                -- ShareAISummaryDTO JSON 序列化

    -- 元数据
    created_at      TEXT NOT NULL,                -- RFC3339
    expires_at      TEXT,                         -- RFC3339, nullable（永不过期则 null）
    visit_count     INTEGER NOT NULL DEFAULT 0,   -- /s/{id} 被访问的次数（统计用）
    last_visited_at TEXT                          -- RFC3339, nullable
);

CREATE INDEX IF NOT EXISTS idx_shares_created_at ON shares(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_shares_expires_at ON shares(expires_at) WHERE expires_at IS NOT NULL;
```

### 3.2 schema 关键决策

| 维度 | 决策 | 理由 |
|---|---|---|
| 业务字段存 JSON TEXT | 不拆 repo / ai_summary 子表 | sharing 数据是「快照」性质（用户分享时的 repo + AI 摘要），不需要后续按字段 query；存 JSON TEXT 最简单 |
| `expires_at` nullable | null 表示永不过期 | 当前业务无过期需求，预留字段 |
| `visit_count` / `last_visited_at` | 新增统计字段 | JSON 文件时代没有，SQLite 时代加上几乎零成本 |
| 主键 | `id` (8 字符短链) | 与现状一致，无需 AUTOINCREMENT |
| 时间字段格式 | RFC3339 TEXT | 与 trending / weekly 一致 |

### 3.3 SQLite 配置

```
?_journal_mode=WAL&_busy_timeout=5000
SetMaxOpenConns(1)
SetMaxIdleConns(1)
```

与其他两个 API 一致，避免抢锁。

### 3.4 旧 data.json 处理

dong4j 在 13:55 明确选 A：**不做迁移**。

理由：
1. **没上线** —— 现网无真实用户分享数据
2. **本地开发数据可丢** —— 部署时 fly volume 上的 `data.json` 直接保留不动，新代码读 SQLite，老 JSON 自然废弃
3. **极简实施** —— 省了一份一次性迁移脚本

部署时操作：
- 新版只读 SQLite，不读 `data.json`
- 旧 `data.json` 保留在卷上不删（占用 < 1MB，无成本）
- 如未来真需要迁移，写脚本扫 `data.json` → INSERT INTO shares 即可

---

## 4. endpoint 设计

### 4.1 业务 endpoint（`/api/v1/*`，需要 Bearer Token）

#### `POST /api/v1/share`

创建新分享。

**鉴权**：必须带 `Authorization: Bearer <api-key>`。

**请求体**：与现状一致 `ShareRepoRequest { repo, aiSummary }`，**不动**。

**响应（200）**：

```jsonc
{
  "schema_version": 1,
  "data": {
    "shareUrl":  "https://starcat.ink/s/aBc1d2eF",
    "shareId":   "aBc1d2eF",
    "expiresAt": null,
    "createdAt": "2026-06-09T12:30:00Z"
  }
}
```

**响应（400）**：

```jsonc
{
  "schema_version": 1,
  "error": {
    "code": "BAD_REQUEST",
    "message": "request body decode failed: unexpected EOF",
    "details": null
  }
}
```

**响应（401）**：

```jsonc
{
  "schema_version": 1,
  "error": {
    "code": "UNAUTHORIZED",
    "message": "missing Authorization header",
    "details": null
  }
}
```

### 4.2 `GET /s/{id}` HTML 渲染（不鉴权，不版本化）

属于「人类访问」路径（用户从 X / 微信 / 邮件等点链接打开），不在 v1 契约范围。

**改动**：
- 路径**完全保留** `GET /s/{id}`
- 内部存储改为读 SQLite `shares` 表（替代旧 `memory.MemoryStore.Get(id)`）
- 模板渲染逻辑（`templates/share.html`）**不动**
- 访问时 `UPDATE shares SET visit_count = visit_count + 1, last_visited_at = NOW() WHERE id = ?`（额外加的统计）

### 4.3 健康检查（不鉴权）

#### `GET /healthz`

**响应（200）**：

```
ok
```

> 给 fly.io health check 用，纯文本响应（与现状一致）。

### 4.4 删除的旧 endpoint（v1.2 新增）

以下路径在 R-01 中**直接删除**：

- ❌ `POST /api/share` → 用 `POST /api/v1/share`

dong4j 在 13:10 明确「没上线，无兼容包袱」。

---

## 5. .env 配置规范

### 5.1 `.env.example` 模板（提交 git）

```bash
# ================================
# starcat-sharing-api .env.example
# ================================

# ──────────────── 服务端口 ────────────────
PORT=5001

# ──────────────── 存储 ────────────────
STORE_FILE=./sharing.db
# 生产环境：/data/sharing.db

# ──────────────── 短链 base URL ────────────────
# 用于拼接 shareUrl（如 https://starcat.ink）
BASE_URL=http://localhost:5001

# ──────────────── API 鉴权白名单（必填）────────────────
# 逗号分隔多个 key；用 supports/scripts/gen-api-key.sh 生成
API_KEYS=sk-starcat-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX

# sharing 不调 GitHub API，故不需要 GITHUB_TOKENS
```

### 5.2 `.env`（本地开发，git 忽略）

```bash
PORT=5001
STORE_FILE=./sharing.db
BASE_URL=http://localhost:5001
API_KEYS=sk-starcat-7Y2K9F3P0XJTV5HW1MNCQR8BLZD4G6AE
```

### 5.3 fly.io secrets（生产环境）

```bash
fly secrets set \
  API_KEYS="sk-starcat-prodKey1,sk-starcat-prodKey2" \
  BASE_URL="https://starcat.ink" \
  STORE_FILE="/data/sharing.db" \
  -a starcat-sharing-api
```

---

## 6. 鉴权中间件接入

`internal/middleware/auth.go`（**与 trending / weekly byte-level 一致**，详见总体设计 §4.1）。

### 6.1 装配位置

```go
// main.go
import "github.com/starcat-app/starcat-sharing-api/internal/middleware"

apiKeys := strings.Split(os.Getenv("API_KEYS"), ",")
authMW := middleware.NewBearerAuth(apiKeys)

mux := http.NewServeMux()
mux.HandleFunc("GET /healthz", handler.Healthz)                    // 不鉴权
mux.HandleFunc("GET /s/{id}", handler.RenderShare)                 // 不鉴权（HTML 渲染）
mux.Handle("POST /api/v1/share", authMW.Wrap(handler.CreateShareV1))  // 鉴权
```

---

## 7. 改造清单（按文件级）

### 7.1 新建文件（共 7 个）

| 路径 | 职责 | 估代码量 |
|---|---|---|
| `internal/model/envelope.go` | `Envelope[T]` + `ErrorResponse`（**与 trending / weekly byte-level 一致**） | ~50 行 |
| `internal/middleware/auth.go` | Bearer 鉴权中间件（**与 trending / weekly byte-level 一致**） | ~80 行 |
| `internal/store/store.go` | Store 接口（含 mock 测试用） | ~50 行 |
| `internal/store/sqlite.go` | SQLite 实现（替换 memory.go） | ~150 行 |
| `internal/store/migrations.go` | DDL 集中管理 | ~50 行 |
| `internal/handler/handler.go` | envelope wrapper + 错误响应 + JSON helper | ~80 行 |
| `.env.example` | 配置模板 | ~20 行 |

### 7.2 改造文件（共 5 个）

| 路径 | 改造内容 |
|---|---|
| `internal/handler/share.go` | ① 新增 `HandleCreateShareV1`（包 envelope）② **删除**旧 `HandleCreateShare` ③ `HandleRenderShare` 不动但内部 store 改 SQLite ④ 错误响应改 envelope 错误形态 |
| `cmd/server/main.go` | ① `godotenv.Load()` ② 装配 SQLite store / 鉴权中间件 ③ **只**注册新 v1 路由（旧路径删） ④ 优雅关闭加 db.Close() |
| `go.mod` | 加 `modernc.org/sqlite` + `github.com/joho/godotenv` |
| `.gitignore` | 加 `.env` `.env.local` `.env.*.local` |
| `.dockerignore` | 加 `.env` |
| `README.md` | 更新 endpoint 列表（只列新 v1）+ .env 配置说明 |
| `CHANGELOG.md` | 追加 R-01 改造条目（含 break change：JSON 文件 → SQLite + 旧 endpoint 删 + 加鉴权） |

### 7.3 删除文件

| 路径 | 删除原因 |
|---|---|
| `internal/store/memory.go` | 被 `sqlite.go` 替代 |

### 7.4 fly.toml 改动

```toml
[env]
  PORT = '5001'

# 删除：STORE_FILE / BASE_URL / API_KEYS 都迁到 fly secrets
```

卷 `starcat_sharing_data → /data` 不动。`data.json` 文件**保留在卷上不动**（不读不删，自然废弃），新代码用 `/data/sharing.db`。

---

## 8. 部署步骤

```bash
cd supports/starcat-sharing-api

# 1. 本地准备 .env
cp .env.example .env
bash ../scripts/gen-api-key.sh   # 生成 API Key 填入 .env

# 2. 本地测
go vet ./...
go build ./...
go test ./...
go run ./cmd/server/

# 3. smoke
API_KEY=$(grep API_KEYS .env | cut -d= -f2 | cut -d, -f1)

curl http://localhost:5001/healthz

curl -X POST -H "Authorization: Bearer $API_KEY" \
  -H 'Content-Type: application/json' \
  'http://localhost:5001/api/v1/share' \
  -d '{"repo":{"fullName":"a/b","starsCount":0,"forksCount":0,"topics":[],"url":"...","description":null,"language":null,"homepage":null},"aiSummary":{"oneLiner":"...","summary":"...","platforms":[],"suitableFor":[],"strengths":[],"risks":[],"suggestedTags":[]}}' | jq

# 4. 无 key 应 401
curl -i -X POST 'http://localhost:5001/api/v1/share' -d '{}'

# 5. HTML 渲染（不鉴权）
SHARE_ID=$(curl -X POST -H "Authorization: Bearer $API_KEY" \
  -H 'Content-Type: application/json' \
  'http://localhost:5001/api/v1/share' \
  -d '...' | jq -r '.data.shareId')
curl "http://localhost:5001/s/$SHARE_ID"   # 返回 HTML

# 6. 部署
fly secrets set \
  API_KEYS="sk-starcat-prodKey1,sk-starcat-prodKey2" \
  BASE_URL="https://starcat.ink" \
  STORE_FILE="/data/sharing.db" \
  -a starcat-sharing-api

fly deploy -a starcat-sharing-api

# 7. 在线 smoke
API_KEY="sk-starcat-prodKey1"
curl https://starcat-sharing-api.fly.dev/healthz
curl -X POST -H "Authorization: Bearer $API_KEY" \
  -H 'Content-Type: application/json' \
  https://starcat-sharing-api.fly.dev/api/v1/share -d '...'
```

回滚：standard fly.io 回滚（`fly deploy --image registry.fly.io/starcat-sharing-api:deployment-<previous-id>`）。旧 `data.json` 保留在卷上随时可回退到旧版（但旧 endpoint 已删，回退需用旧 image）。

---

## 9. 测试范围（sharing 专属）

> 跨 API 共识层测试详见总体设计 §5。

### 9.1 单元测试目标

- `internal/store/sqlite.go`：
  - `TestUpsertShare`：插入 + 按 id 查询
  - `TestGetShare_NotFound`：返回 nil + sql.ErrNoRows
  - `TestVisitCount_Increment`：每次 GetShare 自动 +1 visit_count
- `internal/middleware/auth.go`：与 trending 一致的 4 个测试
- `internal/handler/share.go`：
  - `TestHandleCreateShareV1_Envelope`：envelope 形态
  - `TestHandleCreateShareV1_BadRequest`：JSON 解码失败 → error code BAD_REQUEST
  - `TestHandleCreateShareV1_Persists_To_SQLite`：mock SQLite + 验证插入
  - `TestHandleRenderShare_ReadsFromSQLite`：mock 1 条记录 + GET /s/{id} 返回 HTML

### 9.2 部署阶段验收清单

部署运行 1 周期间每天检查：

- [ ] `fly logs` 无 panic / fatal
- [ ] `fly logs` 看到启动日志 `[env] .env loaded` `[auth] N keys loaded` `[store] sqlite opened at /data/sharing.db`
- [ ] `/api/v1/share` POST 创建 + GET /s/{id} 渲染均通过
- [ ] SQLite 文件大小增长合理（< 1 MB / 周）
- [ ] 鉴权失败 / 总请求 < 5%
- [ ] HTML 渲染（不鉴权）的访问量 visit_count 正常累加
- [ ] 旧 `/data/data.json` 不被读取（fly logs 看不到 memory.go 相关日志）

---

*最后更新：2026-06-09 13:55（v1.2 重写：JSON → SQLite + Bearer 鉴权 + 删旧 endpoint + .env）*

*上游：`R-01-总体设计.md` v1.2*
