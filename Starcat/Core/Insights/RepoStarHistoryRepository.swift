//
//  RepoStarHistoryRepository.swift
//  Starcat
//
//  仓库星标历史的本地持久化边界。
//
//  关键约束：
//  - local_snapshot 是 Starcat 从 GitHub metadata 顺带取得的精确值，不触发额外请求。
//  - 远端刷新只能替换 gh_archive / discovery_snapshot，绝不能删除 local_snapshot。
//  - observed_on 使用 UTC 日期，避免跨时区用户在同一自然日写出两个本机点。
//

import Foundation
import GRDB

enum StarHistorySource: String, Codable, CaseIterable, Sendable {
    case ghArchive = "gh_archive"
    case discoverySnapshot = "discovery_snapshot"
    case localSnapshot = "local_snapshot"

    var isRemote: Bool {
        self != .localSnapshot
    }
}

enum StarHistoryPrecision: String, Codable, CaseIterable, Sendable {
    case estimated
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
}

enum RepoStarHistoryRepositoryError: LocalizedError {
    case negativeStars
    case invalidRemotePoint
    case corruptRecord

    var errorDescription: String? {
        switch self {
        case .negativeStars:
            return "stars_count must not be negative"
        case .invalidRemotePoint:
            return "remote replacement accepts only non-negative remote points"
        case .corruptRecord:
            return "invalid repo star history record"
        }
    }
}

struct GRDBRepoStarHistoryRepository: RepoStarHistoryRepositoryProtocol, Sendable {
    private let database: any DatabaseManaging

    init(database: any DatabaseManaging) {
        self.database = database
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
                    WHERE repo_id = ? AND source IN (?, ?)
                    """,
                arguments: [
                    repoId,
                    StarHistorySource.ghArchive.rawValue,
                    StarHistorySource.discoverySnapshot.rawValue
                ]
            )
            for point in points {
                try Self.record(repoId: repoId, point: point).save(db)
            }
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
