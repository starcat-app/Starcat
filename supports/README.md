# Starcat 支撑项目（supports）

> 本目录收录 Starcat 主仓库依赖的**独立项目**。每个子目录（除明确标注外）都是独立的
> git 仓库、独立 GitHub 仓库、独立部署单元，**不**与主仓库共享版本号或 CI。
>
> 文件同步关系详见 [`SYNC.md`](./SYNC.md)。

---

## 📦 项目清单（共 16 个）

### Go API 服务（7 个）

| 子目录 | GitHub | 端口 | 角色 |
|--------|--------|:----:|------|
| [`starcat-sharing-api/`](./starcat-sharing-api/) | [`starcat-app/starcat-sharing-api`](https://github.com/starcat-app/starcat-sharing-api) | 5001 | AI 分享链接生成 + 公开分享页托管 |
| [`starcat-trending-api/`](./starcat-trending-api/) | [`starcat-app/starcat-trending-api`](https://github.com/starcat-app/starcat-trending-api) | 5002 | GitHub Trending 爬虫 → REST API |
| [`starcat-weekly-api/`](./starcat-weekly-api/) | [`starcat-app/starcat-weekly-api`](https://github.com/starcat-app/starcat-weekly-api) | 5003 | 周刊项目同步 + zread 趋势候选 |
| [`starcat-wiki-api/`](./starcat-wiki-api/) | [`starcat-app/starcat-wiki-api`](https://github.com/starcat-app/starcat-wiki-api) | 5004 | DeepWiki / Zread / CodeWiki 收录探测 |
| [`starcat-recommend-api/`](./starcat-recommend-api/) | [`starcat-app/starcat-recommend-api`](https://github.com/starcat-app/starcat-recommend-api) | 5005 | 相似仓库推荐 API |
| [`starcat-discovery-api/`](./starcat-discovery-api/) | [`starcat-app/starcat-discovery-api`](https://github.com/starcat-app/starcat-discovery-api) | 5006 | 探索发现、热门、新发布榜单 |
| [`starcat-license-api/`](./starcat-license-api/) | [`starcat-app/starcat-license-api`](https://github.com/starcat-app/starcat-license-api) 🔒 | — | Direct 分发授权 API |

### 其他支撑项目（9 个）

| 子目录 | GitHub | 说明 |
|--------|--------|------|
| [`starcat-pro/`](./starcat-pro/) | [`starcat-app/starcat-pro`](https://github.com/starcat-app/starcat-pro) | 公开支持、Issue 与发布说明 |
| [`starcat-localization/`](./starcat-localization/) | [`starcat-app/starcat-localization`](https://github.com/starcat-app/starcat-localization) | 本地化资源管理 |
| [`homebrew-starcat/`](./homebrew-starcat/) | [`starcat-app/homebrew-starcat`](https://github.com/starcat-app/homebrew-starcat) | Starcat App Homebrew Cask（`brew install --cask starcat`） |
| [`starcat-skill/`](./starcat-skill/) | [`starcat-app/starcat-skill`](https://github.com/starcat-app/starcat-skill) | 供 Codex / Claude 等 AI Agent 使用的 Starcat Skill |
| [`starcat-cli/`](./starcat-cli/) | [`starcat-app/starcat-cli`](https://github.com/starcat-app/starcat-cli) | 跨平台 Starcat CLI 与 MCP 运行时 |
| [`homebrew-starcat-cli/`](./homebrew-starcat-cli/) | [`starcat-app/homebrew-starcat-cli`](https://github.com/starcat-app/homebrew-starcat-cli) | Starcat CLI Homebrew Formula tap |
| [`ai-file-wall/`](./ai-file-wall/) | —（本地独立项目） | 多 AI 并行开发时的 Git 变更与文件冲突预警面板 |
| [`extensions/starcat-chrome-plugin/`](./extensions/starcat-chrome-plugin/) | [`starcat-app/starcat-chrome-plugin`](https://github.com/starcat-app/starcat-chrome-plugin) | Chrome 浏览器插件 |
| [`extensions/starcat-safari-plugin/`](./extensions/starcat-safari-plugin/) | [`starcat-app/starcat-safari-plugin`](https://github.com/starcat-app/starcat-safari-plugin) | Safari 浏览器插件 |

> 端口规范：5000 段是 macOS 系统服务保留段，自建后端从 5001 起顺序分配。

---

## 🧩 在 Starcat 中的角色

```
┌──────────────────────────────────────────────────────────────┐
│                    Starcat App (macOS)                        │
│                                                               │
│  ┌────────────┐  ┌────────────┐  ┌──────────┐  ┌──────────┐ │
│  │ GitHub     │  │  Trending  │  │  Share   │  │  Direct  │ │
│  │ Stars      │  │  视图/入口  │  │  入口    │  │  购买    │ │
│  │ (SQLite)   │  │            │  │          │  │  入口    │ │
│  └─────┬──────┘  └─────┬──────┘  └────┬─────┘  └────┬─────┘ │
│        │               │              │              │       │
│        │   GitHub REST │  GET /repo   │  POST /api   │  POST │
│        │   API (官方)  │  GET /user   │  /share      │  /v1/ │
│        │               │  GET /lang   │              │direct │
│        │               ↓              ↓              ↓       │
└────────┼───────────────┼──────────────┼──────────────┼───────┘
         │               │              │              │
         │          port 5002      port 5001           │
         │               ↓              ↓          port 5010
  ┌──────┴──────┐ ┌────────────┐ ┌────────────┐ ┌──────────────┐
  │ GitHub REST │ │ trending   │ │ sharing    │ │ license      │
  │ (官方)      │ │ -api       │ │ -api       │ │ -api 🔒      │
  └─────────────┘ └────────────┘ └────────────┘ └──────────────┘
```

### 核心 API 角色

**`starcat-trending-api`（5002）** — GitHub 官方 REST API 没有 Trending 接口，由本服务爬取网页并提供结构化数据。

| Method | Path | 说明 |
|--------|------|------|
| GET | `/repo?lang=…&since=daily/weekly/monthly` | Trending 仓库列表 |
| GET | `/user?lang=…&since=…&sponsorable=1` | Trending 开发者列表 |
| GET | `/lang` | 支持的语言字典 |

**`starcat-sharing-api`（5001）** — 分享页要被**未安装 Starcat** 的人访问，必须是独立 Web 服务。

| Method | Path | 说明 |
|--------|------|------|
| POST | `/api/share` | 接收 repo 数据 + AI 摘要，返回短链 |
| GET | `/s/{id}` | 公开分享页（服务端渲染） |

**`starcat-weekly-api`（5003）** — 同步 GitHub Weekly 周刊、Trending 榜单生成周报数据。

**`starcat-wiki-api`（5004）** — 探测仓库是否有 DeepWiki / Zread / CodeWiki 等第三方文档。

**`starcat-recommend-api`（5005）** — 基于用户收藏行为生成相似仓库推荐。

**`starcat-discovery-api`（5006）** — 探索发现首页：热门仓库、新发布、分类榜单。

**`starcat-license-api`（5010）🔒 私有** — Direct 分发授权：license activate / validate / deactivate，对接 Creem 支付。

---

## 🚀 快速开始

### 一键拉取所有项目

```bash
cd supports

# 首次 clone 全部 15 个独立仓库
./clone-all.sh

# 后续批量更新
./clone-all.sh --pull
```

> `starcat-license-api` 是**私有**仓库，需 `gh auth login` 或 SSH key。

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

---

## 📁 本目录文件归属

### 主仓库 git 管理（`git pull` 即可同步）

| 路径 | 说明 |
|------|------|
| `AGENTS.md` / `CLAUDE.md` | AI 协作规范 |
| `SYNC.md` | 文件同步说明 |
| `README.md` | 本文档 |
| `Makefile` | 运维命令入口 |
| `start-all.sh` | 一键启动脚本 |
| `clone-all.sh` | 一键拉取脚本 |
| `.claude/` | supports/ 专用 IDE 权限 |
| `backups/` | Fly 备份目录结构 |
| `docs/` | 设计文档、方案、指南 |
| `extensions/{AGENTS,CLAUDE}.md` | 插件目录 AI 规范 |
| `scripts/` | 运维脚本 |

### 独立 git 仓库（各自管理）

- 上表除 `ai-file-wall` 外的 15 个独立仓库目录

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
- **本地开发**：各项目 `.env`（gitignore），跨机器用 `scripts/sync-untracked.sh` 同步
- **绝不要**把真实 API Key / Token 提交到 git

---

## 📚 相关文档

- [`SYNC.md`](./SYNC.md) — 文件同步说明（git 管理 vs 跨机器同步）
- [主仓库 CLAUDE.md](../CLAUDE.md)
- [supports/CLAUDE.md](./CLAUDE.md)
- [supports/AGENTS.md](./AGENTS.md)
