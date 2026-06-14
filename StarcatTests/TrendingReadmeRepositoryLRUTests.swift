//
//  TrendingReadmeRepositoryLRUTests.swift
//  StarcatTests
//
//  HOM-201 P1-3（2026-06-14）：trending_readmes LRU 自动淘汰行为测试。
//
//  阈值参数对外暴露给测试（`enforceLRULimits` 支持 `maxRows` / `lowWaterRows` /
//  `maxBytes` / `lowWaterBytes`），用 InMemoryDatabaseManager 起 v4+ schema
//  跑真实 SQLite,直接验证淘汰策略:
//   - 行数触发:总行数 > maxRows 时按 cached_at ASC 收缩到 lowWaterRows
//   - 字节触发:总 size > maxBytes 时按累计 size 收缩到 lowWaterBytes
//   - 未达阈值:不淘汰任何行
//

import Testing
import Foundation
import GRDB
@testable import Starcat

@Suite("TrendingReadmeRepository LRU")
struct TrendingReadmeRepositoryLRUTests {

    private func makeReadme(fullName: String, size: Int, cachedAt: String) -> TrendingReadme {
        TrendingReadme(
            fullName: fullName,
            renderedHtml: String(repeating: "x", count: size),
            etag: nil,
            lastModified: nil,
            cachedAt: cachedAt,
            size: size
        )
    }

    /// 按 idx 生成 ISO8601 字符串,保证 ASC 排序后 idx 小的更早。
    private func iso(_ idx: Int) -> String {
        // 2026-06-14T00:00:00Z + idx 秒,简化 SQL ORDER BY cached_at ASC 的语义。
        let base = ISO8601DateFormatter.shared.date(from: "2026-06-14T00:00:00Z")!
        return ISO8601DateFormatter.shared.string(from: base.addingTimeInterval(TimeInterval(idx)))
    }

    @Test("行数未达阈值 → 不淘汰")
    func underRowLimit_noEviction() async throws {
        let db = try InMemoryDatabaseManager()
        let repo = TrendingReadmeRepository(database: db)

        for i in 0..<5 {
            try await repo.upsert(makeReadme(fullName: "o/\(i)", size: 100, cachedAt: iso(i)))
        }

        // maxRows=10:5 行远未达,enforceLRULimits 应直接 return
        try await db.writer.write { conn in
            try TrendingReadmeRepository.enforceLRULimits(
                conn,
                maxRows: 10,
                lowWaterRows: 8,
                maxBytes: 1_000_000,
                lowWaterBytes: 800_000
            )
        }

        let count = try await repo.countAll()
        #expect(count == 5)
    }

    @Test("行数超阈值 → 按 cached_at ASC 收缩到 lowWaterRows")
    func overRowLimit_shrinksToLowWater() async throws {
        let db = try InMemoryDatabaseManager()
        let repo = TrendingReadmeRepository(database: db)

        for i in 0..<20 {
            try await repo.upsert(makeReadme(fullName: "o/\(i)", size: 100, cachedAt: iso(i)))
        }

        // 注意:upsert 自带的 LRU 走默认值(max=500)不触发,这里手动调小阈值
        try await db.writer.write { conn in
            try TrendingReadmeRepository.enforceLRULimits(
                conn,
                maxRows: 10,
                lowWaterRows: 8,
                maxBytes: 1_000_000_000,
                lowWaterBytes: 1_000_000_000
            )
        }

        // 20 → 8 行(收缩到 lowWaterRows)
        let count = try await repo.countAll()
        #expect(count == 8)

        // 验证留下的是最新的 8 行(idx 12..19),最早的 12 行被删
        for i in 0..<12 {
            let found = try await repo.find(fullName: "o/\(i)")
            #expect(found == nil, "idx \(i) 应该被删")
        }
        for i in 12..<20 {
            let found = try await repo.find(fullName: "o/\(i)")
            #expect(found != nil, "idx \(i) 应该保留")
        }
    }

    @Test("字节超阈值 → 按 cached_at ASC 累计 size 收缩到 lowWaterBytes")
    func overByteLimit_shrinksByRunningSize() async throws {
        let db = try InMemoryDatabaseManager()
        let repo = TrendingReadmeRepository(database: db)

        // 写 10 行,每行 size = 1000;total = 10_000
        for i in 0..<10 {
            try await repo.upsert(makeReadme(fullName: "o/\(i)", size: 1000, cachedAt: iso(i)))
        }

        // maxBytes=5000(超),lowWaterBytes=3000:删 oldest 累计 ≤ (10000-3000)=7000 的行
        // → idx 0..6 累计 7000(7 行)恰好删,留 3 行 size=3000
        try await db.writer.write { conn in
            try TrendingReadmeRepository.enforceLRULimits(
                conn,
                maxRows: 1_000_000,
                lowWaterRows: 1_000_000,
                maxBytes: 5_000,
                lowWaterBytes: 3_000
            )
        }

        let totalBytes = try await repo.totalBytes()
        #expect(totalBytes == 3_000, "应收缩到 lowWaterBytes(3000),实际 \(totalBytes)")

        let count = try await repo.countAll()
        #expect(count == 3, "10 - 7 = 3 行,实际 \(count)")
    }

    @Test("upsert 自动触发 LRU(默认阈值,刚好突破 lruMaxRows)")
    func upsertTriggersLRU() async throws {
        // 用默认阈值跑(500 行)。InMemory + size=10 字节 → 总 IO 约 50KB,可接受。
        // 写 lruMaxRows+1 = 501 次:前 500 次每次行数累加都 ≤ lruMaxRows 不触发,
        // 第 501 次 insert 后行数=501 > lruMaxRows → 触发 → 收缩到 lruLowWaterRows(400)。
        let db = try InMemoryDatabaseManager()
        let repo = TrendingReadmeRepository(database: db)

        for i in 0..<(TrendingReadmeRepository.lruMaxRows + 1) {
            try await repo.upsert(makeReadme(fullName: "o/\(i)", size: 10, cachedAt: iso(i)))
        }

        let count = try await repo.countAll()
        #expect(count == TrendingReadmeRepository.lruLowWaterRows,
                "upsert 后应触发 LRU 收缩到 \(TrendingReadmeRepository.lruLowWaterRows),实际 \(count)")
    }
}
