//
//  MultiSelectButton.swift
//  Starcat
//
//  顶部 toolbar 「多选模式切换」按钮。
//
//  原归属：`RepoListView.multiSelectButton`（仅 Manage 路径，闭包内直接读
//  `HomeViewModel.isMultiSelectMode` 和 `toggleMultiSelectMode()`）。W12 toolbar
//  专项 PR-1 抽出，让 Trending / Weekly / Activity 也能复用同款图标 + 快捷键。
//
//  关键约束：
//  - 视觉态由入参 `isActive` 驱动（`checklist` ↔ `checklist.checked`），具体激活
//    含义由调用方决定（Manage 用 `HomeViewModel.isMultiSelectMode`、其它场景用
//    各自的 `MultiSelectionStore.isActive`）；
//  - 键盘快捷键统一 `⌘⇧M`，调用方注入时不重复定义；
//  - `isDisabled` 由调用方按业务场景注入（典型场景：trending / weekly 未登录态——
//    批量 star/unstar 必须调 GitHub API 需要 token），禁用时 tooltip 切到
//    `disabledHelpKey` 解释为何不能用。与 `SmartSearchField` 的 disabled 语义同款。
//

import SwiftUI

/// Toolbar 多选切换按钮。
struct MultiSelectButton: View {

    let isActive: Bool
    let action: () -> Void

    /// 调用方注入：当业务场景不允许进入多选模式时（如未登录），传 true 让按钮变灰且 no-op。
    /// 默认 false 兼容 Manage 等不需要登录守卫的场景。
    var isDisabled: Bool = false

    /// 禁用态的 tooltip 文案 key。仅 `isDisabled == true` 时生效，提示用户为何按钮不可用。
    var disabledHelpKey: LocalizedStringKey = "batch.multiSelect.disabledNotAuthenticated"

    var body: some View {
        Button(action: action) {
            ToolbarIcon(isActive ? "checklist.checked" : "checklist")
                .accessibilityLabel(isActive ? Text("batch.exitMultiSelect") : Text("batch.multiSelect"))
        }
        .disabled(isDisabled)
        .help(isDisabled
              ? Text(disabledHelpKey)
              : (isActive ? Text("list.exitMultiSelectMode") : Text("list.multiSelectMode")))
        .keyboardShortcut("m", modifiers: [.command, .shift])
    }
}
