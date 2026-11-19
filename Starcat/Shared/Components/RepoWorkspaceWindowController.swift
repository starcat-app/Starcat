//
//  RepoWorkspaceWindowController.swift
//  Starcat
//
//  仓库 Issues、Skills 和文件浏览共用的固定画布。尺寸由 AppKit 独占，
//  内容加载、折叠及本地化更新不能反向触发 SwiftUI sheet 的尺寸协商。
//

import AppKit
import SwiftUI

/// 只负责窗口所有权；各工作区通过关闭回调保存草稿、取消任务和释放会话。
@MainActor
final class RepoWorkspaceWindowController: NSWindowController, NSWindowDelegate {
    private static var activeControllers: [String: RepoWorkspaceWindowController] = [:]
    private weak var parentWindow: NSWindow?
    private var identifier = ""
    private var onDismiss: (() -> Void)?
    private var isDismissing = false

    /// 以实际宿主屏幕的可见区计算一次，不用下限将窗口撑出小屏幕。
    static func contentSize(available: NSSize?) -> NSSize {
        let available = available ?? NSSize(width: 1_244, height: 800)
        return NSSize(width: max(1, min(1_180, available.width - 64)),
                      height: max(1, min(720, available.height - 80)))
    }

    /// 调用者必须从自己的 View 读取父窗口，避免多窗口场景挂到别的主窗口。
    @discardableResult
    static func present<Content: View>(
        identifier: String,
        title: String,
        parent: NSWindow?,
        dependencies: AppDependencies,
        fixedSize: NSSize? = nil,
        onDismiss: @escaping () -> Void = {},
        @ViewBuilder content: (@escaping () -> Void) -> Content
    ) -> RepoWorkspaceWindowController? {
        let key = "\(parent?.windowNumber ?? -1):\(identifier)"
        if let active = activeControllers[key] {
            active.window?.makeKeyAndOrderFront(nil)
            return active
        }
        if let sheet = parent?.attachedSheet {
            sheet.makeKeyAndOrderFront(nil)
            return nil
        }
        let size = fixedSize ?? contentSize(available: parent?.screen?.visibleFrame.size ?? NSScreen.main?.visibleFrame.size)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false
        )
        let controller = RepoWorkspaceWindowController(window: window)
        controller.identifier = key
        controller.parentWindow = parent
        controller.onDismiss = onDismiss
        let host = NSHostingController(rootView: content { [weak controller] in
            controller?.dismissWorkspace()
        }.appHostEnvironment(dependencies).ignoresSafeArea(.container))
        host.sizingOptions = []
        host.view.frame = NSRect(origin: .zero, size: size)
        window.contentViewController = host
        window.contentMinSize = size
        window.contentMaxSize = size
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        window.delegate = controller
        activeControllers[key] = controller
        if let parent {
            parent.beginSheet(window) { [weak controller] _ in controller?.releaseWorkspace() }
        } else {
            controller.showWindow(nil)
            window.center()
        }
        return controller
    }

    /// 关闭动作幂等；先清理业务，再拆 hosting tree，外部结束 sheet 也走相同清理。
    func dismissWorkspace() {
        guard !isDismissing else { return }
        isDismissing = true
        performCleanup()
        guard let window else { return }
        if let parentWindow, parentWindow.attachedSheet === window {
            parentWindow.endSheet(window)
        } else {
            window.orderOut(nil)
            releaseWorkspace()
        }
    }

    private func performCleanup() {
        let cleanup = onDismiss
        onDismiss = nil
        cleanup?()
    }

    private func releaseWorkspace() {
        performCleanup()
        window?.orderOut(nil)
        window?.contentViewController = nil
        window = nil
        Self.activeControllers[identifier] = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismissWorkspace()
        return false
    }
}
