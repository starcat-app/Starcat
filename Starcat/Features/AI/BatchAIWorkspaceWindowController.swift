//
//  BatchAIWorkspaceWindowController.swift
//  Starcat
//
//  批量标签工作区的固定尺寸 AppKit sheet 承载层。
//
//  AppKit 只拥有窗口尺寸、父子窗口关系和释放时机；任务状态仍由 BatchAIQueueService
//  持有。关闭窗口时只释放 hosting tree，不取消队列，因此用户可以稍后从进度入口继续审核。
//

import AppKit
import SwiftUI

enum BatchAIWorkspaceWindowMetrics {
    static let contentSize = NSSize(width: 960, height: 640)
}

@MainActor
final class BatchAIWorkspaceWindowController: NSWindowController, NSWindowDelegate {
    private static var activeController: BatchAIWorkspaceWindowController?

    private weak var parentWindow: NSWindow?
    private var onDismiss: (() -> Void)?
    private var isDismissing = false

    static func present(
        dependencies: AppDependencies,
        initialMode: BatchAIWorkspaceInitialMode,
        options: Binding<BatchAIQueueOptions>,
        hasUsableExternalSearchProvider: Bool,
        onStart: @escaping (BatchAIRepositoryScope) async -> Bool,
        onDismiss: @escaping () -> Void
    ) {
        if let activeController {
            activeController.window?.makeKeyAndOrderFront(nil)
            return
        }

        var closeAction: (() -> Void)?
        let content = BatchAIWorkspaceView(
            service: dependencies.batchAIQueueService,
            initialMode: initialMode,
            options: options,
            canPrepareCodeContext: dependencies.repoAIInsightService.canPrepareCodeContext,
            hasUsableExternalSearchProvider: hasUsableExternalSearchProvider,
            onStart: onStart,
            onClose: { closeAction?() }
        )
        .appHostEnvironment(dependencies)
        .ignoresSafeArea(.container)

        let hostingController = NSHostingController(rootView: content)
        // SwiftUI 只在固定 bounds 内布局，不能把 preferred/intrinsic size 回传给 AppKit，
        // 否则展开摘要选项时会重新参与 sheet 尺寸协商。
        hostingController.sizingOptions = []

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: BatchAIWorkspaceWindowMetrics.contentSize),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = String.l10n("batchAI.generateTags.title")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.contentMinSize = BatchAIWorkspaceWindowMetrics.contentSize
        window.contentMaxSize = BatchAIWorkspaceWindowMetrics.contentSize
        window.backgroundColor = .windowBackgroundColor

        let controller = BatchAIWorkspaceWindowController(window: window, onDismiss: onDismiss)
        closeAction = { [weak controller] in controller?.dismiss() }
        activeController = controller
        controller.presentFromCurrentWindow()
    }

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
        fatalError("BatchAIWorkspaceWindowController does not support storyboard initialization")
    }

    private func presentFromCurrentWindow() {
        guard let window else { return }
        // 多选底栏或状态 popover 关闭的同一事件循环里 keyWindow 可能仍是临时面板，
        // 因此优先挂到 mainWindow，和仓库分组工作区保持一致。
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
