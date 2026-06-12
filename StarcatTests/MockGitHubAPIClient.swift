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
@testable import Starcat

/// `GitHubAPIClientProtocol` 的可注入 Mock。
/// 每个方法都对应一个 handler 闭包；未设置的 handler 调用会 fatalError。
///
/// `final class` + `@unchecked Sendable`：协议要求 Sendable；mock 假定测试单线程串行使用，不做严格 isolation。
final class MockGitHubAPIClient: GitHubAPIClientProtocol, @unchecked Sendable {

    // MARK: - Handlers（每方法一个）

    /// W4-4 C2：handler 多了 `ifNoneMatch` 参数，便于测试断言"是否带了 ETag"。
    var starredReposHandler: ((_ page: Int, _ perPage: Int, _ ifNoneMatch: String?) async throws -> APIResponse<[StarredRepoDTO]>)?
    var unstarHandler: ((_ owner: String, _ repo: String) async throws -> Void)?
    var starHandler: ((_ owner: String, _ repo: String) async throws -> Void)?
    var getCurrentUserHandler: (() async throws -> GitHubUserDTO)?
    var readmeHTMLHandler: ((_ owner: String, _ repo: String, _ ifNoneMatch: String?, _ ifModifiedSince: String?) async throws -> BytesResponse)?
    /// HOM-47：Releases API mock handler。
    var releasesHandler: ((_ owner: String, _ repo: String, _ perPage: Int) async throws -> APIResponse<[GitHubReleaseDTO]>)?
    /// 2026-06-08：单仓库元数据 API mock handler（Weekly 详情页本地缓存未命中时调）。
    var repoHandler: ((_ owner: String, _ repo: String) async throws -> GitHubRepoDTO)?

    // MARK: - 调用记录（供断言用）

    private(set) var readmeHTMLCalls: [(owner: String, repo: String, ifNoneMatch: String?, ifModifiedSince: String?)] = []
    private(set) var starCalls: [(owner: String, repo: String)] = []
    /// W12 PR-3：批量 unstar 测试需要断言 API 调用次数。
    /// 与 starCalls 对称，每次进入 `unstar(owner:repo:)` 都 append（无论 handler 是否抛错）。
    private(set) var unstarCalls: [(owner: String, repo: String)] = []
    /// HOM-47：releases 调用日志，便于断言"是否拉过 / 拉了几次"。
    private(set) var releasesCalls: [(owner: String, repo: String, perPage: Int)] = []

    // MARK: - Protocol conformance

    func starredRepos(page: Int, perPage: Int, ifNoneMatch: String?) async throws -> APIResponse<[StarredRepoDTO]> {
        guard let handler = starredReposHandler else {
            fatalError("MockGitHubAPIClient.starredReposHandler 未设置")
        }
        return try await handler(page, perPage, ifNoneMatch)
    }

    func unstar(owner: String, repo: String) async throws {
        unstarCalls.append((owner, repo))
        guard let handler = unstarHandler else {
            fatalError("MockGitHubAPIClient.unstarHandler 未设置")
        }
        try await handler(owner, repo)
    }

    func star(owner: String, repo: String) async throws {
        starCalls.append((owner, repo))
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
        ifModifiedSince: String?
    ) async throws -> BytesResponse {
        readmeHTMLCalls.append((owner, repo, ifNoneMatch, ifModifiedSince))
        guard let handler = readmeHTMLHandler else {
            fatalError("MockGitHubAPIClient.readmeHTMLHandler 未设置")
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
        releasesCalls.append((owner, repo, perPage))
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
            rateLimit: .empty
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
            rateLimit: .empty
        )
    }
}
