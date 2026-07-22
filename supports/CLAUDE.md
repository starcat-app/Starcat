# supports/CLAUDE.md — Claude Code 在 supports/ 配套项目工作区下的协作规则

> 这是 Starcat 配套项目工作区（supports/）的 Claude Code 协作规则。
> 与根 `Starcat/CLAUDE.md` 配合使用,本文档**只覆盖 supports/ 特有的硬性约束**。

---

## 必读清单(开工前)

1. **根 Starcat/CLAUDE.md** — 全局规则(本目录所有 AI 协作者必须遵守)
2. **supports/AGENTS.md** — supports/ 整体结构、独立仓库边界、6 个公共 API 与私有 License API 对照表
3. **被修改项目的 `AGENTS.md`** — 项目特定的开发规范、命令、commit 规范；若项目没有单独 `AGENTS.md`，以本文件和项目 README 为准

---

## 关键约束(强制)

`supports/` 下的 `.github`、官网、文档、API、CLI、插件、Homebrew 和本地化目录均可能是独立 Git 仓库。修改前先在目标目录运行 `git status -sb` 并核对 remote；不要把多个独立仓库的改动混成主仓库提交。官网源码统一位于 `starcat-site/`，根目录 `pages/` 仅为待删除的迁移验证副本。

### 1. Go 版本一致性(2026-06-08 起)

**6 个 API 项目必须保持 Go directive 一致**(2026-06-08 已统一为 `go 1.25.0`):

| 项目 | go.mod | workflows/go.yml |
|------|--------|-----------------|
| starcat-sharing-api | `go 1.25.0` | `go-version: [1.25]` |
| starcat-trending-api | `go 1.25.0` | `go-version: [1.25]` |
| starcat-weekly-api | `go 1.25.0` | `go-version: [1.25]` |
| starcat-wiki-api | `go 1.25.0` | `go-version: [1.25]` |
| starcat-recommend-api | `go 1.25.0` | `go-version: [1.25]` |
| starcat-discovery-api | `go 1.25.0` | `go-version: [1.25]` |

**禁止行为**:
- ❌ 只升级某一个项目的 Go 版本(必须 6 个 API 项目同步)
- ❌ 升级 Go 后忘了同步 `workflows/go.yml` 的矩阵版本
- ❌ 升级 Go 后没跑 `go build ./... && go vet ./...` 验证

### 2. Module path 规范

各 API 项目的 `module` 指令必须使用完整路径(2026-06-08 已统一):

```
github.com/starcat-app/starcat-sharing-api
github.com/starcat-app/starcat-trending-api
github.com/starcat-app/starcat-weekly-api
github.com/starcat-app/starcat-wiki-api
github.com/starcat-app/starcat-recommend-api
github.com/starcat-app/starcat-discovery-api
```

**项目内 import 必须用绝对路径**(用 module path 前缀),不允许相对路径:
```go
// ✅ 正确
import "github.com/starcat-app/starcat-weekly-api/internal/handler"

// ❌ 错误:Go 1.16+ 不支持
import "./internal/handler"
```

### 3. 升级 Go 依赖的标准流程

```bash
cd supports/starcat-xxx-api
go get -u ./...        # 升级所有依赖
go mod tidy            # 清理 go.sum
go build ./...         # 必须能编译
go vet ./...           # 必须 vet 干净
```

**升级后必须**:
- 在该项目的 `CHANGELOG.md` 追加依赖升级记录
- 如果升级导致 breaking change,更新该项目的 `AGENTS.md` 和 `README.md`

---

## 必做项

✅ 修改任何 Go 代码后必须跑 `go build ./... && go vet ./...`
✅ 新增 Go 文件后必须 `git add` 并跑 build 验证
✅ 改 `go.mod` 必须跑 `go mod tidy` 同步 `go.sum`
✅ 新增 / 删除 API 服务后必须同步 `supports/start-all.sh`、`supports/Makefile`、`supports/scripts/` 运维脚本和跨服务文档
✅ 有 SQLite / Fly volume 的新增服务必须接入 backup / restore / wipe 脚本；无持久化存储的服务必须在文档中说明排除原因
✅ PR 必须填写 `.github/PULL_REQUEST_TEMPLATE.md`
✅ Bug 报告必须用 `.github/ISSUE_TEMPLATE/bug_report.yml`

---

## 必不做项

❌ **不要 commit 编译产物**(`/server`、`/bin/`、`*.exe` 都被 .gitignore 忽略)
❌ **不要把 `data.json`、`*.db`、`.weekly-repo/` 提交进 git**(数据文件)
❌ **不要改 `fly.toml` 的 `app` 字段** — 那是 Fly.io 平台的应用名,改了会创建新应用
❌ **不要在 main.go 里硬编码端口/路径** — 用环境变量(`PORT`、`BASE_URL`、`STORE_FILE`)
❌ **不要把 secrets 写进代码或 .env** — 用 `fly secrets set` 或 GitHub Secrets
❌ **不要跨项目 import**(sharing 不能 import trending 的代码)

---

## Fly.io 部署

每个项目都有独立的 Fly.io 应用:

| 项目 | Fly app | 本地端口 | 存储 |
|------|---------|----------|------|
| `starcat-sharing-api` | `starcat-sharing-api` | 5001 | SQLite / Fly volume |
| `starcat-trending-api` | `starcat-trending-api` | 5002 | SQLite / Fly volume |
| `starcat-weekly-api` | `starcat-weekly-api` | 5003 | SQLite / Fly volume + git repo |
| `starcat-wiki-api` | `starcat-wiki-api` | 5004 | SQLite / Fly volume |
| `starcat-recommend-api` | `starcat-recommend-api` | 5005 | 无 Fly volume，仅进程缓存 |
| `starcat-discovery-api` | `starcat-discovery-api` | 5006 | SQLite / Fly volume |

```bash
cd supports/starcat-xxx-api
fly deploy                              # 部署
fly secrets set GITHUB_TOKEN=ghp_xxx    # 设置 secret
fly logs                                # 看日志
fly status                              # 看状态
```

**部署触发**:push 到 main → `.github/workflows/fly-deploy.yml` 自动部署
**必要 Secrets**(在 GitHub repo Settings → Secrets):
- `FLY_API_TOKEN` — 所有 API 项目共用同一个 token(Fly.io 个人 access token)

---

## 详细文档

| 主题 | 文档 |
|------|------|
| 目录整体结构、6 个 API 项目对照 | [`AGENTS.md`](./AGENTS.md) |
| 本地一次性启动所有 API | [`start-all.sh`](./start-all.sh) |
| Fly.io 脚本与环境变量 | [`docs/fly-io-环境变量.md`](./docs/fly-io-环境变量.md) |
| 全局规则、i18n、UI 规范、Keychain | 根 `../CLAUDE.md` |
| 单项目开发规范、commit 格式 | 各项目自己的 `AGENTS.md` |
| CI/CD 配置 | 各项目 `.github/workflows/*.yml` |

---

*最后更新: 2026-06-30(补齐 recommend / discovery 服务清单与新增 API 脚本同步规范)*
