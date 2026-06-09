//
//  GitHubFallbackRepoSource.swift
//  Starcat
//
//  R-01 RepoSource chain 第四节：GitHub 官方 `/repos/{o}/{r}` 兜底拉。
//
//  适用场景：
//  - 用户没 star、列表也没 hint（极少见，例如外链导航 / URL scheme 进详情页）
//  - 或 hint 大小写不匹配被 BackendHintRepoSource 跳过
//
//  约束：
//  - GitHub Rate Limit：未授权 60 req/h，授权 5000 req/h；详情页常规进入即触发，
//    `RepoResolver` 已建立 chain 顺序保证大多数场景前面的源就命中，本源真正被调
//    的频次有限
//  - throws 由 `RepoResolver` catch 跳过此源（如 404 / 401 / 网络超时）
//

import Foundation

struct GitHubFallbackRepoSource: RepoSource {
    let name = "GitHubFallbackRepoSource"

    private let apiClient: any GitHubAPIClientProtocol

    init(apiClient: any GitHubAPIClientProtocol) {
        self.apiClient = apiClient
    }

    func tryResolve(owner: String, name: String, hint: StarcatRepoCardDTO?) async throws -> Repo? {
        // 拉完整 GitHubRepoDTO，转 in-memory Repo（不入库；isStarred = false 因为用户
        // 未 star，registry 由 view 层在适配 viewData 时另判）
        let dto = try await apiClient.repo(owner: owner, repo: name)
        let cachedAtISO = ISO8601DateFormatter.shared.string(from: Date())
        return GRDBRepoRepository.repoFromDTO(
            dto,
            starredAt: nil,
            cachedAt: cachedAtISO,
            isStarred: false
        )
    }
}
