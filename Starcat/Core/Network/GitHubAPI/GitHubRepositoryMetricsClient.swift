//
//  GitHubRepositoryMetricsClient.swift
//  Starcat
//
//  仓库洞察与 RAG Remote Context 共用的类型化 GitHub 仓库指标客户端。
//
//  关键约束：
//  - actor 串行化出站请求，避免洞察页面一次并发击穿 GitHub secondary rate limit。
//  - 本层只返回类型化 DTO 与响应元数据，不生成面向 LLM 的文本。
//  - 202、Rate Limit、不可用端点和 304 均映射为稳定错误，上层据此决定重试或保留旧缓存。
//

import Foundation

/// 单次 GitHub Metrics 响应携带的限流信息。
struct GitHubMetricsRateLimit: Equatable, Sendable {
    let remaining: Int?
    let resetAt: Date?
    let retryAfter: TimeInterval?
}

/// 类型化数据与缓存、审计需要的 HTTP 元数据。
struct GitHubMetricsResponse<Value: Sendable>: Sendable {
    let value: Value
    let requestURL: URL
    let statusCode: Int
    let etag: String?
    let rateLimit: GitHubMetricsRateLimit
}

/// 调试审计只观察 URL 与状态，不接触 Authorization 请求头。
enum GitHubMetricsRequestEvent: Equatable, Sendable {
    case request(URL)
    case response(URL, statusCode: Int)
    case failure(URL, message: String)
}

typealias GitHubMetricsRequestObserver = @Sendable (GitHubMetricsRequestEvent) -> Void

/// GitHub Metrics 的稳定错误语义。ViewModel 不需要解析字符串或猜测状态码。
enum GitHubRepositoryMetricsError: Error, Equatable, Sendable {
    case generating(retryAfter: TimeInterval?)
    case notModified(etag: String?)
    case unauthorized
    case rateLimited(statusCode: Int, message: String, retryAfter: TimeInterval?, resetAt: Date?)
    case forbidden(message: String, resetAt: Date?)
    case unavailable(statusCode: Int, message: String)
    case http(statusCode: Int, message: String)
    case invalidResponse

    var statusCode: Int? {
        switch self {
        case .generating: return 202
        case .notModified: return 304
        case .unauthorized: return 401
        case .rateLimited(let statusCode, _, _, _): return statusCode
        case .forbidden: return 403
        case .unavailable(let statusCode, _), .http(let statusCode, _): return statusCode
        case .invalidResponse: return nil
        }
    }
}

extension GitHubRepositoryMetricsError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .generating:
            return "GitHub is generating repository statistics"
        case .notModified:
            return "GitHub response was not modified"
        case .unauthorized:
            return "GitHub authentication is required"
        case .rateLimited(_, let message, _, _),
             .forbidden(let message, _),
             .unavailable(_, let message),
             .http(_, let message):
            return message
        case .invalidResponse:
            return "GitHub returned an invalid response"
        }
    }
}

/// Search Issues 返回的标签。
struct GitHubRepositoryIssueLabel: Codable, Equatable, Sendable {
    let name: String
}

/// Search Issues 的单条 Issue / Pull Request。
struct GitHubRepositoryIssueItem: Decodable, Equatable, Sendable {
    private struct PullRequestMarker: Decodable, Equatable, Sendable {}

    let number: Int
    let title: String
    let state: String
    let htmlURL: String
    let body: String?
    let labels: [GitHubRepositoryIssueLabel]
    let comments: Int
    let createdAt: String?
    let closedAt: String?
    let updatedAt: String
    let repositoryURL: String?
    private let pullRequest: PullRequestMarker?

    var isPullRequest: Bool { pullRequest != nil }

    enum CodingKeys: String, CodingKey {
        case number, title, state, body, labels, comments
        case htmlURL = "html_url"
        case createdAt = "created_at"
        case closedAt = "closed_at"
        case updatedAt = "updated_at"
        case repositoryURL = "repository_url"
        case pullRequest = "pull_request"
    }

    /// GitHub Search 理论上受 repo qualifier 约束，但仍做返回值二次校验，防止查询词扩大范围。
    func belongs(to repository: RepoIdentity) -> Bool {
        let expectedAPIPath = "/repos/\(repository.owner)/\(repository.name)".lowercased()
        if let repositoryURL,
           URL(string: repositoryURL)?.path.lowercased() == expectedAPIPath {
            return true
        }
        let expectedHTMLPrefix = "/\(repository.owner)/\(repository.name)/".lowercased()
        return URL(string: htmlURL)?.path.lowercased().hasPrefix(expectedHTMLPrefix) == true
    }
}

/// Search Issues 的总数与有限明细。
struct GitHubRepositoryIssueSearch: Decodable, Equatable, Sendable {
    let totalCount: Int
    let items: [GitHubRepositoryIssueItem]

    enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode([GitHubRepositoryIssueItem].self, forKey: .items)
        // 旧 RAG 测试桩只返回 items；生产 GitHub 始终有 total_count。
        totalCount = try container.decodeIfPresent(Int.self, forKey: .totalCount) ?? items.count
    }
}

/// GraphQL 合并活动请求返回的最近事件。`occurredAt` 已在客户端按
/// closedAt > updatedAt 的优先级收口，上层不再理解 GraphQL union。
struct GitHubRepositoryActivityEventMetric: Equatable, Sendable {
    let number: Int
    let title: String
    let htmlURL: String
    let occurredAt: String
}

/// 单次 GraphQL 请求同时承载活动 KPI 与最近动态，替代六次 Search REST 请求。
struct GitHubRepositoryActivityBundleMetric: Equatable, Sendable {
    let createdPullRequests: Int
    let mergedPullRequests: Int
    let createdIssues: Int
    let closedIssues: Int
    let recentPullRequests: [GitHubRepositoryActivityEventMetric]
    let recentIssues: [GitHubRepositoryActivityEventMetric]
}

/// GitHub 最近 52 周 Commit Activity 的一周数据。
/// GitHub `/stats/commit_activity` 单周条目。
/// `days` 为周日→周六共 7 天的提交数；`week` 为该周周日 00:00 UTC 的 Unix 秒。
struct GitHubWeeklyCommitActivity: Decodable, Equatable, Sendable {
    let week: Int
    let total: Int
    let days: [Int]

    private enum CodingKeys: String, CodingKey {
        case week, total, days
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        week = try container.decodeIfPresent(Int.self, forKey: .week) ?? 0
        total = try container.decode(Int.self, forKey: .total)
        days = try container.decodeIfPresent([Int].self, forKey: .days) ?? []
    }
}

/// GitHub contributors endpoint 的贡献者。
struct GitHubRepositoryContributorMetric: Decodable, Equatable, Sendable {
    let login: String
    let contributions: Int
    let avatarURL: String?
    let htmlURL: String?

    enum CodingKeys: String, CodingKey {
        case login, contributions
        case avatarURL = "avatar_url"
        case htmlURL = "html_url"
    }
}

/// Community Profile 中 Starcat 首版需要展示的文档可用性。
struct GitHubRepositoryCommunityProfile: Decodable, Equatable, Sendable {
    /// Community / license 文件节点；只取浏览器可打开的 `html_url`。
    private struct CommunityFile: Decodable, Equatable, Sendable {
        let htmlURL: URL?

        enum CodingKeys: String, CodingKey {
            case htmlURL = "html_url"
        }
    }

    private struct Files: Decodable, Equatable, Sendable {
        let codeOfConduct: CommunityFile?
        let codeOfConductFile: CommunityFile?
        let contributing: CommunityFile?
        let issueTemplate: CommunityFile?
        let license: CommunityFile?
        let pullRequestTemplate: CommunityFile?
        let readme: CommunityFile?

        enum CodingKeys: String, CodingKey {
            case codeOfConduct = "code_of_conduct"
            case codeOfConductFile = "code_of_conduct_file"
            case issueTemplate = "issue_template"
            case pullRequestTemplate = "pull_request_template"
            case contributing, license, readme
        }
    }

    let healthPercentage: Int
    private let files: Files

    var hasReadme: Bool { files.readme != nil }
    var hasCodeOfConduct: Bool { files.codeOfConduct != nil || files.codeOfConductFile != nil }
    var hasContributing: Bool { files.contributing != nil }
    var hasIssueTemplate: Bool { files.issueTemplate != nil }
    var hasLicense: Bool { files.license != nil }
    var hasPullRequestTemplate: Bool { files.pullRequestTemplate != nil }

    var readmeHTMLURL: URL? { files.readme?.htmlURL }
    /// 优先仓库内 CODE_OF_CONDUCT 文件；其次官方 CoC 页（html_url 可能为 null）。
    var codeOfConductHTMLURL: URL? {
        files.codeOfConductFile?.htmlURL ?? files.codeOfConduct?.htmlURL
    }
    var contributingHTMLURL: URL? { files.contributing?.htmlURL }
    var issueTemplateHTMLURL: URL? { files.issueTemplate?.htmlURL }
    var licenseHTMLURL: URL? { files.license?.htmlURL }
    var pullRequestTemplateHTMLURL: URL? { files.pullRequestTemplate?.htmlURL }

    enum CodingKeys: String, CodingKey {
        case healthPercentage = "health_percentage"
        case files
    }
}

/// Contents API 返回的目录项；只用于补足 Community Profile 无法表达的多文件 Issue 模板目录。
private struct GitHubRepositoryContentEntry: Decodable, Equatable, Sendable {
    let name: String
    let type: String

    var isIssueTemplateCandidate: Bool {
        guard type == "file" else { return false }
        let normalizedName = name.lowercased()
        guard normalizedName != "config.yml" else { return false }
        // GitHub 当前只把 .md 识别为传统模板、.yml 识别为 Issue Form；.yaml 不在官方约定内。
        return normalizedName.hasSuffix(".md") || normalizedName.hasSuffix(".yml")
    }
}

/// RAG 既有 Release 远程证据使用的类型化响应。
struct GitHubRepositoryReleaseMetric: Decodable, Equatable, Sendable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: String
    let publishedAt: String?

    enum CodingKeys: String, CodingKey {
        case name, body
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case publishedAt = "published_at"
    }
}

/// RAG 既有 Security Advisory 远程证据使用的类型化响应。
struct GitHubRepositorySecurityAdvisoryMetric: Decodable, Equatable, Sendable {
    private struct Publisher: Decodable, Equatable, Sendable {
        let login: String
    }

    let ghsaID: String
    let cveID: String?
    let summary: String
    let severity: String
    let htmlURL: String?
    let publishedAt: String
    private let publisher: Publisher?

    var publisherLogin: String? { publisher?.login }

    enum CodingKeys: String, CodingKey {
        case summary, severity, publisher
        case ghsaID = "ghsa_id"
        case cveID = "cve_id"
        case htmlURL = "html_url"
        case publishedAt = "published_at"
    }
}

/// 类型化端点协议。observer 只服务 RAG Debug Trace，普通洞察调用传 nil。
protocol GitHubRepositoryMetricsClient: Sendable {
    /// 切换认证 / 数据库作用域前取消普通洞察请求，并清空只属于旧账号的退避状态。
    func clearTransientState() async

    /// begin / end 覆盖整个 DatabaseManager.reopen 窗口，避免清理后又插入新请求。
    func beginDatabaseScopeChange() async
    func endDatabaseScopeChange() async

    func loadActivityBundle(
        repository: RepoIdentity,
        dateRange: String
    ) async throws -> GitHubRepositoryActivityBundleMetric

    func searchIssues(
        repository: RepoIdentity,
        query: String,
        sort: String,
        order: String,
        perPage: Int,
        observer: GitHubMetricsRequestObserver?
    ) async throws -> GitHubMetricsResponse<GitHubRepositoryIssueSearch>

    func loadCommitActivity(
        repository: RepoIdentity,
        ifNoneMatch: String?,
        observer: GitHubMetricsRequestObserver?
    ) async throws -> GitHubMetricsResponse<[GitHubWeeklyCommitActivity]>

    func loadContributors(
        repository: RepoIdentity,
        limit: Int,
        ifNoneMatch: String?,
        observer: GitHubMetricsRequestObserver?
    ) async throws -> GitHubMetricsResponse<[GitHubRepositoryContributorMetric]>

    func loadCommunityProfile(
        repository: RepoIdentity,
        ifNoneMatch: String?,
        observer: GitHubMetricsRequestObserver?
    ) async throws -> GitHubMetricsResponse<GitHubRepositoryCommunityProfile>

    func loadIssueTemplateAvailability(
        repository: RepoIdentity,
        observer: GitHubMetricsRequestObserver?
    ) async throws -> Bool

    func loadReleases(
        repository: RepoIdentity,
        limit: Int,
        ifNoneMatch: String?,
        observer: GitHubMetricsRequestObserver?
    ) async throws -> GitHubMetricsResponse<[GitHubRepositoryReleaseMetric]>

    func loadSecurityAdvisories(
        repository: RepoIdentity,
        limit: Int,
        ifNoneMatch: String?,
        observer: GitHubMetricsRequestObserver?
    ) async throws -> GitHubMetricsResponse<[GitHubRepositorySecurityAdvisoryMetric]>
}

extension GitHubRepositoryMetricsClient {
    func clearTransientState() async {}
    func beginDatabaseScopeChange() async {
        await clearTransientState()
    }
    func endDatabaseScopeChange() async {}

    func searchIssues(
        repository: RepoIdentity,
        query: String,
        sort: String,
        order: String,
        perPage: Int
    ) async throws -> GitHubMetricsResponse<GitHubRepositoryIssueSearch> {
        try await searchIssues(
            repository: repository,
            query: query,
            sort: sort,
            order: order,
            perPage: perPage,
            observer: nil
        )
    }

    func loadCommitActivity(
        repository: RepoIdentity,
        ifNoneMatch: String? = nil
    ) async throws -> GitHubMetricsResponse<[GitHubWeeklyCommitActivity]> {
        try await loadCommitActivity(
            repository: repository,
            ifNoneMatch: ifNoneMatch,
            observer: nil
        )
    }

    func loadCommitActivity(
        repository: RepoIdentity,
        observer: GitHubMetricsRequestObserver?
    ) async throws -> GitHubMetricsResponse<[GitHubWeeklyCommitActivity]> {
        try await loadCommitActivity(
            repository: repository,
            ifNoneMatch: nil,
            observer: observer
        )
    }

    func loadContributors(
        repository: RepoIdentity,
        limit: Int,
        ifNoneMatch: String? = nil
    ) async throws -> GitHubMetricsResponse<[GitHubRepositoryContributorMetric]> {
        try await loadContributors(
            repository: repository,
            limit: limit,
            ifNoneMatch: ifNoneMatch,
            observer: nil
        )
    }

    func loadContributors(
        repository: RepoIdentity,
        limit: Int,
        observer: GitHubMetricsRequestObserver?
    ) async throws -> GitHubMetricsResponse<[GitHubRepositoryContributorMetric]> {
        try await loadContributors(
            repository: repository,
            limit: limit,
            ifNoneMatch: nil,
            observer: observer
        )
    }

    func loadCommunityProfile(
        repository: RepoIdentity,
        ifNoneMatch: String? = nil
    ) async throws -> GitHubMetricsResponse<GitHubRepositoryCommunityProfile> {
        try await loadCommunityProfile(
            repository: repository,
            ifNoneMatch: ifNoneMatch,
            observer: nil
        )
    }

    func loadCommunityProfile(
        repository: RepoIdentity,
        observer: GitHubMetricsRequestObserver?
    ) async throws -> GitHubMetricsResponse<GitHubRepositoryCommunityProfile> {
        try await loadCommunityProfile(
            repository: repository,
            ifNoneMatch: nil,
            observer: observer
        )
    }

    /// 测试桩和不支持 Contents API 的实现保留 Community Profile 原语义。
    func loadIssueTemplateAvailability(
        repository _: RepoIdentity,
        observer _: GitHubMetricsRequestObserver?
    ) async throws -> Bool {
        false
    }

    func loadReleases(
        repository: RepoIdentity,
        limit: Int,
        ifNoneMatch: String? = nil
    ) async throws -> GitHubMetricsResponse<[GitHubRepositoryReleaseMetric]> {
        try await loadReleases(
            repository: repository,
            limit: limit,
            ifNoneMatch: ifNoneMatch,
            observer: nil
        )
    }

    func loadReleases(
        repository: RepoIdentity,
        limit: Int,
        observer: GitHubMetricsRequestObserver?
    ) async throws -> GitHubMetricsResponse<[GitHubRepositoryReleaseMetric]> {
        try await loadReleases(
            repository: repository,
            limit: limit,
            ifNoneMatch: nil,
            observer: observer
        )
    }

    func loadSecurityAdvisories(
        repository: RepoIdentity,
        limit: Int,
        ifNoneMatch: String? = nil
    ) async throws -> GitHubMetricsResponse<[GitHubRepositorySecurityAdvisoryMetric]> {
        try await loadSecurityAdvisories(
            repository: repository,
            limit: limit,
            ifNoneMatch: ifNoneMatch,
            observer: nil
        )
    }

    func loadSecurityAdvisories(
        repository: RepoIdentity,
        limit: Int,
        observer: GitHubMetricsRequestObserver?
    ) async throws -> GitHubMetricsResponse<[GitHubRepositorySecurityAdvisoryMetric]> {
        try await loadSecurityAdvisories(
            repository: repository,
            limit: limit,
            ifNoneMatch: nil,
            observer: observer
        )
    }
}

/// GitHub URL 构造的单一来源，RAG 失败审计与真实请求必须使用同一规则。
struct GitHubRepositoryMetricsEndpointBuilder: Sendable {
    let baseURL: URL

    func searchIssues(
        query: String,
        sort: String,
        order: String,
        perPage: Int
    ) -> URL {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("search/issues"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "sort", value: sort),
            URLQueryItem(name: "order", value: order),
            URLQueryItem(name: "per_page", value: String(perPage))
        ]
        return components.url!
    }

    func repository(
        _ repository: RepoIdentity,
        suffix: String,
        queryItems: [URLQueryItem] = []
    ) -> URL {
        let url = baseURL
            .appendingPathComponent("repos")
            .appendingPathComponent(repository.owner)
            .appendingPathComponent(repository.name)
            .appendingPathComponent(suffix)
        guard !queryItems.isEmpty else { return url }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = queryItems
        return components.url!
    }
}

/// 生产实现。actor 的串行执行是有意的限流策略，不应改回一次并发加载全部区块。
actor DefaultGitHubRepositoryMetricsClient: GitHubRepositoryMetricsClient {
    private let httpClient: any RAGHTTPClientProtocol
    private let tokenProvider: any GitHubTokenProviding
    private let endpoints: GitHubRepositoryMetricsEndpointBuilder
    private let now: @Sendable () -> Date
    private let requestGate = GitHubMetricsRequestGate()
    private let inflightTracker = GitHubMetricsInflightTracker()
    private let databaseScopeBarrier = GitHubMetricsDatabaseScopeBarrier()
    private var rateLimitBackoffUntil: [GitHubMetricsAuthorizationIdentity: Date] = [:]
    private var endpointFailureStates: [
        GitHubMetricsFailureKey: GitHubMetricsFailureState
    ] = [:]

    init(
        httpClient: any RAGHTTPClientProtocol = URLSessionRAGHTTPClient(),
        token: String?,
        baseURL: URL = URL(string: "https://api.github.com")!,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.httpClient = httpClient
        self.tokenProvider = FixedGitHubTokenProvider(token: token)
        self.endpoints = GitHubRepositoryMetricsEndpointBuilder(baseURL: baseURL)
        self.now = now
    }

    func loadActivityBundle(
        repository: RepoIdentity,
        dateRange: String
    ) async throws -> GitHubRepositoryActivityBundleMetric {
        try await withDatabaseScope { [self] in
            try Task.checkCancellation()
            let currentToken = await tokenProvider.currentToken()?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let url = endpoints.baseURL.appendingPathComponent("graphql")
            let key = GitHubMetricsInflightKey(
                url: url,
                ifNoneMatch: nil,
                authorizationIdentity: currentToken,
                requestIdentity: "activity-bundle:\(repository.owner)/\(repository.name):\(dateRange)"
            )
            return try await inflightTracker.value(for: key) { [self] in
                try await executeSerializedActivityBundle(
                    url: url,
                    repository: repository,
                    dateRange: dateRange,
                    token: currentToken
                )
            }
        }
    }

    /// 洞察使用动态 Token Provider，登录 / 登出后不需要重建 AppDependencies。
    init(
        httpClient: any RAGHTTPClientProtocol = URLSessionRAGHTTPClient(),
        tokenProvider: any GitHubTokenProviding,
        baseURL: URL = URL(string: "https://api.github.com")!,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.httpClient = httpClient
        self.tokenProvider = tokenProvider
        self.endpoints = GitHubRepositoryMetricsEndpointBuilder(baseURL: baseURL)
        self.now = now
    }

    func clearTransientState() async {
        await beginDatabaseScopeChange()
        await endDatabaseScopeChange()
    }

    func beginDatabaseScopeChange() async {
        // 先关闭入口，后续调用会在读取 Token 前等待；再取消已存在的普通洞察 Task。
        // observer 请求不强制取消，但必须自然结束后才能允许数据库 reopen。
        await databaseScopeBarrier.beginChange()
        await inflightTracker.cancelAllAndWait()
        await databaseScopeBarrier.waitUntilDrained()
        rateLimitBackoffUntil.removeAll(keepingCapacity: true)
        endpointFailureStates.removeAll(keepingCapacity: true)
    }

    func endDatabaseScopeChange() async {
        await databaseScopeBarrier.endChange()
    }

    private func withDatabaseScope<Value: Sendable>(
        _ operation: () async throws -> Value
    ) async throws -> Value {
        await databaseScopeBarrier.enter()
        do {
            let value = try await operation()
            await databaseScopeBarrier.leave()
            return value
        } catch {
            await databaseScopeBarrier.leave()
            throw error
        }
    }

    func searchIssues(
        repository: RepoIdentity,
        query: String,
        sort: String,
        order: String,
        perPage: Int,
        observer: GitHubMetricsRequestObserver?
    ) async throws -> GitHubMetricsResponse<GitHubRepositoryIssueSearch> {
        let url = endpoints.searchIssues(
            query: query,
            sort: sort,
            order: order,
            perPage: max(1, min(perPage, 100))
        )
        return try await get(url, observer: observer)
    }

    func loadCommitActivity(
        repository: RepoIdentity,
        ifNoneMatch: String?,
        observer: GitHubMetricsRequestObserver?
    ) async throws -> GitHubMetricsResponse<[GitHubWeeklyCommitActivity]> {
        try await get(
            endpoints.repository(repository, suffix: "stats/commit_activity"),
            ifNoneMatch: ifNoneMatch,
            observer: observer
        )
    }

    func loadContributors(
        repository: RepoIdentity,
        limit: Int,
        ifNoneMatch: String?,
        observer: GitHubMetricsRequestObserver?
    ) async throws -> GitHubMetricsResponse<[GitHubRepositoryContributorMetric]> {
        try await get(
            endpoints.repository(
                repository,
                suffix: "contributors",
                queryItems: [URLQueryItem(name: "per_page", value: String(max(1, min(limit, 100))))]
            ),
            ifNoneMatch: ifNoneMatch,
            observer: observer
        )
    }

    func loadCommunityProfile(
        repository: RepoIdentity,
        ifNoneMatch: String?,
        observer: GitHubMetricsRequestObserver?
    ) async throws -> GitHubMetricsResponse<GitHubRepositoryCommunityProfile> {
        try await get(
            endpoints.repository(repository, suffix: "community/profile"),
            ifNoneMatch: ifNoneMatch,
            observer: observer
        )
    }

    func loadIssueTemplateAvailability(
        repository: RepoIdentity,
        observer: GitHubMetricsRequestObserver?
    ) async throws -> Bool {
        do {
            let response: GitHubMetricsResponse<[GitHubRepositoryContentEntry]> = try await get(
                endpoints.repository(repository, suffix: "contents/.github/ISSUE_TEMPLATE"),
                observer: observer
            )
            return response.value.contains(where: \.isIssueTemplateCandidate)
        } catch GitHubRepositoryMetricsError.unavailable(let statusCode, _) where statusCode == 404 {
            // 没有 ISSUE_TEMPLATE 目录是正常的“未提供”状态，不应让整个社区信号加载失败。
            return false
        }
    }

    func loadReleases(
        repository: RepoIdentity,
        limit: Int,
        ifNoneMatch: String?,
        observer: GitHubMetricsRequestObserver?
    ) async throws -> GitHubMetricsResponse<[GitHubRepositoryReleaseMetric]> {
        try await get(
            endpoints.repository(
                repository,
                suffix: "releases",
                queryItems: [URLQueryItem(name: "per_page", value: String(max(1, min(limit, 100))))]
            ),
            ifNoneMatch: ifNoneMatch,
            observer: observer
        )
    }

    func loadSecurityAdvisories(
        repository: RepoIdentity,
        limit: Int,
        ifNoneMatch: String?,
        observer: GitHubMetricsRequestObserver?
    ) async throws -> GitHubMetricsResponse<[GitHubRepositorySecurityAdvisoryMetric]> {
        try await get(
            endpoints.repository(
                repository,
                suffix: "security-advisories",
                queryItems: [
                    URLQueryItem(name: "per_page", value: String(max(1, min(limit, 100)))),
                    URLQueryItem(name: "state", value: "published"),
                    URLQueryItem(name: "sort", value: "published"),
                    URLQueryItem(name: "direction", value: "desc")
                ]
            ),
            ifNoneMatch: ifNoneMatch,
            observer: observer
        )
    }

    /// 唯一出站点：统一认证、API version、ETag、限流响应头和状态码映射。
    private func get<Value: Decodable & Sendable>(
        _ url: URL,
        ifNoneMatch: String? = nil,
        observer: GitHubMetricsRequestObserver?
    ) async throws -> GitHubMetricsResponse<Value> {
        try await withDatabaseScope { [self] in
            try Task.checkCancellation()
            let currentToken = await tokenProvider.currentToken()?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // RAG observer 需要一一对应的 request / response / failure Trace，不能与普通洞察
            // 请求合并；普通洞察没有 observer，完全相同的 URL、validator、认证身份可以安全
            // 共享同一 Task。Token 只作为内存 Key，不记录日志或写入磁盘。
            if observer == nil {
                let key = GitHubMetricsInflightKey(
                    url: url,
                    ifNoneMatch: ifNoneMatch,
                    authorizationIdentity: currentToken,
                    requestIdentity: "GET"
                )
                return try await inflightTracker.value(for: key) { [self] in
                    try await executeSerializedGet(
                        url,
                        ifNoneMatch: ifNoneMatch,
                        token: currentToken,
                        observer: nil
                    )
                }
            }

            return try await executeSerializedGet(
                url,
                ifNoneMatch: ifNoneMatch,
                token: currentToken,
                observer: observer
            )
        }
    }

    /// gate 必须包住真正的网络 await。in-flight 合并发生在 gate 之前，否则重复调用会
    /// 先排入串行队列，等首个请求完成后仍继续发出第二个请求，达不到节省配额的目的。
    private func executeSerializedGet<Value: Decodable & Sendable>(
        _ url: URL,
        ifNoneMatch: String?,
        token: String?,
        observer: GitHubMetricsRequestObserver?
    ) async throws -> GitHubMetricsResponse<Value> {
        // Swift actor 在 await 期间可重入，单靠 actor 不能保证 URLSession 请求真正串行。
        // 显式 gate 覆盖整个网络 await，避免多个区块同时击中 secondary rate limit。
        await requestGate.acquire()
        let authorizationIdentity = GitHubMetricsAuthorizationIdentity(token: token)
        let failureKey = observer == nil
            ? GitHubMetricsFailureKey(
                url: url,
                authorizationIdentity: authorizationIdentity,
                requestIdentity: "GET"
            )
            : nil
        var didStartNetwork = false
        do {
            try Task.checkCancellation()
            try enforceRateLimitBackoff(for: authorizationIdentity)
            try enforceEndpointFailureBackoff(for: failureKey)
            didStartNetwork = true
            let result: GitHubMetricsResponse<Value> = try await performGet(
                url,
                ifNoneMatch: ifNoneMatch,
                token: token,
                observer: observer
            )
            clearEndpointFailure(for: failureKey)
            await requestGate.release()
            return result
        } catch {
            if didStartNetwork {
                recordRateLimitBackoff(from: error, authorizationIdentity: authorizationIdentity)
                recordEndpointFailure(from: error, for: failureKey)
            }
            await requestGate.release()
            throw error
        }
    }

    /// GraphQL 与 REST 共用同一串行 gate，避免页面首次加载时两类请求同时出站。
    private func executeSerializedActivityBundle(
        url: URL,
        repository: RepoIdentity,
        dateRange: String,
        token: String?
    ) async throws -> GitHubRepositoryActivityBundleMetric {
        await requestGate.acquire()
        let authorizationIdentity = GitHubMetricsAuthorizationIdentity(token: token)
        let failureKey = GitHubMetricsFailureKey(
            url: url,
            authorizationIdentity: authorizationIdentity,
            requestIdentity: "activity-bundle:\(repository.owner)/\(repository.name):\(dateRange)"
        )
        var didStartNetwork = false
        do {
            try Task.checkCancellation()
            try enforceRateLimitBackoff(for: authorizationIdentity)
            try enforceEndpointFailureBackoff(for: failureKey)
            didStartNetwork = true
            let result = try await performActivityBundle(
                url: url,
                repository: repository,
                dateRange: dateRange,
                token: token
            )
            clearEndpointFailure(for: failureKey)
            await requestGate.release()
            return result
        } catch {
            if didStartNetwork {
                recordRateLimitBackoff(from: error, authorizationIdentity: authorizationIdentity)
                recordEndpointFailure(from: error, for: failureKey)
            }
            await requestGate.release()
            throw error
        }
    }

    private func performActivityBundle(
        url: URL,
        repository: RepoIdentity,
        dateRange: String,
        token: String?
    ) async throws -> GitHubRepositoryActivityBundleMetric {
        let base = "repo:\(repository.owner)/\(repository.name)"
        let body = GitHubMetricsGraphQLRequest(
            query: Self.activityBundleQuery,
            variables: [
                "createdPullRequests": "\(base) is:pr created:\(dateRange)",
                "mergedPullRequests": "\(base) is:pr merged:\(dateRange)",
                "createdIssues": "\(base) is:issue created:\(dateRange)",
                "closedIssues": "\(base) is:issue closed:\(dateRange)",
                "recentPullRequests": "\(base) is:pr sort:updated-desc",
                "recentIssues": "\(base) is:issue sort:updated-desc"
            ]
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Starcat", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await httpClient.data(for: request)
        try Task.checkCancellation()
        let metadata = responseMetadata(response)
        guard response.statusCode == 200 else {
            throw mapError(data: data, response: response, metadata: metadata)
        }
        guard let envelope = try? JSONDecoder().decode(
            GitHubMetricsGraphQLEnvelope<GitHubActivityBundleGraphQLData>.self,
            from: data
        ) else {
            throw GitHubRepositoryMetricsError.invalidResponse
        }
        if let errors = envelope.errors, !errors.isEmpty {
            throw GitHubRepositoryMetricsError.http(
                statusCode: 400,
                message: errors.map(\.message).joined(separator: "; ")
            )
        }
        guard let payload = envelope.data else {
            throw GitHubRepositoryMetricsError.invalidResponse
        }
        return payload.metric
    }

    /// 六个 alias 共用一次 GraphQL POST；`issueCount` 给 KPI，nodes 只取最近 5 条。
    private static let activityBundleQuery = """
        query RepositoryActivityBundle(
          $createdPullRequests: String!,
          $mergedPullRequests: String!,
          $createdIssues: String!,
          $closedIssues: String!,
          $recentPullRequests: String!,
          $recentIssues: String!
        ) {
          createdPullRequests: search(query: $createdPullRequests, type: ISSUE, first: 1) {
            issueCount
          }
          mergedPullRequests: search(query: $mergedPullRequests, type: ISSUE, first: 1) {
            issueCount
          }
          createdIssues: search(query: $createdIssues, type: ISSUE, first: 1) {
            issueCount
          }
          closedIssues: search(query: $closedIssues, type: ISSUE, first: 1) {
            issueCount
          }
          recentPullRequests: search(query: $recentPullRequests, type: ISSUE, first: 5) {
            issueCount
            nodes {
              ... on PullRequest {
                number
                title
                url
                closedAt
                updatedAt
              }
            }
          }
          recentIssues: search(query: $recentIssues, type: ISSUE, first: 5) {
            issueCount
            nodes {
              ... on Issue {
                number
                title
                url
                closedAt
                updatedAt
              }
            }
          }
        }
        """

    private func performGet<Value: Decodable & Sendable>(
        _ url: URL,
        ifNoneMatch: String?,
        token: String?,
        observer: GitHubMetricsRequestObserver?
    ) async throws -> GitHubMetricsResponse<Value> {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Starcat", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let ifNoneMatch, !ifNoneMatch.isEmpty {
            request.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match")
        }

        observer?(.request(url))
        do {
            let (data, response) = try await httpClient.data(for: request)
            try Task.checkCancellation()
            observer?(.response(url, statusCode: response.statusCode))
            let metadata = responseMetadata(response)
            guard response.statusCode == 200 else {
                throw mapError(data: data, response: response, metadata: metadata)
            }
            guard let value = try? JSONDecoder().decode(Value.self, from: data) else {
                throw GitHubRepositoryMetricsError.invalidResponse
            }
            return GitHubMetricsResponse(
                value: value,
                requestURL: url,
                statusCode: response.statusCode,
                etag: response.value(forHTTPHeaderField: "ETag"),
                rateLimit: metadata
            )
        } catch {
            observer?(.failure(url, message: error.localizedDescription))
            throw error
        }
    }

    private func responseMetadata(_ response: HTTPURLResponse) -> GitHubMetricsRateLimit {
        let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init)
        let resetAt = response.value(forHTTPHeaderField: "X-RateLimit-Reset")
            .flatMap(TimeInterval.init)
            .map(Date.init(timeIntervalSince1970:))
        return GitHubMetricsRateLimit(
            remaining: remaining,
            resetAt: resetAt,
            retryAfter: retryAfter(from: response)
        )
    }

    private func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(value) {
            return max(0, seconds)
        }
        guard let date = HTTPDateParser.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now()))
    }

    private func mapError(
        data: Data,
        response: HTTPURLResponse,
        metadata: GitHubMetricsRateLimit
    ) -> GitHubRepositoryMetricsError {
        let message = (try? JSONDecoder().decode(GitHubMetricsErrorResponse.self, from: data).message)
            ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
        switch response.statusCode {
        case 202:
            return .generating(retryAfter: metadata.retryAfter)
        case 304:
            return .notModified(etag: response.value(forHTTPHeaderField: "ETag"))
        case 401:
            return .unauthorized
        case 403 where metadata.retryAfter != nil || metadata.remaining == 0:
            return .rateLimited(
                statusCode: response.statusCode,
                message: message,
                retryAfter: metadata.retryAfter,
                resetAt: metadata.resetAt
            )
        case 403:
            return .forbidden(message: message, resetAt: metadata.resetAt)
        case 429:
            return .rateLimited(
                statusCode: response.statusCode,
                message: message,
                retryAfter: metadata.retryAfter,
                resetAt: metadata.resetAt
            )
        case 404, 422:
            return .unavailable(statusCode: response.statusCode, message: message)
        default:
            return .http(statusCode: response.statusCode, message: message)
        }
    }

    /// 限流窗口内直接阻止后续排队请求继续出站。上层已有 stale-while-refresh，
    /// 因此快速返回稳定错误比在网络 gate 内长时间 sleep 更符合页面生命周期。
    private func enforceRateLimitBackoff(
        for authorizationIdentity: GitHubMetricsAuthorizationIdentity
    ) throws {
        guard let blockedUntil = rateLimitBackoffUntil[authorizationIdentity] else { return }
        let currentDate = now()
        guard currentDate < blockedUntil else {
            rateLimitBackoffUntil[authorizationIdentity] = nil
            return
        }
        throw GitHubRepositoryMetricsError.rateLimited(
            statusCode: 429,
            message: "GitHub rate limit backoff is active",
            retryAfter: blockedUntil.timeIntervalSince(currentDate),
            resetAt: blockedUntil
        )
    }

    /// GitHub 可能通过 Retry-After 或 X-RateLimit-Reset 表达恢复时间；取较晚值，
    /// 避免时钟误差导致提前重试。只有真实限流语义才会建立全客户端 backoff。
    private func recordRateLimitBackoff(
        from error: Error,
        authorizationIdentity: GitHubMetricsAuthorizationIdentity
    ) {
        guard let metricsError = error as? GitHubRepositoryMetricsError else { return }
        let deadline: Date?
        switch metricsError {
        case .rateLimited(_, _, let retryAfter, let resetAt):
            let currentDate = now()
            let retryDeadline = retryAfter.map { currentDate.addingTimeInterval($0) }
            deadline = [retryDeadline, resetAt].compactMap { $0 }.max()
        case .forbidden(_, let resetAt):
            deadline = resetAt
        default:
            deadline = nil
        }
        guard let deadline else { return }
        rateLimitBackoffUntil[authorizationIdentity] = max(
            rateLimitBackoffUntil[authorizationIdentity] ?? .distantPast,
            deadline
        )
    }

    /// endpoint 级失败缓存只服务普通洞察；RAG observer 请求仍保持一一对应的真实出站。
    private func enforceEndpointFailureBackoff(
        for key: GitHubMetricsFailureKey?
    ) throws {
        guard let key, let state = endpointFailureStates[key] else { return }
        let currentDate = now()
        // 到期后保留 failureCount，下一次真实尝试若仍失败才能继续指数增长；
        // 一旦成功会由 clearEndpointFailure 精确清掉。
        guard currentDate < state.blockedUntil else { return }
        if let cachedError = state.cachedError {
            throw cachedError
        }
        throw GitHubRepositoryMetricsError.http(
            statusCode: 503,
            message: "Repository metrics retry backoff is active"
        )
    }

    private func recordEndpointFailure(
        from error: Error,
        for key: GitHubMetricsFailureKey?
    ) {
        guard let key, !(error is CancellationError) else { return }
        let previousCount = endpointFailureStates[key]?.failureCount ?? 0
        let failureCount = min(previousCount + 1, 5)
        let currentDate = now()
        let state: GitHubMetricsFailureState?

        switch error as? GitHubRepositoryMetricsError {
        case .unavailable:
            state = GitHubMetricsFailureState(
                failureCount: failureCount,
                blockedUntil: currentDate.addingTimeInterval(24 * 60 * 60),
                cachedError: error as? GitHubRepositoryMetricsError
            )
        case .forbidden:
            state = GitHubMetricsFailureState(
                failureCount: failureCount,
                blockedUntil: currentDate.addingTimeInterval(5 * 60),
                cachedError: error as? GitHubRepositoryMetricsError
            )
        case .generating(let retryAfter):
            state = GitHubMetricsFailureState(
                failureCount: failureCount,
                blockedUntil: currentDate.addingTimeInterval(retryAfter ?? 2),
                cachedError: error as? GitHubRepositoryMetricsError
            )
        case .unauthorized, .rateLimited, .notModified:
            state = nil
        case .http, .invalidResponse, .none:
            let delay = min(pow(2, Double(failureCount)), 30)
            state = GitHubMetricsFailureState(
                failureCount: failureCount,
                blockedUntil: currentDate.addingTimeInterval(delay),
                cachedError: nil
            )
        }

        if let state {
            endpointFailureStates[key] = state
            trimEndpointFailureStatesIfNeeded()
        } else {
            endpointFailureStates[key] = nil
        }
    }

    private func clearEndpointFailure(for key: GitHubMetricsFailureKey?) {
        guard let key else { return }
        endpointFailureStates[key] = nil
    }

    private func trimEndpointFailureStatesIfNeeded() {
        let maximumEntries = 128
        guard endpointFailureStates.count > maximumEntries else { return }
        let overflow = endpointFailureStates.count - maximumEntries
        for key in endpointFailureStates
            .sorted(by: { $0.value.blockedUntil < $1.value.blockedUntil })
            .prefix(overflow)
            .map(\.key) {
            endpointFailureStates[key] = nil
        }
    }
}

private struct GitHubMetricsErrorResponse: Decodable {
    let message: String
}

private struct GitHubMetricsAuthorizationIdentity: Hashable, Sendable {
    let token: String?
}

private struct GitHubMetricsFailureKey: Hashable, Sendable {
    let url: URL
    let authorizationIdentity: GitHubMetricsAuthorizationIdentity
    let requestIdentity: String
}

private struct GitHubMetricsFailureState: Sendable {
    let failureCount: Int
    let blockedUntil: Date
    let cachedError: GitHubRepositoryMetricsError?
}

private struct GitHubMetricsGraphQLRequest: Encodable {
    let query: String
    let variables: [String: String]
}

private struct GitHubMetricsGraphQLError: Decodable {
    let message: String
}

private struct GitHubMetricsGraphQLEnvelope<Payload: Decodable>: Decodable {
    let data: Payload?
    let errors: [GitHubMetricsGraphQLError]?
}

private struct GitHubActivityBundleGraphQLData: Decodable {
    private struct EventNode: Decodable {
        let number: Int?
        let title: String?
        let url: String?
        let closedAt: String?
        let updatedAt: String?

        var metric: GitHubRepositoryActivityEventMetric? {
            guard let number,
                  let title,
                  let url,
                  let occurredAt = closedAt ?? updatedAt
            else {
                return nil
            }
            return GitHubRepositoryActivityEventMetric(
                number: number,
                title: title,
                htmlURL: url,
                occurredAt: occurredAt
            )
        }
    }

    private struct SearchConnection: Decodable {
        let issueCount: Int
        let nodes: [EventNode?]?

        var events: [GitHubRepositoryActivityEventMetric] {
            nodes?.compactMap { $0?.metric } ?? []
        }
    }

    private let createdPullRequests: SearchConnection
    private let mergedPullRequests: SearchConnection
    private let createdIssues: SearchConnection
    private let closedIssues: SearchConnection
    private let recentPullRequests: SearchConnection
    private let recentIssues: SearchConnection

    var metric: GitHubRepositoryActivityBundleMetric {
        GitHubRepositoryActivityBundleMetric(
            createdPullRequests: createdPullRequests.issueCount,
            mergedPullRequests: mergedPullRequests.issueCount,
            createdIssues: createdIssues.issueCount,
            closedIssues: closedIssues.issueCount,
            recentPullRequests: recentPullRequests.events,
            recentIssues: recentIssues.events
        )
    }
}

private struct FixedGitHubTokenProvider: GitHubTokenProviding {
    let token: String?

    func currentToken() async -> String? {
        token
    }
}

/// 普通洞察请求的进程内去重 Key。
///
/// 认证身份必须进入 Key：登录切换发生在网络 await 期间时，新账户不能等待旧 Token 发起
/// 的请求。Token 仅存在于内存字典且从不输出；退出登录后旧 Task 完成即自动释放。
private struct GitHubMetricsInflightKey: Hashable, Sendable {
    let url: URL
    let ifNoneMatch: String?
    let authorizationIdentity: String?
    let requestIdentity: String
}

/// `Any` 只用于同一 Key 的泛型响应暂存。Key 已同时固定 URL 和请求契约，同一 URL 在
/// Metrics Client 中只会解码为一种 DTO；取值时仍做动态类型校验，未来端点复用 URL 时
/// 不会发生强制转换崩溃。
private struct GitHubMetricsInflightValue: @unchecked Sendable {
    let value: Any
}

/// 合并完全相同的普通 Metrics GET。实现沿用 README in-flight tracker 的成功经验：
/// 首个调用创建 Task，后续调用 await 同一个 Task；Task 在成功或失败终态先清理字典，
/// 避免完成态条目长期占用内存或遮蔽下一次手动刷新。
private actor GitHubMetricsInflightTracker {
    private var inflight: [
        GitHubMetricsInflightKey: Task<GitHubMetricsInflightValue, Error>
    ] = [:]

    func value<Value: Sendable>(
        for key: GitHubMetricsInflightKey,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        if let existing = inflight[key] {
            let boxed = try await existing.value
            guard let value = boxed.value as? Value else {
                throw GitHubRepositoryMetricsError.invalidResponse
            }
            return value
        }

        let task = Task<GitHubMetricsInflightValue, Error> { [weak self] in
            do {
                let value = try await operation()
                await self?.clear(key)
                return GitHubMetricsInflightValue(value: value)
            } catch {
                await self?.clear(key)
                throw error
            }
        }
        inflight[key] = task
        let boxed = try await task.value
        guard let value = boxed.value as? Value else {
            throw GitHubRepositoryMetricsError.invalidResponse
        }
        return value
    }

    private func clear(_ key: GitHubMetricsInflightKey) {
        inflight[key] = nil
    }

    /// 切账号时先取消、再等待所有共享任务完成，确保调用方不会把旧响应写进新数据库。
    func cancelAllAndWait() async {
        let tasks = Array(inflight.values)
        inflight.removeAll(keepingCapacity: true)
        tasks.forEach { $0.cancel() }
        for task in tasks {
            _ = try? await task.value
        }
    }
}

/// 数据库作用域读写屏障：请求持有 read lease；切库先关闭入口、取消请求并等待 drain。
private actor GitHubMetricsDatabaseScopeBarrier {
    private var isChanging = false
    private var activeRequests = 0
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        while isChanging {
            await withCheckedContinuation { continuation in
                entryWaiters.append(continuation)
            }
        }
        activeRequests += 1
    }

    func leave() {
        activeRequests = max(0, activeRequests - 1)
        guard activeRequests == 0 else { return }
        let waiters = drainWaiters
        drainWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func beginChange() {
        isChanging = true
    }

    func waitUntilDrained() async {
        guard activeRequests > 0 else { return }
        await withCheckedContinuation { continuation in
            drainWaiters.append(continuation)
        }
    }

    func endChange() {
        isChanging = false
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

/// actor 可重入，因此用 continuation gate 保证“正在 await 的网络请求”也占有串行槽位。
private actor GitHubMetricsRequestGate {
    private var isAcquired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isAcquired else {
            isAcquired = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            isAcquired = false
            return
        }
        waiters.removeFirst().resume()
    }
}

/// Retry-After 允许 HTTP-date；使用固定 POSIX locale，避免跟随 App Locale 解析失败。
private enum HTTPDateParser {
    static func date(from value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: value)
    }
}
