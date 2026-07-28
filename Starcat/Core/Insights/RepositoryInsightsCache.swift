//
//  RepositoryInsightsCache.swift
//  Starcat
//
//  仓库洞察的类型化 SQLite 缓存。缓存层只管理 payload、TTL 与损坏隔离，
//  不发网络请求；stale 记录仍会返回，由上层实现 stale-while-refresh。
//

import Foundation
import GRDB

enum RepositoryInsightsDataset: String, CaseIterable, Sendable {
    case activityCounts
    case recentActivity
    case commitActivity
    case contributors
    case communityProfile
    case securityAdvisories

    /// TTL 是产品数据口径的一部分，不能由每个调用方自由决定。
    var timeToLive: TimeInterval {
        switch self {
        case .activityCounts, .recentActivity:
            return 15 * 60
        case .commitActivity, .contributors, .communityProfile, .securityAdvisories:
            return 24 * 60 * 60
        }
    }
}

enum RepositoryInsightsRangeKey: String, CaseIterable, Sendable {
    case week
    case month
    case quarter
    case year
    case all
}

struct RepositoryInsightsCachedValue<Value: Sendable>: Sendable {
    let value: Value
    let fetchedAt: Date
    let staleAfter: Date
    let responseETag: String?
    let defaultBranchSHA: String?

    func isStale(at date: Date) -> Bool {
        date >= staleAfter
    }
}

protocol RepositoryInsightsCaching: Sendable {
    func load<Value: Decodable & Sendable>(
        repoId: Int64,
        dataset: RepositoryInsightsDataset,
        range: RepositoryInsightsRangeKey,
        as type: Value.Type
    ) async throws -> RepositoryInsightsCachedValue<Value>?

    func store<Value: Encodable & Sendable>(
        _ value: Value,
        repoId: Int64,
        dataset: RepositoryInsightsDataset,
        range: RepositoryInsightsRangeKey,
        fetchedAt: Date,
        responseETag: String?,
        defaultBranchSHA: String?
    ) async throws

    func remove(
        repoId: Int64,
        dataset: RepositoryInsightsDataset,
        range: RepositoryInsightsRangeKey
    ) async throws
}

struct GRDBRepositoryInsightsCache: RepositoryInsightsCaching, Sendable {
    private let database: any DatabaseManaging

    init(database: any DatabaseManaging) {
        self.database = database
    }

    func load<Value: Decodable & Sendable>(
        repoId: Int64,
        dataset: RepositoryInsightsDataset,
        range: RepositoryInsightsRangeKey,
        as type: Value.Type
    ) async throws -> RepositoryInsightsCachedValue<Value>? {
        let record = try await database.writer.read { db in
            try RepositoryInsightsSnapshotRecord
                .filter(Column("repo_id") == repoId)
                .filter(Column("dataset") == dataset.rawValue)
                .filter(Column("range_key") == range.rawValue)
                .fetchOne(db)
        }
        guard let record else { return nil }

        do {
            let value = try JSONDecoder().decode(type, from: record.payloadJSON)
            guard
                let fetchedAt = ISO8601DateFormatter.shared.date(from: record.fetchedAt),
                let staleAfter = ISO8601DateFormatter.shared.date(from: record.staleAfter)
            else {
                try await deleteRecord(repoId: repoId, dataset: dataset, range: range)
                return nil
            }
            return RepositoryInsightsCachedValue(
                value: value,
                fetchedAt: fetchedAt,
                staleAfter: staleAfter,
                responseETag: record.responseETag,
                defaultBranchSHA: record.defaultBranchSHA
            )
        } catch {
            // payload schema 变化或局部损坏只淘汰这一行；其它数据集仍可离线展示。
            try await deleteRecord(repoId: repoId, dataset: dataset, range: range)
            return nil
        }
    }

    func store<Value: Encodable & Sendable>(
        _ value: Value,
        repoId: Int64,
        dataset: RepositoryInsightsDataset,
        range: RepositoryInsightsRangeKey,
        fetchedAt: Date,
        responseETag: String?,
        defaultBranchSHA: String?
    ) async throws {
        let record = RepositoryInsightsSnapshotRecord(
            repoId: repoId,
            dataset: dataset.rawValue,
            rangeKey: range.rawValue,
            payloadJSON: try JSONEncoder().encode(value),
            defaultBranchSHA: defaultBranchSHA,
            fetchedAt: ISO8601DateFormatter.shared.string(from: fetchedAt),
            staleAfter: ISO8601DateFormatter.shared.string(
                from: fetchedAt.addingTimeInterval(dataset.timeToLive)
            ),
            responseETag: responseETag
        )
        try await database.writer.write { db in
            try record.save(db)
        }
    }

    func remove(
        repoId: Int64,
        dataset: RepositoryInsightsDataset,
        range: RepositoryInsightsRangeKey
    ) async throws {
        try await deleteRecord(repoId: repoId, dataset: dataset, range: range)
    }

    private func deleteRecord(
        repoId: Int64,
        dataset: RepositoryInsightsDataset,
        range: RepositoryInsightsRangeKey
    ) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: """
                    DELETE FROM repo_insights_snapshots
                    WHERE repo_id = ? AND dataset = ? AND range_key = ?
                    """,
                arguments: [repoId, dataset.rawValue, range.rawValue]
            )
        }
    }
}
