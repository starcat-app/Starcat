//
//  WorkspaceTitlebarControls.swift
//  Starcat
//
//  Agent / RAG 工作台独立窗口的 titlebar 右侧控制区。
//
//  这些按钮是窗口级操作,不属于具体业务 header:
//  - 右栏折叠 / 展开
//  - 窗口置顶 / 取消置顶
//  - RAG 专用：打开独立配置窗口（推理 + 提示词 + 检索）
//

import SwiftUI

/// 独立 workspace window 与其 SwiftUI 内容共享的 chrome 状态。
///
/// 左栏交给 `NavigationSplitView` 管理，右栏交给原生 SwiftUI Inspector 管理。
/// 这里保留窗口级单一状态，确保 titlebar 按钮与系统分栏始终读取同一份可见性。
@MainActor
@Observable
final class WorkspaceChromeState {
    /// 两栏导航外壳只使用 `.all` / `.detailOnly`：前者显示原生 Sidebar，后者折叠它。
    var leftColumnVisibility: NavigationSplitViewVisibility = .all
    var isRightColumnCollapsed: Bool = false
    var isPinned: Bool = false

    var isLeftColumnCollapsed: Bool {
        get { leftColumnVisibility == .detailOnly }
        set { leftColumnVisibility = newValue ? .detailOnly : .all }
    }

    /// Inspector API 使用“是否展示”，titlebar 仍使用“是否折叠”表达按钮状态；
    /// 用一个可写反向属性连接两套语义，避免在 View body 中手写易漂移的 Binding。
    var isRightColumnPresented: Bool {
        get { !isRightColumnCollapsed }
        set { isRightColumnCollapsed = !newValue }
    }
}

/// Agent / RAG 工作台共用的原生窗口工具栏内容。
///
/// 按钮必须直接作为 `ToolbarItemGroup` 的子项交给系统，不能再包进自定义 HStack 或
/// titlebar accessory。这样按钮的纵向位置、组合胶囊和交互动画都由窗口 toolbar 统一管理。
struct WorkspaceToolbarContent: ToolbarContent {

    @Bindable var chromeState: WorkspaceChromeState
    let onPinnedChange: (Bool) -> Void
    /// RAG 工作台传入设置动作；Agent 不传时复用同一组工具栏，只少一个按钮。
    var onSettings: (() -> Void)? = nil

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        // macOS 会把 `.primaryAction` 固定在 leading。把 SwiftUI `Spacer` 作为独立原生
        // toolbar item，系统会将它映射为 flexible space，把后续 automatic 组推到最右侧。
        ToolbarItem(placement: .automatic) {
            Spacer()
        }

        ToolbarItemGroup(placement: .automatic) {
            Button {
                chromeState.isRightColumnCollapsed.toggle()
            } label: {
                Image(systemName: "inset.filled.rightthird.rectangle")
            }
            .foregroundStyle(chromeState.isRightColumnCollapsed ? Color.accentColor : .secondary)
            .help(
                chromeState.isRightColumnCollapsed
                    ? LocalizedStringKey("workspace.chrome.showRight")
                    : LocalizedStringKey("workspace.chrome.hideRight")
            )

            Button {
                chromeState.isPinned.toggle()
                onPinnedChange(chromeState.isPinned)
            } label: {
                Image(systemName: chromeState.isPinned ? "pin.circle.fill" : "pin.circle")
            }
            .foregroundStyle(chromeState.isPinned ? Color.accentColor : .secondary)
            .help(
                chromeState.isPinned
                    ? LocalizedStringKey("workspace.chrome.unpin")
                    : LocalizedStringKey("workspace.chrome.pin")
            )

            if let onSettings {
                Button {
                    onSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .foregroundStyle(.secondary)
                .help(LocalizedStringKey("rag.workspace.settings.open"))
            }
        }
    }
}
