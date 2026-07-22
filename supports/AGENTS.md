# supports/AGENTS.md — Starcat 配套项目工作区

> 本目录包含 Starcat 的后端 Go 服务、官网、用户文档、CLI、插件、Homebrew tap 等独立配套项目。
> 本文档给所有 AI 协作者(Claude / Cursor / Gemini CLI 等)阅读，重点记录 Go API 通用约定，并说明其它独立仓库的边界。

---

## 目录定位

`supports/` 是 Starcat 主项目的**配套项目工作区**。Starcat 主项目（根目录）是 macOS 客户端；本目录中的 GitHub 项目各自拥有独立 remote、分支、CI/CD 和发布边界。

| 项目类型 | 目录 | 说明 |
|----------|------|------|
| 官网 | `starcat-site/` | Direct、Direct Test、App Store 官网与本地运营控制台的源码单一来源 |
| 用户文档 | `starcat-docs/` | Mintlify 官方使用文档 |
| 公开支持 | `starcat-pro/` | Issue、公开发布说明与营销图片源 |
| 工具与集成 | `starcat-cli/`、`starcat-skill/`、`extensions/` | CLI/MCP、AI Agent Skill 与浏览器插件 |
| 分发与协作 | `homebrew-starcat*/`、`starcat-localization/`、`.github/` | Homebrew、本地化和组织主页 |
| 后端 API | `starcat-*-api/` | 下表列出的 Go 服务；Fly.io 规则只适用于这些项目 |

> 官网已从根目录 `pages/` 拆分到 `starcat-site/`。旧 `pages/` 只用于迁移验证，不再作为官网源码来源。

| 子项目 | 用途 | 客户端哪里用 |
|--------|------|--------------|
| `starcat-sharing-api` | AI 分享页面生成 + 渲染 | Starcat 的「分享」功能 |
| `starcat-trending-api` | GitHub Trending 数据抓取 + API | Starcat 的「Trending」视图 |
| `starcat-weekly-api` | 阮一峰周刊项目同步 + API | Starcat 的「Weekly 周刊」分类 |
| `starcat-wiki-api` | GitHub Wiki / 文档可用性探测 + 缓存 | Starcat 的 README / Wiki 辅助入口 |
| `starcat-recommend-api` | 相似仓库推荐 API | Starcat 仓库详情页的相关推荐 |
| `starcat-discovery-api` | 探索发现、热门、新发布榜单 API | Starcat 的「探索」入口 |

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

---

## 通用技术栈

- **Go 1.25.0** — 6 个项目 go.mod 统一(2026-06-08 起,详见 [`CLAUDE.md`](./CLAUDE.md))
- **net/http** — 标准库 HTTP 服务,无第三方框架
- **godotenv** — `github.com/joho/godotenv`,从 `.env` 文件加载环境变量(2026-06-09 R-01 起统一,详见 §R-01 配置规范)
- **modernc.org/sqlite** — 有状态 API 使用 SQLite(R-01 起 sharing 也改 SQLite,详见对应方案)
- **Docker** — 多阶段构建,slim / scratch 镜像
- **Fly.io** — 部署平台,6 个项目 6 个独立 app
- **GitHub Actions** — CI(`go vet` + `gofmt` + 编译 + 单测) + CD(fly deploy) + Release(多平台二进制 + GitHub Release),三个 workflow 串联: `go.yml` 成功 → `fly-deploy.yml` + `release.yml` 并行跑

---

## 通用项目结构(参考)

各 API 项目都遵循相似的布局:

```
starcat-xxx-api/
├── cmd/server/main.go          # 程序入口
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

### 添加新的子项目

新增项目时,必须沿用现有的工程规范(详见 [`CLAUDE.md`](./CLAUDE.md)):

1. 创建目录 `starcat-xxx-api/`
2. **必带文件**(参考 sharing / weekly):
   - `go.mod`(`module github.com/starcat-app/starcat-xxx-api`、`go 1.25.0`)
   - `Dockerfile`(多阶段构建,参考 sharing 或 weekly)
   - `fly.toml`
   - `.gitignore`(参考 sharing 的 76 行版本)
   - `.dockerignore`
   - `.gitattributes`
   - `README.md`、`CHANGELOG.md`、`CONTRIBUTING.md`
   - `.github/`(8 个标准文件:`FUNDING.yml`、`dependabot.yml`、`workflows/{go,fly-deploy,release}.yml`、`PULL_REQUEST_TEMPLATE.md`、`ISSUE_TEMPLATE/{bug_report,feature_request}.yml`)
   - `release.yml` 2026-06-08 起统一加入(产出多平台二进制 + 发 GitHub Release)
3. 同步更新本 `AGENTS.md` 的目录表、项目对照表、配置说明和文件索引
4. 同步更新本 `CLAUDE.md` 的关键约束、项目清单和部署说明
5. 同步更新 `supports/start-all.sh`、`supports/Makefile` 和 `supports/scripts/` 下的运维脚本；有 SQLite / Fly volume 的服务还必须补齐 backup / restore / wipe 入口
6. 同步更新 `supports/README.md`、`supports/docs/fly-io-环境变量.md` 等跨服务运维文档

---

## 部署(Fly.io)

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
| `FLY_API_TOKEN` | Fly.io 部署 token | 6 个项目共用同一个 |
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
| `/api/v1/*` 全部 | ✅ 必须 | 业务数据,无 key 一律 401 |
| `/internal/sync/*` 全部 | ✅ 必须 | admin 操作,优先使用独立 `ADMIN_API_KEYS`;旧服务如未拆分则使用业务 key 白名单 |

### 跨项目共享鉴权代码

`internal/middleware/auth.go` 在多个项目 **byte-level 一致** 复制粘贴（详见 R-01 总体设计 §4.1）。新增 API 服务时必须先复用现有实现,除非接口鉴权模型确实不同。

### 日志脱敏

任何涉及 API Key / GitHub PAT 的日志**必须**脱敏：

```
sk-star****G6AE         # 前 7 + 末 4 + 中间星号
ghp_xxx****abcd
```

**绝对禁止**：`log.Printf("auth ok, key=%s", key)`。

---

## 跨项目共享代码同步约定（2026-06-09 R-01 起）

依据 [`CLAUDE.md`](./CLAUDE.md)「不要跨项目 import」原则,以下文件在 N 个项目里 **byte-level 一致**（除 package 名 / module path 引用）。**任何一份更新必须同步另外 N 份**,PR 描述里勾「跨 N 个 API 同步 xxx.go」清单。

| 共享文件 | sharing | trending | weekly | wiki | recommend | discovery | 备注 |
|---|---|---|---|---|---|---|---|
| `internal/model/envelope.go` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | 6 份保持同一响应语义 |
| `internal/middleware/auth.go` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Bearer 鉴权；改一份时检查其他服务是否需要同步 |
| `internal/enricher/ratelimit.go` | — | ✅ | ✅ | — | — | — | GitHub enrich 服务使用 |
| `internal/tokenpool/tokenpool.go` | ✅ | ✅ | ✅ | — | — | ✅ | GitHub PAT 池轮换 |
| `internal/middleware/cors.go` | ⚠️ 按需 | ⚠️ 按需 | ⚠️ 按需 | ⚠️ 按需 | ⚠️ 按需 | ⚠️ 按需 | 若都需要 CORS 则保持一致 |

> 未来若需要,dong4j 可决定升级到「Go workspace mode + 共享 supports/pkg/*」,但本次 R-01 沿用现有约束。

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
| `CLAUDE.md` | Claude Code 硬性协作规则 |
| `AGENTS.md` | 本文档,综合介绍 |
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
| Starcat 全局规则 | `../CLAUDE.md` |
| 工程进度索引 | `../docs/功能实现总览.md` |
| 前端 R-01 设计 | `../docs/3-设计/详细设计/18-三场景共用架构.md` |

### 各项目详细文档

- [starcat-weekly-api/AGENTS.md](./starcat-weekly-api/AGENTS.md) — 周刊后端开发规范
- [starcat-sharing-api/README.md](./starcat-sharing-api/README.md) — 分享服务 API 文档
- [starcat-trending-api/README.md](./starcat-trending-api/README.md) — Trending 服务 API 文档
- [starcat-wiki-api/README.md](./starcat-wiki-api/README.md) — Wiki 服务 API 文档
- [starcat-recommend-api/README.md](./starcat-recommend-api/README.md) — 推荐服务 API 文档
- [starcat-discovery-api/README.md](./starcat-discovery-api/README.md) — 探索发现服务 API 文档

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
