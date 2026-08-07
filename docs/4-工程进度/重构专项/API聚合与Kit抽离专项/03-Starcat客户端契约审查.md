# Starcat 客户端契约审查

> 日期: 2026-08-07  
> 范围: `AppEndpoints` / `StarcatGatewayRouting` / 各 `*API` / `ServiceHealthChecker`  
> 结论: **B 方案已落地**——默认聚合域名 + `X-SC-Svc`；自托管仍可覆盖 baseURL

## 1. 审查问题

聚合网关落地后，客户端默认是否切到单一 `starcat-api.fly.dev`，以及如何与自托管共存。

## 2. 契约对照（B 方案）

| 契约面 | 客户端 | 后端 | 状态 |
|--------|--------|------|------|
| 默认 baseURL | 六个业务均 `https://starcat-api.fly.dev` | 聚合进程监听同一 Host | 已对齐 |
| 分流头 | 始终发 `X-SC-Svc: <rawValue>` | 网关头优先；兼收旧 `X-Starcat-Service` | 已对齐 |
| Paths | `/api/v1/...`、`/healthz`、`/api/v1/ping` | 各 server 原路径未改 | 不变 |
| ping envelope | `schema_version=1` + `{service,version,ok}` | kit ping | 不变 |
| Bearer Auth | 各服务独立 Key | 各服务 `*_API_KEYS` Pin | 不变 |
| `/healthz` 巡检 | 不带头（聚合返回服务列表） | 网关聚合 healthz | OK |
| 自托管 | 设置页覆盖 baseURL；仍可带头 | 独立进程忽略未知头 | 支持 |

## 3. 代码动作

- 新增 `StarcatGatewayRouting.swift`（头名 + 聚合 URL）
- `AppEndpoints` v11：六个 `productionURL` 指向聚合入口（license 除外）
- Trending / Weekly / Sharing / Wiki / Recommend / Discovery / StarHistory + `ServiceHealthChecker` 注入 `X-SC-Svc`
- trending `WikiNotifier` 固定带 `X-SC-Svc: wiki`

## 4. 运维注意

- **无需**为六个服务配置自定义域名
- 部署 `starcat-api` 后旧 `starcat-*-api.fly.dev` 可逐步下线；在此之前旧客户端仍可打独立 app
- 用户本地 / 自托管：设置页填 `http://127.0.0.1:500x` 即可
