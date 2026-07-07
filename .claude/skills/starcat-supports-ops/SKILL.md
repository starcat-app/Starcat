---
name: starcat-supports-ops
description: Starcat supports 后端运维专用流程。用于用户要启动、停止、查看 Starcat 自建 Go API 服务，处理 supports/start-all.sh、supports/Makefile、Fly.io secrets 同步、Fly 状态和健康检查、/data 卷备份恢复、API key 生成、wiki 缓存预热、生产 API key 写入 Configs/Secrets.xcconfig 等后端运维任务。
---

# Starcat Supports 后端运维

使用这个 skill 处理 `supports/` 下自建后端 API 的本地联调和 Fly.io 运维。所有说明必须使用中文；命令、路径、环境变量、服务名等技术字面量保持原文。

## 硬性规则

- 先说明操作计划和副作用，等 dong4j 明确确认后再执行会改变外部状态的命令。
- 对生产 Fly.io 操作默认先只读检查：`make fly-status-all`、`make fly-health-all`、`fly secrets list`。
- 不要打印 `.env` 或 Fly secrets 明文；涉及 key 的命令只报告变量名和同步结果。
- `fly-restore-*`、`fly-wipe-data-*`、`fly secrets set`、`fly deploy` 都是高风险操作，必须单独确认。
- 保留无关 dirty files；本地服务启动/停止不应修改 Swift 代码或文档。

## 入口选择

| 任务 | 推荐入口 |
|---|---|
| 启动全部本地 Go API | `make start-supports` 或 `cd supports && ./start-all.sh` |
| 停止全部本地 Go API | `make stop-supports` 或 `cd supports && ./start-all.sh --stop` |
| 查看本地服务状态 | `cd supports && ./start-all.sh --status` |
| 同步全部 Fly secrets | `make sync-fly-secrets` 或 `make -C supports fly-secrets-all` |
| 查看 Fly 状态/健康 | `make -C supports fly-status-all` / `make -C supports fly-health-all` |
| 备份 Fly /data | `make -C supports fly-backup-<service>` |
| 恢复 Fly /data | `make -C supports fly-restore-<service> LOCAL_DB=...` 或 `RESTORE_ARCHIVE=...` |
| 生成 API key | `bash supports/scripts/gen-api-key.sh [count] [--env]` |
| 预热 wiki 缓存 | `bash supports/scripts/warm-wiki-cache.sh --dry-run` 后再决定是否真实预热 |
| 把 supports `.env` key 写入客户端编译配置 | `make setup-production-api-keys` |

## 标准工作流

1. 读取 `references/ops-map.md`，确认目标服务、命令和风险等级。
2. 先做只读检查：
   - `git status --short`
   - `make -C supports fly-health-all` 或本地 `./start-all.sh --status`
   - 对 secrets 只用 `fly secrets list -a <app>`，不要读取或输出值。
3. 说明命令会影响本地进程、Fly secrets、Fly /data、还是客户端配置。
4. 等确认后执行。
5. 执行后验证：
   - 本地服务：`./start-all.sh --status` 和对应 `/healthz`。
   - Fly secrets：`fly secrets list -a <app>`。
   - Fly 备份：检查 `supports/backups/<app>/<timestamp>/data.tar.gz` 和 `MANIFEST.txt`。
   - Fly 恢复：查看 `/data` 列表和 `/healthz`。

## 重要提醒

- `supports/start-all.sh` 必须从 `supports/` 根启动，它会进入各项目根目录执行服务，不能从 `bin/` 目录直接运行服务。
- 有状态服务是 `sharing`、`trending`、`weekly`、`wiki`、`discovery`；`recommend` 没有持久化卷。
- Fly restore 会覆盖生产 `/data`，恢复前先建议备份。
- `sync-production-api-keys-from-env.sh` 会重写 `Configs/Secrets.xcconfig`，这是仓库文件变更，不是只读运维。

## 参考

详细服务、端口、变量和失败恢复见 `references/ops-map.md`。
