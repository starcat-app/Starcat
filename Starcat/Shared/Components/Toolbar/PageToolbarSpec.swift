//
//  PageToolbarSpec.swift
//  Starcat
//
//  顶部 toolbar 内容的"页感知"派发载体。
//
//  设计目标（W12 toolbar 专项 PR-1）：
//  - 把 `RepoListView.toolbar` 内硬编码的 `if selectedPage == .manage` 单分支
//    替换为「按 selectedPage 派发一个 spec → toolbar 把 spec 内容 splat 进各槽」。
//  - 每个 page 的 toolbar items 写在各自的 builder 里（`makeManageToolbarSpec` /
//    `makeTrendingToolbarSpec` / `makeActivityToolbarSpec`），扩展只动对应分支。
//
//  关键约束：
//  - 用 `AnyView` 擦类型：SwiftUI `.toolbar` 的 `ToolbarItem` 子 view 要求 `some View`，
//    跨 page 派发只能擦类型；toolbar 控件总量 < 10 个，diff 损耗忽略。
//  - 本次 PR-1 是「行为等价迁移」：仅 Manage 走完整 spec；trending / activity
//    返回空 spec，保持各自自绘 toolbar 的现状。PR-2/3/4 再逐步迁过来。
//
//  TODO（后续 PR）：
//  - PR-2：把 `searchField` 从 manage-only 改为所有 page 都有；
//  - PR-3/4：把 trending/weekly 的自绘 toolbar 整体搬进对应 spec builder。
//

import SwiftUI

/// 单个页面在系统 toolbar 中要渲染的内容。
///
/// 三个槽位严格对应 `.toolbar { ... }` 内三个 `ToolbarItem(Group)`，
/// 每个槽位为 nil 时该 ToolbarItem 整体不渲染，避免出现空 group 浪费空间。
struct PageToolbarSpec {

    /// 主操作组：filter / sort / multi-select 等左侧按钮。
    /// 渲染位置：`ToolbarItemGroup(placement: .primaryAction)` 第 1 组。
    var leadingPrimary: AnyView?

    /// 主操作组：wiki / external / clone / share 等"依赖当前选中项"的右侧按钮。
    /// 与 `leadingPrimary` 分组是为了系统在窄 toolbar 下有合理的折叠优先级。
    /// 渲染位置：`ToolbarItemGroup(placement: .primaryAction)` 第 2 组。
    var trailingPrimary: AnyView?

    /// 智能搜索框（SmartSearchField）。
    /// 渲染位置：独立 `ToolbarItem(placement: .primaryAction)`，最右侧。
    var searchField: AnyView?

    /// 完全空的 spec（trending / activity 在 PR-1 阶段使用）。
    static let empty = PageToolbarSpec()

    init(leadingPrimary: AnyView? = nil, trailingPrimary: AnyView? = nil, searchField: AnyView? = nil) {
        self.leadingPrimary = leadingPrimary
        self.trailingPrimary = trailingPrimary
        self.searchField = searchField
    }
}
