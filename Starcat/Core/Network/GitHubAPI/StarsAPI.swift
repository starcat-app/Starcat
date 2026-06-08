//
//  StarsAPI.swift
//  Starcat
//
//  GET /user/starred 系列端点封装。
//
//  关键点：
//  - Accept 头必须为 `application/vnd.github.star+json` 才会返回 starred_at；
//    默认的 `vnd.github+json` 只返回 repo 元数据
//  - 分页：page + per_page（最大 100）；总页数从 Link 头 rel="last" 解析
//  - GitHub 没有真正的 delta query：客户端需要拉全量然后对比本地（见 SyncManager）
//

import Foundation

extension GitHubAPIClient {

    /// 拉取一页 starred repos。
    /// - Parameters:
    ///   - page: 页码，从 1 开始。
    ///   - perPage: 每页条数，最大 100。
    ///   - ifNoneMatch: W4-4 C2，条件请求的 ETag（含双引号原样回传）。
    ///     若服务端内容未变化，client.perform 会抛 `NetworkError.notModified(etag:)`。
    func starredRepos(page: Int, perPage: Int = 100, ifNoneMatch: String? = nil) async throws -> APIResponse<[StarredRepoDTO]> {
        precondition(page >= 1, "page must be >= 1")
        precondition(perPage >= 1 && perPage <= 100, "perPage must be in [1, 100]")

        let query: [URLQueryItem] = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per_page", value: String(perPage)),
            URLQueryItem(name: "sort", value: "created"),       // 按 star 时间排序
            URLQueryItem(name: "direction", value: "desc")
        ]
        return try await get(
            path: AppEndpoints.GitHubREST.Paths.userStarred,
            queryItems: query,
            accept: "application/vnd.github.star+json",
            ifNoneMatch: ifNoneMatch
        )
    }

    /// 取消 star。
    func unstar(owner: String, repo: String) async throws {
        try await delete(path: AppEndpoints.GitHubREST.Paths.starRepo(owner: owner, repo: repo))
    }

    /// 重新 star（仅作为接口完备性提供，UI 暂不调用）。
    func star(owner: String, repo: String) async throws {
        try await put(path: AppEndpoints.GitHubREST.Paths.starRepo(owner: owner, repo: repo))
    }

    // MARK: - Subscription (Watch)

    /// 获取 Watch 订阅状态。
    ///
    /// **重要：404 是预期行为，不是错误**。
    ///
    /// GitHub Watch API 的 4 档状态返回方式：
    /// - All Activity（订阅所有事件）→ `200` + `subscribed=true, ignored=false`
    /// - Ignore（忽略全部）         → `200` + `subscribed=false, ignored=true`
    /// - Custom（自定义事件类型）    → `200` + 其他 subscribed/ignored 组合
    /// - **Participating + @mentions**（GitHub 默认级别，用户未显式设置）→ **`404`**
    ///
    /// 也就是说 `404` 不代表"找不到 repo"，而是"该用户对这个 repo 没有显式订阅记录、
    /// 保持 GitHub 默认的 Participating 级别"——这是 GitHub 自己的设计，被吐槽过但没改。
    ///
    /// 调用方约定：必须显式 `catch NetworkError.notFound` 并翻译为 `.participating`
    /// （见 `RepoDetailView.fetchSubscription()`），不能把 404 当 error 处理，更不能
    /// 当成"repo 不存在"——否则会让所有未手动改过 Watch 的仓库都显示报错。
    ///
    /// Console.app 看到 `GET /repos/X/Y/subscription -> 404` 是正常 debug 日志，
    /// 配额信息 `rl=4983/5000` 表示当前 1 小时窗口内 API 配额还剩多少。
    func getSubscription(owner: String, repo: String) async throws -> GitHubSubscriptionDTO {
        let response: APIResponse<GitHubSubscriptionDTO> = try await get(
            path: AppEndpoints.GitHubREST.Paths.repoSubscription(owner: owner, repo: repo)
        )
        return response.value
    }

    /// 设置 Watch 状态
    func putSubscription(owner: String, repo: String, subscribed: Bool, ignored: Bool) async throws -> GitHubSubscriptionDTO {
        let body = GitHubSubscriptionRequestDTO(subscribed: subscribed, ignored: ignored)
        let response: APIResponse<GitHubSubscriptionDTO> = try await put(
            path: AppEndpoints.GitHubREST.Paths.repoSubscription(owner: owner, repo: repo),
            body: body
        )
        return response.value
    }

    /// 取消 Watch
    func deleteSubscription(owner: String, repo: String) async throws {
        try await delete(path: AppEndpoints.GitHubREST.Paths.repoSubscription(owner: owner, repo: repo))
    }
}
