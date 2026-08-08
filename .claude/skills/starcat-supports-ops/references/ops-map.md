# Supports 运维地图

## 服务与端口

### 目标生产架构：聚合

| 服务目录 | Fly App | 分流 | 状态 |
|---|---|---|---|
| `starcat-api` | `starcat-api` | `X-SC-Svc` | 有状态，同卷分库 `/data/*.db` |

客户端默认：`https://starcat-api.fly.dev`。迁库：`docs/4-工程进度/重构专项/API聚合与Kit抽离专项/04-聚合迁库SOP.md`。

> 2026-08-08 已完成 `starcat-api` App / Volume / Secrets / 首轮五库种子迁移，并解除维护模式完成六服务 ping 与只读业务验证。旧 App 未停用且仍持续写入，当前属于双跑验证；切流前必须重新进入维护模式并安排最终同步 / 写入冻结窗口。下面六个独立 App 继续承载既有生产流量。

### 当前生产：独立 App（兼容自托管 / 待迁移）

| 服务目录 | Fly App | 本地端口 | 状态 |
|---|---|---:|---|
| `starcat-sharing-api` | `starcat-sharing-api` | 5001 | 有状态，`/data/sharing.db` |
| `starcat-trending-api` | `starcat-trending-api` | 5002 | 有状态，`/data/trending.db` |
| `starcat-weekly-api` | `starcat-weekly-api` | 5003 | 有状态，`/data/weekly.db` 和 `/data/weekly-repo` |
| `starcat-wiki-api` | `starcat-wiki-api` | 5004 | 有状态，`/data/wiki.db` |
| `starcat-recommend-api` | `starcat-recommend-api` | 5005 | 无持久化卷 |
| `starcat-discovery-api` | `starcat-discovery-api` | 5006 | 有状态，`/data/discovery.db` |

## 本地多服务启动

### 聚合（推荐调试）

```bash
cd supports/starcat-api
cp .env.example .env   # 填 STARCAT_SHARED_API_KEY 与分库路径
go run ./cmd/server/
# 默认 PORT=8080；请求带 X-SC-Svc
```

sharing 模板已 `go:embed`，聚合 cwd 不再需要 `templates/` 软链。

### 当前独立进程

`supports/start-all.sh` 负责构建并启动六个独立服务：

```bash
cd supports && ./start-all.sh
cd supports && ./start-all.sh --status
cd supports && ./start-all.sh --stop
```

关键约束：

- 需要 Go 版本与各项目 `go.mod` 对齐。
- 端口 5001 到 5006 必须空闲。
- 脚本会把二进制放到各项目 `bin/`，日志放到各项目 `logs/`。

## Fly secrets 同步

**目标聚合：**

```bash
make -C supports fly-secrets-api
bash supports/scripts/fly-secrets-sync.sh starcat-api
```

**当前生产（独立 App）：**

```bash
make sync-fly-secrets
make -C supports fly-secrets-all
make -C supports fly-secrets-trending
bash supports/scripts/fly-secrets-sync.sh starcat-trending-api
```

规则：

- 从目标项目 `.env` 读取，不 `source` 整个 `.env`。
- 不输出 secrets 明文。
- 聚合：同步脚本读取 `STARCAT_SHARED_API_KEY` 并生成六个 `*_API_KEYS` Fly secret；本地 `go run` 仍需在 `.env` 写六项。前缀变量 + `/data/*` 分库；`SHARING_BASE_URL` 强制 `https://starcat.ink`。
- 聚合配置按 `Apply → FromEnv → restore` 隔离；Discovery Admin Key 必填；trending/weekly Wiki notifier 都走 loopback + `X-SC-Svc: wiki`。
- 当前独立 App：`STORE_FILE` / `REPO_DIR` 强制 `/data/*`；独立 sharing `BASE_URL` 强制 `https://starcat.ink`；独立 trending/weekly 的 `WIKI_API_URL` 强制 `https://starcat-wiki-api.fly.dev`。

## Fly 状态与部署

聚合：

```bash
make -C supports fly-status-api
make -C supports fly-health-api
make -C supports fly-build-check-api  # 只检查构建，不部署；要求 Docker daemon
make -C supports fly-deploy-api    # 生产变更，必须确认
```

当前生产独立 App：

```bash
make -C supports fly-status-all
make -C supports fly-health-all
make -C supports fly-secrets-list
make -C supports fly-deploy-all
```

部署会调用 `fly deploy --remote-only --ha=false`，属于生产变更，必须确认。

## 备份与恢复

备份（迁库前针对**旧独立 App**）：

```bash
make -C supports fly-backup-trending
make -C supports fly-backup-weekly
```

输出在 `supports/backups/<app>/<timestamp>/`，包含 `data.tar.gz` 和 `MANIFEST.txt`。

聚合恢复必须先离线合并五份备份，并在维护模式下一次性恢复：

```bash
make -C supports fly-prepare-api-restore SHARING_BACKUP=... TRENDING_BACKUP=... WEEKLY_BACKUP=... WIKI_BACKUP=... DISCOVERY_BACKUP=...
make -C supports fly-maintenance-api-on
make -C supports fly-restore-api RESTORE_ARCHIVE=backups/starcat-api/<ts>/data.tar.gz
make -C supports fly-maintenance-api-off
```

工具会检查五库完整性、`weekly-repo/` 和远端 maintenance 状态。完整步骤及 Sharing 公网下线门禁见迁库 SOP（勿与“恢复到原独立 App”混淆）。

恢复到原独立 App 时，`LOCAL_DB` 和归档模式都会先清空整个 `/data`；Weekly 要保留 `weekly-repo/` 必须使用包含该目录的整包归档。任何恢复前都先做可验证备份。

## 长期待决

- 是否停机 / 销毁六个独立 Fly App（开源仓可继续保留单仓叙事与自托管）。
- `make sync-fly-secrets` 是否改为默认 `fly-secrets-api`（当前仍指向 `fly-secrets-all`；聚合仅处于双跑验证、尚未最终切流，默认入口暂不改）。
