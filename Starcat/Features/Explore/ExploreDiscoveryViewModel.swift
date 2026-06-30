//
//  ExploreDiscoveryViewModel.swift
//  Starcat
//
//  发现 / 热门 / 新发布列表状态机。
//
//  设计约束：
//  - Trending 保持走现有 TrendingViewModel，本 VM 只负责 starcat-discovery-api；
//  - 列表分页和排序全由服务端处理，客户端只维护当前页快照；
//  - 筛选切换时清空旧列表，避免右侧详情继续显示已不属于当前筛选的仓库。
//

import Foundation
import Observation

@MainActor
@Observable
final class ExploreDiscoveryViewModel {

    private static let pageSize = 20

    private(set) var repos: [DiscoveryRepoDTO] = []
    private(set) var total: Int = 0
    private(set) var nextPage: Int?
    private(set) var isLoading: Bool = false
    private(set) var isRefreshing: Bool = false
    private(set) var loadError: String?
    private(set) var reposRevision: Int = 0
    private(set) var lastRefreshedAt: Date?

    var sortOption: ExploreSortOption = .recommended

    private var inFlightRequestID = UUID()

    func reload(
        api: DiscoveryAPI,
        mode: ExploreMode,
        language: String?,
        topic: String?,
        platform: String?,
        sort: ExploreSortOption,
        showsRefreshIndicator: Bool = false
    ) async {
        let requestID = UUID()
        inFlightRequestID = requestID
        isLoading = !showsRefreshIndicator
        isRefreshing = showsRefreshIndicator
        loadError = nil

        do {
            let page = try await fetchPage(
                api: api,
                mode: mode,
                language: language,
                topic: topic,
                platform: platform,
                sort: sort,
                page: 1
            )
            guard inFlightRequestID == requestID else { return }
            repos = page.items
            total = page.total
            nextPage = page.nextPage
            lastRefreshedAt = Date()
            reposRevision += 1
        } catch {
            guard inFlightRequestID == requestID else { return }
            loadError = error.localizedDescription
            repos = []
            total = 0
            nextPage = nil
            reposRevision += 1
        }

        if inFlightRequestID == requestID {
            isLoading = false
            isRefreshing = false
        }
    }

    func loadMoreIfNeeded(
        api: DiscoveryAPI,
        currentRepo: DiscoveryRepoDTO,
        mode: ExploreMode,
        language: String?,
        topic: String?,
        platform: String?,
        sort: ExploreSortOption
    ) async {
        guard let nextPage else { return }
        guard !isLoading, !isRefreshing else { return }
        guard repos.suffix(4).contains(currentRepo) else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let page = try await fetchPage(
                api: api,
                mode: mode,
                language: language,
                topic: topic,
                platform: platform,
                sort: sort,
                page: nextPage
            )
            repos.append(contentsOf: page.items)
            total = page.total
            self.nextPage = page.nextPage
            reposRevision += 1
        } catch {
            // 追加页失败不清空当前列表，只保留日志；用户仍可点击顶部刷新重试。
            AppLog.network.warning("Explore load more failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func fetchPage(
        api: DiscoveryAPI,
        mode: ExploreMode,
        language: String?,
        topic: String?,
        platform: String?,
        sort: ExploreSortOption,
        page: Int
    ) async throws -> DiscoveryPage {
        let query = DiscoveryListQuery(
            language: normalizedFilter(language),
            platform: normalizedFilter(platform),
            topic: normalizedFilter(topic),
            sort: sort.normalized(for: mode).apiValue,
            page: page,
            limit: Self.pageSize
        )

        switch mode {
        case .discover:
            return try await api.fetchFeed(query: query)
        case .popular:
            return try await api.fetchMostPopular(query: query)
        case .newReleases:
            return try await api.fetchNewReleases(query: query)
        case .trending:
            assertionFailure("Trending keeps using TrendingViewModel")
            return DiscoveryPage(items: [], total: 0, page: page, pageSize: Self.pageSize, nextPage: nil)
        }
    }

    private func normalizedFilter(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
