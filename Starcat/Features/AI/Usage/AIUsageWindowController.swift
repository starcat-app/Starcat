//
//  AIUsageWindowController.swift
//  Starcat
//
//  AI 用量统计面板的单例 AppKit 窗口外壳。
//

import AppKit
import SwiftUI

private enum AIUsageWindowMetrics {
    static let defaultContentSize = NSSize(width: 1_180, height: 780)
    static let minimumContentSize = NSSize(width: 980, height: 640)
    static let autosaveName = "AIUsageDashboardWindow"
}

/// 独立窗口避免占用主三栏和设置页的长期空间；重复打开只激活同一实例。
final class AIUsageWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: AIUsageWindowController?

    @MainActor
    static func show(dependencies: AppDependencies) {
        let controller: AIUsageWindowController
        if let shared {
            controller = shared
        } else {
            controller = AIUsageWindowController(dependencies: dependencies)
            shared = controller
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    private init(dependencies: AppDependencies) {
        let viewModel = AIUsageDashboardViewModel(repository: dependencies.aiUsageRepository)
        let content = AIUsageDashboardView(viewModel: viewModel)
            // 独立窗口统一走标准 hosting 环境，避免后续新增依赖时再次漏注入。
            .appHostEnvironment(dependencies)
        let hostingController = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hostingController)
        window.title = String.l10n("ai.usage.window.title")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(AIUsageWindowMetrics.defaultContentSize)
        window.contentMinSize = AIUsageWindowMetrics.minimumContentSize
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .windowBackgroundColor
        window.setFrameAutosaveName(AIUsageWindowMetrics.autosaveName)

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AIUsageWindowController does not support storyboard initialization")
    }
}
