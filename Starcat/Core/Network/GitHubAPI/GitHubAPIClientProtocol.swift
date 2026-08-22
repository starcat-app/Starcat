//
//  GitHubAPIClientProtocol.swift
//  Starcat
//
//  GitHub API 客户端协议层（D-02 引入）。
//
//  存在意义：把 `GitHubAPIClient` actor 抽象为协议，让 `SyncManager` / `AuthSession` /
//  `ReadmeAPI` 等调用方依赖协议而非具体 actor，从而能写"完全脱离网络"的单元测试
//  （把 Mock 实现塞到测试 target 即可）。
//
//  设计取舍：
//  - **只暴露业务端点**（starredRepos / getCurrentUser / unstar / star / readmeHTML），
//    不暴露底层 `get<T>` / `delete` / `put` / `getBytes`
//    原因：①调用方真正需要 mock 的就是业务行为；②底层 generic `get<T>` 在协议层
//    需要泛型 method + 全部业务调用都已经走业务端点封装好了；③业务端点本身已经决定了
//    path / query / accept 等，mock 时只需要给一个 Result，远比 mock 底层灵活
//  - **README 端点新建 `readmeHTML(owner:repo:ifNoneMatch:ifModifiedSince:)`** ，
//    包装原 `ReadmeAPI` 直接使用 `client.getBytes(path: "/repos/...")` 的拼路径写法。
//    实现见 `ReadmeHTMLAPI.swift`（与 StarsAPI / UserAPI 同风格按端点拆分）。
//  - `Sendable` 约束：保留 actor 自动 Sendable 的语义；调用方都是 await
//
//  Mock 落地（D-14 配套）：测试 target 写 `final class MockGitHubAPIClient: GitHubAPIClientProtocol`，
//  每个 method 用闭包 / Result 控制返回值，单测就能脱离 URLSession 完全运行。
//

import Foundation

protocol GitHubAPIClientProtocol: Sendable {

    // MARK: - Stars

    /// 拉取一页 starred repos。
    /// - Parameter ifNoneMatch: W4-4 C2 条件请求 ETag；命中(304) 时实现方应抛 `NetworkError.notModified(etag:)`。
    /// - Returns: APIResponse 含 [StarredRepoDTO] + LinkHeader（分页信息）+ RateLimitInfo + ETag
    func starredRepos(page: Int, perPage: Int, ifNoneMatch: String?) async throws -> APIResponse<[StarredRepoDTO]>

    /// 取消 star。
    func unstar(owner: String, repo: String) async throws

    /// 重新 star。
    func star(owner: String, repo: String) async throws

    // MARK: - User

    /// 获取当前授权用户信息（同时充当 token 健康检查 — 401 即代表 token 失效）。
    func getCurrentUser() async throws -> GitHubUserDTO

    // MARK: - Repo

    /// 获取单个仓库完整元数据（2026-06-08 引入，Weekly 详情页本地缓存未命中时回源用）。
    ///
    /// - Returns: 完整的 `GitHubRepoDTO`（含 description / language / stargazers_count /
    ///   topics / license / created_at / updated_at / pushed_at 等字段）。
    /// - Throws: 网络层 `NetworkError`（404 / 401 / RateLimit 等）。
    func repo(owner: String, repo: String) async throws -> GitHubRepoDTO

    /// GitHub Repository Search。返回 APIResponse 以保留 rate-limit 与分页响应头。
    func searchRepositories(
        query: GitHubRepositorySearchQuery,
        page: Int,
        perPage: Int
    ) async throws -> APIResponse<GitHubRepositorySearchDTO>

    // MARK: - Readme

    /// 拉取 README（GitHub 服务端渲染的 HTML 片段）。
    /// - Parameters:
    ///   - owner / repo: 仓库 owner 与 name
    ///   - ifNoneMatch: 上次响应保存的 ETag；非空时带 If-None-Match → 304 命中本地缓存
    ///   - ifModifiedSince: 上次响应保存的 Last-Modified；与 ifNoneMatch 等效，二选一即可
    /// - Returns: 字节响应 + ETag / Last-Modified / notModified 标志
    /// - Throws: 404 / 401 / RateLimit / 5xx 等 `NetworkError`
    func readmeHTML(
        owner: String,
        repo: String,
        ifNoneMatch: String?,
        ifModifiedSince: String?,
        requestTimeout: TimeInterval?
    ) async throws -> BytesResponse

    /// 拉取 README 原始 Markdown 文本（决策 E3：按需懒补全）。
    ///
    /// 与 `readmeHTML` 并列、不替换。HTML 是 WebView 渲染主路径，Markdown 走"AI / 向量化按需补"
    /// 路径，落到 `readmes.content`。详见 `docs/3-设计/详细设计/26-向量搜索改进.md` § 3.2。
    ///
    /// - Parameters:
    ///   - owner / repo: 仓库 owner 与 name
    ///   - ifNoneMatch: 上次响应保存的 ETag；非空时带 If-None-Match → 304 命中本地缓存
    ///   - ifModifiedSince: 上次响应保存的 Last-Modified；与 ifNoneMatch 等效，二选一即可
    /// - Returns: 字节响应 + ETag / Last-Modified / notModified 标志
    /// - Throws: 404 / 401 / RateLimit / 5xx 等 `NetworkError`
    func readmeMarkdown(
        owner: String,
        repo: String,
        ifNoneMatch: String?,
        ifModifiedSince: String?,
        requestTimeout: TimeInterval?
    ) async throws -> BytesResponse

    /// 拉取仓库内指定文件的 GitHub 渲染 HTML（Contents API）。
    ///
    /// 与 `/readme` 不同：这里按 path 取任意 Markdown，用来打开语言版 / CONTRIBUTING 等。
    func repositoryFileHTML(
        owner: String,
        repo: String,
        path: String,
        ref: String,
        ifNoneMatch: String?,
        requestTimeout: TimeInterval?
    ) async throws -> BytesResponse

    // MARK: - Subscription (Watch)

    func getSubscription(owner: String, repo: String) async throws -> GitHubSubscriptionDTO
    func putSubscription(owner: String, repo: String, subscribed: Bool, ignored: Bool) async throws -> GitHubSubscriptionDTO
    func deleteSubscription(owner: String, repo: String) async throws

    // MARK: - Releases (HOM-47)

    /// 拉取一页 Releases（按 GitHub 默认排序，最新在前）。
    func releases(owner: String, repo: String, perPage: Int) async throws -> APIResponse<[GitHubReleaseDTO]>

    // MARK: - Events（Activity 公告与关注 PR-2，2026-06-16）

    /// 拉取「我关注的人/组织」最近的公开活动 feed。
    ///
    /// - Parameter ifNoneMatch: 上次响应保存的 ETag；304 命中时实现方抛
    ///   `NetworkError.notModified(etag:)`，与 Stars / Readme 端点同款契约。
    /// - Returns: `APIResponse<[GitHubEventDTO]>` —— linkHeader 永远为 `(nil, nil)`
    ///   （events 不分页，是 30 天滑动窗口）。
    func receivedEvents(
        username: String,
        perPage: Int,
        ifNoneMatch: String?
    ) async throws -> APIResponse<[GitHubEventDTO]>

    // MARK: - Notifications inbox（2026-08-19）

    /// `GET /notifications`。304 时 `notModified == true` 且 `threads` 为空，不抛 `notModified`。
    func listNotifications(
        all: Bool,
        since: String?,
        page: Int,
        perPage: Int,
        ifModifiedSince: String?
    ) async throws -> GitHubNotificationsListResponse

    /// `GET subject.url` 补全请求人 / 正文 / 官方 html_url。
    func hydrateNotificationSubject(path: String) async throws -> GitHubNotificationSubjectHydration

    /// `GET .../issues/{n}/comments`。失败由调用方忽略，正文仍可用。
    func listNotificationIssueComments(path: String) async throws -> [GitHubNotificationComment]

    /// `POST .../issues/{n}/comments`。公开仓库用现有 `public_repo`；私有仓可能 404。
    func createNotificationIssueComment(path: String, body: String) async throws -> GitHubNotificationComment

    /// `PATCH /notifications/threads/{id}` 标已读。成功含 205。
    func markNotificationThreadRead(id: String) async throws

    /// `DELETE /notifications/threads/{id}` 标 Done，从 GitHub inbox 拿掉。成功含 204。
    func markNotificationThreadDone(id: String) async throws

    /// `PATCH .../issues/{n}` 改 `state`。公开仓 `public_repo` 即可；私仓可能 404。
    func updateNotificationIssueState(path: String, state: String) async throws

    /// 把图片传到 `uploads.github.com/user-attachments/assets`，返回可写进评论 Markdown 的 URL。
    /// 未文档化；公开仓 `public_repo` 即可，私仓可能 404。
    func uploadUserAttachment(
        fileName: String,
        contentType: String,
        repositoryID: Int64,
        data: Data
    ) async throws -> URL

    // MARK: - Organization Issues（2026-08-21）

    /// 拉取当前用户在指定组织内可见的一页 Issue；实现方必须排除 Pull Request。
    func organizationIssues(
        organization: String,
        state: GitHubOrganizationIssueState,
        page: Int,
        perPage: Int
    ) async throws -> APIResponse<[GitHubOrganizationIssue]>

    // MARK: - Security Advisories（Activity 公告与关注 PR-3，2026-06-17）

    /// 拉取单个仓库的 Security Advisory 列表（可能为空数组）。
    func securityAdvisories(owner: String, repo: String) async throws -> APIResponse<[GitHubSecurityAdvisoryDTO]>
}

extension GitHubAPIClientProtocol {
    /// 未指定超时的既有调用保持默认 URLSession 策略；RAG 构建会显式传入短超时。
    func readmeHTML(
        owner: String,
        repo: String,
        ifNoneMatch: String?,
        ifModifiedSince: String?
    ) async throws -> BytesResponse {
        try await readmeHTML(
            owner: owner,
            repo: repo,
            ifNoneMatch: ifNoneMatch,
            ifModifiedSince: ifModifiedSince,
            requestTimeout: nil
        )
    }

    func readmeMarkdown(
        owner: String,
        repo: String,
        ifNoneMatch: String?,
        ifModifiedSince: String?
    ) async throws -> BytesResponse {
        try await readmeMarkdown(
            owner: owner,
            repo: repo,
            ifNoneMatch: ifNoneMatch,
            ifModifiedSince: ifModifiedSince,
            requestTimeout: nil
        )
    }

    func repositoryFileHTML(
        owner: String,
        repo: String,
        path: String,
        ref: String,
        ifNoneMatch: String?,
        requestTimeout: TimeInterval?
    ) async throws -> BytesResponse {
        throw NetworkError.clientError(
            statusCode: 501,
            message: "Repository file HTML is not implemented by this client"
        )
    }

    func repositoryFileHTML(
        owner: String,
        repo: String,
        path: String,
        ref: String,
        ifNoneMatch: String?
    ) async throws -> BytesResponse {
        try await repositoryFileHTML(
            owner: owner,
            repo: repo,
            path: path,
            ref: ref,
            ifNoneMatch: ifNoneMatch,
            requestTimeout: nil
        )
    }
}

// MARK: - Conformance

/// `GitHubAPIClient` actor 已经实现了所有要求的方法（在 StarsAPI / UserAPI / ReadmeHTMLAPI
/// extension 中），这里只需空 conformance 声明。
extension GitHubAPIClient: GitHubAPIClientProtocol {}

extension GitHubAPIClientProtocol {
    /// 旧 Mock 的兼容默认实现；任何实际搜索调用都会明确失败，不会伪造空结果。
    func searchRepositories(
        query: GitHubRepositorySearchQuery,
        page: Int,
        perPage: Int
    ) async throws -> APIResponse<GitHubRepositorySearchDTO> {
        throw NetworkError.clientError(statusCode: 501, message: "Repository search is not implemented by this client")
    }

    func listNotifications(
        all: Bool,
        since: String?,
        page: Int,
        perPage: Int,
        ifModifiedSince: String?
    ) async throws -> GitHubNotificationsListResponse {
        throw NetworkError.clientError(statusCode: 501, message: "Notifications inbox is not implemented by this client")
    }

    func hydrateNotificationSubject(path: String) async throws -> GitHubNotificationSubjectHydration {
        throw NetworkError.clientError(statusCode: 501, message: "Notification subject hydration is not implemented by this client")
    }

    func listNotificationIssueComments(path: String) async throws -> [GitHubNotificationComment] {
        throw NetworkError.clientError(statusCode: 501, message: "Notification comments are not implemented by this client")
    }

    func createNotificationIssueComment(path: String, body: String) async throws -> GitHubNotificationComment {
        throw NetworkError.clientError(statusCode: 501, message: "Create notification comment is not implemented by this client")
    }

    func markNotificationThreadRead(id: String) async throws {
        throw NetworkError.clientError(statusCode: 501, message: "Mark notification thread read is not implemented by this client")
    }

    func markNotificationThreadDone(id: String) async throws {
        throw NetworkError.clientError(statusCode: 501, message: "Mark notification thread done is not implemented by this client")
    }

    func updateNotificationIssueState(path: String, state: String) async throws {
        throw NetworkError.clientError(statusCode: 501, message: "Update notification issue state is not implemented by this client")
    }

    func uploadUserAttachment(
        fileName: String,
        contentType: String,
        repositoryID: Int64,
        data: Data
    ) async throws -> URL {
        throw NetworkError.clientError(statusCode: 501, message: "User attachment upload is not implemented by this client")
    }

    func organizationIssues(
        organization: String,
        state: GitHubOrganizationIssueState,
        page: Int,
        perPage: Int
    ) async throws -> APIResponse<[GitHubOrganizationIssue]> {
        throw NetworkError.clientError(statusCode: 501, message: "Organization Issues is not implemented by this client")
    }
}
