# 架构调整：server 包导出与 API 聚合

> 适用版本: 业务 API 2.x / starcat-api-kit ≥ 0.1 / starcat-api ≥ 0.1  
> 状态: 已落地（本地分支，未 push、未部署生产）  
> 日期: 2026-08-07

## 1. 背景与目标

Fly.io 上六个业务 API（sharing / trending / weekly / wiki / recommend / discovery）各自常开 `shared-cpu-1x`，CPU 账单约十几美元/月。目标：

1. **不合并开源仓业务叙事**：各 API 仍独立 Git 仓、独立 LICENSE / Issue。
2. **可依赖引入**：各仓抽出可导出 `server` 包，供聚合进程 import。
3. **共享横切逻辑**：`starcat-api-kit` 收敛 auth / cors / envelope / tokenpool（及后续 github 等）。
4. **聚合部署单元**：`starcat-api` 单进程，生产默认 **单一 Host + `X-SC-Svc` 头分流**（B 方案）；Host 分流仅作本地 / 自托管回退（license-api 永远独立）。

## 2. 目标架构

```text
supports/
├── starcat-api-kit/          # 共享库（独立仓）
├── starcat-*-api/            # 业务 API：cmd/server + server/ + internal/
│   └── server/               # 可导出：FromEnv / Handler / Close / Name
└── starcat-api/              # 聚合：gateway 按 X-SC-Svc（优先）或 Host 挂载
```

### 2.1 为何必须按服务分流（不能只靠 path）

以下路径在多个 API 上冲突，不能挂到同一个 `ServeMux`：

| 路径 | 冲突方 |
|------|--------|
| `GET /api/v1/repos` | trending ↔ weekly |
| `GET /internal/stats` | sharing ↔ trending |
| `POST /internal/sync/discovery` | discovery ↔ weekly |
| `GET /api/v1/ping` / `GET /healthz` | 全部 |

**B 方案（已定）：** 生产只用 `starcat-api.fly.dev`，客户端请求带短头 `X-SC-Svc: <name>`。网关头优先；无头时回退 Host（`*.localhost` / `STARCAT_HOST_*`）。**不配多自定义域名。** 各仓原路径保持不变。

### 2.2 客户端兼容

Starcat 默认六个业务 `productionURL` → `https://starcat-api.fly.dev`，并注入 `X-SC-Svc`（见 `StarcatGatewayRouting`）。设置页仍可覆盖为用户自托管 baseURL；Paths / envelope / Bearer 契约不变。

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

## 6. 聚合进程环境变量（已落地）

同进程多服务时，裸 `STORE_FILE` 会撞库。`starcat-api` 在调用各 `FromEnv` 前应用前缀覆盖：

- `WIKI_STORE_FILE` → Pin 写入裸 `STORE_FILE`
- `TRENDING_API_KEYS` → 裸 `API_KEYS`
- 规则：`<SERVICE_UPPER>_<KEY>`；网关 `PORT` 永不被服务前缀覆盖
- Fly：`[[mounts]]` → `/data`；`[env]` 默认分库路径见 `supports/starcat-api/fly.toml`

## 7. 进程内内存缓存（聚合后）

各业务在各自 `server.FromEnv` / `New` 里 **new 独立 cache 实例**（如 trending `TrendingCache`、weekly/discovery `BulkCache`、sharing `RepositoryCache`、recommend `CachedProvider`）。模块路径不同，**不会**共用一张全局 map，因此不存在「跨服务 cache key 撞车」。

聚合后真正要盯的：

- **内存叠加**：六套缓存 + 多套 cron 同进程，比单服务吃 RAM/CPU（通常仍为 MB～小几十 MB 级，按 Machine 规格观察）
- **冷启动**：进程重启后内存缓存清空，靠 cron / 请求回填（与旧单 App 重启语义相同）
- **环境变量 Pin**：装配顺序后，进程环境里裸名以最后 Pin 的服务为准；各服务 FromEnv 已在 Pin 窗口内把配置读入自己的结构体，业务路径不依赖事后 getenv（wiki 运行期 `CACHE_*` 已用永久 Pin 处理）

## 8. 明确不做

- 不把 license-api 并入聚合
- **不在未授权时**改生产 Fly / push / 迁库（见铁律 #3；迁库步骤见 `04-聚合迁库SOP.md`）
- 不把各仓 SQLite schema 合成单库（同卷 `/data` 下**分文件**）
- 客户端默认已切聚合 URL + `X-SC-Svc`；设置页仍支持自托管覆盖

## 9. 与 R-01 的关系

R-01「跨仓 byte-level 复制」条款由本架构升级为：**以 `starcat-api-kit` 为单一实现源**，各仓仅保留薄别名。详细抽离路线见同目录 `02-Kit继续抽离方案-GitHub-ping-env.md`。
