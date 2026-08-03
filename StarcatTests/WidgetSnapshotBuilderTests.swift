//
//  WidgetSnapshotBuilderTests.swift
//  StarcatTests
//
//  Widget 数据库投影测试：覆盖 Focus、今日重逢和 Release Watch 的隐私、
//  排序、数量上限与确定性选择规则。
//
//  测试使用真实 GRDB 内存库，确保断言的是生产 SQL，而不是测试侧重复实现的 mock。
//

import Foundation
import GRDB
import Testing
@testable import Starcat

@Suite("WidgetSnapshotBuilder")
struct WidgetSnapshotBuilderTests {

    @Test("未绑定用户数据库时拒绝生成 ready 快照")
    func rejectsAnonymousDatabase() async throws {
        let database = try InMemoryDatabaseManager(userId: nil)
        let builder = WidgetSnapshotBuilder(database: database)

        await #expect(throws: WidgetSnapshotBuilderError.noAuthenticatedUser) {
            try await builder.build()
        }
    }

    @Test("Focus 置顶优先、排除不可展示仓库并限制六条")
    func buildsFocusProjection() async throws {
        let database = try InMemoryDatabaseManager(userId: 42)
        for id in Int64(1)...Int64(11) {
            try await database.insertRepoFixture(
                id: id,
                starredAt: String(format: "2026-05-%02lldT00:00:00Z", 30 - id)
            )
        }
        try await database.writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO repo_pins (repo_id, pinned_at) VALUES (1, 100), (2, 200);
                """
            )
            for id in Int64(3)...Int64(8) {
                try db.execute(
                    sql: """
                    INSERT INTO repo_notes (
                        repo_id, content, status, library_state, is_ai_generated
                    ) VALUES (?, NULL, 'using', 'outside_library', 0)
                    """,
                    arguments: [id]
                )
            }

            // 三条即使置顶也必须被隐私和可用性门禁排除。
            try db.execute(
                sql: """
                INSERT INTO repo_pins (repo_id, pinned_at)
                VALUES (9, 900), (10, 1000), (11, 1100)
                """
            )
            try db.execute(sql: "UPDATE repos SET is_private = 1 WHERE id = 9")
            try db.execute(sql: "UPDATE repos SET is_archived = 1 WHERE id = 10")
            try db.execute(
                sql: "UPDATE repos SET access_state = 'inaccessible' WHERE id = 11"
            )
        }

        let snapshot = try await WidgetSnapshotBuilder(database: database).build()

        #expect(snapshot.focusRepositories.map(\.id) == [2, 1, 3, 4, 5, 6])
        #expect(snapshot.focusRepositories.map(\.focusSource) == [
            .pinned, .pinned, .using, .using, .using, .using
        ])
        #expect(snapshot.focusRepositories.count == 6)
        #expect(snapshot.focusRepositories.allSatisfy { $0.openURL.scheme == "starcat" })
    }

    @Test("今日重逢过滤近期、置顶、正在使用和私有仓库并保持同日稳定")
    func buildsStableRediscoveryProjection() async throws {
        let database = try InMemoryDatabaseManager(userId: 99)
        for id in Int64(1)...Int64(11) {
            try await database.insertRepoFixture(
                id: id,
                starredAt: "2026-05-01T00:00:00Z"
            )
        }
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE repos SET starred_at = '2026-07-20T00:00:00Z' WHERE id = 4"
            )
            try db.execute(
                sql: "INSERT INTO repo_pins (repo_id, pinned_at) VALUES (5, 500)"
            )
            try db.execute(
                sql: """
                INSERT INTO repo_notes (
                    repo_id, content, status, library_state, is_ai_generated
                ) VALUES
                    (6, NULL, 'using', 'outside_library', 0),
                    (11, NULL, 'unread', 'in_library', 0)
                """
            )
            try db.execute(sql: "UPDATE repos SET is_private = 1 WHERE id = 7")
            try db.execute(sql: "UPDATE repos SET is_archived = 1 WHERE id = 8")
            try db.execute(
                sql: "UPDATE repos SET access_state = 'inaccessible' WHERE id = 9"
            )
            try db.execute(
                sql: "UPDATE repos SET is_starred = 0, starred_at = NULL WHERE id IN (10, 11)"
            )
        }

        let date = Date(timeIntervalSince1970: 1_753_852_800) // 2026-07-28 UTC
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let builder = WidgetSnapshotBuilder(database: database)
        let first = try await builder.build(generatedAt: date, calendar: calendar)
        let second = try await builder.build(generatedAt: date, calendar: calendar)

        #expect(first.rediscoveryRepository?.id == second.rediscoveryRepository?.id)
        #expect([Int64(1), 2, 3, 11].contains(first.rediscoveryRepository?.id))
        #expect(
            WidgetSnapshotBuilder.selectRediscoveryRepositoryID(
                candidateIDs: [],
                userID: 99,
                date: date,
                calendar: calendar
            ) == nil
        )
    }

    @Test("收藏趋势补齐十二周并排除私有和不可访问仓库")
    func buildsCollectionTrendProjection() async throws {
        let database = try InMemoryDatabaseManager(userId: 42)
        let dates = [
            "2026-05-11T08:00:00Z",
            "2026-07-01T08:00:00Z",
            "2026-07-27T08:00:00Z",
            "2026-07-30T08:00:00Z",
            "2026-07-29T08:00:00Z",
            "2026-07-28T08:00:00Z"
        ]
        for (offset, starredAt) in dates.enumerated() {
            try await database.insertRepoFixture(
                id: Int64(offset + 1),
                starredAt: starredAt
            )
        }
        try await database.writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO repo_notes (
                    repo_id, content, status, library_state, is_ai_generated
                ) VALUES
                    (2, NULL, 'read', 'outside_library', 0),
                    (3, NULL, 'using', 'outside_library', 0),
                    (4, NULL, 'read', 'outside_library', 0)
                """
            )
            try db.execute(sql: "UPDATE repos SET is_private = 1 WHERE id = 5")
            try db.execute(
                sql: "UPDATE repos SET access_state = 'inaccessible' WHERE id = 6"
            )
        }

        let generatedAt = ISO8601DateFormatter().date(
            from: "2026-07-30T12:00:00Z"
        )!
        let snapshot = try await WidgetSnapshotBuilder(database: database).build(
            generatedAt: generatedAt
        )
        let trend = try #require(snapshot.collectionTrend)

        #expect(trend.totalCount == 4)
        #expect(trend.addedInLast30DaysCount == 3)
        #expect(trend.weeklyPoints.count == 12)
        #expect(trend.weeklyPoints.map(\.count).reduce(0, +) == 4)
        #expect(trend.weeklyPoints.last?.count == 2)
        #expect(trend.statusBreakdown.unreadCount == 1)
        #expect(trend.statusBreakdown.readCount == 2)
        #expect(trend.statusBreakdown.usingCount == 1)
    }

    @Test("Release Watch 只投影订阅未读公开记录并保持排序与总数口径")
    func buildsReleaseProjection() async throws {
        let database = try InMemoryDatabaseManager(userId: 42)
        for id in Int64(1)...Int64(4) {
            try await database.insertRepoFixture(id: id)
        }
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE repos SET is_private = 1 WHERE id = 3")
            try db.execute(
                sql: "UPDATE repos SET access_state = 'inaccessible' WHERE id = 4"
            )
        }

        let subscriptions = GRDBReleaseSubscriptionRepository(database: database)
        for id in Int64(1)...Int64(4) {
            try await subscriptions.subscribe(
                repoId: id,
                primingReleaseId: nil,
                primingTagName: nil
            )
        }
        try await subscriptions.unsubscribe(repoId: 2)

        let releases = GRDBReleaseRepository(database: database)
        var records: [ReleaseRecord] = []
        for index in 1...8 {
            records.append(
                makeRelease(
                    id: Int64(100 + index),
                    repoID: 1,
                    publishedAt: String(
                        format: "2026-07-%02dT00:00:00Z",
                        10 + index
                    )
                )
            )
        }
        records.append(makeRelease(id: 201, repoID: 2, publishedAt: "2026-07-30T00:00:00Z"))
        records.append(makeRelease(id: 301, repoID: 3, publishedAt: "2026-07-29T00:00:00Z"))
        records.append(makeRelease(id: 401, repoID: 4, publishedAt: "2026-07-28T00:00:00Z"))
        var draft = makeRelease(id: 202, repoID: 1, publishedAt: "2026-07-31T00:00:00Z")
        draft.isDraft = true
        records.append(draft)
        try await releases.upsertMany(records, isReadDefault: false)
        try await releases.markRead(releaseId: 101, isRead: true)

        let snapshot = try await WidgetSnapshotBuilder(database: database).build()

        #expect(snapshot.unreadReleaseCount == 7)
        #expect(snapshot.unreadReleases.map(\.id) == [108, 107, 106, 105, 104, 103])
        #expect(snapshot.unreadReleases.allSatisfy { $0.repositoryID == 1 })
        #expect(snapshot.unreadReleases.allSatisfy { $0.openURL.path.hasSuffix("/releases") })
        #expect(snapshot.unreadReleases.first?.publishedAt != nil)
    }

    private func makeRelease(
        id: Int64,
        repoID: Int64,
        publishedAt: String
    ) -> ReleaseRecord {
        ReleaseRecord(
            id: id,
            repoId: repoID,
            tagName: "v\(id)",
            name: "Release \(id)",
            bodyMarkdown: "not exported",
            htmlUrl: "https://github.com/octo/demo-\(repoID)/releases/tag/v\(id)",
            isPrerelease: false,
            isDraft: false,
            publishedAt: publishedAt,
            createdAtRemote: publishedAt,
            assetsJson: nil,
            isRead: false,
            fetchedAt: publishedAt
        )
    }
}
