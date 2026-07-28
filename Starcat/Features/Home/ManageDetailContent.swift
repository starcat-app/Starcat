//
//  ManageDetailContent.swift
//  Starcat
//
//  R-01「三场景共用架构」Manage 详情页 ContentView 插槽。
//
//  ────────────────────────────────────────────────────────────────────────────
//  设计意图（详细设计 §3.2 & §5.1）
//  ────────────────────────────────────────────────────────────────────────────
//
//  Manage 详情 = `RepoDetailScaffold` (Hero + RepoLocalSections) + `ManageDetailContent` (body slot)
//
//  本 ContentView 负责 body slot 内容：
//  - `ReadmeStateView`：README WebView + 内嵌 cacheFooter（翻译/刷新按钮）
//
//  R-01 v1.5 修订（2026-06-10 下午, dong4j bug 反馈）：
//  - tags / notes / release 三段（`RepoLocalSections`）**从 ContentView 迁回 Scaffold
//    metadataPanel 内**,跟随 hero 整段折叠让位 README 阅读区;
//  - 本 ContentView 不再渲染 `RepoLocalSections`,body 仅剩 `ReadmeStateView`;
//  - 4 场景的三段调用 100% 同构,Scaffold 内置消除重复(详见 `RepoDetailScaffold.swift`
//    文件头 v1.5 修订段)。
//
//  R-01 v2.1 修订（2026-06-11 晚, dong4j bug 反馈「右下角多了一个一模一样的刷新图标」）：
//  - 撤销 P0-E（2026-06-10）的「Scaffold overlay 浮动刷新按钮」设计 §3.2.9。
//  - 原 §3.2.9 给 Scaffold 加 `onRefresh:` 入参,Manage 详情通过它在 bottomTrailing
//    overlay 出一个浮动 `SyncIconButton` 触发 `viewModel.reloadItems(forceRefresh: true)`;
//    但 `ReadmeStateView.cacheFooter` **始终**也渲染一个同款 `SyncIconButton`(只刷
//    README) → Manage 视觉上同位置叠两个一样的图标,用户分不清职责差异,反馈为 bug。
//  - 修复方向(dong4j 选 A:合并):cacheFooter 内那个按钮在 Manage 场景**同时**刷
//    README + reloadItems。本 ContentView 注入 `HomeViewModel`,onRetry 闭包先发
//    `readmeVM.reload(...)`(内部 fire-and-forget Task),再 `Task { await viewModel.reloadItems }`,
//    两个动作并行不阻塞 UI。Trending / Activity / Weekly 的 ContentView 不变(本来就只
//    刷 README,符合各自语义)。
//  - 关键约束:① cacheFooter 按钮 tooltip 仍是 `readme.refresh`,文案没改——避免影响
//    其他 3 个共用 `ReadmeStateView` 的场景;Manage 场景下事实上扩展到「整页刷新」是
//    合理的(用户在详情页点刷新自然期望全刷),不引入额外按钮分裂 UI。② Scaffold 同步
//    删除 `onRefresh` 参数 + overlay,详见 `RepoDetailScaffold.swift` 文件头 v2.1 修订段。
//
//  滚动 → 折叠：把 ReadmeStateView 的 `onScrollReportChange` 上报到 Scaffold
//  传入的 `onScrollReport` closure,由 Scaffold 内部换算成 collapse progress,
//  Scaffold 的 metadataPanel（含 hero + RepoLocalSections）整段同步折叠。
//
//  ────────────────────────────────────────────────────────────────────────────
//  环境依赖
//  ────────────────────────────────────────────────────────────────────────────
//
//  - `ReadmeViewModel`：README 加载状态机
//  - `ReadmeTranslationViewModel`：翻译状态机（HOM-68）
//  - `AppSettings`：翻译目标语言等
//  - `AuthSession`：未登录时 README 不能显示完整内容（私有仓库）
//  - `HomeViewModel`：v2.1 起 onRetry 内调 `reloadItems(forceRefresh: true)` 用
//

import SwiftUI

/// Manage 详情正文的两种互斥模式。
///
/// 把模式与切换副作用留在视图外部，主详情和独立详情复用同一个
/// `ManageDetailContent` 时会自然共享同一套规则，测试也不必依赖 SwiftUI 私有状态。
enum ManageDetailContentMode: String, CaseIterable, Identifiable {
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
    var transitionEffect: ManageDetailContentTransitionEffect {
        switch self {
        case .readme:
            .cancelInsights
        case .insights:
            .resetScroll
        }
    }
}

/// 模式切换带来的最小副作用契约，避免 README 与洞察在后台同时占用资源。
enum ManageDetailContentTransitionEffect: Equatable {
    case cancelInsights
    case resetScroll
}

/// 仓库和数据库作用域共同决定洞察任务身份；账号切换不能沿用旧 ViewModel 冷却。
private struct RepositoryInsightsLoadIdentity: Hashable {
    let repoID: Int64
    let databaseScopeRevision: UInt64
}

/// Manage 场景详情页的 body 内容（README + 翻译入口）。
struct ManageDetailContent: View {

    let repo: Repo

    /// 由 Scaffold 注入：把 scroll offset 上报回去用于驱动顶部面板折叠。
    let onScrollReport: (RepoDetailScrollReport) -> Void

    @Environment(ReadmeViewModel.self) private var readmeVM
    @Environment(ReadmeTranslationViewModel.self) private var translationVM
    @Environment(AppSettings.self) private var settings
    @Environment(AuthSession.self) private var authSession
    @Environment(AppDependencies.self) private var dependencies
    /// v2.1（2026-06-11）：onRetry 闭包同时刷 README + 整个 repo 视图数据(缓存 repo +
    /// tags + notes + release 计数等)。详见文件头 v2.1 修订段。
    @Environment(HomeViewModel.self) private var viewModel
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @State private var contentMode: ManageDetailContentMode = .readme
    @State private var repositoryInsightsViewModel: RepositoryInsightsViewModel?
    @State private var starHistoryViewModel: StarHistoryViewModel?
    @State private var loadedInsightsDatabaseScopeRevision: UInt64?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer(minLength: 12)

                // 复用 Starcat 自绘胶囊控件，避免 macOS 原生 segmented Picker
                // 在详情页中显得厚重；右对齐后也不会抢占 README 阅读区的视觉焦点。
                // horizontal 24 与 RepoLocalSections / Hero 一致，让「AI 生成」与「洞察」右缘齐平。
                PillSegmentedControl(
                    items: ManageDetailContentMode.allCases,
                    selection: $contentMode,
                    title: \.titleKey,
                    size: .compact
                )
                .accessibilityLabel(Text("insights.repo.mode.label"))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)

            Divider()

            // README ↔ 洞察与我的洞察同款「轻轻落下」；顶栏胶囊固定，不参与内容重建。
            ZStack(alignment: .topLeading) {
                modeBody
                    .id(contentMode)
                    .detailContentTransition()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: contentMode)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: contentMode) { _, newMode in
            switch newMode.transitionEffect {
            case .cancelInsights:
                repositoryInsightsViewModel?.cancelRemoteLoading()
                starHistoryViewModel?.cancel()
            case .resetScroll:
                // README 可能在切换前已把 Hero 折叠；洞察页首帧先恢复顶部 Metadata，
                // 后续再由自己的 ScrollView 持续上报 offset。
                onScrollReport(RepoDetailScrollReport(offsetY: 0, scrollOverflow: 0))
            }
        }
    }

    @ViewBuilder
    private var modeBody: some View {
        if contentMode == .readme {
            // v1.5 修订（2026-06-10）：RepoLocalSections 已迁回 Scaffold metadataPanel，
            // README 继续直接上报滚动，让 hero 折叠行为保持不变。
            ReadmeStateView(
                state: readmeVM.state,
                contentScope: .manage(repoId: repo.id),
                // 统一构造带末尾 `/` 的目录 URL，避免 WebKit 把 HEAD 当文件名后丢掉分支段。
                baseURL: URL(string: repo.htmlUrl).map(ReadmeWebView.repositoryContentBaseURL),
                onScrollReportChange: onScrollReport,
                translationControl: ReadmeTranslationControl(
                    repo: repo,
                    translationVM: translationVM,
                    settings: settings
                )
            ) {
                refreshReadmeAndRepo()
            } onLogin: {
                // 2026-06-29：只弹登录 sheet，不强制走 Device Flow。
                authSession.requestLoginSheet()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    onScrollReport: onScrollReport
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

    /// v2.1 既有语义保持不变：Manage 的 README 刷新同时重读当前 repo 视图数据。
    private func refreshReadmeAndRepo() {
        readmeVM.reload(repo: repo, isLoggedIn: authSession.state.isAuthenticated)
        Task { await viewModel.reloadItems(forceRefresh: true) }
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
            remoteProvider: DefaultRepositoryRemoteInsightsProvider(
                metricsClient: dependencies.repositoryMetricsClient,
                cache: dependencies.repositoryInsightsCache
            )
        )
    }

    private func makeStarHistoryViewModel() -> StarHistoryViewModel {
        StarHistoryViewModel(repository: dependencies.repoStarHistoryRepository)
    }
}
