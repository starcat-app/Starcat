//
//  SkillWorkspaceSnapshotTests.swift
//  StarcatTests
//
//  验证本机库快照的身份、筛选与选择边界。全部数据来自确定性夹具，
//  不读取本机 Agent 目录，也不创建原生窗口。
//

import Foundation
import Testing
@testable import Starcat

/// 对同名、共享与部分失败作业务断言，避免列表行为仅靠 Preview 人工发现。
@Suite("Skill 工作台快照")
@MainActor
struct SkillWorkspaceSnapshotTests {
    @Test("同名不同来源保持独立")
    func sameNameDoesNotMergeSources() {
        let model = makeModel()
        model.searchText = "release-notes"
        #expect(model.visibleItems.count == 2)
        #expect(Set(model.visibleItems.map(\.id)).count == 2)
        #expect(Set(model.visibleItems.compactMap(\.source)).count == 2)
    }

    @Test("库筛选使用明确所有权及诊断", arguments: [
        (SkillWorkspaceFilter.all, 4), (.managed, 2), (.external, 2), (.updates, 1), (.attention, 1)
    ])
    func libraryFilters(expected: (SkillWorkspaceFilter, Int)) {
        let model = makeModel()
        model.navigation = .library(expected.0)
        #expect(model.visibleItems.count == expected.1)
        #expect(model.filterCounts[expected.0] == expected.1)
    }

    @Test("共享根在每个相关 Agent 可见，但物理条目不重复")
    func sharedEntryHasMultipleExposures() throws {
        let model = makeModel()
        model.navigation = .agent("Codex")
        #expect(model.visibleItems.count == 2)
        model.navigation = .agent("OpenCode")
        let shared = try #require(model.visibleItems.first)
        #expect(model.visibleItems.count == 1)
        #expect(shared.locations.count == 1)
        #expect(shared.locations.first?.isShared == true)
        #expect(model.filterCounts[.all] == 4)
    }

    @Test("搜索覆盖来源并忽略大小写与变音符号")
    func searchUsesMetadataAndSource() {
        let model = makeModel()
        model.searchText = " resume "
        #expect(model.visibleItems.count == 1)
        model.searchText = "GITHUB.COM/EXAMPLE"
        #expect(model.visibleItems.count == 1)
        #expect(model.visibleItems.first?.managementKind == .external)
    }

    @Test("筛选收敛选择，屏幕外条目不进入后续批量操作")
    func filterPrunesHiddenSelection() {
        let model = makeModel()
        model.selectedIDs = Set(model.items.map(\.id))
        model.searchText = "release-notes"
        #expect(model.selectedIDs.count == 2)
        model.navigation = .library(.external)
        #expect(model.selectedIDs.count == 1)
        #expect(model.selectedItem?.managementKind == .external)
    }

    @Test("失败保留上次快照和已选条目")
    func failurePreservesSnapshot() throws {
        let model = makeModel()
        let first = try #require(model.items.first)
        model.selectedIDs = [first.id]
        model.setLoadState(.failed("Permission denied"))
        #expect(model.items.count == 4)
        #expect(model.visibleItems.count == 4)
        #expect(model.selectedItem?.id == first.id)
        #expect(model.loadState == .failed("Permission denied"))
    }

    @Test("快照重排保留身份，删除已选条目后清空详情")
    func snapshotReconcilesSelection() throws {
        let model = makeModel()
        let first = try #require(model.items.first)
        model.selectedIDs = [first.id]
        model.applySnapshot(Array(model.items.reversed()))
        #expect(model.selectedItem?.id == first.id)
        model.applySnapshot(model.items.filter { $0.id != first.id })
        #expect(model.selectedIDs.isEmpty)
        #expect(model.selectedItem == nil)
    }

    @Test("生产模型不包含 Preview 样例")
    func productionModelStartsEmpty() {
        let model = SkillWorkspaceViewModel()
        #expect(model.items.isEmpty)
        #expect(model.visibleItems.isEmpty)
        #expect(model.agentNames.isEmpty)
        #expect(model.sources.isEmpty)
    }

    private func makeModel() -> SkillWorkspaceViewModel {
        let model = SkillWorkspaceViewModel()
        model.applySnapshot(SkillWorkspacePreviewFixtures.items())
        return model
    }
}
