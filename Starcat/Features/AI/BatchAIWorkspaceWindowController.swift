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
    static let contentSize = AIOrganizationLayout.windowSize
}

/// 单实例固定 sheet；父窗口由发起操作的 HomeView 传入，展示与点击回调分离。
@MainActor
final class BatchAIWorkspaceWindowController: NSWindowController, NSWindowDelegate {
    private static var activeController: BatchAIWorkspaceWindowController?

    private weak var parentWindow: NSWindow?
    private var onDismiss: (() -> Void)?
    private var isDismissing = false
    private let presentationTrace: BatchAIWorkspacePresentationTrace

    /// 创建固定画布，再在后续主队列回调挂载 sheet，避免重入 popover / SwiftUI 更新栈。
    static func present(
        dependencies: AppDependencies,
        parentWindow: NSWindow?,
        initialMode: BatchAIWorkspaceInitialMode,
        options: Binding<BatchAIQueueOptions>,
        hasUsableExternalSearchProvider: Bool,
        onStart: @escaping (
            BatchAIWorkspacePreflightContext,
            @escaping TagTaxonomyBootstrapProgressHandler
        ) async -> BatchAIWorkspaceStartOutcome,
        onConfirmTaxonomy: @escaping (
            TagTaxonomyBootstrapSession,
            [TagTaxonomyCandidate]
        ) async -> String?,
        onDismiss: @escaping () -> Void
    ) {
        if let activeController {
            // 展示尚未执行时只合并重复请求，不能提前把待挂载的 sheet 当独立窗口打开。
            if activeController.window?.isVisible == true {
                activeController.window?.makeKeyAndOrderFront(nil)
            }
            return
        }
        guard let parentWindow else {
            AppLog.ui.error("[batch-ai-window] Presentation skipped: source window unavailable")
            onDismiss()
            return
        }

        let trace = BatchAIWorkspacePresentationTrace()
        trace.mark("hosting_begin")
        let service = dependencies.batchAIQueueService
        if case .preflight = initialMode {
            // 上一轮若在窗口关闭后才完成，这里先收口，避免旧结果继续占用新任务状态。
            service.finishManualSessionIfResolved()
        }

        var closeAction: (() -> Void)?
        let content = BatchAIWorkspaceView(
            service: service,
            initialMode: initialMode,
            options: options,
            canPrepareCodeContext: dependencies.repoAIInsightService.canPrepareCodeContext,
            hasUsableExternalSearchProvider: hasUsableExternalSearchProvider,
            onStart: onStart,
            onConfirmTaxonomy: onConfirmTaxonomy,
            onClose: { closeAction?() }
        )
        .appHostEnvironment(dependencies)
        .ignoresSafeArea(.container)

        let hostingController = BatchAIWorkspaceHostingController(rootView: content, trace: trace)
        // SwiftUI 只在固定 bounds 内布局，不能把 preferred/intrinsic size 回传给 AppKit，
        // 否则展开摘要选项时会重新参与 sheet 尺寸协商。
        hostingController.sizingOptions = []
        trace.mark("hosting_created")

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: BatchAIWorkspaceWindowMetrics.contentSize),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = String.l10n("batchAI.generateTags.title")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.contentMinSize = BatchAIWorkspaceWindowMetrics.contentSize
        window.contentMaxSize = BatchAIWorkspaceWindowMetrics.contentSize
        window.backgroundColor = .windowBackgroundColor
        // 在挂载前同时固定窗口和 hosting view 的画布，首帧不从零尺寸反复试探 ideal size。
        trace.mark("content_mount_begin")
        hostingController.view.setFrameSize(BatchAIWorkspaceWindowMetrics.contentSize)
        window.contentViewController = hostingController
        trace.mark("content_mounted")

        let controller = BatchAIWorkspaceWindowController(
            window: window,
            parentWindow: parentWindow,
            presentationTrace: trace
        ) {
            // 统一覆盖标题栏关闭按钮、系统关闭和外部 binding 关闭。
            service.finishManualSessionIfResolved()
            onDismiss()
        }
        closeAction = { [weak controller] in controller?.dismiss() }
        activeController = controller
        DispatchQueue.main.async { [weak controller] in
            controller?.presentFromSourceWindow()
        }
    }

    static func dismissIfPresented() {
        activeController?.dismiss()
    }

    private init(
        window: NSWindow,
        parentWindow: NSWindow,
        presentationTrace: BatchAIWorkspacePresentationTrace,
        onDismiss: @escaping () -> Void
    ) {
        self.parentWindow = parentWindow
        self.presentationTrace = presentationTrace
        self.onDismiss = onDismiss
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BatchAIWorkspaceWindowController does not support storyboard initialization")
    }

    private func presentFromSourceWindow() {
        guard Self.activeController === self, !isDismissing, let window else { return }
        // 延迟期间主窗口可能被关闭或已有登录/其它 sheet；不排队挂到失效父窗，
        // 也不回退到全局 keyWindow（它可能属于 popover、Settings 或另一工作台）。
        guard let parentWindow, parentWindow.isVisible, parentWindow.sheetParent == nil,
              parentWindow.attachedSheet == nil else {
            presentationTrace.mark("sheet_skipped_parent_unavailable_or_busy")
            finishDismissal()
            return
        }
        presentationTrace.mark("sheet_begin")
        parentWindow.beginSheet(window) { [weak self] _ in
            self?.finishDismissal()
        }
        // beginSheet 返回只代表 AppKit 接受展示；首帧布局由 hosting controller 单独记录。
        presentationTrace.mark("sheet_returned")
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

/// 有界的本机展示日志：只记一次打开的随机 ID、固定阶段名与单调时钟耗时，不记录用户内容。
@MainActor
private final class BatchAIWorkspacePresentationTrace {
    private let requestID = UUID().uuidString
    private let startedAt = ProcessInfo.processInfo.systemUptime

    /// 每阶段记录累计毫秒；相邻阶段之差可区分 hosting 创建、挂载、布局与 sheet 调用。
    func mark(_ stage: String) {
        let elapsed = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        AppLog.ui.info(
            "[batch-ai-window] id=\(self.requestID, privacy: .public) stage=\(stage, privacy: .public) elapsed_ms=\(elapsed, format: .fixed(precision: 1))"
        )
    }
}

/// 只观察首次 AppKit 布局，不主动触发布局或将测量结果写回 SwiftUI，避免诊断本身制造刷新循环。
@MainActor
private final class BatchAIWorkspaceHostingController<Content: View>: NSHostingController<Content> {
    private let trace: BatchAIWorkspacePresentationTrace
    private var firstLayoutStarted = false
    private var firstLayoutFinished = false

    init(rootView: Content, trace: BatchAIWorkspacePresentationTrace) {
        self.trace = trace
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BatchAIWorkspaceHostingController does not support storyboard initialization")
    }

    override func viewWillLayout() {
        if !firstLayoutStarted {
            firstLayoutStarted = true
            trace.mark("first_layout_begin")
        }
        super.viewWillLayout()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !firstLayoutFinished else { return }
        firstLayoutFinished = true
        trace.mark("first_layout_finished")
    }
}
