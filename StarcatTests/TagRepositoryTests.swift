//
//  TagRepositoryTests.swift
//  StarcatTests
//
//  GRDBTagRepository 单测（W4 Batch A1）。
//
//  覆盖：create / update / delete / find / findByName / fetchAll(排序) / merge(三场景) / name UNIQUE 冲突
//

import Testing
import Foundation
import GRDB
@testable import Starcat

@Suite("GRDBTagRepository")
struct TagRepositoryTests {

    private func makeRepo() throws -> (GRDBTagRepository, any DatabaseManaging) {
        let db = try InMemoryDatabaseManager()
        return (GRDBTagRepository(database: db), db)
    }

    // MARK: - 基础 CRUD

    @Test("create + find: 写入后能查到")
    func createAndFind() async throws {
        let (repo, _) = try makeRepo()
        try await repo.create(.fixture(id: "t-1", name: "swift"))
        let got = try await repo.find(id: "t-1")
        #expect(got?.name == "swift")
        #expect(got?.color == "#FF5722")
    }

    @Test("find: 未命中返回 nil")
    func findMiss() async throws {
        let (repo, _) = try makeRepo()
        let got = try await repo.find(id: "nope")
        #expect(got == nil)
    }

    @Test("findByName: 精确匹配")
    func findByNameHit() async throws {
        let (repo, _) = try makeRepo()
        try await repo.create(.fixture(id: "t-1", name: "swift"))
        try await repo.create(.fixture(id: "t-2", name: "rust"))
        let got = try await repo.findByName("rust")
        #expect(got?.id == "t-2")
    }

    @Test("findByName: 未命中返回 nil")
    func findByNameMiss() async throws {
        let (repo, _) = try makeRepo()
        let got = try await repo.findByName("unknown")
        #expect(got == nil)
    }

    @Test("create: name UNIQUE 冲突会抛 GRDB 错")
    func createDuplicateName() async throws {
        let (repo, _) = try makeRepo()
        try await repo.create(.fixture(id: "t-1", name: "swift"))
        do {
            try await repo.create(.fixture(id: "t-2", name: "swift"))
            Issue.record("期望 UNIQUE 冲突抛错")
        } catch {
            // GRDB.DatabaseError，详细 errorCode 取决于 SQLite 版本，不强约束
        }
    }

    @Test("update: 全字段更新生效")
    func updateAll() async throws {
        let (repo, _) = try makeRepo()
        try await repo.create(.fixture(id: "t-1", name: "swift", color: "#FF5722"))

        var t = try #require(try await repo.find(id: "t-1"))
        t.color = "#0099FF"
        t.icon = "swift"
        t.updatedAt = "2026-05-31T00:00:00Z"
        try await repo.update(t)

        let got = try #require(try await repo.find(id: "t-1"))
        #expect(got.color == "#0099FF")
        #expect(got.icon == "swift")
        #expect(got.updatedAt == "2026-05-31T00:00:00Z")
    }

    @Test("delete: 删除后 find 返 nil")
    func deleteThenFindMiss() async throws {
        let (repo, _) = try makeRepo()
        try await repo.create(.fixture(id: "t-1"))
        try await repo.delete(id: "t-1")
        let got = try await repo.find(id: "t-1")
        #expect(got == nil)
    }

    @Test("fetchAll: 按 sort_order asc 再 name asc 排序")
    func fetchAllOrder() async throws {
        let (repo, _) = try makeRepo()
        try await repo.create(.fixture(id: "t-1", name: "b-tag", sortOrder: 10))
        try await repo.create(.fixture(id: "t-2", name: "a-tag", sortOrder: 0))
        try await repo.create(.fixture(id: "t-3", name: "c-tag", sortOrder: 0))

        let all = try await repo.fetchAll()
        // sort_order=0 优先；同序内按 name 升序：a-tag, c-tag, b-tag
        #expect(all.map(\.id) == ["t-2", "t-3", "t-1"])
    }

    // MARK: - merge

    @Test("merge: source 关联全部转到 target，source 自身被删")
    func mergeBasic() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixture(id: 100)
        try await db.insertRepoFixture(id: 200)
        try await repo.create(.fixture(id: "src", name: "swift-lang"))
        try await repo.create(.fixture(id: "dst", name: "swift"))

        // 直接 SQL 插 repo_tags 避免引 RepoTagRepository 依赖
        try await db.writer.write { db in
            try db.execute(sql: "INSERT INTO repo_tags (repo_id, tag_id, created_at) VALUES (100, 'src', '2026-01-01T00:00:00Z')")
            try db.execute(sql: "INSERT INTO repo_tags (repo_id, tag_id, created_at) VALUES (200, 'src', '2026-01-01T00:00:00Z')")
        }

        try await repo.merge(source: "src", into: "dst")

        // src 不存在
        #expect(try await repo.find(id: "src") == nil)
        // 100/200 现在挂到 dst 名下
        let dstRepos = try await db.writer.read { db in
            try Int64.fetchAll(db, sql: "SELECT repo_id FROM repo_tags WHERE tag_id = 'dst' ORDER BY repo_id")
        }
        #expect(dstRepos == [100, 200])
    }

    @Test("merge: source 与 target 都关联同 repo 时，去重不抛错")
    func mergeDeduplicate() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixture(id: 100)
        try await repo.create(.fixture(id: "src"))
        try await repo.create(.fixture(id: "dst"))
        try await db.writer.write { db in
            try db.execute(sql: "INSERT INTO repo_tags (repo_id, tag_id, created_at) VALUES (100, 'src', '2026-01-01T00:00:00Z')")
            try db.execute(sql: "INSERT INTO repo_tags (repo_id, tag_id, created_at) VALUES (100, 'dst', '2026-01-01T00:00:00Z')")
        }

        try await repo.merge(source: "src", into: "dst")

        // 100 只剩 dst 一条关联（不会因 (100,dst) 已存在而抛 UNIQUE 错）
        let rows = try await db.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM repo_tags WHERE repo_id = 100") ?? 0
        }
        #expect(rows == 1)
    }

    @Test("merge: source == target 时 no-op")
    func mergeSelf() async throws {
        let (repo, _) = try makeRepo()
        try await repo.create(.fixture(id: "t-1"))
        try await repo.merge(source: "t-1", into: "t-1")
        // 标签仍然存在
        #expect(try await repo.find(id: "t-1") != nil)
    }
}
