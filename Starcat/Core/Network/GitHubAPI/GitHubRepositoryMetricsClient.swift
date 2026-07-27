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

/// GitHub 最近 52 周 Commit Activity 的一周数据。
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
    private struct CommunityFile: Decodable, Equatable, Sendable {}
    private struct Files: Decodable, Equatable, Sendable {
        let codeOfConduct: CommunityFile?
        let codeOfConductFile: CommunityFile?
        let contributing: CommunityFile?
        let license: CommunityFile?
        let readme: CommunityFile?

        enum CodingKeys: String, CodingKey {
            case codeOfConduct = "code_of_conduct"
            case codeOfConductFile = "code_of_conduct_file"
            case contributing, license, readme
        }
    }

    let healthPercentage: Int
    private let files: Files

    var hasReadme: Bool { files.readme != nil }
    var hasCodeOfConduct: Bool { files.codeOfConduct != nil || files.codeOfConductFile != nil }
    var hasContributing: Bool { files.contributing != nil }
    var hasLicense: Bool { files.license != nil }

    enum CodingKeys: String, CodingKey {
        case healthPercentage = "health_percentage"
        case files
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
    let ghsaID: String
    let cveID: String?
    let summary: String
    let severity: String
    let htmlURL: String?
    let publishedAt: String

    enum CodingKeys: String, CodingKey {
        case summary, severity
        case ghsaID = "ghsa_id"
        case cveID = "cve_id"
        case htmlURL = "html_url"
        case publishedAt = "published_at"
    }
}

/// 类型化端点协议。observer 只服务 RAG Debug Trace，普通洞察调用传 nil。
protocol GitHubRepositoryMetricsClient: Sendable {
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
        observer: GitHubMetricsRequestObserver?
    ) async throws -> GitHubMetricsResponse<[GitHubWeeklyCommitActivity]>

    func loadContributors(
        repository: RepoIdentity,
        limit: Int,
        observer: GitHubMetricsRequestObserver?
    ) async throws -> GitHubMetricsResponse<[GitHubRepositoryContributorMetric]>

    func loadCommunityProfile(
        repository: RepoIdentity,
        observer: GitHubMetricsRequestObserver?
    ) async throws -> GitHubMetricsResponse<GitHubRepositoryCommunityProfile>

    func loadReleases(
        repository: RepoIdentity,
        limit: Int,
        observer: GitHubMetricsRequestObserver?
    ) async throws -> GitHubMetricsResponse<[GitHubRepositoryReleaseMetric]>

    func loadSecurityAdvisories(
        repository: RepoIdentity,
        limit: Int,
        observer: GitHubMetricsRequestObserver?
    ) async throws -> GitHubMetricsResponse<[GitHubRepositorySecurityAdvisoryMetric]>
}

extension GitHubRepositoryMetricsClient {
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
        repository: RepoIdentity
    ) async throws -> GitHubMetricsResponse<[GitHubWeeklyCommitActivity]> {
        try await loadCommitActivity(repository: repository, observer: nil)
    }

    func loadContributors(
        repository: RepoIdentity,
        limit: Int
    ) async throws -> GitHubMetricsResponse<[GitHubRepositoryContributorMetric]> {
        try await loadContributors(repository: repository, limit: limit, observer: nil)
    }

    func loadCommunityProfile(
        repository: RepoIdentity
    ) async throws -> GitHubMetricsResponse<GitHubRepositoryCommunityProfile> {
        try await loadCommunityProfile(repository: repository, observer: nil)
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
        observer: GitHubMetricsRequestObserver?
    ) async throws -> GitHubMetricsResponse<[GitHubWeeklyCommitActivity]> {
        try await get(
            endpoints.repository(repository, suffix: "stats/commit_activity"),
            observer: observer
        )
    }

    func loadContributors(
        repository: RepoIdentity,
        limit: Int,
        observer: GitHubMetricsRequestObserver?
    ) async throws -> GitHubMetricsResponse<[GitHubRepositoryContributorMetric]> {
        try await get(
            endpoints.repository(
                repository,
                suffix: "contributors",
                queryItems: [URLQueryItem(name: "per_page", value: String(max(1, min(limit, 100))))]
            ),
            observer: observer
        )
    }

    func loadCommunityProfile(
        repository: RepoIdentity,
        observer: GitHubMetricsRequestObserver?
    ) async throws -> GitHubMetricsResponse<GitHubRepositoryCommunityProfile> {
        try await get(
            endpoints.repository(repository, suffix: "community/profile"),
            observer: observer
        )
    }

    func loadReleases(
        repository: RepoIdentity,
        limit: Int,
        observer: GitHubMetricsRequestObserver?
    ) async throws -> GitHubMetricsResponse<[GitHubRepositoryReleaseMetric]> {
        try await get(
            endpoints.repository(
                repository,
                suffix: "releases",
                queryItems: [URLQueryItem(name: "per_page", value: String(max(1, min(limit, 100))))]
            ),
            observer: observer
        )
    }

    func loadSecurityAdvisories(
        repository: RepoIdentity,
        limit: Int,
        observer: GitHubMetricsRequestObserver?
    ) async throws -> GitHubMetricsResponse<[GitHubRepositorySecurityAdvisoryMetric]> {
        try await get(
            endpoints.repository(
                repository,
                suffix: "security-advisories",
                queryItems: [URLQueryItem(name: "per_page", value: String(max(1, min(limit, 100))))]
            ),
            observer: observer
        )
    }

    /// 唯一出站点：统一认证、API version、ETag、限流响应头和状态码映射。
    private func get<Value: Decodable & Sendable>(
        _ url: URL,
        ifNoneMatch: String? = nil,
        observer: GitHubMetricsRequestObserver?
    ) async throws -> GitHubMetricsResponse<Value> {
        // Swift actor 在 await 期间可重入，单靠 actor 不能保证 URLSession 请求真正串行。
        // 显式 gate 覆盖整个网络 await，避免多个区块同时击中 secondary rate limit。
        await requestGate.acquire()
        do {
            try Task.checkCancellation()
            let result: GitHubMetricsResponse<Value> = try await performGet(
                url,
                ifNoneMatch: ifNoneMatch,
                observer: observer
            )
            await requestGate.release()
            return result
        } catch {
            await requestGate.release()
            throw error
        }
    }

    private func performGet<Value: Decodable & Sendable>(
        _ url: URL,
        ifNoneMatch: String?,
        observer: GitHubMetricsRequestObserver?
    ) async throws -> GitHubMetricsResponse<Value> {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Starcat", forHTTPHeaderField: "User-Agent")
        let currentToken = await tokenProvider.currentToken()
        if let token = currentToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let ifNoneMatch, !ifNoneMatch.isEmpty {
            request.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match")
        }

        observer?(.request(url))
        do {
            let (data, response) = try await httpClient.data(for: request)
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
}

private struct GitHubMetricsErrorResponse: Decodable {
    let message: String
}

private struct FixedGitHubTokenProvider: GitHubTokenProviding {
    let token: String?

    func currentToken() async -> String? {
        token
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
