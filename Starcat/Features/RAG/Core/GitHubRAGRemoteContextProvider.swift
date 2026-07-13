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
    private let httpClient: any RAGHTTPClientProtocol
    private let token: String?
    private let cacheNamespace: String
    private let baseURL: URL
    private let cache: RAGRemoteContextMemoryCache

    init(
        httpClient: any RAGHTTPClientProtocol = URLSessionRAGHTTPClient(),
        token: String?,
        baseURL: URL = URL(string: "https://api.github.com")!,
        cache: RAGRemoteContextMemoryCache = .shared
    ) {
        self.httpClient = httpClient
        let normalizedToken = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.token = normalizedToken
        self.cacheNamespace = Self.cacheNamespace(for: normalizedToken)
        self.baseURL = baseURL
        self.cache = cache
    }

    func fetch(
        requests: [RAGRemoteContextRequest],
        candidates: [RAGRepoCandidate],
        onProgress: @escaping @Sendable (RAGRemoteContextFetchProgress) -> Void
    ) async -> [RAGRemoteContextBlock] {
        await fetch(
            requests: requests,
            candidates: candidates,
            onProgress: onProgress,
            onDebug: { _ in }
        )
    }

    func fetch(
        requests: [RAGRemoteContextRequest],
        candidates: [RAGRepoCandidate],
        onProgress: @escaping @Sendable (RAGRemoteContextFetchProgress) -> Void,
        onDebug: @escaping @Sendable (RAGRemoteContextDebugEvent) -> Void
    ) async -> [RAGRemoteContextBlock] {
        let work = requests.enumerated().flatMap { requestIndex, contextRequest in
            candidates.prefix(contextRequest.maxRepos).enumerated().map { candidateIndex, candidate in
                RemoteFetchWork(
                    index: requestIndex * candidates.count + candidateIndex,
                    request: contextRequest,
                    repo: candidate.repo
                )
            }
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
        let cacheKey = "\(cacheNamespace)|\(work.repo.id)|\(work.request.resource.rawValue)|\(work.request.query)|\(work.request.perRepoLimit)"
        if let cached = await cache.value(for: cacheKey) {
            onDebug(RAGRemoteContextDebugEvent(
                repoFullName: work.repo.fullName,
                resource: work.request.resource,
                url: nil,
                outcome: .cacheHit
            ))
            return IndexedRemoteBlock(index: work.index, block: cached)
        }
        do {
            let block = try await fetchOne(work.request, repo: work.repo, onDebug: onDebug)
            guard !Task.isCancelled else { return nil }
            await cache.insert(block, for: cacheKey)
            return IndexedRemoteBlock(index: work.index, block: block)
        } catch {
            // URLSession 取消通常以 URLError.cancelled 抛出，不能把它伪装成 GitHub 失败提示。
            guard !Task.isCancelled else { return nil }
            return IndexedRemoteBlock(index: work.index, block: RAGRemoteContextBlock(
                id: "\(work.repo.id):\(work.request.resource.rawValue)",
                repoId: work.repo.id,
                resource: work.request.resource,
                title: "\(work.repo.fullName) · \(displayName(work.request.resource))",
                sourceURL: URL(string: work.repo.htmlUrl),
                content: "",
                fetchedAt: Date(),
                errorMessage: error.localizedDescription
            ))
        }
    }

    private static let maxConcurrentRequests = 3

    private func fetchOne(
        _ contextRequest: RAGRemoteContextRequest,
        repo: Repo,
        onDebug: @escaping @Sendable (RAGRemoteContextDebugEvent) -> Void
    ) async throws -> RAGRemoteContextBlock {
        let result: (String, URL?)
        switch contextRequest.resource {
        case .githubIssues:
            result = try await fetchIssues(repo: repo, query: contextRequest.query, limit: contextRequest.perRepoLimit, pullRequests: false, resource: contextRequest.resource, onDebug: onDebug)
        case .githubPullRequests:
            result = try await fetchIssues(repo: repo, query: contextRequest.query, limit: contextRequest.perRepoLimit, pullRequests: true, resource: contextRequest.resource, onDebug: onDebug)
        case .githubReleases:
            result = try await fetchReleases(repo: repo, limit: contextRequest.perRepoLimit, resource: contextRequest.resource, onDebug: onDebug)
        case .githubContributors:
            result = try await fetchContributors(repo: repo, limit: contextRequest.perRepoLimit, resource: contextRequest.resource, onDebug: onDebug)
        case .githubCommitActivity:
            result = try await fetchCommitActivity(repo: repo, resource: contextRequest.resource, onDebug: onDebug)
        case .githubSecurityAdvisories:
            result = try await fetchSecurityAdvisories(repo: repo, limit: contextRequest.perRepoLimit, resource: contextRequest.resource, onDebug: onDebug)
        }
        return RAGRemoteContextBlock(
            id: "\(repo.id):\(contextRequest.resource.rawValue)",
            repoId: repo.id,
            resource: contextRequest.resource,
            title: "\(repo.fullName) · \(displayName(contextRequest.resource))",
            sourceURL: result.1,
            content: result.0,
            fetchedAt: Date(),
            errorMessage: nil
        )
    }

    private func fetchIssues(
        repo: Repo,
        query: String,
        limit: Int,
        pullRequests: Bool,
        resource: RAGRemoteContextResource,
        onDebug: @escaping @Sendable (RAGRemoteContextDebugEvent) -> Void
    ) async throws -> (String, URL?) {
        var components = URLComponents(url: baseURL.appendingPathComponent("search/issues"), resolvingAgainstBaseURL: false)!
        let kind = pullRequests ? "is:pr" : "is:issue"
        components.queryItems = [
            URLQueryItem(name: "q", value: "repo:\(repo.fullName) \(kind) \(query)"),
            URLQueryItem(name: "sort", value: "updated"),
            URLQueryItem(name: "order", value: "desc"),
            URLQueryItem(name: "per_page", value: String(limit))
        ]
        let response: SearchIssuesResponse = try await get(
            components.url!,
            repoFullName: repo.fullName,
            resource: resource,
            onDebug: onDebug
        )
        // Planner 生成的 query 不能被当作可信 GitHub Search 语法。即使 query 夹带
        // `OR repo:other/name` 等 qualifier，也只接受当前候选 repo 的返回项。
        let scopedItems = response.items.filter { $0.belongs(to: repo) }
        let lines = scopedItems.prefix(limit).map { item in
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
            ? "没有匹配的公开结果。"
            : "observed_themes=\(themes.isEmpty ? "none" : themes)\n\n\(lines.joined(separator: "\n\n"))"
        return (content, components.url)
    }

    private func fetchReleases(
        repo: Repo,
        limit: Int,
        resource: RAGRemoteContextResource,
        onDebug: @escaping @Sendable (RAGRemoteContextDebugEvent) -> Void
    ) async throws -> (String, URL?) {
        let url = repoAPIURL(repo, suffix: "releases", query: [URLQueryItem(name: "per_page", value: String(limit))])
        let releases: [ReleaseResponse] = try await get(url, repoFullName: repo.fullName, resource: resource, onDebug: onDebug)
        let lines = releases.prefix(limit).map { release in
            """
            \(release.name ?? release.tagName) (\(release.tagName)) published=\(release.publishedAt ?? "unknown")
            url=\(release.htmlURL)
            \(clip(release.body ?? "", limit: 1_000))
            """
        }
        return (lines.isEmpty ? "仓库没有公开 Release。" : lines.joined(separator: "\n\n"), url)
    }

    private func fetchContributors(
        repo: Repo,
        limit: Int,
        resource: RAGRemoteContextResource,
        onDebug: @escaping @Sendable (RAGRemoteContextDebugEvent) -> Void
    ) async throws -> (String, URL?) {
        let url = repoAPIURL(repo, suffix: "contributors", query: [URLQueryItem(name: "per_page", value: String(limit))])
        let contributors: [ContributorResponse] = try await get(url, repoFullName: repo.fullName, resource: resource, onDebug: onDebug)
        let lines = contributors.prefix(limit).map { "\($0.login): contributions=\($0.contributions); url=\($0.htmlURL ?? "")" }
        return (lines.isEmpty ? "没有可用的公开贡献者数据。" : lines.joined(separator: "\n"), url)
    }

    private func fetchCommitActivity(
        repo: Repo,
        resource: RAGRemoteContextResource,
        onDebug: @escaping @Sendable (RAGRemoteContextDebugEvent) -> Void
    ) async throws -> (String, URL?) {
        let url = repoAPIURL(repo, suffix: "stats/commit_activity")
        let weeks: [CommitActivityResponse] = try await get(
            url,
            acceptedStatus: [200],
            repoFullName: repo.fullName,
            resource: resource,
            onDebug: onDebug
        )
        let recent = weeks.suffix(12)
        let total = recent.reduce(0) { $0 + $1.total }
        let activeWeeks = recent.filter { $0.total > 0 }.count
        return ("最近 12 周 commits=\(total)，活跃周数=\(activeWeeks)/\(recent.count)。", url)
    }

    private func fetchSecurityAdvisories(
        repo: Repo,
        limit: Int,
        resource: RAGRemoteContextResource,
        onDebug: @escaping @Sendable (RAGRemoteContextDebugEvent) -> Void
    ) async throws -> (String, URL?) {
        let url = repoAPIURL(repo, suffix: "security-advisories", query: [URLQueryItem(name: "per_page", value: String(limit))])
        let advisories: [SecurityAdvisoryResponse] = try await get(url, repoFullName: repo.fullName, resource: resource, onDebug: onDebug)
        let lines = advisories.prefix(limit).map {
            "\($0.ghsaID) severity=\($0.severity) cve=\($0.cveID ?? "unknown") published=\($0.publishedAt)\n\($0.summary)\nurl=\($0.htmlURL ?? "")"
        }
        return (lines.isEmpty ? "没有返回公开仓库安全公告。" : lines.joined(separator: "\n\n"), url)
    }

    private func repoAPIURL(_ repo: Repo, suffix: String, query: [URLQueryItem] = []) -> URL {
        let path = "repos/\(repo.owner)/\(repo.name)/\(suffix)"
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.isEmpty ? nil : query
        return components.url!
    }

    /// 唯一的 GitHub 出站点：只记录 URL、状态和错误，不记录 Authorization 请求头。
    /// 在 HTTP 客户端真正开始前发 request 事件，故 Debug Trace 能区分网络耗时与缓存命中。
    private func get<T: Decodable>(
        _ url: URL,
        acceptedStatus: Set<Int> = [200],
        repoFullName: String,
        resource: RAGRemoteContextResource,
        onDebug: @escaping @Sendable (RAGRemoteContextDebugEvent) -> Void
    ) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Starcat", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        onDebug(RAGRemoteContextDebugEvent(
            repoFullName: repoFullName,
            resource: resource,
            url: url.absoluteString,
            outcome: .request
        ))
        do {
            let (data, response) = try await httpClient.data(for: request)
            onDebug(RAGRemoteContextDebugEvent(
                repoFullName: repoFullName,
                resource: resource,
                url: url.absoluteString,
                outcome: .response(statusCode: response.statusCode)
            ))
            guard acceptedStatus.contains(response.statusCode) else {
                let message = (try? JSONDecoder().decode(GitHubErrorResponse.self, from: data).message) ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
                throw GitHubRemoteContextError.http(status: response.statusCode, message: message)
            }
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            onDebug(RAGRemoteContextDebugEvent(
                repoFullName: repoFullName,
                resource: resource,
                url: url.absoluteString,
                outcome: .failure(error.localizedDescription)
            ))
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
        }
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
    var request: RAGRemoteContextRequest
    var repo: Repo
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

    var errorDescription: String? {
        switch self {
        case .http(let status, let message): return "GitHub HTTP \(status)：\(message)"
        }
    }
}

private struct GitHubErrorResponse: Decodable { var message: String }

private struct SearchIssuesResponse: Decodable {
    var items: [IssueResponse]
}

private struct IssueResponse: Decodable {
    struct Label: Decodable { var name: String }
    var number: Int
    var title: String
    var state: String
    var htmlURL: String
    var body: String?
    var labels: [Label]
    var comments: Int
    var updatedAt: String
    var repositoryURL: String?

    enum CodingKeys: String, CodingKey {
        case number, title, state, body, labels, comments
        case htmlURL = "html_url"
        case updatedAt = "updated_at"
        case repositoryURL = "repository_url"
    }

    func belongs(to repo: Repo) -> Bool {
        let expectedAPIPath = "/repos/\(repo.owner)/\(repo.name)".lowercased()
        if let repositoryURL,
           URL(string: repositoryURL)?.path.lowercased() == expectedAPIPath {
            return true
        }
        let expectedHTMLPrefix = "/\(repo.owner)/\(repo.name)/".lowercased()
        return URL(string: htmlURL)?.path.lowercased().hasPrefix(expectedHTMLPrefix) == true
    }
}

private struct ReleaseResponse: Decodable {
    var tagName: String
    var name: String?
    var body: String?
    var htmlURL: String
    var publishedAt: String?

    enum CodingKeys: String, CodingKey {
        case name, body
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case publishedAt = "published_at"
    }
}

private struct ContributorResponse: Decodable {
    var login: String
    var contributions: Int
    var htmlURL: String?

    enum CodingKeys: String, CodingKey {
        case login, contributions
        case htmlURL = "html_url"
    }
}

private struct CommitActivityResponse: Decodable {
    var total: Int
}

private struct SecurityAdvisoryResponse: Decodable {
    var ghsaID: String
    var cveID: String?
    var summary: String
    var severity: String
    var htmlURL: String?
    var publishedAt: String

    enum CodingKeys: String, CodingKey {
        case summary, severity
        case ghsaID = "ghsa_id"
        case cveID = "cve_id"
        case htmlURL = "html_url"
        case publishedAt = "published_at"
    }
}
