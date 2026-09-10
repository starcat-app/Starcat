//
//  SearchCenterWindowController.swift
//  Starcat
//
//  全局搜索浮层的 AppKit child window 外壳。
//
//  SwiftUI overlay 与 README 的 WKWebView 共处主窗口时，二者的 cursor rect 仍会
//  参与同一轮 AppKit 光标决策。搜索中心需要覆盖主窗口内容区，因此这里使用一个
//  无标题栏 child NSPanel，把遮罩和搜索内容一起放进独立的 NSWindow。
//

import AppKit
import SwiftUI

/// 搜索中心必须能成为 key window，才能让搜索输入框和容器级快捷键正常工作。
private final class SearchCenterPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 管理主窗口级搜索中心的 child window 生命周期和几何同步。
///
/// SwiftUI 仍然持有 `SearchCenterViewModel` 及所有业务回调；本控制器只负责把已经
/// 构造好的 SwiftUI 内容放进独立窗口，并让窗口跟随主窗口内容区变化。这样不会复制
/// 搜索状态，也不会把 AppKit window 状态变成第二套业务 source of truth。
@MainActor
final class SearchCenterWindowController: NSWindowController, NSWindowDelegate {
    private static var activeController: SearchCenterWindowController?

    private weak var parentWindow: NSWindow?
    private var resizeObserver: NSObjectProtocol?
    private let reduceMotion: Bool
    private var isDismissing = false

    /// 将 SwiftUI 搜索中心作为主窗口内容区上方的 child window 展示。
    ///
    /// `Content` 由调用方构造并注入主窗口所需的 environment，控制器不接触搜索业务
    /// 闭包，避免为了 AppKit 展示再复制一套 HomeView 路由。
    static func present<Content: View>(
        content: Content,
        from parentWindow: NSWindow? = nil,
        reduceMotion: Bool = false
    ) {
        if let activeController {
            activeController.window?.makeKeyAndOrderFront(nil)
            activeController.updateFrame()
            return
        }

        guard let parent = parentWindow ?? mainWindow() else { return }

        let hostingController = NSHostingController(
            rootView: content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
        // 搜索窗口尺寸由主窗口内容区唯一决定，禁止 hosting controller 反向协商窗口尺寸。
        hostingController.sizingOptions = []

        let panel = SearchCenterPanel(
            contentRect: NSRect(origin: .zero, size: parent.contentView?.bounds.size ?? .zero),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hostingController
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.level = parent.level
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let controller = SearchCenterWindowController(
            window: panel,
            parentWindow: parent,
            reduceMotion: reduceMotion
        )
        guard controller.present() else { return }
        activeController = controller
    }

    /// 由 SearchCenterViewModel 的 `isPresented` 关闭状态驱动的统一出口。
    static func dismiss() {
        activeController?.finishDismissal()
    }

    private init(window: NSWindow, parentWindow: NSWindow, reduceMotion: Bool) {
        self.parentWindow = parentWindow
        self.reduceMotion = reduceMotion
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SearchCenterWindowController does not support storyboard initialization")
    }

    private func present() -> Bool {
        guard let parentWindow, let window else { return false }

        // child window 关系保证主窗口移动时搜索窗口一起移动；resize observer 负责同步
        // 内容区尺寸，否则主窗口拖拽后旧 panel 只会覆盖旧的矩形区域。
        parentWindow.addChildWindow(window, ordered: .above)
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: parentWindow,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.updateFrame()
            }
        }
        let targetFrame = frameForCurrentState()
        window.setFrame(targetFrame, display: true)
        window.alphaValue = reduceMotion ? 1 : 0
        window.makeKeyAndOrderFront(nil)
        guard !reduceMotion else { return true }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.20
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
        return true
    }

    private func updateFrame() {
        guard let parentWindow,
              let contentView = parentWindow.contentView,
              let window else { return }

        // `contentView.frame` 使用父窗口坐标系，转换到 screen 后正好覆盖主窗口内容区，
        // 不覆盖标题栏，也不让搜索 panel 的 cursor rect 泄漏到主窗口标题栏。
        let contentFrameOnScreen = parentWindow.convertToScreen(contentView.frame)
        window.setFrame(contentFrameOnScreen, display: true, animate: false)
    }

    private func frameForCurrentState() -> NSRect {
        guard let parentWindow, let contentView = parentWindow.contentView else {
            return window?.frame ?? .zero
        }
        return parentWindow.convertToScreen(contentView.frame)
    }

    private func finishDismissal() {
        guard Self.activeController === self, !isDismissing else { return }
        isDismissing = true
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
            self.resizeObserver = nil
        }
        guard !reduceMotion, let window else {
            completeDismissal()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.completeDismissal()
            }
        }
    }

    private func completeDismissal() {
        if let parentWindow, let window {
            parentWindow.removeChildWindow(window)
            window.orderOut(nil)
            window.contentViewController = nil
            window.alphaValue = 1
        }
        window = nil
        Self.activeController = nil
        parentWindow?.makeKeyAndOrderFront(nil)
    }

    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first(where: {
            $0.frameAutosaveName == MainWindowFrameDefaults.autosaveName
        }) ?? NSApp.keyWindow
    }

    func windowWillClose(_ notification: Notification) {
        isDismissing = true
        completeDismissal()
    }
}
