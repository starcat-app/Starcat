//
//  RepoDetailInsightsHost.swift
//  Starcat
//
//  仓库详情 body 的 README / 洞察切换。
//
//  为什么单独抽出来：
//  洞察中心最初只挂在 Manage（星标模块）的 `ManageDetailContent` 上，探索 /
//  Trending / 周刊 / 动态即使已经 star 也看不到洞察。产品规则现在改成跟分享 /
//  AI 一样：只看 `Repo.isStarred`，不看当前模块。
//
//  关键约束：
//  - 各场景的 README 缓存路径不能混用（Manage 走 repo_id，探索 / Trending /
//    周刊走 owner/repo），所以本组件只包一层切换，README 仍由调用方提供；
//  - 未 star 时不渲染胶囊切换行，AI 浮层顶距 preference 必须写回 0，避免
//    上一次已 star 的 inset 残留；
//  - unstar 时强制回到 README 并取消远端洞察请求，避免洞察页悬空。
//
//  关键词：`PreferenceKey`。项目内同类：`GitHubMarkdownFitWidthImage`。
//  官方搜索词：`SwiftUI PreferenceKey onPreferenceChange`。
//

import SwiftUI

/// 仓库详情正文的两种互斥模式。
///
/// 把模式与切换副作用留在视图外部，主详情、独立详情和探索等模块复用同一套规则。
enum RepoDetailContentMode: String, CaseIterable, Identifiable {
    case readme
    case insights

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .readme:
            "insights.repo.mode.readme"
        case .insights:
            "insights.repo.mode.insights"
        }
    }

    /// 切换模式时需要执行的资源管理动作。
    ///
    /// README 模式必须取消洞察请求；洞察模式需要先重置 Hero 滚动位置。
    var transitionEffect: RepoDetailContentTransitionEffect {
        switch self {
        case .readme:
            .cancelInsights
        case .insights:
            .resetScroll
        }
    }
}

/// 历史别名：星标详情曾把模式类型命名为 Manage 专用。
typealias ManageDetailContentMode = RepoDetailContentMode

/// 模式切换带来的最小副作用契约，避免 README 与洞察在后台同时占用资源。
enum RepoDetailContentTransitionEffect: Equatable {
    case cancelInsights
    case resetScroll
}

/// 历史别名：与 `ManageDetailContentMode` 同步改名。
typealias ManageDetailContentTransitionEffect = RepoDetailContentTransitionEffect

/// 仓库洞察入口的纯函数门禁，测试不必依赖 SwiftUI 私有状态。
enum RepoDetailInsightsAvailability {
    /// 仓库洞察跟模块无关：只有已 star 的仓才出现 README / 洞察切换。
    static func showsSwitcher(isStarred: Bool) -> Bool {
        isStarred
    }

    /// unstar 或从未 star 时强制回到 README，避免洞察页悬空。
    static func resolvedMode(
        isStarred: Bool,
        current: RepoDetailContentMode
    ) -> RepoDetailContentMode {
        showsSwitcher(isStarred: isStarred) ? current : .readme
    }
}

/// 仓库和数据库作用域共同决定洞察任务身份；账号切换不能沿用旧 ViewModel 冷却。
private struct RepositoryInsightsLoadIdentity: Hashable {
    let repoID: Int64
    let databaseScopeRevision: UInt64
}

/// 已 star 时在 README 外再包一层洞察切换；未 star 时原样透出 README。
struct RepoDetailInsightsHost<ReadmeContent: View>: View {

    let repo: Repo
    let onScrollReport: (RepoDetailScrollReport) -> Void
    /// 离开 README 进入洞察时由调用方取消场景私有的后台任务（例如 Manage 的 Star History 预加载）。
    let onLeaveReadme: (() -> Void)?
    let readmeContent: ReadmeContent

    init(
        repo: Repo,
        onScrollReport: @escaping (RepoDetailScrollReport) -> Void,
        onLeaveReadme: (() -> Void)? = nil,
        @ViewBuilder readmeContent: () -> ReadmeContent
    ) {
        self.repo = repo
        self.onScrollReport = onScrollReport
        self.onLeaveReadme = onLeaveReadme
        self.readmeContent = readmeContent()
    }

    @Environment(AppDependencies.self) private var dependencies
    @Environment(AuthSession.self) private var authSession
    @Environment(RepoNotesWorkspace.self) private var notesWorkspace: RepoNotesWorkspace?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.starcatReduceMotion) private var reduceMotion

    @State private var contentMode: RepoDetailContentMode = .readme
    @State private var repositoryInsightsViewModel: RepositoryInsightsViewModel?
    @State private var starHistoryViewModel: StarHistoryViewModel?
    @State private var loadedInsightsDatabaseScopeRevision: UInt64?

    private var showsSwitcher: Bool {
        RepoDetailInsightsAvailability.showsSwitcher(isStarred: repo.isStarred)
    }

    private var effectiveMode: RepoDetailContentMode {
        RepoDetailInsightsAvailability.resolvedMode(
            isStarred: repo.isStarred,
            current: contentMode
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsSwitcher {
                modeSwitcherChrome
            } else {
                // 从已 star 切回未 star 时必须把 AI 浮层顶距清零，否则 PreferenceKey
                // 会继续沿用上一次切换行高度。
                Color.clear
                    .frame(height: 0)
                    .preference(key: RepoDetailAIOverlayTopInsetPreference.self, value: 0)
            }

            ZStack(alignment: .topLeading) {
                modeBody
                    .id(effectiveMode)
                    .detailContentTransition()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: effectiveMode)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: contentMode) { _, newMode in
            applyTransitionEffect(newMode.transitionEffect)
        }
        .onChange(of: repo.id) { _, _ in
            cancelInsightsLoading()
            resetToReadmeWithoutAnimation()
            onScrollReport(RepoDetailScrollReport(offsetY: 0, scrollOverflow: 0))
        }
        .onChange(of: repo.isStarred) { _, isStarred in
            guard !isStarred else { return }
            cancelInsightsLoading()
            resetToReadmeWithoutAnimation()
        }
    }

    /// 上报入口栏可见下沿，避免浮层的 4pt 留白叠加入口栏外侧的 padding。
    private var modeSwitcherChrome: some View {
        let outerPadding: CGFloat = 4
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                if notesWorkspace == nil {
                    Spacer(minLength: 0)
                }
                PillSegmentedControl(
                    items: RepoDetailContentMode.allCases,
                    selection: $contentMode,
                    title: \.titleKey,
                    size: .compact
                )
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel(Text("insights.repo.mode.label"))
                if notesWorkspace != nil {
                    Divider().frame(height: 18)
                    RepoNotesEntry()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                if notesWorkspace != nil {
                    let shape = RoundedRectangle(cornerRadius: 8)
                    shape.fill(StarcatSurface.panel(colorScheme: colorScheme))
                        .overlay { shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1) }
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, outerPadding)

            if notesWorkspace == nil {
                Divider()
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: RepoDetailAIOverlayTopInsetPreference.self,
                    value: proxy.size.height - (notesWorkspace != nil ? outerPadding : 0)
                )
            }
        }
    }

    @ViewBuilder
    private var modeBody: some View {
        if effectiveMode == .readme {
            readmeContent
        } else {
            insightsBody
        }
    }

    @ViewBuilder
    private var insightsBody: some View {
        Group {
            if let repositoryInsightsViewModel, let starHistoryViewModel {
                RepositoryInsightsView(
                    repo: repo,
                    viewModel: repositoryInsightsViewModel,
                    starHistoryViewModel: starHistoryViewModel,
                    onScrollReport: onScrollReport,
                    onStarHistoryChanged: { repo in
                        _ = await dependencies.repositoryInsightsContextCoordinator.prepareArtifact(
                            for: repo,
                            mode: .refreshIfNeeded
                        )
                    }
                )
            } else {
                // ViewModel 在同一个 task 的下一阶段立即注入。这里保持内容区域稳定即可，
                // 不显示中央进度环，避免首次进入洞察时出现一次突兀的加载闪烁。
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(true)
            }
        }
        .task(
            id: RepositoryInsightsLoadIdentity(
                repoID: repo.id,
                databaseScopeRevision: dependencies.databaseScopeRevision
            )
        ) {
            let currentDatabaseScopeRevision = dependencies.databaseScopeRevision
            if let loadedInsightsDatabaseScopeRevision,
               loadedInsightsDatabaseScopeRevision != currentDatabaseScopeRevision {
                repositoryInsightsViewModel?.resetTransientStateForDatabaseScopeChange()
                starHistoryViewModel?.cancel()
            }
            loadedInsightsDatabaseScopeRevision = currentDatabaseScopeRevision

            let insightsViewModel = repositoryInsightsViewModel
                ?? makeRepositoryInsightsViewModel()
            let historyViewModel = starHistoryViewModel
                ?? makeStarHistoryViewModel()
            repositoryInsightsViewModel = insightsViewModel
            starHistoryViewModel = historyViewModel

            async let insightsLoad: Void = insightsViewModel.load(
                repo: repo,
                isAuthenticated: authSession.state.isAuthenticated
            )
            async let historyLoad: Void = historyViewModel.load(repo: repo)
            _ = await (insightsLoad, historyLoad)
        }
    }

    private func applyTransitionEffect(_ effect: RepoDetailContentTransitionEffect) {
        switch effect {
        case .cancelInsights:
            cancelInsightsLoading()
        case .resetScroll:
            onLeaveReadme?()
            onScrollReport(RepoDetailScrollReport(offsetY: 0, scrollOverflow: 0))
        }
    }

    private func cancelInsightsLoading() {
        repositoryInsightsViewModel?.cancelRemoteLoading()
        starHistoryViewModel?.cancel()
    }

    private func resetToReadmeWithoutAnimation() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            contentMode = .readme
        }
    }

    private func makeRepositoryInsightsViewModel() -> RepositoryInsightsViewModel {
        RepositoryInsightsViewModel(
            provider: DefaultRepositoryLocalInsightsProvider(
                releaseRepository: dependencies.releaseRepository,
                healthRepository: dependencies.repoHealthRepository,
                openSSFRepository: dependencies.openSSFScoreRepository,
                insightsCache: dependencies.repositoryInsightsCache,
                database: dependencies.database
            ),
            remoteProvider: dependencies.repositoryRemoteInsightsProvider,
            remoteAccessProvider: dependencies.repositoryRemoteInsightsAccessProvider,
            healthEnrichmentHandler: { repo in
                guard repo.isPrivate else { return }
                _ = try? await dependencies.repoHealthService.refreshWithLatestSignals(
                    repo: repo,
                    apiClient: dependencies.projectGitHubAPIClient
                )
            },
            contextRefreshHandler: { repo in
                _ = await dependencies.repositoryInsightsContextCoordinator.prepareArtifact(
                    for: repo,
                    mode: .refreshIfNeeded
                )
            }
        )
    }

    private func makeStarHistoryViewModel() -> StarHistoryViewModel {
        StarHistoryViewModel(repository: dependencies.repoStarHistoryRepository)
    }
}

/// 两个浮层共享正文区的上下边界。缺少对应栏时，以正文容器边缘为基准。
enum RepoDetailOverlayLayout {
    static let verticalGap: CGFloat = 4
    static let minimumNotesDrawerWidth: CGFloat = 400

    static func verticalInsets(topChromeInset: CGFloat, bottomChromeInset: CGFloat) -> EdgeInsets {
        EdgeInsets(
            top: topChromeInset + verticalGap,
            leading: 0,
            bottom: bottomChromeInset + verticalGap,
            trailing: 0
        )
    }

    /// 右边缘固定，所以左拖使宽度增加。窗口收窄时以实际显示宽度起算，避免拖动初段没有响应。
    static func notesDrawerWidth(
        availableWidth: CGFloat,
        preferredWidth: CGFloat,
        horizontalDrag: CGFloat
    ) -> CGFloat {
        let startingWidth = min(availableWidth, max(minimumNotesDrawerWidth, preferredWidth))
        return min(availableWidth, max(minimumNotesDrawerWidth, startingWidth - horizontalDrag))
    }
}

/// 上报正文顶部到入口栏下沿的实际距离，供笔记和 AI 浮层定位。
struct RepoDetailAIOverlayTopInsetPreference: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// README 状态栏的实际高度，由 `ReadmeStateView` 上报给详情 Scaffold。
///
/// 状态栏包含动态字体、垂直 padding 和不同状态下的按钮组合。没有状态栏时保持 0。
struct RepoDetailAIOverlayBottomInsetPreference: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
