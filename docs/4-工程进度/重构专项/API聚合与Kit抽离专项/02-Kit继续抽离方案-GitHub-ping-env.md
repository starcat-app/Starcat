# Kit 继续抽离方案：GitHub / ping / env

> 适用版本: starcat-api-kit ≥ 0.2.0  
> 状态: **已落地**（A + ping/env；2026-08-07）  
> 日期: 2026-08-07

## 1. 目标

在已有 `auth` / `cors` / `envelope` / `tokenpool` 之上，把多仓复制的横切逻辑继续收敛到 `starcat-api-kit`，供：

- 六个业务 API **独立部署**
- `starcat-api` **聚合进程**

共用同一套实现。

## 2. 本轮范围（A + ping/env）

| kit 包 | 内容 | 消费方 |
|--------|------|--------|
| `github` | `Client`、`GetRepo`、中立 `Repo` DTO、错误类型、可选 `GetReadme` | weekly / trending / sharing / discovery |
| `github` 内 `RateLimitHandler` | 请求间隔 + Pause | weekly / trending（及 Client 内部） |
| `httputil` | `HandlePingV1(service, version)` | 六个业务 API |
| `env` | `LookupRequired` / `CSV` / `OrDefault` / `DurationSeconds` | 各仓 `server.FromEnv` |

### 2.1 本轮不做

- discovery Search / Releases 完整迁入（可继续用本地 `get`，底层 GetRepo 可改调 kit）
- wiki notifier、repo_card 并集
- SQLite / spider / HelloGitHub / SimRepo / BigQuery

## 3. `github` 设计要点

以 **weekly `internal/github`** 为蓝本：

```text
Client
  - pool *tokenpool.Pool
  - limiter *RateLimitHandler（可 nil）
  - http.Client / baseURL / UserAgent
GetRepo(ctx, owner, repo) (*Repo, error)
Repo          // 字段并集，指针可空
ErrNotFound / ErrRateLimited / HTTPError
```

各仓适配：

| 仓 | 改造方式 |
|----|----------|
| weekly | `internal/github` 改为薄包装或直接改 import 到 kit |
| trending | enricher 去掉内联 HTTP，调用 `kit/github.GetRepo` 再写 store |
| sharing | `FetchRepository` 内部调 `GetRepo`，再 map 到 Preview；保留 404/私有合并语义 |
| discovery | `GetRepository` 走 kit；Search/Releases 暂留本地 |

## 4. ping / env

- ping：统一 envelope `{ service, version, ok }`，schema_version=1；鉴权仍由各仓 middleware 包在外面。
- env：纯函数，无 I/O 副作用；缺省配置返回 `error`，由 `FromEnv` / `main` 决定是否 Fatal。

## 5. 兼容与测试

- HTTP 路径与 JSON 字段名对客户端 **保持不变**
- 单测：kit 内 httptest 覆盖 200/404/401/429/5xx；各仓既有 ping / enrich / github 测试继续绿
- 仅本地 `go test` / `go build`；**禁止 Fly deploy**

## 6. 落地顺序

1. kit 实现 `github` + `httputil` + `env` + 测试 → kit 记 0.2.0  
2. weekly 切换 → trending → sharing → discovery  
3. 六个 API ping / FromEnv 改用 kit  
4. Starcat 客户端契约检查（默认无代码变更）  
5. 多轮审查与专项报告
