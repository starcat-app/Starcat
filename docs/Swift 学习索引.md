# Swift 学习索引（dong4j 初学者向）

> **本文档目的**：把 Starcat 代码里**真正用到**的 Swift / SwiftUI / Concurrency / WebKit / GRDB / Foundation 概念，按"分组关键词"形式列出来，配上**项目内代码位置** + **官方文档搜索词**，作为"卡壳时查什么"的入口索引。
>
> **不展开教学**。看到关键词后请：① 跳去 `代码位置` 看 Starcat 里的真实用例 → ② 用 `搜索词` 去 [Apple Developer Docs](https://developer.apple.com/documentation/) 或 [Swift.org Docs](https://docs.swift.org/swift-book/) 查权威说明 → ③ 不懂回来问 AI 协作者。
>
> 创建：2026-05-30 22:30
> 维护原则：项目代码引入新概念时，按所在分组补一条；不重复网上一搜就有的教程。

---

## 1. Swift 语言基础

### 1.1 类型定义

| 关键词 | 在 Starcat 里 | 官方搜索词 |
|---|---|---|
| `struct` | `Repo` / `APIResponse<T>` / `BytesResponse` / `GRDBRepoRepository` | "Swift struct value type" |
| `class` (`final class`) | `ReadmeViewModel` / `HomeViewModel` / `MockGitHubAPIClient` | "Swift reference types classes" |
| `actor` | `GitHubAPIClient`（actor 串行化所有请求） | "Swift actors" |
| `enum`（含关联值） | `NetworkError` / `LoadState` / `ReadmeRefreshResult` / `SidebarItem` | "Swift enumerations associated values" |
| `protocol` | `RepoRepositoryProtocol` / `GitHubAPIClientProtocol` / `GitHubTokenProviding` | "Swift protocols" |
| `extension` | `extension GitHubAPIClient: GitHubAPIClientProtocol {}` / `extension BytesResponse` | "Swift extensions" |
| `typealias` | `URLProtocolStub.Handler` | "Swift typealias" |

### 1.2 属性与可见性

| 关键词 | 用法点 | 注意 |
|---|---|---|
| `let` / `var` | 处处都是 | 优先 `let`，必须可变才用 `var` |
| `private` / `fileprivate` / `internal`(默认) / `public` | `HomeViewModel.repository` 私有依赖 | "Swift access control" |
| `private(set) var` | `HomeViewModel.items / isLoading / loadError`（D-04） | "外部只读，类内可写"——常用于 ViewModel state |
| `static let` | `ReadmeAPI.softTtl` / `AppConstants.*` | "Swift type properties" |
| computed property | `HomeViewModel.selectedRepo` / `LanguageStat.displayName` | "Swift computed property" |
| `lazy var` | 项目里少用 | "Swift lazy stored property" |

### 1.3 控制流

| 关键词 | 用法点 | 注意 |
|---|---|---|
| `guard let` / `if let` | `guard let self else { return }` / `guard let token` | "Swift optional binding" |
| `guard ... else { return }` | race 防护、提前返回 | "Swift guard statement" |
| `if case .updated(let r) = result` | 解构 enum 关联值 | "Swift if case let pattern" |
| `switch` + pattern matching | `switch http.statusCode` 各状态码分支 | "Swift switch statement" |
| `defer` | `HomeViewModel` 旧版用过（D-05 已删） | "Swift defer statement" |

### 1.4 错误处理

| 关键词 | 用法点 | 注意 |
|---|---|---|
| `throws` / `rethrows` | `repository.fetchAllStarred() throws` | "Swift error handling" |
| `try` / `try?` / `try!` | `try?` 静默吞错（`try? await repository.delete(...)`） | "Swift try expressions" |
| `do { try ... } catch { ... }` | 单测 `do-catch NetworkError.case` 模式 | "Swift error catching" |
| `catch SomeError.case` | 精确 catch 某个 case，再 rethrow | "Swift specific error catching" |
| `Result<Success, Failure>` | `HomeViewModel.reloadItems` 用 `Result<[Repo], Error>` 延迟 throw | "Swift Result type" |

### 1.5 泛型

| 关键词 | 用法点 | 注意 |
|---|---|---|
| `<T: Decodable>` | `GitHubAPIClient.get<T>(...)` | "Swift generic functions where clause" |
| `any` / `some` | `any GitHubAPIClientProtocol`（D-02 存在性类型） | "Swift any vs some keyword Swift 5.7+" |
| `Self` | `extension RateLimitInfo { static var empty: RateLimitInfo }` | "Swift Self type" |
| `Sendable` 约束 | `protocol GitHubAPIClientProtocol: Sendable` | "Swift Sendable protocol" |

### 1.6 闭包

| 关键词 | 用法点 | 注意 |
|---|---|---|
| `Task { [weak self] in ... }` | `HomeViewModel.reloadItems` / `ReadmeViewModel.loadInternal` | "Swift closure capture list weak" |
| `[makeResponse] request in ...`（**坑**） | 已废弃用法（capture list 丢 default value，被 D-14 反过来踩过） | 函数捕获在闭包里默认参数失效 → 改用 file-level free function（`httpResponse(...)`） |
| `@escaping` / `@Sendable` 闭包 | `URLProtocolStub.Handler` 是 `@Sendable` | "Swift escaping closures Sendable" |
| trailing closure | `try await writer.read { db in ... }` | "Swift trailing closure syntax" |

### 1.7 字符串与字节

| 关键词 | 用法点 | 注意 |
|---|---|---|
| `String` / `Substring` | `ReadmeWebView.rewriteOneAssetURL` 用 `Substring` 切前缀 | "Swift Substring memory" |
| `Data` ↔ `String` | `String(data: data, encoding: .utf8)` | "Foundation Data encoding" |
| `NSString` interop | `ReadmeWebView.rewriteAssetURLs` 正则要 NSRange | "Swift String NSString bridging" |
| `NSRegularExpression` | 同上 | "Foundation NSRegularExpression" |

---

## 2. Swift Concurrency（Swift 5.5+，**项目重度使用**）

| 关键词 | 用法点 | 官方搜索词 |
|---|---|---|
| `async` / `await` | 所有 IO 方法（`fetchAllStarred` / `readmeHTML` / `getBytes`） | "Swift async await" |
| `Task { ... }` | `Task { [weak self] in ... }` | "Swift Task initializer" |
| `Task.cancel()` / `Task.isCancelled` | `HomeViewModel.currentReloadTask?.cancel()`（D-05 race 防护） | "Swift Task cancellation" |
| `Task.checkCancellation()` | 项目里少用，更多用 `guard !Task.isCancelled` | "Swift Task checkCancellation" |
| `Task<Void, Never>` | `private var currentTask: Task<Void, Never>?` | "Swift Task generic parameters" |
| `async let` | `HomeViewModel.refreshSidebar` 并行起 3 个查询 | "Swift async let concurrency" |
| `withTaskGroup` | 项目里未用，未来批量场景会引入 | "Swift TaskGroup" |
| `@MainActor` | `ReadmeViewModel` / `HomeViewModel` / `AppDependencies` / `Coordinator` | "Swift MainActor" |
| `actor` | `GitHubAPIClient` | "Swift actors data race" |
| `nonisolated` / `nonisolated(unsafe)` | `URLProtocolStub` 静态可变属性 | "Swift nonisolated keyword" |
| `Sendable` / `@Sendable` / `@unchecked Sendable` | `final class URLProtocolStub: URLProtocol, @unchecked Sendable` | "Swift Sendable types concurrency" |
| `CancellationError` | `catch is CancellationError` in `GitHubAPIClient.perform<T>` | "Swift CancellationError" |
| `SWIFT_STRICT_CONCURRENCY` | 本项目 = `minimal`（见 `project.yml`） | "Xcode SWIFT_STRICT_CONCURRENCY build setting" |

---

## 3. SwiftUI（macOS 15+）

### 3.1 View 与状态

| 关键词 | 用法点 | 搜索词 |
|---|---|---|
| `View` / `body` | 所有 `*View.swift` | "SwiftUI View protocol body" |
| `@Observable` | `HomeViewModel` / `ReadmeViewModel` / `AppDependencies`（Observation framework，macOS 14+） | "Observation framework Swift 5.9 macros" |
| `@State` | `HomeView` 持有 `ReadmeViewModel` | "SwiftUI State property wrapper" |
| `@Binding` | `$vm.selectedRepoID` 传给子 View | "SwiftUI Binding two-way" |
| `@Environment(\.colorScheme)` | `ReadmeWebView` 切深浅色 | "SwiftUI Environment values" |
| `@Environment(\.accessibilityReduceMotion)` | `RepoRowSurface` 尊重系统"减少动态效果"设置，关闭非必要缩放/动画 | "SwiftUI accessibilityReduceMotion" |
| `.environment(_:)` | `AppDependencies` 注入到 View 树 | "SwiftUI environment object injection" |
| `@Bindable` | Observation 框架配套，传 binding 给 child | "Swift Bindable property wrapper" |

### 3.2 容器与导航

| 关键词 | 用法点 | 搜索词 |
|---|---|---|
| `NavigationSplitView` | `HomeView` 三栏布局 | "SwiftUI NavigationSplitView macOS" |
| `NavigationSplitViewVisibility` | `HomeView` 显式持有三栏可见性；启动时重置 `.all`，避免上次窄窗口导致 sidebar 折叠态污染下一次启动 | "SwiftUI NavigationSplitViewVisibility" |
| `List(selection:)` | 中栏多选 repo 列表；普通单选已改用 plain `Button` 手动写 `selectedRepoID` 以避开系统蓝色选中底色 | "SwiftUI List selection binding macOS" |
| `Button` + `.buttonStyle(.plain)` | 普通 repo 行点击选择；使用后必须跟 `.focusEffectDisabled()` | "SwiftUI plain button macOS focusEffectDisabled" |
| `ForEach(items)` | 配 `Identifiable` 自动 id 匹配 | "SwiftUI ForEach Identifiable" |
| `Section` / `DisclosureGroup` | Sidebar 分组 | "SwiftUI Section List sidebar" |
| `.listRowBackground` / `.listRowSeparator` | `RepoListView` 清掉系统 row 背景 / 分割线，让 `RepoRowView` 自己表达卡片选中态 | "SwiftUI listRowBackground listRowSeparator macOS" |
| `GeometryReader` | `LayoutDebugOverlay` 的 SwiftUI fallback；真实窗口尺寸已改由 `NSViewRepresentable` 读取 `NSWindow.contentView.bounds`，避免 NavigationSplitView 折叠 sidebar 后误读局部容器 | "SwiftUI GeometryReader proxy size" |

### 3.3 修饰符

| 关键词 | 用法点 | 搜索词 |
|---|---|---|
| `.task(id:)` | View 出现时拉数据，id 变化时重跑 | "SwiftUI task modifier id" |
| `.onChange(of:)` | `HomeView.onChange(selectedRepoID)` 驱动 ReadmeViewModel | "SwiftUI onChange iOS 17" |
| `.onAppear` | `ListRowRevealModifier` 利用 List 懒创建，在 Manage / Trending row 进入可视区域时触发渐进式入场 | "SwiftUI onAppear List row lazy loading" |
| `.toolbar` / `ToolbarItem` | 顶栏同步、状态、排序、多选按钮；搜索入口已改用系统 `.searchable(..., placement: .toolbar)`，避免混入 `primaryAction` 按钮组 | "SwiftUI toolbar ToolbarItem primaryAction macOS" |
| `.searchable(text:placement:prompt:)` | `RepoListView` 右上角 Finder 风格系统搜索入口，绑定 `HomeViewModel.searchQuery` | "SwiftUI searchable placement toolbar macOS" |
| `.confirmationDialog` / `.alert` | 取消 Star 确认（W4 待做） | "SwiftUI confirmationDialog macOS" |
| `.transition` / `.animation(_:value:)` | `RepoListView` / `TrendingView` 中栏内容切换用整块轻过渡；自定义动效需尊重 `accessibilityReduceMotion` | "SwiftUI transition animation value accessibilityReduceMotion" |
| `.onHover` | `RepoRowSurface` 鼠标悬停时增强背景 / 边框，是 macOS 指针体验的基础反馈 | "SwiftUI onHover macOS" |
| `.allowsHitTesting(false)` | `LayoutDebugOverlay` 调试胶囊不拦截下方鼠标事件，覆盖层标准配置 | "SwiftUI allowsHitTesting" |
| `.overlay(alignment:)` | `HomeView` 用 `.overlay(alignment: .topTrailing)` 在右上角接入 `LayoutDebugOverlay` —— overlay 不影响下方视图的布局，仅"覆盖"绘制，是调试视图 / Toast / 角标的标配 | "SwiftUI overlay alignment" |
| `ViewModifier` | `ListRowRevealModifier` 抽取 row 渐进式入场，避免把动画状态散落在业务 row 中 | "SwiftUI custom ViewModifier" |
| `@ViewBuilder` | `RepoRowSurface` 用 builder 接收 compact / card 两套 row 内容，复用同一视觉容器 | "SwiftUI ViewBuilder custom container" |
| `LocalizedStringKey` vs `String` | `AboutView` / `RepoListView` / `SidebarView` / `SettingsView` 等用户可见文案：静态 key 用 `LocalizedStringKey`，动态仓库名、标签名、URL 用 `Text(verbatim:)` 或先 `String(localized:)`，否则 `Text(titleString)` / `.help(titleString)` 会把 key 当普通文本显示 | "SwiftUI LocalizedStringKey Text String variable String localized" |

### 3.4 跨 AppKit 桥接

| 关键词 | 用法点 | 搜索词 |
|---|---|---|
| `NSViewRepresentable` | `ReadmeWebView` 包装 `WKWebView`；`ToolbarSearchFocusRingDisabler` 放置不可见 AppKit 探针修正系统 toolbar search field | "SwiftUI NSViewRepresentable" |
| `Coordinator` 模式 | `ReadmeWebView.Coordinator` 持有 delegate | "NSViewRepresentable Coordinator" |
| `makeNSView` / `updateNSView` | 同上 | "NSViewRepresentable lifecycle" |
| `NSView` → `NSWindow` 桥接 | `MainWindowFrameModifier` 通过不可见 NSView 拿主窗口 | "SwiftUI access NSWindow from NSViewRepresentable" |
| `NSHostingController` | `AboutWindowController` 把 `AboutView` 嵌进 AppKit `NSWindow` | "NSHostingController SwiftUI AppKit" |
| `NSSearchField.focusRingType` | `RepoListView.ToolbarSearchFocusRingDisabler` 禁用系统搜索框外层蓝色 focus ring | "NSSearchField focusRingType NSFocusRingType" |

---

## 4. WebKit（macOS）

| 关键词 | 用法点 | 搜索词 |
|---|---|---|
| `WKWebView` | `ReadmeWebView` | "WKWebView macOS overview" |
| `WKWebViewConfiguration` / `WKPreferences` / `WKWebpagePreferences` | 同上，关 JS | "WKWebView allowsContentJavaScript" |
| `WKNavigationDelegate` | `ReadmeWebView.Coordinator` | "WKNavigationDelegate" |
| `decidePolicyFor navigationAction` | 拦截链接 / 主框架 reload | "WKNavigationActionPolicy decidePolicy" |
| `WKNavigationAction.navigationType == .linkActivated` | 区分用户点链接 vs 程序加载 | "WKNavigationType cases" |
| `loadHTMLString(_:baseURL:)` | 加载 README HTML 片段 | "WKWebView loadHTMLString baseURL" |
| `webView.reload()` 的副作用 | 触发 baseURL 真实请求（**坑**，见 `ReadmeWebView` 第 232-256 行注释） | "WKWebView reload behavior" |
| WebContent 进程 + Sandbox 噪音 | `Failed to change to usage state 2` 等无害 log | "WKWebView WebContent process sandbox logs" |

---

## 5. URLSession / 网络

| 关键词 | 用法点 | 搜索词 |
|---|---|---|
| `URLSession` / `URLSession.shared` | `GitHubAPIClient` 注入 | "URLSession overview" |
| `URLSessionConfiguration.ephemeral` | `URLProtocolStub.ephemeralSession()` 测试用 | "URLSessionConfiguration ephemeral" |
| `URLRequest` | `buildRequest(...)` | "URLRequest httpMethod allHTTPHeaderFields" |
| `HTTPURLResponse` | `response as? HTTPURLResponse` | "HTTPURLResponse statusCode headerFields" |
| `URLComponents` / `URLQueryItem` | `buildRequest` 拼 query | "URLComponents URLQueryItem" |
| `URLProtocol`（自定义子类） | `URLProtocolStub`（D-14 测试基石） | "URLProtocol subclass URLSession testing" |
| `URLProtocol.canInit / startLoading / stopLoading` | 同上 | "URLProtocol lifecycle methods" |
| `URLProtocolClient` | `client?.urlProtocol(...)` 回调 | "URLProtocolClient delegate" |
| `URLError` / `NSURLErrorCancelled` (-999) | 错误码识别 | "URLError NSURLErrorDomain codes" |
| Headers: `If-None-Match` / `ETag` | 条件请求 + 304 命中 | "HTTP conditional GET ETag" |
| Headers: `If-Modified-Since` / `Last-Modified` | 同上 | "HTTP Last-Modified header" |
| Headers: `Link` (RFC 5988) | GitHub 分页 next/last/prev | `RFC 5988 web linking` |
| Headers: `Authorization: Bearer ...` | `request.setValue("Bearer \(token)", forHTTPHeaderField:)` | "HTTP Bearer token authentication" |
| Headers: `Accept: application/vnd.github.html` | README HTML 端点 | "GitHub API media types vnd.github" |

---

## 6. Foundation / 时间日期

| 关键词 | 用法点 | 搜索词 |
|---|---|---|
| `Date` / `TimeInterval` | `static let softTtl: TimeInterval = 6 * 3600` | "Foundation Date TimeInterval" |
| `ISO8601DateFormatter` | `ISO8601DateFormatter.shared`（项目自定义共享实例） | "ISO8601DateFormatter formatOptions" |
| `withInternetDateTime + withFractionalSeconds` | 同上 | "ISO8601DateFormatter Options" |
| `Calendar` / `DateComponents` | 项目里少用 | "Foundation Calendar dateComponents" |

---

## 7. JSON / Codable

| 关键词 | 用法点 | 搜索词 |
|---|---|---|
| `Codable` / `Decodable` / `Encodable` | 所有 DTO（`StarredRepoDTO` / `GitHubUserDTO`） | "Swift Codable encoding decoding" |
| `JSONDecoder` / `JSONEncoder` | `GitHubAPIClient.decoder` | "Foundation JSONDecoder JSONEncoder" |
| `keyDecodingStrategy = .convertFromSnakeCase` | GitHub 返回 snake_case → DTO 用 camelCase | "JSONDecoder convertFromSnakeCase" |
| `JSONSerialization` | `extractErrorMessage` 解错误体 | "Foundation JSONSerialization" |
| `CodingKeys` enum | DTO 内自定义字段映射时用 | "Swift CodingKeys custom" |

---

## 8. GRDB（SQLite）

| 关键词 | 用法点 | 搜索词 |
|---|---|---|
| `DatabasePool` / `DatabaseWriter` | `DatabaseManager` | "GRDB DatabasePool concurrency" |
| `Record` / `MutablePersistableRecord` / `FetchableRecord` / `TableRecord` | `Repo` / `Readme` / `LanguageStat` | "GRDB record protocols" |
| `db.read { db in ... }` / `db.write { db in ... }` | `GRDBRepoRepository` 所有方法 | "GRDB read write closure" |
| `Column` / `.filter` / `.order` / `.limit` / `.fetchAll` / `.fetchOne` | QueryInterface | "GRDB query interface" |
| `db.execute(sql:arguments:)` | 写裸 SQL（多表 JOIN / IN 占位符） | "GRDB execute raw SQL StatementArguments" |
| `StatementArguments` | 同上，参数化 | "GRDB StatementArguments" |
| `upsert(_ db:)` | `ReadmeRepository.upsert` | "GRDB upsert mutating" |
| `Migration` / `DatabaseMigrator` | `DatabaseMigrationsV1` | "GRDB DatabaseMigrator" |
| FTS5 全文搜索 | `repos_fts MATCH ?` | "GRDB FTS5 full text search" |
| Triggers / `CREATE TRIGGER` | Migration v1 里同步 repos ↔ repos_fts | "SQLite triggers FTS" |

---

## 9. Swift Testing（**项目用的新框架，不是 XCTest**）

| 关键词 | 用法点 | 搜索词 |
|---|---|---|
| `import Testing` | 所有 `StarcatTests/*Tests.swift` | "Swift Testing framework Xcode 16" |
| `@Suite("名称")` | `@Suite("GitHubAPIClient 网络路径分支", .serialized)` | "Swift Testing Suite trait" |
| `@Test("描述")` | 每个测试用例 | "Swift Testing Test macro" |
| `#expect(condition)` | 主断言 | "Swift Testing expect macro" |
| `#require(optional)` | 解 optional 失败即停 | "Swift Testing require macro" |
| `Issue.record("msg")` | 主动记一笔 fail | "Swift Testing Issue record" |
| `.serialized` trait | Suite 内 test 串行执行（避免共享静态状态） | "Swift Testing serialized trait" |
| `@testable import Starcat` | 测试访问 `internal` 符号 | "Swift testable import attribute" |
| vs XCTest 的差异 | 更声明式、宏驱动；并行默认；`#expect` vs `XCTAssert*` | "Swift Testing migrate from XCTest" |

---

## 10. macOS 系统集成

| 关键词 | 用法点 | 搜索词 |
|---|---|---|
| `NSWorkspace.shared.open(url)` | `ReadmeWebView.Coordinator` 把外链跳系统浏览器 | "NSWorkspace open URL" |
| `NSWindowController` | `AboutWindowController` 管理单例关于窗口，重复 Cmd+I 复用同一个窗口 | "NSWindowController showWindow" |
| `NSWindow.setFrameAutosaveName` | `MainWindowFrameModifier` 保存 / 恢复主窗口尺寸与位置 | "NSWindow setFrameAutosaveName setFrameUsingName" |
| `NSWindow.contentMinSize` / `minSize` | `MainWindowFrameModifier` 设置主窗口硬下限：启动默认和运行期硬下限统一为 1440×763；不做 sidebar 展开时主动扩窗，也不做动态 minSize，直接让用户拖拽停在稳定宽度 | "NSWindow contentMinSize minSize setFrame" |
| Keychain | `KeychainManager`（**有 DEBUG 临时 fallback，D-16 待还**） | "Keychain Services API macOS" |
| App Sandbox / Entitlements | `Starcat.entitlements` | "App Sandbox macOS entitlements" |
| `NSBackgroundActivityScheduler` | W6 Release 轮询会用 | "NSBackgroundActivityScheduler macOS" |
| `os.Logger` / `os_log` | 项目自包装为 `AppLog.*`（见 `Core/Logging/AppLog.swift`） | "Apple Unified Logging Logger" |
| `OS_ACTIVITY_MODE=disable` 环境变量 | 屏蔽系统 os_log 噪音的开发期技巧 | "Xcode scheme environment variables OS_ACTIVITY_MODE" |
| `UserDefaults` | `AppSettings`（产品级用户偏好，`@Observable` 包装）/ `MainWindowFrameModifier`（间接经 `NSWindow.setFrameAutosaveName`）/ `DebugFlags`（debug-only 开关）。本质是个自动持久化的 plist 文件，路径 `~/Library/Containers/<bundle-id>/Data/Library/Preferences/<bundle-id>.plist` | "Foundation UserDefaults overview" |
| "Command-line preferences" | Apple 内置约定：**Xcode Scheme launch args `-Key Value` 自动注册到 `UserDefaults.standard`**。`DebugFlags` 利用这点，不写一行解析代码就能用 Scheme 切调试开关。详见 `docs/调试工具.md` §1.1 | "NSUserDefaults command-line preferences" |
| `defaults` 命令 | macOS shell 命令，操作 UserDefaults plist。如 `defaults write com.starcat.app DebugLayoutOverlay -bool YES` | "macOS defaults command" |

---

## 11. Xcode / 工程配置

| 关键词 | 用法点 | 搜索词 |
|---|---|---|
| `.xcodeproj` / `.pbxproj` | 项目用 `xcodegen` 生成，**`.gitignore` 忽略 `Starcat.xcodeproj/`** | "xcodegen project.yml generate" |
| `project.yml` | xcodegen 配置入口（`sources: path: Starcat` 全扫描） | "xcodegen sources options" |
| Build Phases / Build Settings | 一般 xcodegen 管理；手改前先看 `project.yml` | "Xcode Build Phases overview" |
| Schemes | Run / Test / Profile / Archive | "Xcode Schemes overview" |
| Scheme → Arguments → Arguments Passed On Launch | 给 App 传命令行参数；`-Key Value` 形式会自动进 UserDefaults。`DebugFlags` 用这个开调试 overlay，详见 `docs/调试工具.md` §3.1 | "Xcode scheme arguments launch" |
| `#if DEBUG` 条件编译 | `DebugFlags`（Release 硬关调试开关） + `KeychainManager` 历史 DEBUG fallback 块 | "Swift conditional compilation DEBUG" |
| `xcodebuild -scheme Starcat -destination 'platform=macOS' test` | CLI 跑测试 | "xcodebuild test command line" |

---

## 12. 项目内自定义类型（**先看这些，理解上下文最快**）

| 类型 | 文件 | 干什么 |
|---|---|---|
| `AppLog` | `Core/Logging/AppLog.swift` | 项目自封装的 Logger 入口（`.network` / `.database` / `.ui` / `.sync` / `.auth` 等 category） |
| `AppConstants` | `Core/Constants/AppConstants.swift` | 全局常量（baseURL / userAgent / OAuth client id 等） |
| `NetworkError` | `Core/Network/NetworkError.swift` | 所有网络错误的统一 enum（**不是 Equatable**，断言走 do-catch） |
| `BytesResponse` / `APIResponse<T>` | `Core/Network/GitHubAPI/GitHubAPIClient.swift` | 网络响应包装（含 ETag / RateLimit / Link） |
| `RateLimitInfo` / `LinkHeader` | 同目录 | 头解析专用 struct |
| `AppDependencies` | `App/AppDependencies.swift` | 依赖容器，组装所有 service / repository |
| `DatabaseManaging` | `Core/Database/DatabaseManager.swift` | GRDB writer 抽象协议，便于内存测试 |
| `RepoRepositoryProtocol` / `GitHubAPIClientProtocol` | D-01 / D-02 引入 | 业务抽象层，单测用 Mock 替换 |
| `URLProtocolStub` / `MockGitHubAPIClient` | `StarcatTests/` | D-14 测试基础设施 |
| `DebugFlags` | `Shared/Utilities/DebugFlags.swift` | 所有 debug-only 开关的中央枚举；`#if DEBUG` + UserDefaults 双保险（Release 包硬关）。新增调试能力一律加在这里，不允许散落 |
| `LayoutDebugOverlay` | `Shared/Components/LayoutDebugOverlay.swift` | 第一个调试视图：`NSViewRepresentable` 读 `NSWindow.contentView.bounds` + 右上角 `regularMaterial` 胶囊显示 `W × H`，受 `DebugFlags.layoutOverlay` 控制 |

---

## 13. 推荐阅读路径（按"现在卡在哪儿"分组）

| 你正在卡的问题 | 先看这条 |
|---|---|
| "什么是 @Observable，跟 @State 啥区别？" | §3.1 关键词 → Observation framework 文档 |
| "actor 和 class 区别？" | §1.1 + §2 → "Swift actors data race" |
| "Task cancel 怎么生效？" | §2 `Task.cancel()` → 看 `HomeViewModel.reloadItems` 第 122-185 行 |
| "为什么协议都要 Sendable？" | §1.5 + §2 → "Swift Sendable concurrency checking" |
| "any vs some 哪个用哪个？" | §1.5 `any/some` → Swift Evolution SE-0335 |
| "GRDB 怎么写 JOIN？" | §8 `db.execute(sql:)` + 看 `GRDBRepoRepository.fetchUntagged` 第 145-156 行 |
| "WKWebView 怎么禁掉 reload？" | §4 + 看 `ReadmeWebView.Coordinator` 第 232-256 行注释 |
| "URLProtocol 是什么巫术？" | §5 + 读 `URLProtocolStub.swift` 全文（顶部注释 + override 三方法） |
| "Swift Testing vs XCTest？" | §9 → Apple WWDC 2024 "Meet Swift Testing" |
| "什么是 capture list 丢 default value？" | §1.6 + 看 `GitHubAPIClientTests.swift` 第 24-39 行（解决方案是用 file-level free function） |
| "Swift 怎么读配置文件 / 调试开关怎么加？" | §10 `UserDefaults` / "Command-line preferences" + §11 launch arguments → **完整使用指南见 `docs/调试工具.md`**（A/B/C 三种切换方式 + 双保险 + 新增 SOP） |

---

*维护原则：项目代码用到某个**新**概念时，按上面分组追加一行；不展开教学；只列"代码位置 + 官方搜索词"两个查询入口。*
