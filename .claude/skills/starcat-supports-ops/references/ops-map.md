# Supports 运维地图

## 服务与端口

### 生产默认：聚合

| 服务目录 | Fly App | 分流 | 状态 |
|---|---|---|---|
| `starcat-api` | `starcat-api` | `X-SC-Svc` | 有状态，同卷分库 `/data/*.db` |

客户端默认：`https://starcat-api.fly.dev`。迁库：`docs/4-工程进度/重构专项/API聚合与Kit抽离专项/04-聚合迁库SOP.md`。

### 遗留：独立 App（自托管 / 过渡）

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

### 遗留：多独立进程

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

**推荐（聚合）：**

```bash
make -C supports fly-secrets-api
bash supports/scripts/fly-secrets-sync.sh starcat-api
```

**遗留（独立 App）：**

```bash
make sync-fly-secrets
make -C supports fly-secrets-all
make -C supports fly-secrets-trending
bash supports/scripts/fly-secrets-sync.sh starcat-trending-api
```

规则：

- 从目标项目 `.env` 读取，不 `source` 整个 `.env`。
- 不输出 secrets 明文。
- 聚合：前缀变量 + `/data/*` 分库；`SHARING_BASE_URL` 强制 `https://starcat.ink`。
- 遗留独立 App：`STORE_FILE` / `REPO_DIR` 强制 `/data/*`；独立 sharing `BASE_URL` 强制 `https://starcat.ink`；独立 trending/weekly 的 `WIKI_API_URL` 强制 `https://starcat-wiki-api.fly.dev`。

## Fly 状态与部署

聚合：

```bash
make -C supports fly-status-api
make -C supports fly-health-api
make -C supports fly-deploy-api    # 生产变更，必须确认
```

遗留独立 App：

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
FLY_BACKUP_STOP=1 make -C supports fly-backup-trending
```

输出在 `supports/backups/<app>/<timestamp>/`，包含 `data.tar.gz` 和 `MANIFEST.txt`。

恢复到聚合卷的步骤见迁库 SOP（勿与「恢复到原独立 App」混淆）。

## 长期待决

- 是否停机 / 销毁六个独立 Fly App（开源仓可继续保留单仓叙事与自托管）。
- `make sync-fly-secrets` 是否改为默认 `fly-secrets-api`（当前仍指向遗留 `fly-secrets-all`，避免误伤过渡期）。
