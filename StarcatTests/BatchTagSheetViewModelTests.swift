//
//  BatchTagSheetViewModelTests.swift
//  StarcatTests
//
//  BatchTagSheetViewModel 单测（W4 Batch A5 子集）。
//

import Testing
import Foundation
@testable import Starcat

@MainActor
@Suite("BatchTagSheetViewModel")
struct BatchTagSheetViewModelTests {

    private func makeVM() throws -> (
        BatchTagSheetViewModel,
        GRDBTagRepository,
        GRDBRepoTagRepository,
        any DatabaseManaging
    ) {
        let db = try InMemoryDatabaseManager()
        let tagRepo = GRDBTagRepository(database: db)
        let rtRepo = GRDBRepoTagRepository(database: db)
        let vm = BatchTagSheetViewModel(tagRepository: tagRepo, repoTagRepository: rtRepo)
        return (vm, tagRepo, rtRepo, db)
    }

    @Test("loadTags: 拉取所有可用标签")
    func loadTagsBasic() async throws {
        let (vm, tagRepo, _, _) = try makeVM()
        try await tagRepo.create(.fixture(id: "t-1"))
        try await tagRepo.create(.fixture(id: "t-2"))
        await vm.loadTags()
        #expect(vm.tags.count == 2)
    }

    @Test("apply: 给 3 个 repo 批量加同一 tag → 全部关联成功")
    func applyAddsTagToAllRepos() async throws {
        let (vm, tagRepo, rtRepo, db) = try makeVM()
        try await db.insertRepoFixture(id: 10)
        try await db.insertRepoFixture(id: 11)
        try await db.insertRepoFixture(id: 12)
        try await tagRepo.create(.fixture(id: "tg"))

        let ok = await vm.apply(repoIds: [10, 11, 12], tagIds: ["tg"])
        #expect(ok == true)

        let count = try await rtRepo.repoCount(forTag: "tg")
        #expect(count == 3)
    }

    @Test("apply: 已有该 tag 的 repo 不会出现 UNIQUE 冲突（idempotent）")
    func applyIsIdempotent() async throws {
        let (vm, tagRepo, rtRepo, db) = try makeVM()
        try await db.insertRepoFixture(id: 1)
        try await db.insertRepoFixture(id: 2)
        try await tagRepo.create(.fixture(id: "tg"))
        try await rtRepo.addTag(repoId: 1, tagId: "tg") // 1 已经有了

        let ok = await vm.apply(repoIds: [1, 2], tagIds: ["tg"])
        #expect(ok == true)
        let count = try await rtRepo.repoCount(forTag: "tg")
        #expect(count == 2)
    }

    @Test("apply: 空 repoIds 也成功（no-op）")
    func applyEmptyRepoIds() async throws {
        let (vm, tagRepo, _, _) = try makeVM()
        try await tagRepo.create(.fixture(id: "tg"))
        let ok = await vm.apply(repoIds: [], tagIds: ["tg"])
        #expect(ok == true)
        #expect(vm.errorMessage == nil)
    }
}
