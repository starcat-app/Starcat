//
//  RepoSkillWindowController.swift
//  Starcat
//
//  Skill 安装工作区的固定 AppKit sheet 外壳。三栏尺寸由窗口持有，避免内容参与 fitting-size 协商。
//

import AppKit
import SwiftUI

/// 窗口只负责承载和关闭；来源、目录与批次由独立会话持有。
@MainActor
final class RepoSkillWindowController: NSWindowController, NSWindowDelegate {
    private static var activeController: RepoSkillWindowController?
    private weak var parentWindow: NSWindow?
    private var session: RepoSkillSession?

    /// 每次打开绑定当前真实仓库；同一时刻只允许一个安装 sheet。
    static func present(repo: Repo, dependencies: AppDependencies) {
        if let activeController {
            activeController.window?.makeKeyAndOrderFront(nil)
            return
        }

        let parent = NSApp.mainWindow ?? NSApp.keyWindow
        // 只在打开前计算一次画布；较小屏幕适当收窄，内容更新不反向驱动窗口尺寸。
        let available = parent?.screen?.visibleFrame.size ?? NSScreen.main?.visibleFrame.size
        let size = NSSize(
            width: min(1_180, (available?.width ?? 1_244) - 64),
            height: min(720, (available?.height ?? 800) - 80)
        )
        var closeAction: (() -> Void)?
        let session = RepoSkillSession(repo: repo, store: dependencies.repoSkillStore)
        let content = RepoSkillSheet(
            session: session,
            onClose: { closeAction?() }
        )
        .appHostEnvironment(dependencies)
        .ignoresSafeArea(.container)
        let host = NSHostingController(rootView: content)
        host.sizingOptions = []
        host.view.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = host
        window.contentMinSize = size
        window.contentMaxSize = size
        window.title = String.l10n("repo.skills.preview.title")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        let controller = RepoSkillWindowController(window: window)
        controller.session = session
        window.delegate = controller
        closeAction = { [weak controller] in controller?.dismissPreview() }
        activeController = controller

        if let parent, parent !== window {
            controller.parentWindow = parent
            parent.beginSheet(window) { [weak controller] _ in controller?.releasePreview() }
        } else {
            controller.showWindow(nil)
            window.center()
        }
    }

    /// 关闭先取消安装；会话完成暂存清理后才释放安全目录授权。
    private func dismissPreview() {
        session?.close()
        guard let window else { return }
        if let parentWindow, parentWindow.attachedSheet === window {
            parentWindow.endSheet(window)
        } else {
            window.orderOut(nil)
            releasePreview()
        }
    }

    private func releasePreview() {
        session = nil
        window?.contentViewController = nil
        window = nil
        Self.activeController = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismissPreview()
        return false
    }
}
