# 20. starcat-wiki-api 客户端对接

> **本文是 `supports/starcat-wiki-api` 的【客户端对接手册】**。
> 服务端的设计与权衡详见 `19-wiki集成.md`（§3-7）。本文只解决「客户端（Starcat App）怎么调、怎么处理、什么情况下降级」。
>
> **目标读者**：要在 Starcat 客户端接入 wiki-api 的 iOS / macOS 工程师（dong4j）。

---

## 0. 元信息

| 项 | 值 |
|---|---|
| 服务名 | `starcat-wiki-api` |
| 端口 | `5004` |
| 基础路径 | `http://127.0.0.1:5004`（本地） / `https://starcat-wiki-api.fly.dev`（生产） |
| 鉴权 | `Authorization: Bearer <api-key>`（与 trending / weekly / sharing 共用同一把 Key） |
| 响应格式 | `Envelope<T>`（`schema_version` + `data` + `meta`），与 supports 4 个 API byte-level 一致 |
| 错误格式 | `ErrorEnvelope`（`code` + `message` + `details?`） |
| 服务端版本 | `v1.0.0`（2026-06-10 初始化，详见 `supports/starcat-wiki-api/CHANGELOG.md`） |

> ⚠️ 本号文档成文于 2026-06-11，**端点形态、字段名、模型结构均已与 `main.go` / `handler/probe.go` / `internal/probe/types.go` e2e 对齐**。如果未来实现改了，先改服务端代码、再改本文档。

---

## 1. 核心能力（一句话）

> **给定一个 GitHub `owner/repo`，告诉你 DeepWiki / Zread / Google Code Wiki 这三个外部文档站有没有收录它；如果收录了，给出跳转 URL。**

Starcat 客户端的「详情页右上角 → 打开外部文档」按钮组用这个数据驱动。

---

## 2. 鉴权

### 2.1 与其他 3 个 API 的关系

| 服务 | 端口 | 鉴权 |
|---|---|---|
| sharing-api | 5001 | `Bearer <api-key>` |
| trending-api | 5002 | `Bearer <api-key>` |
| weekly-api | 5003 | `Bearer <api-key>` |
| **wiki-api** | **5004** | **`Bearer <api-key>`** |

**用户视角**：「一把 Starcat API Key 通行 4 个后端」。**客户端实现**：`StarcatAPIKey` 解析器共用同一个 Keychain item，按 `case .wiki` 路由到 `wiki-api`。

### 2.2 鉴权失败响应

```http
HTTP/1.1 401 Unauthorized
Content-Type: application/json; charset=utf-8

{
  "schema_version": 1,
  "error": {
    "code": "UNAUTHORIZED",
    "message": "missing or invalid Authorization header"
  }
}
```

> 客户端处理：`401` → 标记 `wikiAPI` 不可用（解耦到 `AppDependencies`，详见 §6.2）+ 设置页"服务"Tab 显示「Wiki 服务鉴权失败」。

### 2.3 测试用 Key

- **本地**：用 `bash supports/scripts/gen-api-key.sh 1` 生成
- **e2e 验证**：`sk-starcat-E22GFRKJLNWCGEZBJIFFFTM37H5K5FOH`（已验证可用，仅本地）

---

## 3. 端点速查表

| 方法 | 路径 | 鉴权 | 用途 | 客户端调用频次 |
|---|---|---|---|---|
| `GET` | `/healthz` | ❌ 公开 | 健康检查 | App 启动时 1 次 |
| `GET` | `/api/v1/wikis?owner=&repo=` | ✅ | 单仓库三源探测 | 详情页打开 1 次 |
| `POST` | `/api/v1/wikis/batch` | ✅ | 批量探测（≤50 repo） | 首装 / 批量刷新 |
| `POST` | `/internal/sync/probe` | ✅ | 管理员全量重探测（**当前 noop**） | 调试用，不调 |
| `POST` | `/internal/refresh/owner` | ✅ | 管理员单 owner 刷新（**当前 noop**） | 调试用，不调 |

---

## 4. 端点详解

### 4.1 `GET /healthz`（公开）

**用途**：App 启动时探测 wiki-api 是否在线。

```http
GET /healthz HTTP/1.1
```

**响应**：
```http
HTTP/1.1 200 OK
Content-Type: text/plain; charset=utf-8

ok
```

**客户端实现**：
```swift
// Starcat/Core/Network/WikiAPI.swift
func health() async -> Bool {
    let url = baseURL.appendingPathComponent("healthz")
    var req = URLRequest(url: url)
    req.timeoutInterval = 3
    do {
        let (_, resp) = try await session.data(for: req)
        return (resp as? HTTPURLResponse)?.statusCode == 200
    } catch {
        return false
    }
}
```

**降级**：`health() == false` → `wikiAPI` 实例降级为 `nil`，详情页右上角外部文档按钮组**整体不显示**。

---

### 4.2 `GET /api/v1/wikis`（单查）

**用途**：详情页打开时，探测当前 repo 被 3 个外部站收录状态。

**请求**：
```http
GET /api/v1/wikis?owner=facebook&repo=react HTTP/1.1
Host: 127.0.0.1:5004
Authorization: Bearer sk-starcat-...
```

| Query 参数 | 必填 | 说明 |
|---|---|---|
| `owner` | ✅ | GitHub owner，建议客户端用 `^[a-zA-Z0-9._-]+$` 校验（与 weekly-api `parser/markdown.go:116-131` 一致） |
| `repo` | ✅ | GitHub repo，同上校验 |

**响应（200，冷启动 → fresh）**：
```json
{
  "schema_version": 1,
  "data": [
    {
      "source": "codewiki",
      "status": "unknown",
      "url": "https://codewiki.google/github.com/facebook/react",
      "confidence": "low",
      "probeMethod": "url_probe",
      "httpStatus": 200
    },
    {
      "source": "zread",
      "status": "indexed",
      "url": "https://zread.ai/facebook/react",
      "confidence": "high",
      "probeMethod": "json_api",
      "httpStatus": 200,
      "matchedSignals": ["api_status_success"]
    },
    {
      "source": "deepwiki",
      "status": "indexed",
      "url": "https://deepwiki.com/facebook/react",
      "confidence": "high",
      "probeMethod": "json_api",
      "httpStatus": 200,
      "matchedSignals": ["api_status_completed"]
    }
  ],
  "meta": {
    "generated_at": "2026-06-11T02:25:26+08:00",
    "cache_status": "fresh"
  }
}
```

**响应字段（data[].item）**：

| 字段 | 类型 | 必返 | 说明 |
|---|---|---|---|
| `source` | enum | ✅ | `"deepwiki"` / `"zread"` / `"codewiki"` |
| `status` | enum | ✅ | `"indexed"` / `"probably_indexed"` / `"not_indexed"` / `"unknown"` / `"error"` / `"rate_limited"` |
| `url` | string | ✅ | 跳转 URL（展示页，不是 API URL） |
| `confidence` | string | ✅ | `"high"` / `"medium"` / `"low"` |
| `probeMethod` | string | ✅ | `"html_fingerprint"` / `"batchexecute_fetch"` / `"url_probe"` / `"json_api"` |
| `httpStatus` | int | ❌ | 上游探测 HTTP 状态码（omitted if null） |
| `matchedSignals` | string[] | ❌ | 命中信号集合（omitted if 空） |
| `error` | string | ❌ | 错误信息（仅 status=error 时存在） |
| `expiresAt` | — | ❌ | **不暴露给客户端**（`json:"-"`，缓存用） |

**响应字段（meta）**：

| 字段 | 类型 | 必返 | 说明 |
|---|---|---|---|
| `cache_status` | string | ✅ | `"fresh"` / `"stale"` / `"cold"` |
| `generated_at` | string | ✅ | RFC3339 字符串 |

**URL 模板**（客户端直跳时也按这个拼）：

| source | URL 模板 |
|---|---|
| `deepwiki` | `https://deepwiki.com/{owner}/{repo}` |
| `zread` | `https://zread.ai/{owner}/{repo}` |
| `codewiki` | `https://codewiki.google/github.com/{owner}/{repo}` |

**错误响应**：

```http
HTTP/1.1 400 Bad Request
{
  "schema_version": 1,
  "error": {
    "code": "BAD_REQUEST",
    "message": "owner and repo are required"
  }
}
```

```http
HTTP/1.1 500 Internal Server Error
{
  "schema_version": 1,
  "error": {
    "code": "INTERNAL_ERROR",
    "message": "<sqlite error message>"
  }
}
```

**客户端实现**：
```swift
// Starcat/Core/Network/WikiAPI.swift
actor WikiAPI {
    func status(owner: String, repo: String) async throws -> [WikiStatusItem] {
        var comps = URLComponents(url: baseURL.appendingPathComponent("api/v1/wikis"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "owner", value: owner),
            .init(name: "repo", value: repo),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(apiKey ?? "")", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30   // 冷启动可能要 1-3s 同步探测
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw StarcatAPIError.transport(...)
        }
        let env = try JSONDecoder().decode(
            StarcatEnvelope<[WikiStatusItem]>.self, from: data
        )
        return env.data
    }
}
```

> ⚠️ `req.timeoutInterval = 30`：**冷启动场景下服务端要同步探测 3 个源**（SQLite miss 时走 `syncProbe`，1-3s）。客户端不能给太短，否则会假性失败。

---

### 4.3 `POST /api/v1/wikis/batch`（批量）

**用途**：首装 / 批量刷新时，一次性探测多个 repo。

**请求**：
```http
POST /api/v1/wikis/batch HTTP/1.1
Host: 127.0.0.1:5004
Authorization: Bearer sk-starcat-...
Content-Type: application/json

{
  "repos": [
    "facebook/react",
    "vercel/next.js",
    "openai/openai-cookbook"
  ]
}
```

| Body 字段 | 必填 | 说明 |
|---|---|---|
| `repos` | ✅ | 数组，每项 `"owner/repo"`，**≤50** 个 |

**响应（200，全部走缓存）**：
```json
{
  "schema_version": 1,
  "data": {
    "results": {
      "facebook/react": [
        {"source": "deepwiki", "status": "indexed", "url": "..."},
        {"source": "zread",    "status": "indexed", "url": "..."},
        {"source": "codewiki", "status": "unknown",  "url": "..."}
      ],
      "vercel/next.js": [ ... ],
      "openai/openai-cookbook": [ ... ]
    }
  },
  "meta": {
    "generated_at": "2026-06-11T02:25:30+08:00",
    "total": 3
  }
}
```

**注意**：
- 响应里 **`results` 是 `map<fullName, [items]>`**，不是设计文档 §6.2 想象的 `items: [{repo, providers: [...]}]` 嵌套结构。**e2e 验证后的实现语义**
- 客户端**最多 50 个 repo**，超了返 400
- 服务端内部会并发探测 + repo 之间插入随机延迟 `PROBE_BATCH_MIN/MAX_DELAY_MS`（80-400ms），50 个 repo 大约 30-120s
- **空 repos 也合法**，返 `data.results = {}`

**错误响应**：
```http
HTTP/1.1 400 Bad Request
{
  "schema_version": 1,
  "error": {
    "code": "BAD_REQUEST",
    "message": "too many repos (max 50)"
  }
}
```

```http
HTTP/1.1 400 Bad Request
{
  "schema_version": 1,
  "error": {
    "code": "BAD_REQUEST",
    "message": "invalid body"
  }
}
```

**客户端实现**：
```swift
func statusBatch(repos: [String]) async throws -> [String: [WikiStatusItem]] {
    var req = URLRequest(url: baseURL.appendingPathComponent("api/v1/wikis/batch"))
    req.httpMethod = "POST"
    req.setValue("Bearer \(apiKey ?? "")", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONEncoder().encode(["repos": repos])
    req.timeoutInterval = 180   // 50 repo × 3 源 + 延迟 = 30-120s
    let (data, _) = try await session.data(for: req)
    let env = try JSONDecoder().decode(
        StarcatEnvelope<BatchData>.self, from: data
    )
    return env.data.results
}

private struct BatchData: Decodable {
    let results: [String: [WikiStatusItem]]
}
```

---

### 4.4 Admin 端点（**当前是 noop**，仅供调试）

#### `POST /internal/sync/probe`

```http
POST /internal/sync/probe HTTP/1.1
Authorization: Bearer sk-starcat-...
```

**响应**：
```json
{
  "schema_version": 1,
  "data": {
    "task_id": "task-2026-06-11T02:25:30Z-probe-0",
    "started_at": "2026-06-11T02:25:30+08:00",
    "status": "running"
  }
}
```

> ⚠️ **已知技术债 D-W1**：`handler/admin.go:HandleAdminSyncProbe` 当前只生成 `task_id` 立即返回，**后台没有真正执行重探测**。`scheduler/cron.go:refreshStale` 也是 placeholder。客户端**不应该依赖这个端点**做实际重探测，需要重探测就调 `POST /api/v1/wikis/batch`。

#### `POST /internal/refresh/owner`

同上 noop，**不要调用**。

---

## 5. 数据模型

### 5.1 客户端 DTO

```swift
// Starcat/Core/Network/WikiModels.swift
struct WikiStatusItem: Codable, Sendable, Identifiable {
    let source: DocsSource
    let status: DocsStatus
    let url: String
    let confidence: String
    let probeMethod: String?
    let httpStatus: Int?
    let matchedSignals: [String]?

    var id: String { "\(source.rawValue)-\(url)" }
}

enum DocsSource: String, Codable, CaseIterable, Sendable {
    case deepwiki
    case zread
    case codewiki

    var displayName: String {
        switch self {
        case .deepwiki: return "DeepWiki"
        case .zread:    return "Zread"
        case .codewiki: return "Google Code Wiki"
        }
    }

    var urlTemplate: String {
        switch self {
        case .deepwiki: return "https://deepwiki.com/{owner}/{repo}"
        case .zread:    return "https://zread.ai/{owner}/{repo}"
        case .codewiki: return "https://codewiki.google/github.com/{owner}/{repo}"
        }
    }
}

enum DocsStatus: String, Codable, Sendable {
    case indexed
    case probablyIndexed = "probably_indexed"
    case notIndexed      = "not_indexed"
    case unknown
    case error
    case rateLimited     = "rate_limited"

    /// 是否有"可跳转"价值（驱动主按钮显隐，详见 §7.3）
    var isMeaningful: Bool {
        switch self {
        case .indexed, .probablyIndexed, .unknown: return true
        case .notIndexed, .error, .rateLimited:   return false
        }
    }
}
```

### 5.2 Envelope 复用

跟 trending / weekly / sharing **完全共用** `StarcatEnvelope.swift`：

```swift
// 已存在,不要新建
struct StarcatEnvelope<T: Decodable>: Decodable {
    let schemaVersion: Int
    let data: T
    let meta: StarcatMeta?
}
```

⚠️ **跨项目 byte-level 同步约定**（`supports/docs/R-01-总体设计.md §4.1`）：`StarcatEnvelope` 跟 4 个 Go 服务的 `internal/model/envelope.go` 字段集**必须保持一致**。改 Go 端必须同步改 Swift 端，反之亦然。

---

## 6. 客户端接入方案

### 6.1 AppEndpoints 扩展

```swift
// Starcat/Core/Network/AppEndpoints.swift
enum Wiki: ServiceEndpoint {
    static let productionURL = "https://starcat-wiki-api.fly.dev"
    enum Paths {
        static let status      = "/api/v1/wikis"
        static let statusBatch = "/api/v1/wikis/batch"
    }
}
```

### 6.2 AppDependencies 装配（**强制解耦**）

> ⚠️ **硬性规则**：`wikiAPI` 装配**必须**单独 try，失败转 `nil`，**不能影响** trendingAPI / shareAPI / weeklyAPI 三个 actor 的初始化。

```swift
// Starcat/App/AppDependencies.swift
@MainActor
final class AppDependencies {
    let trendingAPI: TrendingAPI
    let shareAPI: ShareAPI
    let weeklyAPI: WeeklyAPI
    let wikiAPI: WikiAPI?    // ← optional

    init() {
        self.trendingAPI = AppDependencies.makeTrendingAPI()
        self.shareAPI    = AppDependencies.makeShareAPI()
        self.weeklyAPI   = AppDependencies.makeWeeklyAPI()
        self.wikiAPI     = AppDependencies.tryMakeWikiAPI()  // ← 单独 try
    }

    private static func tryMakeWikiAPI() -> WikiAPI? {
        do {
            return try WikiAPI(
                baseURL: AppEndpoints.Wiki.baseURL,
                apiKey: StarcatAPIKeyResolver.resolve(for: .wiki)
            )
        } catch {
            Log.warn("[AppDependencies] WikiAPI init failed: \(error)")
            return nil    // 详情页按钮组整体不显示
        }
    }
}
```

**单服务 down 的影响边界**：

| 场景 | 影响 |
|---|---|
| `wikiAPI == nil` | 详情页外部文档按钮组**整体不显示**；banner 提示「外部文档索引服务暂不可用」 |
| `trendingAPI == nil` | 详情页不能加载 trending 视图；wiki 按钮组**仍正常显示** |
| 两个都 nil | trending 区 + wiki 区都不显示，**互不影响** |

### 6.3 WikiAPI actor 实现

参考 `TrendingAPI.swift:41-186` 的 actor 模式，完整骨架：

```swift
// Starcat/Core/Network/WikiAPI.swift
actor WikiAPI {
    let baseURL: URL
    private(set) var apiKey: String?
    private let session: URLSession

    init(baseURL: URL, apiKey: String?,
         session: URLSession = .starcatDefault) throws {
        guard let url = URL(string: "/api/v1/wikis",
                            relativeTo: baseURL) else {
            throw StarcatAPIError.badURL
        }
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    func status(owner: String, repo: String) async throws -> [WikiStatusItem] {
        // ... 见 §4.2
    }

    func statusBatch(repos: [String]) async throws -> [String: [WikiStatusItem]] {
        // ... 见 §4.3
    }

    func health() async -> Bool { /* ... */ }

    func updateBaseURL(_ url: URL) async {
        self.baseURL = url    // 设置页热更新
    }

    func updateAPIKey(_ key: String?) async {
        self.apiKey = key     // 设置页热更新
    }
}
```

### 6.4 StarcatAPIKey 扩展

```swift
// Starcat/Core/Network/StarcatAPIKey.swift
enum StarcatAPIKeyTarget: CaseIterable {
    case sharing      // 5001
    case trending     // 5002
    case weekly       // 5003
    case wiki         // 5004  ← 新增

    var keychainKey: String {
        switch self {
        case .sharing, .trending, .weekly, .wiki:
            return "com.starcat.app.apiKey"   // 4 个服务共用同一把 Key
        }
    }
}
```

**BYOK 视角**：用户输入 1 把 Starcat API Key，4 个后端都用它。**避免**一个 key 存 4 份。

---

## 7. 详情页 UI 集成

### 7.1 入口位置

详情页（`RepoDetailScaffold`）的 `TrailingActions` 区（右上角）。原 `openInGitHub` 按钮**不动**，**新增**一个 `Wiki ▾` 按钮组。

### 7.2 按钮显隐规则（**重要**）

| 状态组合 | 主按钮显示 |
|---|---|
| 至少 1 个 source 是 `indexed` / `probably_indexed` / `unknown` | ✅ 显示「Wiki ▾」 |
| 3 个 source **全是** `not_indexed` | ❌ 主按钮**整体不显示**（不显示空下拉） |
| 3 个 source **全是** `error` / `rate_limited` | ❌ 主按钮不显示（没意义，等缓存过期） |
| `wikiAPI == nil`（解耦失败） | ❌ 主按钮不显示，改显示「打开主页」备选链接 |
| 未登录态 | ❌ 隐藏（沿用 v1.4 规则） |
| 设置里 3 个 source 全关掉 | ❌ 主按钮不显示（没东西可看） |

**伪代码**：

```swift
@MainActor
func shouldShowWikiDropdown(items: [WikiStatusItem]) -> Bool {
    // 1. wikiAPI 不可用
    guard deps.wikiAPI != nil else { return false }
    // 2. 未登录
    guard session.isLoggedIn else { return false }
    // 3. 至少 1 个启用的 source 有意义结果
    let enabled = items.filter { AppSettings.wiki.enabledSources.contains($0.source) }
    let meaningful = enabled.filter { $0.status.isMeaningful }
    return !meaningful.isEmpty
}
```

### 7.3 下拉组件

`[📖 Wiki ▾]` 主按钮 + Menu 下拉：

```
[📖 Wiki ▾]
  ├─ ✅ DeepWiki           (book.pages.fill)        ← indexed, 主色
  ├─ ✅ Zread              (book.pages.fill)        ← indexed
  ├─ ⚠️ Google Code Wiki   (g.circle.fill)          ← unknown
  ├─ ⏳ GitHub 文档         (book.pages)             ← 设置里关掉了, 不显示
  └─ 打开主站...            (arrow.up.right.square)
```

**UI 行为**：
- **主按钮**显示「Wiki ▾」（点击展开下拉），**不直接跳转**
- **下拉列表**：每个 wiki 源一行，按 `indexed → probablyIndexed → unknown → notIndexed` 顺序排列
  - `indexed` / `probablyIndexed` → 主色行 + 点击 → 浏览器打开
  - `unknown` → 次色行 + 「Try Open」文字 + 点击 → 浏览器打开
  - `notIndexed` / `error` / `rateLimited` → 灰色行 + **不显示**
- **未登录态**：下拉整体隐藏
- **打开主站**（`arrow.up.right.square`）→ 跳 `https://deepwiki.com/`（deepwiki 作兜底，因为是 3 个里最广的）

### 7.4 SWR 客户端配合

服务端支持 SWR（stale-while-revalidate）：命中但过期时**立即返回 stale 数据**，后台异步刷新。客户端**无需**等待 `cache_status == "fresh"` 才渲染 UI：

- `fresh` / `stale` / `cold` 都**立刻**渲染对应按钮（stale 用旧数据，冷启动空态）
- 后台 silent 刷新时，**不显示 loading spinner**（避免 UI 抖动）
- 刷新结果回来后，**平滑切换按钮状态**（用 SwiftUI `@Observable` 自动响应）

---

## 8. 调用时序

### 8.1 用户场景：打开详情页

```
用户点击 repo card
  ↓
详情页 RepoDetailScaffold.onAppear
  ↓
并行触发:
  ├─ WikiAPI.status(owner, repo)   ← 5004
  ├─ TrendingAPI.metadata(...)      ← 5002 (既有)
  └─ 其他既有
  ↓
WikiAPI.status 返回 [WikiStatusItem] + meta.cache_status
  ↓
按 §7.2 显隐规则判断是否显示 Wiki ▾ 按钮
  ↓
若显示:渲染主按钮 + 预拉下拉数据
```

### 8.2 用户场景：首装 / 批量刷新

```
用户进设置 → 外部文档索引 → 「全部重新探测」
  ↓
客户端按 local DB 里所有 repo 全名分批:
  - 50 个一批
  - 串行调 POST /api/v1/wikis/batch(避免触发 Cloudflare)
  ↓
结果写 local cache(SwiftUI @Observable 驱动 UI)
  ↓
显示「已探测 N/M」
```

### 8.3 用户场景：服务热更新

```
设置页 → 服务 → 改 wiki-api baseURL / Key
  ↓
await deps.wikiAPI?.updateBaseURL(newURL)
await deps.wikiAPI?.updateAPIKey(newKey)
  ↓
下次 status() 调用自动用新配置(无需重启 App)
  ↓
若更新后 health() == false → 自动降级为 nil,UI 按钮组消失
```

---

## 9. 错误处理矩阵

| HTTP 状态 | code | 客户端处理 |
|---|---|---|
| `200` | — | 正常解析 `data` |
| `400` | `BAD_REQUEST`（"owner and repo are required"） | 参数校验未过，本地 bug，跳过 |
| `400` | `BAD_REQUEST`（"too many repos (max 50)"） | 客户端分批，单批 ≤ 50 |
| `400` | `BAD_REQUEST`（"invalid body"） | 序列化 bug，本地 bug，跳过 |
| `401` | `UNAUTHORIZED` | `wikiAPI` 降级为 nil + 设置页提示「Wiki 服务鉴权失败」 |
| `500` | `INTERNAL_ERROR` | 详情页按钮组不显示 + 不重试（等下次打开） |
| 网络错误 | — | 同上 500 处理 |

---

## 10. 测试矩阵

### 10.1 客户端单测

| 场景 | 验证点 |
|---|---|
| `WikiAPI.status("facebook", "react")` | mock URLProtocolStub 返真实 200 响应 → 解码出 3 个 item |
| `status` owner/repo 为空 | 本地校验拦截（不发请求） |
| `status` 401 响应 | 抛 `StarcatAPIError.unauthorized` |
| `status` 500 响应 | 抛 `StarcatAPIError.transport` |
| `statusBatch` 50 个 | mock 返 50 个 fullName → 解析 map |
| `statusBatch` 51 个 | 本地校验拦截（不发请求） |
| `health()` true | `wikiAPI` 不降级 |
| `health()` false（连接失败） | `wikiAPI` 降级为 nil（**注意：失败时**装配期已经 try 过，**这里测的是运行期 health**） |
| `shouldShowWikiDropdown` 3 个全 notIndexed | 返 `false` |
| `shouldShowWikiDropdown` 1 个 indexed | 返 `true` |
| `shouldShowWikiDropdown` `wikiAPI == nil` | 返 `false` |
| `shouldShowWikiDropdown` 未登录 | 返 `false` |

### 10.2 e2e 验证（已通过 2026-06-11）

| # | 场景 | 期望 | 实测 |
|---|---|---|---|
| 1 | `GET /api/v1/wikis` 无鉴权 | 401 | ✅ 401 |
| 2 | `GET /api/v1/wikis` 无 owner | 400 | ✅ 400 |
| 3 | `GET /api/v1/wikis?owner=facebook&repo=react` 冷启动 | 200 + 3 items | ✅ 200, deepwiki/zread indexed, codewiki unknown |
| 4 | 同 #3 第二次（fresh 缓存） | 200 + 3 items, cache_status=fresh | ✅ 200, fresh |
| 5 | `POST /api/v1/wikis/batch` 空 repos | 200 + results={} | ✅ 200 |
| 6 | `POST /api/v1/wikis/batch` 3 个 repo | 200 + results map | ✅ 200, 3 个 fullName |
| 7 | `POST /api/v1/wikis/batch` 51 个 | 400 too many | ✅ 400 |
| 8 | `POST /api/v1/wikis/batch` 无效 JSON | 400 invalid body | ✅ 400 |
| 9 | `POST /internal/sync/probe` 有鉴权 | 200 + task_id | ✅ 200 (noop) |
| 10 | `POST /internal/refresh/owner` 有鉴权 | 200 + task_id | ✅ 200 (noop) |
| 11 | `POST /internal/sync/probe` 无鉴权 | 401 | ✅ 401 |

---

## 11. 与设计文档 §6 的差异（**客户端对接必看**）

> **dong4j 在 2026-06-11 复审 wiki-api 实现时发现，19-wiki集成.md §6 的「设计契约」跟当前实现**有几处不一致**。客户端对接以本节「实测实现」为准，不要按 §6 写代码。

| 项 | 19-wiki集成.md §6 设计的 | **当前实现的** | 影响 |
|---|---|---|---|
| §6.1 单查响应 `data` 字段 | `{owner, repo, checkedAt, items: [...]}` 嵌套结构 | `[items...]` 直接数组 | **D-W2**: 客户端解码器按数组解析，不要按嵌套 |
| §6.2 批量请求 `sources` filter | `"sources": ["deepwiki", "zread", "codewiki"]` 字段 | **未实现**，请求只能传 `repos` | **D-W3**: 客户端不要传 `sources` 字段，传了也不生效 |
| §6.2 批量响应 `data` 字段 | `{items: [{repo, providers: [...]}]}` 嵌套 | `{results: {fullName: [items]}}` map | **D-W4**: 客户端按 map 解析 |
| §6.2 批量响应 `meta` | `cache_status, total, served_fresh, served_stale, latency_ms` | `generated_at, total` | 客户端**不要**依赖 `served_fresh/stale/latency_ms` |
| §4.1 cron 03/04/05 三任务 | 实际跑 | **placeholder**（`scheduler/cron.go:46-68`） | 客户端不要依赖服务端定时刷新 |
| §6.3 admin 端点 | 实际重探测 | **noop**（`handler/admin.go:11-32`） | 客户端不要调 admin，需要重探测用 batch |

> **建议**：本节差异全部在 wiki-api **下一次重构时**消化掉（更新实现以对齐设计 OR 更新设计以对齐实现，**不要两边都改**）。在此之前，**客户端按本节实现写代码**。

---

## 12. 已知技术债

| 编号 | 说明 | 状态 |
|---|---|---|
| **D-W1** | admin 端点 + cron 全部 noop，没有真正定时重探测能力 | 未修（**优先 P1**） |
| **D-W2** | §6.1 单查响应 data 是数组，**19-wiki集成.md §6.1 设计的是嵌套对象** | 未修（文档 vs 实现不一致） |
| **D-W3** | §6.2 批量请求 `sources` filter 未实现 | 未修 |
| **D-W4** | §6.2 批量响应 data 是 `{results: map}`，**§6.2 设计的是 `items` 数组** | 未修 |
| **D-W5** | `PROBE_CACHE_*_DAYS/HOURS/MIN` 等 4 个 env 配置在 `.env.example` 列出，但 `sqlite.go:88-100` 写死 TTL，**env 不生效** | 未修 |
| **D-W6** | `tryMakeWikiAPI()` 当前 main 入口**不调用 health() 预热**，`wikiAPI` 是否可用要等首次请求才知道 | 未修（优化项） |
| **D-W7** | `BatchV1` 在并发探测时**没用 `inflight` 防重**（不像单查有 `sync.Map`），同一 batch 内出现重复 repo 会重复探测 | 未修 |
| **D-W8** | 客户端**还没建** `WikiAPI.swift` / `WikiModels.swift` / `RepoDetailExternalDocsDropdown`，本文档是 0→1 蓝图 | 未开始 |

---

## 13. 落地 checklist

> **本期范围**（与 `19-wiki集成.md §10.2 客户端验收清单` 一致，但按本文 §11 差异修正）：

- [ ] `Starcat/Core/Network/AppEndpoints.swift` 追加 `Wiki` case + `Paths.status` / `Paths.statusBatch`
- [ ] `Starcat/Core/Network/StarcatAPIKey.swift` 追加 `.wiki` case
- [ ] `Starcat/Core/Network/WikiAPI.swift` 新建，actor 模式参考 `TrendingAPI.swift:41-186`
- [ ] `Starcat/Core/Network/WikiModels.swift` 新建（`WikiStatusItem` / `DocsSource` / `DocsStatus`）
- [ ] `Starcat/App/AppDependencies.swift` v0.4 改造：`tryMakeWikiAPI()` 单独 try，失败 nil
- [ ] `Starcat/Features/RepoDetail/Components/RepoDetailExternalDocsDropdown.swift` 新建
- [ ] `Starcat/Features/RepoDetail/RepoDetailScaffold.swift` 集成新组件到 `TrailingActions`
- [ ] `Starcat/Features/Settings/SettingsServiceTab.swift` 加「外部文档索引」行：baseURL / Key / enabledSources / 健康检查
- [ ] `StarcatTests/WikiAPITests.swift` 新建（§10.1 矩阵）
- [ ] `StarcatTests/WikiSWRTests.swift` 新建（fresh / stale / cold 三态）
- [ ] `StarcatTests/RepoDetailExternalDocsDropdownTests.swift` 新建（§10.1 `shouldShowWikiDropdown`）
- [ ] `Localizable.xcstrings` 加新键：`wiki.dropdown.title` / `wiki.source.deepwiki` / `wiki.source.zread` / `wiki.source.codewiki` / `wiki.settings.*` / `wiki.fallback.openMain`

---

## 14. 关联文档

| 文档 | 用途 |
|---|---|
| `19-wiki集成.md` | wiki-api 服务端设计与权衡（§3-7）+ 历史 v0.1→v0.5 翻转 |
| `18-三场景共用架构.md` | 客户端 4 个 API（sharing / trending / weekly / wiki）共用架构（Envelope / AppEndpoints / AppDependencies 解耦） |
| `supports/docs/R-01-总体设计.md` | 4 个 Go 服务的总体设计（跨项目 byte-level 同步约束） |
| `docs/工程进度/功能实现总览.md` | 主进度索引，本号文档完成后须勾选 + 加实现说明 |

---

*最后更新：2026-06-11*
