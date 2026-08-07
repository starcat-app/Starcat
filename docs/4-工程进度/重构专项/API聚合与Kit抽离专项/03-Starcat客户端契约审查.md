# Starcat 客户端契约审查

> 日期: 2026-08-07  
> 范围: `Starcat/Core/Network/AppEndpoints.swift` 及各 `*API` / `ServiceHealthChecker`  
> 结论: **本轮无需改业务调用逻辑**；仅补充架构注释（v10）

## 1. 审查问题

上一轮「server 导出 + 聚合网关」未改 Starcat 客户端。本轮在落地 kit github/ping/env 后，确认客户端是否必须跟着改。

## 2. 契约对照

| 契约面 | 客户端现状 | 后端本轮变更 | 是否需改客户端 |
|--------|------------|--------------|----------------|
| 默认 baseURL | 各服务独立 `*.fly.dev` | 聚合网关可选；独立部署仍可用 | 否（默认保持分服务） |
| Paths | `/api/v1/...`、`/healthz`、`/api/v1/ping` | 路径未改 | 否 |
| ping envelope | `schema_version=1` + `{service,version,ok}` | kit `httputil.HandlePingV1` 同契约 | 否 |
| Bearer Auth | 设置页 Key → Authorization | middleware 仍包在 ping 外 | 否 |
| Host 分流 | 未使用 | 仅聚合进程需要 | 否（未切聚合域名） |

## 3. 代码动作

- 在 `AppEndpoints.swift` 文件头追加 **v10** 说明：聚合网关存在，但默认仍走分服务 URL；将来切域名只改 baseURL / 设置项。
- **不**改 `ServiceHealthChecker`、各 `*API` actor、Paths 常量。

## 4. 后续可选（非本轮）

若生产切到单一 `starcat-api` 域名：

1. 为每个逻辑服务配置不同 Host 或统一 base + `X-Starcat-Service`
2. 在设置页 / `resolve` 注入聚合 URL
3. 再补客户端集成测与文档；仍不必改 Paths
