//
//  TrendingListPipeline.swift
//  Starcat
//
//  Trending 列表的后台快照派生管线。
//
//  这个 actor 专门承担排序与评分等 CPU 工作，并按查询桶保存会话级内存快照。
//  ViewModel 只在 MainActor 发布已经准备好的值，避免分类切换期间阻塞窗口动画。
//

import Foundation

/// 唯一标识一个 Trending 数据桶。
///
/// 排序不属于远端查询条件，因此不进入 identity；同一桶切换排序只重新派生展示快照，
/// 不会重复读取 SQLite 或发起网络请求。
struct TrendingQueryIdentity: Hashable, Sendable {
    let period: TrendingPeriod
    let language: TrendingLanguage

    var logValue: String {
        "\(period.rawValue):\(language.rawValue.isEmpty ? "all" : language.rawValue)"
    }
}

/// Trending 全局筛选的不可变输入快照。
///
/// SwiftUI 只负责从各个 Observable store 复制当前值；真正逐 repo 匹配在后台 actor 内完成。
/// 对已关闭的筛选，调用方传空集合，避免无关 store 变化触发整榜重新派生。
struct TrendingListFilter: Hashable, Sendable {
    let star: RepoStarFilter
    let library: RepoLibraryFilter
    let hideArchived: Bool
    let hideForks: Bool
    let languages: Set<String>
    let wikiAvailability: RepoSignalAvailabilityFilter
    let healthAvailability: RepoSignalAvailabilityFilter
    let openSSFAvailability: RepoSignalAvailabilityFilter
    let starredRepoIDs: Set<Int64>
    let inLibraryRepoIDs: Set<Int64>
    let wikiKnownRepoIDs: Set<Int64>
    let wikiAvailableRepoIDs: Set<Int64>
    let healthAvailableRepoIDs: Set<Int64>
    let openSSFAvailableRepoIDs: Set<Int64>

    static let all = TrendingListFilter(
        star: .all,
        library: .all,
        hideArchived: false,
        hideForks: false,
        languages: [],
        wikiAvailability: .unknown,
        healthAvailability: .unknown,
        openSSFAvailability: .unknown,
        starredRepoIDs: [],
        inLibraryRepoIDs: [],
        wikiKnownRepoIDs: [],
        wikiAvailableRepoIDs: [],
        healthAvailableRepoIDs: [],
        openSSFAvailableRepoIDs: []
    )

    /// 查询快照缓存需要把所有影响列表成员关系的输入纳入 key。
    /// 使用枚举 rawValue，避免为了本地缓存把共享筛选枚举扩展成额外协议依赖。
    func hash(into hasher: inout Hasher) {
        hasher.combine(star.rawValue)
        hasher.combine(library.rawValue)
        hasher.combine(hideArchived)
        hasher.combine(hideForks)
        hasher.combine(languages)
        hasher.combine(wikiAvailability.rawValue)
        hasher.combine(healthAvailability.rawValue)
        hasher.combine(openSSFAvailability.rawValue)
        hasher.combine(starredRepoIDs)
        hasher.combine(inLibraryRepoIDs)
        hasher.combine(wikiKnownRepoIDs)
        hasher.combine(wikiAvailableRepoIDs)
        hasher.combine(healthAvailableRepoIDs)
        hasher.combine(openSSFAvailableRepoIDs)
    }

    func matches(_ repo: TrendingRepo) -> Bool {
        let repoID = repo.ghRepoId
        guard star.matches(isStarred: starredRepoIDs.contains(repoID)) else { return false }
        if hideArchived, repo.isArchived ?? false { return false }
        if hideForks, repo.isFork ?? false { return false }

        if !languages.isEmpty {
            guard let language = repo.language?.lowercased(), languages.contains(language) else {
                return false
            }
        }

        switch library {
        case .all:
            break
        case .inLibrary:
            guard inLibraryRepoIDs.contains(repoID) else { return false }
        case .outsideLibrary:
            guard !inLibraryRepoIDs.contains(repoID) else { return false }
        }

        if wikiAvailability != .unknown {
            // Wiki 的“缺失”只接受已探测为 false 的仓库，不能把尚未探测误判成缺失。
            guard wikiKnownRepoIDs.contains(repoID),
                  Self.matchesAvailability(
                    wikiAvailableRepoIDs.contains(repoID),
                    filter: wikiAvailability
                  )
            else { return false }
        }
        guard Self.matchesAvailability(
            healthAvailableRepoIDs.contains(repoID),
            filter: healthAvailability
        ) else { return false }
        guard Self.matchesAvailability(
            openSSFAvailableRepoIDs.contains(repoID),
            filter: openSSFAvailability
        ) else { return false }
        return true
    }

    private static func matchesAvailability(
        _ available: Bool,
        filter: RepoSignalAvailabilityFilter
    ) -> Bool {
        switch filter {
        case .unknown: return true
        case .available: return available
        case .missing: return !available
        }
    }
}

/// 会影响 Trending 展示快照的全部本地派生输入。
struct TrendingDerivationContext: Hashable, Sendable {
    let sort: TrendingSortOption
    let filter: TrendingListFilter
    let languagePreferences: [String: Double]

    func hash(into hasher: inout Hasher) {
        hasher.combine(sort.rawValue)
        hasher.combine(filter)
        hasher.combine(languagePreferences)
    }
}

/// 已完成后台派生、可以直接发布给 SwiftUI 的不可变快照。
struct TrendingPreparedSnapshot: Sendable {
    /// 已排序但尚未应用全局筛选的候选，用于异步补载 Wiki 等筛选信号。
    let allRepos: [TrendingRepo]
    let repos: [TrendingRepo]
    let identityIDs: [String]
    let scores: [String: TrendingScore]
    let recommendedRepos: [TrendingRepo]
}

/// 串行管理 Trending 会话快照并在 MainActor 之外执行列表派生。
///
/// 关键约束：这里只保存可重建的远端缓存数据；用户数据仍由各自 Repository 管理。
/// actor 隔离也保证快速切换多个分类时，不会并发读写同一个快照字典。
actor TrendingListPipeline {
    private static let preparedSnapshotCapacity = 12

    private var rawSnapshots: [TrendingQueryIdentity: [TrendingRepo]] = [:]
    /// 完整 context 命中后可直接返回，不再重复排序、过滤、评分与推荐计算。
    private var preparedSnapshots: [PreparedSnapshotKey: TrendingPreparedSnapshot] = [:]
    private var preparedSnapshotLRU: [PreparedSnapshotKey] = []
    /// 仅供定向测试确认 cache hit 没有重新进入昂贵派生；不参与 UI 观察。
    private var derivationCount = 0
    private let dateFormatter = ISO8601DateFormatter()

    private struct PreparedSnapshotKey: Hashable {
        let identity: TrendingQueryIdentity
        let context: TrendingDerivationContext
    }

    /// 返回内存中已有桶的派生快照；未访问过该桶时返回 nil。
    func preparedSnapshot(
        for identity: TrendingQueryIdentity,
        context: TrendingDerivationContext
    ) -> TrendingPreparedSnapshot? {
        let key = PreparedSnapshotKey(identity: identity, context: context)
        if let snapshot = preparedSnapshots[key] {
            touchPreparedSnapshot(key)
            return snapshot
        }
        guard let repos = rawSnapshots[identity] else { return nil }
        let snapshot = derive(repos: repos, context: context)
        storePreparedSnapshot(snapshot, for: key)
        return snapshot
    }

    /// 替换指定桶的原始数据，并用指定 context 生成快照。ViewModel 会在 await 后复核
    /// context；若用户期间继续切换筛选，则重新调用本方法，杜绝旧结果上屏。
    func prepare(
        repos: [TrendingRepo],
        for identity: TrendingQueryIdentity,
        context: TrendingDerivationContext
    ) -> TrendingPreparedSnapshot {
        rawSnapshots[identity] = repos
        // 同一个远端桶拿到新事实源后，旧 context 的派生结果必须整体失效。
        removePreparedSnapshots(for: identity)
        let snapshot = derive(repos: repos, context: context)
        storePreparedSnapshot(
            snapshot,
            for: PreparedSnapshotKey(identity: identity, context: context)
        )
        return snapshot
    }

    private func storePreparedSnapshot(
        _ snapshot: TrendingPreparedSnapshot,
        for key: PreparedSnapshotKey
    ) {
        preparedSnapshots[key] = snapshot
        touchPreparedSnapshot(key)
        while preparedSnapshotLRU.count > Self.preparedSnapshotCapacity {
            let evicted = preparedSnapshotLRU.removeFirst()
            preparedSnapshots.removeValue(forKey: evicted)
        }
    }

    private func touchPreparedSnapshot(_ key: PreparedSnapshotKey) {
        preparedSnapshotLRU.removeAll { $0 == key }
        preparedSnapshotLRU.append(key)
    }

    private func removePreparedSnapshots(for identity: TrendingQueryIdentity) {
        let staleKeys = preparedSnapshotLRU.filter { $0.identity == identity }
        staleKeys.forEach { preparedSnapshots.removeValue(forKey: $0) }
        preparedSnapshotLRU.removeAll { $0.identity == identity }
    }

    /// 在 actor 内完成全量排序、筛选、评分与推荐，避免 SwiftUI body 重复派生。
    private func derive(
        repos: [TrendingRepo],
        context: TrendingDerivationContext
    ) -> TrendingPreparedSnapshot {
        derivationCount &+= 1
        let sorted = sortedRepos(repos, by: context.sort)
        let filtered = sorted.filter(context.filter.matches)
        let scores = Dictionary(uniqueKeysWithValues: repos.map { repo in
            (repo.fullName, Self.calculateScore(for: repo))
        })
        return TrendingPreparedSnapshot(
            allRepos: sorted,
            repos: filtered,
            identityIDs: filtered.map(\.fullName),
            scores: scores,
            recommendedRepos: recommendedRepos(
                from: filtered,
                scores: scores,
                languagePreferences: context.languagePreferences
            )
        )
    }

    /// 推荐排序与主列表派生共用同一份评分缓存，避免在 MainActor 再做第二次全量排序。
    private func recommendedRepos(
        from repos: [TrendingRepo],
        scores: [String: TrendingScore],
        languagePreferences: [String: Double]
    ) -> [TrendingRepo] {
        let ranked = repos.sorted { lhs, rhs in
            let lhsPreference = languagePreferences[lhs.language ?? ""] ?? 0
            let rhsPreference = languagePreferences[rhs.language ?? ""] ?? 0
            if lhsPreference != rhsPreference {
                return lhsPreference > rhsPreference
            }
            return (scores[lhs.fullName]?.total ?? 0) > (scores[rhs.fullName]?.total ?? 0)
        }
        return Array(ranked.prefix(3))
    }

    private func sortedRepos(
        _ repos: [TrendingRepo],
        by sort: TrendingSortOption
    ) -> [TrendingRepo] {
        switch sort {
        case .recommended:
            return repos
        case .starsDesc:
            return repos.sorted { $0.starsCount > $1.starsCount }
        case .starsAsc:
            return repos.sorted { $0.starsCount < $1.starsCount }
        case .nameAsc:
            return repos.sorted {
                $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending
            }
        case .nameDesc:
            return repos.sorted {
                $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedDescending
            }
        case .updatedDesc:
            return repos.sorted { trendingDate($0.updatedAt) > trendingDate($1.updatedAt) }
        case .updatedAsc:
            return repos.sorted { trendingDate($0.updatedAt) < trendingDate($1.updatedAt) }
        case .createdDesc:
            return repos.sorted { trendingDate($0.createdAt) > trendingDate($1.createdAt) }
        case .createdAsc:
            return repos.sorted { trendingDate($0.createdAt) < trendingDate($1.createdAt) }
        case .risingTrend:
            return repos.sorted {
                if $0.starsInPeriod != $1.starsInPeriod {
                    return $0.starsInPeriod > $1.starsInPeriod
                }
                if $0.starsCount != $1.starsCount {
                    return $0.starsCount > $1.starsCount
                }
                return $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending
            }
        }
    }

    private func trendingDate(_ text: String?) -> Date {
        guard let text, let date = dateFormatter.date(from: text) else {
            return .distantPast
        }
        return date
    }

    /// 评分算法保持原有权重，仅改变执行线程与计算时机。
    private static func calculateScore(for repo: TrendingRepo) -> TrendingScore {
        let growthRate = repo.starsCount > 0
            ? Double(repo.starsInPeriod) / Double(repo.starsCount)
            : 0
        let forkRatio = repo.starsCount > 0
            ? Double(repo.forksCount) / Double(repo.starsCount)
            : 0
        let contributorBonus = min(Double(repo.contributors.count) * 2, 10)
        let total = min(growthRate * 1_000, 40)
            + min(forkRatio * 30, 30)
            + contributorBonus

        return TrendingScore(
            total: Int(total),
            growthRate: growthRate,
            activity: contributorBonus,
            quality: forkRatio
        )
    }

    func derivationCountForTesting() -> Int {
        derivationCount
    }
}
