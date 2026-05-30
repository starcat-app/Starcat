//
//  HomeViewModelMultiSelectTests.swift
//  StarcatTests
//
//  HomeViewModel 多选模式状态机测试（W4 Batch A5 子集）。
//
//  只覆盖 W4 A5 新加的状态转换；列表加载等老逻辑由 reloadItems 自身测试覆盖。
//

import Testing
import Foundation
@testable import Starcat

@MainActor
@Suite("HomeViewModel multi-select")
struct HomeViewModelMultiSelectTests {

    private func makeVM() throws -> HomeViewModel {
        let db = try InMemoryDatabaseManager()
        let repo = GRDBRepoRepository(database: db)
        let tagRepo = GRDBTagRepository(database: db)
        let rtRepo = GRDBRepoTagRepository(database: db)
        let noteRepo = GRDBRepoNoteRepository(database: db)
        return HomeViewModel(
            repository: repo,
            tagRepository: tagRepo,
            repoTagRepository: rtRepo,
            repoNoteRepository: noteRepo
        )
    }

    @Test("默认非多选 / 选区空")
    func defaultsAreSingleMode() throws {
        let vm = try makeVM()
        #expect(vm.isMultiSelectMode == false)
        #expect(vm.multiSelectedRepoIDs.isEmpty)
    }

    @Test("enter 把当前单选作为多选首项 + 清空单选")
    func enterPromotesSingleSelection() throws {
        let vm = try makeVM()
        vm.selectedRepoID = 42
        vm.enterMultiSelectMode()
        #expect(vm.isMultiSelectMode == true)
        #expect(vm.multiSelectedRepoIDs == [42])
        #expect(vm.selectedRepoID == nil)
    }

    @Test("enter 时无单选 → 多选保持空集")
    func enterEmptyWhenNoSingleSelection() throws {
        let vm = try makeVM()
        vm.enterMultiSelectMode()
        #expect(vm.isMultiSelectMode == true)
        #expect(vm.multiSelectedRepoIDs.isEmpty)
    }

    @Test("exit 清空多选 selection")
    func exitClearsMulti() throws {
        let vm = try makeVM()
        vm.enterMultiSelectMode()
        vm.multiSelectedRepoIDs = [1, 2, 3]
        vm.exitMultiSelectMode()
        #expect(vm.isMultiSelectMode == false)
        #expect(vm.multiSelectedRepoIDs.isEmpty)
    }

    @Test("toggle 行为：单 ↔ 多")
    func toggleSwitches() throws {
        let vm = try makeVM()
        vm.toggleMultiSelectMode()
        #expect(vm.isMultiSelectMode == true)
        vm.toggleMultiSelectMode()
        #expect(vm.isMultiSelectMode == false)
    }
}
