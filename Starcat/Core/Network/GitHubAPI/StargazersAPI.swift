//
//  StargazersAPI.swift
//  Starcat
//
//  仓库管理员 / 协作者专用的 GitHub Stargazers 分页端点。
//
//  关键约束：
//  - GitHub 2026-07 起限制普通第三方读取 Stargazers 列表，调用方必须先根据
//    `user_projects` 的权限和授权来源决定是否允许请求；
//  - `application/vnd.github.star+json` 才会返回 `starred_at`；
//  - DTO 故意不解码 user，避免业务层持有或落库 Stargazer 身份信息。
//

import Foundation

/// 单个当前 Stargazer 的 Star 时间；用户身份不进入 Starcat 数据模型。
struct GitHubStargazerDTO: Decodable, Equatable, Sendable {
    let starredAt: String
}

/// Star History Repository 只依赖此窄协议，单测无需构造完整 GitHub 客户端。
protocol GitHubStargazersAPIProtocol: Sendable {
    func stargazers(
        owner: String,
        repo: String,
        page: Int,
        perPage: Int
    ) async throws -> APIResponse<[GitHubStargazerDTO]>
}

extension GitHubAPIClient {

    /// 拉取一页当前 Stargazers，并保留 Link Header 供上层完整分页。
    func stargazers(
        owner: String,
        repo: String,
        page: Int,
        perPage: Int = 100
    ) async throws -> APIResponse<[GitHubStargazerDTO]> {
        precondition(page >= 1, "page must be >= 1")
        precondition(perPage >= 1 && perPage <= 100, "perPage must be in [1, 100]")

        return try await get(
            path: AppEndpoints.GitHubREST.Paths.repoStargazers(owner: owner, repo: repo),
            queryItems: [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "per_page", value: String(perPage))
            ],
            accept: "application/vnd.github.star+json"
        )
    }
}

extension GitHubAPIClient: GitHubStargazersAPIProtocol {}
