//
//  RepoDetailWindowController.swift
//  Starcat
//
//  推荐卡片点击开的「详情独立窗」AppKit 外壳。
//
//  设计要点：
//  - 跟 `RepoAIWindowController` 同款 singleton map 模式（`repo.id → controller`）。
//    同 repo 重复点击不重开，把已有窗带到前台；不同 repo 可同时开多个做对比。
//  - NSWindow（非 NSPanel）—— detail 窗是「主内容载体」，需要 traffic light +
//    title bar，跟主窗一样是 normal-level 窗口。
//  - 内容用 `RepoDetailScaffold` + `ManageDetailContent`，构造与主窗 Manage 详情
//    一致的 viewData（已 star 本地 repo 的标准形态：含 .share + .ai 两个 trailing
//    actions + Pro Health 入口）。
//  - 关窗时从 singleton map 清掉自己（`isReleasedWhenClosed = false` 让
//    NSWindow 不在关闭时自动 dealloc）。
//  - `appHostEnvironment` 注入 AppDependencies + HomeViewModel（标准独立窗口
//    environment 链，与 AI 浮窗一致）。
//
//  与 in-place 导航的对比：
//  - in-place：复用主窗 detail panel，跨 selection 切换会触发 reload +
//    selectedRepoID 清理，存在「卡加载」体感问题。
//  - 新窗口：独立状态，singleton 复用窗口壳；新窗口自己的 selectedRepo 直接
//    来自 `repo` 入参，不需要再回 `homeViewModel.filteredSorted` 查找。
//

import AppKit
import SwiftUI

/// 默认窗口尺寸 800×700：主窗减 sidebar 后的 detail 区域比例。
/// 最小尺寸 600×500：低于此值 hero 头像 + fullName + badge row 会拥挤。
private enum RepoDetailWindowMetrics {
    static let defaultContentSize = NSSize(width: 800, height: 700)
    static let minContentSize = NSSize(width: 600, height: 500)
}

/// 推荐卡片点击后开的「详情独立窗」控制器。
final class RepoDetailWindowController: NSWindowController, NSWindowDelegate {

    /// repo.id → controller 单例 map。
    ///
    /// 与 `RepoAIWindowController.instances` 同模式：字典 + repo.id key，
    /// 支持「多 repo 同时各开一个窗」+「同 repo 重复点击不重开」。
    private static var instances: [Repo.ID: RepoDetailWindowController] = [:]

    private let repoId: Repo.ID
    /// `contentViewController` 持有 hosting controller，确保 SwiftUI 生命周期与
    /// AppKit 窗口一致；`isReleasedWhenClosed = false` 保证关闭时 controller 不被
    /// 立刻 dealloc，让我们能在 `windowWillClose` 里清 singleton。
    private let hostedContentController: NSViewController

    /// 显示给定 repo 的详情独立窗；已开则把窗口带到前台。
    ///
    /// - Parameters:
    ///   - repo: 推荐卡片指向的本地 starred repo（必须有完整 Repo 数据，
    ///     因为详情 viewData 从 `Repo` 派生 hero / starHelp / readmeVM 等）。
    ///   - dependencies: 应用级依赖，注入到 SwiftUI 子树的 `@Environment` 里。
    ///   - homeViewModel: 主窗的 HomeViewModel，让新窗口能共享 StarredRegistry 等
    ///     全局状态（star/unstar 后两窗同步刷新）。
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

        let controller = RepoDetailWindowController(
            repo: repo,
            dependencies: dependencies,
            homeViewModel: homeViewModel
        )
        instances[repo.id] = controller
        controller.showWindow(nil)
        cascadePosition(controller.window)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 第一次开窗：居中。之后开不同 repo：从主窗右上角 cascade 偏移，
    /// 与 macOS 多文档 App（如 Pages / Numbers）开多窗行为对齐。
    @MainActor
    private static func cascadePosition(_ window: NSWindow?) {
        guard let window else { return }
        if let mainWindow = NSApp.windows.first(where: { windowCandidate in
            windowCandidate !== window
                && windowCandidate.isVisible
                && !windowCandidate.title.isEmpty
        }) {
            // 主窗右上角往内偏 20pt，避免遮住主窗的 traffic light
            let origin = NSPoint(
                x: mainWindow.frame.maxX - window.frame.width - 20,
                y: mainWindow.frame.maxY - window.frame.height - 20
            )
            window.setFrameOrigin(origin)
        } else {
            window.center()
        }
    }

    private init(
        repo: Repo,
        dependencies: AppDependencies,
        homeViewModel: HomeViewModel
    ) {
        self.repoId = repo.id

        // 标准有标题窗口：traffic light + close + miniaturize + resize。
        // 不做 glass / borderless —— 这是 detail 内容窗，不是浮窗，需要全功能。
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: RepoDetailWindowMetrics.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        // viewData 复用 Manage 详情页同形态：已 star local repo 应展示 share + ai
        // 两个 trailing actions、Pro Health 入口、starHelp = "repo.unstar"。
        // translation context 透传 fullName（ReadmeStateView 用来拼接 cache key）。
        let viewData = RepoDetailViewData(
            hero: RepoDetailHero(repo: repo),
            trailingActions: [.share, .ai],
            translation: ReadmeTranslationContext(fullName: repo.fullName),
            backendHint: nil
        )

        // body 槽用 ManageDetailContent —— 已 star 本地 repo 的标准 README 视图。
        // heroExtension 槽给空 View（Manage / Weekly / Activity 等 manage 场景同款）。
        let content = RepoDetailScaffold(
            repo: repo,
            viewData: viewData,
            starHelpKey: "repo.unstar",
            showsRepoHealthEntry: true,
            onStarTapped: {
                // 推荐窗里的 star 点击：本地已 star → 触发 unstar。
                // StarredRegistry @Observable 变更会自动驱动主窗 list + 主窗 hero
                // 同步刷新（AppDependencies 共享）。
                try await dependencies.starActionService.unstar(repo: repo)
            },
            heroExtension: { EmptyView() },
            body: { onScrollReport in
                ManageDetailContent(repo: repo, onScrollReport: onScrollReport)
            }
        )
        .appHostEnvironment(dependencies, homeViewModel: homeViewModel)

        let hostingController = NSHostingController(rootView: content)
        self.hostedContentController = hostingController

        window.contentViewController = hostingController
        window.title = repo.fullName
        window.setContentSize(RepoDetailWindowMetrics.defaultContentSize)
        window.contentMinSize = RepoDetailWindowMetrics.minContentSize
        window.minSize = RepoDetailWindowMetrics.minContentSize
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RepoDetailWindowController does not support storyboard initialization")
    }

    /// 窗口关闭：从单例 map 中移除自己，下次 `show(repo:)` 会重建一个全新窗口。
    /// 新窗口走全新 `RepoDetailScaffold` 链路，selectedRepo / readmeVM 等都重新
    /// 从 `repo` 派生。
    func windowWillClose(_ notification: Notification) {
        Self.instances.removeValue(forKey: repoId)
    }
}
