//
//  UndoStarHistoryRepository.swift
//  Starcat
//
//  Undo Star 历史记录仓储层。
//
//  关键约束（2026-07-05 修复）：
//  - 存 `any DatabaseManaging` 而非 `any DatabaseWriter`——用户切换账号时
//    `DatabaseManaging.reopen(userId:)` 替换底层队列，`database.writer` 动态返回
//    当前用户的 writer。存 writer 引用会在 init 时捕获旧队列，导致跨账号数据泄漏。
//

import Foundation
import GRDB

// MARK: - Protocol

protocol UndoStarHistoryRepositoryProtocol: Sendable {
    func record(_ record: UndoStarRecord) async throws
    func remove(ghRepoId: Int64) async throws
    func fetchAll(sort: UndoStarSortOption) async throws -> [UndoStarRecord]
    func clearAll() async throws
    func cleanupExpired(before cutoff: String) async throws -> Int
    /// 从 repos 表取完整 Repo 对象（用于详情页/列表卡片补全数据）。
    func fetchRepo(ghRepoId: Int64) async throws -> Repo?
    /// 统计过期记录数（不删除）。
    func countExpired(before cutoff: String) async throws -> Int
}

/// Undo Star 排序选项。
enum UndoStarSortOption: String, CaseIterable, Identifiable {
    case unstarredAtDesc
    case starsDesc
    case starsAsc
    case updatedDesc
    case updatedAsc
    case nameAsc
    case nameDesc

    var id: String { rawValue }
}

// MARK: - GRDB 实现

struct GRDBUndoStarHistoryRepository: UndoStarHistoryRepositoryProtocol {
    let database: any DatabaseManaging

    func record(_ record: UndoStarRecord) async throws {
        try await database.writer.write { db in
            // 先确保 repos 表有对应行（FK 约束），无则补最小占位行
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO repos (id, owner, name, full_name, html_url, stars_count, forks_count, watchers_count, is_private, is_fork, is_archived, is_starred)
                VALUES (?, ?, ?, ?, ?, ?, 0, 0, 0, 0, 0, 0)
                """,
                arguments: [record.ghRepoId, record.owner, record.name, record.fullName, record.htmlUrl, record.starsCount]
            )

            // 从 repos 表取真实数据补全卡片所需字段
            let row = try Row.fetchOne(db, sql: """
                SELECT description, language, stars_count, forks_count, watchers_count FROM repos WHERE id = ?
                """, arguments: [record.ghRepoId])

            var enriched = record
            if let desc = row?["description"] as? String { enriched.repoDescription = desc }
            if let lang = row?["language"] as? String { enriched.language = lang }
            if let stars = row?["stars_count"] as? Int64 { enriched.starsCount = Int(stars) }
            if let forks = row?["forks_count"] as? Int64 { enriched.forksCount = Int(forks) }
            if let watchers = row?["watchers_count"] as? Int64 { enriched.watchersCount = Int(watchers) }
            try enriched.save(db)
        }
    }

    func remove(ghRepoId: Int64) async throws {
        try await database.writer.write { db in
            try UndoStarRecord.deleteOne(db, key: ghRepoId)
        }
    }

    func fetchAll(sort: UndoStarSortOption) async throws -> [UndoStarRecord] {
        try await database.writer.read { db in
            let order: any SQLOrderingTerm
            switch sort {
            case .unstarredAtDesc:
                order = Column("unstarred_at").desc
            case .starsDesc:
                order = Column("stars_count").desc
            case .starsAsc:
                order = Column("stars_count").asc
            case .nameAsc:
                order = Column("full_name").asc
            case .nameDesc:
                order = Column("full_name").desc
            case .updatedDesc, .updatedAsc:
                // undo_star_history 无 updated_at，回退到 unstarred_at
                order = Column("unstarred_at").desc
            }
            return try UndoStarRecord
                .order(order)
                .fetchAll(db)
        }
    }

    /// 从 repos 表取完整 Repo（含 forks/watchers/topics/license 等所有字段）。
    func fetchRepo(ghRepoId: Int64) async throws -> Repo? {
        try await database.writer.read { db in
            try Repo.fetchOne(db, key: ghRepoId)
        }
    }

    func clearAll() async throws {
        try await database.writer.write { db in
            try UndoStarRecord.deleteAll(db)
        }
    }

    func cleanupExpired(before cutoff: String) async throws -> Int {
        try await database.writer.write { db in
            try db.execute(
                sql: "DELETE FROM undo_star_history WHERE unstarred_at < ?",
                arguments: [cutoff]
            )
            return db.changesCount
        }
    }

    func countExpired(before cutoff: String) async throws -> Int {
        try await database.writer.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM undo_star_history WHERE unstarred_at < ?
                """, arguments: [cutoff]) ?? 0
        }
    }
}
