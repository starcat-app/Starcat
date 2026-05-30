//
//  TagRepository.swift
//  Starcat
//
//  Tag 持久化 Repository（GRDB 实现）。
//
//  ⚠️ 命名约定（与 D-01 RepoRepository 一致）：
//  - 内部 struct 名 `GRDBTagRepository`（实现）
//  - 协议层抽象 `TagRepositoryProtocol`（见 `TagRepositoryProtocol.swift`）
//  - 调用方依赖 `any TagRepositoryProtocol`，仅 AppDependencies / 测试构造时用具体类型
//
//  schema 对照（DatabaseMigrationsV1.createTags）：
//    id TEXT PK | name TEXT UNIQUE NOT NULL | color TEXT | icon TEXT
//    sort_order INTEGER NOT NULL DEFAULT 0 | is_preset BOOLEAN DEFAULT 0
//    parent_id TEXT REFERENCES tags(id) ON DELETE SET NULL
//    created_at TEXT NOT NULL | updated_at TEXT NOT NULL
//

import Foundation
import GRDB

struct GRDBTagRepository {

    private let writer: any DatabaseWriter

    init(database: any DatabaseManaging) {
        self.writer = database.writer
    }

    // MARK: - 写入

    func create(_ tag: Tag) async throws {
        try await writer.write { db in
            var copy = tag
            try copy.insert(db) // 用 insert 而非 save：保证 name 冲突时显式抛错
        }
    }

    /// 全字段 update。调用方应保证 tag.id 存在；不存在视为脏数据由 GRDB 抛错。
    func update(_ tag: Tag) async throws {
        try await writer.write { db in
            try tag.update(db)
        }
    }

    func delete(id: String) async throws {
        try await writer.write { db in
            _ = try Tag.deleteOne(db, key: id)
        }
    }

    /// 把 source 合并到 target：
    /// 1. 把 source 的所有 repo_tags 关联挪到 target（用 INSERT OR IGNORE 处理 (repo,target) 已存在的情形）
    /// 2. 删除 source 的所有 repo_tags（CASCADE 会自动清，但走 step 1 时已 reassign，保险起见显式 DELETE）
    /// 3. 删除 source 标签本身
    /// 全部在一个事务内，要么全成要么全回滚。
    func merge(source: String, into target: String) async throws {
        guard source != target else { return } // 自合并 no-op
        try await writer.write { db in
            // 校验 target 存在（否则 INSERT OR IGNORE 也会因 FK 失败）
            let targetExists = try Tag.fetchOne(db, key: target) != nil
            guard targetExists else {
                throw DatabaseError.openFailed(underlying: NSError(
                    domain: "TagRepository",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "merge 目标标签不存在: \(target)"]
                ))
            }

            // 1. reassign repo_tags：用 INSERT OR IGNORE + 子查询
            //    把 source 名下每条 (repo_id, source) 转写为 (repo_id, target)，
            //    若 (repo_id, target) 已存在则 OR IGNORE 跳过
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO repo_tags (repo_id, tag_id, created_at)
                SELECT repo_id, ?, created_at FROM repo_tags WHERE tag_id = ?
                """,
                arguments: [target, source]
            )

            // 2. 删 source 的所有关联（reassign 完成）
            try db.execute(
                sql: "DELETE FROM repo_tags WHERE tag_id = ?",
                arguments: [source]
            )

            // 3. 删 source tag 自身
            _ = try Tag.deleteOne(db, key: source)
        }
    }

    // MARK: - 查询

    func find(id: String) async throws -> Tag? {
        try await writer.read { db in
            try Tag.fetchOne(db, key: id)
        }
    }

    func findByName(_ name: String) async throws -> Tag? {
        try await writer.read { db in
            try Tag.filter(Column("name") == name).fetchOne(db)
        }
    }

    /// 按 sort_order asc → name asc 排序的全部标签。
    /// 100 量级以内 fetchAll 直接返回；超过 1000 再考虑分页。
    func fetchAll() async throws -> [Tag] {
        try await writer.read { db in
            try Tag
                .order(Column("sort_order").asc, Column("name").asc)
                .fetchAll(db)
        }
    }
}
