//
//  RepoTagsSectionViewModelTests.swift
//  StarcatTests
//
//  RepoTagsSectionViewModel 状态机单测（W4 Batch A3）。
//
//  覆盖：loadFor 双流（assigned + allTags） / removeTag / commit 替换式提交 / 错误回显
//

import Testing
import Foundation
@testable import Starcat

@MainActor
@Suite("RepoTagsSectionViewModel")
struct RepoTagsSectionViewModelTests {

    private func makeVM() throws -> (
        RepoTagsSectionViewModel,
        GRDBTagRepository,
        GRDBRepoTagRepository,
        any DatabaseManaging
    ) {
        let db = try InMemoryDatabaseManager()
        let tagRepo = GRDBTagRepository(database: db)
        let rtRepo = GRDBRepoTagRepository(database: db)
        let vm = RepoTagsSectionViewModel(tagRepository: tagRepo, repoTagRepository: rtRepo)
        return (vm, tagRepo, rtRepo, db)
    }

    // MARK: - loadFor

    @Test("loadFor: 空 repo 无标签 + 全局也无标签")
    func loadEmpty() async throws {
        let (vm, _, _, db) = try makeVM()
        try await db.insertRepoFixture(id: 1)
        await vm.loadFor(repoId: 1)
        #expect(vm.assigned.isEmpty)
        #expect(vm.allTags.isEmpty)
        #expect(vm.errorMessage == nil)
    }

    @Test("loadFor: 全局 3 个标签 + repo 关联 1 个 → assigned/allTags 双流正确")
    func loadAssignedAndAll() async throws {
        let (vm, tagRepo, rtRepo, db) = try makeVM()
        try await db.insertRepoFixture(id: 1)
        try await tagRepo.create(.fixture(id: "t-swift", name: "swift", sortOrder: 0))
        try await tagRepo.create(.fixture(id: "t-rust", name: "rust", sortOrder: 1))
        try await tagRepo.create(.fixture(id: "t-ai", name: "ai", sortOrder: 2))
        try await rtRepo.addTag(repoId: 1, tagId: "t-swift")

        await vm.loadFor(repoId: 1)

        #expect(vm.assigned.map(\.id) == ["t-swift"])
        #expect(vm.allTags.count == 3)
    }

    // MARK: - removeTag

    @Test("removeTag: 移除后 assigned 不再包含该标签")
    func removeTagWorks() async throws {
        let (vm, tagRepo, rtRepo, db) = try makeVM()
        try await db.insertRepoFixture(id: 1)
        try await tagRepo.create(.fixture(id: "t-1"))
        try await tagRepo.create(.fixture(id: "t-2"))
        try await rtRepo.addTag(repoId: 1, tagId: "t-1")
        try await rtRepo.addTag(repoId: 1, tagId: "t-2")

        await vm.loadFor(repoId: 1)
        #expect(vm.assigned.count == 2)

        await vm.removeTag(repoId: 1, tagId: "t-1")
        #expect(vm.assigned.map(\.id) == ["t-2"])
    }

    // MARK: - commit (替换式)

    @Test("commit: 用 setTags 替换式，旧标签全部解除 + 新集合落地")
    func commitReplaces() async throws {
        let (vm, tagRepo, rtRepo, db) = try makeVM()
        try await db.insertRepoFixture(id: 1)
        try await tagRepo.create(.fixture(id: "t-a"))
        try await tagRepo.create(.fixture(id: "t-b"))
        try await tagRepo.create(.fixture(id: "t-c"))
        try await rtRepo.addTag(repoId: 1, tagId: "t-a")

        await vm.loadFor(repoId: 1)
        await vm.commit(repoId: 1, tagIds: ["t-b", "t-c"]) // 弃 a、加 b + c

        let final = Set(vm.assigned.map(\.id))
        #expect(final == ["t-b", "t-c"])
    }

    @Test("commit: 空集合 → 清空该 repo 的所有标签")
    func commitEmpty() async throws {
        let (vm, tagRepo, rtRepo, db) = try makeVM()
        try await db.insertRepoFixture(id: 1)
        try await tagRepo.create(.fixture(id: "t-1"))
        try await rtRepo.addTag(repoId: 1, tagId: "t-1")

        await vm.commit(repoId: 1, tagIds: [])
        await vm.loadFor(repoId: 1)
        #expect(vm.assigned.isEmpty)
    }

    // MARK: - Callback

    @Test("onTagsChanged: removeTag 和 commit 都会触发回调")
    func callbackTriggered() async throws {
        let (vm, tagRepo, _, db) = try makeVM()
        try await db.insertRepoFixture(id: 1)
        try await tagRepo.create(.fixture(id: "t-1"))

        var callCount = 0
        vm.onTagsChanged = { callCount += 1 }

        await vm.removeTag(repoId: 1, tagId: "t-1")
        #expect(callCount == 1)

        await vm.commit(repoId: 1, tagIds: ["t-1"])
        #expect(callCount == 2)
    }
}
