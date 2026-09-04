//
//  AgentWorkspaceWindowController.swift
//  Starcat
//
//  Agent 工作台的 SwiftUI Window Scene 入口与根视图。
//
//  关键约束：工作台必须与主窗口一样由 SwiftUI `Window(id:)` 承载。手工创建
//  `NSWindow + NSHostingController` 会把 NavigationSplitView 降成标题栏下方的内容卡片，
//  无法得到交通灯与 Sidebar 共用同一系统圆角表面的原生 macOS 结构。
//

import AppKit
import SwiftUI

/// Agent 工作台窗口尺寸策略。
enum AgentWorkspaceWindowMetrics {
    static let defaultContentSize = NSSize(width: 1440, height: 820)
    // 三栏展开态与主窗口面临相同的压缩边界；共用硬下限，避免 SwiftUI 在更小窗口中裁切 Sidebar。
    static let minimumContentSize = MainWindowFrameDefaults.contentMinSize
}

/// 保留既有调用面，只负责门禁和打开 SwiftUI Window Scene，不再拥有 AppKit 窗口。
enum AgentWorkspaceWindowController {

    // v2 隔离本次 Window Scene 迁移前后的 restoration 记录，避免错误尺寸继续恢复。
    static let sceneID = "agent-workspace-v2"

    /// 显示 Agent 工作台窗口。
    ///
    /// - Returns: 入口门禁通过且 SwiftUI Scene 动作已注册时返回 `true`。
    @discardableResult
    @MainActor
    static func show(dependencies: AppDependencies) -> Bool {
        guard AIWorkspaceEntryGate.authorizeOpening(
            dependencies: dependencies,
            workspace: .agent
        ) else {
            return false
        }
        guard AIWorkspaceSceneCoordinator.shared.openAgentWindow() else { return false }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
}

/// Agent Scene 的窗口级状态根节点；关闭窗口后由 SwiftUI 释放，重开时得到干净状态。
struct AgentWorkspaceSceneRoot: View {

    let dependencies: AppDependencies

    @State private var chromeState = WorkspaceChromeState()
    @State private var windowReference = WorkspaceSceneWindowReference()

    var body: some View {
        AgentWorkspaceView(chromeState: chromeState)
            .appHostEnvironment(dependencies)
            .frame(
                minWidth: AgentWorkspaceWindowMetrics.minimumContentSize.width,
                minHeight: AgentWorkspaceWindowMetrics.minimumContentSize.height
            )
            .background {
                WorkspaceSceneWindowReader(
                    reference: windowReference,
                    minimumContentSize: AgentWorkspaceWindowMetrics.minimumContentSize
                )
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    WorkspaceTitlebarControls(
                        chromeState: chromeState,
                        onPinnedChange: { isPinned in
                            windowReference.window?.level = isPinned ? .floating : .normal
                        }
                    )
                }
            }
            // 与主窗口相同：让原生 Sidebar 表面贯穿 window toolbar，包住交通灯。
            .toolbarBackground(.hidden, for: .windowToolbar)
    }
}
