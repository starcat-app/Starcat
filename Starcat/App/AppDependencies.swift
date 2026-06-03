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

    /// HOM-54 引入：GitHub Trending 数据仓库。
    let trendingRepository: any TrendingRepositoryProtocol
    /// W7+ 引入：Trending README 持久化（与 manage 路径独立的 `trending_readmes` 表）。
    let trendingReadmeRepository: TrendingReadmeRepository

    // MARK: - 初始化

    /// 生产环境构造：使用真实 DatabaseManager + 根据 useMockOAuth 选择 OAuth Service。
    init() {
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
        self.repoAIInsightService = RepoAIInsightService(
            summaryRepository: summaryRepo,
            readmeRepository: readmeRepo,
            settings: self.settings
        )

        // W4 Batch A1：标签 / 关联 / 笔记+状态 Repository
        self.tagRepository = GRDBTagRepository(database: db)
        self.repoTagRepository = GRDBRepoTagRepository(database: db)
        self.repoNoteRepository = GRDBRepoNoteRepository(database: db)
        let embeddingRepo = GRDBRepoEmbeddingRepository(database: db)
        self.repoEmbeddingRepository = embeddingRepo
        self.semanticSearchService = SemanticSearchService(
            embeddingRepository: embeddingRepo,
            settings: self.settings
        )

        // HOM-54：Trending Repository（W7+ 起接入 GRDB 持久化）
        self.trendingRepository = TrendingRepository(database: db)
    }
}
