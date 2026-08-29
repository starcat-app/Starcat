//
//  GitHubStarListAIGroupingWindowController.swift
//  Starcat
//
//  AI 仓库分组审核工作区的固定尺寸 AppKit sheet 外壳。
//
//  SwiftUI `.sheet` 会先按内容反复计算 fitting size；该页面包含双栏、滚动区和动态文本，
//  因而会把首次展示和关闭拖进主线程多轮布局。本控制器让 AppKit 先确定 960 × 640 的
//  唯一几何尺寸，再把 SwiftUI 当作普通内容渲染，不让内容反向调整窗口。
//

import AppKit
import SwiftUI

/// AI 仓库分组审核窗口的固定几何规格。
private enum GitHubStarListAIGroupingWindowMetrics {
    static let contentSize = NSSize(width: 960, height: 640)
}

/// 管理单个 AI 仓库分组 sheet 的创建、展示与释放。
///
/// 业务状态仍由 `GitHubStarListAIGroupingSession` 持有；控制器只负责 AppKit 生命周期，
/// 不复制任何分组数据。窗口关闭后立即释放 hosting tree，后台分析会话继续按原规则运行。
@MainActor
final class GitHubStarListAIGroupingWindowController: NSWindowController, NSWindowDelegate {
    private static var activeController: GitHubStarListAIGroupingWindowController?

    private weak var parentWindow: NSWindow?
    private var onDismiss: (() -> Void)?
    private var isDismissing = false

    /// 准备内存快照并展示固定尺寸 sheet。重复触发时只激活现有窗口。
    static func present(
        dependencies: AppDependencies,
        preflightContext: GitHubStarListAIGroupingPreflightContext,
        selectedRepositories: [Repo] = [],
        existingMemberships: [Int64: Set<String>] = [:],
        onDismiss: @escaping () -> Void
    ) {
        if let activeController {
            activeController.window?.makeKeyAndOrderFront(nil)
            return
        }

        let session = dependencies.githubStarListAIGroupingSession
        // 窗口关闭后任务可能继续在后台收口；再次打开前清除已经没有待办的旧结果，
        // 否则 prepareManualContext 会因 jobs 非空而继续恢复上一轮审核页。
        session.finishManualSessionIfResolved()
        // 必须在创建 hosting tree 之前完成：这样 SwiftUI 第一帧读取到的是一次性完成态，
        // 不会在窗口出现后因多个 @Observable 字段依次写入而重复布局。
        if selectedRepositories.isEmpty {
            session.prepareManualContext(from: preflightContext)
        } else {
            session.prepareManualContext(
                from: preflightContext,
                repositories: selectedRepositories,
                existingMemberships: existingMemberships
            )
        }

        var closeAction: (() -> Void)?
        let content = GitHubStarListAIGroupingSheet(
            session: session,
            preflightContext: preflightContext,
            onClose: { closeAction?() }
        )
        .appHostEnvironment(dependencies)
        // fullSizeContentView 的标题栏安全区不应再次压缩 640pt 内容，否则 SwiftUI 会为
        // 被压缩后的根视图重新求 ideal height。自定义 header 已承担窗口顶部交互。
        .ignoresSafeArea(.container)

        let hostingController = NSHostingController(rootView: content)
        // 关闭 preferred/min/max/intrinsic sizing 回传。窗口尺寸由 AppKit 唯一持有，
        // SwiftUI 只在已知 bounds 内排版，避免再次进入 sizeThatFits 协商循环。
        hostingController.sizingOptions = []

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: GitHubStarListAIGroupingWindowMetrics.contentSize),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = String.l10n("githubStarLists.aiGrouping.title")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.contentMinSize = GitHubStarListAIGroupingWindowMetrics.contentSize
        window.contentMaxSize = GitHubStarListAIGroupingWindowMetrics.contentSize
        window.backgroundColor = .windowBackgroundColor

        let controller = GitHubStarListAIGroupingWindowController(window: window) {
            // 统一覆盖标题栏关闭按钮、系统关闭和外部 binding 关闭。
            session.releaseManualSessionOnWindowDismiss()
            onDismiss()
        }
        closeAction = { [weak controller] in controller?.dismiss() }
        activeController = controller
        controller.presentFromCurrentWindow()
    }

    /// 外部 binding 变为 false 时同步结束 AppKit sheet；该操作可重复调用。
    static func dismissIfPresented() {
        activeController?.dismiss()
    }

    private init(window: NSWindow, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("GitHubStarListAIGroupingWindowController does not support storyboard initialization")
    }

    /// 优先作为主窗口的原生 sheet 展示；极端情况下找不到主窗时退化为固定独立窗口。
    private func presentFromCurrentWindow() {
        guard let window else { return }
        // Popover 关闭的同一事件循环里 keyWindow 可能仍是临时面板；主窗口优先，
        // 避免把审核 sheet 错挂到即将消失的 popover 上。
        if let parent = NSApp.mainWindow ?? NSApp.keyWindow, parent !== window {
            parentWindow = parent
            parent.beginSheet(window) { [weak self] _ in
                self?.finishDismissal()
            }
        } else {
            showWindow(nil)
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 结束 sheet 时不调用 SwiftUI `dismiss`，避免重新进入 presentation bridge。
    private func dismiss() {
        guard !isDismissing else { return }
        isDismissing = true

        if let parentWindow, let window, parentWindow.attachedSheet === window {
            parentWindow.endSheet(window, returnCode: .cancel)
        } else {
            window?.orderOut(nil)
            finishDismissal()
        }
    }

    /// 只执行一次的释放出口；先通知 SwiftUI binding，再放掉整棵 hosting tree。
    private func finishDismissal() {
        guard Self.activeController === self else { return }
        let callback = onDismiss
        onDismiss = nil
        window?.contentViewController = nil
        window = nil
        callback?()
        Self.activeController = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismiss()
        return false
    }
}
