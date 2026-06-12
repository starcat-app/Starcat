//
//  RepoNotesSectionViewModelTests.swift
//  StarcatTests
//
//  RepoNotesSectionViewModel 单测（W4 Batch A4）。
//
//  覆盖：loadFor / setStatus / saveContent（空串归 nil）/ status 派生 / 错误回显
//

import Testing
import Foundation
@testable import Starcat

@MainActor
@Suite("RepoNotesSectionViewModel")
struct RepoNotesSectionViewModelTests {

    private func makeVM() throws -> (RepoNotesSectionViewModel, GRDBRepoNoteRepository, any DatabaseManaging) {
        let db = try InMemoryDatabaseManager()
        let repo = GRDBRepoNoteRepository(database: db)
        let vm = RepoNotesSectionViewModel(repoNoteRepository: repo)
        return (vm, repo, db)
    }

    @Test("loadFor: 无笔记 → note 为 nil、status 为 nil、无错")
    func loadMissing() async throws {
        let (vm, _, db) = try makeVM()
        try await db.insertRepoFixture(id: 1)
        await vm.loadFor(repoId: 1)
        #expect(vm.note == nil)
        #expect(vm.status == nil)
        #expect(vm.errorMessage == nil)
    }

    @Test("setStatus: 首次设置 → 自动创建 row + status 派生正确")
    func setStatusCreatesRow() async throws {
        let (vm, _, db) = try makeVM()
        try await db.insertRepoFixture(id: 1)

        await vm.setStatus(repoId: 1, status: .using)
        #expect(vm.note?.status == "using")
        #expect(vm.status == .using)
    }

    @Test("setStatus: 切换状态 → 老 content 不丢")
    func setStatusKeepsContent() async throws {
        let (vm, _, db) = try makeVM()
        try await db.insertRepoFixture(id: 1)
        await vm.saveContent(repoId: 1, content: "已有笔记")
        await vm.setStatus(repoId: 1, status: .using)
        #expect(vm.note?.status == "using")
        #expect(vm.note?.content == "已有笔记")
    }

    @Test("saveContent: 写入 + 重新加载 → content 一致")
    func saveContentBasic() async throws {
        let (vm, _, db) = try makeVM()
        try await db.insertRepoFixture(id: 1)
        await vm.saveContent(repoId: 1, content: "this is a note")
        #expect(vm.note?.content == "this is a note")
    }

    @Test("saveContent: 空字符串归一为 nil，保留行（status 仍存在）")
    func saveContentEmptyNormalized() async throws {
        let (vm, _, db) = try makeVM()
        try await db.insertRepoFixture(id: 1)
        await vm.saveContent(repoId: 1, content: "first")
        await vm.setStatus(repoId: 1, status: .using)

        await vm.saveContent(repoId: 1, content: "")
        #expect(vm.note?.content == nil)
        #expect(vm.note?.status == "using") // 行还在
    }

    @Test("status 派生：DB 存 v1 旧值 reading/deprecated → 派生为 .read（lenient）")
    func statusDerivationLegacyValues() async throws {
        let (vm, repo, db) = try makeVM()
        try await db.insertRepoFixtures(count: 2, idStart: 1)

        // 通过底层 upsert 直接写入 v1 旧值（模拟存量数据）。
        try await repo.upsert(RepoNote(
            repoId: 1, content: nil, status: "reading",
            isAIGenerated: false, editedAt: nil
        ))
        try await repo.upsert(RepoNote(
            repoId: 2, content: nil, status: "deprecated",
            isAIGenerated: false, editedAt: nil
        ))

        await vm.loadFor(repoId: 1)
        #expect(vm.status == .read)
        await vm.loadFor(repoId: 2)
        #expect(vm.status == .read)
    }

    @Test("markAsReadIfNeeded: 无 note → 创建 read 行；using 不被覆盖")
    func markAsReadFlow() async throws {
        let (vm, _, db) = try makeVM()
        try await db.insertRepoFixtures(count: 2, idStart: 1)

        // repo 1：无 note → markAsReadIfNeeded 创建 read 行
        await vm.markAsReadIfNeeded(repoId: 1)
        #expect(vm.status == .read)

        // repo 2：先 using，markAsReadIfNeeded 不下行
        await vm.setStatus(repoId: 2, status: .using)
        await vm.markAsReadIfNeeded(repoId: 2)
        #expect(vm.status == .using)
    }
}
