//
//  RepoAIWindowController.swift
//  Starcat
//
//  详情页 AI 助手浮动窗口的 AppKit 外壳（HOM-150）。
//
//  设计要点：
//  - **按 repo.id 复用单例**：同一仓库再点 AI 按钮不会开第二个窗口，而是把已有窗口
//    带到前台，避免堆积一批"同 repo 不同对话"的浮动窗口，与 macOS 用户的浮窗心智
//    （Finder 单文件 quicklook、Preview 单文件预览）对齐。
//  - **不同 repo 各自独立窗口**：用户可以同时开多个 repo 的 AI 助手做对比。
//  - **窗口关闭后释放控制器**：单例 map 在 `windowWillClose` 里清掉对应条目；
//    `isReleasedWhenClosed = false` 让 NSWindow 不在关闭时自动 dealloc，从而保留
//    NSHostingController 直到我们手动放手；下次再开会重建一个全新窗口与 VM。
//  - SwiftUI 内容通过 `.environment(_)` 注入 `AppDependencies` 与 `HomeViewModel`，
//    因为 AppKit 创建的 hosting controller 不会自动继承主窗的 environment 链。
//
//  参考：`AboutWindowController.swift` 同款单例模式。
//

import AppKit
import SwiftUI

/// 默认窗口尺寸与下限，集中在一处便于以后整体调优。
///
/// 调优历史：
/// - HOM-150 dong4j 2026-06-04 15:30："调整为更适合对话框的尺寸——宽度减少，
///   高度增加"→ 第一版 620 x 800。
/// - HOM-150 dong4j 2026-06-04 15:48："将 AI 窗口的默认宽度改成 540"→ 进一步收窄
///   到 540 x 800（约 2:3 比例），更贴近 ChatGPT 桌面端 / iPhone 对话界面比例。
private enum RepoAIWindowMetrics {
    /// 540 x 800：更瘦长（约 2:3 宽高比），单面板 + 输入框的 chat 形态最佳节奏。
    static let defaultContentSize = NSSize(width: 540, height: 800)
    /// 最小尺寸：低于 480 宽 / 600 高时输入条 + 气泡 + segmented toggle bar
    /// 会显得很拥挤。当前默认 540 - 60 = 还有约 1 档可继续收窄空间。
    static let minContentSize = NSSize(width: 480, height: 600)
}

/// 详情页 AI 助手窗口的控制器。
final class RepoAIWindowController: NSWindowController, NSWindowDelegate {

    /// repo.id → controller 单例 map。
    ///
    /// 用字典而不是单一 static var，是为了支持"多个 repo 同时各开一个窗口做对比"，
    /// 同时保留"同一 repo 重复点 AI 不重复开窗口"的体验。
    /// key 类型选 `Repo.ID`（当前为 Int64）而非 String，避免每次 lookup 都做一次
    /// 字符串化的隐式开销，也跟主窗 ViewModel 里其他按 id 索引的容器对齐。
    private static var instances: [Repo.ID: RepoAIWindowController] = [:]

    private let repoId: Repo.ID

    /// 显示给定 repo 的 AI 助手窗口；已开则把窗口带到前台。
    ///
    /// - Parameters:
    ///   - repo: 当前详情页选中的 repo。窗口 title / 上下文都来自这个对象。
    ///   - dependencies: 应用级依赖，注入到 SwiftUI 子树的 `@Environment` 里供
    ///     `RepoAIInsightViewModel` / `RepoAIChatViewModel` 构造时读取。
    ///   - homeViewModel: 主窗的 HomeViewModel，应用标签后用于触发 Sidebar / 列表
    ///     刷新。属性以强引用形式传给 SwiftUI environment（`HomeViewModel` 是 class），
    ///     不会循环引用——主窗关闭时 HomeViewModel 自然释放，AI 窗口里的弱引用回调
    ///     会安全失效。
    @MainActor
    static func show(
        repo: Repo,
        dependencies: AppDependencies,
        homeViewModel: HomeViewModel
    ) {
        if let existing = instances[repo.id] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = RepoAIWindowController(
            repo: repo,
            dependencies: dependencies,
            homeViewModel: homeViewModel
        )
        instances[repo.id] = controller
        controller.showWindow(nil)
        controller.window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(
        repo: Repo,
        dependencies: AppDependencies,
        homeViewModel: HomeViewModel
    ) {
        self.repoId = repo.id

        // `.environment` 必须在 hosting root 上挂——SwiftUI 子树才能正确读到
        // `@Environment(AppDependencies.self)` / `@Environment(HomeViewModel.self)`。
        // 这里同时挂上 settings，因为部分子视图（未来如果引入主题相关 modifier）
        // 会读 settings；与主窗 `StarcatApp` 给 ContentView 注入的链路对齐。
        let content = RepoAIWindowContentView(repo: repo)
            .environment(dependencies)
            .environment(dependencies.authSession)
            .environment(dependencies.settings)
            .environment(homeViewModel)

        let hostingController = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hostingController)

        window.title = "\(repo.fullName) · AI 助手"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(RepoAIWindowMetrics.defaultContentSize)
        window.contentMinSize = RepoAIWindowMetrics.minContentSize
        window.minSize = RepoAIWindowMetrics.minContentSize
        // 窗口关闭后不自动释放，让 controller 的 windowWillClose 里完成清理
        // （与 AboutWindowController 一致）。
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RepoAIWindowController does not support storyboard initialization")
    }

    /// 窗口关闭：从单例 map 中移除自己，下次打开会重建一个全新窗口 + 全新 VM
    /// （清空对话历史，符合 HOM-150 验收"对话存储可选，建议内存中，不持久化"）。
    func windowWillClose(_ notification: Notification) {
        Self.instances.removeValue(forKey: repoId)
    }
}
