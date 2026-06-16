//
//  ActivityEventRepositoryTests.swift
//  StarcatTests
//
//  Activity 公告与关注 PR-1（2026-06-16）：GRDBActivityEventRepository 单测。
//
//  覆盖：
//  - upsertMany（首次插入 + 二次 upsert 保留 is_read）
//  - fetchAll（按 created_at desc + limit 截断）
//  - markRead / markAllRead
//  - unreadCount
//  - deleteOlderThan（30 天清理边界）
//  - clearAll
//

import Testing
import Foundation
import GRDB
@testable import Starcat

@Suite("GRDBActivityEventRepository")
struct ActivityEventRepositoryTests {

    private func makeRepo() throws -> (GRDBActivityEventRepository, any DatabaseManaging) {
        let db = try InMemoryDatabaseManager()
        return (GRDBActivityEventRepository(database: db), db)
    }

    /// 造一行最小可用的 ActivityEventRecord。createdAt 默认偏新时间，便于不被 30 天清理误删。
    private func makeRecord(
        id: String,
        eventType: String = "WatchEvent",
        actor: String = "ruanyf",
        repoName: String = "octo/demo",
        repoId: Int64 = 1,
        createdAt: String = "2026-06-15T00:00:00Z",
        isRead: Bool = false
    ) -> ActivityEventRecord {
        ActivityEventRecord(
            id: id,
            eventType: eventType,
            actorLogin: actor,
            actorAvatarUrl: "https://avatars.githubusercontent.com/\(actor)",
            repoName: repoName,
            repoId: repoId,
            payloadJson: #"{"action":"started"}"#,
            isRead: isRead,
            createdAt: createdAt,
            fetchedAt: "2026-06-16T00:00:00Z"
        )
    }

    // MARK: - upsertMany

    @Test("upsertMany: 首次插入 + 二次 upsert 保留 is_read=true")
    func upsertManyPreservesIsRead() async throws {
        let (repo, _) = try makeRepo()

        let r1 = makeRecord(id: "e1")
        try await repo.upsertMany([r1])
        try await repo.markRead(eventId: "e1", isRead: true)

        // 二次 upsert 同 id：payload / fetched_at / actor 等应被刷新，is_read 必须保留
        var r1Updated = r1
        r1Updated.payloadJson = #"{"action":"updated"}"#
        r1Updated.actorLogin = "another-user"
        try await repo.upsertMany([r1Updated])

        let all = try await repo.fetchAll(limit: 50)
        #expect(all.count == 1)
        #expect(all[0].payloadJson == #"{"action":"updated"}"#)
        #expect(all[0].actorLogin == "another-user")
        #expect(all[0].isRead == true)  // 关键:upsert 不能踩平用户的已读状态
    }

    // MARK: - fetchAll

    @Test("fetchAll: 按 created_at desc + limit 截断")
    func fetchAllOrderAndLimit() async throws {
        let (repo, _) = try makeRepo()

        try await repo.upsertMany([
            makeRecord(id: "old",  createdAt: "2026-06-01T00:00:00Z"),
            makeRecord(id: "new",  createdAt: "2026-06-10T00:00:00Z"),
            makeRecord(id: "mid",  createdAt: "2026-06-05T00:00:00Z"),
        ])

        let got = try await repo.fetchAll(limit: 2)
        #expect(got.map(\.id) == ["new", "mid"])
    }

    // MARK: - unreadCount

    @Test("unreadCount: 仅统计 is_read=0")
    func unreadCountOnlyUnread() async throws {
        let (repo, _) = try makeRepo()

        try await repo.upsertMany([
            makeRecord(id: "a"),
            makeRecord(id: "b"),
            makeRecord(id: "c", isRead: true),
        ])
        // 注：upsertMany 写入的 is_read 跟随 record 自带值。
        // 直接读出来检查 a/b 未读 / c 已读。
        let count = try await repo.unreadCount()
        #expect(count == 2)
    }

    // MARK: - markRead / markAllRead

    @Test("markRead: 单条切换；markAllRead: 全部置已读")
    func markReadOperations() async throws {
        let (repo, _) = try makeRepo()

        try await repo.upsertMany([
            makeRecord(id: "a"),
            makeRecord(id: "b"),
        ])

        try await repo.markRead(eventId: "a", isRead: true)
        #expect(try await repo.unreadCount() == 1)

        try await repo.markAllRead()
        #expect(try await repo.unreadCount() == 0)

        // 再翻回未读
        try await repo.markRead(eventId: "a", isRead: false)
        #expect(try await repo.unreadCount() == 1)
    }

    // MARK: - deleteOlderThan

    @Test("deleteOlderThan(30): 早于 30 天前的行被删；30 天内保留")
    func deleteOlderThanBoundary() async throws {
        let (repo, _) = try makeRepo()

        // ISO8601 字符串与 SQLite datetime('now', '-30 days') 对比能正常工作。
        // 使用相对当前的过去时间，让本测试不会因时钟漂移而 flaky。
        let now = Date()
        let cal = Calendar(identifier: .gregorian)
        let isoFormatter = ISO8601DateFormatter.shared
        let veryOld = cal.date(byAdding: .day, value: -60, to: now)!
        let recent  = cal.date(byAdding: .day, value: -3,  to: now)!
        let edge    = cal.date(byAdding: .day, value: -31, to: now)!   // 越过 30 天边界
        let nearEdge = cal.date(byAdding: .day, value: -29, to: now)!  // 在边界内

        try await repo.upsertMany([
            makeRecord(id: "very-old", createdAt: isoFormatter.string(from: veryOld)),
            makeRecord(id: "edge-31d", createdAt: isoFormatter.string(from: edge)),
            makeRecord(id: "near-29d", createdAt: isoFormatter.string(from: nearEdge)),
            makeRecord(id: "recent",   createdAt: isoFormatter.string(from: recent)),
        ])

        let deleted = try await repo.deleteOlderThan(days: 30)
        #expect(deleted == 2)  // very-old + edge-31d

        let remaining = try await repo.fetchAll(limit: 50).map(\.id).sorted()
        #expect(remaining == ["near-29d", "recent"])
    }

    // MARK: - clearAll

    @Test("clearAll: 整表清空")
    func clearAllRemovesEverything() async throws {
        let (repo, _) = try makeRepo()
        try await repo.upsertMany([makeRecord(id: "a"), makeRecord(id: "b")])
        try await repo.clearAll()
        #expect(try await repo.fetchAll(limit: 50).isEmpty)
    }
}
