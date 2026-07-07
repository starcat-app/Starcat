# Supports 运维地图

## 服务与端口

| 服务目录 | Fly App | 本地端口 | 状态 |
|---|---|---:|---|
| `starcat-sharing-api` | `starcat-sharing-api` | 5001 | 有状态，`/data/sharing.db` |
| `starcat-trending-api` | `starcat-trending-api` | 5002 | 有状态，`/data/trending.db` |
| `starcat-weekly-api` | `starcat-weekly-api` | 5003 | 有状态，`/data/weekly.db` 和 `/data/weekly-repo` |
| `starcat-wiki-api` | `starcat-wiki-api` | 5004 | 有状态，`/data/wiki.db` |
| `starcat-recommend-api` | `starcat-recommend-api` | 5005 | 无持久化卷 |
| `starcat-discovery-api` | `starcat-discovery-api` | 5006 | 有状态，`/data/discovery.db` |

## 本地多服务启动

`supports/start-all.sh` 负责构建并启动全部服务：

```bash
cd supports && ./start-all.sh
cd supports && ./start-all.sh --status
cd supports && ./start-all.sh --stop
cd supports && ./start-all.sh --no-build
```

关键约束：

- 需要 Go 版本与各项目 `go.mod` 对齐。
- 端口 5001 到 5006 必须空闲。
- 脚本会把二进制放到各项目 `bin/`，日志放到各项目 `logs/`。
- 服务必须从项目根启动，因为 sharing 模板、SQLite 路径、weekly repo 路径依赖相对路径。

## Fly secrets 同步

入口：

```bash
make sync-fly-secrets
make -C supports fly-secrets-all
make -C supports fly-secrets-trending
bash supports/scripts/fly-secrets-sync.sh starcat-trending-api
```

规则：

- 从 `supports/starcat-*-api/.env` 读取，不 `source` 整个 `.env`。
- 不输出 secrets 明文。
- `STORE_FILE` / `REPO_DIR` 在 Fly 上强制使用 `/data/*`。
- `sharing` 的 `BASE_URL` 强制为 `https://starcat-sharing-api.fly.dev`。
- `trending` / `weekly` 的 `WIKI_API_URL` 强制为 `https://starcat-wiki-api.fly.dev`。

## Fly 状态与部署

只读检查：

```bash
make -C supports fly-status-all
make -C supports fly-health-all
make -C supports fly-secrets-list
```

部署：

```bash
make -C supports fly-deploy-all
make -C supports fly-deploy-trending
```

部署会调用 `fly deploy --remote-only --ha=false`，属于生产变更，必须确认。

## 备份与恢复

备份：

```bash
make -C supports fly-backup-trending
FLY_BACKUP_STOP=1 make -C supports fly-backup-trending
```

输出在 `supports/backups/<app>/<timestamp>/`，包含 `data.tar.gz` 和 `MANIFEST.txt`。

恢复：

```bash
make -C supports fly-restore-trending LOCAL_DB=/path/to/trending.db
make -C supports fly-restore-trending RESTORE_ARCHIVE=supports/backups/.../data.tar.gz
FLY_RESTORE_YES=1 make -C supports fly-restore-trending LOCAL_DB=/path/to/trending.db
```

恢复会 stop/start machine、清空远端 `/data`、上传数据并 restart。操作前先备份，除非用户明确跳过。

## API key 与客户端编译配置

生成 key：

```bash
bash supports/scripts/gen-api-key.sh
bash supports/scripts/gen-api-key.sh 3
bash supports/scripts/gen-api-key.sh 2 --env
```

从 supports `.env` 同步到客户端编译配置：

```bash
make setup-production-api-keys
```

这会重写 `Configs/Secrets.xcconfig`，随后需要 `xcodegen generate && 重新 build App`。

## wiki 缓存预热

```bash
bash supports/scripts/warm-wiki-cache.sh --dry-run
bash supports/scripts/warm-wiki-cache.sh --trending
bash supports/scripts/warm-wiki-cache.sh --weekly
bash supports/scripts/warm-wiki-cache.sh --zread
bash supports/scripts/warm-wiki-cache.sh
```

前置条件：

- 本地 `trending-api`、`weekly-api`、`wiki-api` 已启动。
- `sqlite3` 可用。
- dry-run 只统计，不调用 wiki-api。

## 失败处理

| 问题 | 处理 |
|---|---|
| 端口占用 | 先 `cd supports && ./start-all.sh --stop`，仍占用再用 `lsof` 定位 |
| `.env` 缺失 | 从对应 `.env.example` 复制并填值 |
| Fly 未登录 | 让用户执行 `fly auth login` |
| backup 找不到 machine | 先 `fly status -a <app>` 确认 App 存在 |
| restore archive 格式不对 | 必须是 `fly-backup-data.sh` 产出的包含顶层 `data/` 的 tar |
| secrets 同步失败 | 检查缺失 key，不输出实际值 |
