//
//  MultiSelectionStore.swift
//  Starcat
//
//  Trending / Weekly / Activity 多选模式的统一状态容器（W12 toolbar 专项 PR-4）。
//
//  存在意义：
//  - Manage 多选有完整 Repo 实例，直接复用 `HomeViewModel.multiSelectedRepoIDs`
//    （`Set<Int64>` 形态 + 从 viewModel.items 反查 Repo）；
//  - Trending / Weekly / Activity 的列表项是 ephemeral，**没有本地 Repo 实例**：
//    每次多选时需要把 owner / name / ghRepoId 等"批量操作必备字段"一并快照下来，
//    避免列表 items 在多选期间换页 / reload 后 selection 找不回 owner/name。
//  - 本 store **不复用** `HomeViewModel.multiSelectedRepoIDs`：那是 Manage 单页强耦合
//    的 set，语义为「已 star 库内多选」；trending/weekly 的"未必已 star"语义混进去
//    会污染 manage 现有多选 + 批量打标签 / 批量 unstar 链路。
//
//  关键约束：
//  - `@MainActor @Observable`：所有读写都在主线程；SwiftUI Observation 自动驱动
//    toolbar 多选按钮 / BatchActionBar 跟随选中数刷新；
//  - 一次只有一个 page 处于多选模式：调用方在 page 切换时主动 `exit()` 当前 store；
//  - 入选的 snapshot 不会自动随后端数据刷新而更新；用户启动批量操作时由
//    BatchStarService 用 `StarredRegistry` 复核每条当前 star 状态再决定 skip。
//

import Foundation
import Observation

/// 单条选中项的最小快照（owner / name + ghRepoId）。
///
/// 与 `BatchStarTarget` 字段重叠的部分（ghRepoId / owner / name）是有意的：
/// snapshot 保留"进入多选瞬间"的元数据，最终触发批量任务时再 `.toTarget()` 转换。
/// 单独引入这层避免 BatchStarTarget 跨出 Sync 层污染到 UI 多选状态。
struct SelectionSnapshot: Equatable, Identifiable {
    let ghRepoId: Int64
    let owner: String
    let name: String

    var id: Int64 { ghRepoId }
    var fullName: String { "\(owner)/\(name)" }

    /// 转 BatchStarTarget 供 BatchStarService 消费。
    func toTarget() -> BatchStarTarget {
        BatchStarTarget(ghRepoId: ghRepoId, owner: owner, name: name)
    }
}

/// 通用多选状态容器。
///
/// 一份实例对应一个 page（trending / weekly / activity）；同一时刻只有一份处于
/// `isActive == true`，由各 page view 在 onDisappear / 切走时主动 `exit()`。
@MainActor
@Observable
final class MultiSelectionStore {

    /// 是否处于多选模式。
    /// 用户按 toolbar 「多选」按钮切换；进入时清空 selection，退出时也清空。
    private(set) var isActive: Bool = false

    /// 当前选中项（按 ghRepoId 索引；同一 ghRepoId 只能存一份，避免重复选）。
    private(set) var snapshots: [Int64: SelectionSnapshot] = [:]

    init() {}

    // MARK: - 派生只读

    /// 当前选中数。
    var count: Int { snapshots.count }

    /// 已排序的所有 snapshot（按 ghRepoId 升序，确保 UI 渲染稳定）。
    var sortedSnapshots: [SelectionSnapshot] {
        snapshots.values.sorted { $0.ghRepoId < $1.ghRepoId }
    }

    /// 查询某条 ghRepoId 是否已选中。row 渲染选中态用。
    func contains(ghRepoId: Int64) -> Bool {
        snapshots[ghRepoId] != nil
    }

    /// 选中项的 BatchStarTarget 数组。供 BatchActionBar 启动批量任务时调用。
    var targets: [BatchStarTarget] {
        sortedSnapshots.map { $0.toTarget() }
    }

    // MARK: - 写入

    /// 进入多选模式（同时清空之前的 selection，避免与上次状态串场）。
    func enter() {
        isActive = true
        snapshots.removeAll()
    }

    /// 退出多选模式 + 清空 selection。
    func exit() {
        isActive = false
        snapshots.removeAll()
    }

    /// toolbar「多选」按钮一键切换。
    func toggle() {
        if isActive { exit() } else { enter() }
    }

    /// 对单条 snapshot 做"选中 / 取消选中"切换。
    /// 用 ghRepoId 作为 key：trending → weekly → manage 切回切去都按同一 id 对齐。
    func toggle(_ snapshot: SelectionSnapshot) {
        if snapshots[snapshot.ghRepoId] != nil {
            snapshots.removeValue(forKey: snapshot.ghRepoId)
        } else {
            snapshots[snapshot.ghRepoId] = snapshot
        }
    }

    /// 全选指定列表（用于 toolbar 上的"全选"操作；本期不内建 UI，但接口预留）。
    func selectAll(_ list: [SelectionSnapshot]) {
        for item in list {
            snapshots[item.ghRepoId] = item
        }
    }

    /// 全部取消选中（不退出多选模式）。
    func deselectAll() {
        snapshots.removeAll()
    }
}
