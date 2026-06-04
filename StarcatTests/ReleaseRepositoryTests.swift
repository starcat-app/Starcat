//
//  ReleaseRepositoryTests.swift
//  StarcatTests
//
//  HOM-47：GRDBReleaseRepository 单测。
//
//  覆盖：
//  - upsertMany（首次插入 + 重复 upsert 保留 is_read）
//  - latest / fetch（按 published_at 倒序）
//  - fetchTimeline（仅取 is_subscribed=1 的 repo，按发布时间 desc）
//  - markRead / markAllRead / markAllRead(forRepo:)
//  - unreadCount（只计活跃订阅 + 未读）
//

import Testing
import Foundation
import GRDB
@testable import Starcat

@Suite("GRDBReleaseRepository")
struct ReleaseRepositoryTests {

    private func makeRepos() throws -> (
        GRDBReleaseRepository,
        GRDBReleaseSubscriptionRepository,
        any DatabaseManaging
    ) {
        let db = try InMemoryDatabaseManager()
        return (
            GRDBReleaseRepository(database: db),
            GRDBReleaseSubscriptionRepository(database: db),
            db
        )
    }

    private func makeRecord(
        id: Int64,
        repoId: Int64,
        tag: String,
        publishedAt: String? = "2026-06-01T00:00:00Z",
        isRead: Bool = false
    ) -> ReleaseRecord {
        ReleaseRecord(
            id: id,
            repoId: repoId,
            tagName: tag,
            name: "Release \(tag)",
            bodyTruncated: nil,
            htmlUrl: "https://github.com/x/y/releases/tag/\(tag)",
            isPrerelease: false,
            isDraft: false,
            publishedAt: publishedAt,
            createdAtRemote: publishedAt,
            assetsJson: nil,
            isRead: isRead,
            fetchedAt: "2026-06-04T00:00:00Z"
        )
    }

    // MARK: - upsertMany

    @Test("upsertMany: 首次插入 + 二次 upsert 保留 is_read=true")
    func upsertManyPreservesIsRead() async throws {
        let (repo, _, db) = try makeRepos()
        try await db.insertRepoFixture(id: 10)

        let r1 = makeRecord(id: 100, repoId: 10, tag: "v1.0")
        try await repo.upsertMany([r1], isReadDefault: false)
        try await repo.markRead(releaseId: 100, isRead: true)

        // 二次 upsert 同 id：body / fetched_at 应被刷新，is_read 必须保留
        var r1Updated = r1
        r1Updated.bodyTruncated = "new body"
        r1Updated.fetchedAt = "2026-06-05T00:00:00Z"
        try await repo.upsertMany([r1Updated], isReadDefault: false)

        let latest = try #require(try await repo.latest(forRepo: 10))
        #expect(latest.bodyTruncated == "new body")
        #expect(latest.fetchedAt == "2026-06-05T00:00:00Z")
        #expect(latest.isRead == true) // 关键：upsert 不能踩平用户的已读状态
    }

    // MARK: - latest / fetch

    @Test("latest: 按 published_at desc 取第一条")
    func latestOrderByPublished() async throws {
        let (repo, _, db) = try makeRepos()
        try await db.insertRepoFixture(id: 10)

        try await repo.upsertMany([
            makeRecord(id: 1, repoId: 10, tag: "v1.0", publishedAt: "2026-05-01T00:00:00Z"),
            makeRecord(id: 2, repoId: 10, tag: "v2.0", publishedAt: "2026-06-01T00:00:00Z"),
            makeRecord(id: 3, repoId: 10, tag: "v1.5", publishedAt: "2026-05-15T00:00:00Z"),
        ], isReadDefault: false)

        let latest = try #require(try await repo.latest(forRepo: 10))
        #expect(latest.tagName == "v2.0")
    }

    @Test("fetch: 按 published_at desc + 限制条数")
    func fetchOrderAndLimit() async throws {
        let (repo, _, db) = try makeRepos()
        try await db.insertRepoFixture(id: 10)
        try await repo.upsertMany([
            makeRecord(id: 1, repoId: 10, tag: "v1.0", publishedAt: "2026-05-01T00:00:00Z"),
            makeRecord(id: 2, repoId: 10, tag: "v2.0", publishedAt: "2026-06-01T00:00:00Z"),
            makeRecord(id: 3, repoId: 10, tag: "v1.5", publishedAt: "2026-05-15T00:00:00Z"),
        ], isReadDefault: false)

        let got = try await repo.fetch(forRepo: 10, limit: 2)
        #expect(got.map(\.tagName) == ["v2.0", "v1.5"])
    }

    // MARK: - fetchTimeline

    @Test("fetchTimeline: 只列出 is_subscribed=1 的 repo，按发布时间 desc")
    func fetchTimelineOnlyActive() async throws {
        let (repo, sub, db) = try makeRepos()
        try await db.insertRepoFixture(id: 10)
        try await db.insertRepoFixture(id: 20)

        // repo 10 订阅，repo 20 取消订阅
        try await sub.subscribe(repoId: 10, primingReleaseId: nil, primingTagName: nil)
        try await sub.subscribe(repoId: 20, primingReleaseId: nil, primingTagName: nil)
        try await sub.unsubscribe(repoId: 20)

        try await repo.upsertMany([
            makeRecord(id: 1, repoId: 10, tag: "v1.0", publishedAt: "2026-05-01T00:00:00Z"),
            makeRecord(id: 2, repoId: 10, tag: "v2.0", publishedAt: "2026-06-01T00:00:00Z"),
            makeRecord(id: 3, repoId: 20, tag: "vX",   publishedAt: "2026-06-15T00:00:00Z"),
        ], isReadDefault: false)

        let timeline = try await repo.fetchTimeline(limit: 50)
        #expect(timeline.count == 2)
        #expect(timeline.map(\.release.tagName) == ["v2.0", "v1.0"])
        #expect(timeline.allSatisfy { $0.repo.id == 10 })
    }

    // MARK: - markRead / markAllRead

    @Test("markRead: 单条切换；markAllRead(forRepo:): 全部置已读")
    func markReadOperations() async throws {
        let (repo, _, db) = try makeRepos()
        try await db.insertRepoFixture(id: 10)
        try await repo.upsertMany([
            makeRecord(id: 1, repoId: 10, tag: "v1"),
            makeRecord(id: 2, repoId: 10, tag: "v2"),
        ], isReadDefault: false)

        try await repo.markRead(releaseId: 1, isRead: true)
        let one = try #require(try await repo.fetch(forRepo: 10, limit: 50).first { $0.id == 1 })
        #expect(one.isRead == true)

        try await repo.markAllRead(forRepo: 10)
        let all = try await repo.fetch(forRepo: 10, limit: 50)
        #expect(all.allSatisfy { $0.isRead == true })
    }

    // MARK: - unreadCount

    @Test("unreadCount: 仅活跃订阅 × 未读")
    func unreadCountOnlyActive() async throws {
        let (repo, sub, db) = try makeRepos()
        try await db.insertRepoFixture(id: 10)
        try await db.insertRepoFixture(id: 20)
        try await sub.subscribe(repoId: 10, primingReleaseId: nil, primingTagName: nil)
        try await sub.subscribe(repoId: 20, primingReleaseId: nil, primingTagName: nil)
        try await sub.unsubscribe(repoId: 20)

        // upsertMany 将 isReadDefault 应用到所有插入行；ReleaseRecord.isRead 字段在
        // upsert 路径里仅作为 in-memory 视图（避免 DTO → record 转换时丢字段），
        // 已读状态通过显式 markRead 设置。
        try await repo.upsertMany([
            makeRecord(id: 1, repoId: 10, tag: "v1"),
            makeRecord(id: 2, repoId: 10, tag: "v2"),
            makeRecord(id: 3, repoId: 20, tag: "vX"), // 不计：repo 已取消订阅
        ], isReadDefault: false)
        try await repo.markRead(releaseId: 2, isRead: true)

        let count = try await repo.unreadCount()
        #expect(count == 1) // 仅 id=1（repo 10 + 未读）
    }
}
