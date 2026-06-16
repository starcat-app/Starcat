//
//  AboutWindowController.swift
//  Starcat
//
//  自定义关于窗口的 AppKit 外壳。
//
//  SwiftUI 的 Window scene 更适合声明式多窗口，但这里需要替换系统菜单的
//  "关于 Starcat"并保持单例窗口行为：重复 Cmd+I 应该把同一个窗口带到前台，
//  而不是创建一串副本。因此用 NSWindowController 承接窗口生命周期，内容仍由
//  SwiftUI 的 AboutView 负责。
//

import AppKit
import SwiftUI

/// 关于窗口的尺寸策略。
///
/// 宽度沿用 dong4j 截图里确认过的紧凑宽度；高度从 520pt 收到 450pt，
/// 因为当前 6 个 tab 的内容都不需要更高的默认窗口。
private enum AboutWindowMetrics {
    static let defaultContentSize = NSSize(width: 680, height: 450)
}

/// Starcat 自定义关于窗口控制器。
final class AboutWindowController: NSWindowController, NSWindowDelegate {

    /// 单例控制器。About 窗口是典型 utility window，重复打开时应复用。
    private static var shared: AboutWindowController?

    /// 显示关于窗口，并激活应用。
    @MainActor
    static func show() {
        let controller: AboutWindowController
        let shouldCenter: Bool

        if let shared {
            controller = shared
            shouldCenter = false
        } else {
            controller = AboutWindowController()
            shared = controller
            shouldCenter = true
        }

        controller.showWindow(nil)
        if shouldCenter {
            controller.window?.center()
        }
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init() {
        // About 同样是 AppKit 独立窗口，不继承 WindowGroup 的环境。
        // modifier 必须写在 environment 之前，让其内部能读到 AppSettings。
        // `.appLocaleEnvironment()` 同理:订阅 LocaleStore.shared 让用户在设置页
        // 切语言后此窗口同步刷新(否则永远跟随系统 locale 显示)。
        let content = AboutView()
            .starcatAnimationOverride()
            .appLocaleEnvironment()
            .environment(AppSettings.shared)
        let hostingController = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hostingController)

        window.title = String.l10n("app.about")
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(AboutWindowMetrics.defaultContentSize)
        // AboutView 只声明最小可用布局，固定尺寸边界必须由 AppKit 窗口层控制。
        window.contentMinSize = AboutWindowMetrics.defaultContentSize
        window.minSize = AboutWindowMetrics.defaultContentSize
        window.maxSize = AboutWindowMetrics.defaultContentSize
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .windowBackgroundColor

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AboutWindowController does not support storyboard initialization")
    }

    /// 用户关闭窗口后保留 controller，但释放 key/main 状态；下次 Cmd+I 复用同一窗口。
    func windowWillClose(_ notification: Notification) {
        window?.resignKey()
    }
}
