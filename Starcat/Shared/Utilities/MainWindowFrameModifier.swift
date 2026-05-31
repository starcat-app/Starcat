//
//  MainWindowFrameModifier.swift
//  Starcat
//
//  登录后的主窗口尺寸与位置管理。
//
//  SwiftUI 的 `.defaultSize(...)` 只在 WindowGroup 创建窗口时给初始建议尺寸；
//  Starcat 登录成功时是在同一个窗口内从登录页切到 HomeView，因此需要在
//  HomeView 真正进入窗口后，通过 NSWindow 接入 AppKit 的 frame autosave 机制。
//

import AppKit
import SwiftUI

enum MainWindowFrameDefaults {
    static let autosaveName = "Starcat.MainWindow"
    static let defaultSize = CGSize(width: 1800, height: 900)

    /// AppKit 保存窗口 frame 的 UserDefaults key 约定。
    ///
    /// 这里显式检查 key，是为了区分：
    /// - 首次登录：没有保存记录，主动给三栏主页一个 1800x900 的默认尺寸
    /// - 后续启动：已有保存记录，优先恢复用户上次拖拽后的尺寸与位置
    static var defaultsKey: String {
        "NSWindow Frame \(autosaveName)"
    }
}

private struct MainWindowFrameModifier: ViewModifier {
    let defaultSize: CGSize

    func body(content: Content) -> some View {
        content
            .background {
                MainWindowFrameReader(defaultSize: defaultSize)
                    .frame(width: 0, height: 0)
            }
    }
}

/// 通过一个不可见 NSView 拿到承载当前 SwiftUI View 的 NSWindow。
///
/// 约束：不要把这个 reader 放到 Settings 或其他独立窗口里，否则会复用同一个
/// autosaveName，导致不同窗口互相覆盖 frame。当前只在 HomeView 根节点挂载。
private struct MainWindowFrameReader: NSViewRepresentable {
    let defaultSize: CGSize

    func makeCoordinator() -> Coordinator {
        Coordinator(defaultSize: defaultSize)
    }

    func makeNSView(context: Context) -> WindowReaderView {
        let view = WindowReaderView()
        view.onMoveToWindow = { [weak coordinator = context.coordinator] window in
            coordinator?.configure(window: window)
        }
        return view
    }

    func updateNSView(_ nsView: WindowReaderView, context: Context) {
        context.coordinator.defaultSize = defaultSize
        context.coordinator.configure(window: nsView.window)
    }

    final class Coordinator {
        var defaultSize: CGSize
        private var didConfigure = false

        init(defaultSize: CGSize) {
            self.defaultSize = defaultSize
        }

        func configure(window: NSWindow?) {
            guard let window, !didConfigure else { return }
            didConfigure = true

            let hasSavedFrame = UserDefaults.standard.object(
                forKey: MainWindowFrameDefaults.defaultsKey
            ) != nil

            // setFrameAutosaveName 启用 AppKit 原生持久化：用户拖拽修改尺寸/位置后，
            // AppKit 会写入 UserDefaults，并在下次设置相同 autosaveName 时恢复。
            window.setFrameAutosaveName(MainWindowFrameDefaults.autosaveName)

            if hasSavedFrame, window.setFrameUsingName(MainWindowFrameDefaults.autosaveName) {
                return
            }

            applyInitialFrame(to: window)
        }

        private func applyInitialFrame(to window: NSWindow) {
            let visibleFrame = window.screen?.visibleFrame
                ?? NSScreen.main?.visibleFrame
                ?? window.frame

            // 默认 1800x900 是三栏主页的理想尺寸；如果用户屏幕可视区域更小，
            // 需要裁到屏幕内，避免首次登录后窗口超出可见范围。
            let targetSize = CGSize(
                width: min(defaultSize.width, visibleFrame.width),
                height: min(defaultSize.height, visibleFrame.height)
            )

            let targetOrigin = CGPoint(
                x: visibleFrame.midX - targetSize.width / 2,
                y: visibleFrame.midY - targetSize.height / 2
            )

            window.setFrame(
                CGRect(origin: targetOrigin, size: targetSize),
                display: true,
                animate: false
            )
        }
    }
}

private final class WindowReaderView: NSView {
    var onMoveToWindow: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onMoveToWindow?(window)
    }
}

extension View {
    /// 为登录后的主窗口启用默认尺寸与 AppKit frame autosave。
    ///
    /// 使用方式：挂在 HomeView 根节点，确保登录页小窗口不会被强制放大，
    /// 同时用户关闭/重开 App 后能恢复上次的窗口尺寸和位置。
    func mainWindowFrameAutosave(
        defaultSize: CGSize = MainWindowFrameDefaults.defaultSize
    ) -> some View {
        modifier(MainWindowFrameModifier(defaultSize: defaultSize))
    }
}
