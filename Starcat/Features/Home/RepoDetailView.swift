//
//  RepoDetailView.swift
//  Starcat
//
//  右栏：仓库详情。
//
//  Week 3：基础元信息卡片（头像、名称、描述、stats、topics、外链）。
//  Week 4：接入 README WebView 渲染 + ETag 缓存。
//
//  布局策略：
//  - 元信息卡片默认在顶部展示，README 区域占满剩余高度独立滚动
//  - README 向下滚动后收起元信息卡片，把阅读空间还给内容；回到顶部再展开
//
//  设计约束：
//  - 无选中行时显示空态
//  - 顶部外链 / clone 按钮由 RepoListView toolbar 统一承载，避免 detail toolbar 落到右栏左边
//  - 智能集合从 repo 详情退回集合浏览：中栏 Manage toolbar 左侧 chevron（2026-06-23）
//  - README 加载通过 ReadmeViewModel 协调（由 HomeView 持有并通过 .onChange 驱动）
//
//  状态归属：
//  - HomeViewModel：列表 / sidebar / selectedRepo（环境注入）
//  - ReadmeViewModel：README 加载状态机（环境注入；HomeView 持有）
//  - 本 view 自身无状态
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ThinkingOrbsKit

struct RepoDetailView: View {

    @Environment(HomeViewModel.self) private var viewModel
    // W4 B1：取消 star 需要的依赖
    @Environment(AppDependencies.self) private var dependencies
    // D-28 修订（2026-06-11）：原 `@Environment(\.starcatReduceMotion) reduceMotion`
    // 移除 —— 该开关唯一消费点 `private var detailContentTransition` 已抽到
    // `Shared/Components/DetailContentTransition.swift` 共享 modifier,reduceMotion 由
    // modifier 内部读取,本 view 不再需要持有该 environment。
    //
    // 2026-06-15 修订:为支持「关闭应用内动画」用户偏好,需要再消费 reduceMotion
    // 给 line 154 的 `.animation(.easeOut(duration: 0.4), value: detailContentID)`
    // 与 line 544 翻译按钮 hover 切图标的 0.15s 淡入做"关动画"兜底。modifier 那
    // 一份不动(包内闭合,view 透明),这里独立持一份是 SwiftUI Environment 的
    // 标准模式,view 之间不共享 @Environment 实例,各 view 按需读取无副作用。
    @Environment(\.starcatReduceMotion) private var reduceMotion
    /// v1.4 修订 (2026-06-10)：trailingActions(.share/.ai) 加 isAuthenticated 守卫的依赖。
    /// Manage 场景业务上必须登录才能看到 repo 列表（HomeViewModel 从本地 starred_repos
    /// 拉数据,登出会清 token + StarredRegistry,但本地 starred_repos 表不清,理论上多账号
    /// 切换时仍可能短暂看到已登出用户的数据）→ 加防御性守卫,与 trending/weekly 全场景一致。
    @Environment(AuthSession.self) private var authSession

    // R-01 §3.2.3 决策：unstar 即点即生效，不再有 confirm alert / unstarError 弹窗。
    // 失败由 StarActionService 内部记日志，UI 仅靠 hero ⭐ chip 抖动 + 短暂红色提示
    // （chip 抖动效果在 RepoMetadataHeaderView 内未来扩展；R-01 阶段先打日志即可）。
    //
    // R-01 v1.2 Phase B3（2026-06-10）：trending 详情页全部交给 `TrendingScaffoldShell`
    // 自治，本 view 不再持有 `isStarringTrending` / `trendingStarError` 等任何 trending
    // 相关状态；折叠面板状态由 `RepoDetailScaffold` 内部持有，本 view 也不再维护。

    /// Trending repo 的元信息（当从 Trending 列表选中时非 nil）。
    var selectedTrendingRepo: TrendingRepo?

    init(selectedTrendingRepo: TrendingRepo? = nil) {
        self.selectedTrendingRepo = selectedTrendingRepo
    }

    var body: some View {
        // 当前不要给 detail 再加 `.frame(minWidth:)`。
        //
        // 之前尝试用 770pt 固定 detail 可读宽度，但它会和 NavigationSplitView 的
        // sidebar 折叠/展开协商叠加：窗口缩到 1190 后再展开左栏时，SwiftUI 需要同时
        // 满足左栏、列表和 detail 的下限，容易出现左栏抽屉或窗口宽度跳动。
        // 运行期硬下限统一交给 `MainWindowFrameModifier` 的 AppKit `contentMinSize`，
        // detail 在这个边界内自适应。
        // 用 ZStack(alignment: .topLeading) 包裹三分支，而不是 Group。
        //
        // 关键差别（21:44 排查后修正）：
        // - Group 是 transparent container，不在 view tree 创建节点；
        //   `.transition` 落在各分支 view 上时，跨分支切换缺少"容器宿主"
        //   把 old view 的 removal 和 new view 的 insertion 同帧协调起来，
        //   实际表现是 "旧 view 直接被替换、新 view 直接出现"，几乎看不到动画。
        // - ZStack 是真正的 layout container；切换时 SwiftUI 会先把 new view
        //   叠加进 ZStack（触发 insertion transition），再把 old view 移除
        //   （触发 removal transition），两份内容在同一帧里完成进出，
        //   `.transition` 才能稳定触发。
        // alignment 选 `.topLeading` 是为了和 detail 内容固有的"从左上展开"
        // 布局一致（VStack(alignment: .leading) + 顶对齐），避免切换瞬间
        // 内容在 Z 轴上突然居中再回到左上。
        ZStack(alignment: .topLeading) {
            if viewModel.selection == .smartCollectionsHome {
                // 智能集合首页只是集合入口，不承载 repo 详情。
                // 这里放在 `selectedRepo` 之前，是为了挡住切换时序里尚未清理的旧
                // selectedRepoID，避免右栏继续显示上一分类的 repo 详情。
                emptyState
                    .id("smart-collections-home-empty")
                    .detailContentTransition()
            } else if let repo = viewModel.selectedRepo {
                RepoDetailScaffold(
                    repo: repo,
                    viewData: RepoDetailViewData(
                        hero: RepoDetailHero(repo: repo),
                        // **v2.0 修订** (2026-06-10):分享/AI 等私人功能可见性绑「已 star」
                        // 单一信任源 = `Repo.isStarred`(本地 DB `is_starred` 列的内存镜像)。
                        // 从 v1.7 的 `StarredRegistry.contains(...)` 回归,因为 registry 异步
                        // bootstrap + SyncManager 304 早退不触发 hook 会让 Manage 启动期
                        // registry 为空 → 私人面板全部不显。`Repo.isStarred` 在 4 场景全部
                        // 可信(详见 `StarringSubsystem.swift` v2.0 修订段)。
                        trailingActions: trailingActions(for: repo),
                        translation: ReadmeTranslationContext(fullName: repo.fullName),
                        backendHint: nil
                    ),
                    // **v2.0 修订**:tooltip 与 toggle 行为对齐——已 star 显示「取消 star」,
                    // 未 star 显示「star」。从 `Repo.isStarred` 直接派生(同 trailingActions)。
                    starHelpKey: repo.isStarred ? "repo.unstar" : "repo.star",
                    showsRepoHealthEntry: ProjectPrivacyPolicy.allowsPublicService(for: repo),
                    // Issues 入口（2026-11-01）：仅星标详情开放；私有仓库在 Scaffold 内再隐藏。
                    showsIssuesEntry: true,
                    onLanguageTapped: { language in
                        viewModel.toggleTemporaryLanguageFilterFromDetail(language)
                    },
                    onStarTapped: { cleanupScope in
                        // §3.2.3 状态机：throws 让 StarStatChipButton 抖动 + 短暂红色（不弹 alert）
                        try await handleStarTapped(repo: repo, cleanupScope: cleanupScope)
                    }
                    // v2.1 修订（2026-06-11）：撤销 §3.2.9 给 Scaffold 加 `onRefresh:` +
                    // 浮动刷新按钮的设计 —— Manage 详情同位置已经有 `cacheFooter` 内的
                    // SyncIconButton(只刷 README),叠加 overlay 的浮动按钮(刷整个仓库视图)
                    // 视觉上无法区分,用户反馈为 bug。改为合并：cacheFooter 内的按钮在
                    // Manage 场景同时承担 README + reloadItems 双职责,详见
                    // `ManageDetailContent.swift` 文件头 v2.1 修订段 +
                    // `RepoDetailScaffold.swift` 文件头 v2.1 修订段。
                ) { onScrollReport in
                    ManageDetailContent(repo: repo, onScrollReport: onScrollReport)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // 2026-06-21 性能修订：
                // Manage 详情的 body 是 README WKWebView。root transition 会让旧 repo
                // 的 WebView 和新 repo 的 WebView 在 0.4s 内同时存在，repo 快速切换时
                // 会触发大量 WebContent 子进程日志并放大卡顿。Manage 同分支切 repo 现在
                // 交给 Scaffold/ReadmeViewModel 直接切换；Trending/Activity/Weekly 仍保留
                // 共享 transition，因为它们的 root 切换语义更依赖入场反馈。
            } else if let trending = selectedTrendingRepo {
                // R-01 §3.2.3 Phase B3（2026-06-10）：trending 详情切到 RepoDetailScaffold
                // + TrendingDetailContent 共用骨架。`TrendingScaffoldShell` 内部维护
                // `displayRepo` / `isLocalHit` 状态机，先查本地（已 star 拿真值，三段
                // 跟着渲染），未命中退化到 ephemeral Repo（id=0，三段隐藏）。
                //
                // **`.id(trending.id)` 故意保留**(与 manage 分支差异)：
                // TrendingScaffoldShell 设计为 `.id` 重建友好——trending row 自带
                // v1.2 完整字段(R-05 透传 10 字段补齐),内部 `task(id: trending.id)`
                // 重建后 displayRepo 同步设置,fallback 走 makeEphemeralRepo() 同步快
                // 路径不依赖网络。同 trending 内切 repo 也触发 transition,体验丝滑。
                TrendingScaffoldShell(trending: trending)
                    .id(trending.id)
                    .detailContentTransition()
            } else if viewModel.selection.isSmartCollectionDetailContext {
                SmartCollectionDetailPanel()
                    .detailHeroTintBackground(tint: smartCollectionPanelTint)
                    .id("smart-collection-panel-\(viewModel.selection.id)")
                    .detailContentTransition()
            } else {
                emptyState
                    .id("empty")
                    .detailContentTransition()
            }
        }
        // 监听"当前显示的 detail 内容标识"变化，触发 .transition 动效。
        //
        // 严格只看 `detailContentID`（Manage 分支固定为 "manage"，其它分支按内容计算），
        // 避免让 .animation 把详情页内部的状态变化（编辑标签、输入笔记、折叠 hero
        // 等）也吃进 implicit 动画，那会引起意外的全局 fade/move 副作用。
        //
        // duration 0.4s（21:44 从 0.28s 调大）：
        // README WebView 启动有 100~200ms 白屏 → 加载 HTML → 渲染的延迟。
        // 之前 0.28s 太快，transition 在 WebView 还没出内容时就结束了，肉眼几乎
        // 看不见"轻轻落下"。0.4s 是经验值，比 README 首帧渲染稍慢一点，让用户
        // 能明确感受到内容从上方滑入。
        .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: detailContentID)
    }

    /// 当前 detail 内容的标识符，用作 `.animation(_:value:)` 的触发 key。
    ///
    /// Manage 内部切 repo 固定返回 `manage`：复用现有视图树并直接更新内容。
    /// Manage 与其它详情类型切换时，外层才运行 0.4 秒 transition，避免把
    /// README / 标签 / 笔记内部更新误纳入整页隐式动画。
    private var detailContentID: String {
        if viewModel.selection == .smartCollectionsHome { return "smart-collections-home-empty" }
        if viewModel.selectedRepo != nil { return "manage" }
        if let id = selectedTrendingRepo?.id { return "trending-\(id)" }
        if viewModel.selection.isSmartCollectionDetailContext { return "smart-collection-panel-\(viewModel.selection.id)" }
        return "empty"
    }

    // D-28 修订（2026-06-11）：原 `private var detailContentTransition` 已抽到
    // `Shared/Components/DetailContentTransition.swift` 暴露成 `.detailContentTransition()`
    // modifier,4 详情页（manage / trending / activity / weekly）共享同一份非对称 transition
    // 配置(insertion: opacity + offset y:14 / removal: opacity / reduceMotion 兜底)。
    // 详细设计见共享文件文件头注释段。

    // R-01 §3.2.3：performUnstar / errorAlertBinding 已迁移到 StarActionService 单点维护
    // （RepoDetailView 不再持有 unstar 业务逻辑）。

    // MARK: - Star toggle / 私人面板可见性（**v2.0 修订**, 2026-06-10）

    /// trailingActions 守卫(与 trending / weekly / activity 4 详情页同构):
    /// 已登录 + `repo.isStarred == true` → `[.share, .ai]`,否则空数组。
    ///
    /// **v2.0 从 v1.7 的 `starredRegistry.contains(...)` 回归到 `repo.isStarred`**:
    /// 直接读 `Repo.isStarred`(本地 DB `is_starred` 列的内存镜像)避免依赖
    /// 异步 bootstrap 的 registry。Manage 场景 `selectedRepo.isStarred` 永远 true
    /// (因为 selectedRepo 来自 `fetchAllStarred`),unstar 后 viewModel 会刷新
    /// 列表 → selectedRepo 切到 nil 或新 repo → 这个 detail view 自动重渲染。
    /// 4 场景同构 + 不依赖 registry async 时序,详见 `RepoLocalSections.swift` 文件头。
    private func trailingActions(for repo: Repo) -> [RepoDetailAction] {
        guard repo.isStarred else {
            return []
        }
        // v2.0（2026-06-16, dong4j）：OpenSSF 入口迁移到 hero `full_name` 同行，
        // 不再放在 trailing actions 数组里。
        var actions: [RepoDetailAction] = []
        if authSession.state.isAuthenticated,
           ProjectPrivacyPolicy.allowsPublicShare(for: repo) {
            actions.append(.share)
        }
        if authSession.state.isAuthenticated {
            actions.append(.ai)
        }
        return actions
    }

    /// hero ⭐/☆ chip 点击(**v2.0 修订**):
    ///
    /// 与 trending / weekly / activity 完全同构——`StarActionService.toggle(repo:)`
    /// 内部按 `repo.isStarred || registry.contains(...)` 任一为 true 走 unstar 分支,
    /// 4 处调用方都是这 6 行模板。失败抛错让 `StarStatChipButton` 触发抖动 +
    /// 短暂红色 600ms。
    ///
    /// 未登录 → `authSession.signIn()` 触发设备流后**不抛错 return**(chip 不抖,
    /// 这不是失败语义)。
    private func handleStarTapped(
        repo: Repo,
        cleanupScope: RepositoryUnstarCleanupScope?
    ) async throws {
        guard authSession.state.isAuthenticated else {
            // 2026-06-29：只弹登录 sheet，不强制走 Device Flow
            authSession.requestLoginSheet()
            return
        }
        if let cleanupScope {
            try await dependencies.starActionService.unstar(repo: repo, cleanupScope: cleanupScope)
        } else {
            try await dependencies.starActionService.toggle(repo: repo)
        }
        await viewModel.refreshAfterExternalStarChange()
    }

    // R-01 §3.2.3 Phase B3（2026-06-10）：本 view 的 trending 分支全部交给
    // `TrendingScaffoldShell`（同 module 平级文件）+ `RepoDetailScaffold` +
    // `TrendingDetailContent` + `TrendingContributorsSection` 共用骨架；
    // 历史 helper（collapsibleMetadataContainer / metadataAccentColor /
    // metadataGradientBackground / updateMetadataPanelVisibility / trendingHeader /
    // trendingStatsSection / trendingContributorsSection / contributorAvatar /
    // trendingReadmeSection / starTrending / TrendingHeroAvatarButton）已全部删除。

    // R-01 §3.2.3 Phase B5（2026-06-10）：原 `metadataCollapseProgress(for:)` 静态
    // helper 已删除——Manage / Trending / Weekly / Activity-repo-backed 全部走
    // `RepoDetailScaffold.metadataCollapseProgress(for:)`，单点维护折叠手感。

    // MARK: - 空态

    private var emptyState: some View {
        RepoDetailNoSelectionPlaceholder()
    }

    /// Smart Collections 右栏浏览面板顶部光晕 tint（与集合 kind / 用户集合 accent 对齐）。
    private var smartCollectionPanelTint: Color {
        switch viewModel.selection {
        case .smartCollection(let kind):
            return kind.tint
        case .userSmartCollection:
            return .accentColor
        default:
            return .accentColor
        }
    }

}

// MARK: - README 状态视图

/// 详情页 README 内容与 `ReadmeViewModel` 活跃目标的对应关系。
enum ReadmeContentScope: Equatable {
    case manage(repoId: Int64)
    case trending(owner: String, repo: String)

    fileprivate var trendingKey: String? {
        switch self {
        case .manage:
            return nil
        case .trending(let owner, let repo):
            return "\(owner)/\(repo)"
        }
    }
}

/// 把 ReadmeViewModel.LoadState 翻译为视觉。
///
/// 拆成独立 View 的好处：
/// - 状态切换造成的 view tree 重建只影响这一块，元信息区不受波及
/// - 重试按钮的回调通过闭包传入，保持本组件无副作用
struct ReadmeStateView: View {

    @Environment(ReadmeViewModel.self) private var readmeVM
    @Environment(AppSettings.self) private var settings
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.starcatReduceMotion) private var reduceMotion

    @Environment(\.repoSubscriberCountRefresh) private var subscriberCountRefresh

    /// 相对时间 helper 需要显式 `\.locale`，否则 formatter 会回到系统语言。
    /// 已挂 `appLocaleEnvironment()` 的子树自动拿到正确值。
    @Environment(\.locale) private var locale

    /// Toast 消息绑定（翻译错误 → 底部浮动提示）。
    @State private var translationToast: String?
    /// 「已是目标语言」轻提示 toast。与错误 toast 分开挂，才能用中性 checkmark 图标、
    /// 不带「前往设置」按钮；两条 toast 互斥出现（提示只在翻译未启动时置位）。
    @State private var translationNoticeToast: String?
    /// 当前已渲染文档的两种翻译输入。用 document key 守门，避免切 repo 的一帧窗口误用旧数据。
    @State private var translationSourceDocumentKey: String?
    @State private var translationSourceSnapshot: ReadmeTranslationSourceSnapshot = .empty
    /// loading 阶段短暂保留上一份文档，让同一个 WKWebView 实例留在视图树中。
    /// 骨架是不透明的，保留内容不会被用户看到，也不会接收点击或进入辅助功能树。
    @State private var retainedReadmeDocument: PresentedReadmeDocument?
    @State private var renderedReadmeDocumentID: String?
    @State private var failedReadmeDocumentID: String?
    /// WebKit 失败后即使网络返回相同缓存，也需要新的文档身份重新导航。
    @State private var readmeRetryGeneration = 0
    @State private var isReadmeContentVisible = false
    @State private var isReadmeSkeletonVisible = true
    /// 链接文档只在当前阅读会话中替换正文，不能写入仓库默认 README 的持久缓存。
    @State private var markdownNavigation = RepositoryMarkdownNavigation()

    /// 非 Manage 的 README 详情页通过显式 repo 开启同一套 Star History DOM 状态机；
    /// Manage 仍由 `ManageDetailContent` 持有，避免同一份 README 产生两个加载器。
    @State private var readmeStarHistoryViewModel: ReadmeStarHistoryViewModel?
    @State private var readmeStarHistoryTask: Task<Void, Never>?

    /// 主窗口各详情页共用一份翻译 VM。星标有 HomeView.selectedRepoID 的 prepare，
    /// 探索 / 活动 / 周刊没有；这里按当前仓 bind，避免 A 的译文和光圈留在 B 上。
    @Environment(ReadmeTranslationViewModel.self) private var sharedTranslationVM

    let state: ReadmeViewModel.LoadState
    let contentScope: ReadmeContentScope
    let baseURL: URL?
    let onScrollReportChange: (RepoDetailScrollReport) -> Void
    /// HOM-68：可选的 README 翻译控件描述。nil 时不渲染翻译入口
    /// （Trending 详情页不接翻译，传 nil；Manage 详情页传具体值）。
    let translationControl: ReadmeTranslationControl?
    /// Manage README 可选的 Star History DOM 状态；其它调用方保持空状态。
    let starHistoryRenderState: ReadmeStarHistoryRenderState
    /// WebView 接近文档底部时的加载兜底；Manage 场景通常已在首帧预加载。
    let onApproachingBottom: () -> Void
    /// 非 Manage README 详情页传入 repo 后，自动复用 Star History 加载与底部兜底。
    /// nil 表示调用方自行提供 `starHistoryRenderState` / `onApproachingBottom`。
    let starHistoryRepo: Repo?
    let onRetry: @MainActor @Sendable () -> Void
    /// 未登录用户点击"登录"按钮时的回调
    let onLogin: () -> Void

    /// HOM-201 P1-2（2026-06-14）：原本接受的 `owner` / `repo` 参数已删除——
    /// `<img>` 相对路径重写在 `ReadmeAPI` upsert 前就完成,渲染层不再需要这两个
    /// 仓库标识来跑正则,这两个参数从 4 个 DetailContent 的调用现场也一并清理。
    init(
        state: ReadmeViewModel.LoadState,
        contentScope: ReadmeContentScope,
        baseURL: URL?,
        onScrollReportChange: @escaping (RepoDetailScrollReport) -> Void,
        translationControl: ReadmeTranslationControl? = nil,
        starHistoryRenderState: ReadmeStarHistoryRenderState = .empty,
        onApproachingBottom: @escaping () -> Void = {},
        starHistoryRepo: Repo? = nil,
        onRetry: @escaping @MainActor @Sendable () -> Void,
        onLogin: @escaping () -> Void
    ) {
        self.state = state
        self.contentScope = contentScope
        self.baseURL = baseURL
        self.onScrollReportChange = onScrollReportChange
        self.translationControl = translationControl
        self.starHistoryRenderState = starHistoryRenderState
        self.onApproachingBottom = onApproachingBottom
        self.starHistoryRepo = starHistoryRepo
        self.onRetry = onRetry
        self.onLogin = onLogin
    }

    /// 骨架 → 真实 README 的轻微 reveal（与 splash 主窗口 0.72s 相比更短，避免拖慢阅读）。
    private enum ReadmeRevealTiming {
        static let contentRevealSeconds = 0.36
    }

    /// README 渲染层的轻量文档快照。身份复用 VM 文档与本地渲染重试序号，
    /// 不在 SwiftUI body 中反复计算整份 HTML 的 SHA-256。
    private struct PresentedReadmeDocument {
        let html: String
        let cachedAt: Date
        let identity: String
        let baseURL: URL?
        var target: RepositoryMarkdownLinkTarget? = nil
    }

    /// 交接任务既跟随文档，也跟随等待结束；终态没有 documentID，不能与 loading 共用身份。
    /// 只保存短身份与阶段，避免在 body 重算时比较 HTML 或因缓存时间更新而重播过渡。
    struct HandoffKey: Equatable {
        enum Phase: Equatable {
            case waiting
            case document(String)
            case resolved
        }

        let scopeIdentity: String
        let phase: Phase

        init(scopeIdentity: String, state: ReadmeViewModel.LoadState,
             documentIdentity: String?, isStateStale: Bool) {
            self.scopeIdentity = scopeIdentity
            if isStateStale {
                phase = .waiting
            } else {
                switch state {
                case .idle, .loading:
                    phase = .waiting
                case .loaded:
                    phase = documentIdentity.map(Phase.document) ?? .waiting
                case .empty, .requiresLogin, .error:
                    phase = .resolved
                }
            }
        }
    }

    var body: some View {
        @Bindable var markdownNavigation = markdownNavigation
        let currentDocument = currentReadmeDocument

        ZStack(alignment: .topLeading) {
            if let presentedDocument = retainedReadmeDocument {
                loadedReadmeContent(presentedDocument)
                    .opacity(isReadmeContentVisible ? 1 : 0)
                    .blur(radius: reduceMotion || isReadmeContentVisible ? 0 : 10)
                    .allowsHitTesting(isReadmeContentVisible && presentedDocument.identity == currentDocument?.identity)
                    .accessibilityHidden(!isReadmeContentVisible || presentedDocument.identity != currentDocument?.identity)
                    .zIndex(0)
            }

            if isReadmeSkeletonVisible {
                readmePlaceholder
                    .transition(readmePlaceholderTransition)
                    .zIndex(1)
            }

            if let failedReadmeDocumentID, failedReadmeDocumentID == currentDocument?.identity {
                ContentUnavailableView {
                    Label("error.loadFailed", systemImage: "exclamationmark.triangle")
                } actions: {
                    Button("action.retry", action: retryReadme)
                    if scopedMarkdownDocument != nil {
                        Button("readme.document.backToReadme", action: returnToReadme)
                    }
                }
                .transition(readmeContentTransition)
                .zIndex(1)
            } else if retainedReadmeDocument == nil, !isReadmeSkeletonVisible, currentDocument == nil {
                resolvedNonLoadedContent
                    .transition(readmeContentTransition)
                    .zIndex(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .animation(
            .easeOut(duration: reduceMotion ? 0.12 : ReadmeRevealTiming.contentRevealSeconds),
            value: isReadmeSkeletonVisible
        )
        .task(id: HandoffKey(
            scopeIdentity: markdownScopeIdentity,
            state: presentedReadmeState,
            documentIdentity: currentDocument?.identity,
            isStateStale: isStateStaleForScope
        )) {
            await handOffReadmeDocument()
        }
        .task(id: readmeStarHistoryPreloadIdentity) {
            await preloadReadmeStarHistoryIfNeeded()
        }
        .onDisappear {
            cancelReadmeStarHistory()
            markdownNavigation.reset(scopeIdentity: markdownScopeIdentity)
        }
        .onChange(of: markdownScopeIdentity, initial: true) { _, identity in
            markdownNavigation.reset(scopeIdentity: identity)
        }
        .toast(message: $markdownNavigation.errorMessage, icon: "exclamationmark.triangle.fill", bottomPadding: 30)
        .toast(
            message: $translationToast,
            icon: "exclamationmark.triangle.fill",
            duration: 5,
            iconColor: .orange,
            bottomPadding: 30,
            actionLabel: translationToastActionLabel,
            onAction: translationToastOnAction
        )
        .toast(
            message: $translationNoticeToast,
            icon: "checkmark.circle.fill",
            duration: 5,
            bottomPadding: 30
        )
        .onChange(of: translationControl?.translationVM.errorMessage) { _, newValue in
            if let msg = newValue {
                translationToast = msg
            }
        }
        .onChange(of: translationToast) { _, newValue in
            if newValue == nil {
                translationControl?.translationVM.dismissError()
            }
        }
        .onChange(of: translationControl?.translationVM.showsAlreadyInTargetNotice == true) { _, shown in
            guard shown else { return }
            // 传 catalog key，由 toast 内部 LocalizedStringKey 按当前语言解析。
            translationNoticeToast = "readme.translate.notice.alreadyInTarget"
        }
        .onChange(of: translationNoticeToast) { _, newValue in
            if newValue == nil {
                translationControl?.translationVM.dismissAlreadyInTargetNotice()
            }
        }
        .starcatRefreshCommand(
            pane: .detail,
            identity: "\(refreshCommandIdentity)-\(readmeVM.isRefreshing)-\(isMarkdownRefreshing)",
            title: String.l10n("commands.actions.refreshCurrentDetail"),
            isEnabled: !readmeVM.isRefreshing && !isMarkdownRefreshing,
            action: refreshDetail
        )
        .onChange(of: translationSyncKey, initial: true) { _, _ in
            syncSharedTranslationToCurrentRepo()
        }
        .onChange(of: settings.readmeTranslationLanguage) { _, _ in
            syncSharedTranslationToCurrentRepo()
        }
        .onChange(of: locale.identifier) { _, _ in
            guard settings.readmeTranslationLanguage == .auto else { return }
            syncSharedTranslationToCurrentRepo()
        }
        .onChange(of: settings.readmeTranslationMode) { _, _ in
            syncSharedTranslationToCurrentRepo()
        }
    }

    /// 注册身份必须随真实 README 对象变化，避免详情切换后 Settings 仍刷新上一仓库。
    private var refreshCommandIdentity: String {
        switch contentScope {
        case .manage(let repoId):
            return "manage-\(repoId)"
        case .trending(let owner, let repo):
            return "public-\(owner.lowercased())/\(repo.lowercased())"
        }
    }

    private var readmePlaceholderTransition: AnyTransition {
        .opacity
    }

    /// 账号切换也必须丢弃临时文档，不能只用同一仓库的名称判断是否仍为当前会话。
    private var markdownScopeIdentity: String {
        "\(refreshCommandIdentity)|database:\(dependencies.databaseScopeRevision)"
    }

    private var scopedMarkdownDocument: RepositoryMarkdownNavigation.Document? {
        markdownNavigation.scopeIdentity == markdownScopeIdentity ? markdownNavigation.document : nil
    }

    private var isMarkdownLoading: Bool {
        markdownNavigation.scopeIdentity == markdownScopeIdentity && markdownNavigation.isLoading
    }

    private var isMarkdownRefreshing: Bool {
        markdownNavigation.scopeIdentity == markdownScopeIdentity && markdownNavigation.isRefreshing
    }

    /// 复用 README 原有的骨架 / 退场 / ready / 入场状态机，不再创建第二个 WebView。
    private var presentedReadmeState: ReadmeViewModel.LoadState {
        if isMarkdownLoading { return .loading }
        if let document = scopedMarkdownDocument {
            return .loaded(html: document.html, cachedAt: document.loadedAt)
        }
        return state
    }

    /// 空态和错误内容使用淡化；正文在稳定的 WebView 外层完成模糊与透明度交接。
    private var readmeContentTransition: AnyTransition {
        .opacity
    }

    /// 请求已在 VM 中立即开始；这里仅等旧页退场再更新 DOM，保持同一个 WKWebView。
    /// HTML 到达后仅等当前 documentID 的正文 DOM 与布局就绪，不等媒体；取消的任务不得发布旧快照。
    private func handOffReadmeDocument() async {
        if retainedReadmeDocument != nil {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                withAnimation(.easeOut(duration: reduceMotion ? 0.06 : 0.12), completionCriteria: .removed) {
                    isReadmeContentVisible = false
                } completion: {
                    continuation.resume()
                }
            }
        }
        guard !Task.isCancelled else { return }
        failedReadmeDocumentID = nil
        if let document = currentReadmeDocument {
            if retainedReadmeDocument?.identity != document.identity {
                renderedReadmeDocumentID = nil
            }
            retainedReadmeDocument = document
            updateReadmeVisibility()
        } else if showsReadmePlaceholder {
            withAnimation(.easeOut(duration: reduceMotion ? 0.12 : 0.18)) {
                isReadmeSkeletonVisible = true
            }
        } else {
            // 空内容、登录提示和请求失败都是终态，必须结束骨架并保留重试入口。
            retainedReadmeDocument = nil
            renderedReadmeDocumentID = nil
            withAnimation(.easeOut(duration: reduceMotion ? 0.12 : 0.24)) {
                isReadmeSkeletonVisible = false
            }
        }
    }

    /// 缓存回切仍在当前 WebView 中时无需再次导航；其余正文必须等待对应 ready。
    private func updateReadmeVisibility() {
        let isReady = currentReadmeDocument?.identity == retainedReadmeDocument?.identity
            && renderedReadmeDocumentID != nil
            && renderedReadmeDocumentID == retainedReadmeDocument?.identity
        withAnimation(.easeOut(duration: reduceMotion ? 0.12 : 0.24)) {
            isReadmeContentVisible = isReady
            isReadmeSkeletonVisible = !isReady
        }
    }

    private func receiveReadmeReady(_ documentID: String) {
        guard documentID == retainedReadmeDocument?.identity,
              documentID == currentReadmeDocument?.identity else { return }
        renderedReadmeDocumentID = documentID
        failedReadmeDocumentID = nil
        updateReadmeVisibility()
    }

    /// 渲染失败不能无限显示骨架；保留宿主并展示可恢复的错误入口。
    private func receiveReadmeFailure(_ documentID: String) {
        guard documentID == retainedReadmeDocument?.identity,
              documentID == currentReadmeDocument?.identity else { return }
        failedReadmeDocumentID = documentID
        withAnimation(.easeOut(duration: reduceMotion ? 0.12 : 0.24)) {
            isReadmeContentVisible = false
            isReadmeSkeletonVisible = false
        }
    }

    /// 重试只刷新当前失败的文档身份，不重建阅读器宿主或同仓库的其它编辑区域。
    private func retryReadme() {
        if failedReadmeDocumentID != nil {
            readmeRetryGeneration += 1
        }
        if let target = scopedMarkdownDocument?.target {
            openMarkdownInCurrentDetail(target, forceRefresh: true)
        } else {
            onRetry()
        }
    }

    /// 正文链接仍按文件刷新，仓库 README 的刷新才同时更新仓库计数。
    private func refreshDetail() {
        if scopedMarkdownDocument == nil { subscriberCountRefresh?.perform() }
        retryReadme()
    }

    /// 切换 repo 时 `state` 可能仍停留在上一个 `.loaded`（onChange 晚于 body 一帧）；
    /// 此时只显示不透明骨架，避免叠在旧 WebView 上。
    private var showsReadmePlaceholder: Bool {
        if isStateStaleForScope { return true }
        switch presentedReadmeState {
        case .idle, .loading:
            return true
        case .loaded, .empty, .requiresLogin, .error:
            return false
        }
    }

    /// 当前 scope 已对齐时才生成可呈现文档，避免 A 仓的延迟结果覆盖 B 仓。
    private var currentReadmeDocument: PresentedReadmeDocument? {
        guard !isStateStaleForScope,
              case .loaded(let html, let cachedAt) = presentedReadmeState
        else { return nil }
        if let document = scopedMarkdownDocument {
            return PresentedReadmeDocument(
                html: document.html,
                cachedAt: document.loadedAt,
                identity: "\(markdownScopeIdentity)|markdown:\(document.identity)|retry:\(readmeRetryGeneration)",
                baseURL: document.target.contentBaseURL,
                target: document.target
            )
        }
        return PresentedReadmeDocument(
            html: html,
            cachedAt: cachedAt,
            identity: "\(markdownScopeIdentity)|\(readmeVM.activeDocumentID ?? "unidentified")|retry:\(readmeRetryGeneration)",
            baseURL: baseURL
        )
    }

    /// onChange 只比较短 token，避免对可能很大的 README HTML 做重复 Equatable / SHA 计算。
    private var readmeDocumentToken: String {
        currentReadmeDocument?.identity ?? "\(refreshCommandIdentity)|unloaded"
    }

    /// 导出当前 README 的原始 Markdown 到本地文件。
    ///
    /// 仅 Manage 路径支持（需要本地 Repo 对象 + readme_contents 表）。
    /// Trending 路径没有本地 Repo，暂不接入。
    ///
    /// 流程：
    /// 1. 查 `readme_contents` 表 → 命中直接导出
    /// 2. 未命中 → 调 `ReadmeAPI.refreshMarkdownIfNeeded(for:)` 从 GitHub 拉取 → 再导出
    /// 3. 弹出 NSSavePanel 让用户选择保存位置，文件名默认 `{repoName}.md`
    private func exportReadmeMarkdown(dependencies: AppDependencies) {
        guard case .manage(let repoId) = contentScope,
              let repo = translationControl?.repo else { return }

        Task {
            let markdown: String
            // 1. 先查本地缓存
            if let cached = try? await dependencies.readmeRepository.findContent(repoId: repoId),
               !cached.isEmpty {
                markdown = cached
            } else {
                // 2. 懒拉取（从 GitHub API 下载原始 Markdown → 写入 readme_contents）
                _ = await dependencies.readmeAPI.refreshMarkdownIfNeeded(for: repo)
                markdown = (try? await dependencies.readmeRepository.findContent(repoId: repoId)) ?? ""
            }

            guard !markdown.isEmpty else { return }

            // 3. 弹出保存面板
            let panel = NSSavePanel()
            panel.title = String.l10n("readme.export.savePanel.title")
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            panel.nameFieldStringValue = "\(repo.name)-README.md"
            panel.canCreateDirectories = true

            let response = panel.runModal()
            guard response == .OK, let url = panel.url else { return }

            do {
                try markdown.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                AppLog.ui.error("Failed to export README markdown: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 用于"新窗口打开 README"的窗口标题。
    ///
    /// Manage 路径从翻译控件拿 `repo.fullName`；Trending 路径从 contentScope 拼。
    private var readmeWindowTitle: String {
        if let repo = translationControl?.repo {
            return repo.fullName
        }
        if case .trending(let owner, let repo) = contentScope {
            return "\(owner)/\(repo)"
        }
        return "README"
    }

    /// 详情页所属仓库。Manage 从翻译控件拿，Trending / Discovery 从 contentScope 拼。
    private var markdownWindowContext: ReadmeWindowMarkdownContext? {
        if let repo = translationControl?.repo {
            return ReadmeWindowMarkdownContext(
                owner: repo.owner,
                repo: repo.name,
                // 私有仓库内的语言版 README / CONTRIBUTING 等文件必须继续使用
                // GitHub App Contents 权限，不能在独立窗口退回主 OAuth client。
                readmeAPI: repo.isPrivate
                    ? dependencies.projectReadmeAPI
                    : dependencies.readmeAPI
            )
        }
        if case .trending(let owner, let repo) = contentScope {
            return ReadmeWindowMarkdownContext(
                owner: owner,
                repo: repo,
                readmeAPI: dependencies.readmeAPI
            )
        }
        return nil
    }

    /// WebKit 已完成同仓分类与 ⌘ 点击判断；这里只决定应用内的承载位置。
    private func openRepositoryMarkdown(_ target: RepositoryMarkdownLinkTarget) {
        guard let context = markdownWindowContext else { return }
        switch settings.repositoryMarkdownOpenMode {
        case .browser:
            NSWorkspace.shared.open(target.browserURL)
        case .newWindow:
            ReadmeWindowController.showRepositoryMarkdown(
                target: target, dependencies: dependencies, readmeAPI: context.readmeAPI
            )
        case .currentDetail:
            openMarkdownInCurrentDetail(target)
        }
    }

    private func openMarkdownInCurrentDetail(_ target: RepositoryMarkdownLinkTarget, forceRefresh: Bool = false) {
        guard let context = markdownWindowContext else { return }
        markdownNavigation.open(
            target, scopeIdentity: markdownScopeIdentity, preservingDocument: forceRefresh
        ) { target in
            try await context.readmeAPI.fetchRenderedRepositoryMarkdown(
                owner: target.owner, repo: target.repo, path: target.path, ref: target.ref,
                forceRefresh: forceRefresh
            )
        }
    }

    private func returnToReadme() {
        markdownNavigation.reset(scopeIdentity: markdownScopeIdentity)
    }

    private var isStateStaleForScope: Bool {
        switch contentScope {
        case .manage(let repoId):
            return readmeVM.activeRepoId != repoId
        case .trending(let owner, let repo):
            return readmeVM.activeTrendingKey != "\(owner)/\(repo)"
        }
    }

    private var readmePlaceholder: some View {
        ReadmeSkeletonView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 翻译错误 toast 操作按钮文案。仅 AI 配置类错误显示"前往设置"。
    private var translationToastActionLabel: String? {
        guard translationControl?.translationVM.translationErrorKind == .aiConfiguration else {
            return nil
        }
        return "readme.translate.error.goToAISettings"
    }

    /// 翻译错误 toast 操作按钮回调：打开设置页并跳转到 AI 服务 tab。
    private var translationToastOnAction: (() -> Void)? {
        guard translationControl?.translationVM.translationErrorKind == .aiConfiguration else {
            return nil
        }
        return {
            AppDelegate.openSettingsWindow(target: "ai")
        }
    }

    private var isReadmeTranslating: Bool {
        guard let identity = currentReadmeTranslationIdentity else { return false }
        return translationVMForBinding.isActivelyTranslating(matching: identity)
    }

    /// 只上屏当前仓的译文。共享 VM 在切探索 / 活动条目后仍可能短暂握着上一仓的状态。
    private var scopedTranslationRenderState: ReadmeTranslationRenderState {
        guard let identity = currentReadmeTranslationIdentity else { return .hidden }
        return translationVMForBinding.visibleRenderState(matching: identity)
    }

    private var translationVMForBinding: ReadmeTranslationViewModel {
        translationControl?.translationVM ?? sharedTranslationVM
    }

    private var currentReadmeTranslationIdentity: String? {
        currentTranslationControl?.identity
    }

    /// 文档翻译沿用现有独立缓存身份，语言版 README 不得与默认 README 共用译文。
    private var currentTranslationControl: ReadmeTranslationControl? {
        translationControl(for: currentReadmeDocument?.target)
    }

    private func translationControl(for target: RepositoryMarkdownLinkTarget?) -> ReadmeTranslationControl? {
        guard var control = translationControl else { return nil }
        if let target {
            control.documentPath = "\(target.ref)/\(target.path)"
        }
        return control
    }

    /// repo + 已对齐文档的轻量身份。scope 未对齐时不算 loaded，避免用 A 的 HTML 给 B prepare。
    private var translationSyncKey: String {
        let repoKey = translationControl.map { "\($0.owner)/\($0.name)" } ?? "none"
        return "\(repoKey)|\(readmeDocumentToken)"
    }

    private func syncSharedTranslationToCurrentRepo() {
        let vm = translationVMForBinding
        let language = settings.effectiveReadmeTranslationLanguage
        let mode = settings.readmeTranslationMode
        guard let control = currentTranslationControl else {
            vm.prepare(
                repo: nil,
                sourceHtml: nil,
                targetLanguage: language,
                mode: mode,
                engine: settings.readmeTranslationEngine
            )
            return
        }
        vm.prepare(
            identity: control.identity,
            cacheOwner: control.cacheOwner,
            cacheRepo: control.cacheRepo,
            sourceHtml: currentReadmeDocument?.html,
            targetLanguage: language,
            mode: mode,
            engine: settings.readmeTranslationEngine
        )
    }

    /// 已加载 README 始终占据同一个结构分支；切 repo 时只更新现有 WKWebView 的文档。
    private func loadedReadmeContent(_ document: PresentedReadmeDocument) -> some View {
        let exportMarkdown: (() -> Void)? = document.target == nil
            ? { exportReadmeMarkdown(dependencies: dependencies) }
            : nil
        let openMarkdown: ((RepositoryMarkdownLinkTarget) -> Void)? = markdownWindowContext == nil
            ? nil
            : { openRepositoryMarkdown($0) }
        let approachingBottom: () -> Void = document.target == nil
            ? effectiveOnApproachingBottom
            : {}

        return VStack(spacing: 0) {
            // 两种翻译方式都不替换整份 HTML。WebView 始终持有原始 DOM：
            // 分段模式追加译文，全文模式只替换 Text node，切换时无需重建原生视图。
            let renderedHtml = document.html
            let documentBaseURL = document.baseURL
            let windowTitle = document.target?.windowTitle ?? readmeWindowTitle
            let documentKey = document.identity
            let markdownContext = markdownWindowContext
            ReadmeWebView(
                htmlFragment: renderedHtml,
                documentID: documentKey,
                baseURL: documentBaseURL,
                onScrollReportChange: onScrollReportChange,
                onOpenInNewWindow: { [html = renderedHtml, baseURL = documentBaseURL, windowTitle, dependencies, markdownContext] in
                    ReadmeWindowController.show(
                        htmlFragment: html,
                        baseURL: baseURL,
                        title: windowTitle,
                        dependencies: dependencies,
                        markdownContext: markdownContext
                    )
                },
                onExportMarkdown: exportMarkdown,
                floatingToolbarTrailingPadding: 14,
                markdownLinkRepositoryOwner: markdownContext?.owner,
                markdownLinkRepositoryName: markdownContext?.repo,
                onOpenRepositoryMarkdown: openMarkdown,
                translationRenderState: scopedTranslationRenderState,
                onTranslationSourceChange: { snapshot in
                    translationSourceDocumentKey = documentKey
                    translationSourceSnapshot = snapshot
                },
                starHistoryRenderState: document.target == nil ? effectiveStarHistoryRenderState : .empty,
                onApproachingBottom: approachingBottom,
                onDocumentReady: receiveReadmeReady,
                onDocumentFailed: receiveReadmeFailure,
                allowsSameDocumentAnchors: document.target != nil
            )
            // 与 ActivityReleaseDetailContent 对齐：body slot 必须吃满 Scaffold 剩余
            // 高度，否则 WKWebView 在 VStack 里按零 intrinsic 高度布局 → 闪一下后空白。
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 圆角只为翻译光圈对齐；空闲不加灰描边——README 是阅读区不是卡片，
            // 彩虹条带自己画环，不依赖静止边框。
            .clipShape(RoundedRectangle(cornerRadius: StarcatAIHaloMetrics.cornerRadius, style: .continuous))
            // README 与通知评论卡共用连续 CA 光圈；NSView 层才能稳定盖住 WKWebView。
            // 底边不预留 glowBleed：WebView 白底会透进底部垫片，与 .vertical 8 叠出
            // 约 16pt 的空带压在 cacheFooter 上方，footer 工具栏因此看起来高了一截；
            // 翻译光圈的底边光晕由 footer（VStack 后绘制的兄弟节点）盖住，顶 / 侧光晕不受影响。
            .padding(EdgeInsets(
                top: StarcatAIHaloMetrics.glowBleed,
                leading: StarcatAIHaloMetrics.glowBleed,
                bottom: 0,
                trailing: StarcatAIHaloMetrics.glowBleed
            ))
            .overlay {
                StarcatAIBloomHaloLayerView(
                    isActive: isReadmeTranslating,
                    reduceMotion: reduceMotion
                )
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            cacheFooter(
                cachedAt: document.cachedAt,
                documentTarget: document.target,
                sourceHtml: document.html,
                sourceSnapshot: translationSourceDocumentKey == documentKey
                    ? translationSourceSnapshot
                    : .empty
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 非 Manage README 页面沿用同一份 cache-first / ETag / DOM 骨架逻辑。
    /// Manage 已经在外层持有 ViewModel，因此只在显式传入 `starHistoryRepo` 时启用。
    private var effectiveStarHistoryRenderState: ReadmeStarHistoryRenderState {
        starHistoryRepo == nil
            ? starHistoryRenderState
            : (readmeStarHistoryViewModel?.renderState ?? .empty)
    }

    private var effectiveOnApproachingBottom: () -> Void {
        starHistoryRepo == nil ? onApproachingBottom : startReadmeStarHistoryFallbackIfNeeded
    }

    /// 用 owner/repo 组成身份，而不是只用临时 Repo.id；Trending / Discovery 的 Repo
    /// 可能是未落库的 ephemeral 对象，但同一公开仓库仍必须共享加载生命周期。
    private var readmeStarHistoryPreloadIdentity: String? {
        guard let repo = starHistoryRepo else { return nil }
        return "\(repo.owner.lowercased())/\(repo.name.lowercased())|\(repo.id)|\(dependencies.databaseScopeRevision)|\(locale.identifier)"
    }

    private func preloadReadmeStarHistoryIfNeeded() async {
        guard let repo = starHistoryRepo else {
            readmeStarHistoryViewModel?.cancel()
            return
        }
        guard repo.starsCount > 0 else {
            readmeStarHistoryViewModel?.cancel()
            return
        }

        let historyViewModel: ReadmeStarHistoryViewModel
        if let readmeStarHistoryViewModel {
            historyViewModel = readmeStarHistoryViewModel
        } else {
            let created = ReadmeStarHistoryViewModel(
                repository: dependencies.repoStarHistoryRepository,
                projectVisibilityProvider: { repoID in
                    (try? await dependencies.userProjectRepository.fetchProject(repoID: repoID))?.visibility
                }
            )
            readmeStarHistoryViewModel = created
            historyViewModel = created
        }

        await historyViewModel.loadIfNeeded(
            repo: repo,
            databaseScopeRevision: dependencies.databaseScopeRevision,
            locale: locale
        )
    }

    private func startReadmeStarHistoryFallbackIfNeeded() {
        guard starHistoryRepo?.starsCount ?? 0 > 0 else { return }
        readmeStarHistoryTask?.cancel()
        readmeStarHistoryTask = Task {
            await preloadReadmeStarHistoryIfNeeded()
        }
    }

    private func cancelReadmeStarHistory() {
        readmeStarHistoryTask?.cancel()
        readmeStarHistoryTask = nil
        readmeStarHistoryViewModel?.cancel()
    }

    @ViewBuilder
    private var resolvedNonLoadedContent: some View {
        switch state {
        case .idle, .loading, .loaded:
            EmptyView()
        case .empty:
            // 无 README 也保留底栏：作者后来补文件时，用户仍能点右下角强制重拉，
            // 不被「空态藏 footer」挡在缓存门外（与 loaded 的 cacheFooter 同结构）。
            VStack(spacing: 0) {
                EmptyStateView(
                    systemImage: "",
                    title: "readme.empty",
                    subtitle: "readme.emptyDescription",
                    businessIcon: .readme
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                emptyStatusFooter()
            }

        case .requiresLogin:
            VStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 36))
                    .foregroundStyle(.blue)
                Text("readme.requiresLogin")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("readme.requiresLoginDescription")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button("action.login", action: onLogin)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .focusEffectDisabled()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .error(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36))
                    .foregroundStyle(.orange)
                Text("readme.failed")
                    .font(.headline)
                Text(verbatim: message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button("action.retry", action: onRetry)
                    .controlSize(.small)
                    .focusEffectDisabled()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 缓存时间脚注，便于用户判断是否需要手动刷新。
    ///
    /// 右下角刷新按钮使用共享 `SyncIconButton`（与 Trending toolbar 同款图标 + 旋转动画）。
    /// 2026-06-02 替换前用的是 `arrow.clockwise` + `.symbolEffect(.variableColor.iterative)`，
    /// 视觉是颜色脉动而非旋转，与 dong4j 期望的"刷新中应该转圈"不符；统一为 `SyncIconButton` 后，
    /// manage / trending 两个详情页（共用 ReadmeStateView）+ Trending toolbar 三处行为完全一致。
    ///
    /// HOM-68：右下角追加翻译入口（仅 Manage 详情页传入 translationControl 时显示）。
    /// 把 `sourceHtml` 透给翻译按钮——按钮调 LLM 时需要把当前源 HTML 作为输入。
    private func cacheFooter(
        cachedAt: Date,
        documentTarget: RepositoryMarkdownLinkTarget?,
        sourceHtml: String,
        sourceSnapshot: ReadmeTranslationSourceSnapshot
    ) -> some View {
        readmeStatusFooter {
            // 时钟和图文必须先合成一组。外层 footer 的 12pt 是给左侧状态与右侧按钮用的；
            // 若把 Image / Text 直接作为 HStack 子项，图标和「缓存于」会被拉开到 12pt。
            if let documentTarget {
                Button("readme.document.backToReadme", action: returnToReadme)
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .font(.caption2)
                    .lineLimit(1)
                    .fixedSize()
                Text(verbatim: documentTarget.path)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(documentTarget.path)
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.caption2)
                    Text(String(format: String.l10n("readme.cachedAtFormat"), RelativeTimeText.pastEvent(cachedAt, locale: locale)))
                        .font(.caption2)
                }
            }
            Spacer()
            if let control = translationControl(for: documentTarget) {
                ReadmeTranslationFooterButton(
                    control: control,
                    sourceHtml: sourceHtml,
                    sourceSnapshot: sourceSnapshot
                )
                Divider().frame(height: 14)
            }
            readmeRefreshButton
        }
    }

    /// 无 README 空态底栏：左侧中性说明，右侧只留刷新（无 HTML 不展示翻译）。
    private func emptyStatusFooter() -> some View {
        readmeStatusFooter {
            Text("readme.emptyFooterStatus")
                .font(.caption2)
            Spacer()
            readmeRefreshButton
        }
    }

    /// loaded / empty 共用底栏容器，保证高度、边距与 `.bar` 背景一致。
    private func readmeStatusFooter<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            content()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 6)
        .foregroundStyle(.secondary)
        .background(.bar)
        // 状态栏高度受系统字体和右侧按钮组合影响。只测量、不参与布局，避免 AI
        // child window 继续用固定间距而覆盖状态栏；没有 footer 的状态分支不会上报值。
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: RepoDetailAIOverlayBottomInsetPreference.self,
                    value: proxy.size.height
                )
            }
        }
    }

    private var readmeRefreshButton: some View {
        SyncIconButton(
            isRefreshing: isMarkdownRefreshing || readmeVM.isRefreshing,
            disabled: isMarkdownRefreshing || readmeVM.isRefreshing,
            font: .caption2,
            frameSize: 18,
            tooltip: String.l10n("readme.refresh"),
            action: refreshDetail
        )
    }
}

// MARK: - HOM-68 翻译控件

/// 详情页注入 `ReadmeStateView` 的翻译控件描述（值类型 + closure 传递必要依赖）。
///
/// 不让 ReadmeStateView 直接依赖 `ReadmeTranslationViewModel` / `AppSettings` 的好处：
/// - 翻译入口是否出现仍由可选 `translationControl` 表达（ephemeral repo 传 nil）；
/// - 共享 VM 的切仓 bind 由 ReadmeStateView 经 Environment 完成，探索 / 活动 /
///   周刊与星标走同一条路径。
@MainActor
struct ReadmeTranslationControl {
    let owner: String
    let name: String
    let repositoryID: Int64?
    /// Manage 的 Markdown 导出与私有仓库鉴权仍需要完整 Repo；下载窗口仅有仓库身份。
    private(set) var repo: Repo?
    let translationVM: ReadmeTranslationViewModel
    let settings: AppSettings

    /// nil 表示仓库 README；文件传入仓库内路径，复用控件时不能覆盖 README 的缓存。
    var documentPath: String? = nil

    init(
        owner: String, name: String, repositoryID: Int64? = nil,
        translationVM: ReadmeTranslationViewModel, settings: AppSettings, documentPath: String? = nil
    ) {
        self.owner = owner
        self.name = name
        self.repositoryID = repositoryID
        self.repo = nil
        self.translationVM = translationVM
        self.settings = settings
        self.documentPath = documentPath
    }

    /// 下载窗口可能没有入库仓库；身份只取 owner/name/path，不伪造 Repo 或 GitHub ID。
    init(
        repo: Repo, translationVM: ReadmeTranslationViewModel,
        settings: AppSettings, documentPath: String? = nil
    ) {
        self.init(
            owner: repo.owner, name: repo.name, repositoryID: repo.id,
            translationVM: translationVM, settings: settings, documentPath: documentPath
        )
        self.repo = repo
    }

    var identity: String {
        if let documentPath {
            return "document:\(owner)/\(name):\(documentPath)"
        }
        return ReadmeTranslationViewModel.readmeIdentity(owner: owner, repo: name)
    }

    var cacheOwner: String {
        documentPath == nil ? owner : "_starcat-documents"
    }

    /// 路径哈希是合法的单层目录名；不含 commit，让正文小改动继续复用已翻译段落。
    var cacheRepo: String {
        documentPath == nil ? name : ReadmeTranslationService.hash(identity)
    }
}

/// README cacheFooter 区域的翻译入口按钮。
///
/// 设计：
/// - 一次点击 = toggle：未显示译文时点击触发翻译（命中缓存即时上屏，否则调 LLM），
///   已显示译文时点击切回原文，符合 dong4j Coding Style 里"最少操作即可完成任务"。
/// - 旁边的下拉菜单负责"选择目标语言"+"重新翻译"+"清除当前译文"，避免在 footer 里
///   堆出多个按钮抢空间。
/// - 翻译进行中图标切换为思考球（与 AI 标签整理行同款）。
/// - 错误不再内联到 footer，改为通过 toast 浮动提示（5 秒自动关闭 + AI 配置类错误可跳转设置）。
struct ReadmeTranslationFooterButton: View {

    let control: ReadmeTranslationControl
    let sourceHtml: String
    let sourceSnapshot: ReadmeTranslationSourceSnapshot
    /// 文件工具栏沿用 Issues 的紧凑图标；README footer 保留原有文字入口。
    var isCompact = false

    /// 翻译中时按钮 hover 状态——hover 显示 stop 图标 + tooltip 切"停止翻译"。
    ///
    /// 2026-06-14 dong4j 反馈"详情页的右下角的翻译, 没有停止操作, 需要添加一个,
    /// 光标移动到图标上显示停止图标, 点击之后停止翻译"。设计选择：
    ///   - 复用主翻译按钮位置（不新增独立 stop 按钮）：避免 footer 区按钮堆积，且
    ///     hover 切换符合用户对"翻译中按钮 = 当前能做的事就是取消"的直觉；
    ///   - hover 时只切**图标**，文字"翻译"保持不变：按钮宽度不抖动，视觉聚焦在 icon；
    ///   - 翻译中按钮**不再 disabled**：让 click 能落地触发 `cancelTranslation()`；
    ///   - 默认思考球动画：脱离 hover 时仍清晰看到"在跑"。
    @State private var isHoveringWhileTranslating: Bool = false

    /// 2026-06-15:hover 切图标的 0.15s 淡入在「关闭应用内动画」时跳过。
    @Environment(\.starcatReduceMotion) private var reduceMotion

    private var translationVM: ReadmeTranslationViewModel { control.translationVM }
    private var settings: AppSettings { control.settings }
    private var selectedSourceSegments: [ReadmeSourceSegment] {
        sourceSnapshot.segments(for: settings.readmeTranslationMode)
    }

    /// 判断当前是否展示译文，用于按钮文字 / icon 切换。
    /// 必须绑定文档：同一仓库的 README 和多个 Skill 各自持有独立译文。
    private var isShowingTranslation: Bool {
        translationVM.isShowingTranslation(matching: control.identity)
    }

    private var isTranslatingCurrentDocument: Bool {
        translationVM.isActivelyTranslating(matching: control.identity)
    }

    var body: some View {
        HStack(spacing: isCompact ? 0 : 4) {
            if isCompact {
                translationButton.toolbarIconHover()
            } else {
                translationButton
            }
            languageMenu
        }
    }

    private var translationButton: some View {
        Button {
            if isTranslatingCurrentDocument {
                // 翻译中保留点击入口用于取消；已完成段落继续由 VM 保留，稍后可接着翻译。
                translationVM.cancelTranslation()
            } else {
                translationVM.toggleTranslation(
                    identity: control.identity,
                    cacheOwner: control.cacheOwner,
                    cacheRepo: control.cacheRepo,
                    repoId: control.repositoryID,
                    sourceHtml: sourceHtml,
                    sourceSegments: selectedSourceSegments,
                    targetLanguage: settings.effectiveReadmeTranslationLanguage,
                    mode: settings.readmeTranslationMode,
                    engine: settings.readmeTranslationEngine
                )
            }
        } label: {
            if isCompact {
                compactIconView
                    .squareLogoActionChrome(
                        side: 22,
                        backgroundColor: isShowingTranslation
                            ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.10)
                    )
            } else {
                HStack(spacing: 4) {
                    iconView
                    Text(buttonTitle)
                        .font(.caption2)
                }
                .foregroundStyle(isShowingTranslation ? .blue : .secondary)
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(
            !isTranslatingCurrentDocument
                && (sourceHtml.isEmpty || selectedSourceSegments.isEmpty)
        )
        .help(buttonTooltip)
        .accessibilityLabel(Text(isTranslatingCurrentDocument ? "readme.translate.tooltip.stop" : buttonTitle))
        .onHover { hovering in
            if isTranslatingCurrentDocument {
                isHoveringWhileTranslating = hovering
            } else if isHoveringWhileTranslating {
                isHoveringWhileTranslating = false
            }
        }
    }

    /// 与 Issues 同一图标画布和进度环；悬停只切可见层，进度不会重置。
    @ViewBuilder
    private var compactIconView: some View {
        if isTranslatingCurrentDocument {
            let total = translationVM.totalSegmentCount
            let fraction = total > 0
                ? min(max(Double(translationVM.completedSegmentCount) / Double(total), 0), 1) : 0
            ZStack {
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: fraction)
                }
                .opacity(isHoveringWhileTranslating ? 0 : 1)
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.red)
                    .opacity(isHoveringWhileTranslating ? 1 : 0)
            }
            .frame(width: 14, height: 14)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isHoveringWhileTranslating)
            .accessibilityValue(Text(verbatim: "\(translationVM.completedSegmentCount)/\(total)"))
        } else {
            Image(systemName: isShowingTranslation ? "character.bubble.fill" : "character.bubble")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isShowingTranslation ? Color.accentColor : Color.primary)
                .frame(width: 14, height: 14)
        }
    }

    /// 按钮图标：3 态切换。
    ///   - 翻译中 + 未 hover → 思考球（与 AI 标签整理行同款，明确"AI 在跑"）
    ///   - 翻译中 + hover → 红色 `stop.fill`（暗示"点击可停"）
    ///   - 非翻译态 → 原 `character.bubble[.fill]` 取决于是否已显示译文
    ///
    /// 翻译中两态用 ZStack + opacity 切换而非 if-else，是因为：
    ///   - if-else 切换会导致 SwiftUI 重新初始化思考球，TimelineView 动画从 0 重启，
    ///     用户连续 hover / leave 时会看到"动画反复重置"的不连续感；
    ///   - ZStack + opacity 保留思考球实例 + 让动画连贯跑下去，hover 切走
    ///     时只是隐藏不重启。
    /// 加 `.animation(.easeInOut(duration: 0.15), value: isHoveringWhileTranslating)`
    /// 让 hover 切换有淡入淡出，避免硬切。
    @ViewBuilder
    private var iconView: some View {
        if isTranslatingCurrentDocument {
            ZStack {
                // 翻译中用 AI 标签整理行（BatchAITagReviewRow.statusIcon）同款思考球
                // 替代系统菊花，统一「AI 在跑」的视觉语言；displaySize 12 适配本按钮
                // 的 12×12 图标槽，paused 透传 reduceMotion 做「关闭应用内动画」兜底。
                ThinkingOrb(
                    state: .working,
                    size: .px20,
                    theme: .auto,
                    paused: reduceMotion,
                    displaySize: 12
                )
                .accessibilityHidden(true)
                .opacity(isHoveringWhileTranslating ? 0 : 1)
                Image(systemName: "stop.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .opacity(isHoveringWhileTranslating ? 1 : 0)
            }
            .frame(width: 12, height: 12)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isHoveringWhileTranslating)
        } else {
            Image(systemName: isShowingTranslation
                  ? "character.bubble.fill"
                  : "character.bubble")
                .font(.caption2)
        }
    }

    /// 主按钮文案：未翻译 → "翻译"；已翻译 → "原文"。
    /// 缓存与当前源不匹配时给 "翻译" 一个 stale 标记，引导用户主动 regenerate。
    /// 翻译中也保持"翻译"文字不变（仅图标 hover 切 stop），避免按钮宽度抖动。
    private var buttonTitle: LocalizedStringKey {
        if isShowingTranslation { return "readme.translate.showOriginal" }
        if translationVM.cacheIsStale {
            // 文档入口复用通用的“重新翻译”，不能把 Skill 更新显示成“README 已更新”。
            return control.documentPath == nil ? "readme.translate.staleAction" : "readme.translate.menu.regenerate"
        }
        return "readme.translate.action"
    }

    private var buttonTooltip: LocalizedStringKey {
        // 翻译中 + hover → "停止翻译"，明确点击会取消而非其它操作。
        if isTranslatingCurrentDocument && isHoveringWhileTranslating {
            return "readme.translate.tooltip.stop"
        }
        if isShowingTranslation {
            return control.documentPath == nil ? "readme.translate.tooltip.showOriginal" : "readme.translate.showOriginal"
        }
        // 引擎可变后文案不再写死 AI，统一指向「所选翻译服务」。
        return "readme.translate.tooltip.translateService"
    }

    /// 右侧 chevron 下拉菜单：引擎 / 方式 / 语言 / 重新翻译。
    /// 不放更多按钮：footer 已足够小，再加按钮会和右边的刷新图标抢空间。
    @State private var availableEngines: [ReadmeTranslationEngine] = []

    private var languageMenu: some View {
        Menu {
            if !availableEngines.isEmpty {
                Picker(selection: Binding(
                    get: { settings.readmeTranslationEngine },
                    set: { settings.readmeTranslationEngine = $0 }
                )) {
                    ForEach(availableEngines) { engine in
                        Label(
                            LocalizedStringKey(engine.displayNameKey),
                            systemImage: engine.systemImage
                        )
                        .tag(engine)
                    }
                } label: {
                    Text("readme.translate.menu.engine")
                }
                .pickerStyle(.inline)

                Divider()
            }

            Picker(selection: Binding(
                get: { settings.readmeTranslationMode },
                set: { settings.readmeTranslationMode = $0 }
            )) {
                ForEach(ReadmeTranslationMode.allCases) { mode in
                    Label(
                        LocalizedStringKey(mode.displayNameKey),
                        systemImage: mode.systemImage
                    )
                    .tag(mode)
                }
            } label: {
                Text("readme.translate.menu.mode")
            }
            .pickerStyle(.inline)

            Divider()

            Picker(selection: Binding(
                get: { settings.readmeTranslationLanguage },
                set: { settings.readmeTranslationLanguage = $0 }
            )) {
                ForEach(ReadmeTranslationLanguage.allCases) { lang in
                    Text(verbatim: lang.displayName).tag(lang)
                }
            } label: {
                Text("readme.translate.menu.language")
            }
            .pickerStyle(.inline)

            Divider()

            Button {
                translationVM.regenerate(
                    identity: control.identity,
                    cacheOwner: control.cacheOwner,
                    cacheRepo: control.cacheRepo,
                    repoId: control.repositoryID,
                    sourceHtml: sourceHtml,
                    sourceSegments: selectedSourceSegments,
                    targetLanguage: settings.effectiveReadmeTranslationLanguage,
                    mode: settings.readmeTranslationMode,
                    engine: settings.readmeTranslationEngine
                )
            } label: {
                Label("readme.translate.menu.regenerate", systemImage: "arrow.clockwise")
            }
            .disabled(
                isTranslatingCurrentDocument
                    || sourceHtml.isEmpty
                    || selectedSourceSegments.isEmpty
            )
        } label: {
            // 与 UnifiedSortMenu 的下拉指示器对齐。
            // 注意：只改 `.caption` / `.caption2` 对 chevron.down 光学差几乎看不出；
            // 用显式 12pt semibold，和排序菜单旁箭头同级可见。
            Image(systemName: "chevron.down")
                .font(isCompact ? .caption : .system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: isCompact ? nil : 16, height: isCompact ? 22 : 16)
                .padding(.horizontal, isCompact ? 2 : 0)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // Menu 默认会把 label 提亮成 primary；强制 secondary，避免比左侧气泡更亮、更抢眼。
        .tint(.secondary)
        .frame(width: isCompact ? nil : 18, height: isCompact ? 22 : nil)
        .focusEffectDisabled()
        .clickablePointer()
        .help("readme.translate.menu.tooltip")
        .task(id: settings.effectiveReadmeTranslationLanguage) {
            await refreshAvailableEngines()
        }
    }

    @MainActor
    private func refreshAvailableEngines() async {
        let available = await ReadmeTranslationEngineAvailability.availableEngines(
            targetLanguage: settings.effectiveReadmeTranslationLanguage,
            settings: settings,
            keychain: KeychainManager.shared
        )
        availableEngines = available
        let resolved = ReadmeTranslationEngineAvailability.resolvedDefault(
            current: settings.readmeTranslationEngine,
            available: available
        )
        if resolved != settings.readmeTranslationEngine, !available.isEmpty {
            settings.readmeTranslationEngine = resolved
        }
    }
}

// MARK: - 小组件

private struct StatItem: View {
    let label: LocalizedStringKey
    let value: Int?
    let introductionKey: RepoStatCountKey
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .center, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .font(.system(size: 14))
                RepoMetadataCountLabel(count: value, introductionKey: introductionKey)
                    .font(.system(size: 14, weight: .medium))
            }
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

private struct DateStatItem: View {
    let label: LocalizedStringKey
    let value: String?
    let systemImage: String

    var body: some View {
        VStack(alignment: .center, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                Text(formattedDate)
                    .monospacedDigit()
                    .lineLimit(1)
                    .font(.system(size: 12, weight: .medium))
            }
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var formattedDate: String {
        guard let value, let date = ISO8601DateFormatter().date(from: value) else {
            return "-"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

struct WatchersMenu: View {
    let repo: Repo
    let loadsMissingSubscriberCount: Bool
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.colorScheme) private var colorScheme
    @State private var isPresented = false

    var body: some View {
        RepoSubscriberCountView(repo: repo, loadsIfMissing: loadsMissingSubscriberCount) { count in
            Button {
                isPresented = true
            } label: {
                StatItem(
                    label: "repo.stats.watchers",
                    value: count,
                    introductionKey: .init(repo.fullName, .subscribers),
                    systemImage: "eye.fill",
                    tint: StatSemanticColor.watchers.resolved(colorScheme: colorScheme)
                )
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .fixedSize()
            .pressableHover(scale: 1)
            .help("repo.watch")
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                RepoWatchOptions(repo: repo)
                    .id("\(dependencies.authSession.state.user?.id ?? 0):\(repo.fullName.lowercased())")
                    .appLocaleEnvironment()
            }
        }
    }
}

/// 面板保留异步结果，直到用户关闭。每次打开按当前账号读取，避免在账号间复用关注状态。
private struct RepoWatchOptions: View {
    let repo: Repo
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.dismiss) private var dismiss
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.repoSubscriberCountRefresh) private var subscriberCountRefresh

    private enum Mode: CaseIterable {
        case participating, allActivity, ignore

        var title: LocalizedStringKey {
            switch self {
            case .participating: "watch.participating"
            case .allActivity: "watch.allActivity"
            case .ignore: "watch.ignore"
            }
        }

        var description: LocalizedStringKey {
            switch self {
            case .participating: "watch.participating.description"
            case .allActivity: "watch.allActivity.description"
            case .ignore: "watch.ignore.description"
            }
        }

        static func from(_ subscription: GitHubSubscriptionDTO) -> Self? {
            if subscription.subscribed { return .allActivity }
            if subscription.ignored { return .ignore }
            return nil
        }
    }

    private enum Subscription: Equatable {
        case loading
        case loaded(Mode?)
        case needsAuthorization
        case loadFailed
    }

    private enum Operation: Equatable {
        case load
        case save(Mode)
    }

    private enum Feedback: Equatable {
        case saved, saveFailed

        var title: LocalizedStringKey {
            switch self {
            case .saved: "watch.updateSuccess"
            case .saveFailed: "watch.updateFailed"
            }
        }
    }

    @State private var subscription: Subscription = .loading
    @State private var operation: Operation? = .load
    @State private var feedback: Feedback?
    @State private var discussionsEnabled: Bool?

    private var selectedMode: Mode? {
        guard case .loaded(let mode) = subscription else { return nil }
        return mode
    }

    private var canChangeMode: Bool {
        guard case .loaded = subscription else { return false }
        return operation == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("repo.stats.watchers")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Mode.allCases, id: \.self) { mode in
                    modeRow(mode, isSelected: mode == selectedMode)
                }
            }
            .disabled(!canChangeMode)

            if dependencies.authSession.state.isAuthenticated {
                subscriptionStatus
            } else {
                Button("action.login") {
                    dismiss()
                    dependencies.authSession.requestLoginSheet()
                }
            }

            Divider()
            customEvents
            Divider()
            Label("watch.listRestriction", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 320, alignment: .leading)
        .padding(12)
        // 覆盖原生浮层的透底材质，避免仓库内容影响文字对比度。
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: operation) {
            guard let operation, dependencies.authSession.state.isAuthenticated else { return }
            await perform(operation)
        }
        .task {
            await loadDiscussionAvailability()
        }
    }

    /// 勾选标记始终占位，悬停只绘制高亮，避免选中与未选中行的文字错位。
    private func modeRow(_ mode: Mode, isSelected: Bool) -> some View {
        Button {
            if isSelected {
                feedback = .saved
            } else {
                operation = .save(mode)
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .frame(width: 14)
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.title)
                        .font(.subheadline.weight(.semibold))
                    Text(mode.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(isSelected ? 0.12 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .inlineActionHover()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var subscriptionStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            if operation != nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("watch.loading").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                switch subscription {
                case .needsAuthorization:
                    Text("activity.notification.missingScope.subtitle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("activity.notification.missingScope.action") {
                        let session = dependencies.authSession
                        dismiss()
                        Task {
                            await session.signOut()
                            session.requestLoginSheet()
                        }
                    }
                case .loadFailed:
                    Text("watch.loadFailed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("action.retry") { operation = .load }
                case .loaded:
                    if let feedback {
                        Label(feedback.title, systemImage: feedback == .saved ? "checkmark.circle" : "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.opacity)
                    }
                case .loading:
                    EmptyView()
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: feedback)
    }

    private var customEvents: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("watch.custom.title")
                .font(.subheadline.weight(.semibold))
            TagChipFlowLayout(constrainsItemWidth: true) {
                eventChip("repo.issues.entry.title", systemImage: "exclamationmark.circle")
                eventChip("watch.custom.event.pullRequests", systemImage: "arrow.triangle.pull")
                eventChip("repo.stats.releases", systemImage: "tag")
                eventChip(
                    "watch.custom.event.discussions", systemImage: "bubble.left.and.bubble.right",
                    isUnavailable: discussionsEnabled == false
                )
                eventChip("watch.custom.event.securityAlerts", systemImage: "shield")
            }
            if discussionsEnabled == false {
                Text("watch.custom.discussionsDisabled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("watch.custom.instructions")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let url = URL(string: repo.htmlUrl) {
                Link("watch.custom.openSettings", destination: url)
                    .font(.caption)
            }
        }
    }

    /// 复用语言筛选的胶囊表面，事件在 GitHub 网页内编辑。
    private func eventChip(_ title: LocalizedStringKey, systemImage: String, isUnavailable: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)
            Text(title)
                .lineLimit(1)
        }
        .font(.caption)
        .modifier(TagChipSurface(color: isUnavailable ? .secondary : .accentColor, isSelected: false))
        .opacity(isUnavailable ? 0.65 : 1)
        .help(Text(title))
    }

    /// 复用仓库资料的缓存策略，讨论状态读取不阻塞前三个订阅档位。
    private func loadDiscussionAvailability() async {
        let metadata = try? await dependencies.apiClient.repo(owner: repo.owner, repo: repo.name)
        guard !Task.isCancelled else { return }
        discussionsEnabled = metadata?.hasDiscussions
    }

    /// 面板关闭、切仓库或切账号会取消任务，避免旧请求回写状态。
    private func perform(_ requestedOperation: Operation) async {
        defer { operation = nil }
        feedback = nil
        do {
            let api = dependencies.apiClient
            switch requestedOperation {
            case .load:
                let mode: Mode?
                do {
                    let response = try await api.getSubscription(owner: repo.owner, repo: repo.name)
                    mode = Mode.from(response)
                } catch NetworkError.notFound {
                    mode = .participating
                }
                try Task.checkCancellation()
                subscription = .loaded(mode)
            case .save(let mode):
                let confirmedMode: Mode?
                if mode == .participating {
                    try await api.deleteSubscription(owner: repo.owner, repo: repo.name)
                    confirmedMode = .participating
                } else {
                    let response = try await api.putSubscription(
                        owner: repo.owner, repo: repo.name,
                        subscribed: mode == .allActivity, ignored: mode == .ignore
                    )
                    confirmedMode = Mode.from(response)
                }
                try Task.checkCancellation()
                subscription = .loaded(confirmedMode)
                feedback = confirmedMode == mode ? .saved : .saveFailed
                if confirmedMode == mode { subscriberCountRefresh?.perform() }
            }
        } catch GitHubWatchSubscriptionError.missingNotificationsScope {
            guard !Task.isCancelled else { return }
            subscription = .needsAuthorization
        } catch {
            guard !Task.isCancelled else { return }
            AppLog.sync.error("Repository watch action failed: \(error.localizedDescription, privacy: .private)")
            switch requestedOperation {
            case .load: subscription = .loadFailed
            case .save: feedback = .saveFailed
            }
        }
    }
}

// R-01 §3.2.3 Phase B3（2026-06-10）：原 `TrendingHeroAvatarButton` 已删除。
// Trending 详情页左上角项目 logo 改由 `RepoMetadataHeaderView` 内置 hero 头像承接，
// 与 Manage / Weekly / Activity 视觉统一；外链跳转入口由 hero「在 GitHub 查看」chip 提供。
