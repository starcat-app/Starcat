//
//  SkillReviewWindowController.swift
//  Starcat
//
//  批量分配与更新审核共用固定 AppKit sheet。尺寸由 NSWindow 持有，
//  大列表和逐项进度不会触发 SwiftUI presentation bridge 的反复测量。
//

import AppKit
import SwiftUI

/// 只持有展示生命周期；所有计划、确认和运行状态属于传入的 SwiftUI 会话。
@MainActor
final class SkillReviewWindowController: NSWindowController, NSWindowDelegate {
    private static var active: SkillReviewWindowController?
    private var closing = false

    static func present<Content: View>(
        titleKey: String, size: NSSize = NSSize(width: 700, height: 600),
        @ViewBuilder content: (@escaping () -> Void) -> Content
    ) {
        if let active { active.window?.makeKeyAndOrderFront(nil); return }
        guard let parent = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false
        )
        let controller = SkillReviewWindowController(window: window)
        let root = content { [weak controller] in controller?.dismissReview() }.ignoresSafeArea(.container)
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.contentMinSize = size
        window.contentMaxSize = size
        window.title = String.l10n(titleKey)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isMovable = false
        window.backgroundColor = .windowBackgroundColor
        window.delegate = controller
        active = controller
        parent.beginSheet(window) { [weak controller] _ in controller?.finish() }
    }

    /// 不让系统关闭绕过页面的提交边界；页内取消会先等待当前项收口。
    func windowShouldClose(_ sender: NSWindow) -> Bool { false }

    private func dismissReview() {
        guard !closing, let window else { return }
        closing = true
        if let parent = window.sheetParent { parent.endSheet(window) }
        else { window.orderOut(nil); finish() }
    }

    private func finish() {
        window?.contentViewController = nil
        window = nil
        if Self.active === self { Self.active = nil }
    }
}
