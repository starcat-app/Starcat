//
//  RepositoryLanguageService.swift
//  Starcat
//
//  仓库详情语言分布的数据边界：读取洞察缓存，并在缓存缺失或过期时刷新 GitHub Languages API。
//

import Foundation

/// 详情语言横条依赖的最小数据协议，便于状态机在测试中验证 cache-first 与刷新行为。
protocol RepositoryLanguageServing: Sendable {
    func cachedLanguages(
        repoID: Int64
    ) async throws -> RepositoryInsightsCachedValue<[String: Int]>?

    func refreshLanguages(
        repoID: Int64,
        owner: String,
        name: String
    ) async throws -> [String: Int]
}

/// 使用现有洞察快照表持久化 GitHub 返回的语言字节分布。
///
/// 这里缓存原始字节而不是 UI 百分比，避免将 Top 5、Other 等展示策略固化到数据层；
/// 将来其它页面复用时可以按自己的容量重新切片。
struct RepositoryLanguageService: RepositoryLanguageServing, Sendable {
    private let apiClient: any GitHubAPIClientProtocol
    private let cache: any RepositoryInsightsCaching

    init(
        apiClient: any GitHubAPIClientProtocol,
        cache: any RepositoryInsightsCaching
    ) {
        self.apiClient = apiClient
        self.cache = cache
    }

    func cachedLanguages(
        repoID: Int64
    ) async throws -> RepositoryInsightsCachedValue<[String: Int]>? {
        try await cache.load(
            repoId: repoID,
            dataset: .languages,
            range: .all,
            as: [String: Int].self
        )
    }

    func refreshLanguages(
        repoID: Int64,
        owner: String,
        name: String
    ) async throws -> [String: Int] {
        let languages = try await apiClient.repositoryLanguages(owner: owner, repo: name)
        try await cache.store(
            languages,
            repoId: repoID,
            dataset: .languages,
            range: .all,
            fetchedAt: Date(),
            responseETag: nil,
            defaultBranchSHA: nil
        )
        return languages
    }
}
