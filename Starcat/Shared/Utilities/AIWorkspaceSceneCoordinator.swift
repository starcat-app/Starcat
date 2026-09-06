//
//  AIWorkspaceSceneCoordinator.swift
//  Starcat
//
//  RAG / Agent 工作台 SwiftUI Window Scene 的打开桥接与 AppKit 窗口探针。
//
//  SwiftUI 的 `openWindow` / `dismissWindow` 只能从 View environment 读取，而工作台
//  入口同时存在于菜单命令和普通业务 View。这里集中保存由主 Scene 注册的动作，避免
//  各入口重新退回手工 `NSWindow + NSHostingController`，破坏原生 Sidebar chrome。
//

import AppKit
import Observation
import SwiftUI

/// 跨入口协调两个 AI 工作台的单实例 SwiftUI Window Scene。
@MainActor
@Observable
final class AIWorkspaceSceneCoordinator {

    /// RAG Scene 构造 ViewModel 所需的主窗口上下文。
    struct KnowledgeRAGLaunchContext: Identifiable {
        let id = UUID()
        let dependencies: AppDependencies
        let homeViewModel: HomeViewModel
    }

    static let shared = AIWorkspaceSceneCoordinator()

    private(set) var knowledgeRAGContext: KnowledgeRAGLaunchContext?

    @ObservationIgnored private var openAgentWindowAction: (() -> Void)?
    @ObservationIgnored private var openKnowledgeRAGWindowAction: (() -> Void)?
    @ObservationIgnored private var dismissKnowledgeRAGWindowAction: (() -> Void)?

    private init() {}

    /// 由主 SwiftUI Scene 注册系统 Window 动作；业务入口只调用下方语义方法。
    func registerWindowActions(
        openAgent: @escaping () -> Void,
        openKnowledgeRAG: @escaping () -> Void,
        dismissKnowledgeRAG: @escaping () -> Void
    ) {
        openAgentWindowAction = openAgent
        openKnowledgeRAGWindowAction = openKnowledgeRAG
        dismissKnowledgeRAGWindowAction = dismissKnowledgeRAG
    }

    @discardableResult
    func openAgentWindow() -> Bool {
        guard let openAgentWindowAction else { return false }
        openAgentWindowAction()
        return true
    }

    /// 首次打开时记录 RAG 所需上下文；重复点击只激活既有 Scene，不重建对话状态。
    @discardableResult
    func openKnowledgeRAGWindow(
        dependencies: AppDependencies,
        homeViewModel: HomeViewModel
    ) -> Bool {
        guard let openKnowledgeRAGWindowAction else { return false }
        if knowledgeRAGContext == nil {
            knowledgeRAGContext = KnowledgeRAGLaunchContext(
                dependencies: dependencies,
                homeViewModel: homeViewModel
            )
        }
        openKnowledgeRAGWindowAction()
        return true
    }

    /// 数据库切换必须先关闭旧 RAG Scene；普通关闭由 Scene root 在 disappear 时清上下文。
    func dismissKnowledgeRAGWindow() {
        guard let dismissKnowledgeRAGWindowAction else {
            knowledgeRAGContext = nil
            return
        }
        dismissKnowledgeRAGWindowAction()
    }

    func knowledgeRAGWindowDidClose(contextID: UUID) {
        guard knowledgeRAGContext?.id == contextID else { return }
        knowledgeRAGContext = nil
    }
}

/// 保存当前 SwiftUI Window 背后的 `NSWindow`，供置顶按钮和尺寸策略使用。
@MainActor
final class WorkspaceSceneWindowReference {
    weak var window: NSWindow?
}

/// 从 SwiftUI Window Scene 窄接入 AppKit：只负责拿窗口引用和设置最小尺寸。
///
/// Window Scene 自己会恢复窗口 frame；这里不能再调用 `setFrameAutosaveName`，否则
/// 旧 AppKit 窗口记录会和 SwiftUI restoration 竞争，导致两个工作台恢复成不同尺寸。
struct WorkspaceSceneWindowReader: NSViewRepresentable {

    let reference: WorkspaceSceneWindowReference
    let minimumContentSize: NSSize
    /// SwiftUI `Window("key")` 的 Scene 标题由系统按 bundle 偏好语言解析，绕开
    /// `String.l10n` 与 `.appLocaleEnvironment` 注入（它们只影响 scene 内视图树），
    /// 设置里选英文 + 系统中文时标题栏仍会显示中文。窗口挂载后在这里手动覆盖。
    var titleKey: String?

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onWindowChange = configure(window:)
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onWindowChange = configure(window:)
        configure(window: nsView.window)
    }

    private func configure(window: NSWindow?) {
        guard let window else { return }
        reference.window = window
        if let titleKey {
            window.title = String.l10n(titleKey)
        }

        // `contentMinSize` 与 `minSize` 分别描述内容区和含标题栏外框，不能复用同一数值。
        let minimumFrameSize = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: minimumContentSize)
        ).size
        window.contentMinSize = minimumContentSize
        window.minSize = minimumFrameSize

        let currentFrame = window.frame
        guard currentFrame.width < minimumFrameSize.width
                || currentFrame.height < minimumFrameSize.height else { return }
        window.setFrame(
            NSRect(
                origin: currentFrame.origin,
                size: NSSize(
                    width: max(currentFrame.width, minimumFrameSize.width),
                    height: max(currentFrame.height, minimumFrameSize.height)
                )
            ),
            display: true,
            animate: false
        )
    }

    final class ProbeView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }
}
