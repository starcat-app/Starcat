//
//  KnowledgeRAGWorkspaceWindowController.swift
//  Starcat
//
//  知识库 RAG 工作台的独立 macOS 窗口外壳。
//
//  设计约束:
//  - RAG 问答和证据核验是长时间工作流,需要完整 macOS 窗口语义。
//  - 不使用主窗口 overlay,避免遮住系统红黄绿按钮和继承底层内容的 cursor rect。
//  - 内容由真实 KnowledgeRAGWorkspaceViewModel 驱动，窗口 controller 持有其 SwiftUI 根视图。
//

import AppKit
import SwiftUI

/// 知识库 RAG 工作台窗口尺寸策略。
private enum KnowledgeRAGWorkspaceWindowMetrics {
    static let defaultContentSize = NSSize(width: 1440, height: 820)
    static let minimumContentSize = NSSize(width: 1180, height: 700)
    static let autosaveName = "KnowledgeRAGWorkspaceWindow"
}

/// 复用单个 RAG 工作台窗口;重复点击 toolbar 入口时把已有窗口带到前台。
final class KnowledgeRAGWorkspaceWindowController: NSWindowController, NSWindowDelegate {

    private static var shared: KnowledgeRAGWorkspaceWindowController?
    private let chromeState: WorkspaceChromeState
    private let viewModel: KnowledgeRAGWorkspaceViewModel

    /// 显示知识库 RAG 工作台窗口。
    @MainActor
    static func show(dependencies: AppDependencies) {
        let controller: KnowledgeRAGWorkspaceWindowController
        let shouldCenter: Bool

        if let shared {
            controller = shared
            shouldCenter = false
        } else {
            controller = KnowledgeRAGWorkspaceWindowController(dependencies: dependencies)
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

    /// 用户数据库切换前销毁旧工作台，避免旧账户的内存历史继续显示，或在切库后把
    /// 未完成回答写进新账户数据库。
    @MainActor
    static func closeForUserDatabaseChange() {
        shared?.viewModel.cancelAnswer()
        shared?.close()
        shared = nil
    }

    private init(dependencies: AppDependencies) {
        let chromeState = WorkspaceChromeState()
        let viewModel = KnowledgeRAGWorkspaceViewModel(dependencies: dependencies)
        self.chromeState = chromeState
        self.viewModel = viewModel

        let content = KnowledgeRAGWorkspaceView(chromeState: chromeState, viewModel: viewModel)
        .appHostEnvironment(dependencies)

        let hostingController = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hostingController)

        window.title = String.l10n("rag.workspace.window.title")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(KnowledgeRAGWorkspaceWindowMetrics.defaultContentSize)
        window.contentMinSize = KnowledgeRAGWorkspaceWindowMetrics.minimumContentSize
        window.minSize = KnowledgeRAGWorkspaceWindowMetrics.minimumContentSize
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .windowBackgroundColor
        window.setFrameAutosaveName(KnowledgeRAGWorkspaceWindowMetrics.autosaveName)

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
        fatalError("KnowledgeRAGWorkspaceWindowController does not support storyboard initialization")
    }

    func windowWillClose(_ notification: Notification) {
        viewModel.cancelAnswer()
        window?.resignKey()
        Self.shared = nil
    }
}
