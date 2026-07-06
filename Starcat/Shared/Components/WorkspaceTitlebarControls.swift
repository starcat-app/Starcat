//
//  WorkspaceTitlebarControls.swift
//  Starcat
//
//  Agent / RAG 工作台独立窗口的 titlebar 右侧控制区。
//
//  这些按钮是窗口级操作,不属于具体业务 header:
//  - 左栏折叠 / 展开
//  - 右栏折叠 / 展开
//  - 窗口置顶 / 取消置顶
//

import SwiftUI

/// 独立 workspace window 与其 SwiftUI 内容共享的 chrome 状态。
///
/// 由窗口 titlebar 按钮修改,由内容视图读取后决定左右栏是否显示。
@MainActor
@Observable
final class WorkspaceChromeState {
    var isLeftColumnCollapsed: Bool = false
    var isRightColumnCollapsed: Bool = false
    var isPinned: Bool = false
}

/// 放在 `NSTitlebarAccessoryViewController` 内的窗口级图标按钮组。
struct WorkspaceTitlebarControls: View {

    @Bindable var chromeState: WorkspaceChromeState
    let onPinnedChange: (Bool) -> Void

    var body: some View {
        HStack(spacing: 6) {
            controlButton(
                systemImage: "inset.filled.leftthird.rectangle",
                isActive: chromeState.isLeftColumnCollapsed,
                help: chromeState.isLeftColumnCollapsed ? "显示左栏" : "隐藏左栏"
            ) {
                chromeState.isLeftColumnCollapsed.toggle()
            }

            controlButton(
                systemImage: "inset.filled.rightthird.rectangle",
                isActive: chromeState.isRightColumnCollapsed,
                help: chromeState.isRightColumnCollapsed ? "显示右栏" : "隐藏右栏"
            ) {
                chromeState.isRightColumnCollapsed.toggle()
            }

            controlButton(
                systemImage: chromeState.isPinned ? "pin.circle.fill" : "pin.circle",
                isActive: chromeState.isPinned,
                help: chromeState.isPinned ? "取消窗口置顶" : "置顶窗口"
            ) {
                chromeState.isPinned.toggle()
                onPinnedChange(chromeState.isPinned)
            }
        }
        .padding(.trailing, 10)
        // NSTitlebarAccessoryViewController 不会可靠地从 SwiftUI 内容推导尺寸。
        // 在透明标题栏 + fullSizeContentView 下显式给出尺寸，避免按钮组被系统按 0 宽布局而不可见。
        .frame(width: 112, height: 32, alignment: .trailing)
    }

    private func controlButton(
        systemImage: String,
        isActive: Bool,
        help: String,
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
        .help(help)
    }
}
