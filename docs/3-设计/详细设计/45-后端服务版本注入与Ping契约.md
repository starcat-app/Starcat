# 后端服务版本注入与 Ping 契约详细设计

> 日期：2026-07-21
> 状态：待实施
> 文档编号：45
> 适用范围：`starcat-trending-api`、`starcat-weekly-api`、`starcat-sharing-api`、`starcat-wiki-api`、`starcat-recommend-api`、`starcat-discovery-api` 与 Starcat「设置 → 服务」连接测试

## 1. 背景

Starcat 通过带 Bearer Auth 的 `GET /api/v1/ping` 验证外部服务地址、API Key 和服务类型。现有响应只包含：

```json
{
  "schema_version": 1,
  "data": {
    "service": "trending",
    "ok": true
  }
}
```

客户端目前能确认“服务可达且类型正确”，但无法判断线上实例运行的是哪个发布版本。六个 Go 服务的版本管理也不统一：部分仓库保留手工维护的 `internal/version.Version`，部分仓库没有版本包，构建流程尚未把 release tag 注入二进制。

本方案把生产发布 tag 作为版本单一真源，在构建镜像时注入 Go 二进制，再由现有 ping 响应返回版本号。客户端按可选字段解析，使后端可以逐个服务升级，不要求同时发布。

## 2. 目标与非目标

### 2.1 目标

- 六个服务使用同一套版本来源、构建注入和 ping 返回契约。
- 生产版本与实际发布 tag 一致，不再依赖手工同步源码常量。
- Starcat 能显示 `可达, 版本号: 1.2.3`。
- 老后端没有 `version` 字段时，Starcat 仍显示“可达”。
- 后端分批升级和回滚时保持协议兼容。
- 手动生产部署也必须携带明确版本，避免发布 `0.0.0-dev`。

### 2.2 非目标

- 不新增公开 `/version` 接口；版本沿用已有鉴权 ping 返回。
- 不改变 `/healthz` 的公开、无鉴权和轻量存活检查职责。
- 不把 Fly release 序号、镜像 digest 或 Git commit hash 冒充产品语义化版本。
- 不在服务启动后读取 `.git`、Makefile 或远端 GitHub API。
- 不改变现有 Bearer Auth、envelope `schema_version` 或服务名校验逻辑。

## 3. 当前基线

> 下表是 2026-07-21 本地仓库快照，只用于说明版本源漂移，不能证明当前线上部署版本。

| 服务 | 源码内版本 | 本地最新 tag | ping 返回版本 | 主要缺口 |
|---|---:|---:|---:|---|
| `starcat-trending-api` | `1.0.0` | `v1.1.1` | 否 | 源码常量已落后 tag |
| `starcat-weekly-api` | `1.0.0` | `v1.1.1` | 否 | 源码常量已落后 tag |
| `starcat-sharing-api` | `1.0.0` | `v1.1.1` | 否 | 源码常量已落后 tag |
| `starcat-wiki-api` | 无 | `v1.1.0` | 否 | 没有统一版本模块 |
| `starcat-recommend-api` | `0.1.0` | 本地无 tag | 否 | 硬编码且未接入 ping |
| `starcat-discovery-api` | `0.1.0` | 本地无 tag | 否 | 仅启动日志读取；部署脚本传入的 build arg 未被 Dockerfile 消费 |

六个目录都是独立 Git 仓库。实施前必须分别检查 `git status`、当前分支、remote 和 `git worktree list`，不能把主 Starcat 仓库状态当成后端仓库状态。

## 4. 核心决策

### 4.1 版本单一真源

生产版本的单一真源是 Git release tag，格式保持现有发布脚本约束：

```text
vMAJOR.MINOR.PATCH
```

例如 tag 为 `v1.2.3`，注入二进制和 API 返回的值统一为：

```text
1.2.3
```

去掉前导 `v` 是展示契约，不由客户端二次猜测或格式化。

### 4.2 构建期注入而非运行时配置

版本属于不可变构建元数据，应和二进制绑定。统一使用 Go linker `-X`：

```text
Git tag
  → deploy workflow / deploy.sh
  → Docker --build-arg VERSION=1.2.3
  → go build -ldflags "-X <module>/internal/version.Version=1.2.3"
  → version.Version
  → GET /api/v1/ping
```

不采用运行时环境变量 `SERVICE_VERSION`，原因是环境变量可以在不替换镜像的情况下变化，无法可靠证明当前二进制版本。

### 4.3 本地开发默认版本

没有注入时统一使用 SemVer 合法的预发布值：

```text
0.0.0-dev
```

该值方便本地 Docker、自托管和直接 `go run` 排障。生产部署流程必须拒绝该默认值。

## 5. 统一 Go 版本模块

每个服务维护 `internal/version/version.go`。`wiki-api` 需要新增，其余服务统一字段名称：

```go
// Package version 暴露当前服务的构建版本信息。
package version

const Service = "trending"

// Version 默认用于本地开发；生产镜像通过 go build -ldflags -X 覆盖。
// 必须声明为 var，因为 Go linker 不能覆盖 const。
var Version = "0.0.0-dev"
```

各仓库的 `Service` 固定值如下：

| 仓库 | `version.Service` |
|---|---|
| `starcat-trending-api` | `trending` |
| `starcat-weekly-api` | `weekly` |
| `starcat-sharing-api` | `sharing` |
| `starcat-wiki-api` | `wiki` |
| `starcat-recommend-api` | `recommend` |
| `starcat-discovery-api` | `discovery` |

已有的 `Name` 若仍被其他代码使用可以保留，但 ping 和启动日志统一读取 `Service` 与 `Version`。

## 6. Ping API 契约

### 6.1 Handler

六个服务继续保持同构的 `ping.go`，通过参数注入服务名和版本，避免 handler 反向依赖每个仓库不同的 module path：

```go
type pingResponse struct {
    Service string `json:"service"`
    OK      bool   `json:"ok"`
    Version string `json:"version"`
}

func HandlePingV1(service, serviceVersion string) http.HandlerFunc {
    return func(w http.ResponseWriter, r *http.Request) {
        writeJSON(w, pingResponse{
            Service: service,
            OK:      true,
            Version: serviceVersion,
        })
    }
}
```

### 6.2 路由注册

`cmd/server/main.go` 不再硬编码服务名：

```go
mux.Handle(
    "GET /api/v1/ping",
    authMW.Wrap(handler.HandlePingV1(version.Service, version.Version)),
)
```

启动日志也应打印相同版本，便于 Fly logs 与 ping 相互核对：

```go
log.Printf("starcat-trending-api %s starting on port %s", version.Version, port)
```

### 6.3 成功响应

```json
{
  "schema_version": 1,
  "data": {
    "service": "trending",
    "ok": true,
    "version": "1.2.3"
  }
}
```

约束：

- `version` 必须为非空字符串。
- 生产值必须符合 `MAJOR.MINOR.PATCH`，不带前导 `v`。
- `schema_version` 仍为 `1`；新增可选字段属于向后兼容扩展，不需要升级 envelope schema。
- `service` 与 `ok` 语义不变。
- 401、4xx、5xx 和网络错误响应不增加版本字段。

## 7. Docker 构建注入

每个 Dockerfile 在 builder stage 声明默认参数：

```dockerfile
ARG VERSION=0.0.0-dev
```

构建命令按各自 `go.mod` module path 注入：

```dockerfile
RUN CGO_ENABLED=0 GOOS=linux go build \
    -ldflags="-w -s -X github.com/starcat-app/starcat-trending-api/internal/version.Version=${VERSION}" \
    -o /app/bin/server \
    ./cmd/server/
```

六个 linker symbol：

| 服务 | `-X` symbol |
|---|---|
| Trending | `github.com/starcat-app/starcat-trending-api/internal/version.Version` |
| Weekly | `github.com/starcat-app/starcat-weekly-api/internal/version.Version` |
| Sharing | `github.com/starcat-app/starcat-sharing-api/internal/version.Version` |
| Wiki | `github.com/starcat-app/starcat-wiki-api/internal/version.Version` |
| Recommend | `github.com/starcat-app/starcat-recommend-api/internal/version.Version` |
| Discovery | `github.com/starcat-app/starcat-discovery-api/internal/version.Version` |

不依赖 Docker build context 中是否包含 `.git`，因此各仓库当前不同的 `.dockerignore` 策略不会影响版本注入。

## 8. 发布流程改造

### 8.1 Trending / Weekly / Sharing / Wiki

这四个仓库当前由 `v*` tag 触发 Go workflow，再由 `workflow_run` 触发 Fly deploy。部署 job 使用：

```yaml
env:
  RELEASE_TAG: ${{ github.event.workflow_run.head_branch }}
run: |
  [[ "$RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
  VERSION="${RELEASE_TAG#v}"
  flyctl deploy --remote-only --build-arg VERSION="$VERSION"
```

`workflow_dispatch` 不能静默使用 `0.0.0-dev`。应增加必填 `version` input，同样执行 SemVer 校验后再部署。

### 8.2 Recommend

Recommend 当前直接监听 `push.tags: ['v*']`，版本来源使用 `github.ref_name`：

```yaml
env:
  RELEASE_TAG: ${{ github.ref_name }}
```

后续步骤与上面相同：校验 tag、去掉 `v`、通过 `--build-arg VERSION` 传给 Fly builder。

### 8.3 Discovery

Discovery 的 `scripts/deploy.sh` 已传 `--build-arg VERSION`，但当前 Dockerfile 没有 `ARG VERSION`，也没有 linker `-X`，导致参数被忽略。实施时需要：

1. Dockerfile 真正消费 `VERSION`。
2. `internal/version.Version` 从 `const` 改为可注入 `var`。
3. deploy script 将 `v1.2.3` 规范化为 `1.2.3` 后再传入。
4. 若补充 tag 驱动的生产 workflow，必须沿用同一校验和注入逻辑，不能出现第二套版本来源。

### 8.4 Makefile 定位

Makefile 中的 `VERSION` 只作为发布命令输入和开发便利值，不能成为运行时真源。若继续保留手工 `VERSION := ...`：

- 发布脚本必须用它创建同值 tag；
- 真正注入生产二进制的仍是 CI 收到的 tag；
- 后续可单独收口 Makefile 的重复维护，但不纳入本次最小实现。

## 9. Starcat 客户端契约

客户端按渐进兼容方式处理 `data.version`：

| 后端响应 | Starcat 显示 |
|---|---|
| 无 `version` | `可达` |
| `version: null` | `可达` |
| `version: ""` 或仅空白 | `可达` |
| `version: "1.2.3"` | `可达, 版本号: 1.2.3` |

客户端仍必须先验证：

1. HTTP 200；
2. envelope 可解码；
3. `data.ok == true`；
4. `data.service` 与当前设置项一致。

只有上述条件全部成立后才显示版本。版本字段不能绕过服务名或鉴权校验。

## 10. 测试方案

### 10.1 每个后端仓库

`ping_test.go` 至少覆盖：

- 200 envelope 包含正确 `service / ok / version`；
- version 与传入 handler 的值完全一致；
- `schema_version` 仍为 1；
- 未授权请求仍返回 401；
- ping 不新增 `meta`。

基础验证：

```bash
go test ./...
go test -race ./...
go vet ./...
go build ./...
```

构建注入验证：

```bash
docker build --build-arg VERSION=9.9.9-test -t starcat-service-version-test .
```

启动容器后，用测试 API Key 请求 `/api/v1/ping`，确认返回的 `data.version` 为 `9.9.9-test`。测试密钥只通过临时环境变量传入，不写入日志、文档或仓库。

### 10.2 Starcat

- 无版本字段：成功且不显示副文案。
- 正常版本：显示本地化后的完整文案。
- 空白版本：按无版本处理。
- service 不匹配：仍返回 `serviceMismatch`。
- 401 / 5xx：仍显示 HTTP 状态码，不显示版本。

定向测试：

```bash
xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' \
  -only-testing:StarcatTests/ServiceHealthCheckerTests test
```

### 10.3 部署后验收

每个服务分别验证：

1. `/healthz` 保持 200。
2. `/api/v1/ping` 无 key 保持 401。
3. `/api/v1/ping` 正确 key 返回 200。
4. `data.service` 正确。
5. `data.version` 等于本次 release tag 去掉 `v` 后的值。
6. Fly 启动日志中的版本与 ping 一致。
7. Starcat 设置页显示预期版本。

## 11. 实施顺序

六个后端是独立仓库，按服务逐个完成闭环，不进行跨仓库一次性盲改：

1. 逐仓库检查 branch、status、worktree 与已有未提交修改。
2. 修改 version package、ping handler、main、Dockerfile 和测试。
3. 修改该仓库自己的发布 workflow / deploy script。
4. 运行 Go 全量测试与本地镜像注入 smoke test。
5. 如仓库 README / README-ZH 已记录 ping 响应，同步更新两份文档。
6. 先验证测试环境；没有独立测试环境时，至少完成本地 Docker smoke test。
7. 明确获得部署许可后再发布生产，发布后立即执行 §10.3。
8. 一个服务验收通过后再进入下一个服务。

建议先从结构最简单的 Recommend 或 Discovery 验证模板，再把确认后的同构改动复制到其余服务。复制后仍需逐仓库检查 module path、workflow 触发事件和 service 名，禁止机械替换后直接部署。

## 12. 回滚策略

- 后端回滚到旧镜像后，ping 不再返回 `version`；Starcat 因字段可选，自动退化为只显示“可达”。
- 客户端无需跟随后端回滚。
- envelope schema 不变，不涉及数据库迁移和持久化数据变更。
- 若某服务版本注入错误，只回滚该服务独立仓库和 Fly app，不影响其余五个服务。
- 版本错误不能通过修改运行时环境变量“热修”；必须重新构建并发布正确版本，保证版本与二进制重新绑定。

## 13. 实施 Checklist

### 通用代码

- [ ] 六个服务都有统一 `internal/version/version.go`。
- [ ] `Version` 为可被 linker 覆盖的 `var`。
- [ ] 本地默认值为 `0.0.0-dev`。
- [ ] ping 返回 `service / ok / version`。
- [ ] 启动日志打印同一 `version.Version`。
- [ ] ping 单测覆盖版本字段。

### 构建与发布

- [ ] 六个 Dockerfile 消费 `ARG VERSION`。
- [ ] 六个 Dockerfile 使用正确 module path 执行 linker `-X`。
- [ ] tag 驱动 workflow 把 `vX.Y.Z` 转成 `X.Y.Z`。
- [ ] 手动生产部署要求显式版本。
- [ ] 生产流程拒绝 `0.0.0-dev`。
- [ ] Discovery 当前无效的 build arg 链路被真正接通。

### 验收

- [ ] 六仓库 `go test ./...` 通过。
- [ ] 六仓库 `go test -race ./...` 通过。
- [ ] 六仓库 `go vet ./...` 和 `go build ./...` 通过。
- [ ] 本地镜像 smoke test 能返回注入版本。
- [ ] 测试环境 ping 与 tag 一致。
- [ ] 获得明确部署许可后，生产逐服务发布并验收。
- [ ] Starcat 对新旧后端的显示均符合 §9。

## 14. 完成标准

只有同时满足以下条件，才能认为该专项完成：

- 六个生产服务返回的 `data.version` 都与各自 release tag 一致；
- 任一服务从日志、ping 和发布记录看到的版本一致；
- Starcat 对无版本旧服务保持兼容；
- 所有发布路径，包括 tag 自动部署和人工逃生入口，都不会生成无明确版本的生产镜像；
- 后端 README / README-ZH、API 文档和 Starcat 详细设计中的契约没有相互冲突。
