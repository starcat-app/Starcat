# Starcat 支撑服务（supports）

> 本目录收录 Starcat 主仓库依赖的**独立后端服务**。每个子目录都是单独的 git 仓库、独立 GitHub 仓库、独立部署单元，**不**与主仓库 (`Starcat/`) 共享版本号或 CI。
>
> 共同约定：**默认端口互不冲突**（5001 / 5002），本地可同时启动。

---

## 📦 当前收录的支撑服务

| 子目录 | GitHub 仓库 | 默认端口 | 角色 | 状态 |
|---|---|:---:|---|---|
| [`starcat-sharing-api/`](./starcat-sharing-api/) | [`dong4j/starcat-sharing-api`](https://github.com/dong4j/starcat-sharing-api) | **5001** | AI 分享链接生成 + 公开分享页托管 | P0 |
| [`starcat-trending-api/`](./starcat-trending-api/) | [`dong4j/starcat-trending-api`](https://github.com/dong4j/starcat-trending-api) | **5002** | GitHub Trending 页面爬虫 → REST API | P0 |

> 端口规范：5000 段是 macOS「ControlCenter」/ AirPlay 等系统服务保留段，5001/5002 留给人用，且两者相邻便于记忆。

---

## 🧩 在 Starcat 中的角色

```
┌─────────────────────────────────────────────────────────────┐
│                  Starcat App (macOS)                        │
│                                                             │
│  ┌──────────────┐    ┌────────────────┐    ┌────────────┐  │
│  │ GitHub Stars │    │    Trending    │    │   Share    │  │
│  │ (本地 SQLite)│    │  视图 / 入口    │    │  入口      │  │
│  └──────┬───────┘    └────────┬───────┘    └─────┬──────┘  │
│         │                     │                  │         │
│         │                     │  GET /repo?lang  │  POST   │
│         │                     │  GET /user       │  /api/  │
│         │                     │  GET /lang       │  share  │
│         │                     ↓                  ↓         │
└─────────┼─────────────────────┼──────────────────┼─────────┘
          │                     │                  │
          │                     │ port 5002        │ port 5001
          │                     ↓                  ↓
   ┌──────┴────────┐    ┌──────────────────┐   ┌──────────────────┐
   │ GitHub REST   │    │ starcat-trending │   │ starcat-sharing  │
   │ (官方)        │    │ -api (自托管)    │   │ -api (自托管)    │
   └───────────────┘    └──────────────────┘   └──────────────────┘
```

### 1. `starcat-trending-api`（5002）

**解决的痛点**：GitHub 官方 REST API 没有 Trending 接口，Trending 是 GitHub 网页功能。

**提供的接口**（与 Python 原版 100% 兼容，详见各子目录的 README）：

| Method | Path | 说明 | Starcat 端调用点 |
|---|---|---|---|
| GET | `/repo?lang=…&since=daily/weekly/monthly` | Trending 仓库列表 | `Starcat/Core/Sync/TrendingRepository.swift` |
| GET | `/user?lang=…&since=…&sponsorable=1` | Trending 开发者列表 | （P1+ 预留） |
| GET | `/lang` | 支持的语言字典 | 启动时缓存到 `TrendingReadme.swift` 旁路表 |

**调用链路**：见 `docs/3-设计/详细设计/starcat-trending-设计.md`（已确认方案的原始设计稿）。

### 2. `starcat-sharing-api`（5001）

**解决的痛点**：Starcat 用户想把自己收藏 + AI 摘要的 repo「分享」给朋友，但 macOS App 不适合做公开 Web 入口。

**提供的接口**：

| Method | Path | 说明 | Starcat 端调用点 |
|---|---|---|---|
| POST | `/api/share` | 接收 repo 数据 + AI 摘要，返回短链 | （P1 实现，预计在「分享弹窗」提交时） |
| GET | `/s/{id}` | 公开访问的分享页（服务端渲染） | 浏览器侧（不在 App 内） |

**为什么需要独立后端**：
- 分享页要能被**未安装 Starcat** 的人访问 → 不能是 macOS 内部功能
- 渲染走服务端 `html/template` + Tailwind → Starcat 主端不污染 UI 栈
- 数据先暂存本地 `data.json`（MVP），后续换持久化

---

## 🛠️ 本地开发

### 一次性启动两个服务

```bash
# Terminal A - Trending API
cd supports/starcat-trending-api
go run ./cmd/server
# → http://localhost:5002

# Terminal B - Sharing API
cd supports/starcat-sharing-api
go run ./cmd/server
# → http://localhost:5001
```

### 在 Starcat 主端指向本地服务

两个 API 的 base URL 走 Starcat 的设置项（`Starcat/Core/Settings/AppSettings.swift` 的「API Base URL」段）。**当前实现是硬编码**，未来改造为：

```swift
// 伪代码,示意未来设置面板的设计
struct APISettings {
    var trendingBaseURL: URL = URL(string: "http://localhost:5002")!
    var sharingBaseURL: URL = URL(string: "http://localhost:5001")!
}
```

修改后切到生产时，只需把 URL 换成 `https://<fly/render 子域名>` 即可，**无需改业务代码**。

### 健康检查

```bash
# Trending
curl http://localhost:5002/        # → {"message":"Hello GitHub trending"}

# Sharing
curl -X POST http://localhost:5001/api/share \
     -H "Content-Type: application/json" \
     -d '{"repo":"octocat/Hello-World","summary":"test"}'
# → {"id":"abc123","url":"http://localhost:5001/s/abc123"}
```

---

## 🌐 Fly.io 生产部署

| App | URL |
|-----|-----|
| starcat-sharing-api | https://starcat-sharing-api.fly.dev |
| starcat-trending-api | https://starcat-trending-api.fly.dev |
| starcat-weekly-api | https://starcat-weekly-api.fly.dev |
| starcat-wiki-api | https://starcat-wiki-api.fly.dev |
| starcat-discovery-api | https://starcat-discovery-api.fly.dev |

**环境变量清单 + 与 Starcat 客户端 API Key 对齐**：[`docs/fly-io-环境变量.md`](./docs/fly-io-环境变量.md)

```bash
在 Starcat 主仓库根目录：

```bash
make sync-fly-secrets              # Fly 各 API secrets（并行）
make setup-production-api-keys     # 客户端各 API baked-in keys
```
```

sharing 生产环境 `BASE_URL` 须为公网 URL（默认 `https://starcat-sharing-api.fly.dev`），详见环境变量文档 §5.1。

---

## 🌐 部署（历史 / 其他平台）

每个子仓库自带 `fly.toml`，可独立部署。**生产环境必须用 HTTPS**。

| 平台 | 文档 |
|------|------|
| Fly.io | **主文档** → [`docs/fly-io-环境变量.md`](./docs/fly-io-环境变量.md) |
| Render | 各子仓库 `docs/DEPLOY_RENDER.md`（如存在） |

---

## 🔐 安全与凭据

- **Fly 生产**：`API_KEYS`、`GITHUB_TOKENS` 等通过 `fly secrets set` 注入，见 [`docs/fly-io-环境变量.md`](./docs/fly-io-环境变量.md)
- **本地开发**：各子项目 `.env`（gitignore），用 `make fly-secrets-all` 可同步到 Fly
- **客户端 baked-in Key**：`Configs/Secrets.xcconfig` → `make setup-production-api-keys`（Starcat 主仓库）
- **绝不要**把真实 API Key / GitHub Token 提交到 git

---

## 🔄 升级与同步

这两个子仓库**独立发版**，主 Starcat 通过 HTTP 契约解耦。修改 API 时：

1. **加新字段** → 兼容（旧客户端忽略未知字段）
2. **删字段 / 改语义** → 必须先升 Starcat 端代码再升服务端（或留双版本过渡）
3. **改路径 / 改方法** → 不允许（破坏性变更），必须新建 endpoint + 旧 endpoint 至少保留一个 release cycle

---

## 📚 相关文档

- [Starcat 主仓库 CLAUDE.md](../CLAUDE.md)
- [Starcat 概要设计](../docs/1-立项/概要设计.md)
- [Starcat 详细设计索引](../docs/3-设计/详细设计/README.md)
- 各子仓库 README：
  - [`starcat-sharing-api/README.md`](./starcat-sharing-api/README.md)
  - [`starcat-trending-api/README.md`](./starcat-trending-api/README.md)
  - [`starcat-discovery-api/README.md`](./starcat-discovery-api/README.md)

---

*最后更新：2026-06-08 — 端口约定 5001/5002，初始集成文档*
