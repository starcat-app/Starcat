//
//  CompanionRecommendationHandler.swift
//  Starcat
//
//  Browser Plugin 推荐列表翻页入口。
//
//  翻页状态由 `RecommendationContextService` 的本地快照持有。浏览器只表达
//  “加载下一页”，不能传 offset，避免重复点击或旧页面状态导致跳页。
//

import Foundation

enum CompanionRecommendationError: Error, Equatable {
    case invalidRepoPath
    case repoNotFound
    case requiresPro
}

@MainActor
struct CompanionRecommendationHandler {
    private let lookupRepo: @Sendable (String, String) async throws -> Repo?
    private let loadNextPage: @MainActor @Sendable (Int64) async throws -> CompanionRecommendationsPageResponse
    private let isProUser: @Sendable () async -> Bool

    init(
        repoRepository: any RepoRepositoryProtocol,
        service: RecommendationContextService,
        entitlementGate: EntitlementGate? = nil
    ) {
        self.init(
            lookupRepo: { owner, name in
                try await repoRepository.findByOwnerName(owner: owner, name: name)
            },
            loadNextPage: { repoID in
                guard let current = service.cachedSnapshot(repoID: repoID) else {
                    // 缓存被设置页清理后，首次“加载更多”退化为重建第一页；插件端
                    // 会按 repoID/fullName 去重，不会把已有卡片重复插入。
                    let fresh = try await service.refresh(repoID: repoID)
                    return CompanionRecommendationsPageResponse(
                        schemaVersion: 1,
                        status: "ok",
                        recommendations: fresh.items.map(CompanionContextProvider.recommendationDTO(_:)),
                        hasMore: fresh.hasMore
                    )
                }

                let added = try await service.refreshNextPage(
                    repoID: repoID,
                    currentSnapshot: current
                )
                let hasMore = service.cachedSnapshot(repoID: repoID)?.hasMore ?? false
                return CompanionRecommendationsPageResponse(
                    schemaVersion: 1,
                    status: "ok",
                    recommendations: added.map(CompanionContextProvider.recommendationDTO(_:)),
                    hasMore: hasMore
                )
            },
            isProUser: {
                await MainActor.run { entitlementGate?.isProUser ?? false }
            }
        )
    }

    /// 测试注入点。
    init(
        lookupRepo: @escaping @Sendable (String, String) async throws -> Repo?,
        loadNextPage: @escaping @MainActor @Sendable (Int64) async throws -> CompanionRecommendationsPageResponse,
        isProUser: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.lookupRepo = lookupRepo
        self.loadNextPage = loadNextPage
        self.isProUser = isProUser
    }

    func loadMore(owner rawOwner: String, repo rawRepo: String) async throws -> CompanionRecommendationsPageResponse {
        let owner = rawOwner.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = rawRepo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CompanionContextProvider.isValidGitHubPathComponent(owner),
              CompanionContextProvider.isValidGitHubPathComponent(name) else {
            throw CompanionRecommendationError.invalidRepoPath
        }
        guard let repo = try await lookupRepo(owner, name) else {
            throw CompanionRecommendationError.repoNotFound
        }
        guard await isProUser() else {
            throw CompanionRecommendationError.requiresPro
        }
        return try await loadNextPage(repo.id)
    }
}
