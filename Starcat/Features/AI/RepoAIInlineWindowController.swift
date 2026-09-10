//
//  RepoAIInlineWindowController.swift
//  Starcat
//
//  README 详情页内 AI 面板的 child window 外壳。
//
//  内嵌 SwiftUI overlay 与 README WKWebView 位于同一个 NSWindow 时，SwiftUI 的
//  `hitTest` 和 `NSCursor.set()` 都不能可靠阻断 WebKit cursor rect。这里保留 AI
//  面板的视觉位置和内容，只把它放进定位于详情区域的独立 child NSPanel。
//

import AppKit
import SwiftUI

/// AI 内嵌面板需要接收文本输入，但不应成为应用的主窗口。
private final class RepoAIInlinePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// SwiftUI 用来保存详情区域锚点 NSView 的轻量引用。
///
/// 锚点 view 只用于把 SwiftUI 详情区转换成 screen 坐标，不承载业务状态；控制器
/// 关闭后不会反向持有主窗口视图树。
@MainActor
final class RepoAIInlineWindowAnchorReference {
    weak var view: NSView?
    /// 保留最近一次有效的详情区域 screen frame，避免 SwiftUI 重建锚点时用整窗猜位置。
    var lastValidScreenFrame: NSRect?

    func update(from view: NSView) {
        self.view = view
        guard let window = view.window,
              view.bounds.width > 1,
              view.bounds.height > 1 else { return }

        let screenFrame = window.convertToScreen(view.convert(view.bounds, to: nil))
        guard screenFrame.width > 1, screenFrame.height > 1 else { return }
        lastValidScreenFrame = screenFrame
    }
}

/// 监听锚点真正挂入窗口和完成布局的时机。
///
/// `NSViewRepresentable.updateNSView` 可能早于 AppKit 把 view 挂进主窗口；如果只在
/// update 回调取坐标，首次打开会拿不到详情区域 frame，只能错误地退回整窗定位。
private final class RepoAIInlineAnchorView: NSView {
    let reference: RepoAIInlineWindowAnchorReference

    init(reference: RepoAIInlineWindowAnchorReference) {
        self.reference = reference
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RepoAIInlineAnchorView does not support storyboard initialization")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        captureFrameAndNotifyController()
    }

    override func layout() {
        super.layout()
        captureFrameAndNotifyController()
    }

    private func captureFrameAndNotifyController() {
        reference.update(from: self)
        RepoAIInlineWindowController.updateAnchor(reference: reference)
    }
}

/// 将详情区域的真实 AppKit frame 回传给 AI child window 控制器。
struct RepoAIInlineWindowAnchor: NSViewRepresentable {
    let reference: RepoAIInlineWindowAnchorReference

    func makeNSView(context: Context) -> NSView {
        let view = RepoAIInlineAnchorView(reference: reference)
        reference.update(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        reference.update(from: nsView)
        RepoAIInlineWindowController.updateAnchor(reference: reference)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        RepoAIInlineWindowController.updateAnchor(reference: nil)
    }
}

/// 管理详情页 AI 内嵌面板的 child window 生命周期、定位和尺寸切换。
///
/// SwiftUI 的 `RepoAIInlinePanelContent` 持有面板内部模式状态；本控制器只持有
/// NSPanel 和锚点，负责把窗口放在详情区底部，并在主窗口 resize 或详情布局变化后
/// 重新计算 frame。这样既隔离 cursor rect，又不复制摘要/对话 ViewModel。
@MainActor
final class RepoAIInlineWindowController: NSWindowController, NSWindowDelegate {
    private static var activeController: RepoAIInlineWindowController?

    private let repo: Repo
    private let dependencies: AppDependencies
    private let homeViewModel: HomeViewModel
    private let onDismiss: () -> Void
    private var topChromeInset: CGFloat
    private var bottomChromeInset: CGFloat
    private let reduceMotion: Bool
    private weak var parentWindow: NSWindow?
    private weak var anchorView: NSView?
    private var lastValidAnchorFrame: NSRect?
    /// NSWindow 的 contentViewController 在不同 AppKit 生命周期阶段的持有行为不应成为
    /// SwiftUI 内容存活的隐含前提；控制器显式保留 hosting tree，关闭时再释放。
    private var hostedContentController: NSViewController?
    private var availableSize: CGSize
    private var resizeObserver: NSObjectProtocol?
    private var escapeMonitor: Any?
    private var isMaximized = false
    private var isDismissing = false
    private var frameUpdateScheduled = false

    /// 展示指定 repo 的 AI 面板；同一时间只保留一个 inline panel。
    static func present(
        repo: Repo,
        dependencies: AppDependencies,
        homeViewModel: HomeViewModel,
        anchorView: NSView?,
        anchorFrame: NSRect?,
        availableSize: CGSize,
        autoGenerateSummaryOnOpen: Bool,
        topChromeInset: CGFloat,
        bottomChromeInset: CGFloat,
        reduceMotion: Bool,
        onDismiss: @escaping () -> Void
    ) -> Bool {
        if let activeController {
            guard activeController.repo.id == repo.id else {
                activeController.finishDismissal(animated: false)
                return present(
                    repo: repo,
                    dependencies: dependencies,
                    homeViewModel: homeViewModel,
                    anchorView: anchorView,
                    anchorFrame: anchorFrame,
                    availableSize: availableSize,
                    autoGenerateSummaryOnOpen: autoGenerateSummaryOnOpen,
                    topChromeInset: topChromeInset,
                    bottomChromeInset: bottomChromeInset,
                    reduceMotion: reduceMotion,
                    onDismiss: onDismiss
                )
            }
            activeController.anchorView = anchorView
            if let anchorFrame {
                activeController.lastValidAnchorFrame = anchorFrame
            }
            activeController.availableSize = availableSize
            activeController.topChromeInset = topChromeInset
            activeController.bottomChromeInset = bottomChromeInset
            activeController.window?.makeKeyAndOrderFront(nil)
            activeController.updateFrame()
            return activeController.window != nil
        }

        // child window 必须挂到锚点所属的详情主窗口；没有有效锚点时直接等待下一帧，
        // 不能用 keyWindow / mainWindow 代替，否则会把面板错误地按整窗居中。
        guard let parentWindow = anchorView?.window else { return false }
        let controller = RepoAIInlineWindowController(
            repo: repo,
            dependencies: dependencies,
            homeViewModel: homeViewModel,
            parentWindow: parentWindow,
            anchorView: anchorView,
            anchorFrame: anchorFrame,
            availableSize: availableSize,
            autoGenerateSummaryOnOpen: autoGenerateSummaryOnOpen,
            topChromeInset: topChromeInset,
            bottomChromeInset: bottomChromeInset,
            reduceMotion: reduceMotion,
            onDismiss: onDismiss
        )
        // 先注册再呈现：`makeKeyAndOrderFront` / child-window 生命周期回调可能在
        // `present()` 内同步触发。若等 `present()` 返回后才登记，`windowWillClose`
        // 会因为找不到 active controller 而跳过清理，SwiftUI 便会永久认为面板已打开，
        // 最终表现为横条消失且后续再也打不开。
        activeController = controller
        guard controller.present() else {
            // 失败路径必须和成功路径成对回滚；不能留下一个已注册但不可见的 controller。
            if activeController === controller {
                activeController = nil
            }
            return false
        }
        return true
    }

    /// 详情 repo 被切换或 SwiftUI overlay 销毁时关闭现有 child window。
    static func dismiss() {
        activeController?.finishDismissal()
    }

    /// 锚点 view 的 frame 变化由 SwiftUI 布局触发；只更新当前 active controller，避免
    /// 旧 repo 的延迟布局回调误移动新 repo 的 AI 窗口。
    static func updateAnchor(
        reference: RepoAIInlineWindowAnchorReference?,
        availableSize: CGSize? = nil,
        topChromeInset: CGFloat? = nil,
        bottomChromeInset: CGFloat? = nil
    ) {
        guard let activeController else { return }
        if let reference {
            activeController.anchorView = reference.view
            if let screenFrame = reference.lastValidScreenFrame {
                activeController.lastValidAnchorFrame = screenFrame
            }
        }
        if let availableSize {
            activeController.availableSize = availableSize
        }
        if let topChromeInset {
            activeController.topChromeInset = topChromeInset
        }
        if let bottomChromeInset {
            activeController.bottomChromeInset = bottomChromeInset
        }
        // 滚动时详情锚点和可用高度会在同一轮布局内变化；如果继续只派发到下一轮
        // run loop，child window 会短暂保留旧 frame，旧面板就可能越过主窗口边缘闪出。
        // 可见窗口直接同步，打开阶段仍走合并调度，避免在首帧布局中重入 AppKit。
        if activeController.window?.isVisible == true {
            activeController.updateFrame()
        } else {
            activeController.scheduleFrameUpdate()
        }
    }

    private init(
        repo: Repo,
        dependencies: AppDependencies,
        homeViewModel: HomeViewModel,
        parentWindow: NSWindow,
        anchorView: NSView?,
        anchorFrame: NSRect?,
        availableSize: CGSize,
        autoGenerateSummaryOnOpen: Bool,
        topChromeInset: CGFloat,
        bottomChromeInset: CGFloat,
        reduceMotion: Bool,
        onDismiss: @escaping () -> Void
    ) {
        self.repo = repo
        self.dependencies = dependencies
        self.homeViewModel = homeViewModel
        self.parentWindow = parentWindow
        self.anchorView = anchorView
        self.lastValidAnchorFrame = anchorFrame
        self.availableSize = availableSize
        self.onDismiss = onDismiss
        self.topChromeInset = topChromeInset
        self.bottomChromeInset = bottomChromeInset
        self.reduceMotion = reduceMotion
        self.hostedContentController = nil

        let initialSize = NSSize(width: 320, height: RepoAIOverlayLayout.panelMinHeight)
        let panel = RepoAIInlinePanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.level = parentWindow.level
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = NSSize(width: 320, height: RepoAIOverlayLayout.panelMinHeight)

        super.init(window: panel)

        // Swift 要求父类初始化完成后才能让闭包捕获 self；内容挂载顺序不能提前，
        // 否则会触发 "self used before super.init"，并不是窗口生命周期上的可选项。
        let content = RepoAIInlinePanelContent(
            repo: repo,
            autoGenerateSummaryOnOpen: autoGenerateSummaryOnOpen,
            onClose: { [weak self] in self?.finishDismissal() },
            onResize: { [weak self] isMaximized in self?.setMaximized(isMaximized) },
            onOpenDetachedWindow: { [weak self] in self?.openDetachedWindow() }
        )
        .appHostEnvironment(dependencies, homeViewModel: homeViewModel)
        let hostingController = NSHostingController(rootView: content)
        hostedContentController = hostingController
        hostingController.sizingOptions = []
        // `.borderless` 只移除了窗口标题栏和系统边框，并不会把 NSPanel 的矩形
        // content view 变成圆角。圆角必须落在 AppKit hosting root 上，否则 SwiftUI
        // 内层的圆角背景与外层矩形窗口会叠出一圈细线，并在四角露出直角边界。
        let hostingView = hostingController.view
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 18
        hostingView.layer?.masksToBounds = true
        panel.contentViewController = hostingController
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RepoAIInlineWindowController does not support storyboard initialization")
    }

    private func present() -> Bool {
        guard let parentWindow, let window else { return false }
        parentWindow.addChildWindow(window, ordered: .above)
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: parentWindow,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleFrameUpdate()
            }
        }
        installEscapeMonitor()
        guard let targetFrame = frameForCurrentState() else {
            removeObservers()
            parentWindow.removeChildWindow(window)
            return false
        }

        window.setFrame(targetFrame, display: true)
        window.alphaValue = reduceMotion ? 1 : 0
        window.makeKeyAndOrderFront(nil)

        guard !reduceMotion else { return true }
        var initialFrame = targetFrame
        initialFrame.origin.y -= 20
        window.setFrame(initialFrame, display: false)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
            window.animator().setFrame(targetFrame, display: true)
        }
        return true
    }

    private func setMaximized(_ isMaximized: Bool) {
        self.isMaximized = isMaximized
        updateFrame(isMaximized: isMaximized, animated: true)
    }

    private func scheduleFrameUpdate() {
        guard !frameUpdateScheduled else { return }
        frameUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.frameUpdateScheduled = false
            self.updateFrame()
        }
    }

    private func updateFrame(isMaximized: Bool? = nil, animated: Bool = false) {
        guard let frame = frameForCurrentState(isMaximized: isMaximized) else { return }
        guard let window else { return }
        guard window.frame != frame else { return }
        if animated, !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(frame, display: true)
            }
        } else {
            window.setFrame(frame, display: true, animate: false)
        }
    }

    private func frameForCurrentState(isMaximized: Bool? = nil) -> NSRect? {
        guard let parentWindow, window != nil else { return nil }

        let anchorFrame: NSRect
        if let anchorView,
           anchorView.window === parentWindow,
           anchorView.bounds.width > 1,
           anchorView.bounds.height > 1 {
            let currentFrame = parentWindow.convertToScreen(anchorView.convert(anchorView.bounds, to: nil))
            lastValidAnchorFrame = currentFrame
            anchorFrame = currentFrame
        } else if let lastValidAnchorFrame {
            // SwiftUI 重建 representable 的短暂窗口脱离期间，继续使用最近一次详情区
            // frame；绝不能退回 parentWindow.contentView，因为那会改变定位参考系。
            anchorFrame = lastValidAnchorFrame
        } else {
            return nil
        }
        let maximized = isMaximized ?? self.isMaximized
        // 高度和宽度必须继续使用 SwiftUI GeometryReader 的 proposal；锚点只负责
        // 提供 screen 坐标。只有首帧 proposal 尚未到达时才回退到锚点尺寸。
        let layoutSize = availableSize.width > 0 && availableSize.height > 0
            ? availableSize
            : anchorFrame.size
        let size = panelSize(for: layoutSize, isMaximized: maximized)
        let desiredOrigin = NSPoint(
            x: anchorFrame.midX - size.width / 2,
            y: anchorFrame.maxY - effectiveBottomChromeInset - size.height
        )
        return clampedPanelFrame(
            origin: desiredOrigin,
            size: size,
            in: parentWindow
        )
    }

    /// 将 child window 限制在主窗口内容区域内，防止滚动布局跨帧时出现越界闪动。
    ///
    /// 高度仍由 `RepoAIOverlayLayout.panelHeight` 决定；这里仅在窗口尺寸确实大于
    /// 当前主窗口可见区域时收缩，并钳制 origin。这样不会改变正常详情页的自动增高、
    /// 变低位置，只保护快速滚动和窗口缩放期间的临界帧。
    private func clampedPanelFrame(origin: NSPoint, size: NSSize, in parentWindow: NSWindow) -> NSRect {
        let visibleFrame = parentWindow.convertToScreen(parentWindow.contentLayoutRect)
        let constrainedSize = NSSize(
            width: min(size.width, visibleFrame.width),
            height: min(size.height, visibleFrame.height)
        )
        let constrainedOrigin = NSPoint(
            x: min(
                max(origin.x, visibleFrame.minX),
                visibleFrame.maxX - constrainedSize.width
            ),
            y: min(
                max(origin.y, visibleFrame.minY),
                visibleFrame.maxY - constrainedSize.height
            )
        )
        return NSRect(origin: constrainedOrigin, size: constrainedSize)
    }

    private func panelSize(for availableSize: CGSize, isMaximized: Bool) -> NSSize {
        let usableWidth = max(320, availableSize.width - 48)
        let width: CGFloat
        if isMaximized {
            width = max(320, usableWidth - 32)
        } else {
            width = min(usableWidth, 720, max(320, usableWidth * 0.70))
        }
        let height = RepoAIOverlayLayout.panelHeight(
            availableHeight: availableSize.height,
            topChromeInset: topChromeInset,
            bottomChromeInset: effectiveBottomChromeInset,
            isMaximized: isMaximized
        )
        return NSSize(width: width, height: height)
    }

    /// 没有 README 状态栏的详情模式仍需保留旧的安全间距；README 页面则使用实测高度。
    private var effectiveBottomChromeInset: CGFloat {
        bottomChromeInset > 0
            ? bottomChromeInset
            : RepoAIOverlayLayout.panelBottomInset
    }

    private func openDetachedWindow() {
        RepoAIWindowController.show(
            repo: repo,
            dependencies: dependencies,
            homeViewModel: homeViewModel
        )
        finishDismissal()
    }

    private func installEscapeMonitor() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, self?.window?.isKeyWindow == true else { return event }
            self?.finishDismissal()
            return nil
        }
    }

    private func finishDismissal(animated: Bool = true) {
        guard Self.activeController === self, !isDismissing else { return }
        isDismissing = true
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }

        guard animated, !reduceMotion, let window else {
            completeDismissal()
            return
        }

        var finalFrame = window.frame
        finalFrame.origin.y -= 20
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
            window.animator().setFrame(finalFrame, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.completeDismissal()
            }
        }
    }

    private func completeDismissal() {
        removeObservers()
        if let parentWindow, let window {
            parentWindow.removeChildWindow(window)
            window.orderOut(nil)
            window.contentViewController = nil
            window.alphaValue = 1
        }
        hostedContentController = nil
        window = nil
        Self.activeController = nil
        parentWindow?.makeKeyAndOrderFront(nil)
        onDismiss()
    }

    private func removeObservers() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
            self.resizeObserver = nil
        }
    }

    func windowWillClose(_ notification: Notification) {
        finishDismissal(animated: false)
    }
}

/// 独立 child window 内的 AI 内容根节点。
///
/// 面板模式仍由 SwiftUI `@State` 持有；切换最大化只通过窄回调通知 AppKit 调整窗口
/// 几何，不把 AI 摘要/对话状态复制到窗口控制器中。
private struct RepoAIInlinePanelContent: View {
    let repo: Repo
    let autoGenerateSummaryOnOpen: Bool
    let onClose: () -> Void
    let onResize: (Bool) -> Void
    let onOpenDetachedWindow: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isMaximized = false

    var body: some View {
        RepoAIWindowContentView(
            repo: repo,
            autoGenerateSummaryOnOpen: autoGenerateSummaryOnOpen,
            respondsToInlineGenerateRequests: true,
            onClose: onClose,
            onInlineResizeTapped: {
                isMaximized.toggle()
                onResize(isMaximized)
            },
            onOpenDetachedWindow: onOpenDetachedWindow,
            isInlineMaximized: isMaximized
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 窗口圆角和裁切由 AppKit hosting root 统一负责；这里保留纯面板底色，避免
        // SwiftUI 再绘制一层圆角和阴影，产生与 child window 矩形边界不一致的细框。
        .background(StarcatSurface.panel(colorScheme: colorScheme))
        .onExitCommand(perform: onClose)
    }
}
