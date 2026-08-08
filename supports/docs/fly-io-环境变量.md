# Fly.io 环境变量配置指南

> 最后更新：2026-08-08  
> 适用范围：`supports/` 下自建后端 API 的 Fly.io 生产部署

---

## 1. App 一览

### 1.1 目标生产架构：聚合 `starcat-api`

| Fly App | 默认 URL | 分流 | 持久化 | SQLite（同卷分文件） |
|---------|----------|------|--------|----------------------|
| `starcat-api` | https://starcat-api.fly.dev | `X-SC-Svc: trending\|weekly\|…` | `/data` | `/data/{wiki,sharing,trending,weekly,discovery}.db` + `/data/weekly-repo` |

Starcat 客户端六个业务默认 baseURL 均为 `https://starcat-api.fly.dev`，见 `StarcatGatewayRouting` / `AppEndpoints`。  
license-api **不**并入聚合。

> **当前生产状态（2026-08-08）**：`starcat-api` App、nrt Volume、Secrets 与首轮五库种子迁移已完成；五库远端 SHA-256 与合并归档一致，`weekly-repo` 文件数一致，迁后 Snapshot 已创建。聚合曾解除维护并通过六服务鉴权 ping 和只读业务抽样；验证后已重新设置维护模式，Machine `185de96f791908` 已停止且 `autostart=false`。App、Volume、Secrets 与 Snapshot 保留，六个旧 App 继续承载生产；1.4.0 切流前必须最终同步 / 冻结写入。

首次创建、首轮种子迁移与功能验证已完成，禁止重复创建 App / Volume 或把本轮归档当作最终切流快照。下一阶段在 1.4.0 发布窗口恢复聚合 Machine 后，必须保持维护模式执行最终同步并复验；未经再次授权不得执行最终同步、切换 `starcat.ink` 或停用旧 App。

恢复已停机聚合 Machine：

```bash
fly machine update 185de96f791908 -a starcat-api --autostart=true --skip-start -y
fly machine start 185de96f791908 -a starcat-api
make -C supports fly-health-api  # 必须返回 {"status":"maintenance"}
```

当前 `autostart=false` 是 Machine 运行态覆盖，仓库 `starcat-api/fly.toml` 仍保留正式生产所需的 `auto_start_machines = true` 和 `min_machines_running = 1`；1.4.0 前不得误执行 deploy 将停机实例重新拉起。现有 Snapshot `vs_P2NQQAXpbv9jUyVVmvy5qe5v` 的平台保留期仅 5 天，不能替代最终迁移批次的新备份和新 Snapshot。

1.4.0 上线后，只有确认 Direct / App Store 两个渠道均可下载，才停止六个旧 App Machine；先保留旧 App / Volume 作回滚资产。旧版本仅能继续展示本地缓存，在线刷新、推荐、发现、Wiki 和分享等能力会随旧服务停机而失效，发布说明必须明确提示用户尽快更新。

迁库步骤见主仓：`docs/4-工程进度/重构专项/API聚合与Kit抽离专项/04-聚合迁库SOP.md`。

### 1.2 当前生产：独立 `starcat-*-api`（兼容自托管 / 待迁移）

| Fly App | 默认 URL | 端口 | 持久化卷 | SQLite 路径 |
|---------|----------|------|----------|-------------|
| `starcat-sharing-api` | https://starcat-sharing-api.fly.dev | 5001 | `/data` | `/data/sharing.db` |
| `starcat-trending-api` | https://starcat-trending-api.fly.dev | 5002 | `/data` | `/data/trending.db` |
| `starcat-weekly-api` | https://starcat-weekly-api.fly.dev | 5003 | `/data` | `/data/weekly.db` |
| `starcat-wiki-api` | https://starcat-wiki-api.fly.dev | 5004 | `/data` | `/data/wiki.db` |
| `starcat-recommend-api` | https://starcat-recommend-api.fly.dev | 5005 | — | — |
| `starcat-discovery-api` | https://starcat-discovery-api.fly.dev | 5006 | `/data` | `/data/discovery.db` |

用户可在 **设置 → 服务** 覆盖 baseURL 指向自托管独立进程；留空则走 §1.1 聚合默认。

---

## 2. 配置来源：三种渠道

| 渠道 | 用途 | 何时改 |
|------|------|--------|
| **`fly.toml` `[env]`** | 非敏感、随部署走的固定值（`PORT`、`GOGC`、分库路径等） | 改仓库 `fly.toml` 后 `fly deploy` |
| **`fly secrets set`** | 密钥、路径、生产 URL 等敏感/环境相关值 | 目标聚合用 `make fly-secrets-api`；当前独立 App 用 `make fly-secrets-<name>` |
| **本地 `.env`** | 开发机 `go run` / 聚合本地调试 | **不**自动上传；用 Makefile 同步到 Fly |

> Fly 上**没有** `.env` 文件。容器启动时只读 OS 环境变量；`fly secrets` 会在运行时注入。

---

## 3. Makefile 快捷命令（推荐）

在 `supports/` 目录：

```bash
make help                  # 列出全部命令
make fly-secrets-api       # 同步聚合 starcat-api（2026-08-08 首次同步已完成）
make fly-health-api        # curl 聚合 /healthz
make fly-secrets-all       # 当前业务生产：六个独立 App secrets
make fly-secrets-trending  # 【当前生产】只同步某一个独立 App
make fly-secrets-list      # 查看独立 App secret 名称
make fly-health-all        # curl 独立 App /healthz
make fly-deploy-api        # 部署聚合（生产变更，需确认）
make fly-backup-all        # 备份有状态独立 App 的 /data（迁库前用）
make fly-prepare-api-restore ...  # 离线合并五份备份并检查 SQLite
make fly-maintenance-api-on       # 聚合迁库维护模式（生产变更）
make fly-restore-api RESTORE_ARCHIVE=backups/starcat-api/<ts>/data.tar.gz
make fly-maintenance-api-off      # 恢复六服务（生产变更）
make fly-restore-trending LOCAL_DB=./starcat-trending-api/trending.db
```

在 Starcat 主仓库根目录：

```bash
make sync-fly-secrets              # 当前等价于 fly-secrets-all；聚合请 make -C supports fly-secrets-api
make setup-production-api-keys     # 从 starcat-api/.env 共用 Key 写入 Secrets.xcconfig（六槽同值，原地改）
```

底层脚本：`supports/scripts/fly-secrets-sync.sh`；备份/恢复见 `fly-backup-data.sh` / `fly-restore-data.sh`（§8）。

---

## 4. 共用约定

### 4.1 `API_KEYS` / 聚合前缀 Key

- **格式**：`sk-starcat-<32 位 base32 大写>`，多个 key 逗号分隔
- **生成**：`bash supports/scripts/gen-api-key.sh`
- **聚合本地运行**：`.env` 需提供六个 `*_API_KEYS`，并与 `STARCAT_SHARED_API_KEY` **同值**；仅在对应服务 `FromEnv` 装配窗口临时映射为裸 `API_KEYS`，随后恢复
- **Fly 同步**：`fly-secrets-sync.sh starcat-api` 只把 `STARCAT_SHARED_API_KEY` 作为六服务共用 Key 输入，并自动生成六个 Fly `*_API_KEYS` secret；本地 `.env` 中的六个 `*_API_KEYS` 不作为同步输入
- **鉴权**：各业务 `/api/v1/*` 仍各自 BearerAuth（网关不做统一鉴权）
- **例外**：`/healthz` 不鉴权；sharing 的 `GET /s/{id}`、`GET /r/starcat-logo.png`、`GET /r/fonts/{file}`、`GET /r/{owner}/{repo}`、`GET /og/repo/{owner}/{repo}` 也不鉴权

**与 Starcat 客户端对齐**（见 §7）：六个 `STARCAT_PRODUCTION_API_KEY_*` 槽位保留，聚合发版时填**相同**值。

### 4.2 `GITHUB_TOKENS`（trending + weekly + discovery 必填）

- 逗号分隔多个 GitHub PAT，至少 1 个
- 聚合环境用 `TRENDING_GITHUB_TOKENS` / `WEEKLY_GITHUB_TOKENS` / `DISCOVERY_GITHUB_TOKENS` / `SHARING_GITHUB_TOKENS`

### 4.3 存储路径（Fly 生产固定值）

| 变量（聚合前缀） | 裸名 / 独立 App | 路径 |
|------------------|-----------------|------|
| `WIKI_STORE_FILE` | `STORE_FILE` | `/data/wiki.db` |
| `SHARING_STORE_FILE` | `STORE_FILE` | `/data/sharing.db` |
| `TRENDING_STORE_FILE` | `STORE_FILE` | `/data/trending.db` |
| `WEEKLY_STORE_FILE` | `STORE_FILE` | `/data/weekly.db` |
| `WEEKLY_REPO_DIR` | `REPO_DIR` | `/data/weekly-repo` |
| `DISCOVERY_STORE_FILE` | `STORE_FILE` | `/data/discovery.db` |

`fly-secrets-sync.sh` 对聚合与独立 App 都会**强制**上述 `/data/*` 路径。

---

## 5. 分 App 环境变量表

> §5.0 为目标聚合；§5.1 起为**当前生产独立 App**（迁移后仍保留自托管能力）。

### 5.0 starcat-api（目标聚合架构）

完整前缀清单见 `supports/starcat-api/.env.example`。同步入口：`make -C supports fly-secrets-api`。

必填要点：

| 变量 | 说明 |
|------|------|
| 本地 `go run`：`STARCAT_SHARED_API_KEY` + 六个 `*_API_KEYS` | 七项同值；与客户端六个 `STARCAT_PRODUCTION_API_KEY_*` 对齐 |
| Fly 同步：`STARCAT_SHARED_API_KEY` | `fly-secrets-sync.sh` 用它生成六个 `*_API_KEYS` secret；无需从 `.env` 读取六项 |
| `*_STORE_FILE` / `WEEKLY_REPO_DIR` | 强制 `/data/...` |
| `SHARING_BASE_URL` | Fly 强制 `https://starcat.ink` |
| `TRENDING_GITHUB_TOKENS` 等 | 各服务 GitHub PAT |
| `RECOMMEND_SIMREPO_API_KEY` | simrepo |
| `TRENDING_WIKI_API_URL` / `TRENDING_WIKI_API_KEY` | 聚合内预热：loopback + 共用 Key；notifier 带 `X-SC-Svc: wiki` |
| `WEEKLY_WIKI_API_URL` / `WEEKLY_WIKI_API_KEY` | 同上；Weekly notifier 也固定带 `X-SC-Svc: wiki` |
| `DISCOVERY_ADMIN_API_KEYS` | 必填；Discovery 管理接口独立 key，不继承 Weekly Admin Key |

> 2026-08-08 已使用 `gen-api-key.sh` 在本地聚合 `.env` 生成独立 `DISCOVERY_ADMIN_API_KEYS`，并校验格式、唯一性、权限与 Git 忽略状态；这只表示本地输入已就绪，尚未执行 `fly secrets set`。

配置隔离规则：`Apply(service) → FromEnv() → restore()`。只有 wiki 请求路径仍读取的四个 `CACHE_*` 通过显式 `Pin` 保留；禁止把整组服务前缀永久展开到进程环境。

图例（以下独立 App 表）：**R** = Fly secrets 必填　**O** = 可选　**T** = 已在 `fly.toml` 固定　**—** = 不适用

### 5.1 starcat-sharing-api（当前生产独立 App）

| 变量 | 级别 | 默认值 / Fly 生产值 | 说明 |
|------|------|---------------------|------|
| `PORT` | T | `5001` | `fly.toml` `[env]` |
| `GOGC` / `GOMAXPROCS` | T | `100` / `1` | 运行时调优 |
| `STORE_FILE` | R | `/data/sharing.db` | SQLite 路径 |
| `API_KEYS` | R | — | Bearer 白名单 |
| `BASE_URL` | R | `https://starcat.ink`（sync 强制；勿用独立 `*.fly.dev`） | 生成分享短链 `shareUrl` 的 host；**不要**用本地 `localhost` |

公开路由：`GET /healthz`、`GET /s/{id}`、`GET /r/starcat-logo.png`、`GET /r/fonts/{file}`、`GET /r/{owner}/{repo}`、`GET /og/repo/{owner}/{repo}`。

---

### 5.2 starcat-trending-api（当前生产独立 App）

| 变量 | 级别 | 默认值 | 说明 |
|------|------|--------|------|
| `PORT` | T | `5002` | |
| `STORE_FILE` | R | `/data/trending.db` | |
| `API_KEYS` | R | — | |
| `GITHUB_TOKENS` | R | — | enricher / GitHub API |
| `WIKI_API_URL` | O | 独立部署强制 `https://starcat-wiki-api.fly.dev` | 设了且配 `WIKI_API_KEY` 才启用 wiki 预热通知 |
| `WIKI_API_KEY` | O | — | 须与 wiki-api 的 `API_KEYS` 中某个 key 一致 |

cron 频率在代码内固定（daily/weekly/monthly 等），无需 Fly env。

---

### 5.3 starcat-weekly-api（当前生产独立 App）

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
| `WIKI_API_URL` / `WIKI_API_KEY` | O | 同 trending（独立部署 wiki URL 强制旧 App） | |

---

### 5.4 starcat-wiki-api（当前生产独立 App）

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

### 5.5 starcat-recommend-api（当前生产独立 App）

| 变量 | 级别 | 默认值 / Fly 生产值 | 说明 |
|------|------|---------------------|------|
| `PORT` | T | `5005` | |
| `API_KEYS` | R | — | 客户端读取接口 Bearer 白名单 |
| `SIMREPO_API_KEY` | R | — | SimRepo 上游只读 key，只允许放后端 |
| `SIMREPO_ENDPOINT` | O | 内置 SimRepo Qdrant recommend endpoint | 如上游 endpoint 变更再显式配置 |
| `CACHE_TTL_SUCCESS_SECONDS` | O | `604800` | 成功结果进程内缓存 TTL |
| `CACHE_TTL_EMPTY_SECONDS` | O | `21600` | 空结果缓存 TTL |
| `CACHE_TTL_ERROR_SECONDS` | O | `600` | 错误缓存 TTL |

> recommend-api 当前无 SQLite 和 Fly volume，`fly-backup-*` / `fly-restore-*` / `fly-wipe-data-*` 不包含它。

---

### 5.6 starcat-discovery-api（当前生产独立 App）

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
  BASE_URL='https://starcat.ink'

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

# recommend
fly secrets set -a starcat-recommend-api \
  API_KEYS='sk-starcat-...' \
  SIMREPO_API_KEY='simrepo-readonly-key'

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

自建后端 hybrid 鉴权（详见 `Starcat/Core/Network/StarcatAPIKey.swift`）：**六个槽位保留**；聚合发版时六槽填**相同**值。

| 优先级 | 来源 | 配置位置 |
|--------|------|----------|
| 1（最高） | 用户 BYOK | **设置 → 服务** 各服务 API Key → Keychain |
| 2 | 发版 baked-in（每服务一槽） | `Configs/Secrets.xcconfig` → `STARCAT_PRODUCTION_API_KEY_<SERVICE>` → `Info.plist` |

| 服务 | xcconfig 字段 | 对齐来源（聚合） |
|------|---------------|------------------|
| Trending / Weekly / Sharing / Wiki / Recommend / Discovery | 各自 `STARCAT_PRODUCTION_API_KEY_*` | `supports/starcat-api/.env` 的 `STARCAT_SHARED_API_KEY`（六槽同值） |

**开箱即用发版路径（聚合）**：

```bash
# 1. supports/starcat-api/.env：本地运行时 STARCAT_SHARED_API_KEY + 六个 *_API_KEYS 同值；
#    Fly 同步脚本只读取 STARCAT_SHARED_API_KEY，并生成六个 Fly *_API_KEYS secret
# 2. 推到 Fly 聚合 App
make -C supports fly-secrets-api

# 3. 写入客户端 Secrets.xcconfig（只改六个 API Key 行，保留其它 secrets）
make setup-production-api-keys

# 4. 重新 build
xcodegen generate && make run
```

**约束**：每个 `STARCAT_PRODUCTION_API_KEY_*` 必须在聚合进程对应服务的 `*_API_KEYS` 白名单内（聚合场景即共用 Key）。

默认生产 URL：

| 服务 | `AppEndpoints` |
|------|----------------|
| 六个业务 | `https://starcat-api.fly.dev`（`X-SC-Svc` 分流） |

用户可在 **设置 → 服务** 覆盖 baseURL（自托管独立进程）；留空则用聚合默认。

> 旧说明（每仓不同 Key、默认 URL 为各 `*-api.fly.dev`）已废弃；脚本注释中保留。

---

## 8. 备份 `/data` 卷

有状态 App 的 SQLite（及 weekly 的 `weekly-repo/`）都挂在容器 **`/data`**，对应 Fly Volume（见 §1 表）。recommend-api 当前只有进程内缓存，不参与 `/data` 备份。

### 8.1 Makefile（推荐）

```bash
cd supports
make fly-backup-weekly            # 一致性备份 weekly 的 SQLite + weekly-repo
make fly-backup-all               # 顺序备份有状态 App
```

备份脚本不会停止或启动 Machine。它会先对该 Machine 挂载的 Fly Volume 创建平台级
Snapshot，并从快照列表识别新建 ID 后轮询至状态为 `created`；这避免依赖不同 fly CLI
版本的创建命令输出。平台快照创建失败或 5 分钟内未完成时，脚本会退出，不会继续本地归档。
随后它会在远端 `/tmp` 用 `VACUUM INTO` 为对应 SQLite 主库创建一致性
副本，并在归档前排除运行中的 `.db`、`.db-wal`、`.db-shm`；归档中的 `data/weekly.db`
因此可独立恢复。`weekly-repo/` 等非数据库文件仍是在线打包，不保证与 SQLite 之间的同一
时刻一致性。

脚本会在本机临时编译并上传一个静态 Go 快照工具到远端 `/tmp`，结束时自动删除；前提是
本机有 Go 工具链。若 App 有多台 Machine，必须显式指定挂载目标 Volume 的实例：

```bash
FLY_BACKUP_MACHINE_ID=<machine-id> make fly-backup-weekly
```

Machine 未启动时脚本会失败退出，避免为了备份擅自改变生产服务生命周期。

输出目录（默认，可用 `FLY_BACKUP_ROOT` 覆盖）：

```
supports/backups/<fly-app-name>/<YYYYMMDD-HHMMSS>/
  data.tar.gz      # 一致性 SQLite 快照 + 其余远端 /data 文件
  MANIFEST.txt     # app / 时间戳 / Fly Snapshot ID / 快照方式 / 恢复提示
```

`supports/backups/` 已 `.gitignore`，勿把生产库提交进 git。

### 8.2 恢复（Makefile，推荐）

#### 聚合迁库

聚合 App 禁止逐库恢复，也禁止在线覆盖。先用五份旧 App 备份离线生成唯一归档：

```bash
make fly-prepare-api-restore \
  SHARING_BACKUP=backups/starcat-sharing-api/<ts>/data.tar.gz \
  TRENDING_BACKUP=backups/starcat-trending-api/<ts>/data.tar.gz \
  WEEKLY_BACKUP=backups/starcat-weekly-api/<ts>/data.tar.gz \
  WIKI_BACKUP=backups/starcat-wiki-api/<ts>/data.tar.gz \
  DISCOVERY_BACKUP=backups/starcat-discovery-api/<ts>/data.tar.gz

make fly-maintenance-api-on
make fly-restore-api RESTORE_ARCHIVE=backups/starcat-api/<ts>/data.tar.gz
make fly-maintenance-api-off
```

`fly-restore-api` 只接受合并归档；它会验证五库、`weekly-repo/`、`PRAGMA integrity_check` 和远端 `status=maintenance`，再清空一次 `/data`。完整生产门禁见专项 `04-聚合迁库SOP.md`。

#### 当前独立 App 恢复

> **破坏范围**：`fly-restore-data.sh` 两种模式都会先清空远端整个 `/data`。`LOCAL_DB` 只是上传来源为单个 SQLite，不代表只覆盖目标数据库；同卷其它文件也会丢失。Weekly 若需要保留 `/data/weekly-repo`，必须使用包含它的整包归档，不能使用 `LOCAL_DB`。

**方式 A：清空整卷后，只上传本地单个 SQLite 文件**

```bash
cd supports
make fly-restore-trending LOCAL_DB=./starcat-trending-api/trending.db
```

脚本清空 `/data` 后，把文件写到对应的 `STORE_FILE`（如 `/data/trending.db`）；若本地同目录有 `trending.db-wal` / `trending.db-shm` 会一并上传。该模式只适合确认卷内没有其它必须保留数据的独立 App。

**方式 B：从 `fly-backup` 的 tar 整包恢复 `/data`**

```bash
make fly-restore-trending RESTORE_ARCHIVE=supports/backups/starcat-trending-api/<timestamp>/data.tar.gz
```

weekly 应使用此方式同时恢复 `weekly.db` + `weekly-repo/`。

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

## 9. 生产数据与 schema 变更约束

六个独立 App 已承载生产数据，禁止把“清卷重建”作为日常 schema 变更方案：

- schema 变更必须由对应服务提供向前迁移，先备份并验证恢复路径；
- 聚合迁库必须按专项 `04-聚合迁库SOP.md` 执行，不能用 wipe 代替迁移；
- `fly-wipe-data-*` 是会永久删除生产卷数据的应急命令，只能在明确指定 App、已有可验证备份且 dong4j 再次授权后人工执行；
- scheduler 能重新抓取部分缓存，不代表 sharing、weekly、discovery 等全部数据都可重建。

以下命令仅保留为破坏性工具示例，**不是 schema 变更 SOP**：

```bash
make -C supports fly-wipe-data-all    # 或单个 fly-wipe-data-trending
make -C supports fly-deploy-all       # 可选：确保镜像最新
make -C supports fly-health-all
```

执行后服务只会创建空库；任何无法重新抓取的数据都需要从备份恢复。

---

## 10. 常驻运行（fly.toml）

各 App 的 `fly.toml` 都关闭自动停机并至少保持一台 Machine：

```toml
[http_service]
  auto_stop_machines = 'off'
  min_machines_running = 1
```

当前仓库配置：

| Fly App | CPU | 内存 |
|---------|-----|------|
| `starcat-api` | `shared-cpu-1x` | 1024 MB |
| `starcat-discovery-api` | `shared-cpu-1x` | 512 MB |
| sharing / trending / weekly / wiki | `shared-cpu-1x` | 256 MB |
| `starcat-recommend-api` | 未在 `fly.toml` 显式声明 | 以 Fly 当前 Machine 配置为准 |

仪表盘显示的 Volume 容量不是 Machine 内存。配置变更需 `fly deploy` 后才生效；真实线上规格仍以 `fly status` / `fly machine status` 为准。

---

## 11. 相关文件

| 文件 | 用途 |
|------|------|
| `supports/Makefile` | Fly 运维 target |
| `supports/scripts/fly-secrets-sync.sh` | `.env` → `fly secrets set` |
| `supports/scripts/fly-backup-data.sh` | Fly `/data` → 本地 `supports/backups/` |
| `supports/scripts/fly-restore-data.sh` | 本地 `.db` / backup tar → Fly `/data` |
| `supports/scripts/prepare-starcat-api-restore.sh` | 五份旧 App 备份 → 唯一聚合恢复归档 |
| `supports/scripts/gen-api-key.sh` | 生成 `sk-starcat-...` |
| `supports/starcat-*/fly.toml` | 端口、volume、常驻策略 |
| `supports/starcat-*/.env.example` | 本地开发模板 |
| `Configs/Secrets.xcconfig.template` | 客户端 baked-in Key 模板 |
| `docs/6-发版与上架/v1-上架检查清单.md` §2.2 | 上架前 Key 策略检查项 |
