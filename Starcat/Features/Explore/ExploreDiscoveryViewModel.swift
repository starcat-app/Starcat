//
//  ExploreDiscoveryViewModel.swift
//  Starcat
//
//  发现 / 热门 / 新发布列表状态机。
//
//  设计约束：
//  - Trending 保持走现有 TrendingViewModel，本 VM 只负责 starcat-discovery-api；
//  - 发现 / 热门 / 新发布按 Weekly bulk 思路：本地缓存全量 catalog，筛选、排序、
//    分页都在本地完成，避免切 sort/filter 时重新请求远端；
//  - 筛选切换时重算本地切片，外层清空右侧详情，避免展示已不属于当前筛选的仓库。
//

import Foundation
import Observation

@MainActor
@Observable
final class ExploreDiscoveryViewModel {

    private static let pageSize = 20
    private static let bulkTTL: TimeInterval = 30 * 60

    private(set) var repos: [DiscoveryRepoDTO] = []
    private(set) var total: Int = 0
    private(set) var nextPage: Int?
    private(set) var isLoading: Bool = false
    private(set) var isRefreshing: Bool = false
    private(set) var loadError: String?
    private(set) var cacheWarning: String?
    private(set) var reposRevision: Int = 0
    private(set) var lastRefreshedAt: Date?
    private(set) var latestSummary: DiscoverySummaryDTO?
    /// 当前 `repos` 对应的完整查询身份。
    ///
    /// 发现 / 热门 / 新发布共享同一个 ViewModel。分类刚切换而新查询尚未完成时，
    /// View 通过这个身份隐藏上一分类的结果，避免把旧列表短暂渲染到新分类下。
    private(set) var publishedQueryIdentity: String?

    var sortOption: ExploreSortOption = .recommended

    private var bulkAllRepos: [DiscoveryRepoDTO] = []
    private var filteredLocalRepos: [DiscoveryRepoDTO] = []
    private var page: Int = 1
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
        let queryIdentity = Self.queryIdentity(
            mode: mode,
            language: language,
            topic: topic,
            platform: platform,
            sort: sort
        )
        let requestID = UUID()
        inFlightRequestID = requestID
        isLoading = !showsRefreshIndicator
        isRefreshing = showsRefreshIndicator
        loadError = nil
        cacheWarning = nil

        let cached = showsRefreshIndicator ? nil : await repository.cachedBulk()
        guard !shouldStop(requestID: requestID) else {
            finish(requestID: requestID)
            return
        }

        if let cached,
           isCacheFresh(at: cached.lastFetchedAt),
           Self.isCachedBulkUsable(cached, for: mode),
           !(await isSummaryNewerThanBulk(cached, repository: repository)) {
            guard !shouldStop(requestID: requestID) else {
                finish(requestID: requestID)
                return
            }
            apply(
                snapshot: cached,
                mode: mode,
                language: language,
                topic: topic,
                platform: platform,
                sort: sort,
                bumpRevision: true
            )
            publishedQueryIdentity = queryIdentity
            finish(requestID: requestID)
            return
        }

        do {
            let fetchResult = try await repository.fetchBulk(ignoresCache: showsRefreshIndicator)
            guard !shouldStop(requestID: requestID) else {
                finish(requestID: requestID)
                return
            }
            apply(
                result: fetchResult.result,
                mode: mode,
                language: language,
                topic: topic,
                platform: platform,
                sort: sort
            )
            publishedQueryIdentity = queryIdentity
            if case .cachedFallback = fetchResult.source {
                cacheWarning = Self.cacheFallbackWarning(fetchResult.fallbackErrorDescription)
            }
        } catch is CancellationError {
            finish(requestID: requestID)
            return
        } catch {
            guard !shouldStop(requestID: requestID) else {
                finish(requestID: requestID)
                return
            }
            loadError = error.localizedDescription
            repos = []
            total = 0
            nextPage = nil
            publishedQueryIdentity = queryIdentity
            reposRevision += 1
        }

        finish(requestID: requestID)
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
        let queryIdentity = Self.queryIdentity(
            mode: mode,
            language: language,
            topic: topic,
            platform: platform,
            sort: sort
        )
        guard publishedQueryIdentity == queryIdentity else { return }
        guard let nextPage else { return }
        guard !isLoading, !isRefreshing else { return }
        guard repos.suffix(4).contains(currentRepo) else { return }

        page = nextPage
        let upperBound = min(page * Self.pageSize, filteredLocalRepos.count)
        repos = Array(filteredLocalRepos.prefix(upperBound))
        self.nextPage = upperBound < filteredLocalRepos.count ? page + 1 : nil
        reposRevision += 1
    }

    /// 生成 View 与 ViewModel 共用的查询身份，防止两边各自拼字符串后产生漂移。
    static func queryIdentity(
        mode: ExploreMode,
        language: String?,
        topic: String?,
        platform: String?,
        sort: ExploreSortOption
    ) -> String {
        [
            mode.id,
            mode == .discover ? "__language_unused__" : (language ?? "__all__"),
            mode == .discover ? (topic ?? "__all__") : "__topic_unused__",
            mode == .discover ? (platform ?? "__all__") : "__platform_unused__",
            sort.normalized(for: mode).id,
        ].joined(separator: "|")
    }

    private func apply(
        snapshot: DiscoveryBulkCachedSnapshot,
        mode: ExploreMode,
        language: String?,
        topic: String?,
        platform: String?,
        sort: ExploreSortOption,
        bumpRevision: Bool
    ) {
        bulkAllRepos = snapshot.repos
        latestSummary = snapshot.summary
        lastRefreshedAt = snapshot.lastFetchedAt
        applyFiltersLocally(
            mode: mode,
            language: language,
            topic: topic,
            platform: platform,
            sort: sort,
            bumpRevision: bumpRevision
        )
    }

    private func apply(
        result: DiscoveryBulkResult,
        mode: ExploreMode,
        language: String?,
        topic: String?,
        platform: String?,
        sort: ExploreSortOption
    ) {
        bulkAllRepos = result.repos
        latestSummary = result.summary
        lastRefreshedAt = Date()
        applyFiltersLocally(
            mode: mode,
            language: language,
            topic: topic,
            platform: platform,
            sort: sort,
            bumpRevision: true
        )
    }

    private func applyFiltersLocally(
        mode: ExploreMode,
        language: String?,
        topic: String?,
        platform: String?,
        sort: ExploreSortOption,
        bumpRevision: Bool
    ) {
        var filtered = bulkAllRepos

        switch mode {
        case .discover:
            if let topic = normalizedFilter(topic) {
                filtered = filtered.filter { $0.topics.contains(topic) }
            }
            if let platform = normalizedFilter(platform) {
                filtered = filtered.filter { $0.platforms.contains(platform) }
            }
        case .popular:
            filtered = filtered.filter { $0.categories.contains(Self.categoryCode(for: mode)) }
            if let language = normalizedFilter(language) {
                filtered = filtered.filter { repo in
                    if language == TrendingLanguage.uncategorizedKey {
                        return (repo.language ?? "").isEmpty
                    }
                    return repo.language?.caseInsensitiveCompare(language) == .orderedSame
                }
            }
        case .newReleases:
            filtered = filtered.filter { $0.categories.contains(Self.categoryCode(for: mode)) }
            if let language = normalizedFilter(language) {
                filtered = filtered.filter { repo in
                    if language == TrendingLanguage.uncategorizedKey {
                        return (repo.language ?? "").isEmpty
                    }
                    return repo.language?.caseInsensitiveCompare(language) == .orderedSame
                }
            }
        case .trending, .weekly:
            break
        }

        filtered.sort(by: Self.makeLocalSorter(sort.normalized(for: mode), mode: mode))
        filteredLocalRepos = filtered
        total = filtered.count
        page = 1
        repos = Array(filtered.prefix(Self.pageSize))
        nextPage = filtered.count > repos.count ? 2 : nil
        if bumpRevision {
            reposRevision += 1
        }
    }

    private static func makeLocalSorter(_ sort: ExploreSortOption, mode: ExploreMode) -> (DiscoveryRepoDTO, DiscoveryRepoDTO) -> Bool {
        switch sort {
        case .recommended:
            return scoreSorter(\.discoveryScore)
        case .popular:
            if mode == .popular {
                return categoryRankSorter(category: categoryCode(for: mode), fallback: scoreSorter(\.popularityScore))
            }
            return scoreSorter(\.popularityScore)
        case .activity:
            return scoreSorter(\.trendingScore)
        case .release:
            if mode == .newReleases {
                return categoryRankSorter(category: categoryCode(for: mode), fallback: scoreSorter(\.releaseScore))
            }
            return scoreSorter(\.releaseScore)
        case .nameAsc:
            return { lhs, rhs in
                let compare = lhs.fullName.localizedCaseInsensitiveCompare(rhs.fullName)
                if compare != .orderedSame { return compare == .orderedAscending }
                return lhs.repoID > rhs.repoID
            }
        case .nameDesc:
            return { lhs, rhs in
                let compare = lhs.fullName.localizedCaseInsensitiveCompare(rhs.fullName)
                if compare != .orderedSame { return compare == .orderedDescending }
                return lhs.repoID > rhs.repoID
            }
        case .stars:
            return { lhs, rhs in
                if lhs.stars != rhs.stars { return lhs.stars > rhs.stars }
                return tieBreak(lhs, rhs, mode: mode)
            }
        case .starsAscending:
            return { lhs, rhs in
                if lhs.stars != rhs.stars { return lhs.stars < rhs.stars }
                return tieBreak(lhs, rhs, mode: mode)
            }
        case .updated:
            return dateStringSorter({ $0.updatedAt ?? $0.pushedAt ?? $0.createdAt }, ascending: false, mode: mode)
        case .updatedAscending:
            return dateStringSorter({ $0.updatedAt ?? $0.pushedAt ?? $0.createdAt }, ascending: true, mode: mode)
        case .created:
            return dateStringSorter(\.createdAt, ascending: false, mode: mode)
        case .createdAscending:
            return dateStringSorter(\.createdAt, ascending: true, mode: mode)
        case .releaseDate:
            return dateStringSorter(\.latestReleaseAt, ascending: false, mode: mode)
        case .releaseDateAscending:
            return dateStringSorter(\.latestReleaseAt, ascending: true, mode: mode)
        }
    }

    private static func scoreSorter(_ keyPath: KeyPath<DiscoveryRepoDTO, Double?>) -> (DiscoveryRepoDTO, DiscoveryRepoDTO) -> Bool {
        { lhs, rhs in
            let lhsScore = lhs[keyPath: keyPath] ?? lhs.score ?? 0
            let rhsScore = rhs[keyPath: keyPath] ?? rhs.score ?? 0
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            if lhs.stars != rhs.stars { return lhs.stars > rhs.stars }
            return lhs.repoID > rhs.repoID
        }
    }

    private static func categoryRankSorter(
        category: String,
        fallback: @escaping (DiscoveryRepoDTO, DiscoveryRepoDTO) -> Bool
    ) -> (DiscoveryRepoDTO, DiscoveryRepoDTO) -> Bool {
        { lhs, rhs in
            let lhsRank = lhs.categoryRanks[category]
            let rhsRank = rhs.categoryRanks[category]
            if let lhsRank, let rhsRank, lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            if lhsRank != nil { return true }
            if rhsRank != nil { return false }
            return fallback(lhs, rhs)
        }
    }

    private static func dateStringSorter(
        _ value: @escaping (DiscoveryRepoDTO) -> String?,
        ascending: Bool,
        mode: ExploreMode
    ) -> (DiscoveryRepoDTO, DiscoveryRepoDTO) -> Bool {
        { lhs, rhs in
            let lhsDate = value(lhs) ?? ""
            let rhsDate = value(rhs) ?? ""
            if lhsDate != rhsDate {
                if lhsDate.isEmpty { return false }
                if rhsDate.isEmpty { return true }
                return ascending ? lhsDate < rhsDate : lhsDate > rhsDate
            }
            return tieBreak(lhs, rhs, mode: mode)
        }
    }

    private static func tieBreak(_ lhs: DiscoveryRepoDTO, _ rhs: DiscoveryRepoDTO, mode: ExploreMode) -> Bool {
        let lhsScore = defaultScore(lhs, mode: mode)
        let rhsScore = defaultScore(rhs, mode: mode)
        if lhsScore != rhsScore { return lhsScore > rhsScore }
        return lhs.repoID > rhs.repoID
    }

    private static func defaultScore(_ repo: DiscoveryRepoDTO, mode: ExploreMode) -> Double {
        switch mode {
        case .discover:
            return repo.discoveryScore ?? repo.score ?? 0
        case .popular:
            return repo.popularityScore ?? repo.score ?? 0
        case .newReleases:
            return repo.releaseScore ?? repo.score ?? 0
        case .trending, .weekly:
            // 趋势 / 周刊不应进入 ExploreDiscoveryViewModel；这里保留兜底只为防止未来误传
            // 导致排序崩溃，正式 UI 分别由 TrendingView / WeeklyContentView 承载。
            return repo.trendingScore ?? repo.score ?? 0
        }
    }

    private func isCacheFresh(at lastFetchedAt: Date) -> Bool {
        Date().timeIntervalSince(lastFetchedAt) < Self.bulkTTL
    }

    private func shouldStop(requestID: UUID) -> Bool {
        Task.isCancelled || inFlightRequestID != requestID
    }

    /// 只有仍持有当前 request ID 的 reload 才能收口 loading 状态，避免旧任务
    /// 被取消后把新任务刚设置的 loading / refreshing 状态提前关掉。
    private func finish(requestID: UUID) {
        guard inFlightRequestID == requestID else { return }
        isLoading = false
        isRefreshing = false
    }

    private func isSummaryNewerThanBulk(
        _ snapshot: DiscoveryBulkCachedSnapshot,
        repository: any DiscoveryRepositoryProtocol
    ) async -> Bool {
        guard let summary = await repository.cachedSummary(),
              let summaryGeneratedAt = Self.parseAPIDate(summary.generatedAt),
              let bulkGeneratedAt = Self.parseAPIDate(snapshot.generatedAt)
        else {
            return false
        }
        return summaryGeneratedAt > bulkGeneratedAt
    }

    private static func parseAPIDate(_ raw: String?) -> Date? {
        ISO8601DateFormatter.githubDate(from: raw)
    }

    private static func cacheFallbackWarning(_ errorDescription: String?) -> String {
        guard let errorDescription, !errorDescription.isEmpty else {
            return String.l10n("explore.cacheFallback.warning")
        }
        return String(format: String.l10n("explore.cacheFallback.warningFormat"), errorDescription)
    }

    private static func isCachedBulkUsable(_ snapshot: DiscoveryBulkCachedSnapshot, for mode: ExploreMode) -> Bool {
        switch mode {
        case .popular, .newReleases:
            let category = categoryCode(for: mode)
            if snapshot.repos.contains(where: { $0.categories.contains(category) }) {
                return true
            }
            guard let discoveryMode = mode.discoveryListMode else { return false }
            return snapshot.summary.mode(discoveryMode)?.total == 0
        case .discover:
            return true
        case .trending, .weekly:
            return false
        }
    }

    private static func categoryCode(for mode: ExploreMode) -> String {
        switch mode {
        case .discover:
            return "discover"
        case .trending, .weekly:
            return ""
        case .popular:
            return "popular"
        case .newReleases:
            return "new_releases"
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
