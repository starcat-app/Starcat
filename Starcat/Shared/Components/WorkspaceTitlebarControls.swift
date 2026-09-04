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

/// 放在 `NSTitlebarAccessoryViewController` 内的窗口级图标按钮组。
struct WorkspaceTitlebarControls: View {

    @Bindable var chromeState: WorkspaceChromeState
    let onPinnedChange: (Bool) -> Void
    /// RAG 工作台专用：右上角齿轮打开配置；Agent 不传则不显示。
    var onSettings: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            controlButton(
                systemImage: "inset.filled.rightthird.rectangle",
                isActive: chromeState.isRightColumnCollapsed,
                helpKey: chromeState.isRightColumnCollapsed
                    ? "workspace.chrome.showRight"
                    : "workspace.chrome.hideRight"
            ) {
                chromeState.isRightColumnCollapsed.toggle()
            }

            controlButton(
                systemImage: chromeState.isPinned ? "pin.circle.fill" : "pin.circle",
                isActive: chromeState.isPinned,
                helpKey: chromeState.isPinned
                    ? "workspace.chrome.unpin"
                    : "workspace.chrome.pin"
            ) {
                chromeState.isPinned.toggle()
                onPinnedChange(chromeState.isPinned)
            }

            if let onSettings {
                controlButton(
                    systemImage: "gearshape",
                    isActive: false,
                    helpKey: "rag.workspace.settings.open"
                ) {
                    onSettings()
                }
            }
        }
        .padding(.trailing, 10)
        // NSTitlebarAccessoryViewController 不会可靠地从 SwiftUI 内容推导尺寸。
        // 按钮数可变（Agent 3 / RAG 4），用 fixedSize 避免末尾按钮被裁掉。
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: 32, alignment: .trailing)
        // titlebar accessory 是独立 hosting 树，不继承主窗口 locale。
        .appLocaleEnvironment()
    }

    private func controlButton(
        systemImage: String,
        isActive: Bool,
        helpKey: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .foregroundStyle(isActive ? Color.accentColor : .secondary)
        .background(isActive ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        .help(helpKey)
    }
}
