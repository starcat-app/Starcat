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
| `AGENTS.md` | supports/ 目录的 AI 协作规范 |
| `CLAUDE.md` | supports/ 目录的 Claude Code 规则 |
| `Makefile` | 运维命令入口（fly 部署、secrets 同步等） |
| `README.md` | 支撑项目总览 |
| `SYNC.md` | 本文档 |
| `start-all.sh` | 本地一键启动全部 API |
| `clone-all.sh` | 一键 clone/pull 全部支撑项目 |
| `.claude/` | supports/ 专用的 Claude Code 权限配置 |
| `backups/` | Fly 数据备份目录结构 |
| `docs/` | 设计文档、改造方案、指南 |
| `extensions/AGENTS.md` | 浏览器插件目录的 AI 协作规范 |
| `extensions/CLAUDE.md` | 浏览器插件目录的 Claude Code 规则 |
| `scripts/` | 运维脚本（fly-backup、fly-restore、fly-secrets 等） |

> `.gitignore` 规则：`supports/*` 默认忽略全部，再用 `!` 逐目录/文件放行。
> 详见主仓库根目录 `.gitignore` 第 222-239 行。

---

## 独立 git 仓库（13 个）

以下目录各自是**独立的 git 仓库**，有自己的 GitHub remote、CI/CD 和版本号：

| # | 目录 | GitHub |
|---|------|--------|
| 1 | `starcat-sharing-api/` | `dong4j/starcat-sharing-api` |
| 2 | `starcat-trending-api/` | `dong4j/starcat-trending-api` |
| 3 | `starcat-weekly-api/` | `dong4j/starcat-weekly-api` |
| 4 | `starcat-wiki-api/` | `dong4j/starcat-wiki-api` |
| 5 | `starcat-recommend-api/` | `dong4j/starcat-recommend-api` |
| 6 | `starcat-discovery-api/` | `dong4j/starcat-discovery-api` |
| 7 | `starcat-pro/` | `dong4j/starcat-pro` |
| 8 | `starcat-license-api/` | `dong4j/starcat-license-api` 🔒 私有 |
| 9 | `starcat-localization/` | `starcat-app/starcat-localization` |
| 10 | `homebrew-starcat/` | `dong4j/homebrew-starcat` |
| 11 | `vscode-makefile-explorer/` | `dong4j/vscode-makefile-explorer` |
| 12 | `extensions/starcat-chrome-plugin/` | `dong4j/starcat-chrome-plugin` |
| 13 | `extensions/starcat-safari-plugin/` | `dong4j/starcat-safari-plugin` |

### 一键拉取所有独立仓库

```bash
cd supports

# 首次 clone 全部 13 个项目
./clone-all.sh

# 后续更新全部
./clone-all.sh --pull
```

> `starcat-license-api` 是**私有**仓库，需要 `gh auth login` 或配置 SSH key。

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
git clone https://github.com/dong4j/Starcat.git
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
| 2026-07-06 | `supports/` 运维文件转主仓库 git 管理 | 减少 sync-untracked 清单维护负担，git 管理更可靠 |
| 2026-07-06 | 独立仓库从 6 个扩展到 13 个 | 新增 starcat-pro、starcat-license-api、starcat-localization、homebrew、vscode 插件、浏览器插件 |
| 2026-07-06 | `starcat-license-api` 初始化为私有仓库 | 包含 Direct 分发授权逻辑，不公开 |
| 2026-07-06 | 新增 `clone-all.sh` | 一键拉取 13 个支撑项目 |
| 2026-06-08 | 初始结构 | 6 个 Go API，端口 5001-5006 |
