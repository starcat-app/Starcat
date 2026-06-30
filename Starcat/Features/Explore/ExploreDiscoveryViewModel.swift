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
        repository: any DiscoveryRepositoryProtocol,
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

        let query = makeQuery(
            mode: mode,
            language: language,
            topic: topic,
            platform: platform,
            sort: sort,
            page: 1
        )

        var didShowCachedPage = false
        if !showsRefreshIndicator,
           let cached = await repository.cachedPage(mode: mode.discoveryListMode, query: query) {
            guard inFlightRequestID == requestID else { return }
            apply(cached)
            didShowCachedPage = true
            isLoading = false
        }

        do {
            let cachedPage = try await repository.fetchPage(mode: mode.discoveryListMode, query: query)
            guard inFlightRequestID == requestID else { return }
            apply(cachedPage)
        } catch {
            guard inFlightRequestID == requestID else { return }
            loadError = error.localizedDescription
            if !didShowCachedPage {
                repos = []
                total = 0
                nextPage = nil
                reposRevision += 1
            }
        }

        if inFlightRequestID == requestID {
            isLoading = false
            isRefreshing = false
        }
    }

    func loadMoreIfNeeded(
        repository: any DiscoveryRepositoryProtocol,
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
            let query = makeQuery(
                mode: mode,
                language: language,
                topic: topic,
                platform: platform,
                sort: sort,
                page: nextPage
            )
            let cachedPage = try await repository.fetchPage(mode: mode.discoveryListMode, query: query)
            repos.append(contentsOf: cachedPage.page.items)
            total = cachedPage.page.total
            self.nextPage = cachedPage.page.nextPage
            lastRefreshedAt = cachedPage.cachedAt
            reposRevision += 1
        } catch {
            // 追加页失败不清空当前列表，只保留日志；用户仍可点击顶部刷新重试。
            AppLog.network.warning("Explore load more failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func makeQuery(
        mode: ExploreMode,
        language: String?,
        topic: String?,
        platform: String?,
        sort: ExploreSortOption,
        page: Int
    ) -> DiscoveryListQuery {
        DiscoveryListQuery(
            language: normalizedFilter(language),
            platform: normalizedFilter(platform),
            topic: normalizedFilter(topic),
            sort: sort.normalized(for: mode).apiValue,
            page: page,
            limit: Self.pageSize
        )
    }

    private func apply(_ cachedPage: DiscoveryCachedPage) {
        repos = cachedPage.page.items
        total = cachedPage.page.total
        nextPage = cachedPage.page.nextPage
        lastRefreshedAt = cachedPage.cachedAt
        reposRevision += 1
    }

    private func normalizedFilter(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
