//
//  MockGitHubAPIClient.swift
//  StarcatTests
//
//  `GitHubAPIClientProtocol` 的纯内存 Mock 实现（D-14 配套，给 ReadmeAPI 等"中层 API
//  协调器"做单测用）。
//
//  设计理由：
//  - `URLProtocolStub` 适合测 `GitHubAPIClient` 本身的网络层（HTTP 状态码 / Header 解析等）
//  - 但测 `ReadmeAPI`（依赖 `client.readmeHTML(...)` + `ReadmeRepository`）时，没必要再起 URLSession：
//    直接 mock 协议方法返回 `BytesResponse` / 错误，路径更短、断言更直接
//
//  使用模式：
//
//  ```swift
//  let mock = MockGitHubAPIClient()
//  mock.readmeHTMLHandler = { owner, repo, etag, lastMod in
//      return BytesResponse(data: htmlBytes, etag: "\"abc\"", lastModified: nil,
//                           statusCode: 200, notModified: false, rateLimit: .empty)
//  }
//  let api = ReadmeAPI(client: mock, repository: readmeRepo)
//  let result = await api.refreshReadme(for: someRepo)
//  ```
//
//  没设置 handler 的方法被调用 → 直接 `fatalError`（fail-fast，让测试明确"你忘了 stub"）。
//

import Foundation
import os.lock
@testable import Starcat

/// `GitHubAPIClientProtocol` 的可注入 Mock。
/// 每个方法都对应一个 handler 闭包；未设置的 handler 调用会 fatalError。
///
/// ────────────────────────────────────────────────────────────────────────────
/// **线程安全约定（2026-06-21 加锁）**
/// ────────────────────────────────────────────────────────────────────────────
///
/// 7 个 `*Calls` 调用记录数组（readmeHTMLCalls / readmeMarkdownCalls / starCalls /
/// unstarCalls / releasesCalls / receivedEventsCalls / securityAdvisoriesCalls）
/// 全部用 `OSAllocatedUnfairLock` 保护。原因：`ActivityViewModel.fetchSecurityAnnouncementDrafts`
/// 用 `withTaskGroup` 并发拉 security advisory（`securityScanConcurrency = 6`），多
/// 个子任务并发调 `apiClient.securityAdvisories(...)` 时，没锁的 Swift `Array` 并发
/// `append` 会丢条目（debug 跑出过：两次调用只记 1 条），具体见
/// `StarcatTests/ActivityViewModelTests.swift::security404Skipped` 的失败 log。
///
/// 公开 API 暴露计算 property 快照，调用方零改动（`mock.securityAdvisoriesCalls.count`
/// 继续用）。私有 storage 用 `_xxxCalls` 前缀 + `OSAllocatedUnfairLock<[...]>` 锁。
///
/// ────────────────────────────────────────────────────────────────────────────
/// `final class` + `@unchecked Sendable`：协议要求 Sendable，calls 数组已上锁满足
/// "并发安全 mutation" 要求；handler closure 本身的并发调用由用户保证。
final class MockGitHubAPIClient: GitHubAPIClientProtocol, @unchecked Sendable {

    // MARK: - Handlers（每方法一个）

    /// W4-4 C2：handler 多了 `ifNoneMatch` 参数，便于测试断言"是否带了 ETag"。
    var starredReposHandler: ((_ page: Int, _ perPage: Int, _ ifNoneMatch: String?) async throws -> APIResponse<[StarredRepoDTO]>)?
    var unstarHandler: ((_ owner: String, _ repo: String) async throws -> Void)?
    var starHandler: ((_ owner: String, _ repo: String) async throws -> Void)?
    var getCurrentUserHandler: (() async throws -> GitHubUserDTO)?
    var readmeHTMLHandler: ((_ owner: String, _ repo: String, _ ifNoneMatch: String?, _ ifModifiedSince: String?) async throws -> BytesResponse)?
    /// 2026-06-12 向量索引改进：README 原始 Markdown 端点 handler。
    var readmeMarkdownHandler: ((_ owner: String, _ repo: String, _ ifNoneMatch: String?, _ ifModifiedSince: String?) async throws -> BytesResponse)?
    /// HOM-47：Releases API mock handler。
    var releasesHandler: ((_ owner: String, _ repo: String, _ perPage: Int) async throws -> APIResponse<[GitHubReleaseDTO]>)?
    /// 2026-06-08：单仓库元数据 API mock handler（Weekly 详情页本地缓存未命中时调）。
    var repoHandler: ((_ owner: String, _ repo: String) async throws -> GitHubRepoDTO)?
    /// 2026-06-16 Activity 公告与关注 PR-2：received_events feed mock handler。
    var receivedEventsHandler: ((_ username: String, _ perPage: Int, _ ifNoneMatch: String?) async throws -> APIResponse<[GitHubEventDTO]>)?
    /// 2026-06-17 Activity 公告与关注 PR-3：security-advisories mock handler。
    var securityAdvisoriesHandler: ((_ owner: String, _ repo: String) async throws -> APIResponse<[GitHubSecurityAdvisoryDTO]>)?
    /// Search Center GitHub 搜索 mock handler。默认不设，避免老测试误用假空结果。
    var searchRepositoriesHandler: ((_ query: GitHubRepositorySearchQuery, _ page: Int, _ perPage: Int) async throws -> APIResponse<GitHubRepositorySearchDTO>)?
    var listNotificationsHandler: ((_ all: Bool, _ since: String?, _ page: Int, _ perPage: Int, _ ifModifiedSince: String?) async throws -> GitHubNotificationsListResponse)?
    var hydrateNotificationSubjectHandler: ((_ path: String) async throws -> GitHubNotificationSubjectHydration)?
    var listNotificationIssueCommentsHandler: ((_ path: String) async throws -> [GitHubNotificationComment])?
    var createNotificationIssueCommentHandler: ((_ path: String, _ body: String) async throws -> GitHubNotificationComment)?
    var markNotificationThreadReadHandler: ((_ id: String) async throws -> Void)?
    var markNotificationThreadDoneHandler: ((_ id: String) async throws -> Void)?
    var updateNotificationIssueStateHandler: ((_ path: String, _ state: String) async throws -> Void)?
    var uploadUserAttachmentHandler: ((_ fileName: String, _ contentType: String, _ repositoryID: Int64, _ data: Data) async throws -> URL)?

    // MARK: - 调用记录（供断言用）
    //
    // 全部用 OSAllocatedUnfairLock 保护，原因见文件头"线程安全约定"。
    // 公开 API 用 getter 暴露快照，私有 storage 用 _xxxCalls 前缀。

    private let _readmeHTMLCalls = OSAllocatedUnfairLock<[(owner: String, repo: String, ifNoneMatch: String?, ifModifiedSince: String?)]>(initialState: [])
    /// 2026-06-12 向量索引改进：README Markdown 调用日志，便于断言"按需懒补全是否真的发请求"。
    private let _readmeMarkdownCalls = OSAllocatedUnfairLock<[(owner: String, repo: String, ifNoneMatch: String?, ifModifiedSince: String?)]>(initialState: [])
    private let _starCalls = OSAllocatedUnfairLock<[(owner: String, repo: String)]>(initialState: [])
    /// W12 PR-3：批量 unstar 测试需要断言 API 调用次数。
    /// 与 starCalls 对称，每次进入 `unstar(owner:repo:)` 都 append（无论 handler 是否抛错）。
    private let _unstarCalls = OSAllocatedUnfairLock<[(owner: String, repo: String)]>(initialState: [])
    /// HOM-47：releases 调用日志，便于断言"是否拉过 / 拉了几次"。
    private let _releasesCalls = OSAllocatedUnfairLock<[(owner: String, repo: String, perPage: Int)]>(initialState: [])
    /// 2026-06-16 Activity 公告与关注 PR-2：events 调用日志，便于断言「ETag 是否被回传」/「是否真的发了请求」。
    private let _receivedEventsCalls = OSAllocatedUnfairLock<[(username: String, perPage: Int, ifNoneMatch: String?)]>(initialState: [])
    /// 2026-06-17 Activity 公告与关注 PR-3：security-advisories 调用日志。
    private let _securityAdvisoriesCalls = OSAllocatedUnfairLock<[(owner: String, repo: String)]>(initialState: [])
    private let _listNotificationsCalls = OSAllocatedUnfairLock<[(all: Bool, since: String?, page: Int, perPage: Int, ifModifiedSince: String?)]>(initialState: [])
    private let _markNotificationThreadReadCalls = OSAllocatedUnfairLock<[String]>(initialState: [])
    private let _markNotificationThreadDoneCalls = OSAllocatedUnfairLock<[String]>(initialState: [])
    private let _createNotificationIssueCommentCalls = OSAllocatedUnfairLock<[(path: String, body: String)]>(initialState: [])

    /// 快照 getter：测试断言用 `mock.readmeHTMLCalls.count` 继续生效。
    var readmeHTMLCalls: [(owner: String, repo: String, ifNoneMatch: String?, ifModifiedSince: String?)] {
        _readmeHTMLCalls.withLock { $0 }
    }
    var readmeMarkdownCalls: [(owner: String, repo: String, ifNoneMatch: String?, ifModifiedSince: String?)] {
        _readmeMarkdownCalls.withLock { $0 }
    }
    var starCalls: [(owner: String, repo: String)] {
        _starCalls.withLock { $0 }
    }
    var unstarCalls: [(owner: String, repo: String)] {
        _unstarCalls.withLock { $0 }
    }
    var releasesCalls: [(owner: String, repo: String, perPage: Int)] {
        _releasesCalls.withLock { $0 }
    }
    var receivedEventsCalls: [(username: String, perPage: Int, ifNoneMatch: String?)] {
        _receivedEventsCalls.withLock { $0 }
    }
    var securityAdvisoriesCalls: [(owner: String, repo: String)] {
        _securityAdvisoriesCalls.withLock { $0 }
    }
    var listNotificationsCalls: [(all: Bool, since: String?, page: Int, perPage: Int, ifModifiedSince: String?)] {
        _listNotificationsCalls.withLock { $0 }
    }
    var markNotificationThreadReadCalls: [String] {
        _markNotificationThreadReadCalls.withLock { $0 }
    }
    var markNotificationThreadDoneCalls: [String] {
        _markNotificationThreadDoneCalls.withLock { $0 }
    }
    var createNotificationIssueCommentCalls: [(path: String, body: String)] {
        _createNotificationIssueCommentCalls.withLock { $0 }
    }

    // MARK: - Protocol conformance

    func starredRepos(page: Int, perPage: Int, ifNoneMatch: String?) async throws -> APIResponse<[StarredRepoDTO]> {
        guard let handler = starredReposHandler else {
            fatalError("MockGitHubAPIClient.starredReposHandler 未设置")
        }
        return try await handler(page, perPage, ifNoneMatch)
    }

    func unstar(owner: String, repo: String) async throws {
        _unstarCalls.withLock { $0.append((owner, repo)) }
        guard let handler = unstarHandler else {
            fatalError("MockGitHubAPIClient.unstarHandler 未设置")
        }
        try await handler(owner, repo)
    }

    func star(owner: String, repo: String) async throws {
        _starCalls.withLock { $0.append((owner, repo)) }
        guard let handler = starHandler else {
            fatalError("MockGitHubAPIClient.starHandler 未设置")
        }
        try await handler(owner, repo)
    }

    func getCurrentUser() async throws -> GitHubUserDTO {
        guard let handler = getCurrentUserHandler else {
            fatalError("MockGitHubAPIClient.getCurrentUserHandler 未设置")
        }
        return try await handler()
    }

    func readmeHTML(
        owner: String,
        repo: String,
        ifNoneMatch: String?,
        ifModifiedSince: String?,
        requestTimeout: TimeInterval?
    ) async throws -> BytesResponse {
        _readmeHTMLCalls.withLock { $0.append((owner, repo, ifNoneMatch, ifModifiedSince)) }
        guard let handler = readmeHTMLHandler else {
            fatalError("MockGitHubAPIClient.readmeHTMLHandler 未设置")
        }
        return try await handler(owner, repo, ifNoneMatch, ifModifiedSince)
    }

    func readmeMarkdown(
        owner: String,
        repo: String,
        ifNoneMatch: String?,
        ifModifiedSince: String?,
        requestTimeout: TimeInterval?
    ) async throws -> BytesResponse {
        _readmeMarkdownCalls.withLock { $0.append((owner, repo, ifNoneMatch, ifModifiedSince)) }
        guard let handler = readmeMarkdownHandler else {
            fatalError("MockGitHubAPIClient.readmeMarkdownHandler 未设置")
        }
        return try await handler(owner, repo, ifNoneMatch, ifModifiedSince)
    }

    // MARK: - Subscription (Watch)

    func getSubscription(owner: String, repo: String) async throws -> GitHubSubscriptionDTO {
        return GitHubSubscriptionDTO(subscribed: false, ignored: false, reason: nil, createdAt: nil, url: nil, repositoryUrl: nil)
    }

    func putSubscription(owner: String, repo: String, subscribed: Bool, ignored: Bool) async throws -> GitHubSubscriptionDTO {
        return GitHubSubscriptionDTO(subscribed: subscribed, ignored: ignored, reason: nil, createdAt: nil, url: nil, repositoryUrl: nil)
    }

    func deleteSubscription(owner: String, repo: String) async throws {
    }

    func releases(owner: String, repo: String, perPage: Int) async throws -> APIResponse<[GitHubReleaseDTO]> {
        _releasesCalls.withLock { $0.append((owner, repo, perPage)) }
        guard let handler = releasesHandler else {
            fatalError("MockGitHubAPIClient.releasesHandler 未设置")
        }
        return try await handler(owner, repo, perPage)
    }

    func repo(owner: String, repo: String) async throws -> GitHubRepoDTO {
        guard let handler = repoHandler else {
            fatalError("MockGitHubAPIClient.repoHandler 未设置")
        }
        return try await handler(owner, repo)
    }

    func receivedEvents(
        username: String,
        perPage: Int,
        ifNoneMatch: String?
    ) async throws -> APIResponse<[GitHubEventDTO]> {
        _receivedEventsCalls.withLock { $0.append((username, perPage, ifNoneMatch)) }
        guard let handler = receivedEventsHandler else {
            fatalError("MockGitHubAPIClient.receivedEventsHandler 未设置")
        }
        return try await handler(username, perPage, ifNoneMatch)
    }

    func securityAdvisories(owner: String, repo: String) async throws -> APIResponse<[GitHubSecurityAdvisoryDTO]> {
        _securityAdvisoriesCalls.withLock { $0.append((owner, repo)) }
        guard let handler = securityAdvisoriesHandler else {
            fatalError("MockGitHubAPIClient.securityAdvisoriesHandler 未设置")
        }
        return try await handler(owner, repo)
    }

    func searchRepositories(
        query: GitHubRepositorySearchQuery,
        page: Int,
        perPage: Int
    ) async throws -> APIResponse<GitHubRepositorySearchDTO> {
        guard let handler = searchRepositoriesHandler else {
            fatalError("MockGitHubAPIClient.searchRepositoriesHandler 未设置")
        }
        return try await handler(query, page, perPage)
    }

    func listNotifications(
        all: Bool,
        since: String?,
        page: Int,
        perPage: Int,
        ifModifiedSince: String?
    ) async throws -> GitHubNotificationsListResponse {
        _listNotificationsCalls.withLock { $0.append((all, since, page, perPage, ifModifiedSince)) }
        guard let handler = listNotificationsHandler else {
            fatalError("MockGitHubAPIClient.listNotificationsHandler 未设置")
        }
        return try await handler(all, since, page, perPage, ifModifiedSince)
    }

    func hydrateNotificationSubject(path: String) async throws -> GitHubNotificationSubjectHydration {
        guard let handler = hydrateNotificationSubjectHandler else {
            fatalError("MockGitHubAPIClient.hydrateNotificationSubjectHandler 未设置")
        }
        return try await handler(path)
    }

    func listNotificationIssueComments(path: String) async throws -> [GitHubNotificationComment] {
        if let handler = listNotificationIssueCommentsHandler {
            return try await handler(path)
        }
        return []
    }

    func createNotificationIssueComment(path: String, body: String) async throws -> GitHubNotificationComment {
        _createNotificationIssueCommentCalls.withLock { $0.append((path, body)) }
        guard let handler = createNotificationIssueCommentHandler else {
            fatalError("MockGitHubAPIClient.createNotificationIssueCommentHandler 未设置")
        }
        return try await handler(path, body)
    }

    func markNotificationThreadRead(id: String) async throws {
        _markNotificationThreadReadCalls.withLock { $0.append(id) }
        guard let handler = markNotificationThreadReadHandler else {
            fatalError("MockGitHubAPIClient.markNotificationThreadReadHandler 未设置")
        }
        try await handler(id)
    }

    func markNotificationThreadDone(id: String) async throws {
        _markNotificationThreadDoneCalls.withLock { $0.append(id) }
        guard let handler = markNotificationThreadDoneHandler else {
            fatalError("MockGitHubAPIClient.markNotificationThreadDoneHandler 未设置")
        }
        try await handler(id)
    }

    func updateNotificationIssueState(path: String, state: String) async throws {
        guard let handler = updateNotificationIssueStateHandler else {
            fatalError("MockGitHubAPIClient.updateNotificationIssueStateHandler 未设置")
        }
        try await handler(path, state)
    }

    func uploadUserAttachment(
        fileName: String,
        contentType: String,
        repositoryID: Int64,
        data: Data
    ) async throws -> URL {
        guard let handler = uploadUserAttachmentHandler else {
            fatalError("MockGitHubAPIClient.uploadUserAttachmentHandler 未设置")
        }
        return try await handler(fileName, contentType, repositoryID, data)
    }
}

// MARK: - 构造便利

extension RateLimitInfo {
    /// 测试用空速率信息（避免 mock 时反复写完整结构）。
    static var empty: RateLimitInfo {
        RateLimitInfo(limit: nil, remaining: nil, reset: nil)
    }
}

extension BytesResponse {
    /// 测试便利：构造 200 响应。
    static func ok(data: Data, etag: String? = nil, lastModified: String? = nil) -> BytesResponse {
        BytesResponse(
            data: data,
            etag: etag,
            lastModified: lastModified,
            statusCode: 200,
            notModified: false,
            rateLimit: .empty,
            pollIntervalSeconds: nil
        )
    }

    /// 测试便利：构造 304 响应（空 body）。
    static func notModified304(etag: String? = nil, lastModified: String? = nil) -> BytesResponse {
        BytesResponse(
            data: Data(),
            etag: etag,
            lastModified: lastModified,
            statusCode: 304,
            notModified: true,
            rateLimit: .empty,
            pollIntervalSeconds: nil
        )
    }
}
