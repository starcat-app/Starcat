//
//  RepositoryInsightsCacheTests.swift
//  StarcatTests
//
//  验证仓库洞察缓存的 TTL、覆盖写、stale 返回和损坏 payload 隔离。
//

import Foundation
import GRDB
import Testing
@testable import Starcat

@Suite("Repository insights cache")
struct RepositoryInsightsCacheTests {

    private struct Payload: Codable, Equatable, Sendable {
        let count: Int
    }

    @Test("活动与长期数据集使用固定 TTL 且 stale 仍可读取")
    func datasetTTLAndStaleRead() async throws {
        let database = try InMemoryDatabaseManager()
        let cache = GRDBRepositoryInsightsCache(database: database)
        try await database.insertRepoFixture(id: 1, owner: "octo", name: "cache")
        let fetchedAt = Date(timeIntervalSince1970: 1_000)

        try await cache.store(
            Payload(count: 3),
            repoId: 1,
            dataset: .activityCounts,
            range: .month,
            fetchedAt: fetchedAt,
            responseETag: "etag-1",
            defaultBranchSHA: "sha-1"
        )
        let activity = try #require(
            try await cache.load(
                repoId: 1,
                dataset: .activityCounts,
                range: .month,
                as: Payload.self
            )
        )
        #expect(activity.value == Payload(count: 3))
        #expect(activity.staleAfter.timeIntervalSince(activity.fetchedAt) == 15 * 60)
        #expect(activity.isStale(at: fetchedAt.addingTimeInterval(15 * 60)))
        #expect(activity.responseETag == "etag-1")
        #expect(activity.defaultBranchSHA == "sha-1")

        try await cache.store(
            Payload(count: 8),
            repoId: 1,
            dataset: .contributors,
            range: .all,
            fetchedAt: fetchedAt,
            responseETag: nil,
            defaultBranchSHA: nil
        )
        let contributors = try #require(
            try await cache.load(
                repoId: 1,
                dataset: .contributors,
                range: .all,
                as: Payload.self
            )
        )
        #expect(contributors.staleAfter.timeIntervalSince(contributors.fetchedAt) == 24 * 60 * 60)
    }

    @Test("相同主键覆盖写且不同 range 互不影响")
    func upsertIsScopedByDatasetAndRange() async throws {
        let database = try InMemoryDatabaseManager()
        let cache = GRDBRepositoryInsightsCache(database: database)
        try await database.insertRepoFixture(id: 2, owner: "octo", name: "ranges")
        let now = Date(timeIntervalSince1970: 2_000)

        try await cache.store(
            Payload(count: 1),
            repoId: 2,
            dataset: .activityCounts,
            range: .week,
            fetchedAt: now,
            responseETag: nil,
            defaultBranchSHA: nil
        )
        try await cache.store(
            Payload(count: 2),
            repoId: 2,
            dataset: .activityCounts,
            range: .month,
            fetchedAt: now,
            responseETag: nil,
            defaultBranchSHA: nil
        )
        try await cache.store(
            Payload(count: 9),
            repoId: 2,
            dataset: .activityCounts,
            range: .week,
            fetchedAt: now,
            responseETag: "new",
            defaultBranchSHA: nil
        )

        let week = try #require(
            try await cache.load(
                repoId: 2,
                dataset: .activityCounts,
                range: .week,
                as: Payload.self
            )
        )
        let month = try #require(
            try await cache.load(
                repoId: 2,
                dataset: .activityCounts,
                range: .month,
                as: Payload.self
            )
        )
        #expect(week.value.count == 9)
        #expect(week.responseETag == "new")
        #expect(month.value.count == 2)
    }

    @Test("损坏 payload 只删除对应数据集")
    func corruptPayloadIsIsolated() async throws {
        let database = try InMemoryDatabaseManager()
        let cache = GRDBRepositoryInsightsCache(database: database)
        try await database.insertRepoFixture(id: 3, owner: "octo", name: "corrupt")
        let now = ISO8601DateFormatter.shared.string(from: Date(timeIntervalSince1970: 3_000))

        try await database.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO repo_insights_snapshots (
                        repo_id, dataset, range_key, payload_json, fetched_at, stale_after
                    ) VALUES
                        (3, 'activityCounts', 'week', ?, ?, ?),
                        (3, 'contributors', 'all', ?, ?, ?)
                    """,
                arguments: [
                    Data("not-json".utf8), now, now,
                    try JSONEncoder().encode(Payload(count: 5)), now, now
                ]
            )
        }

        let corrupt = try await cache.load(
            repoId: 3,
            dataset: .activityCounts,
            range: .week,
            as: Payload.self
        )
        let valid = try #require(
            try await cache.load(
                repoId: 3,
                dataset: .contributors,
                range: .all,
                as: Payload.self
            )
        )
        #expect(corrupt == nil)
        #expect(valid.value.count == 5)

        let remaining = try await database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM repo_insights_snapshots")
        }
        #expect(remaining == 1)
    }
}
