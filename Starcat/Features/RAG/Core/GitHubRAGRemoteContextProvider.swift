//
//  GitHubRAGRemoteContextProvider.swift
//  Starcat
//
//  按 Query Planner 意图为候选 repo 临时读取 GitHub 现场数据。
//
//  这些结果只存在于本轮 RAG 请求，不写数据库和 chunk 索引。每个 repo/resource 独立降级，
//  单个 GitHub 请求失败不会抹掉已经取得的本地知识库证据。
//

import Foundation
import CryptoKit

/// GitHub 远程证据中由 Starcat 生成、且会直接展示在 Inspector 的固定文案。
/// API 返回的标题、正文和字段保持原文；这里只本地化空态与聚合说明，避免英文界面泄漏中文。
enum RAGRemoteContextCopy {
    static var noPublicMatches: String { String.l10n("rag.core.remote.empty.matches") }
    static var noPublicReleases: String { String.l10n("rag.core.remote.empty.releases") }
    static var noPublicContributors: String { String.l10n("rag.core.remote.empty.contributors") }
    static var noPublicSecurityAdvisories: String { String.l10n("rag.core.remote.empty.securityAdvisories") }

    static func commitActivity(total: Int, activeWeeks: Int, weekCount: Int) -> String {
        String(
            format: String.l10n("rag.core.remote.commitActivityFormat"),
            Int64(total),
            Int64(activeWeeks),
            Int64(weekCount)
        )
    }
}

protocol RAGHTTPClientProtocol: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionRAGHTTPClient: RAGHTTPClientProtocol {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, response)
    }
}

struct GitHubRAGRemoteContextProvider: KnowledgeRAGDebuggableRemoteContextProviding {
    private let metricsClient: any GitHubRepositoryMetricsClient
    private let endpoints: GitHubRepositoryMetricsEndpointBuilder
    private let cacheNamespace: String
    private let cache: RAGRemoteContextMemoryCache

    init(
        httpClient: any RAGHTTPClientProtocol = URLSessionRAGHTTPClient(),
        token: String?,
        baseURL: URL = URL(string: "https://api.github.com")!,
        cache: RAGRemoteContextMemoryCache = .shared
    ) {
        let normalizedToken = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.metricsClient = DefaultGitHubRepositoryMetricsClient(
            httpClient: httpClient,
            token: normalizedToken,
            baseURL: baseURL
        )
        self.endpoints = GitHubRepositoryMetricsEndpointBuilder(baseURL: baseURL)
        self.cacheNamespace = Self.cacheNamespace(for: normalizedToken)
        self.cache = cache
    }

    func fetch(
        workItems: [RAGResolvedRemoteWorkItem],
        onProgress: @escaping @Sendable (RAGRemoteContextFetchProgress) -> Void
    ) async -> [RAGRemoteContextBlock] {
        await fetch(
            workItems: workItems,
            onProgress: onProgress,
            onDebug: { _ in }
        )
    }

    func fetch(
        workItems: [RAGResolvedRemoteWorkItem],
        onProgress: @escaping @Sendable (RAGRemoteContextFetchProgress) -> Void,
        onDebug: @escaping @Sendable (RAGRemoteContextDebugEvent) -> Void
    ) async -> [RAGRemoteContextBlock] {
        let work = workItems.enumerated().map { index, item in
            RemoteFetchWork(index: index, item: item)
        }
        guard !work.isEmpty else { return [] }

        var completed = 0
        var indexedBlocks: [IndexedRemoteBlock] = []
        for start in stride(from: 0, to: work.count, by: Self.maxConcurrentRequests) {
            guard !Task.isCancelled else { break }
            let end = min(start + Self.maxConcurrentRequests, work.count)
            await withTaskGroup(of: IndexedRemoteBlock?.self) { group in
                for item in work[start..<end] {
                    group.addTask { await fetchBlock(for: item, onDebug: onDebug) }
                }
                for await result in group {
                    guard !Task.isCancelled else { continue }
                    completed += 1
                    onProgress(.init(completed: completed, total: work.count))
                    if let result { indexedBlocks.append(result) }
                }
            }
        }
        return indexedBlocks.sorted { $0.index < $1.index }.map(\.block)
    }

    /// GitHub 的速率与客户端连接数都有限。小批并发覆盖慢网络而不让一次 Planner 输出
    /// 形成请求风暴；`index` 使 UI 与 Prompt 保持原始 request/candidate 的稳定顺序。
    private func fetchBlock(
        for work: RemoteFetchWork,
        onDebug: @escaping @Sendable (RAGRemoteContextDebugEvent) -> Void
    ) async -> IndexedRemoteBlock? {
        guard !Task.isCancelled else { return nil }
        let repo = work.item.candidate.repo
        let contextRequest = work.item.request
        let cacheKey = "\(cacheNamespace)|\(repo.id)|\(contextRequest.resource.rawValue)|\(contextRequest.query)|\(contextRequest.perRepoLimit)|\(contextRequest.state.rawValue)|\(contextRequest.sort.rawValue)|\(contextRequest.order.rawValue)"
        if let cached = await cache.value(for: cacheKey) {
            onDebug(RAGRemoteContextDebugEvent(
                repoFullName: repo.fullName,
                resource: contextRequest.resource,
                url: nil,
                outcome: .cacheHit
            ))
            var cacheBlock = cached
            cacheBlock.id = work.item.id
            cacheBlock.transport = .cache
            cacheBlock.startedAt = Date()
            cacheBlock.completedAt = Date()
            return IndexedRemoteBlock(index: work.index, block: cacheBlock)
        }
        let startedAt = Date()
        do {
            let block = try await fetchOne(work.item, startedAt: startedAt, onDebug: onDebug)
            guard !Task.isCancelled else { return nil }
            await cache.insert(block, for: cacheKey)
            return IndexedRemoteBlock(index: work.index, block: block)
        } catch {
            // URLSession 取消通常以 URLError.cancelled 抛出，不能把它伪装成 GitHub 失败提示。
            guard !Task.isCancelled else { return nil }
            return IndexedRemoteBlock(index: work.index, block: RAGRemoteContextBlock(
                id: work.item.id,
                repoId: repo.id,
                resource: contextRequest.resource,
                title: "\(repo.fullName) · \(displayName(contextRequest.resource))",
                sourceURL: URL(string: repo.htmlUrl),
                content: "",
                fetchedAt: Date(),
                errorMessage: error.localizedDescription,
                outcome: .failed,
                transport: .network,
                httpStatusCode: Self.httpStatusCode(from: error),
                resultCount: 0,
                requestURL: requestURL(for: contextRequest, repo: repo),
                startedAt: startedAt,
                completedAt: Date(),
                providerName: "GitHub",
                querySummary: contextRequest.query
            ))
        }
    }

    private static let maxConcurrentRequests = 3

    private func fetchOne(
        _ workItem: RAGResolvedRemoteWorkItem,
        startedAt: Date,
        onDebug: @escaping @Sendable (RAGRemoteContextDebugEvent) -> Void
    ) async throws -> RAGRemoteContextBlock {
        let contextRequest = workItem.request
        let repo = workItem.candidate.repo
        let result: RemoteFetchResult
        switch contextRequest.resource {
        case .githubIssues:
            result = try await fetchIssues(repo: repo, request: contextRequest, pullRequests: false, onDebug: onDebug)
        case .githubPullRequests:
            result = try await fetchIssues(repo: repo, request: contextRequest, pullRequests: true, onDebug: onDebug)
        case .githubReleases:
            result = try await fetchReleases(repo: repo, limit: contextRequest.perRepoLimit, resource: contextRequest.resource, onDebug: onDebug)
        case .githubContributors:
            result = try await fetchContributors(repo: repo, limit: contextRequest.perRepoLimit, resource: contextRequest.resource, onDebug: onDebug)
        case .githubCommitActivity:
            result = try await fetchCommitActivity(repo: repo, resource: contextRequest.resource, onDebug: onDebug)
        case .githubSecurityAdvisories:
            result = try await fetchSecurityAdvisories(repo: repo, limit: contextRequest.perRepoLimit, resource: contextRequest.resource, onDebug: onDebug)
        case .externalWeb:
            // 普通 Web 搜索由 RAGExternalWebSearchProvider 执行；到达这里说明调用方越过了
            // resolver 的资源分流，必须失败而不是误发 GitHub 请求。
            throw GitHubRemoteContextError.unsupportedResource
        }
        return RAGRemoteContextBlock(
            id: workItem.id,
            repoId: repo.id,
            resource: contextRequest.resource,
            title: "\(repo.fullName) · \(displayName(contextRequest.resource))",
            sourceURL: result.url,
            content: result.content,
            fetchedAt: Date(),
            errorMessage: nil,
            outcome: result.count > 0 ? .success : .empty,
            transport: .network,
            httpStatusCode: 200,
            resultCount: result.count,
            requestURL: result.url,
            startedAt: startedAt,
            completedAt: Date(),
            providerName: "GitHub",
            querySummary: contextRequest.query,
            resultPreviews: result.previews
        )
    }

    private func fetchIssues(
        repo: Repo,
        request: RAGRemoteContextRequest,
        pullRequests: Bool,
        onDebug: @escaping @Sendable (RAGRemoteContextDebugEvent) -> Void
    ) async throws -> RemoteFetchResult {
        let kind = pullRequests ? "is:pr" : "is:issue"
        let state = request.state == .all ? "" : " is:\(request.state.rawValue)"
        let keywords = Self.sanitizedIssueKeywords(request.query)
        let searchQuery = "repo:\(repo.fullName) \(kind)\(state)\(keywords.isEmpty ? "" : " \(keywords)")"
        let response = try await mappedMetricsRequest {
            try await metricsClient.searchIssues(
                repository: identity(for: repo),
                query: searchQuery,
                sort: request.sort.rawValue,
                order: request.order.rawValue,
                perPage: request.perRepoLimit,
                observer: requestObserver(
                    repoFullName: repo.fullName,
                    resource: request.resource,
                    onDebug: onDebug
                )
            )
        }
        // Planner 生成的 query 不能被当作可信 GitHub Search 语法。即使 query 夹带
        // `OR repo:other/name` 等 qualifier，也只接受当前候选 repo 的返回项。
        let scopedItems = response.value.items.filter {
            $0.belongs(to: identity(for: repo)) && $0.isPullRequest == pullRequests
        }
        let lines = scopedItems.prefix(request.perRepoLimit).map { item in
            let labels = item.labels.map(\.name).joined(separator: ", ")
            return """
                #\(item.number) [\(item.state)] \(item.title)
                updated=\(item.updatedAt); comments=\(item.comments); labels=\(labels); url=\(item.htmlURL)
                \(clip(item.body ?? "", limit: 800))
                """
        }
        let themes = Dictionary(grouping: scopedItems.flatMap(\.labels).map(\.name), by: { $0 })
            .map { ($0.key, $0.value.count) }
            .sorted { $0.1 > $1.1 }
            .prefix(5)
            .map { "\($0.0)(\($0.1))" }
            .joined(separator: ", ")
        let content = lines.isEmpty
            ? RAGRemoteContextCopy.noPublicMatches
            : "observed_themes=\(themes.isEmpty ? "none" : themes)\n\n\(lines.joined(separator: "\n\n"))"
        let previews = scopedItems.prefix(min(request.perRepoLimit, 5)).compactMap { item -> RAGRemoteResultPreview? in
            guard let url = URL(string: item.htmlURL) else { return nil }
            return RAGRemoteResultPreview(title: "#\(item.number) \(item.title)", url: url, providerName: "GitHub")
        }
        return RemoteFetchResult(
            content: content,
            url: response.requestURL,
            count: min(scopedItems.count, request.perRepoLimit),
            previews: previews
        )
    }

    private func fetchReleases(
        repo: Repo,
        limit: Int,
        resource: RAGRemoteContextResource,
        onDebug: @escaping @Sendable (RAGRemoteContextDebugEvent) -> Void
    ) async throws -> RemoteFetchResult {
        let response = try await mappedMetricsRequest {
            try await metricsClient.loadReleases(
                repository: identity(for: repo),
                limit: limit,
                observer: requestObserver(
                    repoFullName: repo.fullName,
                    resource: resource,
                    onDebug: onDebug
                )
            )
        }
        let lines = response.value.prefix(limit).map { release in
            """
            \(release.name ?? release.tagName) (\(release.tagName)) published=\(release.publishedAt ?? "unknown")
            url=\(release.htmlURL)
            \(clip(release.body ?? "", limit: 1_000))
            """
        }
        return RemoteFetchResult(
            content: lines.isEmpty ? RAGRemoteContextCopy.noPublicReleases : lines.joined(separator: "\n\n"),
            url: response.requestURL,
            count: min(response.value.count, limit)
        )
    }

    private func fetchContributors(
        repo: Repo,
        limit: Int,
        resource: RAGRemoteContextResource,
        onDebug: @escaping @Sendable (RAGRemoteContextDebugEvent) -> Void
    ) async throws -> RemoteFetchResult {
        let response = try await mappedMetricsRequest {
            try await metricsClient.loadContributors(
                repository: identity(for: repo),
                limit: limit,
                observer: requestObserver(
                    repoFullName: repo.fullName,
                    resource: resource,
                    onDebug: onDebug
                )
            )
        }
        let lines = response.value.prefix(limit).map {
            "\($0.login): contributions=\($0.contributions); url=\($0.htmlURL ?? "")"
        }
        return RemoteFetchResult(
            content: lines.isEmpty ? RAGRemoteContextCopy.noPublicContributors : lines.joined(separator: "\n"),
            url: response.requestURL,
            count: min(response.value.count, limit)
        )
    }

    private func fetchCommitActivity(
        repo: Repo,
        resource: RAGRemoteContextResource,
        onDebug: @escaping @Sendable (RAGRemoteContextDebugEvent) -> Void
    ) async throws -> RemoteFetchResult {
        let response = try await mappedMetricsRequest {
            try await metricsClient.loadCommitActivity(
                repository: identity(for: repo),
                observer: requestObserver(
                    repoFullName: repo.fullName,
                    resource: resource,
                    onDebug: onDebug
                )
            )
        }
        let recent = response.value.suffix(12)
        let total = recent.reduce(0) { $0 + $1.total }
        let activeWeeks = recent.filter { $0.total > 0 }.count
        return RemoteFetchResult(
            content: RAGRemoteContextCopy.commitActivity(
                total: total,
                activeWeeks: activeWeeks,
                weekCount: recent.count
            ),
            url: response.requestURL,
            count: recent.count
        )
    }

    private func fetchSecurityAdvisories(
        repo: Repo,
        limit: Int,
        resource: RAGRemoteContextResource,
        onDebug: @escaping @Sendable (RAGRemoteContextDebugEvent) -> Void
    ) async throws -> RemoteFetchResult {
        let response = try await mappedMetricsRequest {
            try await metricsClient.loadSecurityAdvisories(
                repository: identity(for: repo),
                limit: limit,
                observer: requestObserver(
                    repoFullName: repo.fullName,
                    resource: resource,
                    onDebug: onDebug
                )
            )
        }
        let lines = response.value.prefix(limit).map {
            "\($0.ghsaID) severity=\($0.severity) cve=\($0.cveID ?? "unknown") published=\($0.publishedAt)\n\($0.summary)\nurl=\($0.htmlURL ?? "")"
        }
        return RemoteFetchResult(
            content: lines.isEmpty ? RAGRemoteContextCopy.noPublicSecurityAdvisories : lines.joined(separator: "\n\n"),
            url: response.requestURL,
            count: min(response.value.count, limit)
        )
    }

    /// 审计 UI 需要展示实际 endpoint，但失败路径不能依赖“请求成功后才返回的 URL”。这里
    /// 与各 fetch 方法复用同一构造规则，只包含公开 URL，不包含任何请求头。
    private func requestURL(for request: RAGRemoteContextRequest, repo: Repo) -> URL? {
        let repository = identity(for: repo)
        switch request.resource {
        case .githubIssues, .githubPullRequests:
            let kind = request.resource == .githubPullRequests ? "is:pr" : "is:issue"
            let state = request.state == .all ? "" : " is:\(request.state.rawValue)"
            let keywords = Self.sanitizedIssueKeywords(request.query)
            return endpoints.searchIssues(
                query: "repo:\(repo.fullName) \(kind)\(state)\(keywords.isEmpty ? "" : " \(keywords)")",
                sort: request.sort.rawValue,
                order: request.order.rawValue,
                perPage: max(1, min(request.perRepoLimit, 100))
            )
        case .githubReleases:
            return endpoints.repository(
                repository,
                suffix: "releases",
                queryItems: [URLQueryItem(name: "per_page", value: String(max(1, min(request.perRepoLimit, 100))))]
            )
        case .githubContributors:
            return endpoints.repository(
                repository,
                suffix: "contributors",
                queryItems: [URLQueryItem(name: "per_page", value: String(max(1, min(request.perRepoLimit, 100))))]
            )
        case .githubCommitActivity:
            return endpoints.repository(repository, suffix: "stats/commit_activity")
        case .githubSecurityAdvisories:
            return endpoints.repository(
                repository,
                suffix: "security-advisories",
                queryItems: [URLQueryItem(name: "per_page", value: String(max(1, min(request.perRepoLimit, 100))))]
            )
        case .externalWeb:
            return nil
        }
    }

    private func identity(for repo: Repo) -> RepoIdentity {
        RepoIdentity(ghRepoID: repo.id, owner: repo.owner, name: repo.name)
    }

    /// 把共享 Client 的请求事件适配回 RAG 审计模型。事件始终不含请求头与 token。
    private func requestObserver(
        repoFullName: String,
        resource: RAGRemoteContextResource,
        onDebug: @escaping @Sendable (RAGRemoteContextDebugEvent) -> Void
    ) -> GitHubMetricsRequestObserver {
        { event in
            switch event {
            case .request(let url):
                onDebug(RAGRemoteContextDebugEvent(
                    repoFullName: repoFullName,
                    resource: resource,
                    url: url.absoluteString,
                    outcome: .request
                ))
            case .response(let url, let statusCode):
                onDebug(RAGRemoteContextDebugEvent(
                    repoFullName: repoFullName,
                    resource: resource,
                    url: url.absoluteString,
                    outcome: .response(statusCode: statusCode)
                ))
            case .failure(let url, let message):
                onDebug(RAGRemoteContextDebugEvent(
                    repoFullName: repoFullName,
                    resource: resource,
                    url: url.absoluteString,
                    outcome: .failure(message)
                ))
            }
        }
    }

    /// RAG 对外继续沿用既有本地化 HTTP 错误；洞察则直接消费 Metrics 的稳定错误枚举。
    private func mappedMetricsRequest<Value>(
        _ operation: () async throws -> Value
    ) async throws -> Value {
        do {
            return try await operation()
        } catch let error as GitHubRepositoryMetricsError {
            if let statusCode = error.statusCode {
                throw GitHubRemoteContextError.http(
                    status: statusCode,
                    message: error.localizedDescription
                )
            }
            throw error
        }
    }

    private func clip(_ value: String, limit: Int) -> String {
        String(value.replacingOccurrences(of: "\u{0000}", with: "").prefix(limit))
    }

    private func displayName(_ resource: RAGRemoteContextResource) -> String {
        switch resource {
        case .githubIssues: return "GitHub Issues"
        case .githubPullRequests: return "GitHub Pull Requests"
        case .githubReleases: return "GitHub Releases"
        case .githubContributors: return "GitHub Contributors"
        case .githubCommitActivity: return "GitHub Commit Activity"
        case .githubSecurityAdvisories: return "GitHub Security Advisories"
        case .externalWeb: return "Web Search"
        }
    }

    /// Planner 输出是不可信搜索文本。固定的 repo/kind/state qualifier 由 Provider 自己添加，
    /// 用户关键词中的 scope qualifier 必须移除，防止 `OR repo:other/name` 扩大请求范围。
    private static func sanitizedIssueKeywords(_ query: String) -> String {
        let qualifierPattern = try? NSRegularExpression(
            pattern: #"(?i)(^|[^a-z0-9_])(repo|org|user|is|type|in):"#
        )
        return query
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { token in
                let logicalToken = token.trimmingCharacters(in: .punctuationCharacters).uppercased()
                let range = NSRange(token.startIndex..<token.endIndex, in: token)
                return logicalToken != "OR"
                    && qualifierPattern?.firstMatch(in: token, range: range) == nil
            }
            .joined(separator: " ")
    }

    private static func httpStatusCode(from error: Error) -> Int? {
        guard case GitHubRemoteContextError.http(let status, _) = error else { return nil }
        return status
    }

    /// 进程内 cache 会跨账户存活，必须按认证身份隔离。这里只保留不可逆短指纹作为
    /// dictionary namespace，不写日志、数据库或网络请求。
    private static func cacheNamespace(for token: String?) -> String {
        guard let token, !token.isEmpty else { return "anonymous" }
        return SHA256.hash(data: Data(token.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

private struct RemoteFetchWork: Sendable {
    var index: Int
    var item: RAGResolvedRemoteWorkItem
}

private struct RemoteFetchResult: Sendable {
    /// 送入 Generator 的远程证据协议，不是 UI 产品文案。空结果标签也保持稳定，避免切换
    /// App 语言后同一 GitHub 响应产生不同 Prompt；面向用户的错误另走 Localizable。
    var content: String
    var url: URL?
    var count: Int
    var previews: [RAGRemoteResultPreview] = []
}

private struct IndexedRemoteBlock: Sendable {
    var index: Int
    var block: RAGRemoteContextBlock
}

/// 远程现场数据只做 15 分钟进程内缓存，不写 rag_chunks 或用户历史。
actor RAGRemoteContextMemoryCache {
    static let shared = RAGRemoteContextMemoryCache()
    private struct Entry { var block: RAGRemoteContextBlock; var expiresAt: Date }
    private var entries: [String: Entry] = [:]
    private let ttl: TimeInterval

    init(ttl: TimeInterval = 15 * 60) { self.ttl = ttl }

    func value(for key: String, now: Date = Date()) -> RAGRemoteContextBlock? {
        guard let entry = entries[key], entry.expiresAt > now else {
            entries.removeValue(forKey: key)
            return nil
        }
        return entry.block
    }

    func insert(_ block: RAGRemoteContextBlock, for key: String, now: Date = Date()) {
        entries[key] = Entry(block: block, expiresAt: now.addingTimeInterval(ttl))
    }

    func removeAll() { entries.removeAll() }
}

enum GitHubRemoteContextError: Error, LocalizedError {
    case http(status: Int, message: String)
    case unsupportedResource

    var errorDescription: String? {
        switch self {
        case .http(let status, let message):
            return String(
                format: String.l10n("rag.core.remote.error.githubHTTPFormat"),
                Int64(status),
                message
            )
        case .unsupportedResource:
            return String.l10n("rag.core.remote.error.webSearchUnsupported")
        }
    }
}
