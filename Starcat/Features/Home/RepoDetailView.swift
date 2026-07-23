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
                    showsRepoHealthEntry: true,
                    onStarTapped: {
                        // §3.2.3 状态机：throws 让 StarStatChipButton 抖动 + 短暂红色（不弹 alert）
                        try await handleStarTapped(repo: repo)
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
        // 严格只看 `detailContentID`（基于 selectedRepo.id / trending.id / "empty" 计算），
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
    /// 三种状态：Manage repo（id 形如 "12345"）/ Trending repo（id 形如 "owner/name"）
    /// / 空态（"empty"）。任意一种切换到另一种 → 触发 view transition；同状态内
    /// 重新选同一条 → id 不变 → 无动画。
    private var detailContentID: String {
        if viewModel.selection == .smartCollectionsHome { return "smart-collections-home-empty" }
        if let id = viewModel.selectedRepo?.id { return "manage-\(id)" }
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
        if authSession.state.isAuthenticated {
            actions.append(.share)
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
    private func handleStarTapped(repo: Repo) async throws {
        guard authSession.state.isAuthenticated else {
            // 2026-06-29：只弹登录 sheet，不强制走 Device Flow
            authSession.requestLoginSheet()
            return
        }
        try await dependencies.starActionService.toggle(repo: repo)
        await viewModel.refreshSidebar()
        await viewModel.reloadItems(forceRefresh: true)
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
    @Environment(\.openSettings) private var openSettings

    /// 相对时间 helper 需要显式 `\.locale`，否则 formatter 会回到系统语言。
    /// 已挂 `appLocaleEnvironment()` 的子树自动拿到正确值。
    @Environment(\.locale) private var locale

    /// Toast 消息绑定（翻译错误 → 底部浮动提示）。
    @State private var translationToast: String?
    /// 当前已渲染文档的两种翻译输入。用 document key 守门，避免切 repo 的一帧窗口误用旧数据。
    @State private var translationSourceDocumentKey: String?
    @State private var translationSourceSnapshot: ReadmeTranslationSourceSnapshot = .empty

    let state: ReadmeViewModel.LoadState
    let contentScope: ReadmeContentScope
    let baseURL: URL?
    let onScrollReportChange: (RepoDetailScrollReport) -> Void
    /// HOM-68：可选的 README 翻译控件描述。nil 时不渲染翻译入口
    /// （Trending 详情页不接翻译，传 nil；Manage 详情页传具体值）。
    let translationControl: ReadmeTranslationControl?
    let onRetry: () -> Void
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
        onRetry: @escaping () -> Void,
        onLogin: @escaping () -> Void
    ) {
        self.state = state
        self.contentScope = contentScope
        self.baseURL = baseURL
        self.onScrollReportChange = onScrollReportChange
        self.translationControl = translationControl
        self.onRetry = onRetry
        self.onLogin = onLogin
    }

    /// 骨架 → 真实 README 的轻微 reveal（与 splash 主窗口 0.72s 相比更短，避免拖慢阅读）。
    private enum ReadmeRevealTiming {
        static let contentRevealSeconds = 0.36
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if showsReadmePlaceholder {
                readmePlaceholder
                    .transition(readmePlaceholderTransition)
                    .zIndex(0)
            }

            if !showsReadmePlaceholder {
                resolvedReadmeContent
                    .transition(readmeContentTransition)
                    .zIndex(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .animation(
            reduceMotion ? nil : .easeOut(duration: ReadmeRevealTiming.contentRevealSeconds),
            value: showsReadmePlaceholder
        )
        .toast(
            message: $translationToast,
            icon: "exclamationmark.triangle.fill",
            iconColor: .orange,
            bottomPadding: 30,
            autoDismiss: false,
            actionLabel: translationToastActionLabel,
            onAction: translationToastOnAction
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
        .starcatRefreshCommand(
            pane: .detail,
            identity: "\(refreshCommandIdentity)-\(readmeVM.isRefreshing)",
            title: String.l10n("commands.actions.refreshCurrentDetail"),
            isEnabled: !readmeVM.isRefreshing,
            action: onRetry
        )
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
        reduceMotion ? .identity : .opacity
    }

    /// 内容从略缩小 + 透明淡入，骨架同步 opacity 淡出，形成轻微 crossfade。
    private var readmeContentTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        return .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.992, anchor: .topLeading)),
            removal: .opacity
        )
    }

    /// 切换 repo 时 `state` 可能仍停留在上一个 `.loaded`（onChange 晚于 body 一帧）；
    /// 此时只显示不透明骨架，避免叠在旧 WebView 上。
    private var showsReadmePlaceholder: Bool {
        if isStateStaleForScope { return true }
        switch state {
        case .idle, .loading:
            return true
        case .loaded, .empty, .requiresLogin, .error:
            return false
        }
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
        return { [openSettings] in
            openSettings()
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .starcatJumpToSettingsTab, object: "ai"
                )
            }
        }
    }

    @ViewBuilder
    private var resolvedReadmeContent: some View {
        switch state {
        case .idle, .loading:
            readmePlaceholder

        case .loaded(let html, let cachedAt):
            VStack(spacing: 0) {
                // 两种翻译方式都不替换整份 HTML。WebView 始终持有原始 DOM：
                // 分段模式追加译文，全文模式只替换 Text node，切换时无需重载页面。
                let renderedHtml = html
                let windowTitle = readmeWindowTitle
                let documentKey = ReadmeTranslationService.hash(html)
                ReadmeWebView(
                    htmlFragment: renderedHtml,
                    baseURL: baseURL,
                    onScrollReportChange: onScrollReportChange,
                    onOpenInNewWindow: { [html = renderedHtml, baseURL, windowTitle, settings] in
                        ReadmeWindowController.show(
                            htmlFragment: html,
                            baseURL: baseURL,
                            title: windowTitle,
                            settings: settings
                        )
                    },
                    onExportMarkdown: { [dependencies] in
                        exportReadmeMarkdown(dependencies: dependencies)
                    },
                    translationRenderState: translationControl?.translationVM.renderState ?? .hidden,
                    onTranslationSourceChange: { snapshot in
                        translationSourceDocumentKey = documentKey
                        translationSourceSnapshot = snapshot
                    }
                )
                .id(readmeWebViewIdentity)
                // 与 ActivityReleaseDetailContent 对齐：body slot 必须吃满 Scaffold 剩余
                // 高度，否则 WKWebView 在 VStack 里按零 intrinsic 高度布局 → 闪一下后空白。
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                cacheFooter(
                    cachedAt: cachedAt,
                    sourceHtml: html,
                    sourceSnapshot: translationSourceDocumentKey == documentKey
                        ? translationSourceSnapshot
                        : .empty
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .empty:
            EmptyStateView(
                systemImage: "doc.text",
                title: "readme.empty",
                subtitle: "readme.emptyDescription"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

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

    private var readmeWebViewIdentity: String {
        switch contentScope {
        case .manage(let repoId):
            return "manage-\(repoId)"
        case .trending(let owner, let repo):
            return "trending-\(owner)/\(repo)"
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
        sourceHtml: String,
        sourceSnapshot: ReadmeTranslationSourceSnapshot
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "clock")
                .font(.caption2)
            Text(String(format: String.l10n("readme.cachedAtFormat"), RelativeTimeText.pastEvent(cachedAt, locale: locale)))
                .font(.caption2)
            Spacer()
            if let control = translationControl {
                ReadmeTranslationFooterButton(
                    control: control,
                    sourceHtml: sourceHtml,
                    sourceSnapshot: sourceSnapshot
                )
                Divider().frame(height: 14)
            }
            SyncIconButton(
                isRefreshing: readmeVM.isRefreshing,
                disabled: readmeVM.isRefreshing,
                font: .caption2,
                frameSize: 18,
                tooltip: String.l10n("readme.refresh"),
                action: onRetry
            )
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 6)
        .foregroundStyle(.secondary)
        .background(.bar)
    }
}

// MARK: - HOM-68 翻译控件

/// 详情页注入 `ReadmeStateView` 的翻译控件描述（值类型 + closure 传递必要依赖）。
///
/// 不让 ReadmeStateView 直接依赖 `ReadmeTranslationViewModel` / `AppSettings` 的好处：
/// - ReadmeStateView 是个无副作用的状态视图，多个详情页（Manage / Trending）都在共用，
///   Trending 路径暂不接翻译；用可选值表达"是否需要翻译入口"比把环境注入条件化更直接；
/// - 单元测试 / Preview 可以传 nil 跳过翻译控件，不需要 mock 翻译 VM。
@MainActor
struct ReadmeTranslationControl {
    let repo: Repo
    let translationVM: ReadmeTranslationViewModel
    let settings: AppSettings
}

/// README cacheFooter 区域的翻译入口按钮。
///
/// 设计：
/// - 一次点击 = toggle：未显示译文时点击触发翻译（命中缓存即时上屏，否则调 LLM），
///   已显示译文时点击切回原文，符合 dong4j Coding Style 里"最少操作即可完成任务"。
/// - 旁边的下拉菜单负责"选择目标语言"+"重新翻译"+"清除当前译文"，避免在 footer 里
///   堆出多个按钮抢空间。
/// - 翻译进行中切换为 ProgressView + 禁用，复用与同列其它按钮（SyncIconButton）一致的视觉。
/// - 错误不再内联到 footer，改为通过 toast 浮动提示（手动关闭 + AI 配置类错误可跳转设置）。
struct ReadmeTranslationFooterButton: View {

    let control: ReadmeTranslationControl
    let sourceHtml: String
    let sourceSnapshot: ReadmeTranslationSourceSnapshot

    /// 翻译中时按钮 hover 状态——hover 显示 stop 图标 + tooltip 切"停止翻译"。
    ///
    /// 2026-06-14 dong4j 反馈"详情页的右下角的翻译, 没有停止操作, 需要添加一个,
    /// 光标移动到图标上显示停止图标, 点击之后停止翻译"。设计选择：
    ///   - 复用主翻译按钮位置（不新增独立 stop 按钮）：避免 footer 区按钮堆积，且
    ///     hover 切换符合用户对"翻译中按钮 = 当前能做的事就是取消"的直觉；
    ///   - hover 时只切**图标**，文字"翻译"保持不变：按钮宽度不抖动，视觉聚焦在 icon；
    ///   - 翻译中按钮**不再 disabled**：让 click 能落地触发 `cancelTranslation()`；
    ///   - 默认 ProgressView 转圈：脱离 hover 时仍清晰看到"在跑"。
    @State private var isHoveringWhileTranslating: Bool = false

    /// 2026-06-15:hover 切图标的 0.15s 淡入在「关闭应用内动画」时跳过。
    @Environment(\.starcatReduceMotion) private var reduceMotion

    private var translationVM: ReadmeTranslationViewModel { control.translationVM }
    private var settings: AppSettings { control.settings }
    private var selectedSourceSegments: [ReadmeSourceSegment] {
        sourceSnapshot.segments(for: settings.readmeTranslationMode)
    }

    /// 判断当前是否展示译文，用于按钮文字 / icon 切换。
    private var isShowingTranslation: Bool {
        if case .showingTranslation = translationVM.displayMode { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                if translationVM.isTranslating {
                    // 翻译中点击 = 用户主动停止：调 VM.cancelTranslation 取消正在跑的
                    // Task + 复位 isTranslating + 不弹错误。下方 onHover 会在按钮失焦后
                    // 把 isHoveringWhileTranslating 复位，恢复默认 icon 形态。
                    translationVM.cancelTranslation()
                } else {
                    translationVM.toggleTranslation(
                        repo: control.repo,
                        sourceHtml: sourceHtml,
                        sourceSegments: selectedSourceSegments,
                        targetLanguage: settings.readmeTranslationLanguage,
                        mode: settings.readmeTranslationMode
                    )
                }
            } label: {
                HStack(spacing: 4) {
                    iconView
                    Text(buttonTitle)
                        .font(.caption2)
                }
                .foregroundStyle(isShowingTranslation ? .blue : .secondary)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            // 翻译中要让点击能落地触发 cancel，所以 disabled 条件改成：
            //   - 翻译中：永远可点（点击 = 取消）；
            //   - 非翻译中 + sourceHtml 为空：disabled（无内容可翻译 / 切换）。
            .disabled(
                !translationVM.isTranslating
                    && (sourceHtml.isEmpty || selectedSourceSegments.isEmpty)
            )
            .help(buttonTooltip)
            .onHover { hovering in
                // 只在翻译中跟踪 hover 切 icon；非翻译态不需要这个状态，确保切回
                // 普通态时 isHoveringWhileTranslating 也被复位，防止下次进入翻译时
                // 因残留 true 直接显示 stop 图标（虽然实际 hover 离开会立刻 false，
                // 但额外守门更稳）。
                if translationVM.isTranslating {
                    isHoveringWhileTranslating = hovering
                } else if isHoveringWhileTranslating {
                    isHoveringWhileTranslating = false
                }
            }

            languageMenu
        }
    }

    /// 按钮图标：3 态切换。
    ///   - 翻译中 + 未 hover → 转圈 ProgressView（明确"在跑"）
    ///   - 翻译中 + hover → 红色 `stop.fill`（暗示"点击可停"）
    ///   - 非翻译态 → 原 `character.bubble[.fill]` 取决于是否已显示译文
    ///
    /// 翻译中两态用 ZStack + opacity 切换而非 if-else，是因为：
    ///   - if-else 切换会导致 SwiftUI 重新初始化 ProgressView，转圈动画从 0 重启，
    ///     用户连续 hover / leave 时会看到"动画反复重置"的不连续感；
    ///   - ZStack + opacity 保留 ProgressView 实例 + 让动画连贯跑下去，hover 切走
    ///     时只是隐藏不重启。
    /// 加 `.animation(.easeInOut(duration: 0.15), value: isHoveringWhileTranslating)`
    /// 让 hover 切换有淡入淡出，避免硬切。
    @ViewBuilder
    private var iconView: some View {
        if translationVM.isTranslating {
            ZStack {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 12, height: 12)
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
        if translationVM.cacheIsStale { return "readme.translate.staleAction" }
        return "readme.translate.action"
    }

    private var buttonTooltip: LocalizedStringKey {
        // 翻译中 + hover → "停止翻译"，明确点击会取消而非其它操作。
        if translationVM.isTranslating && isHoveringWhileTranslating {
            return "readme.translate.tooltip.stop"
        }
        if isShowingTranslation { return "readme.translate.tooltip.showOriginal" }
        return "readme.translate.tooltip.translate"
    }

    /// 右侧 chevron 下拉菜单：切换目标语言、重新翻译。
    /// 不放更多按钮：footer 已足够小，再加按钮会和右边的刷新图标抢空间。
    private var languageMenu: some View {
        Menu {
            Picker(selection: Binding(
                get: { settings.readmeTranslationMode },
                set: { settings.readmeTranslationMode = $0 }
            )) {
                ForEach(ReadmeTranslationMode.allCases) { mode in
                    Text(LocalizedStringKey(mode.displayNameKey)).tag(mode)
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
                    repo: control.repo,
                    sourceHtml: sourceHtml,
                    sourceSegments: selectedSourceSegments,
                    targetLanguage: settings.readmeTranslationLanguage,
                    mode: settings.readmeTranslationMode
                )
            } label: {
                Label("readme.translate.menu.regenerate", systemImage: "arrow.clockwise")
            }
            .disabled(
                translationVM.isTranslating
                    || sourceHtml.isEmpty
                    || selectedSourceSegments.isEmpty
            )
        } label: {
            Image(systemName: "chevron.down")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 16)
        .focusEffectDisabled()
        .help("readme.translate.menu.tooltip")
    }
}

// MARK: - 小组件

private struct StatItem: View {
    let label: LocalizedStringKey
    let value: Int
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .center, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .font(.system(size: 14))
                Text(value, format: .number)
                    .monospacedDigit()
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
    @Environment(AppDependencies.self) private var dependencies
    /// Watchers 图标用 StatSemanticColor.watchers 紫色(light/dark 双主题)。
    @Environment(\.colorScheme) private var colorScheme
    
    enum WatchState: Equatable {
        case loading
        case participating // un-watched (default)
        case allActivity // subscribed: true, ignored: false
        case ignore // subscribed: false, ignored: true
        case custom // other states
        case error
    }
    
    @State private var watchState: WatchState = .loading
    @State private var loadedRepoId: Int64?
    
    var body: some View {
        Menu {
            switch watchState {
            case .loading:
                Text("watch.loading")
            case .error:
                Button("action.retry") {
                    Task { await fetchSubscription() }
                }
            default:
                Button {
                    Task { await updateSubscription(subscribed: false, ignored: false) }
                } label: {
                    if watchState == .participating {
                        Label("watch.participating", systemImage: "checkmark")
                    } else {
                        Text("watch.participating")
                    }
                }

                Button {
                    Task { await updateSubscription(subscribed: true, ignored: false) }
                } label: {
                    if watchState == .allActivity {
                        Label("watch.allActivity", systemImage: "checkmark")
                    } else {
                        Text("watch.allActivity")
                    }
                }

                Button {
                    Task { await updateSubscription(subscribed: false, ignored: true) }
                } label: {
                    if watchState == .ignore {
                        Label("watch.ignore", systemImage: "checkmark")
                    } else {
                        Text("watch.ignore")
                    }
                }

                Divider()

                Button {
                    if let url = URL(string: "\(repo.htmlUrl)/watchers") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("watch.viewOnGithub", systemImage: "safari")
                }
            }
        } label: {
            StatItem(label: "repo.watchers", value: repo.watchersCount, systemImage: "eye.fill", tint: StatSemanticColor.watchers.resolved(colorScheme: colorScheme))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .fixedSize()
        // 2026-06-02 dong4j 要求统一 hover 反馈：跟 Stars / Forks 一样加
        // `.pressableHover()`，让用户感知 Watchers 数字是可点击的（点开下拉菜单）。
        .pressableHover()
        .help("repo.watch")
        // D-37（2026-06-29）：原来用 `.simultaneousGesture(TapGesture())` 想做"打开菜单才懒加载",
        // 但 macOS Menu label 内部 button 优先消费 tap event,挂在外层的 .onEnded 在 Menu 上不可靠
        // 触发,导致 fetchSubscription Task 永远不启动,watchState 永远停在 .loading。
        // 改回 `.task(id: repo.id)`,cache 命中就跳过;跟工程内 9+ 个其他 section 同款 lifecycle。
        // .task 在 view 离开 / repo 切换时会自动 cancel 旧任务,符合"切换 repo 不抢网络"原意。
        .task(id: repo.id) {
            if WatchSubscriptionSessionCache.state(for: repo.id) == nil {
                await fetchSubscription()
            } else {
                applyCachedSubscriptionState()
            }
        }
    }
    
    @discardableResult
    private func applyCachedSubscriptionState() -> Bool {
        if let cached = WatchSubscriptionSessionCache.state(for: repo.id) {
            watchState = cached
            loadedRepoId = repo.id
            return true
        }
        // GitHub Watch 状态只在用户打开菜单时才需要；切换 repo 不再自动打
        // `/subscription`，避免详情切换路径抢网络和触发额外状态更新。
        watchState = .loading
        loadedRepoId = nil
        return false
    }

    private func fetchSubscription() async {
        let requestedRepoId = repo.id
        if loadedRepoId == requestedRepoId, watchState != .error {
            return
        }
        watchState = .loading
        do {
            let dto = try await dependencies.apiClient.getSubscription(owner: repo.owner, repo: repo.name)
            let resolvedState: WatchState
            if dto.subscribed {
                resolvedState = .allActivity
            } else if dto.ignored {
                resolvedState = .ignore
            } else {
                resolvedState = .custom
            }
            guard repo.id == requestedRepoId else { return }
            watchState = resolvedState
            loadedRepoId = requestedRepoId
            WatchSubscriptionSessionCache.set(resolvedState, for: requestedRepoId)
        } catch NetworkError.notFound {
            // 404 在 GitHub Watch API 是预期行为：表示用户对这个 repo 没有显式
            // 订阅记录、保持默认 Participating 级别（不是"repo 不存在"）。
            // 完整语义见 `StarsAPI.getSubscription` 的 doc comment。
            guard repo.id == requestedRepoId else { return }
            watchState = .participating
            loadedRepoId = requestedRepoId
            WatchSubscriptionSessionCache.set(.participating, for: requestedRepoId)
        } catch {
            guard repo.id == requestedRepoId else { return }
            watchState = .error
        }
    }
    
    private func updateSubscription(subscribed: Bool, ignored: Bool) async {
        let repoId = repo.id
        let previousState = watchState
        watchState = .loading
        do {
            if !subscribed && !ignored {
                try await dependencies.apiClient.deleteSubscription(owner: repo.owner, repo: repo.name)
                guard repo.id == repoId else { return }
                watchState = .participating
            } else {
                let dto = try await dependencies.apiClient.putSubscription(
                    owner: repo.owner,
                    repo: repo.name,
                    subscribed: subscribed,
                    ignored: ignored
                )
                guard repo.id == repoId else { return }
                if dto.subscribed {
                    watchState = .allActivity
                } else if dto.ignored {
                    watchState = .ignore
                } else {
                    watchState = .custom
                }
            }
            WatchSubscriptionSessionCache.set(watchState, for: repoId)
            loadedRepoId = repoId
        } catch {
            AppLog.sync.error("Update subscription failed: \(error.localizedDescription, privacy: .public)")
            watchState = previousState
        }
    }
}

@MainActor
private enum WatchSubscriptionSessionCache {
    private static var states: [Int64: WatchersMenu.WatchState] = [:]

    static func state(for repoId: Int64) -> WatchersMenu.WatchState? {
        states[repoId]
    }

    static func set(_ state: WatchersMenu.WatchState, for repoId: Int64) {
        states[repoId] = state
    }
}

// R-01 §3.2.3 Phase B3（2026-06-10）：原 `TrendingHeroAvatarButton` 已删除。
// Trending 详情页左上角项目 logo 改由 `RepoMetadataHeaderView` 内置 hero 头像承接，
// 与 Manage / Weekly / Activity 视觉统一；外链跳转入口由 hero「在 GitHub 查看」chip 提供。
