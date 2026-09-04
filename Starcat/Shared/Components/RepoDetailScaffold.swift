//
//  RepoDetailScaffold.swift
//  Starcat
//
//  R-01「三场景共用架构」详情页通用骨架（Hero header + trailing actions + body slot）。
//
//  ────────────────────────────────────────────────────────────────────────────
//  设计意图（详细设计 §3.2）
//  ────────────────────────────────────────────────────────────────────────────
//
//  各场景详情页（Manage / Trending / Weekly / Activity-repo-backed）只需提供：
//    1. 当前 `Repo` 实例（驱动 Hero header 视觉 + ⭐/☆ chip）
//    2. `RepoDetailViewData`（trailingActions 列表 + 翻译 context + backendHint）
//    3. `onStarTapped` 闭包（Hero stats 行 ⭐/☆ chip 触发 star/unstar）
//    4. `body` view-builder（ContentView 插槽，自由渲染 ScrollView + sections + README）
//
//  Scaffold 负责：
//    - Hero header（复用 `RepoMetadataHeaderView`,渲染元信息 + ⭐/☆ chip + trailing actions）
//    - 折叠面板（复用 `CollapsibleRepoMetadataPanel`）
//    - heroExtension slot（场景特化的 hero 后内容,如 Trending Contributors）
//    - **RepoLocalSections（v1.5 修订, 2026-06-10）**：Tags / Notes (含阅读状态) /
//      Releases 订阅三段内置渲染在 metadataPanel 内,跟随 hero **整段折叠**;
//      4 场景同构（Manage / Trending / Weekly / Activity-repo-backed 都是同样
//      `RepoLocalSections(repo: repo)` 调用）,内置消除 4 场景重复 + 解决「滚动
//      README 时三段挤压阅读区」bug。详见下方 v1.5 修订段。
//    - trailingActions 渲染（按 `RepoDetailAction` enum 派发）
//
//  Scaffold **不**负责：
//    - body 内部布局（ContentView 自己持有 ScrollView + Readme）
//    - star/unstar 业务逻辑（由 onStarTapped 上层处理）
//    - 翻译浮动按钮 / 刷新浮动按钮（这两个是 ReadmeStateView 的内嵌 cacheFooter,
//      ContentView 渲染 ReadmeStateView 时已经包含;Scaffold 不重复渲染）
//
//  ────────────────────────────────────────────────────────────────────────────
//  v2.1 修订（2026-06-11, dong4j bug 反馈「右下角多了一个一模一样的刷新图标」）：
//  ────────────────────────────────────────────────────────────────────────────
//
//  撤销 P0-E（2026-06-10）的 §3.2.9「右下角浮动刷新按钮」设计 —— 删除 `onRefresh:`
//  入参 + `.overlay(alignment: .bottomTrailing)` 浮动 SyncIconButton + 内部 isRefreshing
//  状态机。回归本文件头一开始就声明的设计原则:「翻译浮动按钮 / 刷新浮动按钮 ... Scaffold
//  不重复渲染」。
//
//  当时（P0-E）加这个浮动按钮的目的是给 Manage 详情提供「整页刷新」入口，但同位置
//  `ReadmeStateView.cacheFooter` **始终**也渲染一个同款 `SyncIconButton`(只刷 README) →
//  视觉上同位置叠两个一样的图标,用户分不清职责差异,反馈为 bug。
//
//  修复方向(dong4j 选 A:合并)：cacheFooter 内那个按钮在 Manage 场景**同时**刷 README
//  + reloadItems(整页 repo 视图数据)。Manage 路径下已通过 `ManageDetailContent` 注入
//  `HomeViewModel` + onRetry 闭包内并发触发 `readmeVM.reload(...)` + `Task { await
//  viewModel.reloadItems(forceRefresh: true) }` 实现(详见 `ManageDetailContent.swift`
//  文件头 v2.1 修订段)。Trending / Activity / Weekly 三场景的 cacheFooter onRetry 不变,
//  仍只刷 README,符合各自语义。
//
//  关键约束:
//  - i18n key `repo.detail.refresh`(P0-E 引入,en「Refresh details」/zh-Hans「刷新详情」)
//    在本次修订中一并删除,无残留引用。
//  - cacheFooter 按钮的 tooltip 仍是 `readme.refresh`(无文案修改)——避免影响其他 3 个
//    共用 `ReadmeStateView` 的场景的语义;Manage 下「事实上扩展到整页刷新」是合理的,
//    用户在详情页点刷新自然期望全刷。
//  - 后续若再有「需要在详情页提供独立刷新入口」的诉求,先优先看 cacheFooter onRetry 闭包
//    能否承担,而不是再加 Scaffold overlay。
//
//  ────────────────────────────────────────────────────────────────────────────
//  v1.5 修订（2026-06-10, dong4j bug 反馈）：RepoLocalSections 迁回折叠面板内
//  ────────────────────────────────────────────────────────────────────────────
//
//  v1.2 P0（2026-06-10 上午）把 RepoLocalSections 三段从 hero 下沉到 ContentView,
//  理由是「各场景的 section 集合不同,hero 不该知道有几段要展开」。但实际落地后
//  4 场景的 ContentView body 里 RepoLocalSections 调用 100% 一致（`RepoLocalSections(repo: repo)`
//  无任何场景特化参数）—— 抽象层"灵活性"在事实上没有被使用。
//
//  v1.5 上午用户反馈：滚动 README 时只有 hero 一段折叠,中间三段仍占据屏幕中部
//  挤压 README 阅读区。根因 = 三段在 ContentView body 里、不在折叠面板（CollapsibleRepoMetadataPanel）
//  内 → scroll progress 驱不动它。
//
//  权衡：方案 A（Scaffold 内置 RepoLocalSections,跟随折叠）vs 方案 B（slot 化,
//  调用方传 RepoLocalSections）vs 方案 C（透传 progress 自己衰减）。dong4j 拍板
//  方案 A —— 折叠一致性 > 抽象灵活性,4 场景同构事实推翻了原 v1.2 P0「Scaffold
//  不该知道有几段」原则。
//
//  v1.5 实现：本组件直接挂 `RepoLocalSections(repo: repo)` 在 metadataPanel 内
//  hero + heroExtension 之后,跟随 `CollapsibleRepoMetadataPanel` 的 progress
//  自然折叠（panel 按 PreferenceKey 测三段加入后的高度,visibleHeight = panelHeight ×
//  (1 - progress) 同步衰减,opacity / offset 也同步）。
//
//  4 个 ContentView body 删去自己的 `RepoLocalSections(repo:)` 调用,只剩 ReadmeStateView。
//
//  RepoLocalSections 内部的 v1.4 守卫（`isAuthenticated && repo.id != 0`）+ spring
//  0.25s star 后展开转场动画都保留 —— 用户在 trending/weekly 详情点 star 后,
//  panelHeight 会随三段加入而增长,折叠面板与 spring 转场协同（两层动画都是
//  short-duration spring,叠加视觉 OK）。
//
//  ────────────────────────────────────────────────────────────────────────────
//  与现有 RepoDetailView (Manage / Trending) 的迁移路径
//  ────────────────────────────────────────────────────────────────────────────
//
//  Step 6 接入时：
//  - Manage `RepoDetailView` 拆为：`RepoDetailScaffold` + `ManageDetailContent`（body slot）
//  - Trending `TrendingView` 详情拆为：`RepoDetailScaffold` + `TrendingDetailContent`
//  - Weekly `WeeklyDetailView` 拆为：`RepoDetailScaffold` + `WeeklyDetailContent`
//  - Activity-repo-backed 详情拆为：`RepoDetailScaffold` + `ActivityRepoDetailContent`
//
//  各 ContentView 自主判断 `resolution.isLocalHit` 决定是否渲染 tags / notes / release
//  三段（设计 §3.2.3 决策：Scaffold 不带 sections 配置，避免 god view）。
//

import SwiftUI
import AppKit

/// 合并同一布局周期内的滚动报告。
///
/// 这是一个刻意不接入 Observation 的引用对象：属性变化只负责调度，不应成为新的
/// SwiftUI 刷新来源。实例由 `@State` 保持稳定身份，详情 View 重算时不会丢失待处理报告。
@MainActor
private final class RepoDetailScrollReportScheduler {
    var pendingReport: RepoDetailScrollReport?
    var isScheduled = false
}

extension Notification.Name {
    /// 中栏 toolbar 把属于当前仓库的瞬时反馈交给右侧详情页统一呈现。
    static let repoDetailToastRequested = Notification.Name("StarcatRepoDetailToastRequested")
}

/// 跨 NavigationSplitView 相邻列传递的详情 Toast 请求。
///
/// 请求必须携带 repoID；用户在点击后快速切换仓库时，新的详情页不会误显示旧仓库反馈。
struct RepoDetailToastRequest {
    let repoID: Int64
    let messageKey: String

    static func post(repoID: Int64, messageKey: String) {
        NotificationCenter.default.post(
            name: .repoDetailToastRequested,
            object: RepoDetailToastRequest(repoID: repoID, messageKey: messageKey)
        )
    }
}

/// R-01 详情页通用骨架。
///
/// body slot 接受一个 `(RepoDetailScrollReport) -> Void` 闭包参数 —— body 里的
/// ReadmeStateView 等滚动型组件应该把 scroll offset + 可滚动余量通过这个闭包回传，
/// Scaffold 内部换算成顶部折叠面板的 collapse progress（0...1），并在余量不足时
/// 禁止折叠以避免「半折叠 ↔ 展开」振荡。
///
/// 这样设计的理由（vs PreferenceKey）：
/// - PreferenceKey 需要在 body 里手动叠 `.preference(...)`，对调用方不友好
/// - closure 入参显式契约，VS Code 跳定义时一眼看出"是要我把 scroll offset 喂进来"
/// - Scaffold 内部 progress 状态保持 private，body 完全无感
struct RepoDetailScaffold<Body: View, HeroExt: View>: View {

    /// 当前 repo（驱动 Hero header 视觉）。
    let repo: Repo

    /// 详情页通用视图数据（trailingActions / translation / backendHint）。
    let viewData: RepoDetailViewData

    /// Hero stats 行 ⭐/☆ chip 触发的异步动作（设计 §3.2.3 状态机）。
    ///
    /// - 成功（不抛错）→ chip 自动退出 loading；UI 由 `StarredRegistry` /
    ///   `Repo.isStarred` 字段变更驱动重渲染（API 200 才变 UI 原则）
    /// - 抛错 → chip 抖动 + 短暂红色 600ms，不弹 toast / alert
    /// - 闭包内部应：① 未登录走 `authSession.signIn()` 后 return（不抛错）
    ///   ② 已 star 调 `dependencies.starActionService.unstar(repo:)`
    ///   ③ 未 star 调 `dependencies.starActionService.star(owner:repo:)`
    let onStarTapped: () async throws -> Void

    /// Activity 等场景的 fallback 颜色（无语言时 Hero 渐变使用）。
    let fallbackAccentColor: Color

    /// Stars stat chip 的 tooltip 本地化键（透传给 RepoMetadataHeaderView）。
    let starHelpKey: LocalizedStringKey

    /// 是否显示 Pro 项目健康度入口。
    ///
    /// 产品约束：Health 只在 Manage 详情开放。Trending / Weekly / Activity 详情继续只展示
    /// OpenSSF 入口，避免把 Pro 私人功能暴露到公共发现页。
    let showsRepoHealthEntry: Bool

    /// Manage 详情传入时展示语言分布分割线；其它详情场景保持 nil，不加载语言数据。
    let onLanguageTapped: ((String) -> Void)?

    /// 账本行等场景的顶栏一句（如「你 Star 了 · 2 小时前」）。
    ///
    /// 必须画在本骨架内部、tint 下面：挂在 Scaffold 外面会挡住语言色光晕，
    /// 右栏顶上一截变成白板。背景保持透明，对齐中栏 `manageListTopInset`。
    let topBanner: String?

    // v2.1 修订（2026-06-11）：原 `onRefresh: (() async -> Void)?` 入参已删除。
    // 该字段曾给 §3.2.9「右下角浮动刷新按钮」用,但与 cacheFooter 内置 SyncIconButton
    // 视觉重叠造成 bug,详见文件头 v2.1 修订段。现刷新入口统一收口到 cacheFooter
    // (4 场景共用),Manage 场景下 onRetry 闭包内并发触发 README + reloadItems。

    private let heroExtension_: () -> HeroExt
    private let body_: (@escaping (RepoDetailScrollReport) -> Void) -> Body

    /// 顶部面板折叠进度（0 = 完全展开，1 = 完全折叠）。
    @State private var metadataPanelCollapseProgress: CGFloat = 0

    /// 顶部面板自然高度（由 CollapsibleRepoMetadataPanel 内部回填）。
    @State private var metadataPanelHeight: CGFloat = 0

    /// 父级详情栏明确提议的可用高度。Hero 超高时用它计算内部滚动视口，
    /// 避免 480pt 笔记和 AI 步骤面板把下方 README 完全挤出屏幕。
    ///
    /// 这里不能再测量 Scaffold 自己布局完成后的高度：AI 面板会抬高子树自然高度，
    /// 自测结果再反过来放宽 Hero 上限会形成尺寸反馈，最终让 NavigationSplitView
    /// 三栏一起高于最小窗口并被上下裁切。唯一可信边界是 GeometryReader 收到的父级 proposal。
    @State private var detailViewportHeight: CGFloat = 0

    /// README / Release 时间线在 Hero 展开时的可滚动余量（由 body slot 上报）。
    @State private var readmeScrollOverflow: CGFloat?

    /// 滚动回调可能在一次布局周期内密集到达；调度器只保留最新报告，并且本身不参与
    /// SwiftUI Observation，避免为了合并回调再次触发 View 更新。
    @State private var scrollReportScheduler = RepoDetailScrollReportScheduler()

    /// Wiki 探测结果只影响 hero action 区，不参与 window toolbar，避免异步返回时触发
    /// toolbar 重排跳动。
    @State private var wikiRepoKey: String?
    @State private var wikiLinks: [WikiLink] = []

    /// 相似仓库推荐状态机。放在 Scaffold 层是因为推荐入口属于所有 repo 详情页的通用能力。
    @State private var recommendationVM = RepoRecommendationViewModel()

    /// 推荐列表 popover 展示状态。只有 `recommendationVM.items` 非空时才允许打开。
    @State private var showsRecommendations = false

    /// Manage 详情 README / 洞察切换行高度。其它场景保持 0，AI 浮层用原来的 16pt 顶距。
    @State private var aiOverlayTopChromeInset: CGFloat = 0

    /// 当前 repo 的真实知识库状态。
    ///
    /// 状态从 `repo_notes.library_state` 读取；点击成功写库后才更新，避免把 ❤️ 做成
    /// 乐观 UI。Scaffold 会被详情浮窗复用，不能只依赖 HomeViewModel 当前列表页缓存。
    @State private var libraryState: LibraryState = .outsideLibrary
    @State private var isLibraryOperationInFlight = false
    /// 详情页共用 Toast。知识库操作与中栏 toolbar 的复制反馈共享同一承载层，
    /// 避免相邻列各自弹提示导致反馈位置与操作对象不一致。
    @State private var detailToastMessage: String?

    /// Pro 付费墙展示上下文。Wiki / 推荐入口在已登录但非 Pro 时弹出付费墙。
    @State private var proPaywallContext: ProPaywallContext?

    // v2.2 修订（2026-06-16, dong4j）：原 `@State private var showSecurityScoreSheet`
    // 已下沉到 `RepoMetadataHeaderView` —— OpenSSF 入口图标从右上 trailing actions
    // 迁移到 hero `full_name` 同行，sheet state 跟随入口本地化，不再由 Scaffold 维护。

    // v2.1 修订（2026-06-11）：原 `@State private var isRefreshing: Bool` 已删除。
    // 该状态曾给浮动刷新按钮用,现统一由 cacheFooter 内的 `readmeVM.isRefreshing` 驱动。

    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppDependencies.self) private var dependencies
    @Environment(HomeViewModel.self) private var homeViewModel

    /// 顶部面板折叠/展开动画。轻阻尼 spring，让 README WebView 让位时跟手。
    private var metadataPanelAnimation: Animation {
        .interactiveSpring(response: 0.32, dampingFraction: 0.9, blendDuration: 0.08)
    }

    private var detailToastIcon: String {
        switch detailToastMessage {
        case "library.action.failed":
            return "exclamationmark.triangle.fill"
        case "clone.copiedHttps", "clone.copiedGit", "repo.share.link.copied":
            return "checkmark.circle.fill"
        default:
            return "heart.fill"
        }
    }

    private var detailToastIconColor: Color? {
        switch detailToastMessage {
        case "library.action.added":
            return .red
        case "clone.copiedHttps", "clone.copiedGit", "repo.share.link.copied":
            return .green
        default:
            return nil
        }
    }

    /// README 底部 cache footer 占据状态栏位置，详情提示需要上浮一段距离，
    /// 避免胶囊压在状态栏视觉层级上。
    private var detailToastBottomPadding: CGFloat {
        30
    }

    init(
        repo: Repo,
        viewData: RepoDetailViewData,
        fallbackAccentColor: Color = .accentColor,
        starHelpKey: LocalizedStringKey = "repo.unstar",
        showsRepoHealthEntry: Bool = false,
        onLanguageTapped: ((String) -> Void)? = nil,
        topBanner: String? = nil,
        onStarTapped: @escaping () async throws -> Void,
        @ViewBuilder heroExtension: @escaping () -> HeroExt,
        @ViewBuilder body: @escaping (@escaping (RepoDetailScrollReport) -> Void) -> Body
    ) {
        self.repo = repo
        self.viewData = viewData
        self.fallbackAccentColor = fallbackAccentColor
        self.starHelpKey = starHelpKey
        self.showsRepoHealthEntry = showsRepoHealthEntry
        self.onLanguageTapped = onLanguageTapped
        self.topBanner = topBanner
        self.onStarTapped = onStarTapped
        self.heroExtension_ = heroExtension
        self.body_ = body
    }

    /// 便捷构造：无 heroExtension 的常用场景（Manage / Weekly / Activity-repo-backed）。
    init(
        repo: Repo,
        viewData: RepoDetailViewData,
        fallbackAccentColor: Color = .accentColor,
        starHelpKey: LocalizedStringKey = "repo.unstar",
        showsRepoHealthEntry: Bool = false,
        onLanguageTapped: ((String) -> Void)? = nil,
        topBanner: String? = nil,
        onStarTapped: @escaping () async throws -> Void,
        @ViewBuilder body: @escaping (@escaping (RepoDetailScrollReport) -> Void) -> Body
    ) where HeroExt == EmptyView {
        self.init(
            repo: repo,
            viewData: viewData,
            fallbackAccentColor: fallbackAccentColor,
            starHelpKey: starHelpKey,
            showsRepoHealthEntry: showsRepoHealthEntry,
            onLanguageTapped: onLanguageTapped,
            topBanner: topBanner,
            onStarTapped: onStarTapped,
            heroExtension: { EmptyView() },
            body: body
        )
    }

    var body: some View {
        // GeometryReader 在布局开始时就锁定 NavigationSplitView 给详情栏的真实 proposal。
        // 子树即使因 AI 步骤、草稿或 480pt 编辑器突然增高，也只能在这个 viewport 内滚动，
        // 不能把自己的自然高度继续向上传给三栏根容器。
        GeometryReader { proxy in
            let viewportSize = proxy.size

            // v2.1 修订（2026-06-11）：原 `.overlay(alignment: .bottomTrailing)` 浮动刷新
            // 按钮已删除（与 cacheFooter 内置按钮视觉重叠造成 bug,详见文件头 v2.1 修订段）。
            VStack(alignment: .leading, spacing: 0) {
                if let topBanner, !topBanner.isEmpty {
                    Text(verbatim: topBanner)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .manageListFilterBarChrome()
                        // 透明，让根节点 `detailHeroTintBackground` 透到这句和标题栏背后。
                        .background(.clear)
                    Divider()
                }
                metadataPanelViewport(availableHeight: viewportSize.height)
                body_(updateScrollReport)
                    .onPreferenceChange(RepoDetailAIOverlayTopInsetPreference.self) { newValue in
                        guard aiOverlayTopChromeInset != newValue else { return }
                        aiOverlayTopChromeInset = newValue
                    }
                    .overlay(alignment: .bottom) {
                        if isRepositoryAIAvailable {
                            // 所有 repo-backed 详情共用同一个底部 AI 主入口；独立窗口
                            // 仍只能从该面板内部的“在独立窗口中打开”派生。
                            RepoAIFloatingOverlay(
                                repo: repo,
                                topChromeInset: aiOverlayTopChromeInset
                            )
                        }
                    }
            }
            .frame(
                width: viewportSize.width,
                height: viewportSize.height,
                alignment: .top
            )
            // 这是详情栏的最终隔离边界。正常内容通过 Hero / README 自己的滚动容器访问；
            // clipped 只阻止异常的自然尺寸再次污染 NavigationSplitView 三栏布局。
            .clipped()
            .onAppear {
                updateDetailViewportHeight(viewportSize.height)
            }
            .onChange(of: viewportSize.height) { _, newHeight in
                updateDetailViewportHeight(newHeight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // 根节点 tint：必须在 `CollapsibleRepoMetadataPanel` 外，否则 `.clipped()` 裁掉
        // 向上延伸；滚 README 折叠 hero 时同步淡出。
        .detailHeroTintBackground(
            tint: DetailHeroTintBackground.accentColor(
                language: repo.language,
                fallback: fallbackAccentColor
            ),
            opacity: 1 - metadataPanelCollapseProgress
        )
        .id(repo.id)
        .navigationTitle(repo.name)
        .navigationSubtitle(repo.owner)
        .task(id: wikiLookupKey(for: repo)) {
            await loadWikiLinks(for: repo)
        }
        .onReceive(NotificationCenter.default.publisher(for: .wikiCacheDidChange)) { notification in
            reloadWikiLinksIfChanged(notification, for: repo)
        }
        .onReceive(NotificationCenter.default.publisher(for: .wikiCacheDidReset)) { notification in
            reloadWikiLinksIfReset(notification, for: repo)
        }
        .task(id: repo.id, priority: .utility) {
            // 先让出一次执行权，确保详情 Hero / README 首帧提交后再启动旁路推荐。
            // 真正的磁盘 I/O 已在 cache actor 中执行，这里只负责最终 UI 状态赋值。
            await Task.yield()
            guard !Task.isCancelled else { return }
            guard ProjectPrivacyPolicy.allowsDiscoveryLookup(for: repo) else {
                recommendationVM.clear()
                return
            }
            await recommendationVM.loadInitial(
                repoID: repo.id,
                service: dependencies.recommendationContextService
            )
        }
        .task(id: repo.id) {
            await loadLibraryState(for: repo)
        }
        .onReceive(NotificationCenter.default.publisher(for: .repoLibraryStateDidChange)) { notification in
            // 阅读状态切到“使用中”会在 Repository 层自动入库；详情页必须消费同一通知，
            // 否则列表与数据库已经更新，Scaffold 自己持有的 ❤️ 状态仍会停留在旧值。
            guard notification.userInfo?["repoId"] as? Int64 == repo.id,
                  let rawState = notification.userInfo?["libraryState"] as? String else { return }
            libraryState = LibraryState.parse(rawState)
        }
        .onReceive(NotificationCenter.default.publisher(for: .repoDetailToastRequested)) { notification in
            guard let request = notification.object as? RepoDetailToastRequest,
                  request.repoID == repo.id else { return }
            detailToastMessage = request.messageKey
        }
        .sheet(item: $proPaywallContext) { context in
            ProPaywallSheet.hosted(context: context, dependencies: dependencies)
        }
        .toast(
            message: $detailToastMessage,
            icon: detailToastIcon,
            iconColor: detailToastIconColor,
            bottomPadding: detailToastBottomPadding
        )
        .onChange(of: repo.id) { _, _ in
            withAnimation(reduceMotion ? nil : metadataPanelAnimation) {
                metadataPanelCollapseProgress = 0
                readmeScrollOverflow = nil
            }
            showsRecommendations = false
            detailToastMessage = nil
        }
        .onChange(of: metadataPanelHeight) { _, newHeight in
            restoreExpandedHeroIfNeeded(naturalPanelHeight: newHeight)
        }
        .onChange(of: detailViewportHeight) { _, _ in
            restoreExpandedHeroIfNeeded(naturalPanelHeight: metadataPanelHeight)
        }
        .starcatRepositoryAICommand(
            identity: "\(repo.id)-\(repo.fullName)-\(isRepositoryAIAvailable)",
            isEnabled: isRepositoryAIAvailable
        ) {
            openRepositoryAIFromCommand()
        }
    }

    /// 快捷键必须与详情现有 `.ai` action 使用同一门禁；`id == 0` 是公共列表 fallback，
    /// 不能把它交给按 repo ID 缓存会话的 AI 服务。
    private var isRepositoryAIAvailable: Bool {
        guard repo.id != 0 else { return false }
        return viewData.trailingActions.contains { action in
            if case .ai = action { return true }
            return false
        }
    }

    /// 展开当前详情页底部 AI 面板，但不自动生成摘要。
    ///
    /// Settings 成为 key window 时，命令路由仍保存主窗口最后一个有效详情动作；
    /// 因此先前置主窗口，再向已经挂载的 inline overlay 发送展开请求。
    private func openRepositoryAIFromCommand() {
        guard isRepositoryAIAvailable else { return }
        AppDelegate.activateMainWindowIfPossible()
        NotificationCenter.default.post(name: .gettingStartedDidOpenAI, object: nil)
        dependencies.telemetryManager.track(
            .aiPanelOpened,
            properties: [.source: .string("command")]
        )
        NotificationCenter.default.post(
            name: .repoAIInlineOpenRequested,
            object: nil,
            userInfo: ["repoId": repo.id]
        )
    }

    // recommendationOverlay 已删除（v1.1 推荐按钮从右下角浮动迁到 hero trailing actions），
    // 渲染逻辑迁到 `trailingActionsView` 内联。


    /// 接收 body 内部上报的滚动度量，换算成顶部面板折叠 progress。
    ///
    /// v2.3（2026-06-17）：增加「可折叠资格门控」——当 Hero 展开时的可滚动余量小于
    /// 面板自然高度时禁止折叠。否则折叠会压缩下方 WebView 可视高度 → max scroll 回弹 →
    /// progress 回落 → Hero 再展开，形成「半折叠 ↔ 展开」振荡（HelloGitHub 等短 README
    /// 边界场景）。
    private func updateScrollReport(_ report: RepoDetailScrollReport) {
        guard shouldApplyScrollReport(report) else { return }

        // 同一 run loop 里只安排一次 @State 写入，期间到达的新报告覆盖旧报告。
        // 这既保留 WebView 需要的“离开 layout 栈后更新”约束，也避免高速滚动或 Charts
        // 重排时堆积大量 MainActor Task。
        scrollReportScheduler.pendingReport = report
        guard !scrollReportScheduler.isScheduled else { return }
        scrollReportScheduler.isScheduled = true

        // WKScriptMessageHandler / updateNSView 可能在 SwiftUI layout 栈内回调；
        // 推迟到下一 run loop 写 @State，避免重入打断 WebView 首帧 loadHTMLString。
        Task { @MainActor in
            let latestReport = scrollReportScheduler.pendingReport
            scrollReportScheduler.pendingReport = nil
            scrollReportScheduler.isScheduled = false
            if let latestReport {
                applyScrollReport(latestReport)
            }
        }
    }

    /// 在创建 MainActor Task 前先判断报告是否真的会改变状态。
    ///
    /// `readmeScrollOverflow` 原先每次报告都会赋值，即使只是 Charts 产生的亚像素抖动；
    /// 这会重新布局整个详情页，并立即生成下一份滚动报告。
    private func shouldApplyScrollReport(_ report: RepoDetailScrollReport) -> Bool {
        let nextOverflow = Self.resolvedScrollOverflow(
            current: readmeScrollOverflow,
            reported: report.scrollOverflow
        )
        let overflowChanged = nextOverflow != readmeScrollOverflow
        let effectivePanelHeight = effectiveMetadataPanelHeight(naturalHeight: metadataPanelHeight)
        let stableScrollOverflow = Self.expandedScrollOverflow(
            currentOverflow: nextOverflow,
            panelHeight: effectivePanelHeight,
            collapseProgress: metadataPanelCollapseProgress
        )
        let canCollapse = Self.canCollapseHero(
            scrollOverflow: stableScrollOverflow,
            panelHeight: effectivePanelHeight
        )
        let rawProgress = Self.metadataCollapseProgress(for: report.offsetY)
        let nextProgress = canCollapse ? rawProgress : 0
        return overflowChanged || abs(nextProgress - metadataPanelCollapseProgress) > 0.01
    }

    private func applyScrollReport(_ report: RepoDetailScrollReport) {
        let nextOverflow = Self.resolvedScrollOverflow(
            current: readmeScrollOverflow,
            reported: report.scrollOverflow
        )
        if nextOverflow != readmeScrollOverflow {
            readmeScrollOverflow = nextOverflow
        }

        // Hero 内部滚动时，折叠门槛应以“屏幕上真正占用的高度”计算，
        // 而不是用可能超过整个窗口的自然高度；否则长笔记会让 Hero 永远不具备折叠资格。
        let effectivePanelHeight = effectiveMetadataPanelHeight(naturalHeight: metadataPanelHeight)
        let stableScrollOverflow = Self.expandedScrollOverflow(
            currentOverflow: readmeScrollOverflow,
            panelHeight: effectivePanelHeight,
            collapseProgress: metadataPanelCollapseProgress
        )
        let canCollapse = Self.canCollapseHero(
            scrollOverflow: stableScrollOverflow,
            panelHeight: effectivePanelHeight
        )
        let rawProgress = Self.metadataCollapseProgress(for: report.offsetY)
        let progress = canCollapse ? rawProgress : 0
        guard abs(progress - metadataPanelCollapseProgress) > 0.01 else { return }
        metadataPanelCollapseProgress = progress
    }

    /// 面板内容或窗口高度变化后重新检查折叠资格。
    ///
    /// 长笔记会在编辑 / 预览 / AI 步骤切换时改变自然高度；如果正文已经
    /// 没有足够的滚动余量，必须恢复展开 Hero，避免浮在半折叠状态。
    private func restoreExpandedHeroIfNeeded(naturalPanelHeight: CGFloat) {
        guard metadataPanelCollapseProgress > 0 else { return }
        let effectivePanelHeight = effectiveMetadataPanelHeight(naturalHeight: naturalPanelHeight)
        let stableScrollOverflow = Self.expandedScrollOverflow(
            currentOverflow: readmeScrollOverflow,
            panelHeight: effectivePanelHeight,
            collapseProgress: metadataPanelCollapseProgress
        )
        guard !Self.canCollapseHero(
            scrollOverflow: stableScrollOverflow,
            panelHeight: effectivePanelHeight
        ) else { return }
        withAnimation(reduceMotion ? nil : metadataPanelAnimation) {
            metadataPanelCollapseProgress = 0
        }
    }

    /// 屏幕上实际可见的 Hero 展开高度；未完成首次测量时回退自然高度。
    private func effectiveMetadataPanelHeight(naturalHeight: CGFloat) -> CGFloat {
        Self.cappedMetadataPanelHeight(
            naturalHeight: naturalHeight,
            availableHeight: detailViewportHeight,
            minimumBodyHeight: Self.minimumBodyViewportHeight
        ) ?? naturalHeight
    }

    /// 记录父级 viewport 仅供 README 折叠资格计算使用；Hero 实际 frame 在同一布局轮次
    /// 直接读取 GeometryReader 的 proxy，不等待 @State 回写，因此首帧也不会泄漏自然高度。
    private func updateDetailViewportHeight(_ newHeight: CGFloat) {
        guard newHeight > 0,
              abs(newHeight - detailViewportHeight) > 0.5
        else { return }
        detailViewportHeight = newHeight
    }

    /// 把 WebView 当前上报的余量折算回 Hero 展开态，避免折叠动作本身改变 `clientHeight`
    /// 后让可折叠资格在边界 README 上反复翻转。
    static func expandedScrollOverflow(
        currentOverflow: CGFloat?,
        panelHeight: CGFloat,
        collapseProgress: CGFloat
    ) -> CGFloat? {
        guard let currentOverflow, panelHeight > 0 else { return currentOverflow }
        let normalizedProgress = min(max(collapseProgress, 0), 1)
        return currentOverflow + panelHeight * normalizedProgress
    }

    /// 合并新的滚动余量，忽略不会影响视觉的亚像素变化。
    ///
    /// `nil` 表示本轮尚未测到，不应清掉先前的有效值；否则 README loading 或视图切换
    /// 会让 Hero 折叠资格短暂丢失并产生跳动。
    static func resolvedScrollOverflow(
        current: CGFloat?,
        reported: CGFloat?,
        tolerance: CGFloat = RepoDetailScrollReport.geometryTolerance
    ) -> CGFloat? {
        guard let reported else { return current }
        guard let current else { return reported }
        return abs(reported - current) > max(tolerance, 0) ? reported : current
    }

    /// Hero 是否具备稳定折叠资格：余量未知或面板未测高时保守禁止；余量须 ≥ 面板高度。
    static func canCollapseHero(scrollOverflow: CGFloat?, panelHeight: CGFloat) -> Bool {
        guard let scrollOverflow, panelHeight > 0 else { return false }
        return scrollOverflow >= panelHeight
    }

    /// Hero 溢出时为下方 README / Release 正文预留的最小高度。
    ///
    /// 这不是正文的固定高度：Hero 不溢出时仍按自然高度布局，其余空间全部给正文。
    static var minimumBodyViewportHeight: CGFloat { 160 }

    /// 把 Hero 自然高度限制在详情栏可用高度内，同时保留正文的最小视口。
    ///
    /// 返回 nil 表示尺寸尚未完成或窗口小于保护阈值，调用方应暂时沿用现有自然布局，
    /// 不能在首帧把 Hero 压成 0pt。
    static func cappedMetadataPanelHeight(
        naturalHeight: CGFloat,
        availableHeight: CGFloat,
        minimumBodyHeight: CGFloat
    ) -> CGFloat? {
        guard naturalHeight > 0,
              availableHeight > minimumBodyHeight,
              minimumBodyHeight >= 0
        else { return nil }
        return min(naturalHeight, availableHeight - minimumBodyHeight)
    }

    /// 将 scroll offset 映射为顶部元信息面板的折叠进度。
    /// 0...8pt 保留上下文，8...72pt 跟随压缩，72pt+ 完全收起。
    static func metadataCollapseProgress(for offsetY: CGFloat) -> CGFloat {
        let normalizedOffset = max(offsetY, 0)
        let collapseStart: CGFloat = 8
        let collapseDistance: CGFloat = 64
        return min(max((normalizedOffset - collapseStart) / collapseDistance, 0), 1)
    }

    /// Hero 内部滚动视口。始终保留同一个 ScrollView 结构，避免长笔记展开后
    /// 因条件分支重建 `RepoNotesSection`，进而丢失编辑 buffer 或中断 AI 会话。
    private func metadataPanelViewport(availableHeight: CGFloat) -> some View {
        ScrollView(.vertical) {
            metadataPanel
        }
        .defaultScrollAnchor(.top)
        .detailScrollViewStyle()
        .frame(
            height: metadataPanelVisibleHeight(availableHeight: availableHeight),
            alignment: .top
        )
        .clipped()
    }

    /// 折叠期间按同一 progress 缩小外层滚动视口，避免自然高度被 cap 后
    /// 前半段折叠只改变内容、不改变实际占位的视觉迟滞。
    private func metadataPanelVisibleHeight(availableHeight: CGFloat) -> CGFloat? {
        guard let expandedHeight = Self.cappedMetadataPanelHeight(
            naturalHeight: metadataPanelHeight,
            availableHeight: availableHeight,
            minimumBodyHeight: Self.minimumBodyViewportHeight
        ) else { return nil }
        let progress = min(max(metadataPanelCollapseProgress, 0), 1)
        return expandedHeight * (1 - progress)
    }

    /// 顶部信息面板（折叠容器 + Hero 元信息 + heroExtension slot + RepoLocalSections）。
    ///
    /// 渲染顺序（自上而下）：
    /// 1. `RepoMetadataHeaderView` —— Hero 元信息 + ⭐/☆ chip + trailingActions
    /// 2. `heroExtension_()` —— 场景特化扩展（如 Trending Contributors）
    /// 3. `RepoLocalSections(repo:)` —— **v1.5 内置（2026-06-10）**：Tags / Notes /
    ///    Releases 订阅三段。**4 场景同构**,内置消除 4 个 ContentView 重复 + 解决
    ///    「滚动 README 时三段挤压阅读区」bug —— 三段现在跟随面板整段折叠。
    ///    可见性由 RepoLocalSections 内部 `isAuthenticated && repo.id != 0` 守卫
    ///    自动判定（v1.4 决策）,Scaffold 无条件挂载即可。
    ///
    /// 全部内容包在 `CollapsibleRepoMetadataPanel` 里,内部 PreferenceKey 测自然
    /// 高度 → 按 `metadataPanelCollapseProgress` (0...1) 同步衰减 visibleHeight /
    /// opacity / offset,实现「滚动 README 时整段面板折叠让位阅读」体验。
    ///
    /// **调用方 / heroExtension 需自行处理 horizontal padding**——RepoMetadataHeaderView
    /// 与 RepoLocalSections 内部都用 `.padding(.horizontal, 24)`,extension 也应保持
    /// 这个值以视觉对齐。
    @ViewBuilder
    private var metadataPanel: some View {
        CollapsibleRepoMetadataPanel(
            collapseProgress: $metadataPanelCollapseProgress,
            panelHeight: $metadataPanelHeight
        ) {
            VStack(alignment: .leading, spacing: 0) {
                RepoMetadataHeaderView(
                    repo: repo,
                    fallbackAccentColor: fallbackAccentColor,
                    starHelpKey: starHelpKey,
                    headerSourceBadge: viewData.headerSourceBadge,
                    showsRepoHealthEntry: showsRepoHealthEntry,
                    onLanguageTapped: onLanguageTapped,
                    onStarTapped: onStarTapped
                ) {
                    trailingActionsView
                }
                heroExtension_()
                // v1.5（2026-06-10）：RepoLocalSections 内置渲染,跟随面板整段折叠。
                // 可见性 + spring 0.25s star 后展开转场都由组件内部自治,Scaffold 无脑挂。
                RepoLocalSections(repo: repo)
            }
        }
    }

    /// trailingActions 派发渲染（按 RepoDetailAction enum 类型）。
    ///
    /// Wiki 评审约束（2026-06-11）：Weekly Issue 是 Weekly 分组特有入口，必须永远排第一。
    /// 因此先渲染 `.weeklyIssue`，最后渲染 AI / custom。
    /// Share 已迁入 window toolbar：它是当前 repo 的全局操作，不应继续占用 hero
    /// 内容区的主 CTA 位置。Wiki 保留在 hero action 区并排在 AI 前，避免它的
    /// 异步服务商探测结果让 toolbar 重排跳动；这里仍接收 `.share`，但派发时跳过，
    /// 避免四个场景调用方为一个展示位置变化同步改数据模型。
    @ViewBuilder
    private var trailingActionsView: some View {
        HStack(spacing: 8) {
            ForEach(weeklyIssueActions) { action in
                actionButton(for: action)
            }
            if !wikiLinks.isEmpty {
                if dependencies.authSession.state.isAuthenticated {
                    // 已登录：Pro 门控
                    if dependencies.entitlementGate.isProUser {
                        RepoWikiMenu(links: wikiLinks)
                    } else {
                        // 非 Pro：点击 Wiki 图标弹出付费墙
                        Button {
                            proPaywallContext = ProPaywallContext(feature: .externalWiki)
                        } label: {
                            WikiEntryIcon(size: 13)
                                .frame(width: 28, height: 28)
                                .background {
                                    Capsule(style: .continuous)
                                        .fill(WikiAccent.background(colorScheme: colorScheme))
                                }
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .pressableHover()
                        .help(Text("wiki.menu.help"))
                        .accessibilityLabel(Text("wiki.menu.title"))
                        .fixedSize()
                    }
                } else {
                    // 未登录：点击 Wiki 图标弹出登录 sheet
                    Button {
                        dependencies.authSession.requestLoginSheet()
                    } label: {
                        WikiEntryIcon(size: 13)
                            .frame(width: 28, height: 28)
                            .background {
                                Capsule(style: .continuous)
                                    .fill(WikiAccent.background(colorScheme: colorScheme))
                            }
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .pressableHover()
                    .help(Text("wiki.menu.help"))
                    .accessibilityLabel(Text("wiki.menu.title"))
                    .fixedSize()
                }
            }
            // 相似推荐入口（v1.1 从右下角浮动按钮迁到 hero trailing actions）。
            // 位置：Wiki 菜单之后、剩余 actions（.ai 等）之前 —— 即 AI 按钮的左侧。
            // 显示条件：recommendationVM.hasItems（保持旧浮动按钮的「有就显示、没有就不显示」契约）。
            if recommendationVM.hasItems {
                RepoRecommendButton(hasItems: true) {
                    guard dependencies.authSession.state.isAuthenticated else {
                        dependencies.authSession.requestLoginSheet()
                        return
                    }
                    guard dependencies.entitlementGate.isProUser else {
                        proPaywallContext = ProPaywallContext(feature: .repoRecommendations)
                        return
                    }
                    showsRecommendations = true
                }
                .popover(isPresented: $showsRecommendations, arrowEdge: .bottom) {
                    // v1.1 修订：在 popover builder 里用 `StarredRegistry` 一次性把
                    // `RepoRecommendationItem` 转成 `RecommendationCard`（含 isStarred），
                    // popover 内纯渲染不再访问 registry / 不调 `asCardData()`。
                    let cards: [RecommendationCard] = recommendationVM.items.map { item in
                        RecommendationCard(
                            item: item,
                            card: item.asCardData(registry: dependencies.starredRegistry),
                            hit: item.asSemanticSearchHit()
                        )
                    }
                    RepoRecommendationPopover(
                        items: cards,
                        hasMore: recommendationVM.hasMore,
                        isLoading: recommendationVM.isLoading,
                        isLoadingMore: recommendationVM.isLoadingMore,
                        errorMessage: recommendationVM.errorMessage,
                        onOpen: { item in
                            showsRecommendations = false
                            // v1.1 修订：所有点击（单击/Cmd/中键）都走这里。
                            //   - 本地已 star → 走 `RepoDetailWindowController.show` 开新 Starcat 窗
                            //     （与 AI 按钮开 AI 浮窗的体验一致；同 repo 重复点击不重开）
                            //   - 非本地 / 未 star → NSWorkspace 打开 GitHub URL（fallback）
                            // 新窗的好处：detail 不依赖 in-place 导航的 selectedRepo lookup，
                            // 避免「切 selection 期间 selectedRepoID 被清」造成的卡加载体感。
                            Task {
                                if let localRepo = try? await dependencies.repoRepository.findById(item.repoID),
                                   localRepo.isStarred {
                                    RepoDetailWindowController.show(
                                        repo: localRepo,
                                        dependencies: dependencies,
                                        homeViewModel: homeViewModel
                                    )
                                } else if let url = item.githubURL {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        },
                        onLoadMore: {
                            Task {
                                await recommendationVM.loadMore(
                                    service: dependencies.recommendationContextService
                                )
                            }
                        }
                    )
                    .appLocaleEnvironment()
                }
            }
            if canShowLibraryToggle(for: repo) {
                LibraryToggleButton(
                    isSaved: isRepoSavedToLibrary(repo),
                    isWorking: isLibraryOperationInFlight
                ) {
                    Task {
                        await handleLibraryToggleTapped()
                    }
                }
                .gettingStartedAnchor(.addToLibrary)
            }
            ForEach(remainingActions) { action in
                actionButton(for: action)
            }
        }
    }

    private func canShowLibraryToggle(for repo: Repo) -> Bool {
        // 知识库是登录用户的私有状态；未登录时隐藏入口，避免把“点击后登录”
        // 误读成可以匿名写入本地 libraryState。repo.id <= 0 的临时 repo 也不能入库，
        // 因为写入前必须先有稳定 GitHub repo id 作为 repo_notes 主键。
        dependencies.authSession.state.isAuthenticated && repo.id > 0
    }

    private func isRepoSavedToLibrary(_ repo: Repo) -> Bool {
        libraryState == .inLibrary
    }

    /// 只给详情页 ❤️ 按钮读真实入库状态。
    ///
    /// 关键约束：这里**不能**调 `applyLibraryStateChange`。那条入口会失效知识库
    /// listCache，并在当前停在「知识库」分类时整页 `reloadDatabasePagedItems(.reset)`。
    /// 用户只是点开详情查看 README，状态并未写入变化，却会看到中栏列表被刷一次。
    /// 真正入库 / 移出走 `setLibraryState`；其它窗口改状态走 `.repoLibraryStateDidChange`。
    private func loadLibraryState(for repo: Repo) async {
        guard repo.id > 0 else {
            libraryState = .outsideLibrary
            return
        }
        libraryState = (try? await dependencies.repoNoteRepository.fetchLibraryState(repoId: repo.id)) ?? .outsideLibrary
    }

    private func handleLibraryToggleTapped() async {
        guard dependencies.authSession.state.isAuthenticated else {
            dependencies.authSession.requestLoginSheet()
            return
        }
        guard !isLibraryOperationInFlight else { return }
        guard repo.id > 0 else {
            detailToastMessage = "library.action.failed"
            return
        }

        isLibraryOperationInFlight = true
        defer { isLibraryOperationInFlight = false }

        let currentState = (try? await dependencies.repoNoteRepository.fetchLibraryState(repoId: repo.id)) ?? libraryState
        if currentState == .inLibrary {
            // 知识库归属与阅读状态相互独立；用户明确移出时保留当前 status。
            await setLibraryState(.outsideLibrary)
        } else {
            NotificationCenter.default.post(name: .gettingStartedDidAddRepoToLibrary, object: nil)
            await setLibraryState(.inLibrary)
        }
    }

    private func setLibraryState(_ targetState: LibraryState) async {
        guard dependencies.authSession.state.isAuthenticated else {
            dependencies.authSession.requestLoginSheet()
            return
        }
        guard repo.id > 0 else {
            detailToastMessage = "library.action.failed"
            return
        }

        isLibraryOperationInFlight = true
        defer { isLibraryOperationInFlight = false }

        do {
            if targetState == .inLibrary {
                _ = try await dependencies.repoRepository.upsertRepoMetadataForLibrary(repo: repo, syncedAt: Date())
            }
            try await dependencies.repoNoteRepository.updateLibraryState(repoId: repo.id, state: targetState)
            libraryState = targetState
            homeViewModel.applyLibraryStateChange(repoId: repo.id, state: targetState)
            await homeViewModel.refreshSidebar()
            await homeViewModel.reloadItems(forceRefresh: true)
            detailToastMessage = targetState == .inLibrary ? "library.action.added" : "library.action.removed"
            if targetState == .inLibrary {
                NotificationCenter.default.post(name: .gettingStartedDidAddRepoToLibrary, object: nil)
            }
        } catch {
            AppLog.database.error("Toggle library state failed repo=\(repo.fullName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            detailToastMessage = "library.action.failed"
        }
    }

    /// Weekly 特有 action，固定放在 Wiki 之前。
    private var weeklyIssueActions: [RepoDetailAction] {
        viewData.trailingActions.filter { action in
            if case .weeklyIssue = action { return true }
            return false
        }
    }

    /// 除 Weekly Issue 外的通用/场景 action，固定放在 Wiki 之后。
    private var remainingActions: [RepoDetailAction] {
        viewData.trailingActions.filter { action in
            if case .weeklyIssue = action { return false }
            if case .share = action { return false }
            return true
        }
    }

    @ViewBuilder
    private func actionButton(for action: RepoDetailAction) -> some View {
        switch action {
        case .share:
            EmptyView()

        case .ai:
            // AI 主入口已迁到 README 状态栏横条。独立窗口是底部面板内部
            // “在独立窗口中打开”的附属展示形态，Hero 不再提供第二个并列入口。
            EmptyView()

        case .weeklyIssue(let number, let url):
            Link(destination: url) {
                HStack(spacing: 4) {
                    Image(systemName: "newspaper")
                        .font(.system(size: 12, weight: .semibold))
                    Text("# \(number)")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                }
                .foregroundStyle(.purple)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background {
                    Capsule(style: .continuous)
                        .fill(Color.purple.opacity(0.12))
                }
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(Text("weekly.detail.openIssue"))

        case .custom(_, let label, let systemImage, let handler):
            Button {
                handler()
            } label: {
                Label(label, systemImage: systemImage)
                    .font(.body)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pressableHover()
        }
    }

    private func wikiLookupKey(for repo: Repo) -> String {
        "\(repo.owner)/\(repo.name)"
    }

    /// 每次详情 repo 变化先隐藏旧 Wiki 菜单，再从统一 cache-first 服务读取。
    /// stale / miss 只进入有界后台队列，详情页不等待外部 Wiki 网络。
    @MainActor
    private func loadWikiLinks(for repo: Repo) async {
        wikiLinks = []
        guard ProjectPrivacyPolicy.allowsPublicService(for: repo) else {
            wikiRepoKey = nil
            return
        }
        let key = wikiLookupKey(for: repo)
        wikiRepoKey = key
        let links = dependencies.wikiContextService.cacheFirstLinks(
            owner: repo.owner,
            repo: repo.name,
            isPrivate: repo.isPrivate
        )
        guard !Task.isCancelled, wikiRepoKey == key else { return }
        wikiLinks = links
    }

    /// cache miss 的网络补齐完成后原地刷新当前详情；identity 过滤避免旧 repo 的异步事件
    /// 覆盖已经切换的新详情。这里仅读缓存，不会再次入队或发网络请求。
    @MainActor
    private func reloadWikiLinksIfChanged(_ notification: Notification, for repo: Repo) {
        guard notification.userInfo?["owner"] as? String == repo.owner,
              notification.userInfo?["repo"] as? String == repo.name,
              wikiRepoKey == wikiLookupKey(for: repo) else { return }
        wikiLinks = dependencies.wikiContextService.cachedLinks(owner: repo.owner, repo: repo.name)
    }

    /// 设置页清空缓存时同步移除仍在屏幕上的旧链接；只响应清空前确实受影响的仓库。
    @MainActor
    private func reloadWikiLinksIfReset(_ notification: Notification, for repo: Repo) {
        guard let keys = notification.userInfo?["repositoryKeys"] as? [WikiRepoKey],
              keys.contains(WikiRepoKey(owner: repo.owner, repo: repo.name)),
              wikiRepoKey == wikiLookupKey(for: repo) else { return }
        wikiLinks = []
    }
}
