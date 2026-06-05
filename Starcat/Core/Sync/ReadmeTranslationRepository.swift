//
//  ReadmeTranslationRepository.swift
//  Starcat
//
//  README AI 翻译缓存 Repository（HOM-68）。
//
//  模块职责：
//  - 读写 `readme_translations` 表，对应 schema 见 `DatabaseMigrationsV1.createReadmeTranslations`；
//  - 按 `(repo_id, target_language)` 查找 / upsert 单条翻译；
//  - 提供按 repo 删除（重新翻译时可选清空旧译）与按 repo 批量删除（取消 star 兜底，
//    实际 CASCADE 已经在 schema 层挂上，这里只是给上层一个显式入口）。
//
//  关键约束：
//  - 协议化是为了让 Service 层 + 单元测试可以注入 Mock，避免每条用例都要起内存 GRDB。
//  - 写入仍依赖 readmes.repo_id → repos.id 的外键链路：repo 不存在时 upsert 会失败，
//    给调用方一个明确的兜底点，避免「翻译了一个本地不存在的 repo」这种孤儿数据。
//

import Foundation
import GRDB

/// README 翻译缓存协议。
protocol ReadmeTranslationRepositoryProtocol: Sendable {
    /// 查找指定 repo + 目标语言的最新翻译。
    func find(repoId: Int64, targetLanguage: String) async throws -> ReadmeTranslation?

    /// upsert（按 PK `(repo_id, target_language)` 覆盖）。
    func upsert(_ translation: ReadmeTranslation) async throws

    /// 删除指定 repo 在某语言下的翻译（用户「丢弃译文」入口）。
    func delete(repoId: Int64, targetLanguage: String) async throws

    /// 删除指定 repo 的所有语言译文（取消 star / 清缓存兜底）。
    func deleteAll(repoId: Int64) async throws
}

/// GRDB 实现。
struct GRDBReadmeTranslationRepository: ReadmeTranslationRepositoryProtocol {

    private let writer: any DatabaseWriter

    init(database: any DatabaseManaging) {
        self.writer = database.writer
    }

    func find(repoId: Int64, targetLanguage: String) async throws -> ReadmeTranslation? {
        try await writer.read { db in
            try ReadmeTranslation.fetchOne(db, sql: """
                SELECT * FROM readme_translations
                WHERE repo_id = ? AND target_language = ?
                """, arguments: [repoId, targetLanguage])
        }
    }

    func upsert(_ translation: ReadmeTranslation) async throws {
        try await writer.write { db in
            var copy = translation
            try copy.upsert(db)
        }
    }

    func delete(repoId: Int64, targetLanguage: String) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                DELETE FROM readme_translations
                WHERE repo_id = ? AND target_language = ?
                """, arguments: [repoId, targetLanguage])
        }
    }

    func deleteAll(repoId: Int64) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "DELETE FROM readme_translations WHERE repo_id = ?",
                arguments: [repoId]
            )
        }
    }
}
