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
    /// 语言 / Topic / 平台组合使用有界近期工作集，避免查询快照无限增长。
    private static let preparedSnapshotCapacity = 12
    /// Discovery 服务端默认每 3 小时刷新一次 bulk；客户端复用同一窗口，
    /// 避免本地 30 分钟一过就重复请求尚未更新的服务端快照。
    private static let bulkTTL: TimeInterval = 3 * 60 * 60
    /// 自动刷新失败后暂缓重试。用户切换发现 / 热门 / 新发布时只做本地派生，
    /// 避免已知不可用的服务在每次分类切换时都触发一次超时请求；手动刷新不受此限制。
    private static let automaticRefreshFailureCooldown: TimeInterval = 5 * 60

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

    /// 设置页「感兴趣语言」镜像。「其他」分类的本地过滤依赖它，由 View onChange 同步。
    var interestedLanguages: [String] = []

    private var bulkAllRepos: [DiscoveryRepoDTO] = []
    private var filteredLocalRepos: [DiscoveryRepoDTO] = []
    /// 已完成 filter / sort 的查询结果；命中时只发布首屏，不再扫描 bulk。
    private var preparedSnapshots: [String: PreparedSnapshot] = [:]
    private var preparedSnapshotLRU: [String] = []
    private var page: Int = 1
    private var inFlightRequestID = UUID()
    private var automaticRefreshBlockedUntil: Date?
    /// 定向测试确认 prepared snapshot 命中没有再次扫描 bulk；不参与 UI 逻辑。
    private(set) var localDerivationCountForTesting = 0

    private struct PreparedSnapshot {
        let filteredRepos: [DiscoveryRepoDTO]
    }

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
            sort: sort,
            interestedLanguages: Set(self.interestedLanguages.map { $0.lowercased() })
        )
        let requestID = UUID()
        inFlightRequestID = requestID
        isLoading = !showsRefreshIndicator
        isRefreshing = showsRefreshIndicator
        loadError = nil
        cacheWarning = nil
        var didPublishLocalSnapshot = showsRefreshIndicator
            && publishedQueryIdentity == queryIdentity
            && !bulkAllRepos.isEmpty

        // A → B → A 时直接提交已经派生好的快照。TTL 过期只触发后台 SWR，
        // 不让仍可用的列表重新退回骨架屏。
        if !showsRefreshIndicator, let prepared = preparedSnapshot(for: queryIdentity) {
            publishPreparedSnapshot(prepared, bumpRevision: true)
            publishedQueryIdentity = queryIdentity
            isLoading = false
            didPublishLocalSnapshot = true

            if let lastRefreshedAt, isCacheFresh(at: lastRefreshedAt) {
                finish(requestID: requestID)
                return
            }
            if skipAutomaticRefreshDuringCooldown() {
                finish(requestID: requestID)
                return
            }
            isRefreshing = true
        }

        // 发现 / 热门 / 新发布共用同一 bulk。切换分类时先用会话内快照后台派生首屏，
        // 不再每次重新读取 SQLite；快照过期时仍保留已发布列表并继续后台刷新。
        if !showsRefreshIndicator, !didPublishLocalSnapshot, !bulkAllRepos.isEmpty {
            await applyFiltersLocally(
                sourceRepos: bulkAllRepos,
                mode: mode,
                language: language,
                topic: topic,
                platform: platform,
                sort: sort,
                bumpRevision: true,
                requestID: requestID
            )
            guard !shouldStop(requestID: requestID) else {
                finish(requestID: requestID)
                return
            }
            publishedQueryIdentity = queryIdentity
            isLoading = false
            didPublishLocalSnapshot = true

            if let lastRefreshedAt, isCacheFresh(at: lastRefreshedAt) {
                finish(requestID: requestID)
                return
            }
            if skipAutomaticRefreshDuringCooldown() {
                finish(requestID: requestID)
                return
            }
            isRefreshing = true
        }

        let cached = showsRefreshIndicator || !bulkAllRepos.isEmpty
            ? nil
            : await repository.cachedBulk()
        guard !shouldStop(requestID: requestID) else {
            finish(requestID: requestID)
            return
        }

        if let cached, Self.isCachedBulkUsable(cached, for: mode) {
            let cacheIsStale = !isCacheFresh(at: cached.lastFetchedAt)
            let summaryIsNewer = await isSummaryNewerThanBulk(cached, repository: repository)
            let requiresRefresh = cacheIsStale || summaryIsNewer
            guard !shouldStop(requestID: requestID) else {
                finish(requestID: requestID)
                return
            }
            await apply(
                snapshot: cached,
                mode: mode,
                language: language,
                topic: topic,
                platform: platform,
                sort: sort,
                bumpRevision: true,
                requestID: requestID
            )
            guard !shouldStop(requestID: requestID) else {
                finish(requestID: requestID)
                return
            }
            publishedQueryIdentity = queryIdentity
            isLoading = false
            didPublishLocalSnapshot = true

            if !requiresRefresh || skipAutomaticRefreshDuringCooldown() {
                finish(requestID: requestID)
                return
            }
            isRefreshing = true
        }

        do {
            let fetchResult = try await repository.fetchBulk(ignoresCache: showsRefreshIndicator)
            guard !shouldStop(requestID: requestID) else {
                finish(requestID: requestID)
                return
            }
            if fetchResult.source == .remote || !didPublishLocalSnapshot {
                await apply(
                    result: fetchResult.result,
                    mode: mode,
                    language: language,
                    topic: topic,
                    platform: platform,
                    sort: sort,
                    requestID: requestID
                )
            }
            guard !shouldStop(requestID: requestID) else {
                finish(requestID: requestID)
                return
            }
            publishedQueryIdentity = queryIdentity
            if case .cachedFallback = fetchResult.source {
                cacheWarning = Self.cacheFallbackWarning(fetchResult.fallbackErrorDescription)
                if !showsRefreshIndicator {
                    recordAutomaticRefreshFailure()
                }
            } else {
                automaticRefreshBlockedUntil = nil
            }
        } catch is CancellationError {
            finish(requestID: requestID)
            return
        } catch {
            guard !shouldStop(requestID: requestID) else {
                finish(requestID: requestID)
                return
            }
            if !showsRefreshIndicator {
                recordAutomaticRefreshFailure()
            }
            if !bulkAllRepos.isEmpty || didPublishLocalSnapshot {
                // SWR / 手动刷新失败不能删除最后一次成功快照；列表保持可用，只提示缓存状态。
                loadError = nil
                cacheWarning = Self.cacheFallbackWarning(error.localizedDescription)
            } else {
                loadError = error.localizedDescription
                repos = []
                total = 0
                nextPage = nil
                reposRevision += 1
            }
            publishedQueryIdentity = queryIdentity
        }

        finish(requestID: requestID)
    }

    func loadMoreIfNeeded(
        repository: any DiscoveryRepositoryProtocol,
        currentRepo: DiscoveryRepoDTO?,
        appearingIndex: Int? = nil,
        visibleItemCount: Int? = nil,
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
            sort: sort,
            interestedLanguages: Set(self.interestedLanguages.map { $0.lowercased() })
        )
        guard publishedQueryIdentity == queryIdentity else { return }
        guard let nextPage else { return }
        // 只拦初次加载，不拦 SWR 后台刷新（isRefreshing）。进入分类时 summary/bulk 的
        // 3h 窗口几乎必然触发一次后台刷新，若用它拦截分页，快速滚动期间的所有触发都会
        // 被吞掉；刷新完成后 publishPreparedSnapshot 重置回首屏且已加载数量不变，
        // 共享 modifier 的 onChange 不会重新评估，需求就永久丢失（用户必须来回滚动才能续页）。
        // 本地切片在 MainActor 上串行执行，与刷新的替换发布之间没有竞态。
        guard !isLoading else { return }
        if let appearingIndex, let visibleItemCount {
            guard ListPaginationPolicy.shouldPrefetch(
                appearingIndex: appearingIndex,
                itemCount: visibleItemCount,
                hasMore: true
            ) else { return }
        } else if let currentRepo {
            guard let sourceIndex = repos.firstIndex(of: currentRepo),
                  ListPaginationPolicy.shouldPrefetch(
                      appearingIndex: sourceIndex,
                      itemCount: repos.count,
                      hasMore: true
                  ) else { return }
        }

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
        sort: ExploreSortOption,
        interestedLanguages: Set<String> = []
    ) -> String {
        // 「其他」分类的过滤结果依赖感兴趣语言，identity 必须纳入，避免命中脏快照。
        let otherSuffix = (language == TrendingLanguage.otherRawValue)
            ? ":other:" + interestedLanguages.sorted().joined(separator: ",")
            : ""
        return [
            mode.id,
            mode == .discover ? "__language_unused__" : (language ?? "__all__") + otherSuffix,
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
        bumpRevision: Bool,
        requestID: UUID
    ) async {
        clearPreparedSnapshots()
        await applyFiltersLocally(
            sourceRepos: snapshot.repos,
            mode: mode,
            language: language,
            topic: topic,
            platform: platform,
            sort: sort,
            bumpRevision: bumpRevision,
            requestID: requestID
        )
        guard !shouldStop(requestID: requestID) else { return }
        bulkAllRepos = snapshot.repos
        latestSummary = snapshot.summary
        lastRefreshedAt = snapshot.lastFetchedAt
    }

    private func apply(
        result: DiscoveryBulkResult,
        mode: ExploreMode,
        language: String?,
        topic: String?,
        platform: String?,
        sort: ExploreSortOption,
        requestID: UUID
    ) async {
        clearPreparedSnapshots()
        await applyFiltersLocally(
            sourceRepos: result.repos,
            mode: mode,
            language: language,
            topic: topic,
            platform: platform,
            sort: sort,
            bumpRevision: true,
            requestID: requestID
        )
        guard !shouldStop(requestID: requestID) else { return }
        bulkAllRepos = result.repos
        latestSummary = result.summary
        lastRefreshedAt = Date()
    }

    private func applyFiltersLocally(
        sourceRepos: [DiscoveryRepoDTO],
        mode: ExploreMode,
        language: String?,
        topic: String?,
        platform: String?,
        sort: ExploreSortOption,
        bumpRevision: Bool,
        requestID: UUID
    ) async {
        // Task.detached 只接收 Sendable 值快照；筛选与排序期间不读取任何 Observable 状态。
        localDerivationCountForTesting &+= 1
        let interested = Set(self.interestedLanguages.map { $0.lowercased() })
        let task = Task.detached(priority: .userInitiated) {
            Self.deriveLocalRepos(
                sourceRepos: sourceRepos,
                mode: mode,
                language: language,
                topic: topic,
                platform: platform,
                sort: sort,
                interestedLanguages: interested
            )
        }
        let filtered = await PerformanceTracer.shared.trace(.discoveryLocalFilter, task: task)
        guard !shouldStop(requestID: requestID) else { return }

        let identity = Self.queryIdentity(
            mode: mode,
            language: language,
            topic: topic,
            platform: platform,
            sort: sort,
            interestedLanguages: Set(self.interestedLanguages.map { $0.lowercased() })
        )
        let prepared = PreparedSnapshot(filteredRepos: filtered)
        storePreparedSnapshot(prepared, for: identity)
        publishPreparedSnapshot(prepared, bumpRevision: bumpRevision)
    }

    /// MainActor 只提交已准备好的首屏值；缓存命中和后台派生共用同一发布边界。
    private func publishPreparedSnapshot(_ snapshot: PreparedSnapshot, bumpRevision: Bool) {
        filteredLocalRepos = snapshot.filteredRepos
        total = snapshot.filteredRepos.count
        page = 1
        repos = Array(snapshot.filteredRepos.prefix(Self.pageSize))
        nextPage = snapshot.filteredRepos.count > repos.count ? 2 : nil
        if bumpRevision {
            reposRevision += 1
        }
    }

    private func preparedSnapshot(for identity: String) -> PreparedSnapshot? {
        guard let snapshot = preparedSnapshots[identity] else { return nil }
        preparedSnapshotLRU.removeAll { $0 == identity }
        preparedSnapshotLRU.append(identity)
        return snapshot
    }

    private func storePreparedSnapshot(_ snapshot: PreparedSnapshot, for identity: String) {
        preparedSnapshots[identity] = snapshot
        preparedSnapshotLRU.removeAll { $0 == identity }
        preparedSnapshotLRU.append(identity)
        while preparedSnapshotLRU.count > Self.preparedSnapshotCapacity {
            let evicted = preparedSnapshotLRU.removeFirst()
            preparedSnapshots.removeValue(forKey: evicted)
        }
    }

    /// bulk 事实源替换后，旧派生结果不能继续参与查询。
    private func clearPreparedSnapshots() {
        preparedSnapshots.removeAll(keepingCapacity: true)
        preparedSnapshotLRU.removeAll(keepingCapacity: true)
    }

    /// 在后台线程完成 Discovery bulk 的模式筛选与排序。
    private nonisolated static func deriveLocalRepos(
        sourceRepos: [DiscoveryRepoDTO],
        mode: ExploreMode,
        language: String?,
        topic: String?,
        platform: String?,
        sort: ExploreSortOption,
        interestedLanguages: Set<String>
    ) -> [DiscoveryRepoDTO] {
        var filtered = sourceRepos

        switch mode {
        case .discover:
            if let topic = normalizedFilter(topic) {
                filtered = filtered.filter { $0.topics.contains(topic) }
            }
            if let platform = normalizedFilter(platform) {
                filtered = filtered.filter { $0.platforms.contains(platform) }
            }
        case .popular, .newReleases:
            filtered = filtered.filter { $0.categories.contains(categoryCode(for: mode)) }
            if let language = normalizedFilter(language) {
                filtered = filtered.filter { repo in
                    if language == TrendingLanguage.uncategorizedKey {
                        return (repo.language ?? "").isEmpty
                    }
                    if language == TrendingLanguage.otherRawValue {
                        // 「其他」= 语言非空且不在「感兴趣语言」里。
                        guard let lang = repo.language, !lang.isEmpty else { return false }
                        return !interestedLanguages.contains(lang.lowercased())
                    }
                    return repo.language?.caseInsensitiveCompare(language) == .orderedSame
                }
            }
        case .trending, .weekly, .awesome:
            break
        }

        filtered.sort(by: makeLocalSorter(sort.normalized(for: mode), mode: mode))
        return filtered
    }

    private nonisolated static func makeLocalSorter(
        _ sort: ExploreSortOption,
        mode: ExploreMode
    ) -> (DiscoveryRepoDTO, DiscoveryRepoDTO) -> Bool {
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

    private nonisolated static func scoreSorter(
        _ keyPath: KeyPath<DiscoveryRepoDTO, Double?>
    ) -> (DiscoveryRepoDTO, DiscoveryRepoDTO) -> Bool {
        { lhs, rhs in
            let lhsScore = lhs[keyPath: keyPath] ?? lhs.score ?? 0
            let rhsScore = rhs[keyPath: keyPath] ?? rhs.score ?? 0
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            if lhs.stars != rhs.stars { return lhs.stars > rhs.stars }
            return lhs.repoID > rhs.repoID
        }
    }

    private nonisolated static func categoryRankSorter(
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

    private nonisolated static func dateStringSorter(
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

    private nonisolated static func tieBreak(
        _ lhs: DiscoveryRepoDTO,
        _ rhs: DiscoveryRepoDTO,
        mode: ExploreMode
    ) -> Bool {
        let lhsScore = defaultScore(lhs, mode: mode)
        let rhsScore = defaultScore(rhs, mode: mode)
        if lhsScore != rhsScore { return lhsScore > rhsScore }
        return lhs.repoID > rhs.repoID
    }

    private nonisolated static func defaultScore(
        _ repo: DiscoveryRepoDTO,
        mode: ExploreMode
    ) -> Double {
        switch mode {
        case .discover:
            return repo.discoveryScore ?? repo.score ?? 0
        case .popular:
            return repo.popularityScore ?? repo.score ?? 0
        case .newReleases:
            return repo.releaseScore ?? repo.score ?? 0
        case .trending, .weekly, .awesome:
            // 趋势 / 周刊 / Awesome 不应进入 ExploreDiscoveryViewModel；这里保留兜底只为
            // 防止未来误传导致排序崩溃，正式 UI 分别由各自列表承载。
            return repo.trendingScore ?? repo.score ?? 0
        }
    }

    private func isCacheFresh(at lastFetchedAt: Date) -> Bool {
        Date().timeIntervalSince(lastFetchedAt) < Self.bulkTTL
    }

    /// 冷却期只约束自动 SWR。手动刷新不会调用此方法，因此用户始终可以主动重试。
    private func skipAutomaticRefreshDuringCooldown() -> Bool {
        guard let automaticRefreshBlockedUntil else { return false }
        guard Date() < automaticRefreshBlockedUntil else {
            self.automaticRefreshBlockedUntil = nil
            return false
        }
        cacheWarning = Self.cacheFallbackWarning(nil)
        return true
    }

    private func recordAutomaticRefreshFailure() {
        automaticRefreshBlockedUntil = Date().addingTimeInterval(Self.automaticRefreshFailureCooldown)
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
        // 底层 TLS / 网络细节只进日志；横条用固定用户文案。
        if let errorDescription, !errorDescription.isEmpty {
            AppLog.network.warning("Explore cache fallback detail: \(errorDescription, privacy: .public)")
        }
        return String.l10n("explore.cacheFallback.warning")
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
        case .trending, .weekly, .awesome:
            return false
        }
    }

    private nonisolated static func categoryCode(for mode: ExploreMode) -> String {
        switch mode {
        case .discover:
            return "discover"
        case .trending, .weekly, .awesome:
            return ""
        case .popular:
            return "popular"
        case .newReleases:
            return "new_releases"
        }
    }

    private nonisolated static func normalizedFilter(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
