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
| 分流头 | 业务请求与 `/api/v1/ping` 发 `X-SC-Svc: <rawValue>` | 网关头优先；兼收旧 `X-Starcat-Service` | 已对齐 |
| Paths | `/api/v1/...`、`/healthz`、`/api/v1/ping` | 各 server 原路径未改 | 不变 |
| ping envelope | `schema_version=1` + `{service,version,ok}` | kit ping | 不变 |
| Bearer Auth | 六槽可同值，仍按服务发送 | 各 `*_API_KEYS` 仅在本服务 FromEnv 窗口生效 | 不变 |
| `/healthz` 巡检 | 不带头（聚合返回服务列表） | 网关聚合 healthz | OK |
| 自托管 | 设置页覆盖 baseURL；仍可带头 | 独立进程忽略未知头 | 支持 |

## 3. 代码动作

- 新增 `StarcatGatewayRouting.swift`（头名 + 聚合 URL）
- `AppEndpoints` v11：六个 `productionURL` 指向聚合入口（license 除外）
- Trending / Weekly / Sharing / Wiki / Recommend / Discovery / StarHistory + `ServiceHealthChecker` 注入 `X-SC-Svc`
- trending `WikiNotifier` 固定带 `X-SC-Svc: wiki`
- weekly `WikiNotifier` 同样固定带 `X-SC-Svc: wiki`
- `StarcatGatewayRoutingTests` 固化六服务 productionURL 与头部映射

### 3.1 `/healthz` 的当前语义限制

六个服务默认 baseURL 相同，因此状态栏会并发请求六次同一个 `https://starcat-api.fly.dev/healthz`。`ServiceAvailabilityChecker` 只判断 HTTP 2xx，不解析响应中的 `services`：当前结果表示“聚合网关进程可访问”，不能证明某个业务服务已挂载或健康。单服务契约仍以带 `X-SC-Svc` 和 Bearer Auth 的 `/api/v1/ping`、再加真实业务抽样为准。

## 4. 运维注意

- **无需**为六个服务配置自定义域名
- 2026-08-08 已完成 Fly App / Volume / Secrets / 首轮五库种子迁移，并解除维护模式通过六服务 ping 与只读业务验证；旧 App 未停用且仍持续写入，当前仅为双跑验证，切流前必须重新进入维护模式完成最终同步 / 写入冻结和复验
- 用户本地 / 自托管：设置页填 `http://127.0.0.1:500x` 即可
- 本专项不增加客户端双轨：生产聚合部署、迁库和验收必须早于 Starcat 正式版发布
- `starcat.ink` 公开 Sharing 路由必须由代理注入 `X-SC-Svc: sharing`，详见迁库 SOP §7
