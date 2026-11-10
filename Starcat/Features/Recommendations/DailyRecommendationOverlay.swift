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
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> AnchorView {
        AnchorView()
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        let root = AnyView(content().appLocaleEnvironment())
        nsView.update(
            isPresented: isPresented,
            content: root,
            onClose: onClose,
            onPresentationChanged: onPresentationChanged
        )
    }

    static func dismantleNSView(_ nsView: AnchorView, coordinator: ()) {
        nsView.dismiss()
    }

    /// 锚定实际主窗口，避免多窗口下误用 NSApp.keyWindow。
    @MainActor
    final class AnchorView: NSView {
        private var panel: CardPanel?
        private var observers: [NSObjectProtocol] = []
        private var desiredPresentation = false
        private var root = AnyView(EmptyView())
        private var onClose: () -> Void = {}
        private var onPresentationChanged: (Bool) -> Void = { _ in }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            synchronize()
        }

        func update(
            isPresented: Bool,
            content: AnyView,
            onClose: @escaping () -> Void,
            onPresentationChanged: @escaping (Bool) -> Void
        ) {
            desiredPresentation = isPresented
            root = content
            self.onClose = onClose
            self.onPresentationChanged = onPresentationChanged
            // AppKit child window 的安装不能在 SwiftUI update 中同步触发 focus 更新。
            DispatchQueue.main.async { [weak self] in self?.synchronize() }
        }

        private func synchronize() {
            guard desiredPresentation, let parent = window else { dismiss(); return }
            if let panel,
               let hosting = panel.contentViewController as? NSHostingController<AnyView> {
                // SwiftUI 每次更新必须写入既有 host，否则子窗口会停留在创建时的内容快照。
                hosting.rootView = root
                return
            }
            let hosting = NSHostingController(rootView: root)
            hosting.sizingOptions = []
            let panel = CardPanel(
                contentRect: parent.frame, styleMask: [.borderless, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.fullScreenAuxiliary]
            panel.contentViewController = hosting
            panel.onEscape = { [weak self] in self?.onClose() }
            self.panel = panel
            parent.addChildWindow(panel, ordered: .above)
            panel.setFrame(parent.frame, display: true)
            for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: parent, queue: .main
                ) { [weak self, weak parent] _ in
                    MainActor.assumeIsolated {
                        guard let parent else { return }
                        self?.panel?.setFrame(parent.frame, display: true)
                    }
                })
            }
            panel.makeKeyAndOrderFront(nil)
            onPresentationChanged(true)
        }

        func dismiss() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let panel else { return }
            let parent = panel.parent
            parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.contentViewController = nil
            self.panel = nil
            parent?.makeKeyAndOrderFront(nil)
            onPresentationChanged(false)
        }
    }
}

/// Esc 与 Cmd+W 只关闭抽卡层，不能关闭下方主窗口。
private final class CardPanel: NSPanel {
    var onEscape: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape() }
    override func performClose(_ sender: Any?) { onEscape() }
}

/// 子窗口透明材质采样其后方主界面，保留三栏可辨识轮廓。
struct DailyRecommendationBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let effect = NSVisualEffectView()
        effect.blendingMode = .behindWindow
        effect.material = .hudWindow
        effect.state = .active
        return effect
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
