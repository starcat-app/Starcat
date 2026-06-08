//
//  RepoAPI.swift
//  Starcat
//
//  `GET /repos/{owner}/{repo}` 端点封装。
//
//  ## 用途
//  Weekly 详情页（2026-06-08 引入）在本地缓存未命中时，需要拉一份完整的 repo 元数据，
//  组装成临时 `Repo` 让 UI 复用 `RepoMetadataHeaderView`（同 Manage / Activity 详情页）。
//
//  ## 与 `/user/starred` 的区别
//  - `/user/starred` 返回 `[StarredRepoDTO]`，每个 wrapper 含 `starred_at`，并要求 token 已登录；
//    `repo` 字段是完整的 `GitHubRepoDTO`。
//  - `/repos/{owner}/{repo}` 直接返回单个 `GitHubRepoDTO`，**支持匿名访问**（公开仓库），
//    带 token 时不消耗 starred 缓存语义，单纯查 repo 元数据。
//
//  ## 设计约束
//  - 直接复用 `GitHubRepoDTO`，与 starred / events / search 等其它端点保持解码模型一致；
//  - 不在 actor 内部缓存，由调用方（如 `WeeklyDetailView`）按"选中项目"窗口期持有；
//  - 404（私有仓库 / 已删 / typo）让 `client.get` 抛 `NetworkError.notFound`，UI 决定降级路径。
//

import Foundation

extension GitHubAPIClient {

    /// 获取单个仓库完整元数据。
    ///
    /// - Parameters:
    ///   - owner: 仓库 owner（org 或 user 的 login）。
    ///   - repo: 仓库 name（不含 owner 前缀）。
    /// - Returns: 完整的 `GitHubRepoDTO`（含 description / language / stargazers_count /
    ///   topics / license / created_at / updated_at / pushed_at 等字段）。
    /// - Throws: 网络层 `NetworkError`，404 / 401 / RateLimit 等按各自语义抛。
    func repo(owner: String, repo: String) async throws -> GitHubRepoDTO {
        let response: APIResponse<GitHubRepoDTO> = try await get(
            path: AppEndpoints.GitHubREST.Paths.repo(owner: owner, repo: repo)
        )
        return response.value
    }
}
