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
    /// Week 4 引入：README 缓存 Repository。
    let readmeRepository: ReadmeRepository
    /// Week 4 引入：README HTML 抓取 + 缓存协调。
    let readmeAPI: ReadmeAPI
    /// W4 Batch A1 引入：标签 CRUD。
    let tagRepository: any TagRepositoryProtocol
    /// W4 Batch A1 引入：repo ↔ tag 关联 + 批量打标签。
    let repoTagRepository: any RepoTagRepositoryProtocol
    /// W4 Batch A1 引入：repo 笔记 + 状态管理（同表合并）。
    let repoNoteRepository: any RepoNoteRepositoryProtocol
    /// W6 AI：repo embedding SQLite 缓存。
    let repoEmbeddingRepository: any RepoEmbeddingRepositoryProtocol
    /// W6 AI：语义搜索服务，使用 BYOK 设置 + SQLite 向量缓存。
    let semanticSearchService: SemanticSearchService
    /// W6 AI：单仓 AI 摘要缓存。
    let aiSummaryRepository: any AISummaryRepositoryProtocol
    /// W6 AI：单仓 AI 摘要与标签推荐服务。
    let repoAIInsightService: RepoAIInsightService

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

    /// 第三方后端服务健康检查 actor（2026-06-08）。
    /// 设置页"测试连接"按钮 → `await serviceHealthChecker.check(service:baseURL:)`。
    /// 独立 actor + 短超时（5s），不复用业务 API session。
    let serviceHealthChecker: ServiceHealthChecker

    // MARK: - MUL-176 Weekly（阮一峰周刊）

    /// 阮一峰周刊后端 API 客户端。
    /// 独立 actor，无需 GitHub OAuth；Activity 页 `weekly` 分类直接消费。
    let weeklyAPI: WeeklyAPI

    /// Weekly UI 共享状态：sidebar 计数徽章 + HomeView 详情页路由共用。
    /// 详见 `WeeklySelectionService` 文件头注释。
    let weeklySelectionService: WeeklySelectionService

    // MARK: - HOM-173 分享卡

    /// AI 分享卡后端 API 客户端。
    ///
    /// 2026-06-08 之前是在 `RepoMetadataHeaderView.shareRepo()` 里每次分享 new 一个
    /// `ShareAPI()`——既无法注入测试 mock，也没法与 trending / weekly 共享同一份"端点
    /// 配置/本地切换"语义。统一收进 DI 之后：① 复用 `AppEndpoints.sharing` 解析逻辑，
    /// 本地联调改 env 即可；② `RepoMetadataHeaderView` 通过 environment 拿到这个实例，
    /// 不再 new；③ 未来要做 ShareAPI 单测，从 environment 注入 mock 即可。
    let shareAPI: ShareAPI

    // MARK: - HOM-47 Release 订阅追踪

    /// Release 订阅记录 Repository。
    let releaseSubscriptionRepository: any ReleaseSubscriptionRepositoryProtocol
    /// Release 元数据缓存 Repository。
    let releaseRepository: any ReleaseRepositoryProtocol
    /// Release 巡检协调器：拉一页 Releases → 比对游标 → 写库 → 推通知。
    let releaseMonitor: ReleaseMonitor
    /// Release 系统通知封装（UNUserNotificationCenter）。
    let releaseNotificationService: ReleaseNotificationService
    /// Release 后台轮询调度器（NSBackgroundActivityScheduler）。
    let releasePoller: ReleasePoller

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

    // MARK: - 初始化

    /// 生产环境构造：使用真实 DatabaseManager + 根据 useMockOAuth 选择 OAuth Service。
    init() {
        // 启动期记录三个自建后端 API 的实际 baseURL（DEBUG 会标 `[DEV]`，方便确认
        // 当前到底打的是 fly.dev 生产端点还是 127.0.0.1 本地端点）。
        // 详见 `AppEndpoints.swift` 头注释里的"使用方式"。
        AppEndpoints.logResolvedEndpoints()

        let db: any DatabaseManaging = DatabaseManager.shared
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
                    session?.invalidateSession()
                }
            }
        }

        // Week 3 新增：repository / settings 通过 environment 给 HomeView 用
        // D-01：构造时用具体类型 GRDBRepoRepository，字段类型是协议 any RepoRepositoryProtocol
        let repo = GRDBRepoRepository(database: db)
        self.repoRepository = repo
        self.syncManager = SyncManager(apiClient: api, repository: repo)
        self.settings = AppSettings.shared

        // Week 4 新增：README 子系统
        let readmeRepo = ReadmeRepository(database: db)
        self.readmeRepository = readmeRepo
        // W7+ 新增：Trending README 持久化（trending_readmes 表，PK = full_name）
        let trendingReadmeRepo = TrendingReadmeRepository(database: db)
        self.trendingReadmeRepository = trendingReadmeRepo
        self.readmeAPI = ReadmeAPI(
            client: api,
            repository: readmeRepo,
            trendingRepository: trendingReadmeRepo
        )

        let summaryRepo = GRDBAISummaryRepository(database: db)
        self.aiSummaryRepository = summaryRepo
        let aiInsight = RepoAIInsightService(
            summaryRepository: summaryRepo,
            readmeRepository: readmeRepo,
            settings: self.settings
        )
        self.repoAIInsightService = aiInsight

        // HOM-68：README 翻译。复用 AppSettings.aiSummaryTask 的 provider/model 选择
        // 与 Keychain API Key，独立 Service 承载严格保结构的翻译 prompt + 本地 SQLite 缓存。
        let translationRepo = GRDBReadmeTranslationRepository(database: db)
        self.readmeTranslationRepository = translationRepo
        self.readmeTranslationService = ReadmeTranslationService(
            translationRepository: translationRepo,
            settings: self.settings
        )

        // W4 Batch A1：标签 / 关联 / 笔记+状态 Repository
        let tagRepo = GRDBTagRepository(database: db)
        let repoTagRepo = GRDBRepoTagRepository(database: db)
        self.tagRepository = tagRepo
        self.repoTagRepository = repoTagRepo
        self.repoNoteRepository = GRDBRepoNoteRepository(database: db)

        // HOM-52：批量整理服务装在 AI insight + 标签 + 标签关联 + AI 摘要 Repo 之后。
        // 注：onTagsChanged 由 HomeView 在 environment 注入后挂接，刷新 Sidebar 计数。
        let batchSvc = BatchAIQueueService(
            insightService: aiInsight,
            tagRepository: tagRepo,
            repoTagRepository: repoTagRepo,
            aiSummaryRepository: summaryRepo
        )
        self.batchAIQueueService = batchSvc

        // HOM-126：自动后台 AI 整理调度器。
        // 装配顺序：必须晚于 settings / repoRepository / batchService / syncManager。
        // 注：start() 由 HomeView 在 .task 里调，让"启动延迟"以 SwiftUI scene 进入为起点。
        self.autoTidyScheduler = AutoTidyScheduler(
            settings: self.settings,
            repoRepository: repo,
            batchService: batchSvc,
            syncManager: self.syncManager
        )
        let embeddingRepo = GRDBRepoEmbeddingRepository(database: db)
        self.repoEmbeddingRepository = embeddingRepo
        self.semanticSearchService = SemanticSearchService(
            embeddingRepository: embeddingRepo,
            settings: self.settings
        )

        // HOM-54：Trending Repository（W7+ 起接入 GRDB 持久化）。
        // 把 TrendingAPI 提到顶层 `self.trendingAPI`，让设置页 → 服务 Tab 改地址后
        // 可以直接拿到这个实例 `await trendingAPI.updateBaseURL(_:)` 热更新。
        let trendingAPIInstance = TrendingAPI(baseURL: AppEndpoints.Trending.baseURL)
        self.trendingAPI = trendingAPIInstance
        self.trendingRepository = TrendingRepository(
            api: trendingAPIInstance,
            database: db
        )

        // MUL-176：阮一峰周刊 API 客户端。端点走 `AppEndpoints.Weekly.baseURL`。
        // 用户在设置页改地址 → AppDependencies.setServiceURL 推送到本 actor 的
        // updateBaseURL，无需重启 App。
        self.weeklyAPI = WeeklyAPI(baseURL: AppEndpoints.Weekly.baseURL)

        // MUL-176 followup：UI 共享状态总线，sidebar 与 HomeView 通过它读 total / 选中项目。
        self.weeklySelectionService = WeeklySelectionService()

        // HOM-173：分享卡 API 客户端。端点走 `AppEndpoints.Sharing.baseURL`（保留 /api 后缀）。
        self.shareAPI = ShareAPI(baseURL: AppEndpoints.Sharing.baseURL)

        // 2026-06-08：第三方服务健康检查 actor。独立 ephemeral session + 5s 超时。
        self.serviceHealthChecker = ServiceHealthChecker()

        // HOM-47：Release 订阅追踪。
        // 装配顺序：Repository → Monitor（依赖 API + Repository + RepoRepository）
        //         → NotificationService → Poller（依赖 Monitor + NotificationService）。
        let releaseSubRepo = GRDBReleaseSubscriptionRepository(database: db)
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
        let notificationService = ReleaseNotificationService()
        self.releaseNotificationService = notificationService
        self.releasePoller = ReleasePoller(monitor: monitor, notificationService: notificationService)

        // HOM-PROFILE 2026-06-05：贡献草坪服务。
        // 直接持有具体 GitHubAPIClient（actor），不走 protocol——因为 graphql<T> 是泛型方法，
        // 未挂在协议上以保持 Mock 简单（详见 ContributionService.swift 注释）。
        self.contributionService = ContributionService(apiClient: api)

        // 2026-06-06 A 方案：用户 profile 缓存。
        // 装配三步：① 建 service；② 接到 session（双向，session 强持 service / service weak 反向 → session）；
        // ③ AuthSession.restoreSessionIfAvailable 启动时会用 service.primeFromCache 秒显 sidebar。
        let userProfileSvc = UserProfileService(apiClient: api)
        userProfileSvc.authSession = session
        session.userProfileService = userProfileSvc
        self.userProfileService = userProfileSvc
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
        }
    }

    /// 清空某服务的自定义 URL，等价于 `setServiceURL(nil, for:)`。
    func resetServiceURL(for service: ThirdPartyService) async {
        await setServiceURL(nil, for: service)
    }
}
