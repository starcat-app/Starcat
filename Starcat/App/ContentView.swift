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
    @State private var showDataContributionConsent = false
    @State private var dataContributionConsentDraft = false
    @State private var dataContributionPromptAccountID: Int64?

    private let dataContributionPromptPreferences = DataContributionConsentPromptPreferences()
    /// 2026-06-15:用户「关闭应用内动画」开 + 系统「减少动态效果」开
    /// 任一为真时,跳过登录态切换的 .smooth 隐式动画,避免内容树瞬切时
    /// 仍有 SwiftUI 默认 spring 残留。
    @Environment(\.starcatReduceMotion) private var reduceMotion
    /// splash / 首次引导期间隐藏 window toolbar。
    @Environment(\.firstRunOnboardingActive) private var firstRunOnboardingActive
    /// 当用户主动点击"登录"按钮时（isAuthenticating = true）或 11 个详情页入口请求
    /// 弹登录 sheet 时（shouldShowLoginSheet = true）显示 GithubAuthView sheet。
    ///
    /// 2026-06-29 改造：增加 `shouldShowLoginSheet` 条件，让 11 个详情页的"未登录引导"
    /// 只弹 sheet 不预设 flow——App Store 只展示 Web Flow；Direct 另外提供 Device Flow 与 PAT。
    ///
    /// 注意：不使用 `!isAuthenticated` 作为条件，是为了避免应用启动时就弹出登录窗口，
    /// 用户需要先浏览 trending，点击详情遇到 403 后才主动登录。
    private var showAuthViewBinding: Binding<Bool> {
        Binding(
            get: { authSession.isAuthenticating || authSession.shouldShowLoginSheet },
            set: { _ in }
        )
    }

    /// 把登录、数据库切换、首次引导和登录 Sheet 合并成一个 task identity。
    /// 任一边界变化都会取消旧判断，避免缓存用户先恢复、数据库尚未切换时为错误账户弹窗。
    private var dataContributionPromptEvaluationID: DataContributionPromptEvaluationID {
        DataContributionPromptEvaluationID(
            authenticatedAccountID: authSession.state.user?.id,
            databaseAccountID: dependencies.database.currentUserId,
            databaseScopeRevision: dependencies.databaseScopeRevision,
            isOnboardingActive: firstRunOnboardingActive,
            isAuthSheetPresented: showAuthViewBinding.wrappedValue
        )
    }

    var body: some View {
        HomeView(
            repository: dependencies.repoRepository,
            readmeAPI: dependencies.readmeAPI,
            projectReadmeAPI: dependencies.projectReadmeAPI,
            readmeAvailability: dependencies.readmeAvailability,
            readmeOnHTMLLoaded: dependencies.makeReadmeOnHTMLLoadedHandler(),
            tagRepository: dependencies.tagRepository,
            repoTagRepository: dependencies.repoTagRepository,
            githubStarListRepository: dependencies.githubStarListRepository,
            repoNoteRepository: dependencies.repoNoteRepository,
            repoHealthRepository: dependencies.repoHealthRepository,
            releaseRepository: dependencies.releaseRepository,
            releaseSubscriptionRepository: dependencies.releaseSubscriptionRepository,
            openSSFScoreRepository: dependencies.openSSFScoreRepository,
            smartCollectionRepository: dependencies.smartCollectionRepository,
            searchHistoryRepository: dependencies.searchHistoryRepository,
            semanticSearchService: dependencies.semanticSearchService,
            myInsightsSnapshotProvider: dependencies.myInsightsSnapshotProvider,
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
        .toolbarVisibility(firstRunOnboardingActive ? .hidden : .visible, for: .windowToolbar)
        .animation(reduceMotion ? nil : .smooth, value: authSession.state)
        // 2026-06-29：.onOpenURL 已移到 StarcatApp 顶层（更早注册 NSAppleEventManager，
        // 避免 view 还没 mount 时 URL event 丢失）。这里不再重复挂。
        .sheet(isPresented: showAuthViewBinding) {
            GithubAuthView()
                .appLocaleEnvironment()
        }
        .sheet(isPresented: $showDataContributionConsent) {
            DataContributionConsentSheet(
                isEnabled: $dataContributionConsentDraft,
                onClose: handleDataContributionPromptClose,
                onSave: handleDataContributionPromptSave
            )
            .appLocaleEnvironment()
        }
        .task(id: dataContributionPromptEvaluationID) {
            await evaluateDataContributionPrompt()
        }
    }

    /// 启动遮罩退出后再判断一次账户级授权提示；短暂延迟让 splash / 首次引导的
    /// 退出动画先收口，避免 SwiftUI 在同一帧撤 overlay 又 present Sheet。
    private func evaluateDataContributionPrompt() async {
        let evaluationID = dataContributionPromptEvaluationID
        guard !TestEnvironment.isRunning else { return }

        let delay: Duration = reduceMotion ? .zero : .milliseconds(400)
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled, evaluationID == dataContributionPromptEvaluationID else { return }

        let accountID = evaluationID.authenticatedAccountID
        await dependencies.dataContributionSettings.reload(accountID: accountID)
        guard !Task.isCancelled, evaluationID == dataContributionPromptEvaluationID else { return }

        // 已经在设置页明确开启的用户无需再确认；同时落 campaign 标记，防止以后关闭后被追问。
        if let accountID,
           accountID == evaluationID.databaseAccountID,
           dependencies.dataContributionSettings.isEnabled {
            dataContributionPromptPreferences.markHandled(accountID: accountID)
            return
        }

        guard dataContributionPromptPreferences.shouldPresent(
            authenticatedAccountID: accountID,
            databaseAccountID: evaluationID.databaseAccountID,
            isOnboardingActive: evaluationID.isOnboardingActive,
            isAuthSheetPresented: evaluationID.isAuthSheetPresented,
            isContributionEnabled: dependencies.dataContributionSettings.isEnabled
        ), let accountID else {
            dismissDataContributionPromptWithoutHandling()
            return
        }

        dataContributionConsentDraft = false
        dataContributionPromptAccountID = accountID
        showDataContributionConsent = true
    }

    /// 用户关闭或暂不参与：只记录提示已处理，授权继续保持默认关闭。
    private func handleDataContributionPromptClose() {
        guard let accountID = dataContributionPromptAccountID else {
            showDataContributionConsent = false
            return
        }
        dataContributionPromptPreferences.markHandled(accountID: accountID)
        showDataContributionConsent = false
        dataContributionPromptAccountID = nil
    }

    /// 保存用户选择后立即关闭提示；设置落库失败沿用现有静默回读策略，不在这里打扰用户。
    private func handleDataContributionPromptSave(isEnabled: Bool) {
        guard let accountID = dataContributionPromptAccountID else {
            showDataContributionConsent = false
            return
        }
        dataContributionPromptPreferences.markHandled(accountID: accountID)
        showDataContributionConsent = false
        dataContributionPromptAccountID = nil

        guard dependencies.database.currentUserId == accountID else { return }
        Task {
            await dependencies.dataContributionSettings.setEnabled(isEnabled, accountID: accountID)
        }
    }

    /// 账号、数据库或启动覆盖层变化时撤掉旧账户的弹窗，但不消费它的一次性提示。
    private func dismissDataContributionPromptWithoutHandling() {
        guard showDataContributionConsent else { return }
        showDataContributionConsent = false
        dataContributionPromptAccountID = nil
    }
}

/// 数据贡献提示判断的完整输入快照；只用于 SwiftUI `.task(id:)` 的取消与重启边界。
private struct DataContributionPromptEvaluationID: Equatable {
    let authenticatedAccountID: Int64?
    let databaseAccountID: Int64?
    let databaseScopeRevision: UInt64
    let isOnboardingActive: Bool
    let isAuthSheetPresented: Bool
}
