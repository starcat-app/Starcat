//
//  SearchHistoryRepositoryTests.swift
//  StarcatTests
//
//  GRDBSearchHistoryRepository 单测（2026-06-14，搜索历史从 UserDefaults 升级到
//  GRDB SQLite + CloudKit-ready 字段）。
//
//  覆盖：
//  - record(首次 / 同 query 再次累加 / 大小写归一去重 / query 字段保留最新大小写)
//  - record(空白 / 全空白 → no-op)
//  - fetchAll(按 last_used_at DESC + 不超 limit)
//  - remove(大小写不敏感 / 不存在 → no-op)
//  - clearAll
//  - 超 limit 淘汰最低 decayedScore
//  - SearchHistory.decayedScore 公式纯逻辑（不走 DB）
//

import Testing
import Foundation
@testable import Starcat

@Suite("GRDBSearchHistoryRepository")
@MainActor
struct SearchHistoryRepositoryTests {

    private func makeRepo() throws -> (GRDBSearchHistoryRepository, any DatabaseManaging) {
        let db = try InMemoryDatabaseManager()
        return (GRDBSearchHistoryRepository(database: db), db)
    }

    // MARK: - record

    @Test("record 首次：useCount = 1，timestamps 全部 = now")
    func recordFirstTime() async throws {
        let (repo, _) = try makeRepo()
        try await repo.record("Swift")

        let all = try await repo.fetchAll()
        try #require(all.count == 1)
        let entry = all[0]
        #expect(entry.query == "Swift")
        #expect(entry.queryLower == "swift")
        #expect(entry.useCount == 1)
        // 三个时间戳首次应同一个值（同一 ISO8601 字符串）。
        #expect(entry.lastUsedAt == entry.firstSeenAt)
        #expect(entry.lastUsedAt == entry.modifiedAt)
    }

    @Test("record 多次同 query：useCount 累加，firstSeenAt 不变，lastUsedAt 刷新")
    func recordCumulativeCount() async throws {
        let (repo, _) = try makeRepo()
        try await repo.record("Swift")
        let firstSnapshot = try await repo.fetchAll().first!

        // 等一小段时间确保 ISO8601 timestamps 不会撞秒（withFractionalSeconds 通常 ms 级足够区分）
        try await Task.sleep(nanoseconds: 5_000_000)
        try await repo.record("Swift")
        try await repo.record("Swift")

        let final = try #require(try await repo.fetchAll().first)
        #expect(final.useCount == 3)
        #expect(final.firstSeenAt == firstSnapshot.firstSeenAt) // first 不变
        #expect(final.lastUsedAt > firstSnapshot.lastUsedAt)    // last 刷新
        #expect(final.modifiedAt > firstSnapshot.modifiedAt)
    }

    @Test("record 大小写不敏感去重，但 query 字段保留最新输入的大小写")
    func recordCaseInsensitiveDedup() async throws {
        let (repo, _) = try makeRepo()
        try await repo.record("Swift")
        try await repo.record("SWIFT")
        try await repo.record("swift")

        let all = try await repo.fetchAll()
        try #require(all.count == 1)
        #expect(all[0].query == "swift")     // 最近一次输入
        #expect(all[0].queryLower == "swift")
        #expect(all[0].useCount == 3)
    }

    @Test("record 空白或全空白 query 直接 no-op")
    func recordEmptyOrWhitespace() async throws {
        let (repo, _) = try makeRepo()
        try await repo.record("")
        try await repo.record("   ")
        try await repo.record("\n\t  ")

        let all = try await repo.fetchAll()
        #expect(all.isEmpty)
    }

    @Test("record 自动 trim 首尾空白")
    func recordTrimsWhitespace() async throws {
        let (repo, _) = try makeRepo()
        try await repo.record("  GRDB  ")

        let all = try await repo.fetchAll()
        try #require(all.count == 1)
        #expect(all[0].query == "GRDB")
        #expect(all[0].queryLower == "grdb")
    }

    // MARK: - fetchAll

    @Test("fetchAll 按 last_used_at DESC 排序（数据库层预排序）")
    func fetchAllOrderByLastUsed() async throws {
        let (repo, _) = try makeRepo()
        try await repo.record("first")
        try await Task.sleep(nanoseconds: 5_000_000)
        try await repo.record("second")
        try await Task.sleep(nanoseconds: 5_000_000)
        try await repo.record("third")

        let all = try await repo.fetchAll()
        try #require(all.count == 3)
        #expect(all[0].query == "third")
        #expect(all[1].query == "second")
        #expect(all[2].query == "first")
    }

    // MARK: - remove

    @Test("remove 大小写不敏感")
    func removeCaseInsensitive() async throws {
        let (repo, _) = try makeRepo()
        try await repo.record("Swift")
        try await repo.record("Rust")

        try await repo.remove(query: "SWIFT")

        let all = try await repo.fetchAll()
        try #require(all.count == 1)
        #expect(all[0].query == "Rust")
    }

    @Test("remove 不存在的 query → no-op")
    func removeMissingNoop() async throws {
        let (repo, _) = try makeRepo()
        try await repo.record("Swift")

        try await repo.remove(query: "Go") // 不存在
        let all = try await repo.fetchAll()
        #expect(all.count == 1)
    }

    // MARK: - clearAll

    @Test("clearAll 清空整表")
    func clearAllEmptiesTable() async throws {
        let (repo, _) = try makeRepo()
        try await repo.record("a")
        try await repo.record("b")
        try await repo.record("c")

        try await repo.clearAll()

        let all = try await repo.fetchAll()
        #expect(all.isEmpty)
    }

    // MARK: - 超限淘汰

    @Test("超 limit (50) 时按 decayedScore 升序淘汰一条")
    func evictWhenOverLimit() async throws {
        let (repo, _) = try makeRepo()

        // 先写满 50 条，每条 useCount=1
        for i in 0..<50 {
            try await repo.record("item-\(i)")
            // 让 last_used_at 有递增差异（避免按 ISO8601 排序时 fluctuate）
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let beforeOverflow = try await repo.fetchAll()
        #expect(beforeOverflow.count == 50)

        // 第 51 条插入。最早写入的 "item-0" 应被淘汰（useCount 都是 1 时按 lastUsedAt 最旧）。
        try await repo.record("overflow")

        let after = try await repo.fetchAll()
        #expect(after.count == 50)
        // item-0 已被淘汰，overflow 应该在；item-1 还在；item-0 不在
        let queries = Set(after.map { $0.query })
        #expect(queries.contains("overflow"))
        #expect(!queries.contains("item-0"))
    }

    @Test("超 limit 时高 useCount 项即使较老也不被淘汰")
    func evictPrefersLowScore() async throws {
        let (repo, _) = try makeRepo()

        // 第 1 条强化 useCount，让分数明显高于后来的所有 useCount=1 项
        try await repo.record("hot")
        for _ in 0..<10 {
            try await Task.sleep(nanoseconds: 1_000_000)
            try await repo.record("hot")
        }
        // hot 现在 useCount = 11，lastUsedAt 紧追当前时间

        // 然后插入 49 条新关键词（useCount=1 each），lastUsedAt 都比 "hot" 还新
        for i in 0..<49 {
            try await Task.sleep(nanoseconds: 1_000_000)
            try await repo.record("filler-\(i)")
        }
        let beforeOverflow = try await repo.fetchAll()
        #expect(beforeOverflow.count == 50)

        // 第 51 条插入。淘汰应选 score 最低的 filler-0，而不是 "hot"
        try await Task.sleep(nanoseconds: 1_000_000)
        try await repo.record("trigger-evict")

        let after = try await repo.fetchAll()
        #expect(after.count == 50)
        let queries = Set(after.map { $0.query })
        #expect(queries.contains("hot"))         // 高 useCount 保住
        #expect(queries.contains("trigger-evict"))
        #expect(!queries.contains("filler-0"))   // 最旧 useCount=1 被淘汰
    }

    // MARK: - decayedScore 纯逻辑

    @Test("decayedScore：今天用过的 useCount=1 项 score = 1.0")
    func decayedScoreFreshSingle() {
        let now = Date()
        let entry = SearchHistory(
            id: "1",
            query: "x",
            queryLower: "x",
            useCount: 1,
            lastUsedAt: ISO8601DateFormatter.shared.string(from: now),
            firstSeenAt: ISO8601DateFormatter.shared.string(from: now),
            modifiedAt: ISO8601DateFormatter.shared.string(from: now)
        )
        let score = entry.decayedScore(now: now)
        #expect(abs(score - 1.0) < 0.001)
    }

    @Test("decayedScore：14 天前用过的 useCount=10 半衰为 5.0")
    func decayedScoreOneHalfLife() {
        let now = Date()
        let fourteenDaysAgo = now.addingTimeInterval(-14 * 86_400)
        let entry = SearchHistory(
            id: "1",
            query: "x",
            queryLower: "x",
            useCount: 10,
            lastUsedAt: ISO8601DateFormatter.shared.string(from: fourteenDaysAgo),
            firstSeenAt: ISO8601DateFormatter.shared.string(from: fourteenDaysAgo),
            modifiedAt: ISO8601DateFormatter.shared.string(from: fourteenDaysAgo)
        )
        let score = entry.decayedScore(now: now, halfLifeDays: 14)
        // 半衰一次：10 × 0.5 = 5.0；浮点误差容差 0.01
        #expect(abs(score - 5.0) < 0.01)
    }

    @Test("decayedScore：lastUsedAt 解析失败 fallback 到 useCount（不衰减）")
    func decayedScoreInvalidDateFallback() {
        let entry = SearchHistory(
            id: "1",
            query: "x",
            queryLower: "x",
            useCount: 7,
            lastUsedAt: "not-a-date",
            firstSeenAt: "not-a-date",
            modifiedAt: "not-a-date"
        )
        #expect(entry.decayedScore() == 7.0)
    }
}
