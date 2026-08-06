# 架构调整：server 包导出与 API 聚合

> 适用版本: 业务 API 2.x / starcat-api-kit ≥ 0.1 / starcat-api ≥ 0.1  
> 状态: 已落地（本地分支，未 push、未部署生产）  
> 日期: 2026-08-07

## 1. 背景与目标

Fly.io 上六个业务 API（sharing / trending / weekly / wiki / recommend / discovery）各自常开 `shared-cpu-1x`，CPU 账单约十几美元/月。目标：

1. **不合并开源仓业务叙事**：各 API 仍独立 Git 仓、独立 LICENSE / Issue。
2. **可依赖引入**：各仓抽出可导出 `server` 包，供聚合进程 import。
3. **共享横切逻辑**：`starcat-api-kit` 收敛 auth / cors / envelope / tokenpool（及后续 github 等）。
4. **聚合部署单元**：`starcat-api` 单进程 Host 分流，把多台 Machine 收成一台（license-api 永远独立）。

## 2. 目标架构

```text
supports/
├── starcat-api-kit/          # 共享库（独立仓）
├── starcat-*-api/            # 业务 API：cmd/server + server/ + internal/
│   └── server/               # 可导出：FromEnv / Handler / Close / Name
└── starcat-api/              # 聚合：gateway 按 Host 挂载各 server.Handler()
```

### 2.1 为何必须 Host 分流

以下路径在多个 API 上冲突，不能挂到同一个 `ServeMux`：

| 路径 | 冲突方 |
|------|--------|
| `GET /api/v1/repos` | trending ↔ weekly |
| `GET /internal/stats` | sharing ↔ trending |
| `POST /internal/sync/discovery` | discovery ↔ weekly |
| `GET /api/v1/ping` / `GET /healthz` | 全部 |

聚合网关按 `Host`（或调试头 `X-Starcat-Service`）转发；**各仓原路径保持不变**。

### 2.2 客户端兼容

生产在切换到单一 Fly app 并绑定原 `*.fly.dev` / 自定义域之前，Starcat 客户端可继续使用分服务 baseURL。路径与 envelope 契约不变，**默认无需改 App 逻辑**（见本专项「Starcat 对接检查」）。

## 3. 已落地清单

| 组件 | 分支 / 提交说明 | 关键产物 |
|------|-----------------|----------|
| starcat-api-kit | `main` 本地 | `auth` `cors` `envelope` `tokenpool` |
| 六个业务 API | `feature/export-server-package` | `server/` + kit 薄别名 |
| starcat-api | `main` 本地 | `internal/gateway` + `cmd/server` |
| 主仓登记 | 工作区未强制提交 | `clone-all.sh` / `SYNC.md` / `AGENTS.md` / promo 脚本 |

## 4. 各 API `server` 包契约

```go
Name() string
DefaultPort() string
FromEnv() (*Service, error)   // 缺配置返回 error，禁止库内 log.Fatal
Handler() http.Handler
Addr() string
Close() error                 // 停 scheduler / 关 SQLite，可重复调用
```

`cmd/server` 仅负责：`godotenv` → `FromEnv` → signal → `ListenAndServe`。

## 5. 构建注意

根目录存在 `server/` 包后，裸 `go build ./cmd/server/` 会与默认输出名 `server` 冲突。CI / Dockerfile 必须使用：

```bash
go build -o bin/<name> ./cmd/server/
```

## 6. 明确不做

- 不把 license-api 并入聚合
- 不在本轮改生产 Fly / 不 push 远端
- 不把各仓 SQLite schema 合成单库
- 不要求客户端立刻改为单一 baseURL（可后续迁移）

## 7. 与 R-01 的关系

R-01「跨仓 byte-level 复制」条款由本架构升级为：**以 `starcat-api-kit` 为单一实现源**，各仓仅保留薄别名。详细抽离路线见同目录 `02-Kit继续抽离方案-GitHub-ping-env.md`。
