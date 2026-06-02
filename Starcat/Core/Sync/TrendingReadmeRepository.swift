//
//  TrendingReadmeRepository.swift
//  Starcat
//
//  Trending README 缓存 Repository。
//
//  职责：
//  - 对接 `trending_readmes` 表（v4 迁移引入，schema 见 DatabaseMigrationsV1.createTrendingReadmes）
//  - 按 `full_name`（owner/repo）读写 README HTML 缓存
//  - 与 manage 路径的 `ReadmeRepository`（PK = repo_id: Int64）刻意保持隔离，互不污染
//
//  设计约束：
//  - 与 `ReadmeRepository` 同构：都依赖 `DatabaseManaging`、读写都 async、字段语义对齐
//    （rendered_html / etag / last_modified / cached_at / size），让 ReadmeAPI 复用同一套 SWR 逻辑
//  - PK 是 String（full_name）：GRDB MutablePersistableRecord.upsert 在 String PK 下完全可用
//  - 不直接持有 DatabaseManager 单例，便于注入 InMemoryDatabaseManager 跑测试
//

import Foundation
import GRDB

/// Trending README Repository。
struct TrendingReadmeRepository {

    private let writer: any DatabaseWriter

    init(database: any DatabaseManaging) {
        self.writer = database.writer
    }

    // MARK: - 查询

    /// 按 fullName 查找 README 缓存。
    /// - Returns: 缓存命中返回 TrendingReadme；未命中返回 nil
    func find(fullName: String) async throws -> TrendingReadme? {
        try await writer.read { db in
            try TrendingReadme.fetchOne(db, key: fullName)
        }
    }

    // MARK: - 写入

    /// upsert README 缓存。
    ///
    /// 与 `ReadmeRepository.upsert` 同款：`MutablePersistableRecord.upsert(_:)` 是 mutating，
    /// closure 内拷贝为 var；外部接口仍可传不可变值。
    func upsert(_ readme: TrendingReadme) async throws {
        try await writer.write { db in
            var copy = readme
            try copy.upsert(db)
        }
    }

    /// 仅更新 cached_at（命中 304 时刷新本地缓存有效期判定，不写新 HTML）。
    func touchCachedAt(fullName: String, at date: Date) async throws {
        let iso = ISO8601DateFormatter.shared.string(from: date)
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE trending_readmes SET cached_at = ? WHERE full_name = ?",
                arguments: [iso, fullName]
            )
        }
    }

    /// 删除指定 fullName 的 README 缓存。
    func delete(fullName: String) async throws {
        try await writer.write { db in
            _ = try TrendingReadme.deleteOne(db, key: fullName)
        }
    }

    /// 全表清空（设置页"清理缓存"用，与 `ReadmeRepository.deleteAll` 平行）。
    func deleteAll() async throws {
        try await writer.write { db in
            _ = try TrendingReadme.deleteAll(db)
        }
    }

    // MARK: - 缓存统计

    /// trending_readmes 表行数（设置页"清理缓存"展示用）。
    func countAll() async throws -> Int {
        try await writer.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM trending_readmes") ?? 0
        }
    }

    /// 所有缓存 README 字节总数（基于 `trending_readmes.size` 列）。
    func totalBytes() async throws -> Int64 {
        try await writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(size), 0) FROM trending_readmes") ?? 0
        }
    }
}
