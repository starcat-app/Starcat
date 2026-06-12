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
        ifModifiedSince: String?
    ) async throws -> BytesResponse

    /// 拉取 README 原始 Markdown 文本（决策 E3：按需懒补全）。
    ///
    /// 与 `readmeHTML` 并列、不替换。HTML 是 WebView 渲染主路径，Markdown 走"AI / 向量化按需补"
    /// 路径，落到 `readmes.content`。详见 `docs/详细设计/26-向量搜索改进.md` § 3.2。
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
        ifModifiedSince: String?
    ) async throws -> BytesResponse

    // MARK: - Subscription (Watch)

    func getSubscription(owner: String, repo: String) async throws -> GitHubSubscriptionDTO
    func putSubscription(owner: String, repo: String, subscribed: Bool, ignored: Bool) async throws -> GitHubSubscriptionDTO
    func deleteSubscription(owner: String, repo: String) async throws

    // MARK: - Releases (HOM-47)

    /// 拉取一页 Releases（按 GitHub 默认排序，最新在前）。
    func releases(owner: String, repo: String, perPage: Int) async throws -> APIResponse<[GitHubReleaseDTO]>
}

// MARK: - Conformance

/// `GitHubAPIClient` actor 已经实现了所有要求的方法（在 StarsAPI / UserAPI / ReadmeHTMLAPI
/// extension 中），这里只需空 conformance 声明。
extension GitHubAPIClient: GitHubAPIClientProtocol {}
