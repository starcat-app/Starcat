# 文件同步说明

> 本文档解释 `supports/` 目录下哪些文件由主仓库 git 管理、哪些是独立 git 仓库、
> 以及两台机器（MBP / Studio）之间如何同步 git 不管的文件。

---

## 核心原则

```
git 管理的 → git push/pull 同步
git 不管的 → sync-untracked.sh 同步（按 sync-manifest.list 清单）
独立仓库   → 各自的 git remote + clone-all.sh 一键拉取
```

---

## 主仓库 git 管理的文件

以下 `supports/` 下的文件和目录由 **Starcat 主仓库 git** 直接管理，
在任意机器上 `git pull` 即可获取：

| 路径 | 说明 |
|------|------|
| `AGENTS.md` | supports/ 目录的 AI 协作唯一维护源 |
| `.claude/CLAUDE.md` | Claude Code 配置入口（固定引用 `AGENTS.md`，勿写规范正文） |
| `Makefile` | 运维命令入口（fly 部署、secrets 同步等） |
| `README.md` | 支撑项目总览 |
| `SYNC.md` | 本文档 |
| `start-all.sh` | 本地一键启动全部 API |
| `clone-all.sh` | 一键 clone/pull 全部支撑项目 |
| `.claude/` | supports/ 专用的 Claude Code 权限配置 |
| `backups/` | Fly 数据备份目录结构 |
| `docs/` | 设计文档、改造方案、指南 |
| `extensions/AGENTS.md` | 浏览器插件目录的 AI 协作规范 |
| `extensions/.claude/CLAUDE.md` | 浏览器插件目录 Claude Code 配置入口 |
| `scripts/` | 运维脚本（fly-backup、fly-restore、fly-secrets 等） |

> `.gitignore` 规则：`supports/*` 默认忽略全部，再用 `!` 逐目录/文件放行。
> 详见主仓库根目录 `.gitignore` 第 222-239 行。

---

## 独立仓库目录（25 个）

以下目录各自是**独立的 git 仓库**，有自己的 GitHub remote、CI/CD 和版本号：

| # | 目录 | GitHub |
|---|------|--------|
| 1 | `starcat-sharing-api/` | `starcat-app/starcat-sharing-api` |
| 2 | `starcat-trending-api/` | `starcat-app/starcat-trending-api` |
| 3 | `starcat-weekly-api/` | `starcat-app/starcat-weekly-api` |
| 4 | `starcat-wiki-api/` | `starcat-app/starcat-wiki-api` |
| 5 | `starcat-recommend-api/` | `starcat-app/starcat-recommend-api` |
| 6 | `starcat-discovery-api/` | `starcat-app/starcat-discovery-api` |
| 7 | `starcat-api-kit/` | `starcat-app/starcat-api-kit`（公开） |
| 8 | `starcat-api/` | `starcat-app/starcat-api` 🔒 私有 |
| 9 | `starcat-pro/` | `starcat-app/starcat-pro` |
| 10 | `.github/` | `starcat-app/.github` |
| 11 | `starcat-docs/` | `starcat-app/starcat-docs` |
| 12 | `starcat-site/` | `starcat-app/starcat-site` |
| 13 | `starcat-license-api/` | `starcat-app/starcat-license-api` 🔒 私有 |
| 14 | `starcat-localization/` | `starcat-app/starcat-localization` |
| 15 | `homebrew-starcat/` | `starcat-app/homebrew-starcat` |
| 16 | `starcat-skill/` | `starcat-app/starcat-skill` |
| 17 | `starcat-cli/` | `starcat-app/starcat-cli` |
| 18 | `starcat-alfred-workflow/` | `starcat-app/starcat-alfred-workflow` |
| 19 | `starcat-utools-plugin/` | `starcat-app/starcat-utools-plugin` |
| 20 | `starcat-raycast-extension/` | `starcat-app/starcat-raycast-extension` |
| 21 | `homebrew-starcat-cli/` | `starcat-app/homebrew-starcat-cli` |
| 22 | `extensions/starcat-chrome-plugin/` | `starcat-app/starcat-chrome-plugin` |
| 23 | `extensions/starcat-safari-plugin/` | `starcat-app/starcat-safari-plugin` |
| 24 | `starcat-recsys-trainer/` | `starcat-app/starcat-recsys-trainer` 🔒 私有 |
| 25 | `starcat-collection-api/` | `starcat-app/starcat-collection-api` 🔒 私有 |
| 26 | `starcat-admin-console/` | `starcat-app/starcat-admin-console` |

### 一键拉取所有独立仓库

```bash
cd supports

# 首次 clone 全部 26 个远端目标
./clone-all.sh

# 后续更新全部
./clone-all.sh --pull
```

> `starcat-license-api`、`starcat-collection-api`、`starcat-api` 与 `starcat-recsys-trainer` 是**私有**仓库，需要使用具备 `starcat-app` 组织权限的 `gh auth login` 或 SSH key；`starcat-api-kit` 为公开仓库。

### 新增独立仓库登记

新增项目使用根目录 `.claude/skills/starcat-support-project-create`，并把以下更新视为
同一个创建事务：

1. 在 `clone-all.sh` 的帮助文本和 `PROJECTS` 数组登记仓库；
2. 在 `scripts/sync-starcat-readme-promo.py` 登记双语摘要并生成两份 README
   的 Starcat 推广区块；
3. 更新本文档的独立仓库数量、清单和决策记录；
4. 更新 `README.md` 的项目总数、分类表和 GitHub URL；
5. 验证根 `.gitignore` 仍忽略新项目工作树，禁止用 `git add -f` 加入主仓库。

API 或新的项目类型还要同步 `AGENTS.md` 和对应运维/发布文档。

---

## 跨机器同步（git 不管的文件）

某些文件包含敏感信息（API Key、Token、本地密钥），**不能进 git**，
但 MBP 和 Studio 两台机器都需要。这些文件通过 `scripts/sync-untracked.sh` 同步。

### 同步清单（`scripts/sync-manifest.list`）

```
Configs/Secrets.xcconfig          # 客户端 API Key
notes.md                          # 笔记
.claude/settings.local.json       # 根目录 IDE 权限（被全局 gitignore 忽略）
sparkle-private-key               # Sparkle 签名私钥
supports/starcat-discovery-api/.env
supports/starcat-collection-api/.env
supports/starcat-license-api/.env
supports/starcat-recommend-api/.env
supports/starcat-sharing-api/.env
supports/starcat-trending-api/.env
supports/starcat-weekly-api/.env
supports/starcat-wiki-api/.env
```

### 用法

```bash
# 从项目根目录执行

# dry-run 预览
./scripts/sync-untracked.sh --to studio

# 真同步
./scripts/sync-untracked.sh --to studio --apply

# 只列清单
./scripts/sync-untracked.sh --to studio --list-only
```

> 注意：`supports/` 下曾经有大量条目在同步清单中（`.claude`、`docs/`、`scripts/` 等），
> 2026-07-06 已全部转由主仓库 git 管理，从 manifest 移除。现在 manifest 只保留
> `.env` 和根目录的几个私密文件。

---

## 新机器上手流程

```bash
# 1. clone 主仓库
git clone https://github.com/starcat-app/Starcat.git
cd Starcat

# 2. 拉取所有支撑项目
cd supports && ./clone-all.sh && cd ..

# 3. 从另一台机器同步私密文件
./scripts/sync-untracked.sh --to studio --apply
# （或反过来：在 studio 上 --to mbp）

# 4. 恢复 API secrets
make sync-fly-secrets
```

---

## 决策记录

| 日期 | 决策 | 原因 |
|------|------|------|
| 2026-08-24 | GitHub 独立仓库从 25 个扩展到 26 个 | 新增 `starcat-admin-console`，独立承担本地服务运营、精选发布与 Awesome 来源管理 |
| 2026-08-23 | GitHub 独立仓库从 24 个扩展到 25 个 | 新增私有 `starcat-collection-api`，独立承担经同意的公开 Star 快照收集与训练导出 |
| 2026-08-23 | GitHub 独立仓库从 23 个扩展到 24 个 | 新增私有 `starcat-recsys-trainer`，独立承担推荐数据与离线训练管道 |
| 2026-07-30 | GitHub 独立仓库从 20 个扩展到 21 个 | 新增 `starcat-raycast-extension`，独立维护 Raycast 搜索适配、测试与开源治理 |
| 2026-07-29 | GitHub 独立仓库从 19 个扩展到 20 个 | 新增 `starcat-utools-plugin`，独立维护 uTools 搜索适配、测试与开源治理 |
| 2026-07-29 | GitHub 独立仓库从 18 个扩展到 19 个 | 新增 `starcat-alfred-workflow`，独立维护 Alfred 构建、发布与开源治理 |
| 2026-07-22 | GitHub 独立仓库从 15 个扩展到 18 个 | 补齐组织配置、官方文档与独立官网仓库 |
| 2026-07-20 | 独立仓库从 12 个扩展到 15 个 | 新增 `starcat-skill`、`starcat-cli`、`homebrew-starcat-cli` |
| 2026-07-06 | `supports/` 运维文件转主仓库 git 管理 | 减少 sync-untracked 清单维护负担，git 管理更可靠 |
| 2026-07-06 | 独立仓库从 6 个扩展到 12 个 | 新增 starcat-pro、starcat-license-api、starcat-localization、homebrew、浏览器插件 |
| 2026-07-06 | `starcat-license-api` 初始化为私有仓库 | 包含 Direct 分发授权逻辑，不公开 |
| 2026-07-06 | 新增 `clone-all.sh` | 一键拉取当时的 12 个支撑项目 |
| 2026-06-08 | 初始结构 | 6 个 Go API，端口 5001-5006 |
