//
//  ActivitySyncStateRepositoryTests.swift
//  StarcatTests
//
//  Activity 公告与关注 PR-1（2026-06-16）：GRDBActivitySyncStateRepository 单测。
//
//  覆盖：
//  - current() 返回 nil 当从未写入
//  - update* partial：每个方法只写自己负责的字段，不动其他字段
//  - 重复调用同一 update 走 UPSERT 覆盖而非冲突报错
//  - clear() 整表清空
//

import Testing
import Foundation
import GRDB
@testable import Starcat

@Suite("GRDBActivitySyncStateRepository")
struct ActivitySyncStateRepositoryTests {

    private func makeRepo() throws -> (GRDBActivitySyncStateRepository, any DatabaseManaging) {
        let db = try InMemoryDatabaseManager()
        return (GRDBActivitySyncStateRepository(database: db), db)
    }

    // MARK: - current

    @Test("current: 从未写入返回 nil")
    func currentReturnsNilWhenEmpty() async throws {
        let (repo, _) = try makeRepo()
        let got = try await repo.current()
        #expect(got == nil)
    }

    // MARK: - update events

    @Test("updateEvents: 首次写入创建行 / 二次调用覆盖 events 字段，不影响别的字段")
    func updateEventsPartial() async throws {
        let (repo, _) = try makeRepo()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        try await repo.updateEvents(etag: #""abc""#, lastFetchedAt: t0)

        let first = try #require(try await repo.current())
        #expect(first.eventsEtag == #""abc""#)
        #expect(first.lastEventsFetchedAt != nil)
        #expect(first.blogRssEtag == nil)
        #expect(first.lastBlogFetchedAt == nil)
        #expect(first.lastSecurityFetchedAt == nil)
        #expect(first.lastCleanupAt == nil)

        // 二次调 updateEvents：events 字段覆盖；blog / security / cleanup 字段保留
        try await repo.updateBlogRss(etag: #""blog-etag""#, lastFetchedAt: t0)
        let t1 = Date(timeIntervalSince1970: 1_700_001_000)
        try await repo.updateEvents(etag: nil, lastFetchedAt: t1)

        let second = try #require(try await repo.current())
        #expect(second.eventsEtag == nil)                  // 覆盖（即便传 nil）
        #expect(second.blogRssEtag == #""blog-etag""#)     // 保留
        #expect(second.lastBlogFetchedAt != nil)           // 保留
    }

    // MARK: - update blog rss

    @Test("updateBlogRss: 只动 blog_rss_etag + last_blog_fetched_at")
    func updateBlogRssPartial() async throws {
        let (repo, _) = try makeRepo()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        try await repo.updateEvents(etag: #""ev""#, lastFetchedAt: t0)
        try await repo.updateBlogRss(etag: #""blog""#, lastFetchedAt: t0)

        let state = try #require(try await repo.current())
        #expect(state.eventsEtag == #""ev""#)         // 未被擦除
        #expect(state.blogRssEtag == #""blog""#)
    }

    // MARK: - update security

    @Test("updateSecurity: 只动 last_security_fetched_at")
    func updateSecurityOnlyTimestamp() async throws {
        let (repo, _) = try makeRepo()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        try await repo.updateEvents(etag: #""ev""#, lastFetchedAt: t0)
        try await repo.updateSecurity(lastFetchedAt: t0)

        let state = try #require(try await repo.current())
        #expect(state.eventsEtag == #""ev""#)
        #expect(state.lastSecurityFetchedAt != nil)
    }

    // MARK: - update cleanup

    @Test("updateLastCleanupAt: 仅写 last_cleanup_at；可幂等覆盖")
    func updateLastCleanupAtIdempotent() async throws {
        let (repo, _) = try makeRepo()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = Date(timeIntervalSince1970: 1_700_086_400)  // 1 天后

        try await repo.updateLastCleanupAt(t0)
        let first = try #require(try await repo.current())
        let firstISO = first.lastCleanupAt
        #expect(firstISO != nil)

        try await repo.updateLastCleanupAt(t1)
        let second = try #require(try await repo.current())
        #expect(second.lastCleanupAt != firstISO)         // 已覆盖到新时间
        #expect(second.eventsEtag == nil)                  // 没串污染其他字段
    }

    // MARK: - clear

    @Test("clear: 整表清空，current 重新回 nil")
    func clearEmptiesRow() async throws {
        let (repo, _) = try makeRepo()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        try await repo.updateEvents(etag: #""ev""#, lastFetchedAt: t0)
        #expect(try await repo.current() != nil)

        try await repo.clear()
        #expect(try await repo.current() == nil)
    }
}
