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
    let statistics: StarHistoryStatistics

    init(
        range: StarHistoryRange,
        points: [StarHistoryPoint],
        remoteState: StarHistoryRemoteState,
        coverageStart: Date?,
        updatedAt: Date?,
        statistics: StarHistoryStatistics = .empty
    ) {
        self.range = range
        self.points = points
        self.remoteState = remoteState
        self.coverageStart = coverageStart
        self.updatedAt = updatedAt
        self.statistics = statistics
    }
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
            repo: repo,
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
            guard project.canReadStargazers else {
                let state: StarHistoryRemoteState = repo.isPrivate ? .privateOnly : .unavailable
                return snapshot(repo: repo, range: range, rawPoints: cachedPoints, remoteState: state)
            }
            let candidates = stargazersAPICandidates(for: project, repo: repo)
            guard !candidates.isEmpty else {
                let state: StarHistoryRemoteState = repo.isPrivate ? .privateOnly : .unavailable
                return snapshot(repo: repo, range: range, rawPoints: cachedPoints, remoteState: state)
            }

            if !forceRefresh, loadedGitHubStargazerRepoIDs.contains(repo.id) {
                return snapshot(repo: repo, range: range, rawPoints: cachedPoints, remoteState: .cached)
            }

            var lastError: Error?
            for (index, api) in candidates.enumerated() {
                do {
                    let githubPoints = try await fetchGitHubStargazerPoints(
                        repo: repo,
                        api: api
                    )
                    try await replaceRemotePoints(repoId: repo.id, points: githubPoints)
                    loadedGitHubStargazerRepoIDs.insert(repo.id)
                    let refreshedPoints = try await points(repoId: repo.id)
                    return snapshot(repo: repo, range: range, rawPoints: refreshedPoints, remoteState: .fresh)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                    let hasNext = index + 1 < candidates.count
                    // 仅鉴权类失败才换下一张凭据；解码/契约错误换 token 也不会更好。
                    if hasNext, Self.shouldTryNextStargazersCredential(error) {
                        continue
                    }
                    break
                }
            }

            // 项目路径失败后绝不降级 Discovery：私仓防外泄，公开仓避免与 Stargazers 口径混用。
            if repo.isPrivate,
               !cachedPoints.contains(where: { $0.source == .githubStargazers }) {
                return snapshot(
                    repo: repo,
                    range: range,
                    rawPoints: cachedPoints,
                    remoteState: .privateOnly
                )
            }
            return snapshot(
                repo: repo,
                range: range,
                rawPoints: cachedPoints,
                remoteState: .stale(
                    .transport(lastError?.localizedDescription ?? "stargazers unavailable")
                )
            )
        }

        // 没有“我的项目”关系的私有仓库绝不调用公共 Discovery。
        guard !repo.isPrivate else {
            return snapshot(repo: repo, range: range, rawPoints: cachedPoints, remoteState: .privateOnly)
        }
        guard repo.id > 0, repo.cachedAt != nil, let api else {
            return snapshot(repo: repo, range: range, rawPoints: cachedPoints, remoteState: .unavailable)
        }
        // events 接口返回完整日级序列。每次进程生命周期首次打开该仓库都刷新一次，
        // 之后所有范围共享同一份 canonical cache，不再用旧范围点猜测“已经完整”。
        if !forceRefresh, fullyLoadedRepoIDs.contains(repo.id) {
            return snapshot(repo: repo, range: range, rawPoints: cachedPoints, remoteState: .cached)
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
                        repo: repo,
                        range: range,
                        rawPoints: cachedPoints,
                        remoteState: .stale(.repositoryIDMismatch)
                    )
                }
                try await replaceRemotePoints(repoId: repo.id, points: series.points)
                if let etag {
                    etags[cacheKey] = etag
                }
                fullyLoadedRepoIDs.insert(repo.id)
                let refreshedPoints = try await points(repoId: repo.id)
                return snapshot(repo: repo, range: range, rawPoints: refreshedPoints, remoteState: .fresh)

            case .notModified(let etag):
                if let etag {
                    etags[cacheKey] = etag
                }
                return snapshot(repo: repo, range: range, rawPoints: cachedPoints, remoteState: .notModified)

            case .building(let retryAfter):
                return snapshot(
                    repo: repo,
                    range: range,
                    rawPoints: cachedPoints,
                    remoteState: .building(retryAfter: retryAfter)
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as StarHistoryAPIError {
            // 远端错误不清空上次成功缓存；ViewModel 可以用 stale 状态显示非阻塞提示。
            return snapshot(repo: repo, range: range, rawPoints: cachedPoints, remoteState: .stale(error))
        } catch {
            return snapshot(
                repo: repo,
                range: range,
                rawPoints: cachedPoints,
                remoteState: .stale(.transport(error.localizedDescription))
            )
        }
    }

    /// 按项目授权来源排列 Stargazers 客户端；公开 GitHub App 项目附带 OAuth 兜底。
    ///
    /// 私仓绝不能回退 OAuth：`public_repo` 读不到 Private / Internal。公开仓在 App token
    /// 过期或 403 时回退主登录，避免「已连接 App 反而丢历史」的回归。
    private func stargazersAPICandidates(
        for project: UserProject,
        repo: Repo
    ) -> [any GitHubStargazersAPIProtocol] {
        switch project.authorizationSource {
        case .oauth:
            return [oauthStargazersAPI].compactMap { $0 }
        case .githubApp:
            var candidates: [any GitHubStargazersAPIProtocol] = []
            if let githubAppStargazersAPI {
                candidates.append(githubAppStargazersAPI)
            }
            if !repo.isPrivate, let oauthStargazersAPI {
                candidates.append(oauthStargazersAPI)
            }
            return candidates
        }
    }

    /// App → OAuth 仅对「换凭据可能成功」的失败开放，避免把契约错误打两遍。
    private static func shouldTryNextStargazersCredential(_ error: Error) -> Bool {
        guard let error = error as? NetworkError else { return false }
        switch error {
        case .unauthorized, .notFound, .rateLimited:
            return true
        case .clientError(let statusCode, _):
            return statusCode == 401 || statusCode == 403 || statusCode == 404
        case .transport, .serverError, .cancelled, .invalidURL, .invalidResponse,
             .notModified, .decodingError:
            return false
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
        repo: Repo,
        range: StarHistoryRange,
        rawPoints: [StarHistoryPoint],
        remoteState: StarHistoryRemoteState
    ) -> StarHistorySnapshot {
        let merged = Self.mergeByObservedDay(rawPoints)
        let stitched = StarHistoryCurveBuilder.stitchToPreciseSnapshots(merged)
        let filtered = StarHistoryCurveBuilder.selectRange(stitched, range: range, now: now())
        return StarHistorySnapshot(
            range: range,
            points: filtered,
            remoteState: remoteState,
            coverageStart: merged.first?.date,
            updatedAt: merged.compactMap(\.fetchedAt).max(),
            statistics: StarHistoryStatisticsBuilder.build(
                points: stitched,
                repositoryCreatedAt: repo.createdAt.flatMap(ISO8601DateFormatter.githubDate(from:))
            )
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
