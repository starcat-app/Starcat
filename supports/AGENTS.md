# supports/AGENTS.md — Starcat 配套项目工作区

> 本目录包含 Starcat 的后端 Go 服务、官网、管理控制台、用户文档、CLI、插件、Homebrew tap 等独立配套项目。
> 本文档给所有 AI 协作者(Claude / Cursor / Gemini CLI 等)阅读，重点记录 Go API 通用约定，并说明其它独立仓库的边界。

---

## AI 协作者开工前必读

1. **根 [`AGENTS.md`](../AGENTS.md)** — Starcat 主仓库全局规则
2. **本文档** — supports/ 整体结构、独立仓库边界与 Go API 通用约定
3. **被修改项目的 `AGENTS.md`** — 每个独立仓库必须提供的项目特定开发规范

每个独立仓库统一以根 `AGENTS.md` 为唯一维护源；跨 Agent 规范只改该文件。

**特殊项目约束：**

- `starcat-recsys-trainer` 是私有 Python 3.12 + uv 离线管道，以项目 `README.md` 和 `docs/使用说明.md` 为准；按建立需求暂不创建 CI workflow，本地变更必须执行 `make check`。
- `starcat-collection-api` 是私有 Go 1.25 独立服务，**不可**导入 `starcat-api` Gateway；它与 Trainer 之间只允许 Admin Key 保护的 Pull 导出。

`supports/` 下的 `.github`、官网、文档、API、CLI、插件、Homebrew 和本地化目录均可能是独立 Git 仓库。**修改前**先在目标目录运行 `git status -sb` 并核对 remote；不要把多个独立仓库的改动混成主仓库提交。

---

## 目录定位

`supports/` 是 Starcat 主项目的**配套项目工作区**。Starcat 主项目（根目录）是 macOS 客户端；本目录中的 GitHub 项目各自拥有独立 remote、分支、CI/CD 和发布边界。

| 项目类型 | 目录 | 说明 |
|----------|------|------|
| 官网 | `starcat-site/` | Direct、Direct Test、App Store 官网源码；旧 `_local-admin` 只保留到新控制台验收 |
| 管理控制台 | `starcat-admin-console/` | React + shadcn/ui 本地运营控制台；远程部署属于第二阶段 |
| 用户文档 | `starcat-docs/` | Mintlify 官方使用文档 |
| 公开支持 | `starcat-pro/` | Issue、公开发布说明与营销图片源 |
| 工具与集成 | `starcat-cli/`、`starcat-skill/`、`extensions/` | CLI/MCP、AI Agent Skill 与浏览器插件 |
| 分发与协作 | `homebrew-starcat*/`、`starcat-localization/`、`.github/` | Homebrew、本地化和组织主页 |
| 后端 API | `starcat-*-api/`、`starcat-api-kit/`、`starcat-api/` | 六个业务服务、共享 kit、聚合网关与独立 license / collection；Fly.io 规则只适用于可部署服务 |
| 数据与离线训练 | `starcat-collection-api/`、`starcat-recsys-trainer/` | 私有数据收集 Go 服务 + Python 离线管道；Collection 只接收快照并导出，Trainer 主动 Pull 后训练 |

> 官网源码、Changelog 生成与部署统一归 `starcat-site/`；服务运营控制台独立归
> `starcat-admin-console/`，不要再扩展 `starcat-site/_local-admin`。

| 子项目 | 用途 | 客户端哪里用 |
|--------|------|--------------|
| `starcat-sharing-api` | AI 分享页面生成 + 渲染 | Starcat 的「分享」功能 |
| `starcat-trending-api` | GitHub Trending 数据抓取 + API | Starcat 的「Trending」视图 |
| `starcat-weekly-api` | 阮一峰周刊项目同步 + API | Starcat 的「Weekly 周刊」分类 |
| `starcat-wiki-api` | GitHub Wiki / 文档可用性探测 + 缓存 | Starcat 的 README / Wiki 辅助入口 |
| `starcat-recommend-api` | 相似仓库推荐 API | Starcat 仓库详情页的相关推荐 |
| `starcat-discovery-api` | 探索发现、热门、新发布榜单 API | Starcat 的「探索」入口 |
| `starcat-collection-api` | 静默接收匿名公开 Star 快照 | 设置中用户主动开启的推荐数据贡献旁路 |

---

## 项目对照表

| 项目 | 端口 | 存储 | 核心能力 | Fly app 名 | 关键依赖 |
|------|------|------|----------|------------|----------|
| `starcat-sharing-api` | 5001 | SQLite(`sharing.db`) | 短链生成、HTML 渲染 | `starcat-sharing-api` | `modernc.org/sqlite` |
| `starcat-trending-api` | 5002 | SQLite(`trending.db`) | GitHub Trending 抓取、榜单 API | `starcat-trending-api` | `goquery` |
| `starcat-weekly-api` | 5003 | SQLite(`weekly.db`) + git repo | 阮一峰周刊项目同步、API 补全 | `starcat-weekly-api` | `goldmark` |
| `starcat-wiki-api` | 5004 | SQLite(`wiki.db`) | Wiki / 文档索引探测、SWR 缓存 | `starcat-wiki-api` | `golang.org/x/net/html` |
| `starcat-recommend-api` | 5005 | 进程内缓存 | SimRepo 相似仓库推荐代理 | `starcat-recommend-api` | `github.com/joho/godotenv` |
| `starcat-discovery-api` | 5006 | SQLite(`discovery.db`) | 探索发现、热门、新发布榜单 | `starcat-discovery-api` | `modernc.org/sqlite`、`robfig/cron` |
| `starcat-collection-api` | 5011 | SQLite(`collection.db`) | 公开 Star 快照分块接收、激活与 Trainer 导出 | `starcat-app/starcat-collection-api`（私有） | `starcat-api-kit`、`modernc.org/sqlite` |
| `starcat-api-kit` | — | — | 共享 auth / envelope / CORS / tokenpool | — | 被各 API 通过版本化 Go module 引用 |
| `starcat-api` | 8080 | `/data` 多库 | `X-SC-Svc` 优先、Host 回退，聚合 6 个业务 API（不含 license） | `starcat-api` | 依赖各 API `server` 包 |

> 聚合路线：各业务 API 导出 `server` 包 + 共享 `starcat-api-kit`；`starcat-api` 单进程托管以降低 Fly 常开机成本。`license-api` 保持独立。2026-08-08 已完成 Fly App / Volume / Secrets / 首轮五库种子迁移，并解除维护模式完成六服务 ping 与只读业务验证；旧 App 未停用且仍持续写入，当前属于双跑验证，不是最终数据切流。切流前必须重新进入维护模式并安排最终同步 / 写入冻结窗口。

---

## 通用技术栈

- **Go 1.25.0** — 六个业务 API、独立 Collection API、`starcat-api-kit` 与 `starcat-api` 的 go.mod 统一
- **net/http** — 标准库 HTTP 服务,无第三方框架
- **godotenv** — `github.com/joho/godotenv`,从 `.env` 文件加载环境变量(2026-06-09 R-01 起统一,详见 §R-01 配置规范)
- **modernc.org/sqlite** — 有状态 API 使用 SQLite(R-01 起 sharing 也改 SQLite,详见对应方案)
- **Docker** — 多阶段构建,slim / scratch 镜像
- **Fly.io** — 当前为 6 个业务独立 App；目标为 `starcat-api` 聚合 App，license 和 collection 继续独立
- **GitHub Actions** — CI(`go vet` + `gofmt` + 编译 + 单测) + CD(fly deploy) + Release(多平台二进制 + GitHub Release),三个 workflow 串联: `go.yml` 成功 → `fly-deploy.yml` + `release.yml` 并行跑

### Go 版本一致性（2026-06-08 起）

**6 个可聚合 API + Collection API 必须保持 Go directive 一致**（统一为 `go 1.25.0`）：

| 项目 | go.mod | workflows/go.yml |
|------|--------|-----------------|
| starcat-sharing-api | `go 1.25.0` | `go-version: [1.25]` |
| starcat-trending-api | `go 1.25.0` | `go-version: [1.25]` |
| starcat-weekly-api | `go 1.25.0` | `go-version: [1.25]` |
| starcat-wiki-api | `go 1.25.0` | `go-version: [1.25]` |
| starcat-recommend-api | `go 1.25.0` | `go-version: [1.25]` |
| starcat-discovery-api | `go 1.25.0` | `go-version: [1.25]` |
| starcat-collection-api | `go 1.25.0` | `go-version-file: go.mod` |

**禁止行为：**

- ❌ 只升级某一个可聚合 API 的 Go 版本（六个需同步）；Collection 也必须继续使用同一 Go directive
- ❌ 升级 Go 后忘了同步 `workflows/go.yml` 的矩阵版本
- ❌ 升级 Go 后没跑 `go build ./... && go vet ./...` 验证

### Module path 与 import 规范

各 API 项目的 `module` 指令必须使用完整路径（2026-06-08 已统一）：

```
github.com/starcat-app/starcat-sharing-api
github.com/starcat-app/starcat-trending-api
github.com/starcat-app/starcat-weekly-api
github.com/starcat-app/starcat-wiki-api
github.com/starcat-app/starcat-recommend-api
github.com/starcat-app/starcat-discovery-api
github.com/starcat-app/starcat-collection-api
```

**项目内 import 必须用绝对路径**（用 module path 前缀），不允许相对路径：

```go
// ✅ 正确
import "github.com/starcat-app/starcat-weekly-api/internal/handler"

// ❌ 错误：Go 1.16+ 不支持
import "./internal/handler"
```

---

## 通用项目结构(参考)

六个可聚合业务 API 遵循相似的布局；license、collection 和聚合网关按自身边界调整：

```
starcat-xxx-api/
├── cmd/server/main.go          # 程序入口
├── server/server.go            # 可导出装配入口，供独立 main 与聚合网关共用
├── internal/                   # 业务逻辑(不可被外部 import)
│   ├── handler/                # HTTP handlers
│   ├── model/                  # 数据模型
│   ├── store/                  # 存储层
│   └── ...                     # 项目特定子包(fetcher/parser/...)
├── .github/                    # CI/CD、Issue 模板
├── Dockerfile                  # 多阶段构建
├── fly.toml                    # Fly.io 部署配置
├── go.mod / go.sum
├── README.md
├── CHANGELOG.md
├── CONTRIBUTING.md
├── AGENTS.md                   # 项目特定 AI 协作规范(weekly 有)
├── .gitignore
├── .dockerignore
└── .gitattributes
```

---

## 开发流程

### 首次克隆并构建

```bash
# 克隆 Starcat 仓库(包含 supports/ 子目录)
git clone https://github.com/starcat-app/Starcat.git
cd Starcat/supports/starcat-xxx-api

# 设置环境变量(以 weekly 为例)
export GITHUB_TOKEN=ghp_xxx

# 安装依赖
go mod download

# 本地运行
go run ./cmd/server/

# 测试
go test ./...
```

### 添加新的 Go 依赖

```bash
go get github.com/xxx/yyy@latest
go mod tidy
go build ./... && go vet ./...
```

**升级后必须：**

- 在该项目的 `CHANGELOG.md` 追加依赖升级记录
- 如果升级导致 breaking change，更新该项目的 `AGENTS.md` 和 `README.md`

### 升级 Go 版本(必须所有 API 项目同步)

```bash
# 1. 升级本地 Go toolchain(https://go.dev/dl/)
# 2. 同步修改所有 API 项目的 go.mod:
#    go X.Y.0
# 3. 同步修改所有 API 项目的 .github/workflows/go.yml:
#    go-version: [X.Y]
# 4. 每个项目跑:
cd starcat-sharing-api && go mod tidy && go build ./... && go vet ./...
cd ../starcat-trending-api && go mod tidy && go build ./... && go vet ./...
cd ../starcat-weekly-api && go mod tidy && go build ./... && go vet ./...
cd ../starcat-wiki-api && go mod tidy && go build ./... && go vet ./...
cd ../starcat-recommend-api && go mod tidy && go build ./... && go vet ./...
cd ../starcat-discovery-api && go mod tidy && go build ./... && go vet ./...
```

### 添加新的独立支撑项目

新增 API、CLI、Launcher、浏览器扩展、Homebrew、文档或网站项目时，优先使用根目录
`.claude/skills/starcat-support-project-create`。每个新项目都必须：

1. 位于 `supports/` 或 `supports/extensions/`，拥有独立 `.git`、remote、分支、CI/CD
   和版本边界，禁止加入 Starcat 主仓库。
2. 补齐 `README.md`、`README-ZH.md`、`LICENSE`、`CODE_OF_CONDUCT.md`、
   `CONTRIBUTING.md`、`SECURITY.md`、`SUPPORT.md`、`CHANGELOG.md`、Issue/PR
   模板和适合技术栈的 CI。
3. 在 `supports/scripts/sync-starcat-readme-promo.py` 登记并生成中英文 Starcat
   推广区块。
4. 同步 `supports/clone-all.sh`、`supports/README.md` 和 `supports/SYNC.md`；
   类型或运维拓扑变化时再同步本 `AGENTS.md`。
5. 创建 GitHub 组织仓库、设置 visibility、推送和配置 secrets 前单独确认外部副作用。

新增 Go API 还必须沿用现有服务规范：

- `go.mod` 使用 `github.com/starcat-app/starcat-xxx-api` 和统一 Go directive；
- 补齐多阶段 `Dockerfile`、`fly.toml`、`.dockerignore`、`.gitattributes`、
  `.env.example` 和 Go/Fly/Release workflows；
- 同步 `supports/start-all.sh`、`supports/Makefile` 和 `supports/scripts/` 运维入口；
- 有 SQLite / Fly volume 时补齐 backup / restore / wipe；无持久化存储时记录原因；
- 同步 `supports/docs/fly-io-环境变量.md` 等跨服务文档和客户端真实调用契约。

---

## 部署(Fly.io)

当前六个独立业务 App 的部署方式如下。目标聚合 App 统一从 `supports/` 作为 Docker build context，并通过 `make -C supports fly-deploy-api` 部署；两类操作都是生产变更，必须先获得明确授权。

### 首次部署

```bash
cd supports/starcat-xxx-api
fly launch                    # 首次创建 app
fly secrets set KEY=value     # 设置 secret(如 GITHUB_TOKEN)
fly volumes create data --size 1   # 持久化卷(有 SQLite / Fly volume 的服务需要)
fly deploy                    # 部署
```

### 后续部署

```bash
# 方式 1: 自动 — push 到 main 触发 .github/workflows/fly-deploy.yml
git push origin main

# 方式 2: 手动
fly deploy
```

### 查看状态

```bash
fly status                    # 应用状态
fly logs                      # 实时日志
fly ssh console               # SSH 进容器
```

### 必要 GitHub Secrets

每个项目在 GitHub repo Settings → Secrets 中配置:

| Secret | 用途 | 共享? |
|--------|------|--------|
| `FLY_API_TOKEN` | Fly.io 部署 token | 六个业务 App 与目标聚合 App 可共用 |
| `GITHUB_TOKEN` / `GITHUB_TOKENS` | 调用 GitHub API | 项目特定(sharing / trending / weekly / discovery 需要) |

---

## R-01 配置规范（2026-06-09 起强制）

### `.env` 文件机制

R-01 起,各 API 服务**统一**使用 `github.com/joho/godotenv` 加载 `.env` 文件作为环境变量来源（每个 API 项目根目录各持一份 `.env`）。

#### 加载顺序

```
1. 进程启动 → godotenv.Load() 读 ./.env（不存在不报错）
2. os.Getenv("KEY") 优先级：
   - OS 环境变量已设置 → 用 OS 值（自动覆盖 .env 值）
   - 只在 .env 文件 → 用 .env 值
   - 都没有 → 用代码默认值
```

#### 关键规则

- **每个 API 项目根目录**各持一份 `.env`（与 `fly.toml` 同级）
- `.env` **必须** 加入 `.gitignore`（敏感值不进 git）
- `.env.example` **必须** 提交 git（占位模板,给开发者参考）
- `.dockerignore` **必须** 包含 `.env`（避免被烤进镜像）
- **fly.io 部署**不用 `.env`,改用 `fly secrets set`（fly secrets 进容器后变环境变量,优先级最高）

#### 常见 env 变量

| 变量 | sharing | trending | weekly | wiki | recommend | discovery | 说明 |
|---|---|---|---|---|---|---|---|
| `PORT` | 5001 | 5002 | 5003 | 5004 | 5005 | 5006 | 服务端口 |
| `STORE_FILE` | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ | SQLite 文件路径；本地默认 `./*.db`，Fly 默认 `/data/*.db` |
| `API_KEYS` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | API 鉴权白名单（详见 §API 鉴权约定） |
| `GITHUB_TOKENS` | ✅ | ✅ | ✅ | ❌ | ❌ | ✅ | GitHub PAT 池（多 token 轮换；sharing 用于公开仓库预览） |
| `ADMIN_API_KEYS` | ❌ | ⚠️ 按需 | ⚠️ 按需 | ❌ | ❌ | ✅ | 管理接口鉴权白名单 |
| `SIMREPO_API_KEY` | ❌ | ❌ | ❌ | ❌ | ✅ | ❌ | recommend-api 访问 SimRepo 的服务端密钥 |

> 详细配置说明 + `.env.example` 模板见各 API 的 `docs/R-01-*-改造方案.md`。
>
> 独立 `starcat-collection-api` 另用 `PORT=5011`、`STORE_FILE`、`API_KEYS`、
> `ADMIN_API_KEYS` 和 `PARTICIPANT_HMAC_KEY`；它不进入聚合 Gateway，两类 Bearer key 禁止复用。

---

## API 鉴权约定（2026-06-09 R-01 起强制）

### Bearer Token 鉴权

各 API 的所有 `/api/v1/*` 数据接口 + `/internal/sync/*` 管理接口**必须**校验请求头：

```
Authorization: Bearer <api-key>
```

> 与 OpenAI / Anthropic 等 AI 接口风格一致,客户端集成成本低。

### API Key 格式

```
sk-starcat-<32 字符 base32 大写>
```

总长度 43 字符,信息熵 160 bit（远超 UUID v4 的 122 bit）。

### 生成 API Key

使用脚本 `supports/scripts/gen-api-key.sh`：

```bash
bash supports/scripts/gen-api-key.sh             # 生成 1 个
bash supports/scripts/gen-api-key.sh 3           # 生成 3 个
bash supports/scripts/gen-api-key.sh 2 --env     # 输出 API_KEYS=k1,k2 可直接粘到 .env
```

### 哪些 endpoint 必须鉴权

| endpoint | 鉴权？ | 备注 |
|---|---|---|
| `GET /healthz` | ❌ 不鉴权 | fly.io health check 用,鉴权会打挂自动重启 |
| `GET /s/{id}` | ❌ 不鉴权 | sharing HTML 渲染,浏览器直访 |
| sharing `GET /r/*`、`GET /og/repo/*` | ❌ 不鉴权 | 公开仓库页、静态资源与 OG 图片；完整路由见 sharing `server/server.go` |
| `/api/v1/*` 全部 | ✅ 必须 | 业务数据,无 key 一律 401 |
| `/internal/sync/*` 全部 | ✅ 必须 | admin 操作,优先使用独立 `ADMIN_API_KEYS`;旧服务如未拆分则使用业务 key 白名单 |

### 跨项目共享鉴权代码

R-01 初版曾要求复制 `internal/middleware/auth.go`；当前实现已把通用鉴权收敛到 `starcat-api-kit/auth`。新增或修改服务应优先复用 kit，并保留各服务自身的路由装配和业务约束。

### 日志脱敏

任何涉及 API Key / GitHub PAT 的日志**必须**脱敏：

```
sk-star****G6AE         # 前 7 + 末 4 + 中间星号
ghp_xxx****abcd
```

**绝对禁止**：`log.Printf("auth ok, key=%s", key)`。

---

## 跨项目共享代码同步约定（2026-06-09 R-01 起）

下表是 R-01 初期的复制范围记录。当前共享的 auth / envelope / CORS / tokenpool / GitHub / env / ping 应优先从 `starcat-api-kit` 使用；只有尚未抽离的业务专属实现才按表核对，不再新增通用代码的多仓复制。

| 共享文件 | sharing | trending | weekly | wiki | recommend | discovery | 备注 |
|---|---|---|---|---|---|---|---|
| `internal/model/envelope.go` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | 6 份保持同一响应语义 |
| `internal/middleware/auth.go` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Bearer 鉴权；改一份时检查其他服务是否需要同步 |
| `internal/enricher/ratelimit.go` | — | ✅ | ✅ | — | — | — | GitHub enrich 服务使用 |
| `internal/tokenpool/tokenpool.go` | ✅ | ✅ | ✅ | — | — | ✅ | GitHub PAT 池轮换 |
| `internal/middleware/cors.go` | ⚠️ 按需 | ⚠️ 按需 | ⚠️ 按需 | ⚠️ 按需 | ⚠️ 按需 | ⚠️ 按需 | 若都需要 CORS 则保持一致 |

> 未来若需要,dong4j 可决定升级到「Go workspace mode + 共享 supports/pkg/*」,但本次 R-01 沿用现有约束。

---

## AI 协作者必做 / 必不做

### 必做项

✅ 修改任何 Go 代码后必须跑 `go build ./... && go vet ./...`
✅ 新增 Go 文件后必须 `git add` 并跑 build 验证
✅ 改 `go.mod` 必须跑 `go mod tidy` 同步 `go.sum`
✅ PR 必须填写 `.github/PULL_REQUEST_TEMPLATE.md`
✅ Bug 报告必须用 `.github/ISSUE_TEMPLATE/bug_report.yml`

### 必不做项

❌ **不要改 `fly.toml` 的 `app` 字段** — 那是 Fly.io 平台的应用名，改了会创建新应用
❌ **不要在 main.go 里硬编码端口/路径** — 用环境变量（`PORT`、`BASE_URL`、`STORE_FILE`）
❌ **不要跨项目 import** — sharing 不能 import trending 的代码

---

## 注意事项(踩过的坑)

1. **编译产物不能进 git**:`/server`、`/bin/`、`.idea/`、`.vscode/`、`.DS_Store` 都被 .gitignore 忽略
2. **数据文件不能进 git**:`*.db`(有状态 API,R-01 起 sharing 也是)、`.weekly-repo/`(weekly)、历史遗留 `data.json`(sharing,R-01 后弃用)
3. **`.env` 文件不能进 git**:各 API 都用 `.env`,**只**提交 `.env.example`
4. **环境变量配置**(R-01 改造后)：
   - sharing: `PORT`、`BASE_URL`、`STORE_FILE`、`API_KEYS`、`GITHUB_TOKENS`
   - trending: `PORT`、`STORE_FILE`、`API_KEYS`、`GITHUB_TOKENS`
   - weekly: `PORT`、`STORE_FILE`、`REPO_DIR`、`API_KEYS`、`GITHUB_TOKENS`（**注意**：R-01 起 `GITHUB_TOKEN` 单值改为 `GITHUB_TOKENS` 多值池）
   - wiki: `PORT`、`STORE_FILE`、`API_KEYS`
   - recommend: `PORT`、`API_KEYS`、`SIMREPO_API_KEY`、`SIMREPO_ENDPOINT`、缓存 TTL
   - discovery: `PORT`、`STORE_FILE`、`API_KEYS`、`ADMIN_API_KEYS`、`GITHUB_TOKENS`、同步 cron、缓存 TTL
5. **CI 矩阵版本必须 ≥ go.mod 的 go directive**:否则 CI 会用 `GOTOOLCHAIN=local` 拒绝构建
6. **测试覆盖率**:weekly 有 parser 单测,sharing/trending 暂未覆盖 — 后续可补；R-01 起每个 API 必带 envelope / auth / ratelimit / tokenpool 单测
7. **bin/server 残留**:starcat-sharing-api 历史上 `bin/server` 被误提交过,新项目别再犯

---

## 文件索引

### supports/ 根目录

| 文件 | 用途 |
|------|------|
| `AGENTS.md` | 本文档，supports/ AI 协作唯一维护源 |
| `README.md` | supports 服务群本地运行与运维入口 |
| `Makefile` | supports 服务群 Fly.io 运维命令聚合 |
| `start-all.sh` | 本地一次性启动所有 API 服务 |

### supports/docs/ 跨项目改造方案

**R-01 三场景共用架构后端改造文档族**（2026-06-09 13:55 v1.2 二次重构：删旧 endpoint 兼容 / sharing 改 SQLite / 加 Bearer 鉴权 / GITHUB_TOKEN 多 Token Pool；与前端 `../docs/3-设计/详细设计/18-三场景共用架构.md` v1.2 同步冻结）：

| 文档 | 版本 | 定位 | 阅读时机 |
|------|---|------|---------|
| `docs/R-01-总体设计.md` | v1.2 | **跨 API 共识层**（URL 版本化 / envelope / 错误响应 / **API Key Bearer 鉴权** / **.env + godotenv** / **GitHub Token Pool** / schema_version 演进 / 跨 API 共享代码同步约定 / 测试策略大纲 / 风险权衡 / 实施步骤总表 / fly.io 部署确认附录） | **开工前必读**，先建立全局视图 |
| `docs/R-01-trending-api-改造方案.md` | v1.2 | trending 专属（从无状态爬虫长出 SQLite 三表 / enricher 字段映射 / **Token Pool** / **Bearer 鉴权中间件** / **admin endpoint `/internal/sync/*`** / **删旧 `/lang` `/repo` `/user`**） | 改 trending 时读 |
| `docs/R-01-weekly-api-改造方案.md` | v1.2 | weekly 专属（migrateV2() 加 14 字段 / enricher 扩字段 + **Token Pool** / **Bearer 鉴权** / **删旧 `/api/weekly/*`** / **`/internal/sync` admin**） | 改 weekly 时读 |
| `docs/R-01-sharing-api-改造方案.md` | v1.2 | sharing 专属（**JSON 文件改 SQLite** / **删旧 `/api/share`** / **Bearer 鉴权** / HTML 渲染 `/s/{id}` 不动） | 改 sharing 时读 |

> 阅读顺序：先看总体设计建立共识，再看当前要改的 API 子文档。任何子文档与总体设计冲突时**以总体设计为准**。

### supports/scripts/ 运维脚本

| 脚本 | 用途 |
|---|---|
| `scripts/gen-api-key.sh` | 一键生成符合 R-01 规范的 API Key（`sk-starcat-<32 字符 base32>`）；支持批量、`--env` 模式 |
| `scripts/fly-secrets-sync.sh` | 从本地 `.env` 同步 Fly secrets；新增 API 服务时必须补 case |
| `scripts/fly-backup-data.sh` | 备份有状态 API 的 Fly volume SQLite 数据 |
| `scripts/fly-restore-data.sh` | 恢复有状态 API 的 Fly volume SQLite 数据 |

### 关键外部引用

| 文档 | 路径 |
|------|------|
| Starcat 全局规则 | `../AGENTS.md` |
| 工程进度索引 | `../docs/功能实现总览.md` |
| 前端 R-01 设计 | `../docs/3-设计/详细设计/18-三场景共用架构.md` |

### API 项目协作规范

- [starcat-api/AGENTS.md](./starcat-api/AGENTS.md) — 聚合网关
- [starcat-api-kit/AGENTS.md](./starcat-api-kit/AGENTS.md) — 共享 Go Kit
- [starcat-collection-api/AGENTS.md](./starcat-collection-api/AGENTS.md) — 推荐数据收集
- [starcat-license-api/AGENTS.md](./starcat-license-api/AGENTS.md) — Direct License
- [starcat-sharing-api/AGENTS.md](./starcat-sharing-api/AGENTS.md) — 分享服务
- [starcat-trending-api/AGENTS.md](./starcat-trending-api/AGENTS.md) — Trending 服务
- [starcat-weekly-api/AGENTS.md](./starcat-weekly-api/AGENTS.md) — Weekly 服务
- [starcat-wiki-api/AGENTS.md](./starcat-wiki-api/AGENTS.md) — Wiki 服务
- [starcat-recommend-api/AGENTS.md](./starcat-recommend-api/AGENTS.md) — 推荐服务
- [starcat-discovery-api/AGENTS.md](./starcat-discovery-api/AGENTS.md) — 探索服务

---

## Commit 规范(建议)

各 API 项目建议使用 [Conventional Commits](https://www.conventionalcommits.org/),格式:

```
<type>(<scope>): <subject>
```

| Type | 用途 |
|------|------|
| feat | 新功能 |
| fix | Bug 修复 |
| docs | 文档变更 |
| style | 代码格式 |
| refactor | 重构 |
| perf | 性能优化 |
| test | 测试相关 |
| chore | 构建/CI/依赖 |

示例:`fix(parser): handle missing language field` / `chore(deps): upgrade goquery to v1.12.0`

---

*最后更新: 2026-06-30(补齐 recommend / discovery 服务清单与新增 API 脚本同步规范)*
