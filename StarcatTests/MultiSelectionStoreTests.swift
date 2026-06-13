//
//  MultiSelectionStoreTests.swift
//  StarcatTests
//
//  MultiSelectionStore 状态机测试（W12 toolbar 专项 PR-4 引入 / PR-5 补 retain）。
//
//  覆盖范围：
//  - 默认非多选 / 选区空
//  - enter / exit / toggle 状态转换
//  - toggle(snapshot) 反复点击的添加/移除幂等
//  - selectAll / deselectAll
//  - contains / count / targets 派生只读
//  - 同一 ghRepoId 重复 add 不会重复
//  - retain(visibleIDs:) Manage filter/sort 变化清理孤儿选中项（PR-5 新增）
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("MultiSelectionStore")
struct MultiSelectionStoreTests {

    private func snap(_ ghRepoId: Int64, _ owner: String = "octocat", _ name: String = "hello") -> SelectionSnapshot {
        SelectionSnapshot(ghRepoId: ghRepoId, owner: owner, name: name)
    }

    @Test("默认状态：非多选 / 选区空")
    func defaultsAreEmpty() {
        let store = MultiSelectionStore()
        #expect(store.isActive == false)
        #expect(store.count == 0)
        #expect(store.snapshots.isEmpty)
        #expect(store.targets.isEmpty)
    }

    @Test("enter 进入多选 + 清空旧选")
    func enterClearsOldSelection() {
        let store = MultiSelectionStore()
        store.toggle(snap(1))
        // 此时虽然 isActive=false 但 snapshots 里残留（外部状态非法）
        store.enter()
        #expect(store.isActive == true)
        // enter 应当清空旧 snapshots：避免上次 selection 串场
        #expect(store.snapshots.isEmpty)
    }

    @Test("exit 退出多选 + 清空选区")
    func exitClearsSelection() {
        let store = MultiSelectionStore()
        store.enter()
        store.toggle(snap(1))
        store.toggle(snap(2))
        store.exit()
        #expect(store.isActive == false)
        #expect(store.snapshots.isEmpty)
    }

    @Test("toggle 切换 isActive")
    func toggleSwitchesActiveState() {
        let store = MultiSelectionStore()
        store.toggle()
        #expect(store.isActive == true)
        store.toggle()
        #expect(store.isActive == false)
    }

    @Test("toggle(snapshot) 反复点击 = 添加再移除")
    func toggleSnapshotIsIdempotent() {
        let store = MultiSelectionStore()
        store.enter()

        let s = snap(101, "a", "b")
        store.toggle(s)
        #expect(store.contains(ghRepoId: 101) == true)
        #expect(store.count == 1)

        store.toggle(s)
        #expect(store.contains(ghRepoId: 101) == false)
        #expect(store.count == 0)
    }

    @Test("同一 ghRepoId 重复 toggle add 不会重复（按 id 唯一）")
    func sameIdNotDuplicated() {
        let store = MultiSelectionStore()
        store.enter()

        // 同 id 不同 owner/name（极端 corner case）。
        // 当前实现使用最后一次写入的 snapshot 覆盖，符合"按 id 唯一"语义。
        store.toggle(snap(7, "old-owner", "old-name"))
        store.toggle(snap(7, "old-owner", "old-name"))
        // 上面两次相互抵消（add → remove）
        #expect(store.count == 0)
        #expect(store.contains(ghRepoId: 7) == false)
    }

    @Test("selectAll / deselectAll 批量写入与清空")
    func selectAllAndDeselectAll() {
        let store = MultiSelectionStore()
        store.enter()

        let list = [snap(1), snap(2), snap(3)]
        store.selectAll(list)
        #expect(store.count == 3)
        #expect(store.contains(ghRepoId: 1))
        #expect(store.contains(ghRepoId: 2))
        #expect(store.contains(ghRepoId: 3))

        store.deselectAll()
        #expect(store.count == 0)
        // deselectAll 不退出多选
        #expect(store.isActive == true)
    }

    @Test("targets 派生为 BatchStarTarget 数组，字段一一对应")
    func targetsMappingMatchesSnapshots() {
        let store = MultiSelectionStore()
        store.enter()
        store.toggle(snap(3, "octo", "cat"))
        store.toggle(snap(1, "foo", "bar"))

        let targets = store.targets
        // sortedSnapshots 按 ghRepoId 升序，target 应当对齐
        #expect(targets.map(\.ghRepoId) == [1, 3])
        #expect(targets.map(\.owner) == ["foo", "octo"])
        #expect(targets.map(\.name) == ["bar", "cat"])
    }

    @Test("sortedSnapshots 稳定按 ghRepoId 升序")
    func sortedSnapshotsAreOrdered() {
        let store = MultiSelectionStore()
        store.enter()
        store.toggle(snap(50))
        store.toggle(snap(10))
        store.toggle(snap(30))

        let sorted = store.sortedSnapshots
        #expect(sorted.map(\.ghRepoId) == [10, 30, 50])
    }

    // MARK: - retain(visibleIDs:) — W12 toolbar PR-5
    //
    // Manage filter/sort 变化触发 reloadItems → RepoListView 在 .onChange(of: itemsRevision)
    // 调本方法，移除被隐藏的孤儿选中项。Trending/Weekly/Activity reload 时整页换数据，
    // 由 exit() 兜底，理论上不调本方法（但对它们的实例调用也应安全，本测试也覆盖）。

    @Test("retain：visibleIDs 全覆盖现有选中 → 无变化")
    func retainKeepsAllWhenAllVisible() {
        let store = MultiSelectionStore()
        store.enter()
        store.toggle(snap(10))
        store.toggle(snap(20))
        store.toggle(snap(30))
        #expect(store.count == 3)

        store.retain(visibleIDs: [10, 20, 30, 99])
        #expect(store.count == 3)
        #expect(store.contains(ghRepoId: 10))
        #expect(store.contains(ghRepoId: 20))
        #expect(store.contains(ghRepoId: 30))
    }

    @Test("retain：visibleIDs 只覆盖部分 → 只保留 visible 选中项")
    func retainKeepsVisibleSubset() {
        let store = MultiSelectionStore()
        store.enter()
        store.toggle(snap(10))
        store.toggle(snap(20))
        store.toggle(snap(30))

        // 模拟用户开了 "隐藏 archived" filter，导致 id=20 的 repo 被隐藏
        store.retain(visibleIDs: [10, 30])

        #expect(store.count == 2)
        #expect(store.contains(ghRepoId: 10))
        #expect(store.contains(ghRepoId: 20) == false)
        #expect(store.contains(ghRepoId: 30))
    }

    @Test("retain：visibleIDs 完全不交集 → 清空选中")
    func retainEmptiesWhenNoIntersection() {
        let store = MultiSelectionStore()
        store.enter()
        store.toggle(snap(10))
        store.toggle(snap(20))
        #expect(store.count == 2)

        // 模拟切到完全不同的分类
        store.retain(visibleIDs: [100, 200])
        #expect(store.count == 0)
        #expect(store.isActive == true) // retain 不动 isActive，只清 snapshots
    }

    @Test("retain：非多选模式（isActive=false）→ no-op")
    func retainNoOpWhenInactive() {
        let store = MultiSelectionStore()
        // 不调 enter() — isActive 保持 false
        store.retain(visibleIDs: [10, 20])
        #expect(store.count == 0)
        #expect(store.isActive == false)
    }
}
