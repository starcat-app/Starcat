//
//  DailyRadarWindowChromeModifier.swift
//  Starcat
//
//  每日热点覆盖层的整窗 titlebar 切换桥。
//  SwiftUI 只能隐藏 windowToolbar 内容，不能移除系统 titlebar 的结构占位；
//  因此这里用最小的 AppKit 接入临时启用 fullSizeContentView。
//

import AppKit
import SwiftUI

private struct DailyRadarWindowChromeModifier: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        content
            .background {
                DailyRadarWindowChromeReader(isEnabled: isEnabled)
                    .frame(width: 0, height: 0)
            }
    }
}

/// 只管理当前主窗口的 titlebar 状态；不持有窗口，也不影响 Settings / 工作台窗口。
@MainActor
private struct DailyRadarWindowChromeReader: NSViewRepresentable {
    let isEnabled: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isEnabled: isEnabled)
    }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onMoveToWindow = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.attach(to: nsView.window)
    }

    static func dismantleNSView(_ nsView: ProbeView, coordinator: Coordinator) {
        nsView.onMoveToWindow = nil
        coordinator.restore()
        coordinator.attach(to: nil)
    }

    @MainActor
    final class Coordinator {
        var isEnabled: Bool

        /// 首次附加窗口时记录原始状态；关闭覆盖层或视图销毁时按快照恢复。
        private var originalState: OriginalState?
        private weak var window: NSWindow?

        init() {
            isEnabled = false
        }

        init(isEnabled: Bool) {
            self.isEnabled = isEnabled
        }

        func attach(to newWindow: NSWindow?) {
            guard window !== newWindow else {
                apply(isEnabled: isEnabled)
                return
            }

            restore()
            window = newWindow
            originalState = newWindow.map(OriginalState.init)
            apply(isEnabled: isEnabled)
        }

        private func apply(isEnabled: Bool) {
            guard let window else { return }
            guard isEnabled else {
                restore()
                return
            }

            // 首次启用前保存快照，防止后续 SwiftUI update 顺序让原始状态丢失。
            if originalState == nil {
                originalState = OriginalState(window: window)
            }
            window.styleMask.insert(.fullSizeContentView)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
        }

        /// dismantleNSView 在 Reader 类型作用域调用，不能标记 private。
        func restore() {
            guard let window, let originalState else { return }
            if originalState.hasFullSizeContentView {
                window.styleMask.insert(.fullSizeContentView)
            } else {
                window.styleMask.remove(.fullSizeContentView)
            }
            window.titleVisibility = originalState.titleVisibility
            window.titlebarAppearsTransparent = originalState.titlebarAppearsTransparent
            self.originalState = nil
        }
    }

    @MainActor
    private struct OriginalState {
        let hasFullSizeContentView: Bool
        let titleVisibility: NSWindow.TitleVisibility
        let titlebarAppearsTransparent: Bool

        init(window: NSWindow) {
            hasFullSizeContentView = window.styleMask.contains(.fullSizeContentView)
            titleVisibility = window.titleVisibility
            titlebarAppearsTransparent = window.titlebarAppearsTransparent
        }
    }

    @MainActor
    final class ProbeView: NSView {
        var onMoveToWindow: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onMoveToWindow?(window)
        }
    }
}

extension View {
    /// 在 DailyRadar 覆盖中右内容区时临时切换主窗口 titlebar；关闭后恢复原状态。
    func dailyRadarFullSizeWindowChrome(isEnabled: Bool) -> some View {
        modifier(DailyRadarWindowChromeModifier(isEnabled: isEnabled))
    }
}
