//
//  DailyRecommendationOverlay.swift
//  Starcat
//
//  全窗口抽卡展示：原生透明 child panel 覆盖标题栏与三栏内容，
//  业务状态仍归 DailyRecommendationStore，窗口只管理呈现和键盘隔离。
//

import AppKit
import SwiftUI

/// 覆盖整窗时必须独立承载事件，防止鼠标/快捷键落到 README 的 WebView。
struct DailyRecommendationOverlay<Content: View>: NSViewRepresentable {
    let isPresented: Bool
    let onClose: () -> Void
    let onPresentationChanged: (Bool) -> Void
    let onParentWindowReady: (Bool) -> Void
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> AnchorView {
        AnchorView()
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        // 内容仍铺满整窗；隐藏的系统标题栏只提供外轮廓，不额外下移网页和原生页头。
        let root = AnyView(content().appLocaleEnvironment().ignoresSafeArea())
        nsView.update(
            isPresented: isPresented,
            content: root,
            onClose: onClose,
            onPresentationChanged: onPresentationChanged,
            onParentWindowReady: onParentWindowReady
        )
    }

    static func dismantleNSView(_ nsView: AnchorView, coordinator: ()) {
        nsView.tearDown()
    }

    /// 锚定实际主窗口，避免多窗口下误用 NSApp.keyWindow。
    @MainActor
    final class AnchorView: NSView {
        private var panel: CardPanel?
        private var observers: [NSObjectProtocol] = []
        private weak var observedParent: NSWindow?
        private var reportedReadiness: Bool?
        private var desiredPresentation = false
        private var root = AnyView(EmptyView())
        private var onClose: () -> Void = {}
        private var onPresentationChanged: (Bool) -> Void = { _ in }
        private var onParentWindowReady: (Bool) -> Void = { _ in }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.synchronize() }
        }

        func update(
            isPresented: Bool,
            content: AnyView,
            onClose: @escaping () -> Void,
            onPresentationChanged: @escaping (Bool) -> Void,
            onParentWindowReady: @escaping (Bool) -> Void
        ) {
            desiredPresentation = isPresented
            root = content
            self.onClose = onClose
            self.onPresentationChanged = onPresentationChanged
            self.onParentWindowReady = onParentWindowReady
            // AppKit child window 的安装不能在 SwiftUI update 中同步触发 focus 更新。
            DispatchQueue.main.async { [weak self] in self?.synchronize() }
        }

        private func synchronize() {
            observeParentIfNeeded()
            let ready = window.map {
                $0.isVisible && !$0.isMiniaturized && $0.isKeyWindow && $0.attachedSheet == nil
            } ?? false
            if reportedReadiness != ready {
                reportedReadiness = ready
                onParentWindowReady(ready)
            }
            guard desiredPresentation, let parent = window else { dismiss(); return }
            if let panel,
               let hosting = panel.contentViewController as? NSHostingController<AnyView> {
                // SwiftUI 每次更新必须写入既有 host，否则子窗口会停留在创建时的内容快照。
                hosting.rootView = root
                panel.synchronizeFrame(with: parent)
                return
            }
            let hosting = NSHostingController(rootView: root)
            hosting.sizingOptions = []
            let panel = CardPanel(
                contentRect: parent.frame, styleMask: [.titled, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isMovable = false
            panel.collectionBehavior = [.fullScreenAuxiliary]
            panel.contentViewController = hosting
            panel.onEscape = { [weak self] in self?.onClose() }
            self.panel = panel
            parent.addChildWindow(panel, ordered: .above)
            panel.synchronizeFrame(with: parent)
            panel.makeKeyAndOrderFront(nil)
            onPresentationChanged(true)
        }

        /// 父窗口在抽卡层之外仍需被观察：首次就绪、结束 Sheet 和取消最小化可继续待展示批次。
        private func observeParentIfNeeded() {
            guard observedParent !== window else { return }
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            dismiss(restoringParentFocus: false)
            observedParent = window
            guard let parent = window else { return }
            let refreshWindow: @MainActor @Sendable () -> Void = { [weak self] in self?.synchronize() }
            for name in [
                NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                NSWindow.didEndSheetNotification, NSWindow.didDeminiaturizeNotification,
                NSWindow.didResizeNotification, NSWindow.didMoveNotification,
                NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification
            ] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: parent, queue: .main
                ) { _ in
                    // key-window 通知仍可能处在 AppKit 的 focus 更新栈内，下一轮再更新 hosting tree。
                    DispatchQueue.main.async(execute: refreshWindow)
                })
            }
        }

        /// 观察者与宿主同生共灭；只关卡片时保留父窗口监听，移除宿主才彻底释放。
        func tearDown() {
            desiredPresentation = false
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            observedParent = nil
            dismiss(restoringParentFocus: false)
        }

        private func dismiss(restoringParentFocus: Bool = true) {
            guard let panel else { return }
            let parent = panel.parent
            let wasKey = panel.isKeyWindow
            parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.contentViewController = nil
            self.panel = nil
            // 只在主动关闭可见抽卡层时归还焦点，宿主销毁不能把已隐藏或最小化的主窗带回来。
            if restoringParentFocus, wasKey, NSApp.isActive,
               let parent, parent.isVisible, !parent.isMiniaturized {
                parent.makeKeyAndOrderFront(nil)
            }
            onPresentationChanged(false)
        }
    }
}

/// Esc 与 Cmd+W 只关闭抽卡层，不能关闭下方主窗口。
private final class CardPanel: NSPanel {
    var onEscape: () -> Void = {}

    /// 用系统窗口框架统一裁剪磨砂和 WebKit 内容，避免 borderless 方角盖住主窗口轮廓。
    ///
    /// `.titled` 保留 AppKit 随系统变化的圆角，透明标题栏和 fullSizeContentView 只隐藏外观，
    /// 不手写固定半径，也不单独裁剪 HTML 而漏掉 behindWindow 材质。真正全屏时使用矩形；
    /// 切换 styleMask 可能改变 content/frame 换算，因此最后重新对齐父窗口的完整 frame。
    func synchronizeFrame(with parent: NSWindow) {
        let targetStyle: NSWindow.StyleMask = parent.styleMask.contains(.fullScreen)
            ? [.borderless, .fullSizeContentView]
            : [.titled, .fullSizeContentView]
        if styleMask != targetStyle {
            styleMask = targetStyle
        }
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        titlebarSeparatorStyle = .none
        setFrame(parent.frame, display: true)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape() }
    override func performClose(_ sender: Any?) { onEscape() }
}

/// 透明子窗口直接透出主界面；只轻微调节明暗，不用 HUD 材质把整窗覆盖成灰幕。
struct DailyRecommendationBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // 主窗口的真实内容保留至少 76% 可见度；文字可读性由页头和操作区的局部表面负责。
        Rectangle()
            .fill(colorScheme == .dark ? Color.black.opacity(0.18) : Color.white.opacity(0.24))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
