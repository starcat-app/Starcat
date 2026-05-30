//
//  TagManagementViewModelTests.swift
//  StarcatTests
//
//  TagManagementViewModel 状态机单测（W4 Batch A2）。
//
//  策略：注入真实 GRDB Repository + InMemoryDatabaseManager，
//  不走 Mock。理由：
//  - ViewModel 与 Repository 协同的关键场景（trim / 唯一性 / 合并）
//    需要真实 SQL 语义，Mock 会失真
//  - InMemoryDatabaseManager 已成熟，0 IO 开销
//
//  覆盖：
//  - loadAll：tags + counts 双流并发拉取
//  - create：trim、空字符串拒绝、UNIQUE 重名拒绝、自动选中
//  - update：trim、改名同重检查、保持原名放行
//  - delete：单 / 多删、selection 清理
//  - merge：基本合并、target 自动收敛 selection
//

import Testing
import Foundation
import GRDB
@testable import Starcat

@MainActor
@Suite("TagManagementViewModel")
struct TagManagementViewModelTests {

    private func makeVM() throws -> (TagManagementViewModel, GRDBTagRepository, GRDBRepoTagRepository, any DatabaseManaging) {
        let db = try InMemoryDatabaseManager()
        let tagRepo = GRDBTagRepository(database: db)
        let rtRepo = GRDBRepoTagRepository(database: db)
        let vm = TagManagementViewModel(tagRepository: tagRepo, repoTagRepository: rtRepo)
        return (vm, tagRepo, rtRepo, db)
    }

    // MARK: - loadAll

    @Test("loadAll: 空库 → tags 空、counts 空、无错")
    func loadAllEmpty() async throws {
        let (vm, _, _, _) = try makeVM()
        await vm.loadAll()
        #expect(vm.tags.isEmpty)
        #expect(vm.counts.isEmpty)
        #expect(vm.errorMessage == nil)
        #expect(vm.isLoading == false)
    }

    @Test("loadAll: 拉取已有标签 + 计数")
    func loadAllPopulated() async throws {
        let (vm, tagRepo, rtRepo, db) = try makeVM()
        try await db.insertRepoFixture(id: 1)
        try await tagRepo.create(.fixture(id: "t-1", name: "swift"))
        try await tagRepo.create(.fixture(id: "t-2", name: "rust"))
        try await rtRepo.addTag(repoId: 1, tagId: "t-1")

        await vm.loadAll()

        #expect(vm.tags.count == 2)
        #expect(vm.counts["t-1"] == 1)
        #expect(vm.counts["t-2"] == nil) // 没关联的 tag 不在 counts
    }

    // MARK: - create

    @Test("create: 正常创建 + 自动选中新建项")
    func createBasic() async throws {
        let (vm, _, _, _) = try makeVM()
        let ok = await vm.create(name: "swift", color: "#0A84FF", icon: "tag")
        #expect(ok == true)
        #expect(vm.tags.count == 1)
        #expect(vm.tags[0].name == "swift")
        #expect(vm.selection.count == 1)
        #expect(vm.selection.first == vm.tags[0].id)
    }

    @Test("create: 自动 trim 前后空格")
    func createTrimsWhitespace() async throws {
        let (vm, _, _, _) = try makeVM()
        let ok = await vm.create(name: "  swift  ", color: nil, icon: nil)
        #expect(ok == true)
        #expect(vm.tags[0].name == "swift")
    }

    @Test("create: 空 / 纯空白字符串拒绝")
    func createRejectsEmpty() async throws {
        let (vm, _, _, _) = try makeVM()
        let ok = await vm.create(name: "   ", color: nil, icon: nil)
        #expect(ok == false)
        #expect(vm.errorMessage?.contains("不能为空") == true)
        #expect(vm.tags.isEmpty)
    }

    @Test("create: 重名拒绝（UI 友好检查，不抛 GRDB 错）")
    func createRejectsDuplicate() async throws {
        let (vm, _, _, _) = try makeVM()
        _ = await vm.create(name: "swift", color: nil, icon: nil)
        let ok = await vm.create(name: "swift", color: nil, icon: nil)
        #expect(ok == false)
        #expect(vm.errorMessage?.contains("已存在") == true)
        #expect(vm.tags.count == 1)
    }

    // MARK: - update

    @Test("update: 改 color / icon 成功")
    func updateColorAndIcon() async throws {
        let (vm, _, _, _) = try makeVM()
        _ = await vm.create(name: "swift", color: "#0A84FF", icon: "tag")
        let tag = try #require(vm.tags.first)

        let ok = await vm.update(tag, name: "swift", color: "#FF453A", icon: "star")
        #expect(ok == true)

        let updated = try #require(vm.tags.first)
        #expect(updated.color == "#FF453A")
        #expect(updated.icon == "star")
    }

    @Test("update: 保持原名允许通过（不触发重名检查）")
    func updateKeepNameAllowed() async throws {
        let (vm, _, _, _) = try makeVM()
        _ = await vm.create(name: "swift", color: nil, icon: nil)
        let tag = try #require(vm.tags.first)
        let ok = await vm.update(tag, name: "swift", color: "#000000", icon: nil)
        #expect(ok == true)
    }

    @Test("update: 改名撞他人标签 → 拒绝")
    func updateRenameDuplicate() async throws {
        let (vm, _, _, _) = try makeVM()
        _ = await vm.create(name: "swift", color: nil, icon: nil)
        _ = await vm.create(name: "rust", color: nil, icon: nil)
        let swift = try #require(vm.tags.first { $0.name == "swift" })

        let ok = await vm.update(swift, name: "rust", color: nil, icon: nil)
        #expect(ok == false)
        #expect(vm.errorMessage?.contains("已存在") == true)
    }

    // MARK: - delete

    @Test("delete: 多个 id 一次删 + selection 自动收缩")
    func deleteMultiple() async throws {
        let (vm, _, _, _) = try makeVM()
        _ = await vm.create(name: "swift", color: nil, icon: nil)
        _ = await vm.create(name: "rust", color: nil, icon: nil)
        _ = await vm.create(name: "ai", color: nil, icon: nil)
        // fetchAll 按 sort_order asc → name asc 排序，
        // 三个 sort_order 都是 0，故顺序：ai, rust, swift。

        // 删前 2 个（"ai" + "rust"），剩 "swift"
        let toDelete: Set<String> = Set(vm.tags.prefix(2).map(\.id))
        vm.selection = toDelete
        await vm.delete(ids: toDelete)

        #expect(vm.tags.count == 1)
        #expect(vm.tags[0].name == "swift")
        #expect(vm.selection.isEmpty)
    }

    // MARK: - merge

    @Test("merge: 把 source 合并到 target，关联自动转移")
    func mergeBasic() async throws {
        let (vm, _, rtRepo, db) = try makeVM()
        try await db.insertRepoFixture(id: 100)
        _ = await vm.create(name: "swift-lang", color: nil, icon: nil) // source
        _ = await vm.create(name: "swift", color: nil, icon: nil)      // target
        let source = try #require(vm.tags.first { $0.name == "swift-lang" })
        let target = try #require(vm.tags.first { $0.name == "swift" })
        try await rtRepo.addTag(repoId: 100, tagId: source.id)

        await vm.merge(sources: [source.id, target.id], into: target.id)

        // 现在只剩 target
        #expect(vm.tags.map(\.name) == ["swift"])
        // 关联转移成功
        let countsAfter = try await rtRepo.repoCount(forTag: target.id)
        #expect(countsAfter == 1)
        // selection 收敛到 target
        #expect(vm.selection == [target.id])
    }

    // MARK: - 派生

    @Test("singleSelected / canMerge 派生")
    func derivedFlags() async throws {
        let (vm, _, _, _) = try makeVM()
        _ = await vm.create(name: "a", color: nil, icon: nil)
        _ = await vm.create(name: "b", color: nil, icon: nil)
        let a = try #require(vm.tags.first { $0.name == "a" })
        let b = try #require(vm.tags.first { $0.name == "b" })

        vm.selection = []
        #expect(vm.singleSelected == nil)
        #expect(vm.canMerge == false)

        vm.selection = [a.id]
        #expect(vm.singleSelected?.id == a.id)
        #expect(vm.canMerge == false)

        vm.selection = [a.id, b.id]
        #expect(vm.singleSelected == nil)
        #expect(vm.canMerge == true)
    }
}
