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
    private static let bulkTTL: TimeInterval = 12 * 60 * 60

    private(set) var repos: [DiscoveryRepoDTO] = []
    private(set) var total: Int = 0
    private(set) var nextPage: Int?
    private(set) var isLoading: Bool = false
    private(set) var isRefreshing: Bool = false
    private(set) var loadError: String?
    private(set) var reposRevision: Int = 0
    private(set) var lastRefreshedAt: Date?

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
        let requestID = UUID()
        inFlightRequestID = requestID
        isLoading = !showsRefreshIndicator
        isRefreshing = showsRefreshIndicator
        loadError = nil

        var didShowCachedBulk = false
        if !showsRefreshIndicator,
           let cached = await repository.cachedBulk() {
            guard inFlightRequestID == requestID else { return }
            apply(
                snapshot: cached,
                mode: mode,
                language: language,
                topic: topic,
                platform: platform,
                sort: sort,
                bumpRevision: false
            )
            didShowCachedBulk = true
            isLoading = false
            if isCacheFresh(at: cached.lastFetchedAt) {
                isRefreshing = false
                return
            }
        }

        do {
            let bulk = try await repository.fetchBulk()
            guard inFlightRequestID == requestID else { return }
            apply(
                result: bulk,
                mode: mode,
                language: language,
                topic: topic,
                platform: platform,
                sort: sort
            )
        } catch {
            guard inFlightRequestID == requestID else { return }
            loadError = error.localizedDescription
            if !didShowCachedBulk {
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

        page = nextPage
        let upperBound = min(page * Self.pageSize, filteredLocalRepos.count)
        repos = Array(filteredLocalRepos.prefix(upperBound))
        self.nextPage = upperBound < filteredLocalRepos.count ? page + 1 : nil
        reposRevision += 1
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
        case .popular, .newReleases:
            if let language = normalizedFilter(language) {
                filtered = filtered.filter { repo in
                    if language == TrendingLanguage.uncategorizedKey {
                        return (repo.language ?? "").isEmpty
                    }
                    return repo.language?.caseInsensitiveCompare(language) == .orderedSame
                }
            }
        case .trending:
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
            return scoreSorter(\.popularityScore)
        case .activity:
            return scoreSorter(\.trendingScore)
        case .release:
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
        case .trending:
            return repo.trendingScore ?? repo.score ?? 0
        }
    }

    private func isCacheFresh(at lastFetchedAt: Date) -> Bool {
        Date().timeIntervalSince(lastFetchedAt) < Self.bulkTTL
    }

    private func normalizedFilter(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
