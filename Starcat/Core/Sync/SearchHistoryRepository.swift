//
//  SearchHistoryRepository.swift
//  Starcat
//
//  GRDBSearchHistoryRepository：搜索历史 SQLite 持久化（GRDB 实现）。
//
//  schema 对照（`DatabaseMigrationsV1.createSearchHistory`）：
//    id              TEXT PRIMARY KEY      -- UUID
//    query           TEXT NOT NULL
//    query_lower     TEXT NOT NULL UNIQUE
//    use_count       INTEGER NOT NULL DEFAULT 1
//    last_used_at    TEXT NOT NULL
//    first_seen_at   TEXT NOT NULL
//    modified_at     TEXT NOT NULL
//
//  关键约束：
//  - 所有写操作单条 SQL UPSERT 完成，避免 read-then-write 的并发漏洞。
//  - 历史总数硬上限 50；插入新条时若已满则按 decayedScore 升序删一条（最低分淘汰）。
//  - lower-case 去重直接由 SQLite UNIQUE 索引保证，去重逻辑不依赖应用层先 SELECT。
//

import Foundation
import GRDB

struct GRDBSearchHistoryRepository: SearchHistoryRepositoryProtocol {

    /// 历史总条数硬上限。超出后按 `decayedScore` 升序淘汰最低分项。
    /// 跟旧 UserDefaults 实现保持一致的 50 上限，CloudKit 同步总流量也可控。
    static let limit: Int = 50

    private let database: any DatabaseManaging

    init(database: any DatabaseManaging) {
        self.database = database
    }

    func fetchAll() async throws -> [SearchHistory] {
        try await database.writer.read { db in
            // 数据库按 last_used_at DESC 预排序，UI 层再按 decayedScore 二次排序；
            // 当 useCount 都为 1 时 last_used_at DESC 已经是正确顺序，不需要重排。
            try SearchHistory.fetchAll(
                db,
                sql: "SELECT * FROM search_history ORDER BY last_used_at DESC LIMIT \(Self.limit)"
            )
        }
    }

    func record(_ query: String) async throws {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let lower = trimmed.lowercased()
        let nowISO = ISO8601DateFormatter.shared.string(from: Date())
        let newID = UUID().uuidString

        try await database.writer.write { db in
            // UPSERT：query_lower 命中 → 累加计数并刷新原始大小写；否则新建。
            //
            // 注意大小写刷新语义：
            //   record("Swift") → 显示 "Swift"
            //   随后 record("swift") → 显示 "swift"（覆盖大小写，跟用户最近一次输入保持一致）
            // 这是与旧 UserDefaults 实现行为一致的设计：showing what the user just typed.
            try db.execute(
                sql: """
                INSERT INTO search_history (id, query, query_lower, use_count, last_used_at, first_seen_at, modified_at)
                VALUES (?, ?, ?, 1, ?, ?, ?)
                ON CONFLICT(query_lower) DO UPDATE SET
                    query = excluded.query,
                    use_count = search_history.use_count + 1,
                    last_used_at = excluded.last_used_at,
                    modified_at = excluded.modified_at
                """,
                arguments: [newID, trimmed, lower, nowISO, nowISO, nowISO]
            )

            // 淘汰策略：每次 INSERT 后检查总数；超 limit 则按 decayedScore 升序删一条。
            // 这里我们没法在纯 SQL 里算 pow，所以 SELECT 出来在内存里算分淘汰。
            // 表上限 50 条，SELECT + 排序代价可忽略。
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_history") ?? 0
            if count > Self.limit {
                let entries = try SearchHistory.fetchAll(db)
                let now = Date()
                if let victim = entries.min(by: { $0.decayedScore(now: now) < $1.decayedScore(now: now) }) {
                    try db.execute(
                        sql: "DELETE FROM search_history WHERE id = ?",
                        arguments: [victim.id]
                    )
                }
            }
        }
    }

    func remove(query: String) async throws {
        let lower = query.lowercased()
        try await database.writer.write { db in
            try db.execute(
                sql: "DELETE FROM search_history WHERE query_lower = ?",
                arguments: [lower]
            )
        }
    }

    func clearAll() async throws {
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM search_history")
        }
    }
}
