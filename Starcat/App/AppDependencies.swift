//
//  AppDependencies.swift
//  Starcat
//
//  应用级依赖容器。
//
//  按"开发前问题清单 5.3"决议：Environment + Protocol，不引第三方 DI 库。
//  本类负责组装：API 客户端 + OAuth Service + AuthSession + SyncManager
//
//  生产 vs Mock 切换：
//  - 编译期通过 `STARCAT_USE_MOCK_OAUTH` 标志（在 Build Settings 中定义，或 Constants 中切换）
//  - 此处用一个静态布尔；DEBUG 编译默认 true，RELEASE 强制 false
//  - 注：要"立刻试 Device Flow"时把 useMockOAuth 改为 false 即可
//

import Foundation

@MainActor
@Observable
final class AppDependencies {

    // MARK: - 配置

    /// 是否使用 Mock OAuth Service。
    /// 已获得真实 Client ID（见 Constants.githubOAuthClientID），全模式走真实 Device Flow。
    /// 需要回到 Mock 跑离线 UI 调试时，临时改为 true 即可。
    static let useMockOAuth: Bool = false

    // MARK: - 依赖实例（顺序敏感）

    let database: any DatabaseManaging
    /// D-02：注入类型从 actor 改为协议，便于 Preview / 测试替换为 Mock。
    let apiClient: any GitHubAPIClientProtocol
    let oauthService: any GithubOAuthServiceProtocol
    let authSession: AuthSession
    let syncManager: SyncManager
    /// Week 3 引入：HomeView 在初始化时需要复用这个 repository 构建 ViewModel。
    /// D-01：注入类型从 struct 改为协议，便于测试替换为 Mock。
    let repoRepository: any RepoRepositoryProtocol
    /// Week 3 引入：用户偏好（列表密度等）。
    let settings: AppSettings
    /// StoreKit 2 订阅协调器。它是 Pro 权益的单一真相源。
    let subscriptionManager: SubscriptionManager
    /// 统一 Pro 门控服务。业务层通过它判断是否放行，而不是直接读 `settings.isProUser`。
    let entitlementGate: EntitlementGate
    /// 本机 MCP Service。Pro 用户可开启，让本机 Agent 通过 MCP 读取 Starcat 上下文。
    let mcpService: StarcatMCPService
    /// Week 4 引入：README 缓存 Repository。
    let readmeRepository: ReadmeRepository
    /// Week 4 引入：README HTML 抓取 + 缓存协调。
    let readmeAPI: ReadmeAPI
    /// HOM-201 P0-2（2026-06-14）：README "已知不存在" 共享会话状态。
    ///
    /// 由所有 `ReadmeViewModel`（manage 全局 VM + active/weekly 各 Shell 局部 VM）
    /// 共用同一实例，让"manage 命中 404 → 切到 active 看同 repo"等跨场景路径
    /// 短路掉重复的 GitHub 请求。详见 `ReadmeAvailability.swift`。
    let readmeAvailability: ReadmeAvailability
    /// HOM-201 P0-3（2026-06-14）：README 网络刷新 in-flight 去重器。
    ///
    /// 注入到 `ReadmeAPI`，让同 `repo.id` / `owner/repo` 的并发 refresh 请求
    /// 合并为一个 Task，多个 ViewModel（manage / active / weekly 等）同时请求
    /// 时只发一次 GitHub。详见 `ReadmeInflightTracker.swift`。
    let readmeInflightTracker: ReadmeInflightTracker
    /// HOM-201 P2-3（2026-06-14）：README 缓存命中 / 刷新结果计数器。
    ///
    /// 进程级,SWR 状态机所有终态(cachedHit / refresh-200 / 304 / 404 / failed)
    /// 都在 `ReadmeAPI` 内 record;Settings 调试段 / AppLog 周期 flush 都可以读
    /// `snapshot()` 拿当前累计值。详见 `ReadmeMetrics.swift`。
    let readmeMetrics: ReadmeMetrics
    /// W4 Batch A1 引入：标签 CRUD。
    let tagRepository: any TagRepositoryProtocol
    /// W4 Batch A1 引入：repo ↔ tag 关联 + 批量打标签。
    let repoTagRepository: any RepoTagRepositoryProtocol
    /// GitHub Stars List 本地缓存。
    let githubStarListRepository: any GitHubStarListRepositoryProtocol
    /// GitHub Stars List 远端同步与 mutation 协调服务。
    let githubStarListSyncService: GitHubStarListSyncService
    /// W4 Batch A1 引入：repo 笔记 + 状态管理（同表合并）。
    let repoNoteRepository: any RepoNoteRepositoryProtocol
    /// 搜索浮层 `⌘K` 的关键词历史 Repository（GRDB SQLite，CloudKit-ready 字段已就绪，W5 同步接入）。
    let searchHistoryRepository: any SearchHistoryRepositoryProtocol
    /// 用户自定义智能集合 Repository。内置集合不入库，只有用户保存的规则在这里。
    let smartCollectionRepository: any SmartCollectionRepositoryProtocol
    /// W6 AI：repo embedding SQLite 缓存。
    let repoEmbeddingRepository: any RepoEmbeddingRepositoryProtocol
    /// W6 AI：语义搜索服务，使用 BYOK 设置 + SQLite 向量缓存。
    let semanticSearchService: SemanticSearchService
    /// 2026-06-12 向量索引改进：后台慢速预拉 + 全量重建服务（Settings 触发）。
    let semanticIndexBuilder: SemanticIndexBuilder
    /// W6 AI：单仓 AI 摘要缓存。
    let aiSummaryRepository: any AISummaryRepositoryProtocol
    /// W6 AI：单仓 AI 摘要与标签推荐服务。
    let repoAIInsightService: RepoAIInsightService
    /// AI 对话历史磁盘存储。由依赖容器显式装配，避免 ViewModel 默认参数读取 MainActor 单例。
    let diskChatHistoryStore: DiskChatHistoryStore

    /// HOM-52：批量未分类仓库 AI 整理队列服务（会话级单例）。
    ///
    /// 单例理由：同时只允许跑一批整理任务，避免 AI 配额尖刺，且 panel/banner 多处订阅
    /// 同一份状态。装在 AppDependencies 让 HomeView 通过 environment 注入到 RepoListView /
    /// BatchAIQueuePanel / BatchAIUntaggedBanner，无需多余的 @State 传参。
    let batchAIQueueService: BatchAIQueueService

    /// HOM-126：自动后台 AI 整理调度器（会话级单例）。
    ///
    /// 依赖装配顺序：必须晚于 settings / repoRepository / batchAIQueueService / syncManager。
    /// HomeView 在 `.task` 里 `scheduler.start()` 启动，让"启动后 60s 触发"以 HomeView
    /// 进入后开始计时；不在 init 里 start 是因为 AppDependencies 在 `@main` init 阶段
    /// 构造，那时 SwiftUI scene 还没装好，过早启动延迟意义不大且更难追踪。
    let autoTidyScheduler: AutoTidyScheduler

    // MARK: - HOM-68 README 翻译

    /// README AI 翻译缓存 Repository。
    let readmeTranslationRepository: any ReadmeTranslationRepositoryProtocol
    /// README AI 翻译服务（AI 调用 + 缓存协调）。
    let readmeTranslationService: ReadmeTranslationService

    /// HOM-54 引入：GitHub Trending 数据仓库。
    let trendingRepository: any TrendingRepositoryProtocol
    /// W7+ 引入：Trending README 持久化（与 manage 路径独立的 `trending_readmes` 表）。
    let trendingReadmeRepository: TrendingReadmeRepository
    /// HOM-54 内部 API actor，2026-06-08 起从 `TrendingRepository` 提到顶层暴露，
    /// 让设置页 → 服务 Tab 改地址后可以直接 `await trendingAPI.updateBaseURL(_:)` 热更新。
    let trendingAPI: TrendingAPI

    /// 2026-06-11 dong4j：trending sidebar 语言列表的状态容器。
    ///
    /// 启动 / 用户切到 trending 时由 HomeView `.task` 触发 `reload()` 拉一次后端聚合数据；
    /// SidebarView 通过 environment 读取 `displayList` 渲染语言行。
    /// 后端返空 / 不可达时 store 内部退化到 fallbackList，sidebar 始终能展示一组入口。
    let trendingLanguageStore: TrendingLanguageStore

    /// 第三方后端服务健康检查 actor（2026-06-08）。
    /// 设置页"测试连接"按钮 → `await serviceHealthChecker.check(service:baseURL:)`。
    /// 独立 actor + 短超时（5s），不复用业务 API session。
    let serviceHealthChecker: ServiceHealthChecker
    /// 状态栏五个自建 API 的 `/healthz` 可用性巡检。
    /// 与 `serviceHealthChecker` 分开：前者只判断后端进程是否在线，后者校验 URL + API Key。
    let serviceAvailabilityMonitor: ServiceAvailabilityMonitor

    // MARK: - MUL-176 Weekly（阮一峰周刊）

    /// 阮一峰周刊后端 API 客户端。
    /// 独立 actor，无需 GitHub OAuth；Activity 页 `weekly` 分类直接消费。
    let weeklyAPI: WeeklyAPI

    /// Weekly UI 共享状态：sidebar 计数徽章 + HomeView 详情页路由共用。
    /// 详见 `WeeklySelectionService` 文件头注释。
    let weeklySelectionService: WeeklySelectionService

    /// Activity 本地分类计数：只复用 ActivityViewModel 已加载的内存快照，不触发额外 IO。
    let activityCategoryCountService: ActivityCategoryCountService

    /// Sidebar 装饰动画与 Activity 切分类的协调（仅头像 tint；草坪不参与）。
    let sidebarAnimationCoordinator: SidebarAnimationCoordinator

    /// Weekly 三源聚合语言筛选 Store。首次进入 Weekly 时懒加载。
    let weeklyLanguageStore: WeeklyLanguageStore

    /// R-06.4 客户端 bulk 缓存仓库：一次性拉全量 weekly 聚合数据 + 落 SQLite，让
    /// `WeeklyContentViewModel` 走"渐进式 SWR 双轨制"——首次入场拉 remote 出图 + 后台
    /// bulkSync 落盘，后续 sort/lang 切换走本地缓存零网络。
    let weeklyBulkRepository: WeeklyBulkRepository

    // MARK: - HOM-173 分享卡

    /// AI 分享卡后端 API 客户端。
    ///
    /// 2026-06-08 之前是在 `RepoMetadataHeaderView.shareRepo()` 里每次分享 new 一个
    /// `ShareAPI()`——既无法注入测试 mock，也没法与 trending / weekly 共享同一份"端点
    /// 配置/本地切换"语义。统一收进 DI 之后：① 复用 `AppEndpoints.sharing` 解析逻辑，
    /// 本地联调改 env 即可；② `RepoMetadataHeaderView` 通过 environment 拿到这个实例，
    /// 不再 new；③ 未来要做 ShareAPI 单测，从 environment 注入 mock 即可。
    let shareAPI: ShareAPI

    // MARK: - Wiki 外部文档索引

    /// DeepWiki / Zread / Google Code Wiki 单仓库收录查询客户端。
    /// 构造期不发网络请求，因此保持非 optional；服务故障由每次请求独立降级。
    let wikiAPI: WikiAPI

    /// 相似仓库推荐查询客户端。
    /// 构造期不发网络请求；详情页按当前 repo id 懒加载推荐结果。
    let recommendAPI: RecommendAPI

    /// Wiki 探测结果磁盘 JSON 缓存（2026-06-15）。
    /// 单进程单实例，与设置页 / `WikiContextService` 共用 observable 派生量。
    let diskWikiCache: DiskWikiCache

    /// Wiki SWR 编排层（2026-06-15）：read-through cache + 后台刷新 + 并发去重。
    /// 上层 `RepoAIChatViewModel.bootstrap` 通过它一次性拿"已知 wiki 链接"+ 顺手
    /// 触发后台刷新；未来详情页 toolbar wiki popover 也接入这里。
    let wikiContextService: WikiContextService

    // MARK: - OpenSSF Scorecard

    /// OpenSSF Scorecard 公开 API 客户端（无鉴权）。
    let openSSFScoreAPI: OpenSSFScoreAPI
    /// OpenSSF Scorecard 本地缓存仓库。
    let openSSFScoreRepository: any OpenSSFScoreRepositoryProtocol
    /// OpenSSF Scorecard 刷新协调服务。
    let openSSFScoreService: OpenSSFScoreService
    /// OpenSSF Scorecard UI 状态缓存，列表与详情页同步读取。
    let openSSFScoreStore: OpenSSFScoreStore
    /// OpenSSF Scorecard 后台刷新调度器。
    let openSSFScorePoller: OpenSSFScorePoller

    // MARK: - Repo Health

    /// Repo Health 本地快照仓库。
    let repoHealthRepository: any RepoHealthRepositoryProtocol
    /// Repo Health 刷新协调服务。
    let repoHealthService: RepoHealthService
    /// Repo Health UI 状态缓存。
    let repoHealthStore: RepoHealthStore
    /// Repo Health 后台刷新调度器。
    let repoHealthPoller: RepoHealthPoller

    // MARK: - HOM-47 Release 订阅追踪

    /// Release 订阅记录 Repository。
    let releaseSubscriptionRepository: any ReleaseSubscriptionRepositoryProtocol
    /// Release 元数据缓存 Repository。
    let releaseRepository: any ReleaseRepositoryProtocol
    /// Release 巡检协调器:拉一页 Releases → 比对游标 → 写库 → 推通知。
    let releaseMonitor: ReleaseMonitor
    /// Release 系统通知封装（UNUserNotificationCenter）。
    let releaseNotificationService: ReleaseNotificationService
    /// Release 后台轮询调度器（NSBackgroundActivityScheduler）。
    let releasePoller: ReleasePoller

    // MARK: - Activity 公告与关注（PR-1，2026-06-16）

    /// following 分类 GitHub Events feed 本地缓存 Repository。
    /// PR-1 仅装配，PR-2 接 `GitHubEventsAPI` 后由 ActivityViewModel 消费。
    let activityEventRepository: any ActivityEventRepositoryProtocol

    /// announcement 分类双源公告（blog / security）本地缓存 Repository。
    /// PR-1 仅装配，PR-3 接 `GitHubBlogRSSAPI` + `GitHubSecurityAdvisoryAPI` 后由 ActivityViewModel 消费。
    let activityAnnouncementRepository: any ActivityAnnouncementRepositoryProtocol

    /// Activity 数据接入单行 meta 表 Repository（per-source ETag + lastFetchedAt + lastCleanupAt）。
    /// PR-2/PR-3 读取它判 TTL 与 304 短路，并写回最新 ETag。
    let activitySyncStateRepository: any ActivitySyncStateRepositoryProtocol

    /// PR-3：GitHub Blog RSS 客户端（`github.blog/feed/`，独立 host）。
    let blogRSSClient: any GitHubBlogRSSAPIProtocol

    // MARK: - HOM-PROFILE 贡献草坪（2026-06-05）

    /// 用户贡献草坪服务（GraphQL + 3h 缓存 + UserDefaults 持久化）。
    ///
    /// 单实例随 AppDependencies 生命周期：sidebar 显示时调 `load(login:)`，命中 TTL 直接返回，
    /// 不会重复发请求。登出时 SidebarView 触发 `reset(login:)` 清缓存。
    /// 注意持有的是具体 actor 类型 `GitHubAPIClient` 而非 protocol——因为 `graphql<T>` 是
    /// 泛型方法，未挂在 `GitHubAPIClientProtocol` 上以保持 mock 简单。
    let contributionService: ContributionService

    // MARK: - 用户 profile 缓存（2026-06-06 A 方案）

    /// 当前登录用户 profile 的离线缓存 + 后台刷新协调器。
    ///
    /// 解决三个问题（详见 `UserProfileService.swift` 文件头）：
    /// ① 启动期 sidebar 200-800ms 空白 → primeFromCache 秒显
    /// ② profile 字段 App 内不会刷新 → 30min TTL + ShareCardSheet onAppear force refresh
    /// ③ 内存快照丢失 → UserDefaults 持久化
    ///
    /// 装配顺序约束：service 必须在 AuthSession 之后建（service.authSession = session 反向 weak 引用）；
    /// 同时 session.userProfileService = service（强引用，session 持有 service）。
    let userProfileService: UserProfileService

    /// 分享卡开发语言统计服务（当前用户拥有的公开、非 fork 仓库语言聚合）。
    ///
    /// 与 `HomeViewModel.languageStats` 刻意分离：后者统计 starred 项目的语言，表达兴趣；
    /// 这里统计用户自己的公开仓库，表达开发画像。服务内部有 12h TTL + UserDefaults 快照，
    /// 登录后异步预热，分享卡打开时直接消费已缓存数据。
    let developerLanguageService: DeveloperLanguageService

    // MARK: - R-01 三场景共用架构（2026-06-09）

    /// 全局已 star 仓库 id 集合（@Observable）。
    /// 所有列表 / 详情通过 `registry.contains(ghRepoId:)` 判断 star 状态，跨场景自动同步。
    let starredRegistry: StarredRegistry

    /// star / unstar 唯一权威服务（写入 registry 的唯一路径）。
    let starActionService: StarActionService

    /// StarredRegistry 启动 / 同步完成后的全量重建 helper。
    let starredRegistryBootstrapper: StarredRegistryBootstrapper

    /// W12 toolbar 专项 PR-3：批量 star / unstar 调度服务。
    ///
    /// 单例：同一时刻只允许跑一个批次；进度 / 完成摘要由本服务统一暴露给 BatchActionBar
    /// 等 UI 订阅。复用 `starActionService` 单条入口，保证"写入路径唯一"契约。
    let batchStarService: BatchStarService

    /// W12 toolbar 专项 PR-4：Trending 多选 store。
    ///
    /// W12 toolbar PR-5（2026-06-12）：原来 PR-4 注释里写「与 manage（沿用 HomeViewModel.multiSelectedRepoIDs）刻意分开」
    /// 的设计在 PR-5 被主动打破——dong4j 拍板把 Manage 也迁到 MultiSelectionStore，4 个场景统一交互
    /// （点击 toggle / 无 Shift / 卡片视觉对齐）。PR-4 担心的"未必已 star 污染 manage"在 Manage 自己的
    /// store 上不存在（Manage 库内 100% 已 star），同时 BatchActionBar / RemoteBatchActionBar 两个组件
    /// 仍按业务语义独立（前者打标签+Unstar，后者 Star+Unstar），不存在污染问题。
    let trendingMultiSelectionStore: MultiSelectionStore

    /// W12 toolbar 专项 PR-4：Weekly 多选 store。
    let weeklyMultiSelectionStore: MultiSelectionStore

    /// W12 toolbar 专项 PR-4：Activity 多选 store。
    /// 仅有 repo 关联的 ActivityItem 才能进入多选；announcement / suggestion 这类
    /// `repo == nil` 的项在 row 层级隐藏 toggle，不会被加入 snapshots。
    let activityMultiSelectionStore: MultiSelectionStore

    /// W12 toolbar 专项 PR-5：Manage 多选 store（替代原 HomeViewModel.multiSelectedRepoIDs）。
    ///
    /// 与三个远端 store 同款，但语义不同：
    /// - 入选的 snapshot 全部对应**本地 Repo**（Repo.id == GitHub ID == ghRepoId，同一 Int64 域）；
    /// - 进入多选起始空集合，点击 row toggle（不继承 selectedRepoID，对齐 Trending 现状）；
    /// - 退出多选**不动** selectedRepoID，详情页保持，对齐 Trending UX；
    /// - filter / sort 变化触发 reloadItems 后，RepoListView 在 `.onChange(of: itemsRevision)`
    ///   调 `retain(visibleIDs:)` 移除被隐藏的孤儿选中项（A2 路线，view 层主导 store 生命周期，
    ///   不让 HomeViewModel 持 store 引用，避免重新耦合）；
    /// - BatchActionBar 用 `Set(store.snapshots.keys)` 直接喂 `batchAddTag(repoIds:tagId:)`
    ///   （Repo.id == ghRepoId 等价，无需额外字段映射）。
    let manageMultiSelectionStore: MultiSelectionStore

    /// 详情页 Repo 解析链（Local → Hint → BackendAggregate(占位) → GitHub → Minimal）。
    let repoResolver: RepoResolver

    // MARK: - README onHTMLLoaded handler (HOM-201 P0-4, 2026-06-14)

    /// 构造 `ReadmeViewModel.onHTMLLoaded` 回调用的 closure。
    ///
    /// 原本只在 `HomeView.init` 里 inline 给 manage 全局 VM 挂载，导致从 active /
    /// weekly 详情页进入已 star 仓库时不会触发 `refreshMarkdownIfNeeded` +
    /// `refreshIndexIfChanged` —— 后者是文档 `docs/3-设计/详细设计/26-向量搜索改进.md`
    /// §6 关键流程表承诺的"详情页 README 拉到 → 异步补 raw markdown 落
    /// readmes.content + 视情况重建向量索引"触发源。manage 与 active 都走
    /// `loadInternal`（依赖同一 `readmes` 表 PK=repo_id），两者行为应一致；本工厂方法
    /// 把 closure 提到 DI 层，让 `ActivityDetailScaffoldShell` 等 Shell 局部 VM
    /// 也能复用同一份逻辑。
    ///
    /// **trending / weekly 路径**：`ReadmeViewModel.loadTrending` 内部根本不调
    /// `onHTMLLoaded`（参见 ReadmeViewModel 实现），所以传给走 trending 路径的 Shell
    /// （Weekly）是 dead-code dispatch，无副作用——传入只是为了让所有 Shell 装配
    /// 代码同构、避免日后切换路径时漏接。
    ///
    /// **生命周期**：closure 仅 capture `readmeAPI` / `semanticSearchService` 两个
    /// App 级长寿命引用，不持有 `self`，避免 closure 长期挂在 `ReadmeViewModel` 上
    /// 把整个 `AppDependencies` 的释放时机绑定到 ViewModel。
    func makeReadmeOnHTMLLoadedHandler() -> @MainActor (Repo) -> Void {
        let readmeAPI = self.readmeAPI
        let semantic = self.semanticSearchService
        return { repo in
            Task { @MainActor in
                let result = await readmeAPI.refreshMarkdownIfNeeded(for: repo)
                if case .updated = result {
                    await semantic.refreshIndexIfChanged(for: repo)
                }
            }
        }
    }

    // MARK: - 初始化

    /// 生产环境构造：使用真实 DatabaseManager + 根据 useMockOAuth 选择 OAuth Service。
    ///
    /// 数据库是 Starcat 的核心数据载体。初始化失败时不能继续构造半可用依赖树，
    /// 否则后续 Repository 可能在错误路径上读写。这里向上抛出，由 `StarcatApp`
    /// 展示受控启动失败页，并保留诊断包导出入口。
    init() throws {
        // 启动期记录五个自建后端 API 的实际 baseURL（DEBUG 会标 `[DEV]`，方便确认
        // 当前到底打的是 fly.dev 生产端点还是 127.0.0.1 本地端点）。
        // 详见 `AppEndpoints.swift` 头注释里的"使用方式"。
        AppEndpoints.logResolvedEndpoints()

        // 2026-06-12 多账号 DB 隔离：DatabaseManager 不再单例，启动期用 `userId: nil`
        // 走 `users/_anonymous` 占位 DB；AuthSession 在登录成功后通过 onUserSessionChanged
        // closure 触发 `database.reopen(userId:)` 切到该 user 的 DB。
        let db: any DatabaseManaging
        do {
            db = try DatabaseManager(userId: nil)
        } catch {
            DiagnosticLogStore.record(
                level: .critical,
                category: "database",
                operation: "startup.openDatabase",
                message: "Failed to initialize database",
                underlying: error.localizedDescription
            )
            throw error
        }
        self.database = db

        let api = GitHubAPIClient()
        self.apiClient = api

        let oauth: any GithubOAuthServiceProtocol
        if Self.useMockOAuth {
            AppLog.auth.info("Using MockGithubOAuthService (DEBUG)")
            oauth = MockGithubOAuthService()
        } else {
            AppLog.auth.info("Using GithubDeviceFlowService")
            oauth = GithubDeviceFlowService()
        }
        self.oauthService = oauth

        let session = AuthSession(
            oauthService: oauth,
            apiClient: api,
            keychain: KeychainManager.shared
        )
        self.authSession = session

        // 集中式 401 处理：任何 GitHub API 调用映射出 401 → 失效会话 → 自动回登录页。
        // api 是 actor，回调通过 Task 异步注入；首个真实网络请求发生在启动恢复（.task）之后，
        // 注入早已完成，不会漏。弱引用 session 避免 api ↔ authSession 之间的循环强引用。
        Task { [weak session] in
            await api.setUnauthorizedHandler {
                Task { @MainActor in
                    // invalidateSession 2026-06-12 起改 async（要 await DB 切到 _anonymous）
                    await session?.invalidateSession()
                }
            }
        }

        // Week 3 新增：repository / settings 通过 environment 给 HomeView 用
        // D-01：构造时用具体类型 GRDBRepoRepository，字段类型是协议 any RepoRepositoryProtocol
        let repo = GRDBRepoRepository(database: db)
        self.repoRepository = repo
        let settings = AppSettings.shared
        self.settings = settings
        let notificationService = ReleaseNotificationService(settings: settings)
        self.releaseNotificationService = notificationService
        self.syncManager = SyncManager(apiClient: api, repository: repo, notificationService: notificationService)
        let subscriptions = SubscriptionManager(settings: settings)
        self.subscriptionManager = subscriptions
        self.entitlementGate = EntitlementGate(
            entitlementProvider: subscriptions,
            userIDProvider: { [weak session] in
                session?.state.user?.id
            }
        )

        // Week 4 新增：README 子系统
        let readmeRepo = ReadmeRepository(database: db)
        self.readmeRepository = readmeRepo
        // W7+ 新增：Trending README 持久化（trending_readmes 表，PK = full_name）
        let trendingReadmeRepo = TrendingReadmeRepository(database: db)
        self.trendingReadmeRepository = trendingReadmeRepo
        // HOM-201 P0-3：网络刷新 in-flight 去重器。先于 ReadmeAPI 构造，作为依赖注入。
        let inflightTracker = ReadmeInflightTracker()
        self.readmeInflightTracker = inflightTracker
        // HOM-201 P2-3:缓存指标计数器。无 IO 无依赖,构造即用,注入 ReadmeAPI。
        let metrics = ReadmeMetrics()
        self.readmeMetrics = metrics
        self.readmeAPI = ReadmeAPI(
            client: api,
            repository: readmeRepo,
            trendingRepository: trendingReadmeRepo,
            inflightTracker: inflightTracker,
            metrics: metrics
        )
        // HOM-201 P0-2：跨 VM 共享的 404 短路状态容器。无依赖、无 IO，构造即用。
        self.readmeAvailability = ReadmeAvailability()

        let summaryRepo = GRDBAISummaryRepository(database: db)
        self.aiSummaryRepository = summaryRepo

        // 2026-06-13 W4：RepoContextPacker 客户端接入三件套装配。
        // 顺序：① SharedSnapshotService（无依赖，单 struct 实例 OK）
        //      ② RepoContextStorage（单例，从此 root 走 storage.shared 即 W6 决议）
        //      ③ RepoAIContextProvider（组合上面两个 + settings）
        // 三者都 W3 决议「失败降级 nil」，注入 RepoAIInsightService 时**不破坏**现有
        // 测试（init 加默认参数 nil 让旧测试无需改动）。
        let snapshotService = SharedSnapshotService()
        let repoContextStorage = RepoContextStorage.shared
        let repoAIContextProvider = RepoAIContextProvider(
            snapshotService: snapshotService,
            storage: repoContextStorage,
            settings: self.settings
        )

        let aiInsight = RepoAIInsightService(
            summaryRepository: summaryRepo,
            readmeRepository: readmeRepo,
            settings: self.settings,
            repoAIContextProvider: repoAIContextProvider,
            entitlementGate: self.entitlementGate
        )
        self.repoAIInsightService = aiInsight
        self.diskChatHistoryStore = .shared

        // HOM-68：README 翻译。复用 AppSettings.aiTranslationTask 的 provider/model 选择
        // 与 Keychain API Key，独立 Service 承载严格保结构的翻译 prompt + 纯磁盘缓存。
        //
        // **HOM-68 v2（2026-06-15）**：缓存层从 GRDB 表（已删 `readme_translations`）
        // 改为 `DiskReadmeTranslationCache.shared`（路径 `<appSupport>/com.starcat.app/
        // translations-cache/<owner>/<repo>/<lang>.{html,json}`）。改造原因 + 详细决策
        // 见 `ReadmeTranslationRepositoryProtocol` 顶部注释。装配点用 shared 单例是因
        // 为 cache 是 `@MainActor @Observable`，UI（设置页存储 Tab）也需要观察同一份
        // 状态（totalBytes / itemCount / latestCreatedAt），多实例会导致 UI 状态不同步。
        self.readmeTranslationRepository = DiskReadmeTranslationCache.shared
        self.readmeTranslationService = ReadmeTranslationService(
            translationRepository: DiskReadmeTranslationCache.shared,
            settings: self.settings,
            entitlementGate: self.entitlementGate
        )

        // W4 Batch A1：标签 / 关联 / 笔记+状态 Repository
        let rawTagRepo = GRDBTagRepository(database: db)
        let tagRepo = GatedTagRepository(base: rawTagRepo, entitlementGate: self.entitlementGate)
        let repoTagRepo = GRDBRepoTagRepository(database: db)
        let githubStarListRepo = GRDBGitHubStarListRepository(database: db)
        self.tagRepository = tagRepo
        self.repoTagRepository = repoTagRepo
        self.githubStarListRepository = githubStarListRepo
        self.githubStarListSyncService = GitHubStarListSyncService(
            apiClient: api,
            repository: githubStarListRepo
        )
        self.repoNoteRepository = GRDBRepoNoteRepository(database: db)
        self.searchHistoryRepository = GRDBSearchHistoryRepository(database: db)
        self.smartCollectionRepository = GatedSmartCollectionRepository(
            base: GRDBSmartCollectionRepository(database: db),
            entitlementGate: self.entitlementGate
        )

        // HOM-52：批量整理服务装在 AI insight + 标签 + 标签关联 + AI 摘要 Repo 之后。
        // 注：onTagsChanged 由 HomeView 在 environment 注入后挂接，刷新 Sidebar 计数。
        let batchSvc = BatchAIQueueService(
            insightService: aiInsight,
            tagRepository: tagRepo,
            repoTagRepository: repoTagRepo,
            aiSummaryRepository: summaryRepo,
            entitlementGate: self.entitlementGate,
            notificationService: notificationService
        )
        self.batchAIQueueService = batchSvc

        // HOM-126：自动后台 AI 整理调度器。
        // 装配顺序：必须晚于 settings / repoRepository / batchService / syncManager。
        // 注：start() 由 HomeView 在 .task 里调，让"启动延迟"以 SwiftUI scene 进入为起点。
        self.autoTidyScheduler = AutoTidyScheduler(
            settings: self.settings,
            repoRepository: repo,
            batchService: batchSvc,
            syncManager: self.syncManager,
            entitlementGate: self.entitlementGate
        )
        let embeddingRepo = GRDBRepoEmbeddingRepository(database: db)
        self.repoEmbeddingRepository = embeddingRepo
        // 2026-06-12 向量索引改进：注入 README / 笔记 / 摘要三类仓库，
        // 让 SemanticSearchService.buildSnapshot 能从本地数据库取 readme.content /
        // ai_summaries.summary_json / repo_notes.content，拼出三段式 indexedText。
        let semantic = SemanticSearchService(
            embeddingRepository: embeddingRepo,
            settings: self.settings,
            readmeRepository: readmeRepo,
            noteRepository: self.repoNoteRepository,
            summaryRepository: summaryRepo,
            entitlementGate: self.entitlementGate
        )
        self.semanticSearchService = semantic

        let mcpFacade = StarcatMCPFacade(
            repoRepository: repo,
            readmeRepository: readmeRepo,
            tagRepository: tagRepo,
            repoTagRepository: repoTagRepo,
            repoNoteRepository: self.repoNoteRepository,
            semanticSearchService: semantic,
            settings: self.settings
        )
        let mcpWriteFacade = StarcatMCPWriteFacade(
            repoRepository: repo,
            tagRepository: tagRepo,
            repoTagRepository: repoTagRepo,
            repoNoteRepository: self.repoNoteRepository,
            settings: self.settings,
            entitlementGate: self.entitlementGate,
            refreshSemanticIndex: { [weak semantic] repo in
                Task { @MainActor in
                    await semantic?.refreshIndexIfChanged(for: repo)
                }
            }
        )
        self.mcpService = StarcatMCPService(
            settings: self.settings,
            entitlementGate: self.entitlementGate,
            facade: mcpFacade,
            writeFacade: mcpWriteFacade,
            notificationService: notificationService
        )

        // 2026-06-12 向量索引改进：摘要生成成功后触发单 repo 向量重建。
        // weak 捕获避免 `aiInsight ↔ semantic` 形成强循环（两者都是 @MainActor final class，
        // 长生命周期对象，理论上不会真正释放，但 weak 是更稳的写法）。
        // 闭包内调 `refreshIndexIfChanged`（内部 try/catch 处理 missingAPIKey 等）。
        aiInsight.setOnSummaryGenerated { [weak semantic] repo in
            Task { @MainActor in
                await semantic?.refreshIndexIfChanged(for: repo)
            }
        }

        // 2026-06-12 向量索引改进：后台慢速预拉 + 全量重建服务。
        // 由 Settings → "AI 索引" Section 的「开始预拉 / 暂停 / 全量重建」按钮驱动；
        // 装配时仅持有依赖，不主动 start——避免无声烧 API 配额（决策 E3）。
        self.semanticIndexBuilder = SemanticIndexBuilder(
            repoRepository: repo,
            readmeAPI: self.readmeAPI,
            semanticSearchService: semantic
        )

        // HOM-54：Trending Repository（W7+ 起接入 GRDB 持久化）。
        // 把 TrendingAPI 提到顶层 `self.trendingAPI`，让设置页 → 服务 Tab 改地址后
        // 可以直接拿到这个实例 `await trendingAPI.updateBaseURL(_:)` 热更新。
        //
        // R-01 v1.2（2026-06-09）：后端强制 Bearer Auth，apiKey 由 `StarcatAPIKeyResolver`
        // 解析当前生效的 key（设置页覆盖 → production 默认），由 AppDependencies.setServiceAPIKey
        // 在用户改 key 后推送到 actor 的 updateAPIKey 热更新。
        let trendingAPIInstance = TrendingAPI(
            baseURL: AppEndpoints.Trending.baseURL,
            apiKey: StarcatAPIKeyResolver.resolve(for: .trending)
        )
        self.trendingAPI = trendingAPIInstance
        self.trendingRepository = TrendingRepository(
            api: trendingAPIInstance,
            database: db
        )
        // sidebar 语言列表 store。注意：构造期不主动 reload，避免拉网络阻塞启动；
        // 由 HomeView `.task` 在首次进入时调 `reload()`，与 trending 列表的首屏入场时序一致。
        self.trendingLanguageStore = TrendingLanguageStore(api: trendingAPIInstance)

        // MUL-176：阮一峰周刊 API 客户端。端点走 `AppEndpoints.Weekly.baseURL`。
        // 用户在设置页改地址 → AppDependencies.setServiceURL 推送到本 actor 的
        // updateBaseURL，无需重启 App。
        let weeklyAPIInstance = WeeklyAPI(
            baseURL: AppEndpoints.Weekly.baseURL,
            apiKey: StarcatAPIKeyResolver.resolve(for: .weekly)
        )
        self.weeklyAPI = weeklyAPIInstance

        // MUL-176 followup：UI 共享状态总线，sidebar 与 HomeView 通过它读 total / 选中项目。
        self.weeklySelectionService = WeeklySelectionService()
        self.activityCategoryCountService = ActivityCategoryCountService()
        self.sidebarAnimationCoordinator = SidebarAnimationCoordinator()
        self.weeklyLanguageStore = WeeklyLanguageStore(api: weeklyAPIInstance)

        // R-06.4: 客户端 bulk 缓存仓库。注入同一 weeklyAPI actor 实例，让 bulk 端点
        // 与分页 endpoint 共享 baseURL / apiKey 热更新（设置页改地址后两条路径同时生效）。
        self.weeklyBulkRepository = WeeklyBulkRepository(api: weeklyAPIInstance, database: db)

        // HOM-173：分享卡 API 客户端。端点走 `AppEndpoints.Sharing.baseURL`（保留 /api 后缀）。
        self.shareAPI = ShareAPI(
            baseURL: AppEndpoints.Sharing.baseURL,
            apiKey: StarcatAPIKeyResolver.resolve(for: .sharing)
        )

        // Wiki 首期只做详情页单查，不在启动期 health probe，也不接 batch 预热。
        let wikiAPIInstance = WikiAPI(
            baseURL: AppEndpoints.Wiki.baseURL,
            apiKey: StarcatAPIKeyResolver.resolve(for: .wiki)
        )
        self.wikiAPI = wikiAPIInstance

        // Recommend 首期只做详情页单查，不在启动期请求。服务 URL / API Key 与其它
        // 自建后端同样通过设置页热更新。
        self.recommendAPI = RecommendAPI(
            baseURL: AppEndpoints.Recommend.baseURL,
            apiKey: StarcatAPIKeyResolver.resolve(for: .recommend)
        )

        // 2026-06-15 v4.y：Wiki 磁盘缓存 + SWR 编排。装配顺序：
        // disk cache（只读 / 无网络）→ SWR service（依赖 cache + WikiAPI）。
        // shared singleton 保留默认，AppDependencies 引用同一实例，让设置页存储 Tab
        // 与对话 VM 共享同一份 `itemCount` / `totalBytes` observable 派生量。
        self.diskWikiCache = .shared
        self.wikiContextService = WikiContextService(
            cache: .shared,
            fetcher: wikiAPIInstance
        )

        // OpenSSF Scorecard：公开 API + 本地缓存 + 非阻塞 UI store。
        // 注意：这里不启动网络请求；HomeView 登录态门控负责启动后台 poller，
        // Health 相关入口只读本地库，避免把 OpenSSF 的缺失/慢响应带到前台动画里。
        let openSSFAPI = OpenSSFScoreAPI()
        self.openSSFScoreAPI = openSSFAPI
        let openSSFRepo = GRDBOpenSSFScoreRepository(database: db)
        self.openSSFScoreRepository = openSSFRepo
        let openSSFService = OpenSSFScoreService(api: openSSFAPI, repository: openSSFRepo)
        self.openSSFScoreService = openSSFService
        self.openSSFScoreStore = OpenSSFScoreStore(service: openSSFService)
        self.openSSFScorePoller = OpenSSFScorePoller(service: openSSFService)

        // 2026-06-08：第三方服务健康检查 actor。独立 ephemeral session + 5s 超时。
        self.serviceHealthChecker = ServiceHealthChecker()
        // 2026-06-21：状态栏 API 可用性巡检。构造期不阻塞网络；启动后由后台任务立刻检查一次，
        // 后续每 10 分钟刷新，失败会通过 @Observable 状态更新 toolbar。
        self.serviceAvailabilityMonitor = ServiceAvailabilityMonitor()

        // HOM-47：Release 订阅追踪。
        // 装配顺序：Repository → Monitor（依赖 API + Repository + RepoRepository）
        //         → NotificationService → Poller（依赖 Monitor + NotificationService）。
        let rawReleaseSubRepo = GRDBReleaseSubscriptionRepository(database: db)
        let releaseSubRepo = GatedReleaseSubscriptionRepository(
            base: rawReleaseSubRepo,
            entitlementGate: self.entitlementGate
        )
        self.releaseSubscriptionRepository = releaseSubRepo
        let releaseRecordRepo = GRDBReleaseRepository(database: db)
        self.releaseRepository = releaseRecordRepo
        let monitor = ReleaseMonitor(
            apiClient: api,
            subscriptionRepo: releaseSubRepo,
            releaseRepo: releaseRecordRepo,
            repoRepo: repo
        )
        self.releaseMonitor = monitor
        self.releasePoller = ReleasePoller(monitor: monitor, notificationService: notificationService)

        // Repo Health：自动路径只聚合已有本地缓存；用户点击 Health 面板刷新时只主动
        // 更新 GitHub Releases 信号，OpenSSF 交给后台 poller 缓慢补齐。
        // 装配必须晚于 Release / OpenSSF 仓库。
        let healthRepo = GRDBRepoHealthRepository(database: db)
        self.repoHealthRepository = healthRepo
        let healthService = RepoHealthService(
            repository: healthRepo,
            releaseRepository: releaseRecordRepo,
            openSSFRepository: openSSFRepo,
            apiClient: api
        )
        self.repoHealthService = healthService
        self.repoHealthStore = RepoHealthStore(service: healthService)
        self.repoHealthPoller = RepoHealthPoller(service: healthService)

        // Activity 公告与关注 PR-1（2026-06-16）：纯本地 CRUD Repository，不接网络。
        // PR-2/PR-3 在外层 ActivityViewModel 里组合「GitHub Events API + RSS + Security Advisory」
        // 与这 3 个 repo 完成 SWR。装配顺序：3 个 repo 互相独立，与 Release section 并列即可。
        self.activityEventRepository = GRDBActivityEventRepository(database: db)
        self.activityAnnouncementRepository = GRDBActivityAnnouncementRepository(database: db)
        self.activitySyncStateRepository = GRDBActivitySyncStateRepository(database: db)
        self.blogRSSClient = GitHubBlogRSSClient()

        // HOM-PROFILE 2026-06-05：贡献草坪服务。
        // 直接持有具体 GitHubAPIClient（actor），不走 protocol——因为 graphql<T> 是泛型方法，
        // 未挂在协议上以保持 Mock 简单（详见 ContributionService.swift 注释）。
        let contributionSvc = ContributionService(apiClient: api)
        self.contributionService = contributionSvc
        // 2026-06-15 修复(切换账号草坪不刷新):把 service 挂到 AuthSession,让 signOut /
        // invalidateSession / restore 401 三处的"登出联动清理"都能 reset 草坪缓存,
        // 否则 B 登录后 sidebar `.task` 触发的 `load(login: B)` 会因 lastFetchedAt 还在
        // A 那次成功的 3h TTL 窗口内被 no-op 掉,草坪一直挂着 A 的数据(详见 AuthSession 字段注释)。
        session.contributionService = contributionSvc

        // 2026-06-06 A 方案：用户 profile 缓存。
        // 装配三步：① 建 service；② 接到 session（双向，session 强持 service / service weak 反向 → session）；
        // ③ AuthSession.restoreSessionIfAvailable 启动时会用 service.primeFromCache 秒显 sidebar。
        let userProfileSvc = UserProfileService(apiClient: api)
        userProfileSvc.authSession = session
        session.userProfileService = userProfileSvc
        self.userProfileService = userProfileSvc

        // 分享卡开发语言服务：从用户拥有的公开仓库聚合 `/languages` 字节数。
        // 与 ContributionService 同样持有具体 GitHubAPIClient，避免把分享卡专属端点扩进全局 mock 协议。
        let developerLanguageSvc = DeveloperLanguageService(apiClient: api)
        session.developerLanguageService = developerLanguageSvc
        self.developerLanguageService = developerLanguageSvc

        // ────────────────────────────────────────────────────────────────────
        // R-01「三场景共用架构」装配（2026-06-09）
        // ────────────────────────────────────────────────────────────────────

        let registry = StarredRegistry()
        self.starredRegistry = registry

        // userIDProvider 闭包：从 authSession 取当前用户 id（未登录时 nil）
        // weak self 不需要 —— closure 只引用 session（已经是 self.authSession 强持），
        // 但避免 closure 长期持有可能导致的延迟释放，明确 capture session。
        let starActionSvc = StarActionService(
            apiClient: api,
            repoRepository: repo,
            registry: registry,
            userIDProvider: { [weak session] in
                session?.state.user?.id
            },
            homeRefresher: nil           // HomeView 在 .task 时通过 attachHomeRefresher 挂接
        )
        self.starActionService = starActionSvc

        let bootstrapper = StarredRegistryBootstrapper(registry: registry, repoRepository: repo)
        self.starredRegistryBootstrapper = bootstrapper

        // W12 PR-3：批量 star / unstar 调度服务。
        // 复用 starActionService 单条入口；本服务自身不直接碰 apiClient / repoRepository,
        // 保证「写入路径唯一」契约不破。
        self.batchStarService = BatchStarService(
            starActionService: starActionSvc,
            registry: registry
        )

        // W12 PR-4：三个 page 的多选 store。各 page 独立持有，互不干扰。
        self.trendingMultiSelectionStore = MultiSelectionStore()
        self.weeklyMultiSelectionStore = MultiSelectionStore()
        self.activityMultiSelectionStore = MultiSelectionStore()
        self.manageMultiSelectionStore = MultiSelectionStore()

        // RepoResolver chain：5 个 source 按优先级顺序
        // R-01 v1.2（2026-06-09）：BackendAggregateRepoSource 已填实，接 weekly 的
        // GET /api/v1/weekly/{owner}/{repo}（v0.5.2 dong4j 重命名）；详细见 BackendAggregateRepoSource.swift。
        self.repoResolver = RepoResolver(chain: [
            LocalRepoSource(repository: repo),
            BackendHintRepoSource(),
            BackendAggregateRepoSource(weeklyAPI: self.weeklyAPI),
            GitHubFallbackRepoSource(apiClient: api),
            MinimalRepoSource()              // 永远命中兜底
        ])

        // ────────────────────────────────────────────────────────────────────
        // R-01 钩子注入：SyncManager 同步完成 + AuthSession 登出
        // ────────────────────────────────────────────────────────────────────

        // SyncManager 全量 / 增量同步成功完成 → bootstrapper.reload() 同步 registry 到 DB
        // 注：weak 不需要，bootstrapper 与 syncManager 都由 self 强持（生命周期一致）
        self.syncManager.onSyncCompleted = { [bootstrapper, starListSyncService = self.githubStarListSyncService, session] in
            await bootstrapper.reload()
            if let login = session.state.user?.login {
                await starListSyncService.sync(login: login)
            }
        }

        // AuthSession 登出 / 失效 → bootstrapper.clearOnSignOut() 清空 registry
        session.onSignOut = { [bootstrapper] in
            bootstrapper.clearOnSignOut()
        }

        // 2026-06-12 多账号 DB 隔离：登录态变化 → 切 SQLite 到对应 user 目录。
        //
        // weak self：closure 长期挂在 session 上，session 被 self 强持，避免循环引用。
        // closure 为 @MainActor + async：AuthSession 也在 @MainActor 上，直接 await
        // 不需要 hop；switchUserDatabase 内部 await database.reopen(userId:) 串行执行。
        //
        // 错误处理：reopen 失败仅记日志不向上抛——AuthSession 不关心 DB 细节,
        // 而且失败状态下 currentPool 仍指向旧 pool（reopen 实现保证），用户至少
        // 还能看到自己的数据，不会进入"无 DB 可用"的死状态。
        session.onUserSessionChanged = { [weak self] userId in
            guard let self else { return }
            do {
                try await self.switchUserDatabase(to: userId)
            } catch {
                AppLog.database.error(
                    "switchUserDatabase failed for userId=\(userId.map(String.init) ?? "anonymous", privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }

            // HOM-199 B1：DB 切到新用户后立即 reload StarredRegistry。
            //
            // 为什么不依赖 `onSyncCompleted`：那是 SyncManager.performFullSync 跑完才触发，
            // 通常滞后 1~5 秒。这段窗口里所有 RepoCardViewData.isStarred 都从空 / 旧用户的
            // registry 读出 → 卡片心形全空、HomeViewModel 的 isStarred 投影错误，
            // 直到 sync 完成才"突然出现"心形，体验割裂。
            //
            // 这里 reload 的是 **登录前已经持久化在用户 DB 里的** repos.is_starred 列，
            // 不需要走网络——纯磁盘读 < 50ms，可以接受同步等待。
            //
            // signOut 路径（userId == nil）也跑：DB 已切到 _anonymous，registry 应是空集；
            // 走 reload 会从 anonymous DB 读到空集，等价 `clearOnSignOut()`，不冲突。
            // 失败容忍：reload 内部已 try/catch + 日志，不会向外抛错破坏 closure 语义。
            await self.starredRegistryBootstrapper.reload()
        }

        // 启动期 reload：异步 Task，不阻塞 init。测试 host 跳过避免触发 DB 启动期成本。
        if !TestEnvironment.isRunning {
            Task { [bootstrapper] in
                await bootstrapper.reload()
            }
            subscriptions.onEntitlementDidChange = { [weak self] in
                self?.mcpService.refreshForCurrentSettings()
            }
            self.mcpService.refreshForCurrentSettings()
            self.serviceAvailabilityMonitor.startPeriodicChecks()
        }
    }

    // MARK: - 多账号 DB 切换（2026-06-12 多账号 DB 隔离）

    /// 切换 SQLite 到指定 GitHub User ID 对应的目录。`nil` 切到 `_anonymous` 占位 DB。
    ///
    /// 调用方：AuthSession 通过 `onUserSessionChanged` closure 触发。**不要从外部直接调**，
    /// 否则可能跟 AuthSession 的内部状态变化竞态（场景：UI 直接调本方法切到 X，但
    /// AuthSession 没同步更新 state，Repository 在新 DB 里查不到对应 user 的数据）。
    ///
    /// 关键约束：本方法内部 `await database.reopen(userId:)`——后者标 `@MainActor`，
    /// 在 MainActor 队列内串行执行，多次并发调用会顺序排队不并发。
    func switchUserDatabase(to userId: Int64?) async throws {
        try await database.reopen(userId: userId)
    }

    // MARK: - 本机恢复出厂

    /// Storage 页“清空所有数据”的单一执行入口。
    ///
    /// 这里刻意集中编排，而不是让 SettingsView 直接删文件：
    /// - 先停 MCP，避免 reset 期间本机 agent 端口继续暴露旧设置；
    /// - 通过 AuthSession.signOut() 释放当前登录态并切到 `_anonymous` DB；
    /// - 清文件型缓存 / 生成物；
    /// - 删除当前 GitHub user id 的本地 DB 目录；
    /// - 最后恢复 AppSettings / Keychain / UserDefaults 本机配置。
    ///
    /// 全流程只动本机，不调用 GitHub / CloudKit / 自建后端删除远端数据。
    func resetLocalAppData(for target: AppDataResetTarget) async throws {
        mcpService.stop()

        let resetter = AppDataResetService(
            database: database,
            settings: settings
        )
        try await resetter.resetLocalData(
            for: target,
            releaseCurrentSession: { [authSession] in
                await authSession.signOut()
            },
            clearGeneratedCaches: { [weak self] in
                await self?.clearGeneratedLocalCachesForFactoryReset()
            }
        )

        mcpService.stop()
    }

    /// 清理不依赖当前用户 SQLite 的全局文件型缓存 / 生成物。
    ///
    /// README 缓存位于用户 DB；当前用户 DB 会整体删除，所以这里不需要再通过
    /// ReadmeRepository 清一次匿名库。用户自选输出目录的 AI Context / CodeFlow
    /// 删除必须发生在 AppSettings reset 之前，否则 security-scoped bookmark 会先丢失。
    private func clearGeneratedLocalCachesForFactoryReset() async {
        let cleaner = CacheCleaner(readmeRepository: readmeRepository)
        await cleaner.clearImageCache()
        cleaner.clearArchives()

        do { try await DiskReadmeTranslationCache.shared.deleteEverything() }
        catch { AppLog.general.warning("Factory reset: translation cache cleanup failed: \(error.localizedDescription, privacy: .public)") }

        do { try await DiskAnySearchCache.shared.deleteEverything() }
        catch { AppLog.general.warning("Factory reset: AnySearch cache cleanup failed: \(error.localizedDescription, privacy: .public)") }

        do { try DiskWikiCache.shared.deleteEverything() }
        catch { AppLog.general.warning("Factory reset: Wiki cache cleanup failed: \(error.localizedDescription, privacy: .public)") }

        do { try DiskChatHistoryStore.shared.deleteEverything() }
        catch { AppLog.general.warning("Factory reset: chat history cleanup failed: \(error.localizedDescription, privacy: .public)") }

        do { try RepoContextStorage.shared.deleteAllProjects() }
        catch { AppLog.general.warning("Factory reset: AI context cleanup failed: \(error.localizedDescription, privacy: .public)") }

        do { try CodeFlowStorage.shared.deleteAllProjects() }
        catch { AppLog.general.warning("Factory reset: CodeFlow cleanup failed: \(error.localizedDescription, privacy: .public)") }
    }

    // MARK: - 第三方服务热更新（2026-06-08 新增）

    /// 设置页 → 服务 Tab 调用入口：把用户填的 URL 既写入 `AppSettings` 持久化，
    /// 又推送到对应 API actor 的 `updateBaseURL`，让"修改即生效"不需要重启。
    ///
    /// 参数 `url` 已经过 `ThirdPartyService.validate(_:)` 校验为合法 URL。
    /// 传入 nil → 等价于 `resetServiceURL(for:)`：清空持久化、actor 回退到 production。
    ///
    /// 异步是因为 actor 方法要 `await`；UI 侧（@MainActor SwiftUI）调用时 `Task {}` 包一下。
    func setServiceURL(_ url: URL?, for service: ThirdPartyService) async {
        let target: URL = url ?? AppEndpoints.production(for: service)

        // 1) 持久化用户输入（nil/空串 → 删 key，回退默认）
        settings.setCustomURL(url?.absoluteString, for: service)

        // 2) 推送到对应 actor 热更新
        switch service {
        case .trending: await trendingAPI.updateBaseURL(target)
        case .weekly:   await weeklyAPI.updateBaseURL(target)
        case .sharing:  await shareAPI.updateBaseURL(target)
        case .wiki:     await wikiAPI.updateBaseURL(target)
        case .recommend: await recommendAPI.updateBaseURL(target)
        }

        // 3) trending sidebar 语言列表跟随 baseURL 重拉（指向新地址的实际数据）。
        //    其他服务的 sidebar 内容（weekly issues / activity 分类）目前不走类似的 store，
        //    无需在这里同步刷新；未来扩展时再加。
        if service == .trending {
            await trendingLanguageStore.reload()
        } else if service == .weekly {
            weeklyLanguageStore.invalidate()
            await weeklyLanguageStore.reload()
        }

        // 状态栏服务状态走 `/healthz`，URL 改动后应立即重新检测，避免 toolbar 继续显示旧端点结果。
        await serviceAvailabilityMonitor.refreshNow()
    }

    /// 清空某服务的自定义 URL，等价于 `setServiceURL(nil, for:)`。
    func resetServiceURL(for service: ThirdPartyService) async {
        await setServiceURL(nil, for: service)
    }

    // MARK: - 第三方服务 API Key 热更新（R-01 v1.2 2026-06-09 新增）

    /// 设置页 → 服务 Tab 调用入口：把用户填的 API Key 既写入 `AppSettings` 持久化，
    /// 又推送到对应 API actor 的 `updateAPIKey`，让"修改即生效"不需要重启。
    ///
    /// 传入 nil / 空字符串 → 等价于 `resetServiceAPIKey(for:)`：清空用户配置，
    /// actor 回退到 `StarcatAPIKeyDefaults.productionKey`（production 默认 key）。
    ///
    /// 异步是因为 actor 方法要 `await`；UI 侧（@MainActor SwiftUI）调用时 `Task {}` 包一下。
    func setServiceAPIKey(_ key: String?, for service: ThirdPartyService) async {
        // 1) 持久化用户输入（nil/空串 → 删 key，回退默认）
        settings.setCustomAPIKey(key, for: service)

        // 2) 解析新的生效 key（用户填了 → 用用户的；没填 → 用 production 默认）
        //    StarcatAPIKeyResolver.resolve 内部会读 AppSettings 最新状态。
        //    @MainActor hop 是为了拿 AppSettings.shared，但本方法已经在 @MainActor 上下文。
        let resolved = StarcatAPIKeyResolver.resolve(for: service)

        // 3) 推送到对应 actor 热更新
        switch service {
        case .trending: await trendingAPI.updateAPIKey(resolved)
        case .weekly:   await weeklyAPI.updateAPIKey(resolved)
        case .sharing:  await shareAPI.updateAPIKey(resolved)
        case .wiki:     await wikiAPI.updateAPIKey(resolved)
        case .recommend: await recommendAPI.updateAPIKey(resolved)
        }

        // 4) trending API Key 改了 → 立刻用新 key 重拉一次语言列表。
        //    之前 401 用户配好新 key 后 sidebar 立即恢复正确入口，无需重启。
        if service == .trending {
            await trendingLanguageStore.reload()
        } else if service == .weekly {
            weeklyLanguageStore.invalidate()
            await weeklyLanguageStore.reload()
        }
    }

    /// 清空某服务的自定义 API Key（回退到 production 默认）。
    func resetServiceAPIKey(for service: ThirdPartyService) async {
        await setServiceAPIKey(nil, for: service)
    }
}
