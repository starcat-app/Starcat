//
//  AwesomeSourceManagerWindowController.swift
//  Starcat
//
//  Awesome 来源管理的固定尺寸 AppKit sheet。与 AI 整理共用 840 × 560 画布，
//  禁止 SwiftUI 的内容尺寸协商将来源网格反向撑大成宽窗口。
//

import AppKit
import SwiftUI

/// 只管理窗口生命周期；勾选草稿、来源增删和保存仍由原有 View / Store 负责。
@MainActor
final class AwesomeSourceManagerWindowController: NSWindowController, NSWindowDelegate {
    static let contentSize = AIOrganizationLayout.windowSize

    private static var activeController: AwesomeSourceManagerWindowController?
    private weak var parentWindow: NSWindow?
    private var onDismiss: (() -> Void)?
    private var isDismissing = false

    /// 两个入口共用同一窗口；优先挂到当前设置或主窗口，而不是强制切回主窗口。
    static func present(dependencies: AppDependencies, onDismiss: @escaping () -> Void) {
        if let activeController {
            activeController.window?.makeKeyAndOrderFront(nil)
            return
        }

        let sourceWindow = NSApp.keyWindow ?? NSApp.mainWindow
        let parentWindow = sourceWindow?.sheetParent ?? sourceWindow
        // 来源快照已由 Store 在提出展示意图前加载，View 初始化即可捕获完整草稿。
        let content = AwesomeSourceManagerSheet(store: dependencies.awesomeStore)
            .appHostEnvironment(dependencies)
            .ignoresSafeArea(.container)
        let hostingController = NSHostingController(rootView: content)
        hostingController.sizingOptions = []

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = String.l10n("awesome.sources.title")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.contentMinSize = contentSize
        window.contentMaxSize = contentSize
        window.backgroundColor = .windowBackgroundColor
        hostingController.view.setFrameSize(contentSize)
        window.contentViewController = hostingController

        let controller = AwesomeSourceManagerWindowController(
            window: window, parentWindow: parentWindow, onDismiss: onDismiss
        )
        activeController = controller
        // 不在 SwiftUI 的 onChange 更新栈内开始 AppKit 模态展示。
        DispatchQueue.main.async { [weak controller] in
            controller?.presentFromSourceWindow()
        }
    }

    /// Store 完成保存、取消或切换账户后结束同一个窗口；重复关闭不产生额外回调。
    static func dismissIfPresented() {
        activeController?.dismiss()
    }

    private init(window: NSWindow, parentWindow: NSWindow?, onDismiss: @escaping () -> Void) {
        self.parentWindow = parentWindow
        self.onDismiss = onDismiss
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AwesomeSourceManagerWindowController does not support storyboard initialization")
    }

    /// 不排队挂到已失效或被其它 sheet 占用的父窗；无父窗时才退化为固定独立窗口。
    private func presentFromSourceWindow() {
        guard Self.activeController === self, !isDismissing, let window else { return }
        if let parentWindow {
            guard parentWindow.isVisible, parentWindow.attachedSheet == nil else {
                finishDismissal()
                return
            }
            parentWindow.beginSheet(window) { [weak self] _ in
                self?.finishDismissal()
            }
        } else {
            showWindow(nil)
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// 直接结束 AppKit sheet，不再进入 SwiftUI presentation bridge 的尺寸协商。
    private func dismiss() {
        guard !isDismissing else { return }
        isDismissing = true
        if let parentWindow, let window, parentWindow.attachedSheet === window {
            parentWindow.endSheet(window, returnCode: .cancel)
        } else {
            window?.orderOut(nil)
            finishDismissal()
        }
    }

    /// 先释放 hosting tree 再通知 Store，避免异步保存引发重复关闭。
    private func finishDismissal() {
        guard Self.activeController === self else { return }
        let callback = onDismiss
        onDismiss = nil
        window?.contentViewController = nil
        window = nil
        Self.activeController = nil
        callback?()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismiss()
        return false
    }
}
