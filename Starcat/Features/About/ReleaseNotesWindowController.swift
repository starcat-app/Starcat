//
//  ReleaseNotesWindowController.swift
//  Starcat
//
//  Help → 更新说明 的 AppKit 单例窗口外壳。
//
//  与 AboutWindowController 同模式：重复打开复用同一窗口，内容由 SwiftUI
//  ReleaseNotesView 渲染；changelog 仍来自 bundle 内 CHANGELOG / CHANGELOG-ZH。
//

import AppKit
import SwiftUI

/// Release Notes 窗口尺寸。
///
/// 默认高度比旧版略高，减少最新版长条目在首屏被裁切的观感。
/// 最大宽度限制正文行长，最大高度则确保窗口在常见 MacBook 可视区域内仍可完整操作。
private enum ReleaseNotesWindowMetrics {
    static let defaultContentSize = NSSize(width: 640, height: 580)
    static let minimumContentSize = NSSize(width: 560, height: 460)
    static let maximumContentSize = NSSize(width: 960, height: 820)
}

/// App 内静态版本说明窗口。
///
/// 不接 Sparkle / GitHub Releases 自动更新链路，避免 Help 菜单入口引入额外网络语义。
final class ReleaseNotesWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: ReleaseNotesWindowController?

    @MainActor
    static func show() {
        let controller: ReleaseNotesWindowController
        let shouldCenter: Bool

        if let shared {
            controller = shared
            shouldCenter = false
        } else {
            controller = ReleaseNotesWindowController()
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
        let content = ReleaseNotesView()
            .starcatAnimationOverride()
            .appLocaleEnvironment()
            .environment(AppSettings.shared)
        let hostingController = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hostingController)

        window.title = String.l10n("releaseNotes.window.title")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(ReleaseNotesWindowMetrics.defaultContentSize)
        window.contentMinSize = ReleaseNotesWindowMetrics.minimumContentSize
        window.minSize = ReleaseNotesWindowMetrics.minimumContentSize
        window.contentMaxSize = ReleaseNotesWindowMetrics.maximumContentSize
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .windowBackgroundColor

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ReleaseNotesWindowController does not support storyboard initialization")
    }

    /// 在用户拖拽期间钳制窗口外框尺寸。
    ///
    /// `NSHostingController` 的内容使用 Auto Layout，AppKit 会忽略 `minSize` /
    /// `maxSize` 这一类普通窗口约束，因此必须在 delegate 回调里限制实际拖拽结果。
    /// 配置值描述的是 content 尺寸，这里先换算为包含标题栏的 window frame 尺寸。
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let minimumFrameSize = sender.frameRect(
            forContentRect: NSRect(origin: .zero, size: ReleaseNotesWindowMetrics.minimumContentSize)
        ).size
        let maximumFrameSize = sender.frameRect(
            forContentRect: NSRect(origin: .zero, size: ReleaseNotesWindowMetrics.maximumContentSize)
        ).size

        return NSSize(
            width: min(max(frameSize.width, minimumFrameSize.width), maximumFrameSize.width),
            height: min(max(frameSize.height, minimumFrameSize.height), maximumFrameSize.height)
        )
    }

    func windowWillClose(_ notification: Notification) {
        window?.resignKey()
    }
}
