//
//  TestFixtures.swift
//  StarcatTests
//
//  共享的测试 fixture 构造函数（W4 Batch A1 引入）。
//
//  本文件存在的理由：
//  - 多个 Repository 测试都需要"先插入 repos 行，再插入关联表行"
//    （因为 repo_tags / repo_notes / readmes 都对 repos.id 有外键约束）
//  - 之前 `ReadmeRepositoryTests` 自己手写了 28 列 INSERT；本批 3 个新 Suite 都用到，
//    抽出来避免在每个 Suite 都拷一份
//
//  使用模式：
//  ```swift
//  let db = try InMemoryDatabaseManager()
//  try await db.insertRepoFixture(id: 42)
//  ```
//

import Foundation
import GRDB
@testable import Starcat

extension DatabaseManaging {

    /// 在数据库里插一行最小可工作的 `repos` 记录，仅用于满足外键约束。
    /// 字段值是占位数据，测试若需要真实字段语义请显式 update。
    ///
    /// ⚠️ name 默认含 id（如 `demo-100`）以保证 full_name 唯一；
    /// repos.full_name 是 UNIQUE，调用多次必须保证 id 不同以避免冲突。
    func insertRepoFixture(
        id: Int64,
        owner: String = "octo",
        name: String? = nil,
        starredAt: String? = "2026-05-30T00:00:00Z"
    ) async throws {
        let resolvedName = name ?? "demo-\(id)"
        let fullName = "\(owner)/\(resolvedName)"
        try await writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO repos (
                    id, owner, name, full_name, description, language,
                    stars_count, forks_count, watchers_count, topics, license,
                    homepage, html_url, clone_url, ssh_url,
                    is_private, is_fork, is_archived, is_starred,
                    pushed_at, created_at, updated_at, starred_at, cached_at
                ) VALUES (
                    ?, ?, ?, ?, 'd', 'Swift',
                    0, 0, 0, '[]', NULL,
                    NULL, ?, NULL, NULL,
                    0, 0, 0, 1,
                    NULL, NULL, NULL, ?, '2026-05-30T00:00:00Z'
                )
                """,
                arguments: [id, owner, resolvedName, fullName, "https://github.com/\(fullName)", starredAt]
            )
        }
    }

    /// 批量插 fixture repos（按 id 升序、starredAt 倒序，便于断言排序）。
    func insertRepoFixtures(count: Int, idStart: Int64 = 1) async throws {
        for i in 0..<count {
            let id = idStart + Int64(i)
            // starredAt 用倒计时使早插入的 starred_at 更大（fetchAllStarred 按 desc 排）
            let star = String(format: "2026-05-%02dT00:00:00Z", 30 - i)
            try await insertRepoFixture(id: id, starredAt: star) // name=nil → 自动 "demo-{id}"
        }
    }
}

// MARK: - Tag fixture

extension Tag {
    /// 构造 fixture Tag（id 必填，其余有默认值）。
    static func fixture(
        id: String,
        name: String? = nil,
        color: String? = "#FF5722",
        icon: String? = "tag",
        sortOrder: Int = 0,
        parentId: String? = nil
    ) -> Tag {
        Tag(
            id: id,
            name: name ?? "tag-\(id)",
            color: color,
            icon: icon,
            sortOrder: sortOrder,
            isPreset: false,
            parentId: parentId,
            createdAt: "2026-05-30T00:00:00Z",
            updatedAt: "2026-05-30T00:00:00Z"
        )
    }
}
