//
//  FollowGraphWindowOverlay.swift
//  Starcat
//
//  覆盖整个主窗口 theme frame，而非每日热点的中右两栏。宿主不参与窗口尺寸计算，
//  关闭时立即拆除并恢复原 first responder，不修改 toolbar、交通灯或窗口几何。
//

import AppKit
import SwiftUI

/// 同窗口覆盖层；环境必须跨 NSHostingView 显式传递，避免语言 / 主题丢失。
@MainActor
struct FollowGraphWindowOverlay<Content: View>: NSViewRepresentable {
    let isPresented: Bool
    let onEscape: () -> Void
    @ViewBuilder var content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.changed = { [weak coordinator = context.coordinator, weak view] in
            if let view { coordinator?.attach(view) }
        }
        return view
    }

    func updateNSView(_ view: Probe, context: Context) {
        let coordinator = context.coordinator
        coordinator.onEscape = onEscape
        guard isPresented else { coordinator.detach(); return }
        let root = AnyView(content().environment(\.self, context.environment).appLocaleEnvironment())
        if let host = coordinator.host { host.rootView = root }
        else {
            coordinator.host = NSHostingView(rootView: root)
            coordinator.host?.sizingOptions = []
            coordinator.host?.safeAreaRegions = []
        }
        coordinator.attach(view)
    }

    static func dismantleNSView(_ nsView: Probe, coordinator: Coordinator) {
        nsView.changed = nil
        coordinator.detach()
    }

    /// Escape monitor 仅消费所属窗口的 Escape，不拦截其他窗口的键盘操作。
    @MainActor final class Coordinator {
        var host: NSHostingView<AnyView>?
        var onEscape: (() -> Void)?
        private weak var window: NSWindow?
        private weak var previousResponder: NSResponder?
        private var monitor: Any?

        func attach(_ probe: Probe) {
            guard let host, let window = probe.window, let container = window.contentView?.superview else { return }
            if host.superview !== container {
                self.window = window
                previousResponder = window.firstResponder
                container.addSubview(host, positioned: .above, relativeTo: nil)
                window.makeFirstResponder(host)
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self, event.window === self.window, event.keyCode == 53 else { return event }
                    self.onEscape?()
                    return nil
                }
            }
            host.frame = container.bounds
            host.autoresizingMask = [.width, .height]
        }

        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            let wasMounted = host?.superview != nil
            host?.removeFromSuperview()
            host = nil
            if wasMounted { window?.makeFirstResponder(previousResponder) }
            previousResponder = nil
            window = nil
        }
    }

    /// 零交互探针只提供所属窗口，不参与布局尺寸或事件命中。
    @MainActor final class Probe: NSView {
        var changed: (() -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); changed?() }
        override func layout() { super.layout(); changed?() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
