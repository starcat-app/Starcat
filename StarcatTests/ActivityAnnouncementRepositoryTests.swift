//
//  ActivityAnnouncementRepositoryTests.swift
//  StarcatTests
//
//  Activity 公告与关注 PR-1（2026-06-16）：GRDBActivityAnnouncementRepository 单测。
//
//  覆盖：
//  - upsertMany（首次插入 + 二次 upsert 保留 is_read）
//  - fetchAll（按 created_at desc + limit 截断）
//  - fetch(source:) 按来源过滤
//  - markRead / markAllRead / unreadCount
//  - deleteOlderThan（30 天边界）
//  - AnnouncementSource.makeId 命名空间隔离 + AnnouncementCategoriesCodec 编解码
//

import Testing
import Foundation
import GRDB
@testable import Starcat

@Suite("GRDBActivityAnnouncementRepository")
struct ActivityAnnouncementRepositoryTests {

    private func makeRepo() throws -> (GRDBActivityAnnouncementRepository, any DatabaseManaging) {
        let db = try InMemoryDatabaseManager()
        return (GRDBActivityAnnouncementRepository(database: db), db)
    }

    private func makeRecord(
        nativeId: String,
        source: AnnouncementSource = .blog,
        title: String = "Sample Announcement",
        createdAt: String = "2026-06-15T00:00:00Z",
        isRead: Bool = false,
        categories: [String]? = nil,
        repoName: String? = nil
    ) -> ActivityAnnouncementRecord {
        ActivityAnnouncementRecord(
            id: source.makeId(nativeId: nativeId),
            source: source.rawValue,
            title: title,
            bodyMarkdown: "<p>body html</p>",
            author: "octocat",
            url: "https://github.blog/\(nativeId)",
            repoName: repoName,
            categories: AnnouncementCategoriesCodec.encode(categories),
            isRead: isRead,
            createdAt: createdAt,
            fetchedAt: "2026-06-16T00:00:00Z"
        )
    }

    // MARK: - id 命名空间

    @Test("AnnouncementSource.makeId: 不同 source 的相同 nativeId 不冲突")
    func sourcePrefixedIdNoCollision() async throws {
        let (repo, _) = try makeRepo()

        try await repo.upsertMany([
            makeRecord(nativeId: "42", source: .blog),
            makeRecord(nativeId: "42", source: .security, repoName: "octo/demo"),
        ])

        let all = try await repo.fetchAll(limit: 50)
        #expect(all.count == 2)
        #expect(Set(all.map(\.id)) == Set(["blog:42", "security:42"]))
    }

    // MARK: - upsertMany

    @Test("upsertMany: 首次插入 + 二次 upsert 保留 is_read=true")
    func upsertManyPreservesIsRead() async throws {
        let (repo, _) = try makeRepo()

        let r1 = makeRecord(nativeId: "1")
        try await repo.upsertMany([r1])
        try await repo.markRead(announcementId: r1.id, isRead: true)

        var r1Updated = r1
        r1Updated.title = "Updated title"
        r1Updated.bodyMarkdown = "<p>new body</p>"
        try await repo.upsertMany([r1Updated])

        let all = try await repo.fetchAll(limit: 50)
        #expect(all.count == 1)
        #expect(all[0].title == "Updated title")
        #expect(all[0].bodyMarkdown == "<p>new body</p>")
        #expect(all[0].isRead == true)  // 关键:保留用户已读状态
    }

    // MARK: - fetchAll / fetch(source:)

    @Test("fetchAll: 按 created_at desc + limit 截断")
    func fetchAllOrderAndLimit() async throws {
        let (repo, _) = try makeRepo()

        try await repo.upsertMany([
            makeRecord(nativeId: "old", createdAt: "2026-06-01T00:00:00Z"),
            makeRecord(nativeId: "new", createdAt: "2026-06-10T00:00:00Z"),
            makeRecord(nativeId: "mid", createdAt: "2026-06-05T00:00:00Z"),
        ])

        let got = try await repo.fetchAll(limit: 2)
        #expect(got.map(\.id) == ["blog:new", "blog:mid"])
    }

    @Test("fetch(source:): 仅返回指定来源的行")
    func fetchSourceFilter() async throws {
        let (repo, _) = try makeRepo()

        try await repo.upsertMany([
            makeRecord(nativeId: "b1", source: .blog,     createdAt: "2026-06-05T00:00:00Z"),
            makeRecord(nativeId: "b2", source: .blog,     createdAt: "2026-06-10T00:00:00Z"),
            makeRecord(nativeId: "s1", source: .security, createdAt: "2026-06-08T00:00:00Z", repoName: "octo/demo"),
        ])

        let blogOnly = try await repo.fetch(source: .blog, limit: 50)
        #expect(blogOnly.map(\.id) == ["blog:b2", "blog:b1"])

        let securityOnly = try await repo.fetch(source: .security, limit: 50)
        #expect(securityOnly.map(\.id) == ["security:s1"])
    }

    // MARK: - markRead / unreadCount

    @Test("markRead / markAllRead 与 unreadCount 配合")
    func markReadOperations() async throws {
        let (repo, _) = try makeRepo()

        try await repo.upsertMany([
            makeRecord(nativeId: "1"),
            makeRecord(nativeId: "2"),
            makeRecord(nativeId: "3", isRead: true),
        ])

        #expect(try await repo.unreadCount() == 2)

        try await repo.markRead(announcementId: "blog:1", isRead: true)
        #expect(try await repo.unreadCount() == 1)

        try await repo.markAllRead()
        #expect(try await repo.unreadCount() == 0)
    }

    // MARK: - deleteOlderThan

    @Test("deleteOlderThan(30): 边界与 ActivityEvent 同款")
    func deleteOlderThanBoundary() async throws {
        let (repo, _) = try makeRepo()

        let now = Date()
        let cal = Calendar(identifier: .gregorian)
        let iso = ISO8601DateFormatter.shared
        let veryOld = cal.date(byAdding: .day, value: -60, to: now)!
        let recent  = cal.date(byAdding: .day, value: -3,  to: now)!

        try await repo.upsertMany([
            makeRecord(nativeId: "old",    createdAt: iso.string(from: veryOld)),
            makeRecord(nativeId: "recent", createdAt: iso.string(from: recent)),
        ])

        let deleted = try await repo.deleteOlderThan(days: 30)
        #expect(deleted == 1)
        #expect(try await repo.fetchAll(limit: 50).map(\.id) == ["blog:recent"])
    }

    // MARK: - categories codec

    @Test("AnnouncementCategoriesCodec: encode / decode / nil round-trip")
    func categoriesCodecRoundTrip() async throws {
        let (repo, _) = try makeRepo()

        try await repo.upsertMany([
            makeRecord(nativeId: "with-cats", categories: ["AI & ML", "Security"]),
            makeRecord(nativeId: "empty-cats", categories: []),       // 空数组编码为 nil
            makeRecord(nativeId: "no-cats"),                            // nil 直接 nil
        ])

        let all = try await repo.fetchAll(limit: 50)

        let withCats = try #require(all.first { $0.id == "blog:with-cats" })
        let emptyCats = try #require(all.first { $0.id == "blog:empty-cats" })
        let noCats = try #require(all.first { $0.id == "blog:no-cats" })

        #expect(AnnouncementCategoriesCodec.decode(withCats.categories) == ["AI & ML", "Security"])
        #expect(emptyCats.categories == nil)       // 空数组转 nil 节省存储
        #expect(noCats.categories == nil)
        // decode nil / 失败串 → 空数组（容错）
        #expect(AnnouncementCategoriesCodec.decode(nil) == [])
        #expect(AnnouncementCategoriesCodec.decode("not-json") == [])
    }

    // MARK: - clearAll

    @Test("clearAll: 整表清空")
    func clearAllRemovesEverything() async throws {
        let (repo, _) = try makeRepo()
        try await repo.upsertMany([makeRecord(nativeId: "1"), makeRecord(nativeId: "2")])
        try await repo.clearAll()
        #expect(try await repo.fetchAll(limit: 50).isEmpty)
    }
}
