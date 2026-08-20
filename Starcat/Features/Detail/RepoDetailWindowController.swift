//
//  RepoDetailWindowController.swift
//  Starcat
//
//  仓库详情完整独立窗。
//
//  ─────────────────────────────────────────────────────────
//  与 ReadmeWindowController 的视觉差异
//  ─────────────────────────────────────────────────────────
//
//  RepoDetailWindowController：
//  - 完整仓库详情页：hero（头像 + 全名 + badges）+ 元信息卡片
//    + README + AI 助手入口 + 翻译 + 分享 + Pro Health 入口
//  - 窗口标题 = 仓库全名（owner/repo）
//  - 同 repo 点击复用窗口（singleton），不同 repo 可同时开多个
//
//  ReadmeWindowController：
//  - 只有 README 正文 + 右下角浮动工具栏（字号调节 / 回到顶部）
//  - 无 hero、无元信息卡片、无 AI、无翻译、无分享
//  - 每次点击都开新窗口（不复用），方便对照阅读
//
//  一句话：RepoDetailWindow 是"围绕这个仓库做一切操作"的工作台；
//         ReadmeWindow 是"只看 README"的阅读器。
//
//  ─────────────────────────────────────────────────────────
//  设计要点
//  ─────────────────────────────────────────────────────────
//
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

        // 用 `RepoDetailWindowContent` 包装层持有 `ReadmeViewModel` / `ReadmeTranslationViewModel`：
        // 这两个 VM 是**单 repo 状态机**（与 `HomeView` / `WeeklyDetailScaffoldShell` 同模式），
        // 不在 `appHostEnvironment` 注入的标准 service 链里，必须在新窗自己 `@State` 创建
        // 并 `.environment(_:)` 注入，否则 `ManageDetailContent` 里 `@Environment(ReadmeViewModel.self)`
        // 读不到值会触发 SwiftUI 断言崩溃（首次实机崩溃即此原因）。
        let content = RepoDetailWindowContent(
            repo: repo,
            viewData: viewData,
            dependencies: dependencies,
            homeViewModel: homeViewModel
        )

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
    /// 新窗走全新 `RepoDetailScaffold` 链路，selectedRepo / readmeVM 等都重新
    /// 从 `repo` 派生。
    func windowWillClose(_ notification: Notification) {
        Self.instances.removeValue(forKey: repoId)
    }
}

// MARK: - RepoDetailWindowContent

/// 推荐详情独立窗的 SwiftUI 根视图（hosting controller 用）。
///
/// 关键职责：在 `@State` 里持有**单 repo 状态机**（`ReadmeViewModel` +
/// `ReadmeTranslationViewModel`），再注入到 environment 链。
///
/// 为什么需要这层包装：
/// - `ReadmeViewModel` / `ReadmeTranslationViewModel` 是按 repo 绑定的状态机（一个
///   详情窗一个实例，跨详情页不共享），不像 `AppDependencies` 里的全局 service 那样可以
///   在 `appHostEnvironment` 静态注入。
/// - `appHostEnvironment` 注入链只覆盖 10 个 service（authSession / settings / 等），
///   不含 `ReadmeViewModel`。
/// - `ManageDetailContent` 在 body 里用 `@Environment(ReadmeViewModel.self)` / `@Environment(ReadmeTranslationViewModel.self)`
///   读这两个 VM。如果不在这层新建并注入，新窗的 manage body 第一次渲染就会触发
///   `EnvironmentValues.subscript.getter` 的 `_assertionFailure` 崩溃
///   （实机首次崩溃即此原因，crash log 0x1b89e4e70 → RepoDetailWindowController:154）。
///
/// 与 `HomeView`（全局 manage VM）和 `WeeklyDetailScaffoldShell`（每 shell 局部 VM）
/// 的同款 pattern：每个详情展示位置自己持有 VM 自己注入。
struct RepoDetailWindowContent: View {
    let repo: Repo
    let viewData: RepoDetailViewData
    let dependencies: AppDependencies
    let homeViewModel: HomeViewModel

    /// 单 repo README 加载状态机（与 `HomeView._readmeVM` / `WeeklyDetailScaffoldShell.readmeVM` 同模式）。
    ///
    /// `api` / `availability` 走 `dependencies` 全局 service，`activeRepoId` 会在
    /// `body` 里随 repo 变化（这里 repo 固定，所以一次 load 就够）。
    @State private var readmeVM: ReadmeViewModel
    /// 翻译浮动入口对应的 VM。
    @State private var translationVM: ReadmeTranslationViewModel

    init(
        repo: Repo,
        viewData: RepoDetailViewData,
        dependencies: AppDependencies,
        homeViewModel: HomeViewModel
    ) {
        self.repo = repo
        self.viewData = viewData
        self.dependencies = dependencies
        self.homeViewModel = homeViewModel
        _readmeVM = State(initialValue: ReadmeViewModel(
            api: dependencies.readmeAPI,
            privateAPI: dependencies.projectReadmeAPI,
            availability: dependencies.readmeAvailability
        ))
        _translationVM = State(initialValue: ReadmeTranslationViewModel(
            service: dependencies.readmeTranslationService
        ))
    }

    var body: some View {
        RepoDetailScaffold(
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
        // 先把单 repo VM 注入 environment（`appHostEnvironment` 链不覆盖它们），
        // 再叠加标准 service 链（authSession / settings / subscriptionManager / 等）。
        // 顺序很关键：先 readmeVM / translationVM，再 appHostEnvironment，否则
        // `appHostEnvironment` 内部多次重写环境链时可能覆盖掉前面的注入。
        .environment(readmeVM)
        .environment(translationVM)
        .appHostEnvironment(dependencies, homeViewModel: homeViewModel)
        // 触发首次 README 加载 + 翻译态准备。
        //
        // 为什么需要这个 task：主窗 (`HomeView`) 的初次 README 加载是在
        // `.onChange(of: viewModel.selectedRepoID)` 里触发的（line 444-470），
        // 依赖"selectedRepo 变化"作为触发信号。新窗的 `repo` 是固定值（推荐项），
        // 没有"变化"可监 —— 必须显式 `.task` 在窗体首次出现时调一次
        // `readmeVM.load(...)`，否则 ReadmeStateView 永远显示 loading 骨架屏
        // （用户实机复现：hero 正常 + readme 一直在转圈）。
        //
        // 同步调 `translationVM.prepare(...)`：与 HomeView 同款（line 457-461），
        // 让翻译浮动按钮在 README 还没加载时也有占位 UI 状态，避免首次点击
        // 翻译浮层时拿到 nil 上下文。
        .task {
            readmeVM.load(
                repo: repo,
                isLoggedIn: dependencies.authSession.state.isAuthenticated
            )
            translationVM.prepare(
                repo: repo,
                sourceHtml: nil,
                targetLanguage: dependencies.settings.effectiveReadmeTranslationLanguage,
                mode: dependencies.settings.readmeTranslationMode
            )
        }
    }
}
