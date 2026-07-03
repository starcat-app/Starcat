//
//  ReleaseSubscriptionRepositoryTests.swift
//  StarcatTests
//
//  HOM-47：GRDBReleaseSubscriptionRepository 单测。
//
//  覆盖：
//  - subscribe（首次插入 + 重新订阅保留 lastKnown 游标）
//  - unsubscribe（仅置 is_subscribed=0，行保留）
//  - setNotifyEnabled（开关静默）
//  - updatePollCursor（推进游标 + lastPolledAt）
//  - fetchActive（只返回 is_subscribed=1 的行）
//

import Testing
import Foundation
import GRDB
@testable import Starcat

@Suite("GRDBReleaseSubscriptionRepository")
struct ReleaseSubscriptionRepositoryTests {

    private func makeRepo() throws -> (GRDBReleaseSubscriptionRepository, any DatabaseManaging) {
        let db = try InMemoryDatabaseManager()
        return (GRDBReleaseSubscriptionRepository(database: db), db)
    }

    // MARK: - subscribe

    @Test("subscribe: 首次写入 → is_subscribed=1 / notify_enabled=1 / lastKnown 写入")
    func subscribeFirstTime() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixture(id: 42)

        try await repo.subscribe(repoId: 42, primingReleaseId: 1001, primingTagName: "v1.0")

        let got = try #require(try await repo.find(repoId: 42))
        #expect(got.isSubscribed == true)
        #expect(got.notifyEnabled == true)
        #expect(got.lastKnownReleaseId == 1001)
        #expect(got.lastKnownTagName == "v1.0")
    }

    @Test("subscribe: 重新订阅 → is_subscribed=1，原 lastKnown 不被 nil 覆盖（COALESCE）")
    func resubscribePreservesCursor() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixture(id: 42)

        try await repo.subscribe(repoId: 42, primingReleaseId: 1001, primingTagName: "v1.0")
        try await repo.unsubscribe(repoId: 42)
        // 重新订阅时不传 priming → 不应清空原游标
        try await repo.subscribe(repoId: 42, primingReleaseId: nil, primingTagName: nil)

        let got = try #require(try await repo.find(repoId: 42))
        #expect(got.isSubscribed == true)
        #expect(got.lastKnownReleaseId == 1001)
        #expect(got.lastKnownTagName == "v1.0")
    }

    // MARK: - unsubscribe

    @Test("unsubscribe: 仅置 is_subscribed=0，行保留 + lastKnown 保留")
    func unsubscribeKeepsRow() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixture(id: 42)
        try await repo.subscribe(repoId: 42, primingReleaseId: 1001, primingTagName: "v1.0")

        try await repo.unsubscribe(repoId: 42)

        let got = try #require(try await repo.find(repoId: 42))
        #expect(got.isSubscribed == false)
        #expect(got.lastKnownReleaseId == 1001) // 保留以供再次订阅
    }

    // MARK: - setNotifyEnabled

    @Test("setNotifyEnabled: 切换 notify_enabled，不动 is_subscribed")
    func setNotifyEnabledToggle() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixture(id: 42)
        try await repo.subscribe(repoId: 42, primingReleaseId: 1, primingTagName: "v1")

        try await repo.setNotifyEnabled(repoId: 42, enabled: false)
        var got = try #require(try await repo.find(repoId: 42))
        #expect(got.notifyEnabled == false)
        #expect(got.isSubscribed == true)

        try await repo.setNotifyEnabled(repoId: 42, enabled: true)
        got = try #require(try await repo.find(repoId: 42))
        #expect(got.notifyEnabled == true)
    }

    // MARK: - updatePollCursor

    @Test("updatePollCursor: 推进 lastKnown + lastPolledAt")
    func updatePollCursorAdvances() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixture(id: 42)
        try await repo.subscribe(repoId: 42, primingReleaseId: 1, primingTagName: "v1")

        // 用一个具体 Date 实例，断言时再用同一格式化器还原字符串避免 .withFractionalSeconds 噪音
        let polled = Date(timeIntervalSince1970: 1_780_000_000)
        let expectedISO = ISO8601DateFormatter.shared.string(from: polled)
        try await repo.updatePollCursor(
            repoId: 42,
            latestReleaseId: 99,
            latestTagName: "v9",
            polledAt: polled
        )

        let got = try #require(try await repo.find(repoId: 42))
        #expect(got.lastKnownReleaseId == 99)
        #expect(got.lastKnownTagName == "v9")
        #expect(got.lastPolledAt == expectedISO)
    }

    // MARK: - fetchActive

    @Test("fetchActive: 只返回 is_subscribed=1 的订阅")
    func fetchActiveOnly() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixture(id: 1)
        try await db.insertRepoFixture(id: 2)
        try await db.insertRepoFixture(id: 3)

        try await repo.subscribe(repoId: 1, primingReleaseId: 1, primingTagName: "v1")
        try await repo.subscribe(repoId: 2, primingReleaseId: 2, primingTagName: "v2")
        try await repo.subscribe(repoId: 3, primingReleaseId: 3, primingTagName: "v3")
        try await repo.unsubscribe(repoId: 2)

        let active = try await repo.fetchActive()
        let allRows = try await repo.fetchAll()

        #expect(active.count == 2)
        #expect(active.map(\.repoId).sorted() == [1, 3])
        #expect(allRows.count == 3) // 行保留，仅 is_subscribed 切换
    }

    @Test("Release 订阅资格: 已 star 或已入库才允许")
    func releaseSubscriptionEligibility() {
        #expect(ReleaseSubscriptionEligibility.canSubscribe(
            repo: Self.repoFixture(isStarred: true),
            libraryState: .outsideLibrary
        ))
        #expect(ReleaseSubscriptionEligibility.canSubscribe(
            repo: Self.repoFixture(isStarred: false),
            libraryState: .inLibrary
        ))
        #expect(!ReleaseSubscriptionEligibility.canSubscribe(
            repo: Self.repoFixture(isStarred: false),
            libraryState: .outsideLibrary
        ))
    }

    private static func repoFixture(isStarred: Bool) -> Repo {
        Repo(
            id: 42,
            owner: "octo",
            name: "demo",
            fullName: "octo/demo",
            description: nil,
            language: "Swift",
            starsCount: 0,
            forksCount: 0,
            watchersCount: 0,
            topics: nil,
            license: nil,
            homepage: nil,
            htmlUrl: "https://github.com/octo/demo",
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: false,
            isFork: false,
            isArchived: false,
            isStarred: isStarred,
            pushedAt: nil,
            createdAt: nil,
            updatedAt: nil,
            starredAt: nil,
            cachedAt: nil
        )
    }
}
