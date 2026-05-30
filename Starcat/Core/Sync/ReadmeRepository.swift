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

    private let writer: any DatabaseWriter

    init(database: any DatabaseManaging) {
        self.writer = database.writer
    }

    // MARK: - 查询

    /// 按 repoId 查找 README 缓存。
    /// - Returns: 缓存命中返回 Readme；未命中返回 nil
    func find(repoId: Int64) async throws -> Readme? {
        try await writer.read { db in
            try Readme.fetchOne(db, key: repoId)
        }
    }

    // MARK: - 写入

    /// upsert README 缓存。
    ///
    /// GRDB 的 `MutablePersistableRecord.upsert(_:)` 是 mutating 方法（会回填 rowID），
    /// 因此必须在 closure 内拷贝为 var；外部接口仍可传不可变值。
    func upsert(_ readme: Readme) async throws {
        try await writer.write { db in
            var copy = readme
            try copy.upsert(db)
        }
    }

    /// 仅更新 cached_at（命中 304 时刷新本地缓存有效期判定，不写新 HTML）。
    func touchCachedAt(repoId: Int64, at date: Date) async throws {
        let iso = ISO8601DateFormatter.shared.string(from: date)
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE readmes SET cached_at = ? WHERE repo_id = ?",
                arguments: [iso, repoId]
            )
        }
    }

    /// 删除指定 repo 的 README 缓存。
    func delete(repoId: Int64) async throws {
        try await writer.write { db in
            _ = try Readme.deleteOne(db, key: repoId)
        }
    }

    /// 全表清空（设置页"清理缓存"用，目前未接入 UI）。
    func deleteAll() async throws {
        try await writer.write { db in
            _ = try Readme.deleteAll(db)
        }
    }
}
