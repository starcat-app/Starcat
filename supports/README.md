# Starcat 支撑项目（supports）

> 本目录收录 Starcat 主仓库依赖的**独立项目**。每个子目录（除明确标注外）都是独立的
> git 仓库，并拥有自己的版本和 CI 边界。可部署服务是独立部署单元，
> `starcat-api-kit` 是公开 Go 共享库，`starcat-api` 是私有聚合部署单元。
>
> 文件同步关系详见 [`SYNC.md`](./SYNC.md)。

---

## 📦 项目清单（共 26 个）

### Go 后端项目（10 个）

| 子目录 | GitHub | 端口 | 角色 |
|--------|--------|:----:|------|
| [`starcat-sharing-api/`](./starcat-sharing-api/) | [`starcat-app/starcat-sharing-api`](https://github.com/starcat-app/starcat-sharing-api) | 5001 | AI 分享链接生成 + 公开分享页托管 |
| [`starcat-trending-api/`](./starcat-trending-api/) | [`starcat-app/starcat-trending-api`](https://github.com/starcat-app/starcat-trending-api) | 5002 | GitHub Trending 爬虫 → REST API |
| [`starcat-weekly-api/`](./starcat-weekly-api/) | [`starcat-app/starcat-weekly-api`](https://github.com/starcat-app/starcat-weekly-api) | 5003 | 周刊、Show HN、HelloGitHub 等多来源项目发现流水线 |
| [`starcat-wiki-api/`](./starcat-wiki-api/) | [`starcat-app/starcat-wiki-api`](https://github.com/starcat-app/starcat-wiki-api) | 5004 | DeepWiki / Zread / CodeWiki 收录探测 |
| [`starcat-recommend-api/`](./starcat-recommend-api/) | [`starcat-app/starcat-recommend-api`](https://github.com/starcat-app/starcat-recommend-api) | 5005 | 相似仓库推荐 API |
| [`starcat-discovery-api/`](./starcat-discovery-api/) | [`starcat-app/starcat-discovery-api`](https://github.com/starcat-app/starcat-discovery-api) | 5006 | 探索发现、热门、新发布榜单 |
| [`starcat-license-api/`](./starcat-license-api/) | [`starcat-app/starcat-license-api`](https://github.com/starcat-app/starcat-license-api) 🔒 | 5010 | Direct 分发授权 API |
| [`starcat-collection-api/`](./starcat-collection-api/) | [`starcat-app/starcat-collection-api`](https://github.com/starcat-app/starcat-collection-api) 🔒 | 5011 | 静默接收匿名公开 Star 快照，向 Trainer 提供内部导出 |
| [`starcat-api-kit/`](./starcat-api-kit/) | [`starcat-app/starcat-api-kit`](https://github.com/starcat-app/starcat-api-kit) | — | 六个业务 API 共用的 auth / envelope / GitHub / env 等基础包 |
| [`starcat-api/`](./starcat-api/) | [`starcat-app/starcat-api`](https://github.com/starcat-app/starcat-api) 🔒 | 8080 | 私有聚合部署单元；以 `X-SC-Svc` 分流六个业务 API，不含 license |

### 其他支撑项目（17 个）

| 子目录 | GitHub | 说明 |
|--------|--------|------|
| [`starcat-pro/`](./starcat-pro/) | [`starcat-app/starcat-pro`](https://github.com/starcat-app/starcat-pro) | 公开支持、Issue 与发布说明 |
| [`.github/`](./.github/) | [`starcat-app/.github`](https://github.com/starcat-app/.github) | 组织主页与共享社区健康文件 |
| [`starcat-docs/`](./starcat-docs/) | [`starcat-app/starcat-docs`](https://github.com/starcat-app/starcat-docs) | Starcat 官方用户文档 |
| [`starcat-site/`](./starcat-site/) | [`starcat-app/starcat-site`](https://github.com/starcat-app/starcat-site) | Direct、App Store 官网、博客与公开法律页面源码 |
| [`starcat-admin-console/`](./starcat-admin-console/) | [`starcat-app/starcat-admin-console`](https://github.com/starcat-app/starcat-admin-console) | 本地优先的服务统计、数据操作、精选发布与 Awesome 来源管理控制台 |
| [`starcat-localization/`](./starcat-localization/) | [`starcat-app/starcat-localization`](https://github.com/starcat-app/starcat-localization) | 本地化资源管理 |
| [`homebrew-starcat/`](./homebrew-starcat/) | [`starcat-app/homebrew-starcat`](https://github.com/starcat-app/homebrew-starcat) | Starcat App Homebrew Cask（`brew install --cask starcat`） |
| [`starcat-skill/`](./starcat-skill/) | [`starcat-app/starcat-skill`](https://github.com/starcat-app/starcat-skill) | 供 Codex / Claude 等 AI Agent 使用的 Starcat Skill |
| [`starcat-cli/`](./starcat-cli/) | [`starcat-app/starcat-cli`](https://github.com/starcat-app/starcat-cli) | 跨平台 Starcat CLI 与 MCP 运行时 |
| [`starcat-recsys-trainer/`](./starcat-recsys-trainer/) | [`starcat-app/starcat-recsys-trainer`](https://github.com/starcat-app/starcat-recsys-trainer) 🔒 | 推荐数据采集、标准化、离线训练、评估和 ServingBundle 发布 |
| [`starcat-alfred-workflow/`](./starcat-alfred-workflow/) | [`starcat-app/starcat-alfred-workflow`](https://github.com/starcat-app/starcat-alfred-workflow) | 在 Alfred 中搜索 Starcat 本地仓库与 GitHub |
| [`starcat-utools-plugin/`](./starcat-utools-plugin/) | [`starcat-app/starcat-utools-plugin`](https://github.com/starcat-app/starcat-utools-plugin) | 在 uTools 中搜索 Starcat 本地仓库与 GitHub |
| [`starcat-raycast-extension/`](./starcat-raycast-extension/) | [`starcat-app/starcat-raycast-extension`](https://github.com/starcat-app/starcat-raycast-extension) | 在 Raycast 中搜索 Starcat 本地仓库与 GitHub |
| [`homebrew-starcat-cli/`](./homebrew-starcat-cli/) | [`starcat-app/homebrew-starcat-cli`](https://github.com/starcat-app/homebrew-starcat-cli) | Starcat CLI Homebrew Formula tap |
| [`ai-file-wall/`](./ai-file-wall/) | —（本地独立项目） | 多 AI 并行开发时的 Git 变更与文件冲突预警面板 |
| [`extensions/starcat-chrome-plugin/`](./extensions/starcat-chrome-plugin/) | [`starcat-app/starcat-chrome-plugin`](https://github.com/starcat-app/starcat-chrome-plugin) | Chrome 浏览器插件 |
| [`extensions/starcat-safari-plugin/`](./extensions/starcat-safari-plugin/) | [`starcat-app/starcat-safari-plugin`](https://github.com/starcat-app/starcat-safari-plugin) | Safari 浏览器插件 |

> 端口规范：5000 段是 macOS 系统服务保留段，自建后端从 5001 起顺序分配。

---

## 🧩 在 Starcat 中的角色

```
Starcat App
  ├─ GitHub 官方 API
  ├─ 六个业务 API
  │    ├─ 当前业务生产（2026-08-08）：六个独立 starcat-*-api Fly App
  │    └─ 已验证后停机保留：starcat-api.fly.dev + X-SC-Svc → 六个 server 包
  ├─ starcat-license-api（支付 / 授权边界，始终独立）
  └─ starcat-collection-api（公开 Star 数据贡献边界，始终独立）
```

客户端代码已经默认指向聚合 URL。Fly App、Volume、Secrets、首轮五库种子迁移已完成，并曾解除维护模式通过六服务 ping 与只读业务验证；验证后已重新开启维护模式、关闭请求自动唤醒并停止聚合 Machine。六个旧 App 未停用且仍持续写入；1.4.0 正式切流前必须以维护模式启动聚合服务，完成最终同步 / 写入冻结和全链路验收。

### 核心 API 角色

**`starcat-trending-api`（5002）** — GitHub 官方 REST API 没有 Trending 接口，由本服务爬取网页并提供结构化数据。

| Method | Path | 说明 |
|--------|------|------|
| GET | `/api/v1/repos?lang=…&since=daily/weekly/monthly` | Trending 仓库列表 |
| GET | `/api/v1/users?lang=…&since=…&sponsorable=1` | Trending 开发者列表 |
| GET | `/api/v1/languages` | 支持的语言字典 |

**`starcat-sharing-api`（5001）** — 分享页要被**未安装 Starcat** 的人访问，因此公开 Web 路由必须持续可访问；目标聚合架构由 `starcat-api` 挂载其 `server` 包，并由 `starcat.ink` 代理注入 `X-SC-Svc: sharing`。

| Method | Path | 说明 |
|--------|------|------|
| POST | `/api/v1/share` | 接收 repo 数据 + AI 摘要，返回短链 |
| GET | `/s/{id}` | 公开分享页（服务端渲染） |
| GET | `/r/{owner}/{repo}` | 公开仓库预览页 |
| GET | `/og/repo/{owner}/{repo}` | 公开仓库 Open Graph 图片 |

**`starcat-weekly-api`（5003）** — 聚合阮一峰周刊、zread、Show HN、HelloGitHub 与人工情报，生成统一的项目发现数据。

**`starcat-wiki-api`（5004）** — 探测仓库是否有 DeepWiki / Zread / CodeWiki 等第三方文档。

**`starcat-recommend-api`（5005）** — 基于用户收藏行为生成相似仓库推荐。

**`starcat-discovery-api`（5006）** — 探索发现首页：热门仓库、新发布、分类榜单。

**`starcat-license-api`（5010）🔒 私有** — Direct 分发授权：license activate / validate / deactivate，对接 Creem 支付。

**`starcat-collection-api`（5011）🔒 私有** — 只接收经用户同意的匿名公开 Star 完整快照；不接入 Gateway，不包含 History、状态或删除逻辑。

---

## 🚀 快速开始

### 一键拉取所有项目

```bash
cd supports

# 首次 clone 全部 26 个远端目标
./clone-all.sh

# 后续批量更新
./clone-all.sh --pull
```

> `starcat-license-api`、`starcat-collection-api`、`starcat-api` 与 `starcat-recsys-trainer` 是**私有**仓库，需使用具备 `starcat-app` 组织权限的 `gh auth login` 或 SSH key；`starcat-api-kit` 为公开仓库。

### 一次性启动全部 API

```bash
./start-all.sh
```

### 单独启动

```bash
cd supports/starcat-trending-api
go run ./cmd/server
# → http://localhost:5002
```

### 新增独立支撑项目

使用根目录 Skill：

```text
.claude/skills/starcat-support-project-create
```

创建流程会补齐开源治理文件和 README，并强制同步：

- `clone-all.sh`
- `scripts/sync-starcat-readme-promo.py`（私有项目在公开前不登记公开推广区）
- 本文档与 `SYNC.md`
- 按项目类型需要的 CI、Release/Audit 和运维入口

新项目始终保持独立 Git 仓库，不能加入 Starcat 主仓库。创建组织仓库、推送和设置
secrets 需要单独确认。

---

## 📁 本目录文件归属

### 主仓库 git 管理（`git pull` 即可同步）

| 路径 | 说明 |
|------|------|
| `AGENTS.md` | supports/ AI 协作唯一维护源 |
| `.claude/CLAUDE.md` | Claude Code 配置入口（固定引用 `AGENTS.md`，勿写规范正文） |
| `SYNC.md` | 文件同步说明 |
| `README.md` | 本文档 |
| `Makefile` | 运维命令入口 |
| `start-all.sh` | 一键启动脚本 |
| `clone-all.sh` | 一键拉取脚本 |
| `.claude/` | supports/ 专用 IDE 权限 |
| `backups/` | Fly 备份目录结构 |
| `docs/` | 设计文档、方案、指南 |
| `extensions/AGENTS.md` | 插件目录 AI 协作规范 |
| `extensions/.claude/CLAUDE.md` | 插件目录 Claude Code 配置入口 |
| `scripts/` | 运维脚本 |

### 独立 git 仓库（各自管理）

- 上表除 `ai-file-wall` 外的 25 个独立仓库目录

### 跨机器同步（`sync-untracked.sh`）

- 各 API 项目的 `.env` 文件（含本地密钥，gitignore 不管）

> 详见 [`SYNC.md`](./SYNC.md)

---

## 🌐 生产部署

| 平台 | 文档 |
|------|------|
| Fly.io | [`docs/fly-io-环境变量.md`](./docs/fly-io-环境变量.md) |
| 运维命令 | `make help`（在 supports/ 下执行） |

---

## 🔐 安全

- **Fly 生产**：`API_KEYS`、`GITHUB_TOKENS` 通过 `fly secrets set` 注入
- **聚合目标**：`starcat-api` 使用带服务前缀的 secrets 和 `/data` 分库；当前六个独立 App 在完成迁库验收前继续保留
- **本地开发**：各项目 `.env`（gitignore），跨机器用 `scripts/sync-untracked.sh` 同步
- **绝不要**把真实 API Key / Token 提交到 git

---

## 📚 相关文档

- [`SYNC.md`](./SYNC.md) — 文件同步说明（git 管理 vs 跨机器同步）
- [本地编译教程](../docs/7-工具与脚本/本地编译教程.md) — 从源码编 App、本地 API 和 CLI
- [主仓库 AGENTS.md](../AGENTS.md)
- [supports/AGENTS.md](./AGENTS.md)
