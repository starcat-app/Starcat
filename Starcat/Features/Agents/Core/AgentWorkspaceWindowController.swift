//
//  AgentWorkspaceWindowController.swift
//  Starcat
//
//  Agent 工作台的独立 macOS 窗口外壳。
//
//  设计约束:
//  - Agent 是长时间停留的工作区,需要系统 titlebar 的红黄绿按钮、拖拽和双击缩放。
//  - 不再用主窗口 overlay 承载,避免覆盖 titlebar safe area 和底层 WebView cursor rect 竞争。
//  - AppKit 自建窗口不会继承主 Window 的 SwiftUI environment,必须走 appHostEnvironment。
//

import AppKit
import SwiftUI

/// Agent 工作台窗口尺寸策略。
private enum AgentWorkspaceWindowMetrics {
    static let defaultContentSize = NSSize(width: 1440, height: 820)
    static let minimumContentSize = NSSize(width: 1180, height: 700)
    static let autosaveName = "AgentWorkspaceWindow"
}

/// 复用单个 Agent 工作台窗口;重复点击 toolbar 入口时把已有窗口带到前台。
final class AgentWorkspaceWindowController: NSWindowController, NSWindowDelegate {

    private static var shared: AgentWorkspaceWindowController?
    private let chromeState: WorkspaceChromeState

    /// 显示 Agent 工作台窗口。
    @MainActor
    static func show(dependencies: AppDependencies) {
        let controller: AgentWorkspaceWindowController
        let shouldCenter: Bool

        if let shared {
            controller = shared
            shouldCenter = false
        } else {
            controller = AgentWorkspaceWindowController(dependencies: dependencies)
            shared = controller
            shouldCenter = true
        }

        controller.showWindow(nil)
        if shouldCenter {
            controller.window?.center()
        }
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(dependencies: AppDependencies) {
        let chromeState = WorkspaceChromeState()
        self.chromeState = chromeState

        let content = AgentWorkspaceView(chromeState: chromeState)
        .appHostEnvironment(dependencies)

        let hostingController = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hostingController)

        window.title = "Agent 工作台"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(AgentWorkspaceWindowMetrics.defaultContentSize)
        window.contentMinSize = AgentWorkspaceWindowMetrics.minimumContentSize
        window.minSize = AgentWorkspaceWindowMetrics.minimumContentSize
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .windowBackgroundColor
        window.setFrameAutosaveName(AgentWorkspaceWindowMetrics.autosaveName)

        let controls = NSTitlebarAccessoryViewController()
        controls.layoutAttribute = .right
        let controlsView = NSHostingView(rootView: WorkspaceTitlebarControls(chromeState: chromeState) { [weak window] isPinned in
            window?.level = isPinned ? .floating : .normal
        })
        // 标题栏 accessory 由 AppKit 布局；显式 frame 能避免 SwiftUI hosting view 初始 intrinsic size 为 0。
        controlsView.frame = NSRect(x: 0, y: 0, width: 112, height: 32)
        controls.view = controlsView
        window.addTitlebarAccessoryViewController(controls)

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AgentWorkspaceWindowController does not support storyboard initialization")
    }

    func windowWillClose(_ notification: Notification) {
        window?.resignKey()
    }
}
