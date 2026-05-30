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
            path: "/user/starred",
            queryItems: query,
            accept: "application/vnd.github.star+json",
            ifNoneMatch: ifNoneMatch
        )
    }

    /// 取消 star。
    func unstar(owner: String, repo: String) async throws {
        try await delete(path: "/user/starred/\(owner)/\(repo)")
    }

    /// 重新 star（仅作为接口完备性提供，UI 暂不调用）。
    func star(owner: String, repo: String) async throws {
        try await put(path: "/user/starred/\(owner)/\(repo)")
    }
}
