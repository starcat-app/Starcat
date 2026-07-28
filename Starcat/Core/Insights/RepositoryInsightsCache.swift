//
//  RepositoryInsightsCache.swift
//  Starcat
//
//  仓库洞察的类型化 SQLite 缓存。缓存层管理 payload、TTL、损坏隔离与有界解码热缓存，
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
        case .commitActivity, .contributors:
            return 24 * 60 * 60
        case .communityProfile:
            return 3 * 24 * 60 * 60
        case .securityAdvisories:
            return 6 * 60 * 60
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

    /// 远端返回 304 时只续期已有 payload，避免重复编码和写入相同的大块 JSON。
    func touch(
        repoId: Int64,
        dataset: RepositoryInsightsDataset,
        range: RepositoryInsightsRangeKey,
        fetchedAt: Date,
        responseETag: String?
    ) async throws

    func remove(
        repoId: Int64,
        dataset: RepositoryInsightsDataset,
        range: RepositoryInsightsRangeKey
    ) async throws
}

struct GRDBRepositoryInsightsCache: RepositoryInsightsCaching, Sendable {
    private let database: any DatabaseManaging
    private let hotCache: RepositoryInsightsHotCache

    init(database: any DatabaseManaging, hotCacheCapacity: Int = 48) {
        self.database = database
        self.hotCache = RepositoryInsightsHotCache(capacity: hotCacheCapacity)
    }

    func load<Value: Decodable & Sendable>(
        repoId: Int64,
        dataset: RepositoryInsightsDataset,
        range: RepositoryInsightsRangeKey,
        as type: Value.Type
    ) async throws -> RepositoryInsightsCachedValue<Value>? {
        let hotKey = makeHotKey(
            repoId: repoId,
            dataset: dataset,
            range: range,
            type: type
        )
        if let cached = await hotCache.value(for: hotKey, as: type) {
            return cached
        }

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
            let cached = RepositoryInsightsCachedValue(
                value: value,
                fetchedAt: fetchedAt,
                staleAfter: staleAfter,
                responseETag: record.responseETag,
                defaultBranchSHA: record.defaultBranchSHA
            )
            await hotCache.insert(cached, for: hotKey)
            return cached
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
        let staleAfter = fetchedAt.addingTimeInterval(dataset.timeToLive)
        let record = RepositoryInsightsSnapshotRecord(
            repoId: repoId,
            dataset: dataset.rawValue,
            rangeKey: range.rawValue,
            payloadJSON: try JSONEncoder().encode(value),
            defaultBranchSHA: defaultBranchSHA,
            fetchedAt: ISO8601DateFormatter.shared.string(from: fetchedAt),
            staleAfter: ISO8601DateFormatter.shared.string(from: staleAfter),
            responseETag: responseETag
        )
        try await database.writer.write { db in
            try record.save(db)
        }
        await hotCache.insert(
            RepositoryInsightsCachedValue(
                value: value,
                fetchedAt: fetchedAt,
                staleAfter: staleAfter,
                responseETag: responseETag,
                defaultBranchSHA: defaultBranchSHA
            ),
            for: makeHotKey(
                repoId: repoId,
                dataset: dataset,
                range: range,
                type: Value.self
            )
        )
    }

    func touch(
        repoId: Int64,
        dataset: RepositoryInsightsDataset,
        range: RepositoryInsightsRangeKey,
        fetchedAt: Date,
        responseETag: String?
    ) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE repo_insights_snapshots
                    SET fetched_at = ?,
                        stale_after = ?,
                        response_etag = COALESCE(?, response_etag)
                    WHERE repo_id = ? AND dataset = ? AND range_key = ?
                    """,
                arguments: [
                    ISO8601DateFormatter.shared.string(from: fetchedAt),
                    ISO8601DateFormatter.shared.string(
                        from: fetchedAt.addingTimeInterval(dataset.timeToLive)
                    ),
                    responseETag,
                    repoId,
                    dataset.rawValue,
                    range.rawValue
                ]
            )
        }
        await hotCache.touch(
            databaseScope: databaseScope,
            repoId: repoId,
            dataset: dataset,
            range: range,
            fetchedAt: fetchedAt,
            staleAfter: fetchedAt.addingTimeInterval(dataset.timeToLive),
            responseETag: responseETag
        )
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
        await hotCache.remove(
            databaseScope: databaseScope,
            repoId: repoId,
            dataset: dataset,
            range: range
        )
    }

    /// writer 实例随 DatabaseManager.reopen 一起切换。把它和 userId 同时纳入 Key，
    /// 即使测试内同一账号被重新打开为空库，也不会读到上一个数据库实例的解码对象。
    private var databaseScope: RepositoryInsightsDatabaseScope {
        RepositoryInsightsDatabaseScope(
            writerIdentity: ObjectIdentifier(database.writer as AnyObject),
            userID: database.currentUserId
        )
    }

    private func makeHotKey<Value>(
        repoId: Int64,
        dataset: RepositoryInsightsDataset,
        range: RepositoryInsightsRangeKey,
        type: Value.Type
    ) -> RepositoryInsightsHotCacheKey {
        RepositoryInsightsHotCacheKey(
            databaseScope: databaseScope,
            repoId: repoId,
            dataset: dataset,
            range: range,
            valueType: String(reflecting: type)
        )
    }
}

private struct RepositoryInsightsDatabaseScope: Hashable, Sendable {
    let writerIdentity: ObjectIdentifier
    let userID: Int64?
}

private struct RepositoryInsightsHotCacheKey: Hashable, Sendable {
    let databaseScope: RepositoryInsightsDatabaseScope
    let repoId: Int64
    let dataset: RepositoryInsightsDataset
    let range: RepositoryInsightsRangeKey
    let valueType: String
}

private struct RepositoryInsightsHotCacheEntry: @unchecked Sendable {
    let value: Any
    var fetchedAt: Date
    var staleAfter: Date
    var responseETag: String?
    let defaultBranchSHA: String?
}

/// 只保存最近访问的少量已解码快照。容量按“数据集行”计算，不按仓库计算；
/// 48 条约等于最近 8 个仓库的六类远端区块，避免页面往返反复 SQLite + JSON decode。
private actor RepositoryInsightsHotCache {
    private let capacity: Int
    private var entries: [RepositoryInsightsHotCacheKey: RepositoryInsightsHotCacheEntry] = [:]
    private var recency: [RepositoryInsightsHotCacheKey] = []

    init(capacity: Int) {
        self.capacity = max(0, capacity)
    }

    func value<Value: Sendable>(
        for key: RepositoryInsightsHotCacheKey,
        as type: Value.Type
    ) -> RepositoryInsightsCachedValue<Value>? {
        guard let entry = entries[key], let value = entry.value as? Value else {
            removeKey(key)
            return nil
        }
        markRecentlyUsed(key)
        return RepositoryInsightsCachedValue(
            value: value,
            fetchedAt: entry.fetchedAt,
            staleAfter: entry.staleAfter,
            responseETag: entry.responseETag,
            defaultBranchSHA: entry.defaultBranchSHA
        )
    }

    func insert<Value: Sendable>(
        _ cached: RepositoryInsightsCachedValue<Value>,
        for key: RepositoryInsightsHotCacheKey
    ) {
        guard capacity > 0 else { return }
        entries[key] = RepositoryInsightsHotCacheEntry(
            value: cached.value,
            fetchedAt: cached.fetchedAt,
            staleAfter: cached.staleAfter,
            responseETag: cached.responseETag,
            defaultBranchSHA: cached.defaultBranchSHA
        )
        markRecentlyUsed(key)
        while entries.count > capacity, let oldest = recency.first {
            removeKey(oldest)
        }
    }

    func touch(
        databaseScope: RepositoryInsightsDatabaseScope,
        repoId: Int64,
        dataset: RepositoryInsightsDataset,
        range: RepositoryInsightsRangeKey,
        fetchedAt: Date,
        staleAfter: Date,
        responseETag: String?
    ) {
        let matchingKeys = entries.keys.filter {
            $0.databaseScope == databaseScope
                && $0.repoId == repoId
                && $0.dataset == dataset
                && $0.range == range
        }
        for key in matchingKeys {
            guard var entry = entries[key] else { continue }
            entry.fetchedAt = fetchedAt
            entry.staleAfter = staleAfter
            entry.responseETag = responseETag ?? entry.responseETag
            entries[key] = entry
            markRecentlyUsed(key)
        }
    }

    func remove(
        databaseScope: RepositoryInsightsDatabaseScope,
        repoId: Int64,
        dataset: RepositoryInsightsDataset,
        range: RepositoryInsightsRangeKey
    ) {
        let matchingKeys = entries.keys.filter {
            $0.databaseScope == databaseScope
                && $0.repoId == repoId
                && $0.dataset == dataset
                && $0.range == range
        }
        for key in matchingKeys {
            removeKey(key)
        }
    }

    private func markRecentlyUsed(_ key: RepositoryInsightsHotCacheKey) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private func removeKey(_ key: RepositoryInsightsHotCacheKey) {
        entries[key] = nil
        recency.removeAll { $0 == key }
    }
}
