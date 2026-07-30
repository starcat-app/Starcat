//
//  RepoStarHistoryRepository.swift
//  Starcat
//
//  仓库星标历史的本地持久化边界。
//
//  关键约束：
//  - local_snapshot 是 Starcat 从 GitHub metadata 顺带取得的精确值，不触发额外请求。
//  - 远端刷新只能替换远端来源，绝不能删除 local_snapshot。
//  - observed_on 使用 UTC 日期，避免跨时区用户在同一自然日写出两个本机点。
//

import Foundation
import GRDB

enum StarHistorySource: String, Codable, CaseIterable, Sendable {
    case ghArchive = "gh_archive"
    case discoverySnapshot = "discovery_snapshot"
    case githubStargazers = "github_stargazers"
    case localSnapshot = "local_snapshot"

    var isRemote: Bool {
        self != .localSnapshot
    }
}

enum StarHistoryPrecision: String, Codable, CaseIterable, Sendable {
    case estimated
    /// 由当前仍在 Star 的用户及其 starred_at 重建，不包含已取消 Star 的历史峰值。
    case reconstructed
    case snapshot
}

struct StarHistoryPoint: Codable, Equatable, Identifiable, Sendable {
    let date: Date
    let count: Int
    let source: StarHistorySource
    let precision: StarHistoryPrecision
    let fetchedAt: Date?

    init(
        date: Date,
        count: Int,
        source: StarHistorySource = .ghArchive,
        precision: StarHistoryPrecision = .estimated,
        fetchedAt: Date? = nil
    ) {
        self.date = date
        self.count = count
        self.source = source
        self.precision = precision
        self.fetchedAt = fetchedAt
    }

    var id: String {
        "\(StarHistoryDateCodec.dayString(from: date))|\(source.rawValue)"
    }
}

protocol RepoStarHistoryRepositoryProtocol: Sendable {
    func points(repoId: Int64) async throws -> [StarHistoryPoint]

    func cached(
        repo: Repo,
        range: StarHistoryRange
    ) async throws -> StarHistorySnapshot

    func recordLocalSnapshot(
        repoId: Int64,
        starsCount: Int,
        observedAt: Date,
        fetchedAt: Date
    ) async throws

    func replaceRemotePoints(
        repoId: Int64,
        points: [StarHistoryPoint]
    ) async throws

    func refresh(
        repo: Repo,
        range: StarHistoryRange,
        forceRefresh: Bool
    ) async throws -> StarHistorySnapshot
}

enum RepoStarHistoryRepositoryError: LocalizedError {
    case negativeStars
    case invalidRemotePoint
    case invalidGitHubPagination
    case invalidGitHubStargazerTimestamp
    case corruptRecord

    var errorDescription: String? {
        switch self {
        case .negativeStars:
            return "stars_count must not be negative"
        case .invalidRemotePoint:
            return "remote replacement accepts only non-negative remote points"
        case .invalidGitHubPagination:
            return "GitHub Stargazers pagination did not advance"
        case .invalidGitHubStargazerTimestamp:
            return "GitHub Stargazers response contains an invalid starred_at"
        case .corruptRecord:
            return "invalid repo star history record"
        }
    }
}

enum StarHistoryRemoteState: Equatable, Sendable {
    case cached
    case fresh
    case notModified
    case building(retryAfter: TimeInterval)
    case privateOnly
    case stale(StarHistoryAPIError)
    case unavailable
}

struct StarHistorySnapshot: Equatable, Sendable {
    let range: StarHistoryRange
    let points: [StarHistoryPoint]
    let remoteState: StarHistoryRemoteState
    let coverageStart: Date?
    let updatedAt: Date?
}

actor GRDBRepoStarHistoryRepository: RepoStarHistoryRepositoryProtocol {
    private struct RemoteCacheKey: Hashable {
        let repoID: Int64
        let range: StarHistoryRange
    }

    private let database: any DatabaseManaging
    private let api: (any StarHistoryAPIProtocol)?
    private let projectRepository: (any UserProjectRepositoryProtocol)?
    private let oauthStargazersAPI: (any GitHubStargazersAPIProtocol)?
    private let githubAppStargazersAPI: (any GitHubStargazersAPIProtocol)?
    private let now: @Sendable () -> Date
    private var etags: [RemoteCacheKey: String] = [:]
    private var fullyLoadedRepoIDs: Set<Int64> = []
    private var loadedGitHubStargazerRepoIDs: Set<Int64> = []
    /// AI 与洞察页可能同时请求同一范围。Task 独立于任一页面取消，完成后统一落库。
    private var refreshTasks: [RemoteCacheKey: Task<StarHistorySnapshot, Error>] = [:]

    init(
        database: any DatabaseManaging,
        api: (any StarHistoryAPIProtocol)? = nil,
        projectRepository: (any UserProjectRepositoryProtocol)? = nil,
        oauthStargazersAPI: (any GitHubStargazersAPIProtocol)? = nil,
        githubAppStargazersAPI: (any GitHubStargazersAPIProtocol)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.database = database
        self.api = api
        self.projectRepository = projectRepository
        self.oauthStargazersAPI = oauthStargazersAPI
        self.githubAppStargazersAPI = githubAppStargazersAPI
        self.now = now
    }

    func points(repoId: Int64) async throws -> [StarHistoryPoint] {
        try await database.writer.read { db in
            try RepoStarHistoryPointRecord
                .filter(Column("repo_id") == repoId)
                .order(Column("observed_on"), Column("source"))
                .fetchAll(db)
                .map(Self.point(from:))
        }
    }

    func cached(
        repo: Repo,
        range: StarHistoryRange
    ) async throws -> StarHistorySnapshot {
        try await recordCurrentMetadataSnapshotIfPossible(repo)
        let cachedPoints = try await points(repoId: repo.id)
        let hasGitHubHistory = cachedPoints.contains { $0.source == .githubStargazers }
        return snapshot(
            range: range,
            rawPoints: cachedPoints,
            remoteState: repo.isPrivate && !hasGitHubHistory ? .privateOnly : .cached
        )
    }

    func recordLocalSnapshot(
        repoId: Int64,
        starsCount: Int,
        observedAt: Date,
        fetchedAt: Date
    ) async throws {
        guard starsCount >= 0 else {
            throw RepoStarHistoryRepositoryError.negativeStars
        }
        try await database.writer.write { db in
            try Self.saveLocalSnapshot(
                repoId: repoId,
                starsCount: starsCount,
                observedAt: observedAt,
                fetchedAt: fetchedAt,
                db: db
            )
        }
    }

    func replaceRemotePoints(
        repoId: Int64,
        points: [StarHistoryPoint]
    ) async throws {
        guard points.allSatisfy({
            $0.source.isRemote && $0.count >= 0 && $0.fetchedAt != nil
        }) else {
            throw RepoStarHistoryRepositoryError.invalidRemotePoint
        }

        try await database.writer.write { db in
            // 明确列出远端来源，而不是“删除非 local”，避免未来新增本机来源时被误删。
            try db.execute(
                sql: """
                    DELETE FROM repo_star_history_points
                    WHERE repo_id = ? AND source IN (?, ?, ?)
                    """,
                arguments: [
                    repoId,
                    StarHistorySource.ghArchive.rawValue,
                    StarHistorySource.discoverySnapshot.rawValue,
                    StarHistorySource.githubStargazers.rawValue
                ]
            )
            for point in points {
                try Self.record(repoId: repoId, point: point).save(db)
            }
        }
    }

    func refresh(
        repo: Repo,
        range: StarHistoryRange,
        forceRefresh: Bool
    ) async throws -> StarHistorySnapshot {
        let key = RemoteCacheKey(repoID: repo.id, range: range)
        if let task = refreshTasks[key] {
            return try await task.value
        }

        // 不把 forceRefresh 放进 key：手动刷新与自动补齐同时发生时都以当前远端结果为准，
        // 再发第二个请求不会增加信息，只会放大 GitHub / Discovery 压力。
        let task = Task {
            try await self.performRefresh(
                repo: repo,
                range: range,
                forceRefresh: forceRefresh
            )
        }
        refreshTasks[key] = task
        defer {
            refreshTasks[key] = nil
        }
        return try await task.value
    }

    private func performRefresh(
        repo: Repo,
        range: StarHistoryRange,
        forceRefresh: Bool
    ) async throws -> StarHistorySnapshot {
        try await recordCurrentMetadataSnapshotIfPossible(repo)
        let cachedPoints = try await points(repoId: repo.id)

        if let project = try await projectRepository?.fetchProject(repoID: repo.id) {
            guard project.canReadStargazers,
                  let stargazersAPI = stargazersAPI(for: project)
            else {
                let state: StarHistoryRemoteState = repo.isPrivate ? .privateOnly : .unavailable
                return snapshot(range: range, rawPoints: cachedPoints, remoteState: state)
            }

            if !forceRefresh, loadedGitHubStargazerRepoIDs.contains(repo.id) {
                return snapshot(range: range, rawPoints: cachedPoints, remoteState: .cached)
            }

            do {
                let githubPoints = try await fetchGitHubStargazerPoints(
                    repo: repo,
                    api: stargazersAPI
                )
                try await replaceRemotePoints(repoId: repo.id, points: githubPoints)
                loadedGitHubStargazerRepoIDs.insert(repo.id)
                let refreshedPoints = try await points(repoId: repo.id)
                return snapshot(range: range, rawPoints: refreshedPoints, remoteState: .fresh)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 项目已经匹配到专属 GitHub 数据源后不再降级到公共 Discovery，
                // 防止私有项目外泄，也避免同一项目在两种统计口径间来回切换。
                if repo.isPrivate,
                   !cachedPoints.contains(where: { $0.source == .githubStargazers }) {
                    return snapshot(
                        range: range,
                        rawPoints: cachedPoints,
                        remoteState: .privateOnly
                    )
                }
                return snapshot(
                    range: range,
                    rawPoints: cachedPoints,
                    remoteState: .stale(.transport(error.localizedDescription))
                )
            }
        }

        // 没有“我的项目”关系的私有仓库绝不调用公共 Discovery。
        guard !repo.isPrivate else {
            return snapshot(range: range, rawPoints: cachedPoints, remoteState: .privateOnly)
        }
        guard repo.id > 0, repo.cachedAt != nil, let api else {
            return snapshot(range: range, rawPoints: cachedPoints, remoteState: .unavailable)
        }
        if !forceRefresh, hasCoverage(for: range, in: cachedPoints, repoID: repo.id) {
            return snapshot(range: range, rawPoints: cachedPoints, remoteState: .cached)
        }

        let cacheKey = RemoteCacheKey(repoID: repo.id, range: range)
        do {
            let result = try await api.fetch(
                request: StarHistoryRequest(repo: repo),
                range: range,
                ifNoneMatch: etags[cacheKey]
            )
            switch result {
            case .ready(let series, let etag):
                guard series.repoID == repo.id,
                      series.fullName.caseInsensitiveCompare(repo.fullName) == .orderedSame,
                      series.range == range
                else {
                    return snapshot(
                        range: range,
                        rawPoints: cachedPoints,
                        remoteState: .stale(.repositoryIDMismatch)
                    )
                }
                try await replaceRemotePoints(repoId: repo.id, points: series.points)
                if let etag {
                    etags[cacheKey] = etag
                }
                if range == .all {
                    fullyLoadedRepoIDs.insert(repo.id)
                }
                let refreshedPoints = try await points(repoId: repo.id)
                return snapshot(range: range, rawPoints: refreshedPoints, remoteState: .fresh)

            case .notModified(let etag):
                if let etag {
                    etags[cacheKey] = etag
                }
                return snapshot(range: range, rawPoints: cachedPoints, remoteState: .notModified)

            case .building(let retryAfter):
                return snapshot(
                    range: range,
                    rawPoints: cachedPoints,
                    remoteState: .building(retryAfter: retryAfter)
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as StarHistoryAPIError {
            // 远端错误不清空上次成功缓存；ViewModel 可以用 stale 状态显示非阻塞提示。
            return snapshot(range: range, rawPoints: cachedPoints, remoteState: .stale(error))
        } catch {
            return snapshot(
                range: range,
                rawPoints: cachedPoints,
                remoteState: .stale(.transport(error.localizedDescription))
            )
        }
    }

    private func stargazersAPI(
        for project: UserProject
    ) -> (any GitHubStargazersAPIProtocol)? {
        switch project.authorizationSource {
        case .oauth:
            return oauthStargazersAPI
        case .githubApp:
            return githubAppStargazersAPI
        }
    }

    /// 拉取全部当前 Stargazers，并仅在内存中按 UTC 日期聚合成累计曲线。
    ///
    /// GitHub 返回的是“当前仍在 Star 的用户”的 `starred_at`，因此结果是重建曲线，
    /// 无法恢复已取消 Star 的用户和历史峰值；Stargazer 身份不会进入持久化模型。
    private func fetchGitHubStargazerPoints(
        repo: Repo,
        api: any GitHubStargazersAPIProtocol
    ) async throws -> [StarHistoryPoint] {
        var page = 1
        var visitedPages: Set<Int> = []
        var starredDates: [Date] = []
        let fetchedAt = now()

        while visitedPages.insert(page).inserted {
            try Task.checkCancellation()
            let response = try await api.stargazers(
                owner: repo.owner,
                repo: repo.name,
                page: page,
                perPage: 100
            )
            for item in response.value {
                guard let starredAt = ISO8601DateFormatter.githubDate(from: item.starredAt) else {
                    throw RepoStarHistoryRepositoryError.invalidGitHubStargazerTimestamp
                }
                starredDates.append(starredAt)
            }

            guard let nextPage = response.linkHeader.nextPage else { break }
            guard nextPage > page else {
                throw RepoStarHistoryRepositoryError.invalidGitHubPagination
            }
            page = nextPage
        }

        let countsByDay = Dictionary(
            grouping: starredDates,
            by: StarHistoryDateCodec.dayString(from:)
        ).mapValues(\.count)
        var cumulativeCount = 0
        return try countsByDay.keys.sorted().map { day in
            guard let date = StarHistoryDateCodec.date(from: day) else {
                throw RepoStarHistoryRepositoryError.invalidGitHubStargazerTimestamp
            }
            cumulativeCount += countsByDay[day, default: 0]
            return StarHistoryPoint(
                date: date,
                count: cumulativeCount,
                source: .githubStargazers,
                precision: .reconstructed,
                fetchedAt: fetchedAt
            )
        }
    }

    /// Repo metadata 的落库事务直接复用此方法，保证 repo 与当天精确点原子提交。
    static func saveLocalSnapshot(
        repoId: Int64,
        starsCount: Int,
        observedAt: Date,
        fetchedAt: Date,
        db: Database
    ) throws {
        let record = RepoStarHistoryPointRecord(
            repoId: repoId,
            observedOn: StarHistoryDateCodec.dayString(from: observedAt),
            starsCount: starsCount,
            source: StarHistorySource.localSnapshot.rawValue,
            precision: StarHistoryPrecision.snapshot.rawValue,
            fetchedAt: ISO8601DateFormatter.shared.string(from: fetchedAt)
        )
        try record.save(db)
    }

    private static func record(
        repoId: Int64,
        point: StarHistoryPoint
    ) throws -> RepoStarHistoryPointRecord {
        guard let fetchedAt = point.fetchedAt else {
            throw RepoStarHistoryRepositoryError.invalidRemotePoint
        }
        return RepoStarHistoryPointRecord(
            repoId: repoId,
            observedOn: StarHistoryDateCodec.dayString(from: point.date),
            starsCount: point.count,
            source: point.source.rawValue,
            precision: point.precision.rawValue,
            fetchedAt: ISO8601DateFormatter.shared.string(from: fetchedAt)
        )
    }

    private static func point(from record: RepoStarHistoryPointRecord) throws -> StarHistoryPoint {
        guard
            let observedOn = StarHistoryDateCodec.date(from: record.observedOn),
            let fetchedAt = ISO8601DateFormatter.shared.date(from: record.fetchedAt),
            let source = StarHistorySource(rawValue: record.source),
            let precision = StarHistoryPrecision(rawValue: record.precision)
        else {
            throw RepoStarHistoryRepositoryError.corruptRecord
        }
        return StarHistoryPoint(
            date: observedOn,
            count: record.starsCount,
            source: source,
            precision: precision,
            fetchedAt: fetchedAt
        )
    }

    private func recordCurrentMetadataSnapshotIfPossible(_ repo: Repo) async throws {
        guard repo.id > 0, repo.cachedAt != nil, repo.starsCount >= 0 else { return }
        let observedAt = now()
        try await recordLocalSnapshot(
            repoId: repo.id,
            starsCount: repo.starsCount,
            observedAt: observedAt,
            fetchedAt: observedAt
        )
    }

    private func snapshot(
        range: StarHistoryRange,
        rawPoints: [StarHistoryPoint],
        remoteState: StarHistoryRemoteState
    ) -> StarHistorySnapshot {
        let merged = Self.mergeByObservedDay(rawPoints)
        let filtered = Self.points(merged, in: range, now: now())
        return StarHistorySnapshot(
            range: range,
            points: filtered,
            remoteState: remoteState,
            coverageStart: merged.first?.date,
            updatedAt: merged.compactMap(\.fetchedAt).max()
        )
    }

    /// 同一天只向上层暴露一个读数：本机快照 > GitHub 重建 > Discovery > GH Archive。
    ///
    /// 两个同优先级点则保留 fetchedAt 更新者，保证重复同步不会让旧值覆盖新值。
    private static func mergeByObservedDay(_ points: [StarHistoryPoint]) -> [StarHistoryPoint] {
        var bestByDay: [String: StarHistoryPoint] = [:]
        for point in points {
            let day = StarHistoryDateCodec.dayString(from: point.date)
            guard let existing = bestByDay[day] else {
                bestByDay[day] = point
                continue
            }
            let pointPriority = priority(of: point)
            let existingPriority = priority(of: existing)
            if pointPriority > existingPriority
                || (pointPriority == existingPriority
                    && (point.fetchedAt ?? .distantPast) > (existing.fetchedAt ?? .distantPast)) {
                bestByDay[day] = point
            }
        }
        return bestByDay.values.sorted { $0.date < $1.date }
    }

    private static func priority(of point: StarHistoryPoint) -> Int {
        switch point.source {
        case .localSnapshot: return 4
        case .githubStargazers: return 3
        case .discoverySnapshot: return 2
        case .ghArchive: return point.precision == .snapshot ? 2 : 1
        }
    }

    private static func points(
        _ points: [StarHistoryPoint],
        in range: StarHistoryRange,
        now: Date
    ) -> [StarHistoryPoint] {
        let cutoff: Date?
        switch range {
        case .threeMonths:
            cutoff = now.addingTimeInterval(-92 * 86_400)
        case .oneYear:
            cutoff = now.addingTimeInterval(-366 * 86_400)
        case .all:
            cutoff = nil
        }
        guard let cutoff else { return points }
        return points.filter { $0.date >= cutoff }
    }

    private func hasCoverage(
        for range: StarHistoryRange,
        in points: [StarHistoryPoint],
        repoID: Int64
    ) -> Bool {
        if range == .all {
            return fullyLoadedRepoIDs.contains(repoID)
        }
        let remoteDates = points.lazy.filter { $0.source.isRemote }.map(\.date)
        guard let earliest = remoteDates.min() else { return false }
        let requiredDays: TimeInterval = range == .threeMonths ? 92 : 366
        // 服务端 1y 使用 ISO 周降采样，允许首点相对范围边界晚一周。
        return earliest <= now().addingTimeInterval(-(requiredDays - 7) * 86_400)
    }
}

enum StarHistoryDateCodec {
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    static func dayString(from date: Date) -> String {
        let components = utcCalendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    static func date(from day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return utcCalendar.date(
            from: DateComponents(year: parts[0], month: parts[1], day: parts[2])
        )
    }
}
