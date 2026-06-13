//
//  ReadmeRepository.swift
//  Starcat
//
//  README 缓存 Repository。
//
//  职责：
//  - 对接 `readmes` 表（schema 见 DatabaseMigrationsV1.createReadmes）
//  - 读取已缓存 README（含 etag / last_modified，用于 If-None-Match 增量校验）
//  - upsert 新拉到的 HTML
//  - 按 repo 删除（取消 star 或主动清缓存时调用）
//
//  设计约束：
//  - 与 RepoRepository 同构（同一个 DatabaseManaging 注入），方便 AppDependencies 统一组装
//  - 不直接持有 DatabaseManager 单例
//  - 读写都 async；GRDB 在内部用专属 dispatch queue，避免阻塞主线程
//
//  字段语义：
//  - content：原始 Markdown（当前阶段未使用，留作 P2 翻译/AI 摘要复用）
//  - rendered_html：GitHub 服务端渲染好的 HTML 片段（实际显示用这个）
//  - etag / last_modified：HTTP 缓存校验头
//  - cached_at：本地写入时间（ISO8601，便于按时间清理）
//  - size：byte 长度，未来批量清理大缓存时按它排序
//

import Foundation
import GRDB

/// README Repository。
struct ReadmeRepository {

    private let database: any DatabaseManaging

    init(database: any DatabaseManaging) {
        self.database = database
    }

    // MARK: - 查询

    /// 按 repoId 查找 README 缓存。
    /// - Returns: 缓存命中返回 Readme；未命中返回 nil
    func find(repoId: Int64) async throws -> Readme? {
        try await database.writer.read { db in
            try Readme.fetchOne(db, key: repoId)
        }
    }

    // MARK: - 写入

    /// upsert README 缓存。
    ///
    /// GRDB 的 `MutablePersistableRecord.upsert(_:)` 是 mutating 方法（会回填 rowID），
    /// 因此必须在 closure 内拷贝为 var；外部接口仍可传不可变值。
    func upsert(_ readme: Readme) async throws {
        try await database.writer.write { db in
            var copy = readme
            try copy.upsert(db)
        }
    }

    /// 仅更新 cached_at（命中 304 时刷新本地缓存有效期判定，不写新 HTML）。
    func touchCachedAt(repoId: Int64, at date: Date) async throws {
        let iso = ISO8601DateFormatter.shared.string(from: date)
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE readmes SET cached_at = ? WHERE repo_id = ?",
                arguments: [iso, repoId]
            )
        }
    }

    /// 删除指定 repo 的 README 缓存。
    func delete(repoId: Int64) async throws {
        try await database.writer.write { db in
            _ = try Readme.deleteOne(db, key: repoId)
        }
    }

    /// 全表清空（设置页"清理缓存"用，已在 W4-4 D4 接入）。
    func deleteAll() async throws {
        try await database.writer.write { db in
            _ = try Readme.deleteAll(db)
        }
    }

    /// 仅更新 `content` 列（向量索引改进 2026-06-12，决策 E3）。
    ///
    /// 用途：`ReadmeAPI.refreshMarkdownIfNeeded(...)` 按需懒补全 raw Markdown 时使用，
    /// 不影响 `rendered_html` / `etag` / `last_modified` / `cached_at` / `size`——
    /// HTML 路径的 SWR 缓存语义保持完整。
    ///
    /// 如果 readmes 行不存在，本方法不会插入（用 UPDATE 而非 UPSERT）：避免在没有
    /// HTML 缓存的情况下落下"只有 markdown 没 HTML"的半行数据，让 WebView 不至于
    /// 误信缓存命中。调用方应在补 Markdown 之前确保 readme 行已存在（HTML 已抓过）。
    func updateContent(repoId: Int64, content: String) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE readmes SET content = ? WHERE repo_id = ?",
                arguments: [content, repoId]
            )
        }
    }

    // MARK: - W4-4 D4：缓存统计

    /// readmes 表行数（设置页"清理缓存"显示当前缓存条目数用）。
    func countAll() async throws -> Int {
        try await database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM readmes") ?? 0
        }
    }

    /// 所有缓存 README 字节总数（基于 `readmes.size` 列）。
    /// 注：size 是 upsert 时写入的 HTML 字节数，等价于 disk 占用的近似量级。
    func totalBytes() async throws -> Int64 {
        try await database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(size), 0) FROM readmes") ?? 0
        }
    }
}
