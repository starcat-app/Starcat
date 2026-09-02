//
//  BorderBeamSearchLabWindowController.swift
//  Starcat
//
//  Border Beam 搜索实验窗口的 AppKit 外壳。
//
//  为什么用 NSWindowController：
//  - 与 About 窗口一致，重复打开只激活同一实例；
//  - 整段 `#if DEBUG`，Release 菜单与场景都不暴露实验入口。
//

#if DEBUG
import AppKit
import SwiftUI

/// Border Beam Search Lab 窗口尺寸。
private enum BorderBeamSearchLabWindowMetrics {
    static let defaultContentSize = NSSize(width: 640, height: 480)
    static let minimumContentSize = NSSize(width: 520, height: 400)
}

/// DEBUG-only 实验窗口控制器。
@MainActor
final class BorderBeamSearchLabWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: BorderBeamSearchLabWindowController?

    /// 显示或前置实验窗口。
    static func show() {
        let controller: BorderBeamSearchLabWindowController
        let shouldCenter: Bool

        if let shared {
            controller = shared
            shouldCenter = false
        } else {
            controller = BorderBeamSearchLabWindowController()
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
        // Lab 是独立 AppKit 窗口，不继承主 WindowGroup 环境；动画与 locale 需显式注入。
        let content = BorderBeamSearchLabView()
            .starcatAnimationOverride()
            .appLocaleEnvironment()
            .environment(AppSettings.shared)
        let hostingController = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hostingController)

        // DEBUG 文案保持 verbatim，不进 String Catalog。
        window.title = "Border Beam Search Lab"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(BorderBeamSearchLabWindowMetrics.defaultContentSize)
        window.contentMinSize = BorderBeamSearchLabWindowMetrics.minimumContentSize
        window.minSize = BorderBeamSearchLabWindowMetrics.minimumContentSize
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BorderBeamSearchLabWindowController does not support storyboard initialization")
    }

    func windowWillClose(_ notification: Notification) {
        window?.resignKey()
    }
}
#endif
