//
//  RepoStarHistoryRepository.swift
//  Starcat
//
//  GitHub 官方仓库星标历史的本地持久化边界。
//
//  关键约束：
//  - GitHub 官方周数据是唯一事实源；Repo metadata 不再额外生成本机历史点。
//  - 原始周缓存用于 ETag/SWR，标准化日级点只是可重建的查询缓存。
//  - observed_on 使用 UTC 日期，避免 GitHub 周边界在本地时区发生漂移。
//

import Foundation
import GRDB

enum StarHistorySource: String, Codable, CaseIterable, Sendable {
    case ghArchive = "gh_archive"
    case discoverySnapshot = "discovery_snapshot"
    case githubStargazers = "github_stargazers"
    case githubHistory = "github_history"
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
        source: StarHistorySource = .githubHistory,
        precision: StarHistoryPrecision = .reconstructed,
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

    func replaceOfficialPoints(
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
    case invalidRemotePoint
    case invalidGitHubPagination
    case invalidGitHubHistoryWeek
    case corruptRecord

    var errorDescription: String? {
        switch self {
        case .invalidRemotePoint:
            return "official replacement accepts only non-negative GitHub history points"
        case .invalidGitHubPagination:
            return "GitHub Star History pagination did not advance"
        case .invalidGitHubHistoryWeek:
            return "GitHub Star History response contains an invalid week"
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

/// 服务端覆盖信息与曲线分开保存：没有新 Star 的日期仍然可能已经完成采集。
/// generatedAt 同时作为缓存配对身份，禁止把新水位贴到另一批旧曲线上。
struct StarHistoryCoverage: Codable, Equatable, Sendable {
    let start: Date?
    let lastEvent: Date?
    let dataThrough: Date?
    let generatedAt: Date
}

/// 官方响应的持久化事实源。曲线点只是读模型；版本升级后可以从这些周数据无损重建。
struct GitHubStarHistoryCachePayload: Codable, Equatable, Sendable {
    let weeks: [GitHubStarHistoryWeekDTO]
    /// 每日轻量刷新只更新最新页；每 7 天重新全量分页，兜底 GitHub 对旧周的修订。
    let fullHistoryValidatedAt: Date
}

struct StarHistorySnapshot: Equatable, Sendable {
    let range: StarHistoryRange
    let points: [StarHistoryPoint]
    let remoteState: StarHistoryRemoteState
    let coverageStart: Date?
    let updatedAt: Date?
    let statistics: StarHistoryStatistics
    let coverage: StarHistoryCoverage?

    init(
        range: StarHistoryRange,
        points: [StarHistoryPoint],
        remoteState: StarHistoryRemoteState,
        coverageStart: Date?,
        updatedAt: Date?,
        statistics: StarHistoryStatistics = .empty,
        coverage: StarHistoryCoverage? = nil
    ) {
        self.range = range
        self.points = points
        self.remoteState = remoteState
        self.coverageStart = coverageStart
        self.updatedAt = updatedAt
        self.statistics = statistics
        self.coverage = coverage
    }
}

actor GRDBRepoStarHistoryRepository: RepoStarHistoryRepositoryProtocol {
    private static let fullHistoryValidationInterval: TimeInterval = 7 * 24 * 60 * 60
    private static let maximumHistoryPages = 100

    private let database: any DatabaseManaging
    private let insightsCache: GRDBRepositoryInsightsCache
    private let projectRepository: (any UserProjectRepositoryProtocol)?
    private let oauthHistoryAPI: (any GitHubStarHistoryAPIProtocol)?
    private let githubAppHistoryAPI: (any GitHubStarHistoryAPIProtocol)?
    private let now: @Sendable () -> Date
    /// 所有显示范围共享同一份完整周缓存，因此并发去重必须按 repo，而不是按 range。
    private var refreshTasks: [Int64: Task<StarHistorySnapshot, Error>] = [:]

    init(
        database: any DatabaseManaging,
        projectRepository: (any UserProjectRepositoryProtocol)? = nil,
        oauthHistoryAPI: (any GitHubStarHistoryAPIProtocol)? = nil,
        githubAppHistoryAPI: (any GitHubStarHistoryAPIProtocol)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.database = database
        self.insightsCache = GRDBRepositoryInsightsCache(database: database)
        self.projectRepository = projectRepository
        self.oauthHistoryAPI = oauthHistoryAPI
        self.githubAppHistoryAPI = githubAppHistoryAPI
        self.now = now
    }

    func points(repoId: Int64) async throws -> [StarHistoryPoint] {
        try await database.writer.read { db in
            try RepoStarHistoryPointRecord
                .filter(Column("repo_id") == repoId)
                .filter(Column("source") == StarHistorySource.githubHistory.rawValue)
                .order(Column("observed_on"), Column("source"))
                .fetchAll(db)
                .map(Self.point(from:))
        }
    }

    func cached(
        repo: Repo,
        range: StarHistoryRange
    ) async throws -> StarHistorySnapshot {
        // 当前总数为零时产品不展示历史；连派生点和覆盖缓存也不读，旧缓存保留到未来重新获 Star。
        guard repo.starsCount > 0 else { return Self.zeroStarSnapshot(range: range) }
        let cachedPoints = try await points(repoId: repo.id)
        return await snapshot(
            repo: repo,
            range: range,
            rawPoints: cachedPoints,
            remoteState: repo.isPrivate && cachedPoints.isEmpty ? .privateOnly : .cached
        )
    }

    func replaceOfficialPoints(
        repoId: Int64,
        points: [StarHistoryPoint]
    ) async throws {
        guard points.allSatisfy({
            $0.source == .githubHistory && $0.count >= 0 && $0.fetchedAt != nil
        }) else {
            throw RepoStarHistoryRepositoryError.invalidRemotePoint
        }

        try await database.writer.write { db in
            // 单源模式下同一仓库只允许存在一批官方派生点，完整替换可杜绝旧来源残留。
            try db.execute(
                sql: "DELETE FROM repo_star_history_points WHERE repo_id = ?",
                arguments: [repoId]
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
        // 放在 single-flight 之前，确保零 Star 调用既不创建请求，也不等待同仓旧任务后误显历史。
        guard repo.starsCount > 0 else { return Self.zeroStarSnapshot(range: range) }
        if let task = refreshTasks[repo.id] {
            let shared = try await task.value
            guard shared.range != range else { return shared }
            // 网络与落库共享，但范围筛选属于每个调用方自己的读模型。
            return await snapshot(
                repo: repo,
                range: range,
                rawPoints: try await points(repoId: repo.id),
                remoteState: shared.remoteState
            )
        }

        // 不把 forceRefresh 放进 key：手动刷新与自动补齐同时发生时都以当前远端结果为准，
        // 再发第二个请求不会增加信息，只会放大 GitHub API 压力。
        let task = Task {
            try await self.performRefresh(
                repo: repo,
                range: range,
                forceRefresh: forceRefresh
            )
        }
        refreshTasks[repo.id] = task
        defer {
            refreshTasks[repo.id] = nil
        }
        return try await task.value
    }

    private func performRefresh(
        repo: Repo,
        range: StarHistoryRange,
        forceRefresh: Bool
    ) async throws -> StarHistorySnapshot {
        let cachedPoints = try await points(repoId: repo.id)
        let project = try await projectRepository?.fetchProject(repoID: repo.id)
        // 私仓必须先有“我的项目”关系，避免把不可见仓库名发给公共 OAuth 路径。
        guard !repo.isPrivate || project != nil else {
            return await snapshot(repo: repo, range: range, rawPoints: cachedPoints, remoteState: .privateOnly)
        }
        guard repo.id > 0, repo.cachedAt != nil else {
            return await snapshot(repo: repo, range: range, rawPoints: cachedPoints, remoteState: .unavailable)
        }
        let cachedHistory = try await insightsCache.load(
            repoId: repo.id,
            dataset: .starHistoryWeeks,
            range: .all,
            as: GitHubStarHistoryCachePayload.self
        )
        if !forceRefresh, let cachedHistory, !cachedHistory.isStale(at: now()) {
            let readyPoints = try await ensureOfficialPoints(
                repo: repo,
                payload: cachedHistory.value,
                fetchedAt: cachedHistory.fetchedAt,
                existingPoints: cachedPoints
            )
            return await snapshot(repo: repo, range: range, rawPoints: readyPoints, remoteState: .cached)
        }

        let candidates = historyAPICandidates(for: project, repo: repo)
        guard !candidates.isEmpty else {
            let state: StarHistoryRemoteState = repo.isPrivate ? .privateOnly : .unavailable
            return await snapshot(repo: repo, range: range, rawPoints: cachedPoints, remoteState: state)
        }

        var lastError: Error?
        for (index, api) in candidates.enumerated() {
            do {
                let fetchedAt = now()
                let needsFullHistory = forceRefresh
                    || cachedHistory == nil
                    || fetchedAt.timeIntervalSince(
                        cachedHistory?.value.fullHistoryValidatedAt ?? .distantPast
                    ) >= Self.fullHistoryValidationInterval

                if !needsFullHistory, let cachedHistory {
                    do {
                        let latest = try await api.starHistory(
                            owner: repo.owner,
                            repo: repo.name,
                            page: 1,
                            perPage: 30,
                            ifNoneMatch: cachedHistory.responseETag
                        )
                        let mergedWeeks = try Self.mergeLatestWeeks(
                            latest.value,
                            into: cachedHistory.value.weeks
                        )
                        let payload = GitHubStarHistoryCachePayload(
                            weeks: mergedWeeks,
                            fullHistoryValidatedAt: cachedHistory.value.fullHistoryValidatedAt
                        )
                        let refreshedPoints = try await persistOfficialHistory(
                            repo: repo,
                            payload: payload,
                            fetchedAt: fetchedAt,
                            etag: latest.etag
                        )
                        return await snapshot(
                            repo: repo, range: range, rawPoints: refreshedPoints, remoteState: .fresh
                        )
                    } catch NetworkError.notModified(let etag) {
                        try await insightsCache.touch(
                            repoId: repo.id,
                            dataset: .starHistoryWeeks,
                            range: .all,
                            fetchedAt: fetchedAt,
                            responseETag: etag
                        )
                        return await snapshot(
                            repo: repo, range: range, rawPoints: cachedPoints, remoteState: .notModified
                        )
                    }
                }

                let fetched = try await fetchCompleteOfficialHistory(repo: repo, api: api)
                let payload = GitHubStarHistoryCachePayload(
                    weeks: fetched.weeks,
                    fullHistoryValidatedAt: fetchedAt
                )
                let refreshedPoints = try await persistOfficialHistory(
                    repo: repo,
                    payload: payload,
                    fetchedAt: fetchedAt,
                    etag: fetched.firstPageETag
                )
                return await snapshot(
                    repo: repo, range: range, rawPoints: refreshedPoints, remoteState: .fresh
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if index + 1 < candidates.count, Self.shouldTryNextHistoryCredential(error) {
                    continue
                }
                break
            }
        }

        if repo.isPrivate,
           !cachedPoints.contains(where: { $0.source == .githubHistory }) {
            return await snapshot(repo: repo, range: range, rawPoints: cachedPoints, remoteState: .privateOnly)
        }
        return await snapshot(
            repo: repo,
            range: range,
            rawPoints: cachedPoints,
            remoteState: .stale(Self.historyError(from: lastError))
        )
    }

    /// GitHub App 项目优先使用 installation token；公开仓失败后才回退主 OAuth。
    private func historyAPICandidates(
        for project: UserProject?,
        repo: Repo
    ) -> [any GitHubStarHistoryAPIProtocol] {
        guard let project else {
            return [oauthHistoryAPI].compactMap { $0 }
        }
        switch project.authorizationSource {
        case .oauth:
            return [oauthHistoryAPI].compactMap { $0 }
        case .githubApp:
            var candidates: [any GitHubStarHistoryAPIProtocol] = []
            if let githubAppHistoryAPI {
                candidates.append(githubAppHistoryAPI)
            }
            if !repo.isPrivate, let oauthHistoryAPI {
                candidates.append(oauthHistoryAPI)
            }
            return candidates
        }
    }

    /// App → OAuth 仅对「换凭据可能成功」的失败开放，避免把契约错误打两遍。
    private static func shouldTryNextHistoryCredential(_ error: Error) -> Bool {
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

    /// GitHub 官方端点分页必须串行：页码与 Link 都属于同一响应快照，不能并发猜页。
    private func fetchCompleteOfficialHistory(
        repo: Repo,
        api: any GitHubStarHistoryAPIProtocol
    ) async throws -> (weeks: [GitHubStarHistoryWeekDTO], firstPageETag: String?) {
        var page = 1
        var visitedPages: Set<Int> = []
        var weeks: [GitHubStarHistoryWeekDTO] = []
        var firstPageETag: String?

        while visitedPages.insert(page).inserted {
            try Task.checkCancellation()
            let response = try await api.starHistory(
                owner: repo.owner,
                repo: repo.name,
                page: page,
                perPage: 30,
                ifNoneMatch: nil
            )
            try Self.validateHistoryWeeks(response.value)
            if page == 1 {
                firstPageETag = response.etag
            }
            weeks.append(contentsOf: response.value)

            guard let nextPage = response.linkHeader.nextPage else { break }
            guard nextPage > page, nextPage <= Self.maximumHistoryPages else {
                throw RepoStarHistoryRepositoryError.invalidGitHubPagination
            }
            page = nextPage
        }
        return (try Self.canonicalWeeks(weeks), firstPageETag)
    }

    private func persistOfficialHistory(
        repo: Repo,
        payload: GitHubStarHistoryCachePayload,
        fetchedAt: Date,
        etag: String?
    ) async throws -> [StarHistoryPoint] {
        let officialPoints = try Self.officialPoints(
            weeks: payload.weeks,
            currentStars: repo.starsCount,
            fetchedAt: fetchedAt
        )
        try await insightsCache.store(
            payload,
            repoId: repo.id,
            dataset: .starHistoryWeeks,
            range: .all,
            fetchedAt: fetchedAt,
            responseETag: etag,
            defaultBranchSHA: nil
        )
        try await replaceOfficialPoints(repoId: repo.id, points: officialPoints)
        try await storeCoverage(repoID: repo.id, weeks: payload.weeks, fetchedAt: fetchedAt)
        return try await points(repoId: repo.id)
    }

    /// 原始周缓存存在但派生点被清理/损坏时只做本地重建，不额外请求 GitHub，也不续期 TTL。
    private func ensureOfficialPoints(
        repo: Repo,
        payload: GitHubStarHistoryCachePayload,
        fetchedAt: Date,
        existingPoints: [StarHistoryPoint]
    ) async throws -> [StarHistoryPoint] {
        if existingPoints.contains(where: { $0.source == .githubHistory }) {
            return existingPoints
        }
        let rebuilt = try Self.officialPoints(
            weeks: payload.weeks,
            currentStars: repo.starsCount,
            fetchedAt: fetchedAt
        )
        try await replaceOfficialPoints(repoId: repo.id, points: rebuilt)
        try await storeCoverage(repoID: repo.id, weeks: payload.weeks, fetchedAt: fetchedAt)
        return try await points(repoId: repo.id)
    }

    private func storeCoverage(
        repoID: Int64,
        weeks: [GitHubStarHistoryWeekDTO],
        fetchedAt: Date
    ) async throws {
        let coverage = Self.coverage(weeks: weeks, fetchedAt: fetchedAt, now: now())
        try await insightsCache.store(
            coverage,
            repoId: repoID,
            dataset: .starHistoryCoverage,
            range: .all,
            fetchedAt: fetchedAt,
            responseETag: nil,
            defaultBranchSHA: nil
        )
    }

    private static func validateHistoryWeeks(_ weeks: [GitHubStarHistoryWeekDTO]) throws {
        for week in weeks {
            guard week.week >= 0,
                  week.total >= 0,
                  week.days.count == 7,
                  week.days.allSatisfy({ $0 >= 0 }),
                  week.days.reduce(0, +) == week.total
            else {
                throw RepoStarHistoryRepositoryError.invalidGitHubHistoryWeek
            }
        }
    }

    private static func canonicalWeeks(
        _ weeks: [GitHubStarHistoryWeekDTO]
    ) throws -> [GitHubStarHistoryWeekDTO] {
        try validateHistoryWeeks(weeks)
        // 页边界可能因新周插入而漂移，持久化合并只认 week 时间戳，不认 page 号。
        return Dictionary(weeks.map { ($0.week, $0) }, uniquingKeysWith: { _, newer in newer })
            .values
            .sorted { $0.week < $1.week }
    }

    private static func mergeLatestWeeks(
        _ latest: [GitHubStarHistoryWeekDTO],
        into cached: [GitHubStarHistoryWeekDTO]
    ) throws -> [GitHubStarHistoryWeekDTO] {
        let latest = try canonicalWeeks(latest)
        guard let oldestLatestWeek = latest.first?.week else {
            return try canonicalWeeks(cached)
        }
        let stablePrefix = cached.filter { $0.week < oldestLatestWeek }
        return try canonicalWeeks(stablePrefix + latest)
    }

    private static func officialPoints(
        weeks: [GitHubStarHistoryWeekDTO],
        currentStars: Int,
        fetchedAt: Date
    ) throws -> [StarHistoryPoint] {
        let canonical = try canonicalWeeks(weeks)
        var events: [StarHistoryCurveBuilder.DailyEvent] = []
        events.reserveCapacity(canonical.count * 7)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        for week in canonical {
            let weekStart = Date(timeIntervalSince1970: TimeInterval(week.week))
            for (offset, count) in week.days.enumerated() where count > 0 {
                guard let date = calendar.date(byAdding: .day, value: offset, to: weekStart) else {
                    throw RepoStarHistoryRepositoryError.invalidGitHubHistoryWeek
                }
                events.append(.init(date: date, count: count))
            }
        }
        return try StarHistoryCurveBuilder.normalize(
            events: events,
            currentStars: currentStars,
            fetchedAt: fetchedAt,
            source: .githubHistory,
            precision: .reconstructed
        )
    }

    private static func coverage(
        weeks: [GitHubStarHistoryWeekDTO],
        fetchedAt: Date,
        now: Date
    ) -> StarHistoryCoverage {
        let canonical = (try? canonicalWeeks(weeks)) ?? []
        let start = canonical.first.map { Date(timeIntervalSince1970: TimeInterval($0.week)) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let lastEvent = canonical.reversed().lazy.compactMap { week -> Date? in
            guard let offset = week.days.lastIndex(where: { $0 > 0 }) else { return nil }
            return calendar.date(
                byAdding: .day,
                value: offset,
                to: Date(timeIntervalSince1970: TimeInterval(week.week))
            )
        }.first
        let lastCoveredDay = canonical.last.flatMap {
            calendar.date(
                byAdding: .day,
                value: 6,
                to: Date(timeIntervalSince1970: TimeInterval($0.week))
            )
        }
        return StarHistoryCoverage(
            start: start,
            lastEvent: lastEvent,
            dataThrough: lastCoveredDay.map { min($0, now) },
            generatedAt: fetchedAt
        )
    }

    private static func historyError(from error: Error?) -> StarHistoryAPIError {
        guard let error else { return .providerUnavailable }
        guard let networkError = error as? NetworkError else {
            return .transport(error.localizedDescription)
        }
        switch networkError {
        case .unauthorized:
            return .unauthorized
        case .notFound:
            return .repositoryNotFound
        case .rateLimited(let retryAfter):
            return .rateLimited(retryAfter: retryAfter)
        case .serverError:
            return .providerUnavailable
        case .cancelled:
            return .transport(CancellationError().localizedDescription)
        case .invalidURL, .invalidResponse, .notModified, .clientError,
             .decodingError, .transport:
            return .transport(networkError.localizedDescription)
        }
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

    private func snapshot(
        repo: Repo,
        range: StarHistoryRange,
        rawPoints: [StarHistoryPoint],
        remoteState: StarHistoryRemoteState
    ) async -> StarHistorySnapshot {
        let cachedCoverage = try? await insightsCache.load(
            repoId: repo.id, dataset: .starHistoryCoverage, range: .all,
            as: StarHistoryCoverage.self
        )
        // 旧缓存没有覆盖信息时仍可画曲线；只是不声称最后事件日就是采集水位。
        let coverage = cachedCoverage?.value
        let matchingCoverage = coverage.flatMap { value in
            rawPoints.contains { $0.source == .githubHistory && $0.fetchedAt == value.generatedAt }
                ? value : nil
        }
        let officialPoints = rawPoints
            .filter { $0.source == .githubHistory }
            .sorted { $0.date < $1.date }
        let filtered = StarHistoryCurveBuilder.selectRange(officialPoints, range: range, now: now())
        return StarHistorySnapshot(
            range: range,
            points: filtered,
            remoteState: remoteState,
            coverageStart: matchingCoverage?.start ?? officialPoints.first?.date,
            updatedAt: officialPoints.compactMap(\.fetchedAt).max(),
            statistics: StarHistoryStatisticsBuilder.build(
                points: officialPoints,
                repositoryCreatedAt: repo.createdAt.flatMap(ISO8601DateFormatter.githubDate(from:))
            ),
            coverage: matchingCoverage
        )
    }

    /// 零 Star 只返回进程内空读模型，不删除官方缓存；仓库重新获 Star 后仍可按 TTL 复用。
    private static func zeroStarSnapshot(range: StarHistoryRange) -> StarHistorySnapshot {
        StarHistorySnapshot(
            range: range,
            points: [],
            remoteState: .unavailable,
            coverageStart: nil,
            updatedAt: nil,
            statistics: .empty,
            coverage: nil
        )
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
