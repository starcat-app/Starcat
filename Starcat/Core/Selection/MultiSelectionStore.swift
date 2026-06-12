//
//  MultiSelectionStore.swift
//  Starcat
//
//  Manage / Trending / Weekly / Activity 4 个分类多选模式的**统一**状态容器。
//
//  历史：
//  - W12 toolbar 专项 PR-4（2026-06-12 17:35）：首次引入，仅服务 Trending/Weekly/Activity 3 个远端场景，
//    避免「未必已 star 的 ephemeral 多选语义」污染 Manage 当时基于 HomeViewModel.multiSelectedRepoIDs
//    的「已 star 库内多选 + batch-tag」链路；
//  - W12 toolbar 专项 PR-5（2026-06-12，dong4j grill-me 拍板）：Manage 也迁到本 store，4 场景统一。
//    PR-4 担心的污染问题在 **Manage 用自己的实例 + BatchActionBar/RemoteBatchActionBar 仍按业务语义独立**
//    （前者只暴露打标签+Unstar，后者只暴露 Star+Unstar）的前提下不存在。
//
//  存在意义：
//  - Trending / Weekly / Activity 的列表项是 ephemeral，**没有本地 Repo 实例**：
//    每次多选时需要把 owner / name / ghRepoId 等"批量操作必备字段"一并快照下来，
//    避免列表 items 在多选期间换页 / reload 后 selection 找不回 owner/name。
//  - Manage 虽然有完整本地 Repo 实例，但走同一份 store 让 4 场景的交互（点击 toggle / Cmd+A 全选 /
//    退出 / Cmd+点击 toggle）完全一致，UX 可预测且代码路径单一。
//    Manage 的 BatchActionBar 用 `Set(store.snapshots.keys)` 直接喂 `batchAddTag(repoIds:tagId:)`
//    （Repo.id == ghRepoId 同 Int64 域，无需字段映射）。
//
//  关键约束：
//  - `@MainActor @Observable`：所有读写都在主线程；SwiftUI Observation 自动驱动
//    toolbar 多选按钮 / BatchActionBar 跟随选中数刷新；
//  - 一次只有一个 page 处于多选模式：调用方（RepoListView）在 page 切换时主动 `exit()` 当前 store；
//  - 入选的 snapshot 不会自动随后端数据刷新而更新；用户启动批量操作时由
//    BatchStarService 用 `StarredRegistry` 复核每条当前 star 状态再决定 skip；
//  - **Manage 专属约束**（A2 路线）：filter / sort 变化触发 reloadItems 后，view 层在
//    `.onChange(of: itemsRevision)` 调 `retain(visibleIDs:)` 清理被隐藏的孤儿选中项。
//    Trending/Weekly/Activity 不会触发该路径——它们 reload 时整页换数据，由 exit() 兜底。
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

    /// 全选指定列表。
    ///
    /// W12 toolbar PR-5：Cmd+A 全选快捷键调用此方法（4 场景同款）。调用方负责把当前 visible items
    /// 转成 `[SelectionSnapshot]`（owner / name / ghRepoId）传进来；本方法只负责把 snapshots
    /// 字典做 by-key 合并（同 ghRepoId 覆盖，不会重复）。
    func selectAll(_ list: [SelectionSnapshot]) {
        for item in list {
            snapshots[item.ghRepoId] = item
        }
    }

    /// 全部取消选中（不退出多选模式）。
    func deselectAll() {
        snapshots.removeAll()
    }

    /// 只保留 `visibleIDs` 内的选中项；其余孤儿选中项移除。
    ///
    /// W12 toolbar PR-5（A2 路线）：Manage 场景下 filter / sort 变化触发 reloadItems 后，
    /// items 是「全集的子集」（如开「隐藏 archived」），原本选中但被隐藏的 repo 应该从 selection
    /// 中移除（避免「看不见的选中项」继续参与批量操作）。
    ///
    /// view 层在 `.onChange(of: viewModel.itemsRevision)` 调用此方法，store 不感知 view 的具体
    /// items 形态，调用方负责把 items 映射为 `Set<Int64>` ghRepoId。
    ///
    /// Trending/Weekly/Activity 不会调用本方法 —— 它们 reload 时整页换数据，由 RepoListView 切页面
    /// 时 exit() 兜底清空。本方法对它们的实例调用也安全（只读 snapshots 字典做集合运算）。
    func retain(visibleIDs: Set<Int64>) {
        // 只在多选模式下做清理。非多选态 snapshots 已为空，无需操作。
        guard isActive else { return }
        let staleKeys = snapshots.keys.filter { !visibleIDs.contains($0) }
        for key in staleKeys {
            snapshots.removeValue(forKey: key)
        }
    }
}
