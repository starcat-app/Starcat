# 20. starcat-wiki-api 客户端对接方案

> **状态：客户端实施完成，全量自动化测试通过，待 dong4j 真机验收。**
>
> **评审结论（dong4j，2026-06-11）**：
> 1. 权限边界开放：未登录、未 Star 的 repo 也可使用 Wiki。
> 2. 首期范围收敛：Starcat 只做详情页单仓库查询。
> 3. Weekly Issue 必须排在最前，因为它是 Weekly 分组特有入口。
>
> 本文基于 2026-06-11 的实际代码重新审计：
> - 客户端：`Starcat/` 当前主分支
> - 后端：`supports/starcat-wiki-api`，commit `ac237e9`
> - 原始设计：`docs/3-设计/详细设计/19-wiki集成.md`
>
> 本文以当前代码事实为准，不直接照搬 19 号文档。19 号文档保留产品背景和历史决策，
> 但其中客户端契约、状态枚举、批量语义和依赖装配方案已有明显过期内容。

---

## 1. 结论

首期采用一个窄范围、可独立验收的接入方案：

1. Starcat 只调用 `GET /api/v1/wikis?owner=&repo=`，不接 batch/admin。
2. 详情页通过一个统一的 `RepoWikiMenu` 展示已确认收录的外部文档站。
3. 组件挂在 `RepoDetailScaffold`，一次覆盖 Manage、Trending、Weekly、Activity 四类 repo 详情页。
4. `WikiAPI` 是始终可构造的非 optional actor；网络失败是请求状态，不是依赖装配失败。
5. 不在 App 启动时探活，不因一次 `/healthz` 失败永久隐藏功能。
6. 首期不增加客户端数据库、不批量预热、不做 source 开关、不做“Try Open”猜测跳转。
7. Wiki 查询不依赖 GitHub 登录，也不依赖 repo 是否已 Star。

这个范围已经能完成核心价值：“打开任意 repo 详情时，若 DeepWiki / Zread / Code Wiki 已收录，
用户可直接跳转阅读”，同时避免把后端 v2 尚不稳定的异步 batch 状态机带进客户端。

---

## 2. 审计结果

### 2.1 可以直接复用的现有能力

| 能力 | 当前实现 | 接入结论 |
|---|---|---|
| 统一 endpoint | `AppEndpoints` | 新增 `Wiki` 命名空间 |
| 服务配置 | `ThirdPartyService.allCases` + `ServicesSettingsTab` | 新增 `.wiki` 后自动生成设置区块 |
| BYOK | `AppSettings` + Keychain + `StarcatAPIKeyResolver` | 按现有“每服务独立覆盖，production key 兜底”规则复用 |
| 热更新 | `AppDependencies.setServiceURL/setServiceAPIKey` | switch 新增 `.wiki` |
| 健康检查 | `ServiceHealthChecker` | 设置页手动测试连接时复用 |
| Envelope | `StarcatEnvelopeDecoder` | 直接解码 `[WikiStatusItem]` |
| 详情页统一骨架 | `RepoDetailScaffold` | Wiki 入口应在此统一接入 |
| 测试网络桩 | `URLProtocolStub` | 客户端单测使用固定响应，不依赖公网 |

### 2.2 原 19/20 号方案中不合理或已过期的部分

| 原方案 | 审计结论 | 新方案 |
|---|---|---|
| `WikiAPI?`，初始化失败变 nil | 当前 API actor 初始化不抛错；把网络故障建模成 DI 缺失会导致恢复困难 | `let wikiAPI: WikiAPI`，错误由每次请求表达 |
| App 启动调用 `/healthz` | 增加启动网络请求；瞬时故障会造成错误的全局降级 | 只在设置页用户主动“测试连接”时探活 |
| 4 个服务共用一个 Keychain item | 当前实现按 `ThirdPartyService.rawValue` 分服务存 BYOK；改成共享会破坏既有设置模型 | `.wiki` 使用独立 BYOK 覆盖，production 默认 key 仍可相同 |
| 未登录隐藏 Wiki | Wiki API 使用 Starcat service key，不使用 GitHub OAuth；外部文档也是公开内容 | 登录与否都可查询和跳转 |
| 仅已 Star repo 显示 | Trending/Weekly 的未 Star repo 同样有阅读文档价值 | 所有合法 `owner/repo` 都显示查询结果 |
| `unknown/probably_indexed/rate_limited` | 后端 v2 已删除这些公开契约 | 客户端只处理 `indexed/not_indexed/error`，并容忍未来未知值 |
| 离线时按模板显示 “Try Open” | 会把“服务不可用”误表示成“可能已收录”，用户点击后可能进入无效页面 | 请求失败时静默隐藏 Wiki 菜单，保留 GitHub 原入口 |
| 首装批量扫描全部 stars | 后端 batch 是异步秒返，首次常拿不到结果；还会制造大量外站探测 | 首期不接 batch，按详情页访问懒加载 |
| 客户端写本地 Wiki cache | 后端已有 SQLite + SWR；客户端再缓存会出现双 TTL 和失效一致性问题 | 首期不持久化，后端缓存是单一信任源 |
| 设置每个 source 开关 | 后端单查不支持 source filter，关闭 UI 也不会减少后端探测成本 | 首期不提供 source 开关 |
| 将 Wiki 塞进各场景 `trailingActions` | 四个详情页会重复维护异步状态和装配逻辑 | `RepoDetailScaffold` 内统一挂载自治组件 |

### 2.3 后端当前真实契约

#### 单查

```http
GET /api/v1/wikis?owner=facebook&repo=react
Authorization: Bearer <api-key>
```

```json
{
  "schema_version": 1,
  "data": [
    {
      "source": "zread",
      "status": "indexed",
      "url": "https://zread.ai/facebook/react",
      "probeMethod": "json_api",
      "httpStatus": 200,
      "matchedSignals": ["api_status_success"]
    }
  ],
  "meta": {
    "generated_at": "2026-06-11T10:00:00+08:00",
    "cache_status": "fresh"
  }
}
```

`cache_status` 语义：

| 值 | 后端行为 | 客户端行为 |
|---|---|---|
| `cold` | 无缓存，同步探测三源后返回 | 正常渲染，不额外轮询 |
| `fresh` | 返回新鲜缓存 | 正常渲染 |
| `stale` | 立即返回旧缓存，后台刷新 | 正常渲染旧结果；下次进入详情自然拿新结果 |

首期客户端不依赖 `cache_status` 做状态机。原因是 stale 请求只返回旧值，后端没有推送或任务查询端点；
当前页面主动轮询只会增加请求和 UI 抖动，收益有限。

#### 状态

当前 Go 类型定义为：

```text
probing / indexed / not_indexed / error
```

但单查 handler 只把 `probing` 映射为 `not_indexed`，**没有把 `error` 映射为
`not_indexed`**。因此 README 中“error 对外映射为 not_indexed”的描述与代码不一致。
客户端必须容忍 `error`，但只把 `indexed` 当成可跳转结果。

#### 批量

`POST /api/v1/wikis/batch` 当前是异步入队接口：

- 已有 fresh cache 的 repo 会出现在 `data.results`。
- 无缓存 repo 只会计入 `new_probes`，首次响应通常没有结果。
- 后端没有 task status / completion endpoint。
- 客户端若要拿最终值，只能自行轮询单查或再次 batch。

所以 batch 不适合作为首期客户端预热 API。保留为后续能力，不进入本次实现。

---

## 3. 产品行为

### 3.1 入口位置

入口位于所有 repo 详情页 Hero 区域右上角，与 Share、AI、Weekly Issue 等 action 同一行。

由 `RepoDetailScaffold` 统一渲染：

```text
[Weekly #123] [Wiki ▾] [Share] [AI]
```

Wiki 是 repo 的公开阅读入口，不属于 Tags / Notes / Releases 这类私人数据，因此：

- 未登录也允许显示。
- 未 Star 也允许显示。
- 不参与 `RepoLocalSections` 的可见性规则。

### 3.2 显示状态

| 状态 | UI |
|---|---|
| 请求中 | 不占位，不显示 spinner，避免 Hero action 行跳动过强 |
| 至少一个 `indexed` | 显示 `Wiki` Menu，只列出 indexed 项 |
| 全部 `not_indexed` | 不显示 |
| 只有 `error` / 未知状态 | 不显示，并记录网络日志 |
| 401 / 4xx / 5xx / 网络失败 | 不显示；设置页可测试连接和修正 URL/Key |
| repo fullName 非法 | 不发请求，不显示 |

不提供“打开 Wiki 主站”兜底。主站不是当前 repo 的文档，不能替代精确结果。

### 3.3 Menu 行为

```text
[book.pages  Wiki ▾]
  DeepWiki             ↗
  Zread                ↗
  Google Code Wiki     ↗
```

- 排序固定为 DeepWiki、Zread、Google Code Wiki，不依赖后端 map/并发返回顺序。
- 行点击使用服务端返回 URL，经 `http/https + host` 校验后交给 `NSWorkspace.shared.open`。
- 只使用服务端返回 URL，不在客户端重复拼 URL 模板。
- Menu 使用 `.buttonStyle(.plain)` 时必须紧跟 `.focusEffectDisabled()`。

---

## 4. 客户端架构

### 4.1 文件范围

计划新增：

```text
Starcat/Core/Network/WikiAPI.swift
Starcat/Core/Network/WikiModels.swift
Starcat/Shared/Components/RepoWikiMenu.swift
StarcatTests/WikiAPITests.swift
StarcatTests/RepoWikiMenuStateTests.swift
```

计划修改：

```text
Starcat/Core/Network/AppEndpoints.swift
Starcat/Core/Settings/ThirdPartyService.swift
Starcat/App/AppDependencies.swift
Starcat/Shared/Components/RepoDetailScaffold.swift
Starcat/Resources/Localizable.xcstrings
StarcatTests/StarcatAPIKeyTests.swift
docs/功能实现总览.md
docs/7-工具与脚本/Swift-学习索引.md
```

不修改数据库 schema，不新增 SPM 依赖，因此不触发开源致谢新增。

### 4.2 Endpoint 与服务设置

`AppEndpoints` 新增第四个自建后端：

```swift
enum Wiki {
    static let productionURL = URL(string: "https://starcat-wiki-api.fly.dev")!

    @MainActor
    static var baseURL: URL {
        AppEndpoints.resolve(production: productionURL, service: .wiki)
    }

    enum Paths {
        static let status = "/api/v1/wikis"
        static let healthz = "/healthz"
    }
}
```

`ThirdPartyService` 新增 `.wiki`，并补齐：

- 标题、描述、SF Symbol、颜色。
- production URL。
- source repository URL。
- `/healthz` URL。
- 鉴权探测 URL：`/api/v1/wikis`。不带 owner/repo 时有效 key 返回 400，错误 key 返回 401；
  `ServiceHealthChecker` 现有规则会把 400 视为鉴权通过。

设置页无需新增专用 View。`ServicesSettingsTab` 已按 `ThirdPartyService.allCases` 自动渲染 URL、
API Key、重置和测试连接。

### 4.3 WikiAPI

```swift
actor WikiAPI {
    private var baseURL: URL
    private var apiKey: String?
    private let session: URLSession
    private let decoder: JSONDecoder

    init(baseURL: URL, apiKey: String? = nil, session: URLSession? = nil)

    func fetchStatus(owner: String, repo: String) async throws -> [WikiStatusItem]
    func updateBaseURL(_ url: URL)
    func updateAPIKey(_ key: String?)
}
```

约束：

- 实现风格对齐 `TrendingAPI` / `WeeklyAPI`。
- URL 使用 `URLComponents` + `URLQueryItem`，禁止字符串拼 query。
- Bearer header 规则与其他三个自建服务一致。
- 使用 `StarcatEnvelopeDecoder.decode([WikiStatusItem].self, ...)`。
- 首期不暴露 `health()`，健康检查统一由 `ServiceHealthChecker` 负责。
- 首期不实现 `fetchBatch`，避免出现“代码存在但没有正确消费异步语义”的半成品。

### 4.4 DTO 的前向兼容

后端刚从 v1 状态模型切到 v2，客户端不能用脆弱的 raw-value enum 让一个未知值导致整包解码失败。

推荐模型：

```swift
struct WikiStatusItem: Decodable, Sendable, Identifiable {
    let source: WikiSource
    let status: WikiProbeStatus
    let url: URL
    let probeMethod: String?
    let httpStatus: Int?
    let matchedSignals: [String]?

    var id: String { source.rawValue }
}

enum WikiProbeStatus: Sendable, Equatable {
    case indexed
    case notIndexed
    case error
    case unknown(String)
}
```

`WikiProbeStatus` 自定义 `Decodable`，未知值落入 `.unknown(raw)`。`WikiSource` 也应避免未知 source
拖垮整包：可以自定义 unknown case，UI 过滤不认识的 source。

`confidence` 不进入 DTO。该字段已从后端 v2 schema 和 `ProbeResult` 删除。

### 4.5 AppDependencies

```swift
let wikiAPI: WikiAPI
```

初始化与其他 API 同级：

```swift
self.wikiAPI = WikiAPI(
    baseURL: AppEndpoints.Wiki.baseURL,
    apiKey: StarcatAPIKeyResolver.resolve(for: .wiki)
)
```

并在两个热更新 switch 中追加 `.wiki`：

```swift
case .wiki: await wikiAPI.updateBaseURL(target)
case .wiki: await wikiAPI.updateAPIKey(resolved)
```

这里不存在“wiki-api down 导致其他 actor 初始化失败”的问题：actor 构造不发网络请求，也不抛错。
真正的服务隔离发生在请求级，每个 actor 独立持有 URLSession 和状态。

### 4.6 RepoWikiMenu

组件职责：

1. 接收 `repo.owner` / `repo.name`。
2. 从 Environment 获取 `AppDependencies`。
3. `.task(id: repo.fullName)` 调用 `wikiAPI.fetchStatus`。
4. 把结果交给纯函数 `RepoWikiMenuState.make(items:)` 过滤、排序和生成菜单项。
5. 仅当结果非空时渲染 Menu。

建议状态：

```swift
@State private var links: [WikiLink] = []
```

不需要额外 ViewModel。组件只有一次请求和一个数组，单独创建 `@Observable` 类型会增加无收益抽象。

将组件放进 `RepoDetailScaffold.trailingActionsView`。评审已确定 Weekly Issue 必须在最前，
最终顺序契约为：

```text
Weekly: Weekly Issue -> Wiki -> Share -> AI
其他详情页: Wiki -> Share -> AI
```

当前 `RepoDetailAction` 数组已经能识别 `.weeklyIssue`，不需要修改四个调用方的数据模型。
`RepoDetailScaffold` 渲染时把 actions 分成两组：

1. `weeklyIssueActions`：只包含 `.weeklyIssue`，先渲染。
2. `remainingActions`：其余 `.share/.ai/.custom`，在 `RepoWikiMenu` 后渲染。

这样可以保证 Weekly 特有入口始终第一，同时不引入新的 action priority、排序数字或场景枚举。

---

## 5. 请求时序

```text
打开任意 repo 详情页
  -> RepoDetailScaffold 创建 RepoWikiMenu
  -> task(id: repo.fullName)
  -> WikiAPI.fetchStatus(owner, repo)
  -> StarcatEnvelopeDecoder 解码
  -> 过滤 status == indexed
  -> 固定 source 顺序排序
  -> 0 项：隐藏；1~3 项：显示 Wiki Menu
```

切换 repo 时 SwiftUI 会取消旧 task。`URLSession.data(for:)` 支持协作取消，组件不需要自己维护 request token。

---

## 6. 错误处理

| 场景 | 处理 |
|---|---|
| owner/repo 为空 | 本地不发请求 |
| 200 + 合法 envelope | 渲染 indexed 项 |
| 200 + 未知 status/source | 忽略未知项，其他合法项继续展示 |
| 400 | 视为客户端参数 bug，记录 warning，隐藏 |
| 401 | 记录 unauthorized，隐藏；用户在设置页修正 Key |
| 5xx | 记录 server error，隐藏 |
| timeout/offline | 记录 transport error，隐藏 |
| URL 非 http/https 或无 host | 丢弃该 item，禁止打开 |

首期不增加 toast/banner。详情页仍有 GitHub、README 等主路径，Wiki 是增强能力；用全局错误提示打断用户不合适。

---

## 7. 测试方案

### 7.1 客户端单测

`WikiAPITests` 使用 `URLProtocolStub`：

- 请求 method/path/query 正确。
- 有 key 时发送 Bearer header，无 key 时不发送。
- 200 解码三种 source。
- `indexed/not_indexed/error` 解码正确。
- 未知 status/source 不导致整包失败。
- 401、500、非法 JSON 映射到预期错误。
- `updateBaseURL` / `updateAPIKey` 下一次请求立即生效。

`RepoWikiMenuStateTests` 测纯状态转换：

- 只保留 indexed。
- 固定 DeepWiki -> Zread -> Code Wiki 顺序。
- 全 not_indexed/error 返回空。
- 非法 URL 被过滤。
- 单个合法结果仍显示 Menu。

扩展现有测试：

- `StarcatAPIKeyTests` 增加 `.wiki` 默认/自定义/重置覆盖。
- `ThirdPartyService` 相关测试增加 production URL、health URL、auth probe URL。

### 7.2 构建与测试

新增 Swift 文件后：

```bash
xcodegen generate
xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' \
  -only-testing:StarcatTests/WikiAPITests \
  -only-testing:StarcatTests/RepoWikiMenuStateTests test
xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' test
```

按项目约定，跑测前需要关闭 Xcode IDE，避免争抢 `testmanagerd`。

### 7.3 人工验收

由 dong4j 启动 App 验证：

1. Manage、Trending、Weekly、Activity 四类 repo 详情都能出现 Wiki Menu。
2. 未登录、未 Star repo 也可显示。
3. `facebook/react` 等已收录 repo 至少显示一个来源并能打开正确 URL。
4. 全未收录 repo 不显示空 Menu。
5. 设置页 Wiki 服务可改 URL/Key，保存后无需重启即可生效。
6. 错误 Key 时 Wiki 隐藏，但 Trending/Weekly/Sharing 不受影响。

---

## 8. 后端审计债务

这些问题不阻塞首期单查接入，但需要单独处理，不能混入客户端 PR：

| 编号 | 问题 | 影响 |
|---|---|---|
| WIKI-BE-01 | README 说 `error` 对外映射为 `not_indexed`，代码实际会返回 `error` | 契约文档不一致 |
| WIKI-BE-02 | batch 没有 task status，首次异步响应拿不到新结果 | 客户端无法可靠显示批量进度 |
| WIKI-BE-03 | retry 针对单 source 入队，但 `batchProbeAsync` 会重探同 repo 三个 source | 额外外站流量，可能覆盖正常缓存 |
| WIKI-BE-04 | scheduler 的 retry cron 写死 30 分钟，未读取 `RETRY_INTERVAL_MINUTES` | 配置与运行行为不一致 |
| WIKI-BE-05 | admin 两个端点返回 running task，但实际不执行任务 | 容易误判成功 |
| WIKI-BE-06 | probe tests 直接访问公网，不是稳定单元测试 | 离线/CI 网络受限时失败；本次实测 6 个失败 |
| WIKI-BE-07 | `CHANGELOG.md` 只有 v1.0.0，未记录 v2 breaking contract | 版本追踪不完整 |
| WIKI-BE-08 | `createSchema` 又调用 `migrateV2`，与“全新服务不做 migration”约定冲突 | 代码与项目约定不一致 |

建议后续独立提交修复 WIKI-BE-01/03/04/05/06/07/08；batch 客户端能力等 WIKI-BE-02 有明确任务查询契约后再设计。

---

## 9. 实施步骤与验收门槛

评审通过后按以下顺序实施：

1. 网络契约层
   - 新增 endpoint、service case、DTO、WikiAPI。
   - 验证：`WikiAPITests` 通过。
2. 依赖与设置层
   - 装配 `wikiAPI`，补 URL/Key 热更新与设置页元数据。
   - 验证：现有 Services/API key 测试加 `.wiki` 后通过。
3. 详情页 UI
   - 新增 `RepoWikiMenu`，在 `RepoDetailScaffold` 统一挂载。
   - 验证：状态纯函数测试 + 四详情页编译通过。
4. 文档与进度
   - 更新 `docs/7-工具与脚本/Swift-学习索引.md`：`actor`、`.task(id:)`、自定义 `Decodable`、`Menu`。
   - 更新 `docs/功能实现总览.md`：checkbox、实现说明、文件清单、约束/TODO、仪表盘和变更日志。
5. 全量验证
   - `xcodegen generate`。
   - 目标 Suite + 全量单测。
   - dong4j 真机验证四类详情页与浏览器跳转。

**完成定义**：不是“API 能请求成功”，而是四类 repo 详情页都通过统一组件得到一致行为，设置热更新生效，
失败不影响其他服务，自动测试覆盖网络契约和菜单状态转换，工程进度与学习索引同步完成。

### 9.1 实施结果（2026-06-11）

1. 网络契约层已完成：新增 `WikiModels.swift` / `WikiAPI.swift`，只接
   `GET /api/v1/wikis?owner=&repo=`，DTO 对未知 source/status 宽松解码。
2. 依赖与设置层已完成：`ThirdPartyService.wiki`、`AppEndpoints.Wiki`、非 optional
   `AppDependencies.wikiAPI`、URL/API Key 热更新和设置页双阶段健康检查均已接通。
3. 详情页 UI 已完成：`RepoWikiMenu` 统一挂到 `RepoDetailScaffold`；Weekly 固定
   `Weekly Issue -> Wiki -> Share -> AI`，其他详情固定 `Wiki -> Share -> AI`。
4. 自动化覆盖已完成：新增 `WikiAPITests` 6 项、`RepoWikiMenuStateTests` 3 项，并扩展
   `ServiceHealthCheckerTests` / `StarcatAPIKeyTests`；定向运行共 27 项通过。
5. 工程同步与验证已完成：执行 `xcodegen generate`；定向 27 项 / 4 suites 通过；全量
   Swift Testing 415 项 / 59 suites 通过，XCTest 33 项通过（1 项样例生成器按设计跳过）。
   同步更新本设计、Swift 学习索引和功能进度总览。

### 9.2 本地联调修复（2026-06-11）

- Starcat 的 URL/API Key 优先级实现无误：设置页已保存值优先于 production 默认值。
- Wiki 401 并非客户端未发送 Bearer，而是旧 `supports/start-all.sh` 用硬编码 Key 覆盖了
  `supports/starcat-wiki-api/.env`；客户端发送 `.env` 中正确 Key 时，服务白名单却是另一把 Key。
- `start-all.sh` 已删除 API Key、Wiki Key、GitHub Token 硬编码，各服务从自身 `.env` 加载；
  同时改用 `nohup + disown`，健康检查成功后立即返回。
- 设置页 URL 与 API Key 是两行独立保存。仅保存 Key 不会自动保存 URL；若要走本地 Wiki，
  URL 行必须保存 `http://127.0.0.1:5004`。本次排查时持久化配置中尚无 `wiki` URL。
- Trending 客户端 `/api/v1/repos` 与本地 Go 路由一致，本地 scheduler 已抓取 17 条数据；
  页面无数据时应检查 `127.0.0.1:5002` 是否仍在监听，而不是回退旧 `/repo` 路径。

未自动验收的仅剩人工交互：四类详情页实际菜单位置、浏览器跳转、未登录/未 Star 展示、
设置页热更新。按项目约定由 dong4j 启动 App 验证。

### 9.3 RepoWikiMenu「按钮永远不出现」bug 修复（2026-06-12）

**现象**：dong4j 启动 App 进入 `react/react` 详情页（确认本地 wiki 5004 返回 200 +
3 个 indexed、设置页"测试连接"也通过 HTTP 200），但右上角始终看不到 Wiki 菜单。
`log show ... | grep wiki` 也完全没有 `wiki:` 任何字样，意味着 `.task` 闭包根本没跑过。

**根因**：`RepoWikiMenu` 老版 body 写成：

```swift
Group {
    if !links.isEmpty { Menu { ... } ... }
}
.task(id: repo.fullName) { await loadLinks() }
```

初始 `links == []` → Group 内 `if false` → body **退化为 EmptyView**。SwiftUI **不会**
给 EmptyView 调度 `.task` / `.onAppear`（已知坑），形成死锁：

```
links 空 → body 是 EmptyView → .task 不跑 → loadLinks 不跑 → links 永远空
```

跟后端、URL、API Key 完全无关。设置页"测试连接"走的是 `ServiceHealthChecker` actor
+ `/api/v1/ping` 单独路径，不受此 bug 影响，所以能 200。

**修复**：把 `.task` 挪到 `.background { Color.clear }` 上。`.background` 渲染的辅助层
不影响父布局（不占 HStack spacing），但作为 view modifier 总会被求值，`Color.clear`
是真实视图节点，`.task` 必然被调度。视觉效果跟"按需出现"完全一致。

**额外补强**：`loadLinks` 全路径加 `print()` 兜底（`os.Logger` 在 Xcode console 的
`.info` 级别可能被 filter 隐藏，`print` 永远走 stdout 可见），下次再有问题不用先去调
Xcode Debug Area 的 filter 设置。

**教训**：任何形如 `Group { if cond { ... } }.task` / `.onAppear` 的 SwiftUI 代码都要
警惕这个坑 —— 要么保证 if 条件初始为 true，要么用 `.background` / 真实占位承载副作用
modifier。本项目其它类似模式（条件渲染 + 视图副作用）后续遇到都按这个模式处理。

**涉及文件**：`Starcat/Shared/Components/RepoWikiMenu.swift`（v1.1）。
单测 `RepoWikiMenuStateTests` / `WikiAPITests` 9 项全过（这两个 suite 测的是纯函数和
网络层，不依赖 view body 渲染时序，修复未引发回归）。

---

## 10. 已确认决策

dong4j 于 2026-06-11 确认：

1. **权限边界开放**：Wiki 对未登录、未 Star repo 同样可用，因为它是公开阅读能力。
2. **首期只做详情页单查**：不做 batch 预热、source 开关和客户端缓存。
3. **Weekly Issue 必须第一**：Weekly 页面顺序为
   `Weekly Issue -> Wiki -> Share -> AI`；其他详情页为 `Wiki -> Share -> AI`。

以上三项作为客户端实施与验收的固定约束。

---

*最后更新：2026-06-11（客户端实施完成）*
