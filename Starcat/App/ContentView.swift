//
//  ContentView.swift
//  Starcat
//
//  根视图：根据 AuthSession 状态在登录页与主界面之间切换。
//
//  Week 3 范围：
//  - .unauthenticated / .awaitingUserCode → GithubAuthView（V2 视觉升级版，2026-06-03 上线）
//  - .authenticated → HomeView（三栏布局）
//

import SwiftUI

struct ContentView: View {

    @Environment(AuthSession.self) private var authSession
    @Environment(AppDependencies.self) private var dependencies
    /// 2026-06-15:用户「关闭应用内动画」开 + 系统「减少动态效果」开
    /// 任一为真时,跳过登录态切换的 .smooth 隐式动画,避免内容树瞬切时
    /// 仍有 SwiftUI 默认 spring 残留。
    @Environment(\.starcatReduceMotion) private var reduceMotion
    /// splash / 首次引导期间隐藏 window toolbar。
    @Environment(\.firstRunOnboardingActive) private var firstRunOnboardingActive
    /// Agent Workspace 是主窗口沉浸式工作模式；打开时隐藏系统 window toolbar，
    /// 避免底层 HomeView 的 toolbar 与 Agent 自己的 run header 同时出现。
    @State private var agentWorkspaceActive: Bool = false

    /// 当用户主动点击"登录"按钮时（isAuthenticating = true）或 11 个详情页入口请求
    /// 弹登录 sheet 时（shouldShowLoginSheet = true）显示 GithubAuthView sheet。
    ///
    /// 2026-06-29 改造：增加 `shouldShowLoginSheet` 条件，让 11 个详情页的"未登录引导"
    /// 只弹 sheet 不强制走 Device Flow——sheet 弹出来是 idle 态，用户在 sheet 内自己选
    /// Device Flow / PAT。
    ///
    /// 注意：不使用 `!isAuthenticated` 作为条件，是为了避免应用启动时就弹出登录窗口，
    /// 用户需要先浏览 trending，点击详情遇到 403 后才主动登录。
    private var showAuthViewBinding: Binding<Bool> {
        Binding(
            get: { authSession.isAuthenticating || authSession.shouldShowLoginSheet },
            set: { _ in }
        )
    }

    var body: some View {
        HomeView(
            repository: dependencies.repoRepository,
            readmeAPI: dependencies.readmeAPI,
            readmeAvailability: dependencies.readmeAvailability,
            readmeOnHTMLLoaded: dependencies.makeReadmeOnHTMLLoadedHandler(),
            tagRepository: dependencies.tagRepository,
            repoTagRepository: dependencies.repoTagRepository,
            githubStarListRepository: dependencies.githubStarListRepository,
            repoNoteRepository: dependencies.repoNoteRepository,
            repoHealthRepository: dependencies.repoHealthRepository,
            releaseRepository: dependencies.releaseRepository,
            openSSFScoreRepository: dependencies.openSSFScoreRepository,
            smartCollectionRepository: dependencies.smartCollectionRepository,
            searchHistoryRepository: dependencies.searchHistoryRepository,
            semanticSearchService: dependencies.semanticSearchService,
            trendingRepository: dependencies.trendingRepository,
            githubAPIClient: dependencies.apiClient,
            readmeTranslationService: dependencies.readmeTranslationService,
            entitlementGate: dependencies.entitlementGate,
            telemetryManager: dependencies.telemetryManager
        )
        // 这里的 SwiftUI root minWidth 会参与系统窗口约束。
        // 旧值 800×600 会在 NavigationSplitView 自动折叠 sidebar 后重新成为窗口下限，
        // 导致中栏 420 + 右栏 770 被继续压缩。改成 AppKit 硬下限同源常量，
        // 保证折叠态也至少保住 RepoList + Detail 两列。
        .frame(
            minWidth: MainWindowFrameDefaults.contentMinSize.width,
            minHeight: MainWindowFrameDefaults.contentMinSize.height
        )
        .mainWindowFrameAutosave()
        // 让三栏内容背景延伸到 window toolbar 下方，避免 toolbar 的独立实色背景
        // 与 Sidebar / Repo detail 顶部渐变形成横向硬分界。各栏仍自行决定背景颜色，
        // 这里只移除系统 toolbar 的遮挡，不改变 toolbar item 的布局与交互。
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbarVisibility(firstRunOnboardingActive || agentWorkspaceActive ? .hidden : .visible, for: .windowToolbar)
        .onPreferenceChange(AgentWorkspaceActivePreferenceKey.self) { isActive in
            agentWorkspaceActive = isActive
        }
        .animation(reduceMotion ? nil : .smooth, value: authSession.state)
        // 2026-06-29：.onOpenURL 已移到 StarcatApp 顶层（更早注册 NSAppleEventManager，
        // 避免 view 还没 mount 时 URL event 丢失）。这里不再重复挂。
        .sheet(isPresented: showAuthViewBinding) {
            GithubAuthView()
                .appLocaleEnvironment()
        }
    }
}

/// 子视图向 `ContentView` 回传 Agent 工作台是否正在覆盖主窗口。
///
/// 用 PreferenceKey 而不是把 `showAgentWorkspace` 提升到 App 级状态，是为了保持入口仍在
/// `HomeView`/`RepoListView` 内部，同时让根视图能控制 window toolbar 可见性。
struct AgentWorkspaceActivePreferenceKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}
