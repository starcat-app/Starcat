//
//  RepoTagRepositoryTests.swift
//  StarcatTests
//
//  GRDBRepoTagRepository 单测（W4 Batch A1）。
//
//  覆盖：addTag(+幂等) / removeTag / setTags(替换式) / batchAddTag / fetchTagIds /
//  fetchTags(JOIN 排序) / fetchRepos / repoCount / repoCountsByTag
//

import Testing
import Foundation
import GRDB
@testable import Starcat

@Suite("GRDBRepoTagRepository")
struct RepoTagRepositoryTests {

    private func makeRepos() throws -> (
        GRDBRepoTagRepository,
        GRDBTagRepository,
        any DatabaseManaging
    ) {
        let db = try InMemoryDatabaseManager()
        return (
            GRDBRepoTagRepository(database: db),
            GRDBTagRepository(database: db),
            db
        )
    }

    /// 建 3 个 repo + 3 个 tag fixture。
    private func seed(
        repoTag: GRDBRepoTagRepository,
        tag: GRDBTagRepository,
        db: any DatabaseManaging
    ) async throws {
        try await db.insertRepoFixtures(count: 3, idStart: 1)
        try await tag.create(.fixture(id: "t-swift", name: "swift", sortOrder: 0))
        try await tag.create(.fixture(id: "t-rust", name: "rust", sortOrder: 1))
        try await tag.create(.fixture(id: "t-ai", name: "ai", sortOrder: 2))
    }

    // MARK: - addTag

    @Test("addTag: 写入 + 幂等（重复 add 不抛错）")
    func addTagIdempotent() async throws {
        let (rt, tag, db) = try makeRepos()
        try await seed(repoTag: rt, tag: tag, db: db)

        try await rt.addTag(repoId: 1, tagId: "t-swift")
        try await rt.addTag(repoId: 1, tagId: "t-swift") // 第二次：INSERT OR IGNORE 不报错

        let ids = try await rt.fetchTagIds(forRepo: 1)
        #expect(ids == ["t-swift"]) // 仍只有一条
    }

    // MARK: - removeTag

    @Test("removeTag: 删除关联")
    func removeTag() async throws {
        let (rt, tag, db) = try makeRepos()
        try await seed(repoTag: rt, tag: tag, db: db)

        try await rt.addTag(repoId: 1, tagId: "t-swift")
        try await rt.addTag(repoId: 1, tagId: "t-rust")
        try await rt.removeTag(repoId: 1, tagId: "t-swift")

        let ids = try await rt.fetchTagIds(forRepo: 1)
        #expect(ids == ["t-rust"])
    }

    @Test("removeTag: 不存在的关联 no-op")
    func removeMissingNoop() async throws {
        let (rt, tag, db) = try makeRepos()
        try await seed(repoTag: rt, tag: tag, db: db)
        try await rt.removeTag(repoId: 1, tagId: "t-swift") // 没存过也不抛
    }

    // MARK: - setTags

    @Test("setTags: 替换式覆盖（先删后插）")
    func setTagsReplace() async throws {
        let (rt, tag, db) = try makeRepos()
        try await seed(repoTag: rt, tag: tag, db: db)

        try await rt.addTag(repoId: 1, tagId: "t-swift")
        try await rt.addTag(repoId: 1, tagId: "t-rust")
        try await rt.setTags(repoId: 1, tagIds: ["t-ai"]) // 完整替换

        let ids = try await rt.fetchTagIds(forRepo: 1)
        #expect(ids == ["t-ai"])
    }

    @Test("setTags: 传空数组 = 清空该 repo 的标签")
    func setTagsEmpty() async throws {
        let (rt, tag, db) = try makeRepos()
        try await seed(repoTag: rt, tag: tag, db: db)

        try await rt.addTag(repoId: 1, tagId: "t-swift")
        try await rt.setTags(repoId: 1, tagIds: [])

        let ids = try await rt.fetchTagIds(forRepo: 1)
        #expect(ids.isEmpty)
    }

    // MARK: - batchAddTag

    @Test("batchAddTag: 批量给多个 repo 加同一标签")
    func batchAdd() async throws {
        let (rt, tag, db) = try makeRepos()
        try await seed(repoTag: rt, tag: tag, db: db)

        try await rt.batchAddTag(repoIds: [1, 2, 3], tagId: "t-swift")

        let count = try await rt.repoCount(forTag: "t-swift")
        #expect(count == 3)
    }

    @Test("batchAddTag: 已存在关系跳过（INSERT OR IGNORE）")
    func batchAddIdempotent() async throws {
        let (rt, tag, db) = try makeRepos()
        try await seed(repoTag: rt, tag: tag, db: db)

        try await rt.addTag(repoId: 2, tagId: "t-swift")
        try await rt.batchAddTag(repoIds: [1, 2, 3], tagId: "t-swift") // 2 已存在

        let count = try await rt.repoCount(forTag: "t-swift")
        #expect(count == 3) // 1+2+3 三条，重复的 2 不会变成 4
    }

    // MARK: - fetchTags (JOIN 排序)

    @Test("fetchTags: 按 tag 表 sort_order asc → name asc 排序")
    func fetchTagsSorted() async throws {
        let (rt, tag, db) = try makeRepos()
        try await seed(repoTag: rt, tag: tag, db: db)

        try await rt.addTag(repoId: 1, tagId: "t-ai")    // sortOrder=2
        try await rt.addTag(repoId: 1, tagId: "t-swift") // sortOrder=0
        try await rt.addTag(repoId: 1, tagId: "t-rust")  // sortOrder=1

        let tags = try await rt.fetchTags(forRepo: 1)
        #expect(tags.map(\.id) == ["t-swift", "t-rust", "t-ai"])
    }

    // MARK: - fetchRepos

    @Test("fetchRepos: 返回某标签下的 starred repo")
    func fetchReposByTag() async throws {
        let (rt, tag, db) = try makeRepos()
        try await seed(repoTag: rt, tag: tag, db: db)

        try await rt.addTag(repoId: 1, tagId: "t-swift")
        try await rt.addTag(repoId: 3, tagId: "t-swift")

        let repos = try await rt.fetchRepos(forTag: "t-swift")
        // 按 starred_at desc：seed 中 id=1 的 starredAt 更新（2026-05-30），id=3 更早
        #expect(repos.map(\.id) == [1, 3])
    }

    @Test("fetchRepos: 排除 is_starred=0 的 repo（用户取消 star 后不出现）")
    func fetchReposSkipUnstarred() async throws {
        let (rt, tag, db) = try makeRepos()
        try await seed(repoTag: rt, tag: tag, db: db)

        try await rt.addTag(repoId: 1, tagId: "t-swift")
        try await rt.addTag(repoId: 2, tagId: "t-swift")
        // 把 repo 2 标记为已取消 star
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE repos SET is_starred = 0 WHERE id = 2")
        }

        let repos = try await rt.fetchRepos(forTag: "t-swift")
        #expect(repos.map(\.id) == [1])
    }

    // MARK: - count

    @Test("repoCount: 仅计 starred 的 repo")
    func repoCountStarredOnly() async throws {
        let (rt, tag, db) = try makeRepos()
        try await seed(repoTag: rt, tag: tag, db: db)

        try await rt.addTag(repoId: 1, tagId: "t-swift")
        try await rt.addTag(repoId: 2, tagId: "t-swift")
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE repos SET is_starred = 0 WHERE id = 2")
        }

        let count = try await rt.repoCount(forTag: "t-swift")
        #expect(count == 1) // 只算 repo 1
    }

    @Test("repoCountsByTag: 一次 group by 拉所有 tag 的 count")
    func repoCountsByTagBulk() async throws {
        let (rt, tag, db) = try makeRepos()
        try await seed(repoTag: rt, tag: tag, db: db)

        try await rt.addTag(repoId: 1, tagId: "t-swift")
        try await rt.addTag(repoId: 2, tagId: "t-swift")
        try await rt.addTag(repoId: 3, tagId: "t-rust")

        let counts = try await rt.repoCountsByTag()
        #expect(counts["t-swift"] == 2)
        #expect(counts["t-rust"] == 1)
        #expect(counts["t-ai"] == nil) // 没有关联的 tag 不出现在结果里
    }
}
