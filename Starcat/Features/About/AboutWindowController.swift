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
        let hostingController = NSHostingController(rootView: AboutView())
        let window = NSWindow(contentViewController: hostingController)

        window.title = "关于 Starcat"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 680, height: 520))
        window.minSize = NSSize(width: 680, height: 520)
        window.maxSize = NSSize(width: 680, height: 520)
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
