# Fly.io 环境变量配置指南

> 最后更新：2026-06-30
> 适用范围：`supports/` 下自建后端 API 的 Fly.io 生产部署

---

## 1. App 一览

| Fly App | 默认 URL | 端口 | 持久化卷挂载 | SQLite 路径（生产） |
|---------|----------|------|--------------|---------------------|
| `starcat-sharing-api` | https://starcat-sharing-api.fly.dev | 5001 | `/data` | `/data/sharing.db` |
| `starcat-trending-api` | https://starcat-trending-api.fly.dev | 5002 | `/data` | `/data/trending.db` |
| `starcat-weekly-api` | https://starcat-weekly-api.fly.dev | 5003 | `/data` | `/data/weekly.db` |
| `starcat-wiki-api` | https://starcat-wiki-api.fly.dev | 5004 | `/data` | `/data/wiki.db` |
| `starcat-discovery-api` | https://starcat-discovery-api.fly.dev | 5006 | `/data` | `/data/discovery.db` |

Starcat 客户端默认 baseURL 与上表 `*.fly.dev` 对齐，见 `Starcat/Core/Network/AppEndpoints.swift`。

---

## 2. 配置来源：三种渠道

| 渠道 | 用途 | 何时改 |
|------|------|--------|
| **`fly.toml` `[env]`** | 非敏感、随部署走的固定值（`PORT`、`GOGC` 等） | 改仓库 `fly.toml` 后 `fly deploy` |
| **`fly secrets set`** | 密钥、路径、生产 URL 等敏感/环境相关值 | `make fly-secrets-<name>` 或 `fly secrets set` |
| **本地 `.env`** | 开发机 `go run` / `start-all.sh` 用 | **不**自动上传；用 Makefile 同步到 Fly |

> Fly 上**没有** `.env` 文件。容器启动时只读 OS 环境变量；`fly secrets` 会在运行时注入。

---

## 3. Makefile 快捷命令（推荐）

在 `supports/` 目录：

```bash
make help                  # 列出全部命令
make fly-secrets-all       # 从各 API .env 同步 secrets → Fly（值不落盘 echo）
make fly-secrets-trending  # 只同步某一个
make fly-secrets-list      # 查看已配置的 secret 名称
make fly-health-all        # curl 全部 /healthz
make fly-deploy-all        # 部署全部 App
make fly-backup-all        # 备份全部 /data → supports/backups/
make fly-backup-trending   # 只备份 trending
make fly-restore-trending LOCAL_DB=./starcat-trending-api/trending.db
make fly-wipe-data-all     # ⚠️ 清空全部 /data 卷（删库重建）
```

在 Starcat 主仓库根目录：

```bash
make sync-fly-secrets              # 等价于 cd supports && make fly-secrets-all
make setup-production-api-keys     # 从 supports 各 API .env 写入客户端 baked-in（每服务独立 key）
```

底层脚本：`supports/scripts/fly-secrets-sync.sh`；备份/恢复见 `fly-backup-data.sh` / `fly-restore-data.sh`（§8）。

---

## 4. 共用约定

### 4.1 `API_KEYS`（必填，所有 App 都有）

- **格式**：`sk-starcat-<32 位 base32 大写>`，多个 key 逗号分隔
- **生成**：`bash supports/scripts/gen-api-key.sh`
- **鉴权**：`/api/v1/*` 与 `/internal/*` 强制 `Authorization: Bearer <key>`
- **例外**：`/healthz`、sharing 的 `GET /s/{id}` 不鉴权

**与 Starcat 客户端对齐**（见 §7）：发版构建用的各服务 `STARCAT_PRODUCTION_API_KEY_*` **须**与对应 Fly App 的 `API_KEYS` 白名单一致（各服务可各不相同）。

### 4.2 `GITHUB_TOKENS`（trending + weekly + discovery 必填）

- 逗号分隔多个 GitHub PAT，至少 1 个
- weekly 兼容旧名 `GITHUB_TOKEN`（单值），同步脚本会自动写成 `GITHUB_TOKENS`

### 4.3 存储路径（Fly 生产固定值）

| 变量 | sharing | trending | weekly | wiki | discovery |
|------|---------|----------|--------|------|-----------|
| `STORE_FILE` | `/data/sharing.db` | `/data/trending.db` | `/data/weekly.db` | `/data/wiki.db` | `/data/discovery.db` |
| `REPO_DIR` | — | — | `/data/weekly-repo` | — | — |

`fly-secrets-sync.sh` 会**强制覆盖**为上表路径，避免把本地 `./trending.db` 同步上去。

---

## 5. 分 App 环境变量表

图例：**R** = Fly secrets 必填　**O** = 可选　**T** = 已在 `fly.toml` 固定　**—** = 不适用

### 5.1 starcat-sharing-api

| 变量 | 级别 | 默认值 / Fly 生产值 | 说明 |
|------|------|---------------------|------|
| `PORT` | T | `5001` | `fly.toml` `[env]` |
| `GOGC` / `GOMAXPROCS` | T | `100` / `1` | 运行时调优 |
| `STORE_FILE` | R | `/data/sharing.db` | SQLite 路径 |
| `API_KEYS` | R | — | Bearer 白名单 |
| `BASE_URL` | R | `https://starcat-sharing-api.fly.dev` | 生成分享短链 `shareUrl` 的 host；**不要**用本地 `localhost` |

公开路由：`GET /healthz`、`GET /s/{id}`（分享页 HTML）。

---

### 5.2 starcat-trending-api

| 变量 | 级别 | 默认值 | 说明 |
|------|------|--------|------|
| `PORT` | T | `5002` | |
| `STORE_FILE` | R | `/data/trending.db` | |
| `API_KEYS` | R | — | |
| `GITHUB_TOKENS` | R | — | enricher / GitHub API |
| `WIKI_API_URL` | O | — | 设了且配 `WIKI_API_KEY` 才启用 wiki 预热通知 |
| `WIKI_API_KEY` | O | — | 须与 wiki-api 的 `API_KEYS` 中某个 key 一致 |

cron 频率在代码内固定（daily/weekly/monthly 等），无需 Fly env。

---

### 5.3 starcat-weekly-api

| 变量 | 级别 | 默认值 | 说明 |
|------|------|--------|------|
| `PORT` | T | `5003` | |
| `STORE_FILE` | R | `/data/weekly.db` | |
| `REPO_DIR` | R | `/data/weekly-repo` | 阮一峰周刊 git clone 缓存 |
| `API_KEYS` | R | — | 客户端 Bearer |
| `GITHUB_TOKENS` | R | — | 或 legacy `GITHUB_TOKEN` |
| `ADMIN_API_KEYS` | O | — | **≠ API_KEYS**；仅 `POST /internal/sync/discovery`；未配则该路由恒 401 |
| `DISCOVERY_CRON` | O | `17 * * * *` | Show HN 抓取 |
| `DISCOVERY_HN_LIMIT` | O | `30` | |
| `DISCOVERY_BATCH_SIZE` | O | `20` | |
| `DISCOVERY_RETRY_DELAY_MINUTES` | O | `60` | |
| `ZREAD_TRENDING_CRON` | O | `0 6 * * *` | zread 周榜 |
| `WIKI_API_URL` / `WIKI_API_KEY` | O | — | 同 trending |

---

### 5.4 starcat-wiki-api

| 变量 | 级别 | 默认值 | 说明 |
|------|------|--------|------|
| `PORT` | T | `5004` | |
| `STORE_FILE` | R | `/data/wiki.db` | |
| `API_KEYS` | R | — | |
| `PROBE_USER_AGENT` | O | 内置 Chrome UA | 反爬 User-Agent |
| `ENABLE_CODEWIKI_BATCHEXECUTE` | O | `false` | 设为 `true` 启用 CodeWiki RPC 探测 |
| `CACHE_INDEXED_TTL_HOURS` | O | `168` | indexed 缓存 7 天 |
| `CACHE_NOT_INDEXED_TTL_HOURS` | O | `24` | |
| `CACHE_PROBING_TTL_MINUTES` | O | `10` | probing 超时回收 |
| `CACHE_ERROR_TTL_MINUTES` | O | `30` | |
| `PROBE_ZREAD_INTERVAL_MS` | O | `1000` | 同源限速 |
| `PROBE_DEEPWIKI_INTERVAL_MS` | O | `1000` | |
| `PROBE_CODEWIKI_INTERVAL_MS` | O | `1000` | |
| `RETRY_MAX_ATTEMPTS` | O | `3` | |
| `RETRY_INTERVAL_MINUTES` | O | `30` | |

> wiki 可选变量较多，**Fly 首发通常只配 `API_KEYS` + `STORE_FILE`**，其余走代码默认值。需要调优时再 `fly secrets set`。

---

### 5.5 starcat-discovery-api

| 变量 | 级别 | 默认值 / Fly 生产值 | 说明 |
|------|------|---------------------|------|
| `PORT` | T | `5006` | |
| `STORE_FILE` | R | `/data/discovery.db` | Fly 生产固定路径；本地 `.env` 应使用 `./discovery.db` |
| `API_KEYS` | R | — | 客户端读取接口 Bearer 白名单 |
| `ADMIN_API_KEYS` | R | — | `/internal/sync/discovery` 管理接口 key，不能与 `API_KEYS` 复用 |
| `GITHUB_TOKENS` | R | — | GitHub PAT 池，逗号分隔 |
| `SYNC_ENABLED` | O | `true` | 首次空部署且未配置真实 PAT 时可临时设为 `false` |
| `SYNC_CRON` | O | `17 */3 * * *` | 增量同步 |
| `FULL_SYNC_CRON` | O | `23 2 * * *` | 全量同步 |

---

## 6. 手工 fly CLI 示例

```bash
# 生成 key
bash supports/scripts/gen-api-key.sh

# sharing（注意 BASE_URL 必须是公网可访问的分享域名）
fly secrets set -a starcat-sharing-api \
  API_KEYS='sk-starcat-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX' \
  STORE_FILE='/data/sharing.db' \
  BASE_URL='https://starcat-sharing-api.fly.dev'

# trending
fly secrets set -a starcat-trending-api \
  API_KEYS='sk-starcat-...' \
  GITHUB_TOKENS='ghp_...' \
  STORE_FILE='/data/trending.db'

# weekly
fly secrets set -a starcat-weekly-api \
  API_KEYS='sk-starcat-...' \
  GITHUB_TOKENS='ghp_...' \
  STORE_FILE='/data/weekly.db' \
  REPO_DIR='/data/weekly-repo'

# wiki
fly secrets set -a starcat-wiki-api \
  API_KEYS='sk-starcat-...' \
  STORE_FILE='/data/wiki.db'

# discovery
fly secrets set -a starcat-discovery-api \
  API_KEYS='sk-starcat-...' \
  ADMIN_API_KEYS='sk-starcat-admin-...' \
  GITHUB_TOKENS='ghp_...' \
  STORE_FILE='/data/discovery.db'

# 查看（只显示名称与 digest，不显示明文）
fly secrets list -a starcat-trending-api
```

设置 secrets 后 Fly 会自动滚动重启 Machine；也可手动 `fly deploy`。

---

## 7. 与 Starcat 客户端 API Key 对齐

自建后端共用 hybrid 鉴权模型（详见 `Starcat/Core/Network/StarcatAPIKey.swift`），但 **baked-in key 按服务独立**：

| 优先级 | 来源 | 配置位置 |
|--------|------|----------|
| 1（最高） | 用户 BYOK | **设置 → 服务** 各服务 API Key → Keychain |
| 2 | 发版 baked-in（每服务一条） | `Configs/Secrets.xcconfig` → `STARCAT_PRODUCTION_API_KEY_<SERVICE>` → `Info.plist` |

| 服务 | xcconfig / Info.plist 字段 | 读取自 `.env` |
|------|---------------------------|---------------|
| Trending | `STARCAT_PRODUCTION_API_KEY_TRENDING` | `supports/starcat-trending-api/.env` |
| Weekly | `STARCAT_PRODUCTION_API_KEY_WEEKLY` | `supports/starcat-weekly-api/.env` |
| Sharing | `STARCAT_PRODUCTION_API_KEY_SHARING` | `supports/starcat-sharing-api/.env` |
| Wiki | `STARCAT_PRODUCTION_API_KEY_WIKI` | `supports/starcat-wiki-api/.env` |
| Discovery | `STARCAT_PRODUCTION_API_KEY_DISCOVERY` | `supports/starcat-discovery-api/.env` |

**开箱即用发版路径（推荐，全自动）**：

```bash
# 1. 各 API .env 各自填 API_KEYS=（可以不同）
# 2. 推到 Fly
make sync-fly-secrets

# 3. 从 .env 写入客户端 Secrets.xcconfig（各服务 key 独立同步）
make setup-production-api-keys

# 4. 重新 build
xcodegen generate && make run
```

**约束**：每个 `STARCAT_PRODUCTION_API_KEY_*` 必须是对应 Fly App `API_KEYS` 白名单里的某一个（通常取 `.env` 里逗号分隔的第一个）。

默认生产 URL（无需用户配置即可访问）：

| 服务 | `AppEndpoints` |
|------|----------------|
| Weekly | `https://starcat-weekly-api.fly.dev` |
| Trending | `https://starcat-trending-api.fly.dev` |
| Sharing | `https://starcat-sharing-api.fly.dev` |
| Wiki | `https://starcat-wiki-api.fly.dev` |
| Discovery | `https://starcat-discovery-api.fly.dev` |

用户可在 **设置 → 服务** 覆盖 baseURL（自部署场景）；留空则用上表默认。

---

## 8. 备份 `/data` 卷

各 App 的 SQLite（及 weekly 的 `weekly-repo/`）都挂在容器 **`/data`**，对应 Fly Volume（见 §1 表）。

### 8.1 Makefile（推荐）

```bash
cd supports
make fly-backup-trending          # 只备份 trending
make fly-backup-all               # 顺序备份全部 App

# 短暂停机后备份（SQLite 一致性更好，约 20–30s 不可用）
FLY_BACKUP_STOP=1 make fly-backup-trending
```

输出目录（默认，可用 `FLY_BACKUP_ROOT` 覆盖）：

```
supports/backups/<fly-app-name>/<YYYYMMDD-HHMMSS>/
  data.tar.gz      # 远端 /data 整包
  MANIFEST.txt     # app / 时间戳 / 恢复提示
```

`supports/backups/` 已 `.gitignore`，勿把生产库提交进 git。

### 8.2 恢复（Makefile，推荐）

**方式 A：只上传本地单个 SQLite 文件**

```bash
cd supports
make fly-restore-trending LOCAL_DB=./starcat-trending-api/trending.db
```

脚本会写到 Fly 上对应的 `STORE_FILE`（如 `/data/trending.db`），并删除远端旧的 `-wal` / `-shm`；若本地同目录有 `trending.db-wal` / `trending.db-shm` 会一并上传。

**方式 B：从 `fly-backup` 的 tar 整包恢复 `/data`**

```bash
make fly-restore-trending RESTORE_ARCHIVE=supports/backups/starcat-trending-api/<timestamp>/data.tar.gz
```

weekly 应用此方式可同时恢复 `weekly.db` + `weekly-repo/`。

**安全确认**

- 默认会提示输入 `starcat-trending-api` 等 app 全名确认覆盖。
- 自动化脚本：`FLY_RESTORE_YES=1 make fly-restore-trending LOCAL_DB=...`
- **覆盖前请先** `make fly-backup-<app>`。

流程：stop machine → start（SSH）→ 清空 `/data` → 上传 → restart（约 30–60s 不可用）。

### 8.3 手动恢复（不用 Makefile）

```bash
mkdir -p /tmp/restore-data
tar xzf supports/backups/starcat-trending-api/<timestamp>/data.tar.gz -C /tmp/restore-data
# 再 fly ssh sftp put … 或使用 fly-restore-data.sh
```

底层脚本：`supports/scripts/fly-backup-data.sh`、`supports/scripts/fly-restore-data.sh`。

---

## 9. 删库重建 SOP（schema 变更后）

项目未上线，不做 migration；schema 变了直接清卷：

```bash
make -C supports fly-wipe-data-all    # 或单个 fly-wipe-data-trending
make -C supports fly-deploy-all       # 可选：确保镜像最新
make -C supports fly-health-all
```

服务重启后 `createSchema()` 会建空库；trending/weekly 的 scheduler 会重新抓取数据。

---

## 10. 常驻运行（fly.toml）

各 App 的 `fly.toml` 已统一：

```toml
[http_service]
  auto_stop_machines = 'off'
  min_machines_running = 1
```

改完后 `fly deploy` 生效。Machine 规格：`shared-cpu-1x` + **256MB RAM**（仪表盘「1 GB」是 Volume 磁盘，不是内存）。

---

## 11. 相关文件

| 文件 | 用途 |
|------|------|
| `supports/Makefile` | Fly 运维 target |
| `supports/scripts/fly-secrets-sync.sh` | `.env` → `fly secrets set` |
| `supports/scripts/fly-backup-data.sh` | Fly `/data` → 本地 `supports/backups/` |
| `supports/scripts/fly-restore-data.sh` | 本地 `.db` / backup tar → Fly `/data` |
| `supports/scripts/gen-api-key.sh` | 生成 `sk-starcat-...` |
| `supports/starcat-*/fly.toml` | 端口、volume、常驻策略 |
| `supports/starcat-*/.env.example` | 本地开发模板 |
| `Configs/Secrets.xcconfig.template` | 客户端 baked-in Key 模板 |
| `docs/6-发版与上架/v1-上架检查清单.md` §2.2 | 上架前 Key 策略检查项 |
