//
//  RepoListView.swift
//  Starcat
//
//  中栏：仓库列表视图。
//
//  职责：
//  - 渲染 HomeViewModel.items，每行调度到 RepoRowView
//  - 响应行选中 → 写入 HomeViewModel.selectedRepo
//  - 空 / 加载 / 错误状态友好展示
//
//  设计约束：
//  - 普通单选用 plain Button 手动写 selectedRepoID，避免系统蓝色选中底色压过自定义样式
//  - 多选模式仍用 SwiftUI List selection binding，保留 Cmd / Shift 原生多选体验
//  - 行密度由 AppSettings 注入，密度切换实时生效（@Observable 通知）
//

import SwiftUI
import AppKit
import Observation

/// 中栏数量行的轻量计数状态。
///
/// Trending / Activity 的列表数据由各自子 ViewModel 发布；如果把计数继续存成
/// `RepoListView.@State`，每次列表发布都会让包含 tint、toolbar、List 与所有 sheet 的
/// 父视图重新计算。独立成引用状态后，只有下面的数量行 modifier 观察它。
@MainActor
@Observable
private final class RepoListNavigationMetrics {
    private(set) var trendingRepoCount = 0
    private(set) var activityItemCount = 0

    func applyTrendingRepoCount(_ count: Int) {
        guard trendingRepoCount != count else { return }
        trendingRepoCount = count
    }

    func applyActivityItemCount(_ count: Int) {
        guard activityItemCount != count else { return }
        activityItemCount = count
    }
}

/// 星标管理列表会话内的 AI 摘要存在状态。
///
/// 这里单独使用 `@Observable` 引用对象，而不是把 `Set<Int64>` 直接放进
/// `RepoListView.@State`：摘要写入时只需要让读取该状态的 Repo 行失效，不能让包含
/// toolbar、sheet 和整棵 List 的页面根视图一起重算。
@MainActor
@Observable
final class RepoListAISummaryAvailability {
    private(set) var repoIDs: Set<Int64> = []
    /// 数据库切换时递增；旧库查询即使忽略 Task cancellation 晚到，也不能污染新账号。
    private var reloadRevision: UInt64 = 0

    func contains(_ repoID: Int64) -> Bool {
        repoIDs.contains(repoID)
    }

    func reload(from repository: any AISummaryRepositoryProtocol) async {
        let requestedRevision = reloadRevision
        do {
            let fetchedRepoIDs = try await repository.fetchRepoIDsWithSummary()
            guard requestedRevision == reloadRevision, !Task.isCancelled else { return }
            // 与实时通知采用并集合并，避免查询返回时覆盖查询期间刚生成的摘要。
            // 每次 Manage 列表重新出现都会执行轻量 DISTINCT 查询，补回列表隐藏期间漏接的通知。
            repoIDs.formUnion(fetchedRepoIDs)
        } catch {
            // 标识缺失不应阻断 Repo 列表；列表下次出现时会自然重试。
            AppLog.database.warning("Repo list AI summary availability load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 账号数据库是硬隔离边界；切库后旧账号的存在性集合必须立即丢弃。
    func resetForDatabaseChange() {
        reloadRevision &+= 1
        repoIDs.removeAll()
    }

    func markAvailable(repoID: Int64) {
        guard !repoIDs.contains(repoID) else { return }
        repoIDs.insert(repoID)
    }
}

/// 只观察导航计数的局部 modifier。
///
/// 数量文案走系统 `navigationSubtitle`，和面包屑共用标题栏左缘，不能改成内容区内边距。
/// 系统 subtitle 只能接 String；探索的 info 按钮用探针贴到这行文字右侧，星标 / 活动附件槽仍空。
///
/// 关键约束：调用方传入 Manage 的静态数量文案，但不读取 `metrics`；Trending / Activity
/// 回写数量时，SwiftUI 只会重算这个 modifier，不会重新求值 `RepoListView.body`。
private struct RepoListNavigationSubtitleModifier: ViewModifier {
    let selectedPage: SidebarRootPage
    let selectedExploreMode: ExploreMode
    let selectedTrendingLanguage: TrendingLanguage
    let selectedDiscoveryLanguage: String?
    let selectedDiscoveryTopic: String?
    let selectedDiscoveryPlatform: String?
    let selectedWeeklyLanguage: String?
    let selectedActivityCategory: ActivityCategory
    let manageSubtitle: String
    let metrics: RepoListNavigationMetrics
    let exploreCatalogStore: ExploreCatalogStore
    let trendingLanguageStore: TrendingLanguageStore
    let weeklyLanguageStore: WeeklyLanguageStore
    let weeklySelectionService: WeeklySelectionService
    let activityCategoryCountService: ActivityCategoryCountService

    @Environment(\.locale) private var locale

    func body(content: Content) -> some View {
        content
            .navigationSubtitle(countText)
            .background {
                if selectedPage == .trending, !countText.isEmpty {
                    TitlebarSubtitleAccessoryAttacher(subtitle: countText) {
                        ExploreModeInfoButton(mode: selectedExploreMode)
                            .id(selectedExploreMode)
                    }
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
                }
            }
    }

    private var countText: String {
        switch selectedPage {
        case .manage:
            return manageSubtitle
        case .trending:
            return exploreRepoCountSubtitle
        case .activity:
            if selectedActivityCategory == .notification {
                return GitHubNotificationMapper.listCountSubtitle(
                    total: activityCategoryCountService.notificationTotalCount ?? 0,
                    unread: activityCategoryCountService.count(for: .notification) ?? 0,
                    locale: locale
                )
            }
            let count = selectedActivityCategory == .undoStar
                ? (activityCategoryCountService.count(for: .undoStar) ?? 0)
                : metrics.activityItemCount
            if selectedActivityCategory.usesRepositoryCountSubtitle {
                return repoCountSubtitle(count)
            }
            return String(
                format: String.l10n("activity.itemCountFormat"),
                count
            )
        case .insights:
            // HomeView 在洞察页直接替换整列，本分支仅用于 enum 穷尽性兜底。
            return ""
        }
    }

    private func repoCountSubtitle(_ count: Int) -> String {
        String(
            format: String.l10n("list.repoCountFormat"),
            count
        )
    }

    private var exploreRepoCountSubtitle: String {
        let presentation = ExploreNavigationPresentation.make(
            mode: selectedExploreMode,
            trendingLanguage: selectedTrendingLanguage,
            discoveryLanguage: selectedDiscoveryLanguage,
            discoveryTopic: selectedDiscoveryTopic,
            discoveryPlatform: selectedDiscoveryPlatform,
            weeklyLanguage: selectedWeeklyLanguage,
            topics: exploreCatalogStore.displayTopics,
            platforms: exploreCatalogStore.displayPlatforms
        )
        let counts = exploreRepoCounts

        guard presentation.isFiltered, let total = counts.total else {
            return repoCountSubtitle(counts.current)
        }
        return String(
            format: String.l10n("list.filteredRepoCountFormat"),
            counts.current,
            total
        )
    }

    /// 分子优先读取与侧栏同源的聚合计数；发现页同时选中 topic + platform 时，
    /// 后端 summary 没有交叉维度，只能使用列表 ViewModel 已发布的真实交集数量。
    private var exploreRepoCounts: (current: Int, total: Int?) {
        switch selectedExploreMode {
        case .discover:
            let total = exploreCatalogStore.total(for: .discover)
            let current: Int
            if selectedDiscoveryTopic != nil, selectedDiscoveryPlatform != nil {
                current = metrics.trendingRepoCount
            } else if let selectedDiscoveryTopic {
                current = exploreCatalogStore.topicCount(for: selectedDiscoveryTopic)
                    ?? metrics.trendingRepoCount
            } else if let selectedDiscoveryPlatform {
                current = exploreCatalogStore.platformCount(for: selectedDiscoveryPlatform)
                    ?? metrics.trendingRepoCount
            } else {
                current = total ?? metrics.trendingRepoCount
            }
            return (current, total)
        case .popular, .newReleases:
            let total = exploreCatalogStore.total(for: selectedExploreMode)
            let current = exploreCatalogStore.languageCount(
                for: selectedDiscoveryLanguage,
                mode: selectedExploreMode
            ) ?? metrics.trendingRepoCount
            return (current, total)
        case .trending:
            let aggregates = trendingLanguageStore.displayList
            let aggregateTotal = aggregates.reduce(0) { $0 + $1.count }
            let total = aggregateTotal > 0 ? aggregateTotal : nil
            let current = selectedTrendingLanguage.rawValue.isEmpty
                ? (total ?? metrics.trendingRepoCount)
                : (aggregates.first { $0.key == selectedTrendingLanguage.rawValue }?.count
                    ?? metrics.trendingRepoCount)
            return (current, total)
        case .weekly:
            let aggregates = weeklyLanguageStore.displayList
            let aggregateTotal = aggregates.reduce(0) { $0 + $1.count }
            let total = weeklySelectionService.total ?? (aggregateTotal > 0 ? aggregateTotal : nil)
            let current = selectedWeeklyLanguage.flatMap { selectedLanguage in
                aggregates.first { $0.key == selectedLanguage }?.count
            } ?? total ?? 0
            return (current, total)
        }
    }
}

/// 把 SwiftUI 附件钉在系统 `navigationSubtitle` 文字右侧。
///
/// 为什么走 AppKit 探针：标题栏数量必须和面包屑共用系统 subtitle 的左缘；
/// SwiftUI 又不能在 `navigationSubtitle(String)` 里放 Button。探针本身零尺寸、
/// 不抢点击；真正可点的是钉到标题栏里的 `NSHostingView`。
///
/// 查：`docs/7-工具与脚本/Swift-学习索引.md` → `NSViewRepresentable`。
private struct TitlebarSubtitleAccessoryAttacher<Accessory: View>: NSViewRepresentable {
    var subtitle: String
    var accessory: Accessory

    init(subtitle: String, @ViewBuilder accessory: () -> Accessory) {
        self.subtitle = subtitle
        self.accessory = accessory()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.subtitle = subtitle
        context.coordinator.accessory = AnyView(
            accessory
                .environment(\.locale, context.environment.locale)
                .environment(\.starcatInterfaceScale, context.environment.starcatInterfaceScale)
                .environment(\.colorScheme, context.environment.colorScheme)
        )
        DispatchQueue.main.async {
            context.coordinator.attach(from: nsView)
            if context.coordinator.hostingView?.superview == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    context.coordinator.attach(from: nsView)
                }
            }
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        var subtitle = ""
        var accessory = AnyView(EmptyView())
        var hostingView: NSHostingView<AnyView>?
        weak var label: NSView?
        var frameObserver: NSObjectProtocol?

        func attach(from probe: NSView) {
            guard let window = probe.window, !subtitle.isEmpty else {
                detach()
                return
            }
            guard let label = Self.findTitlebarLabel(in: window, matching: subtitle) else {
                return
            }
            let hosted = accessory
            if let hostingView {
                hostingView.rootView = hosted
            } else {
                let view = NSHostingView(rootView: hosted)
                view.translatesAutoresizingMaskIntoConstraints = true
                view.autoresizingMask = []
                hostingView = view
            }
            guard let hostingView else { return }
            if hostingView.superview !== label.superview {
                hostingView.removeFromSuperview()
                label.superview?.addSubview(hostingView)
            }
            self.label = label
            observeFrame(of: label)
            reposition()
        }

        func detach() {
            if let frameObserver {
                NotificationCenter.default.removeObserver(frameObserver)
                self.frameObserver = nil
            }
            hostingView?.removeFromSuperview()
            hostingView = nil
            label = nil
        }

        func reposition() {
            guard let label, let hostingView, hostingView.superview != nil else { return }
            let size: CGFloat = 16
            hostingView.frame = NSRect(
                x: label.frame.maxX + 4,
                y: floor(label.frame.midY - size / 2),
                width: size,
                height: size
            )
        }

        private func observeFrame(of label: NSView) {
            if let frameObserver {
                NotificationCenter.default.removeObserver(frameObserver)
            }
            label.postsFrameChangedNotifications = true
            frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: label,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reposition()
                }
            }
        }

        /// 系统面包屑 / subtitle 画在标题栏，不在 contentView 里；从 theme frame 全树搜。
        private static func findTitlebarLabel(in window: NSWindow, matching text: String) -> NSView? {
            let root = window.contentView?.superview ?? window.contentView
            guard let root else { return nil }
            var matches: [NSView] = []
            collectLabels(in: root, matching: text, into: &matches)
            let contentTop = window.contentLayoutRect.maxY
            return matches
                .filter { view in
                    let rect = view.convert(view.bounds, to: nil)
                    return rect.minY >= contentTop - 2
                }
                .max { lhs, rhs in
                    lhs.convert(lhs.bounds, to: nil).minY < rhs.convert(rhs.bounds, to: nil).minY
                }
            ?? matches.first
        }

        private static func collectLabels(in view: NSView, matching text: String, into matches: inout [NSView]) {
            if labelText(of: view) == text {
                matches.append(view)
            }
            for child in view.subviews {
                collectLabels(in: child, matching: text, into: &matches)
            }
        }

        private static func labelText(of view: NSView) -> String? {
            if let field = view as? NSTextField {
                let value = field.stringValue
                if !value.isEmpty { return value }
                let attributed = field.attributedStringValue.string
                if !attributed.isEmpty { return attributed }
            }
            if let label = view.accessibilityLabel(), !label.isEmpty {
                return label
            }
            return nil
        }
    }
}

/// 规则编辑器 Sheet 载荷（`sheet(item:)` 避免首帧空白 sheet）。
private struct SmartCollectionRuleEditorItem: Identifiable {
    let id = UUID()
    let mode: SmartCollectionRuleEditorSheet.Mode
}

/// CodeFlow / CodebaseMemory sheet 每次打开都需要独立 identity。
///
/// macOS `.sheet(item:)` 可能复用旧 presentation host；如果直接用 `Repo` 做 item，
/// Panel 内部的 `@State` ViewModel 会保留上一个 repo 的缓存状态。单独包一层 UUID，
/// 让每次点击入口都强制生成全新的 sheet 内容树。
private struct CodeGraphSheetItem: Identifiable {
    let id = UUID()
    let repo: Repo
}

struct RepoListView: View {

    private static let navigationBreadcrumbSeparator = " › "
    private static let navigationBreadcrumbSegmentLimit = 24

    @Environment(HomeViewModel.self) private var viewModel
    @Environment(AppSettings.self) private var settings
    /// HOM-52：批量 AI 整理入口横幅需要查询队列状态。
    @Environment(AppDependencies.self) private var dependencies
    /// W12 PR-4 followup：trending / weekly toolbar 多选按钮按登录态禁用——
    /// 批量 star/unstar 必须调 GitHub API 携带 token，未登录态点按钮无任何效果，
    /// 直接在源头 disable 比让用户点了报错友好。
    @Environment(AuthSession.self) private var authSession
    @Environment(SyncManager.self) private var syncManager
    /// `RelativeDateTimeFormatter` 须显式注入 locale（对齐 ActivityView）。
    @Environment(\.locale) private var locale
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.openWindow) private var openWindow

    /// HOM-54：TrendingRepository，用于渲染 Trending 页面。
    var trendingRepository: (any TrendingRepositoryProtocol)?
    /// HOM-54：Trending 一键订阅复用 GitHub API 的 star 端点。
    var githubAPIClient: (any GitHubAPIClientProtocol)?

    let selectedPage: SidebarRootPage
    @Binding var selectedExploreMode: ExploreMode
    @Binding var selectedTrendingLanguage: TrendingLanguage
    /// 当前选中的 Trending repo ID（用于卡片高亮和 README 加载）。
    @Binding var selectedTrendingRepoID: String?
    /// 当前选中的 Trending repo 完整数据（用于右侧详情页元信息展示）。
    @Binding var selectedTrendingRepo: TrendingRepo?
    @Binding var selectedDiscoveryLanguage: String?
    @Binding var selectedDiscoveryTopic: String?
    @Binding var selectedDiscoveryPlatform: String?
    @Binding var selectedDiscoveryRepoID: Int64?
    @Binding var selectedDiscoveryRepo: DiscoveryRepoDTO?
    @Binding var selectedWeeklyLanguage: String?
    /// Activity 页当前分类。
    @Binding var selectedActivityCategory: ActivityCategory
    /// Activity 页当前选中项，驱动右侧详情。
    @Binding var selectedActivityItem: ActivityItem?
    /// Getting Started 的 Undo Star 教学跳转后，一次性请求打开第一条记录。
    let undoStarAutoSelectRequestID: Int
    /// HOM-52：Untagged 视图顶部 banner 的"启动整理 / 查看进度"回调。
    /// 这两个动作产生 sheet 由 HomeView 统一承载（避免 RepoListView 多持一个 @State）。
    var onStartBatchAI: (() -> Void)?
    var onShowBatchAIPanel: (() -> Void)?
    /// 全局搜索中心由 HomeView 承载；列表 toolbar 只负责触发，不持有浮层状态。
    var onOpenSearchCenter: (() -> Void)?
    /// 覆盖式知识库 RAG 工作台由 HomeView 承载；列表 toolbar 只暴露入口。
    var onOpenKnowledgeRAGWorkspace: (() -> Void)?
    /// Browser Plugin 的 Open in Starcat 由 HomeView 负责切换根页面和选中详情。
    var onOpenCompanionRepo: ((Repo) -> Void)?
    /// Browser Plugin 的生成摘要动作需要先定位 repo，再打开 AI 窗口并启动生成。
    var onGenerateCompanionSummary: ((Repo) -> Void)?
    /// 洞察数字下钻后的返回入口；临时筛选本身仍由 HomeViewModel 统一管理。
    var onReturnToInsights: (() -> Void)?

    @Environment(\.starcatReduceMotion) private var reduceMotion

    // 中栏自身操作的轻量反馈；仓库链接与 Clone URL 属于当前详情对象，改由右栏
    // RepoDetailScaffold 的共用 Toast 显示，避免提示落在错误列。
    @State private var toastMessage: String?
    @State private var repoPinToastMessage: String?
    /// toolbar spec 会通过 `AnyView` 频繁重建，sheet 必须由稳定的页面根节点承载。
    /// 否则关闭 CodeFlow 时 presentation host 被替换，窗口会短暂再次出现。
    @State private var codeFlowSheetItem: CodeGraphSheetItem?
    @State private var codebaseMemorySheetItem: CodeGraphSheetItem?
    /// 分享入口已迁到 toolbar；进度 Sheet 同样必须由稳定根节点承载，避免 toolbar
    /// 子树重建时 presentation host 被替换。任务状态按 repoID 隔离，切换仓库不会串写结果。
    @State private var shareTaskStore = RepoShareTaskStore()
    @State private var sharePresentation: RepoSharePresentation?
    /// Sheet 收起后任务仍会完成；轻量 toast 明确指出是哪个仓库，避免当前选择造成误解。
    @State private var shareCompletionMessage: String?
    /// CodeFlow 为 Pro 功能；免费用户点入口时弹出统一付费墙，不打开执行面板。
    @State private var paywallContext: ProPaywallContext?
    @State private var ruleEditorSheetItem: SmartCollectionRuleEditorItem?
    /// GitHub 组织可限制第三方 OAuth App 访问仓库节点；这类错误需要结构化解释原因。
    @State private var showGitHubStarListOAuthRestrictionSheet = false
    /// 列表顶栏「同步于」文案；会话内跟 `SyncManager.state`，冷启动读 DB `last_sync_at`。
    @State private var lastSyncedAt: Date?
    /// 列表计数由独立观察对象承载，避免计数发布让整个 RepoListView 根层重算。
    @State private var navigationMetrics = RepoListNavigationMetrics()
    /// 摘要存在状态与导航计数同样局部观察，避免摘要生成后重算整个页面根视图。
    @State private var aiSummaryAvailability = RepoListAISummaryAvailability()
    /// Repo List 窗口会话级事实源。
    ///
    /// Explore / Activity 的 View 会随 `selectedPage` 条件分支创建和销毁；这里只持有
    /// ViewModel 与数据快照，不常驻隐藏的 List，从而兼顾模块回切缓存和稳定布局成本。
    @State private var discoveryViewModel = ExploreDiscoveryViewModel()
    @State private var trendingViewModel: TrendingViewModel?
    @State private var weeklyViewModel: WeeklyContentViewModel?
    @State private var activityViewModel: ActivityViewModel?
    @State private var smartSearchExpandToken = 0
    @State private var toolbarSearchHistory: [SearchHistory] = []
    @State private var showingInterestedLanguagePicker = false
    @State private var interestedLanguageDraft = ""

    var body: some View {
        @Bindable var vm = viewModel

        #if DEBUG
        // ⏱️ 切分类性能诊断：body 重算是性能瓶颈的重灾区，记录每次重算的时机和距 T0 的 elapsed。
        // body 是 computed property，print 会在每次 SwiftUI 决定调用 body 时打一次。
        // 用 .notice 保证 Xcode console 实时可见（.debug / .info 在 macOS 上会被吞）。
        let _ = {
            if selectedPage == .manage {
                AppLog.ui.notice("[switch-cat] RepoListView.body recomputed (items=\(self.viewModel.items.count), itemsRev=\(self.viewModel.itemsRevision), state=\(self.contentStateKey, privacy: .public)) +\(HomeViewModel.msSinceT0, format: .fixed(precision: 1))ms")
            } else {
                // 非 Manage 模块不读取 Manage items/revision，避免调试日志本身建立跨模块观察依赖。
                AppLog.ui.notice("[switch-cat] RepoListView.body recomputed (state=\(self.contentStateKey, privacy: .public)) +\(HomeViewModel.msSinceT0, format: .fixed(precision: 1))ms")
            }
        }()
        #endif

        ZStack(alignment: .top) {
            // 全列底层光晕：必须做 ZStack 底层，不能挂在 contentBody 的 `.background` 上——
            // `safeAreaInset` / List 默认底色会在上层盖住 background 修饰器（2026-06-23 回归）。
            DetailHeroTintBackground(tint: listColumnTintColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                // tint 变化只需要补间背景光晕。动画挂在整列根节点时，同一帧发生的
                // List 数据发布也会继承 0.45s transaction，AppKit 会反复布局 row，
                // 分类切换期间因此连骨架 / Sidebar 动画都会一起掉帧。
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.45),
                    value: listColumnTintColor
                )
                .allowsHitTesting(false)

            listColumnChrome
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .toast(message: $toastMessage, icon: "doc.on.clipboard")
        .toast(message: $repoPinToastMessage, icon: "pin.fill")
        .toast(message: $shareCompletionMessage, icon: "link.circle")
        .sheet(isPresented: $showGitHubStarListOAuthRestrictionSheet) {
            GitHubStarListOAuthRestrictionSheet()
                .appLocaleEnvironment()
        }
        .sheet(item: $sharePresentation) { presentation in
            RepoShareTaskSheet(
                taskStore: shareTaskStore,
                repoID: presentation.repoID,
                onCancel: { shareTaskStore.cancel(repoID: presentation.repoID) },
                onRetry: { retryShare(repoID: presentation.repoID) }
            )
            .id(presentation.repoID)
            .appLocaleEnvironment()
        }
        .sheet(item: $paywallContext) { context in
            ProPaywallSheet.hosted(context: context, dependencies: dependencies)
        }
        .sheet(item: $ruleEditorSheetItem) { item in
            SmartCollectionRuleEditorSheet(
                mode: item.mode,
                onCancel: {
                    ruleEditorSheetItem = nil
                },
                onSaved: {
                    ruleEditorSheetItem = nil
                }
            )
            .appLocaleEnvironment()
        }
        .sheet(item: $codeFlowSheetItem) { item in
            CodeFlowPanel(repo: item.repo)
                .id(item.id)
                .appSheetRootEnvironment(dependencies)
        }
        .sheet(item: $codebaseMemorySheetItem) { item in
            CodebaseMemoryPanel(repo: item.repo)
                .id(item.id)
                .appSheetRootEnvironment(dependencies)
        }
        .onChange(of: shareTaskStore.latestCompletion) { _, completion in
            guard let completion, sharePresentation?.repoID != completion.repoID else { return }
            let key: String
            switch completion.outcome {
            case .success:
                key = "repo.share.notification.successFormat"
            case .failure:
                key = "repo.share.notification.failureFormat"
            }
            shareCompletionMessage = String(format: String.l10n(key), completion.repoFullName)
        }
        .onAppear {
            // Browser Plugin 请求可能先于主窗口恢复到达；窗口重新挂载时需要补消费
            // 已保存的 pendingRequest，否则用户关闭主窗口后点击 Open in Starcat 无响应。
            handleCompanionActionRequest(dependencies.companionActionDispatcher.pendingRequest)
        }
        .onChange(of: dependencies.companionActionDispatcher.pendingRequest) { _, request in
            handleCompanionActionRequest(request)
        }
        // W12 PR-4：切页面时主动 exit 非活跃 store，避免"切到 trending 时 weekly 还显示
        // 底部多选栏"的视觉穿帮。同一时刻只允许一份处于 isActive，由本视图集中保证。
        .onChange(of: selectedPage) { _, newPage in
            exitInactiveMultiSelectStores(for: newPage, activityCategory: selectedActivityCategory)
            // 离开活动页时清理 Undo Star 的外部 repo 引用
            if newPage != .activity {
                viewModel.externalSelectedRepo = nil
            }
        }
        .onChange(of: selectedExploreMode) { _, newMode in
            // 探索模块切换子模式时保留多选开关状态，但清空选中项（不同列表 repo 不同）
            let store = dependencies.exploreMultiSelectionStore
            if store.isActive {
                store.clearSelection()
            }
            if newMode != .weekly {
                dependencies.weeklySelectionService.clearSelection()
            }
        }
        .onChange(of: selectedActivityCategory) { _, newCat in
            // 离开 Undo Star 时清理外部 repo 引用 + 退出多选
            if newCat != .undoStar {
                viewModel.externalSelectedRepo = nil
                let store = dependencies.undoStarMultiSelectionStore
                if store.isActive { store.exit() }
            }
        }
        // PR-4 followup：登录态变化时（典型场景：登出 / token 失效），主动把所有远端 store
        // exit 掉。否则用户从「多选中」直接登出后，store.isActive 仍为 true，底部条会试图
        // 渲染但按钮全 disable，体验割裂。
        .onChange(of: authSession.state.isAuthenticated) { _, isAuthed in
            if !isAuthed {
                exitAllRemoteStores()
            }
        }
        .onChange(of: authSession.state.user?.login) { oldLogin, newLogin in
            guard oldLogin != newLogin else { return }
            resetRepoListModuleSession()
        }
        // W12 PR-5 A2 路线：Manage filter/sort 变化触发 reloadItems → itemsRevision 自增 →
        // 此处调 store.retain(visibleIDs) 清理被隐藏的孤儿选中项（替代原 viewModel.applyView
        // 内的 formIntersection 块）。view 层主导 store 生命周期，避免 viewModel 持 store 引用。
        .onChange(of: viewModel.selection) { _, newSelection in
            // 切到智能集合 / 订阅发布等非列表分组时，退出多选
            let store = dependencies.manageMultiSelectionStore
            guard store.isActive else { return }
            switch newSelection {
            case .smartCollectionsHome, .smartCollection:
                store.exit()
            default:
                break
            }
        }
        .onChange(of: viewModel.itemsRevision) { _, _ in
            let store = dependencies.manageMultiSelectionStore
            guard store.isActive else { return }
            Task {
                let snapshots = await viewModel.selectionSnapshotsForCurrentQuery()
                let visibleIDs = Set(snapshots.map(\.ghRepoId))
                store.retain(visibleIDs: visibleIDs)
            }
        }
        // W12 PR-5：Cmd+A 全选 — 4 场景统一注入一个隐藏按钮承载快捷键。
        // 仅当**当前 page 对应的 store** 处于多选模式时生效（disabled 否则）。Shift 区间选不补。
        .background {
            ZStack {
                selectAllShortcutButton
                smartSearchShortcutButton
            }
        }
    }

    /// W12 PR-5：Manage 的 Cmd+A 全选隐藏按钮。
    ///
    /// 实现细节：
    /// - 用 `Button { ... }.keyboardShortcut("a", modifiers: .command).hidden()` 是 SwiftUI 注册
    ///   全局键盘快捷键的常规手法（隐藏按钮不占布局，但快捷键由 SwiftUI 路由系统接管）；
    /// - 仅在 manage store 处于 active 时启用，否则 `.disabled(true)` 让 Cmd+A 不抢系统默认行为；
    /// - selectAll 的入参由 view 自己从 viewModel.filteredSorted 构造 SelectionSnapshot
    ///   （Repo.id == ghRepoId）。**R-07 修订**：从 `items` 改用 `filteredSorted` ——
    ///   原 `items` 是当前页切片（≤ 20 条），Cmd+A 只能"全选可见页"反直觉；用户口径
    ///   下 "Cmd+A 全选" 应该是"过滤后的全集"，与 R-07 之前 `items = 全集` 时的行为
    ///   语义对齐。
    /// - Trending / Weekly / Activity 的 Cmd+A 由各自的 view 在本 PR 同步注入（行为 4 场景统一）。
    ///   它们的 visible items 不暴露到 RepoListView 这一层，避免本视图反向依赖子 ViewModel。
    @ViewBuilder
    private var selectAllShortcutButton: some View {
        let store = dependencies.manageMultiSelectionStore
        Button {
            Task {
                let snapshots = await viewModel.selectionSnapshotsForCurrentQuery()
                store.selectAll(snapshots)
            }
        } label: {
            EmptyView()
        }
        .keyboardShortcut("a", modifiers: .command)
        .disabled(!store.isActive || selectedPage != .manage)
        .hidden()
    }

    /// 常规搜索（列表 toolbar SmartSearchField）快捷键。默认 Command+F，仅 Manage 页生效。
    private var smartSearchShortcutButton: some View {
        Button {
            viewModel.smartSearchMode = .keyword
            smartSearchExpandToken += 1
        } label: {
            EmptyView()
        }
        .keyboardShortcut(
            settings.keyboardShortcutsEnabled && settings.regularSearchShortcutEnabled
                ? settings.regularSearchShortcut.swiftUIShortcut
                : nil
        )
        .disabled(selectedPage != .manage)
        .hidden()
    }

    /// 中栏前景层：navigation / inset / toolbar / 列表内容（叠在 `DetailHeroTintBackground` 上）。
    @ViewBuilder
    private var listColumnChrome: some View {
        // 非 Manage 页面不能求值 `manageNavigationSubtitle`，否则会把 HomeViewModel 的
        // items / collection 计数重新带入 Explore 与 Activity 的观察图。
        let manageSubtitle = selectedPage == .manage ? manageNavigationSubtitle : ""
        contentBody
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(.clear)
            .modifier(RepoListNavigationSubtitleModifier(
                selectedPage: selectedPage,
                selectedExploreMode: selectedExploreMode,
                selectedTrendingLanguage: selectedTrendingLanguage,
                selectedDiscoveryLanguage: selectedDiscoveryLanguage,
                selectedDiscoveryTopic: selectedDiscoveryTopic,
                selectedDiscoveryPlatform: selectedDiscoveryPlatform,
                selectedWeeklyLanguage: selectedWeeklyLanguage,
                selectedActivityCategory: selectedActivityCategory,
                manageSubtitle: manageSubtitle,
                metrics: navigationMetrics,
                exploreCatalogStore: dependencies.exploreCatalogStore,
                trendingLanguageStore: dependencies.trendingLanguageStore,
                weeklyLanguageStore: dependencies.weeklyLanguageStore,
                weeklySelectionService: dependencies.weeklySelectionService,
                activityCategoryCountService: dependencies.activityCategoryCountService
            ))
            .navigationTitle(navigationTitle)
            // W4 A5：多选模式底部浮动操作栏；W12 PR-4 扩展到 trending/weekly/activity；
            // W12 PR-5：统一 BatchActionBar(context:)，星标 / 探索共用同一组件。
            .safeAreaInset(edge: .bottom, spacing: 0) {
                currentBatchActionBar
            }
            .toolbar {
                // 智能集合详情的返回入口属于当前导航上下文，固定放在全局状态左侧，
                // 避免混入页面筛选操作后随不同 toolbar spec 改变位置。
                if viewModel.selection.isSmartCollectionDetailContext, viewModel.selectedRepo != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            viewModel.selectedRepoID = nil
                        } label: {
                            ToolbarIcon("chevron.left.circle")
                                .accessibilityLabel(Text("smartCollections.panel.backToCollection"))
                        }
                        .help("smartCollections.panel.backToCollection")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    AppStatusToolbarButton(
                        lastSyncedAt: lastSyncedAt,
                        onShowBatchAIPanel: onShowBatchAIPanel
                    )
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        onOpenKnowledgeRAGWorkspace?()
                    } label: {
                        workspaceToolbarIcon("r.circle", tint: Color(nsColor: .systemTeal))
                            .accessibilityLabel(Text("toolbar.knowledgeRAGWorkspace.label"))
                    }
                    .help(Text(verbatim: knowledgeRAGWorkspaceHelp))
                    .gettingStartedAnchor(.ragWorkspace)
                }
                let spec = currentToolbarSpec
                if let leading = spec.leadingPrimary {
                    ToolbarItemGroup(placement: .primaryAction) {
                        leading
                    }
                }
                if let trailing = spec.trailingPrimary {
                    ToolbarItemGroup(placement: .primaryAction) {
                        trailing
                    }
                }
                if let search = spec.searchField {
                    ToolbarItem(placement: .primaryAction) {
                        search
                    }
                }
            }
    }

    private var knowledgeRAGWorkspaceHelp: String {
        guard settings.keyboardShortcutsEnabled, settings.knowledgeRAGShortcutEnabled else {
            return String.l10n("toolbar.knowledgeRAGWorkspace.help.shortcutDisabled")
        }
        return String(
            format: String.l10n("toolbar.knowledgeRAGWorkspace.help"),
            settings.knowledgeRAGShortcut.displayText
        )
    }

    private func workspaceToolbarIcon(_ systemName: String, tint: Color) -> some View {
        ToolbarIcon(systemName)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            // AI workspace 需要比常规灰色 toolbar 图标更容易被发现；
            // 使用系统动态色而不是固定 RGB，确保明暗主题下都有足够辨识度。
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
    }

    /// 把三个远端 store 全部 exit。登出 / token 失效场景调用。
    /// Manage 库内 100% 已 star，登出会触发会话清空但不主动 exit manage store（manage 多选不依赖
    /// GitHub API token，本地操作如打标签仍可执行；如果用户登出后打 unstar 会被 StarActionService 拦）。
    private func exitAllRemoteStores() {
        let explore = dependencies.exploreMultiSelectionStore
        if explore.isActive { explore.exit() }
    }

    /// 把"非当前 page+分类"对应的多选 store 全部 exit。
    private func exitInactiveMultiSelectStores(for page: SidebarRootPage, activityCategory: ActivityCategory) {
        let manage = dependencies.manageMultiSelectionStore
        let explore = dependencies.exploreMultiSelectionStore

        switch page {
        case .manage:
            if explore.isActive { explore.exit() }
        case .trending:
            if manage.isActive { manage.exit() }
        case .activity:
            if manage.isActive { manage.exit() }
            if explore.isActive { explore.exit() }
        case .insights:
            if manage.isActive { manage.exit() }
            if explore.isActive { explore.exit() }
        }
    }

    // MARK: - 中栏顶部 accent 光晕（与 Sidebar / 详情列联动）

    /// 中栏 tint 取色优先级与 `SidebarHeaderView.sidebarTintColor` 对齐。
    ///
    /// Explore weekly 走 `WeeklySelectionService` 真源。
    private var listColumnTintColor: Color {
        if selectedPage == .trending, selectedExploreMode == .weekly,
           let project = dependencies.weeklySelectionService.selectedItem {
            return DetailHeroTintBackground.accentColor(
                language: project.language,
                fallback: WeeklyVisualStyle.accentColor
            )
        }
        if let language = viewModel.selectedRepo?.language, !language.isEmpty {
            return LanguageColor.color(for: language)
        }
        if let language = selectedTrendingRepo?.language, !language.isEmpty {
            return LanguageColor.color(for: language)
        }
        if let language = selectedDiscoveryRepo?.language, !language.isEmpty {
            return LanguageColor.color(for: language)
        }
        if let item = selectedActivityItem {
            return item.accentColor
        }
        return .accentColor
    }

    // MARK: - Toolbar spec 派发

    /// 按 `selectedPage` 派发当前 toolbar 内容。
    ///
    /// 设计参见 `PageToolbarSpec` 文件头：
    /// - Manage 走完整 spec，并显示本地关键词 / 语义搜索入口；
    /// - Trending / Activity 隐藏本地搜索入口，只保留主窗口级 `⌘K` 全局搜索。
    ///   这样避免用户在非 Manage 页面看到一个 disabled 搜索框，却误以为当前页支持
    ///   本地 FTS5 / 向量搜索。
    /// W12 PR-4：统一的批量操作底栏，星标 / 探索模块共用 BatchActionBar。
    @ViewBuilder
    private var currentBatchActionBar: some View {
        switch selectedPage {
        case .manage:
            let store = dependencies.manageMultiSelectionStore
            if store.isActive {
                BatchActionBar(context: .manage, store: store)
            }
        case .trending:
            let store = exploreMultiSelectionStore
            if store.isActive {
                BatchActionBar(context: .explore, store: store)
            }
        case .activity:
            if selectedActivityCategory == .undoStar {
                let store = dependencies.undoStarMultiSelectionStore
                if store.isActive {
                    BatchActionBar(context: .explore, store: store)
                }
            } else {
                EmptyView()
            }
        case .insights:
            EmptyView()
        }
    }

    /// 探索模块全局多选 store（5 个子模式共享同一实例）。
    private var exploreMultiSelectionStore: MultiSelectionStore {
        dependencies.exploreMultiSelectionStore
    }

    private var currentToolbarSpec: PageToolbarSpec {
        switch selectedPage {
        case .manage:    return makeManageToolbarSpec()
        case .trending:
            if selectedExploreMode == .trending {
                return makeTrendingToolbarSpec()
            }
            if selectedExploreMode == .weekly {
                return makeWeeklyToolbarSpec()
            }
            return makeDiscoveryToolbarSpec()
        case .activity:  return makeActivityToolbarSpec()
        case .insights:  return .empty
        }
    }

    /// Trending 页面 toolbar spec（W12 PR-4）：
    /// - leading 暂无（period picker 仍在中栏自绘 toolbar，period 是数据切片维度而非排序）；
    /// - trailing 注入：[wiki / external / clone / share] +「多选按钮」。
    ///   wiki / external / clone 派发 `selectedTrendingRepo` 单选项；多选按钮驱动
    ///   `trendingMultiSelectionStore`，由 `TrendingView` 的行点击 toggle 选中状态。
    /// - PR-4 followup：未登录态多选按钮 disable。批量 star/unstar 都需要 token，
    ///   未登录直接 disable 比让用户点了再弹错误友好；如果 store 已经处于 active
    ///   （比如登录后切到 trending 又登出），同帧把 store exit 兜底清掉 stale selection。
    @MainActor
    private func makeTrendingToolbarSpec() -> PageToolbarSpec {
        let store = dependencies.trendingMultiSelectionStore
        let registry = dependencies.starredRegistry
        let isAuthed = authSession.state.isAuthenticated

        let trailing: AnyView = {
            let selectionView: AnyView? = selectedTrendingRepo.map { repo in
                let isStarred = registry.contains(ghRepoId: repo.ghRepoId)
                let sel = ToolbarRepoSelection.from(
                    trending: repo,
                    isStarred: isStarred
                )
                // Trending 未 star 的仓库没有本地 Repo，复用详情页现有 ephemeral 转换，
                // 仅作为 CodeFlow 下载参数使用，不写入数据库。
                let actionRepo = repo.makeEphemeralRepo()
                return AnyView(
                    Group {
                        selectedRepoToolbarActions(
                            selection: sel,
                            codeFlowRepo: actionRepo.isPrivate ? nil : actionRepo,
                            shareRepo: actionRepo,
                            isShareAvailable: isStarred
                        )
                    }
                )
            }
            return AnyView(
                Group {
                    selectionView
                    MultiSelectButton(
                        isActive: store.isActive,
                        action: { store.toggle() },
                        isDisabled: !isAuthed
                    )
                }
            )
        }()

        return PageToolbarSpec(
            leadingPrimary: AnyView(globalFilterMenu()),
            trailingPrimary: trailing,
            searchField: AnyView(smartSearchField())
        )
    }

    /// Explore 的 Discovery 子模块 toolbar spec。
    ///
    /// 2026-07-05：发现 / 热门 / 新发布 已接入统一多选，支持全部 6 种批量操作。
    @MainActor
    private func makeDiscoveryToolbarSpec() -> PageToolbarSpec {
        let store = exploreMultiSelectionStore
        let registry = dependencies.starredRegistry
        let isAuthed = authSession.state.isAuthenticated

        let trailing: AnyView? = {
            let selectionView: AnyView? = selectedDiscoveryRepo.map { repo in
                let isStarred = registry.contains(ghRepoId: repo.repoID)
                let actionRepo = repo.toEphemeralRepo(isStarred: isStarred)
                let selection = ToolbarRepoSelection.from(
                    repo: actionRepo,
                    isStarred: isStarred
                )
                return AnyView(
                    selectedRepoToolbarActions(
                        selection: selection,
                        codeFlowRepo: actionRepo.isPrivate ? nil : actionRepo,
                        shareRepo: actionRepo,
                        isShareAvailable: isStarred
                    )
                )
            }
            return AnyView(
                Group {
                    selectionView
                    MultiSelectButton(
                        isActive: store.isActive,
                        action: { store.toggle() },
                        isDisabled: !isAuthed
                    )
                }
            )
        }()

        return PageToolbarSpec(
            leadingPrimary: AnyView(globalFilterMenu()),
            trailingPrimary: trailing,
            searchField: AnyView(smartSearchField())
        )
    }

    /// Explore Weekly toolbar spec：
    /// - 单选动作来自 `WeeklySelectionService.selectedItem`;
    /// - 多选按钮驱动 `weeklyMultiSelectionStore`,与 `WeeklyContentView` 行点击逻辑同源。
    @MainActor
    private func makeWeeklyToolbarSpec() -> PageToolbarSpec {
        let store = dependencies.weeklyMultiSelectionStore
        let registry = dependencies.starredRegistry
        let isAuthed = authSession.state.isAuthenticated

        let selectionView: AnyView? = {
            guard let item = dependencies.weeklySelectionService.selectedItem else { return nil }
            let isStarred = registry.contains(ghRepoId: item.ghRepoId)
            let sel = ToolbarRepoSelection.from(
                weekly: item,
                isStarred: isStarred
            )
            // Weekly card 已包含生成临时 Repo 所需的 GitHub 元数据。不可访问的历史
            // 项目不展示 CodeFlow，避免用户进入后必然得到 zipball 404。
            let actionRepo = item.card.toEphemeralRepo()
            return AnyView(
                Group {
                    selectedRepoToolbarActions(
                        selection: sel,
                        codeFlowRepo: item.isAvailable && !actionRepo.isPrivate ? actionRepo : nil,
                        shareRepo: actionRepo,
                        isShareAvailable: isStarred
                    )
                }
            )
        }()

        let trailing = AnyView(
            Group {
                selectionView
                if CuratedPublisherAccessPolicy.canAccess(userID: authSession.state.user?.id) {
                    Button {
                        openWindow(id: CuratedPublisherWindow.id)
                    } label: {
                        ToolbarIcon("star.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Color(nsColor: .systemRed))
                            .accessibilityLabel(Text("curatedPublisher.toolbar.open"))
                    }
                    .help("curatedPublisher.toolbar.open")
                }
                MultiSelectButton(
                    isActive: store.isActive,
                    action: { store.toggle() },
                    isDisabled: !isAuthed
                )
            }
        )

        return PageToolbarSpec(
            leadingPrimary: AnyView(globalFilterMenu()),
            trailingPrimary: trailing,
            searchField: AnyView(smartSearchField())
        )
    }

    /// Activity 页面 toolbar spec。Undo Star 分类支持多选。
    @MainActor
    private func makeActivityToolbarSpec() -> PageToolbarSpec {
        if selectedActivityCategory == .notification {
            // 通知详情不是仓库页：过滤 / 打开网页 / clone / 分享都不适用。
            return PageToolbarSpec(
                leadingPrimary: nil,
                trailingPrimary: nil,
                searchField: AnyView(smartSearchField())
            )
        }
        let registry = dependencies.starredRegistry
        let isAuthed = authSession.state.isAuthenticated

        let selectionView: AnyView? = {
            guard let repo = selectedActivityItem?.repo else { return nil }
            let isStarred = repo.isStarred || registry.contains(ghRepoId: repo.id)
            let sel = ToolbarRepoSelection.from(
                repo: repo,
                isStarred: isStarred
            )
            return AnyView(
                Group {
                    selectedRepoToolbarActions(
                        selection: sel,
                        codeFlowRepo: repo.isPrivate ? nil : repo,
                        shareRepo: repo,
                        isShareAvailable: isStarred
                    )
                }
            )
        }()

        let trailing = AnyView(
            Group {
                selectionView
                if selectedActivityCategory == .undoStar {
                    let store = dependencies.undoStarMultiSelectionStore
                    MultiSelectButton(
                        isActive: store.isActive,
                        action: { store.toggle() },
                        isDisabled: !isAuthed
                    )
                }
            }
        )

        return PageToolbarSpec(
            leadingPrimary: AnyView(globalFilterMenu()),
            trailingPrimary: trailing,
            searchField: AnyView(smartSearchField())
        )
    }

    /// Manage 页面 toolbar：filter / multiSelect / external / clone / search。
    /// 排序与 Stars 同步已迁到列表顶栏 `manageFilterBar`（对齐 Weekly / Activity）。
    @MainActor
    private func makeManageToolbarSpec() -> PageToolbarSpec {
        let leading = AnyView(
            Group {
                Button {
                    openSmartCollectionEditor()
                } label: {
                    ToolbarIcon("gearshape.circle")
                }
                .disabled(!canOpenSmartCollectionEditor)
                .help("smartCollections.editor.help")

                globalFilterMenu(includesStatusFilter: true)

                // W12 PR-5：Manage 多选按钮直接驱动 manageMultiSelectionStore（替代原
                // viewModel.toggleMultiSelectMode），与 trending/weekly/activity 同款机制。
                // Manage 已登录是隐含前提（库内 100% 已 star），不传 isDisabled。
                MultiSelectButton(
                    isActive: dependencies.manageMultiSelectionStore.isActive,
                    action: { dependencies.manageMultiSelectionStore.toggle() }
                )
            }
        )

        let trailing: AnyView? = {
            guard let repo = viewModel.selectedRepo else { return nil }
            let isStarred = repo.isStarred || dependencies.starredRegistry.contains(ghRepoId: repo.id)
            let selection = ToolbarRepoSelection.from(
                repo: repo,
                isStarred: isStarred
            )
            return AnyView(
                Group {
                    selectedRepoToolbarActions(
                        selection: selection,
                        codeFlowRepo: repo.isPrivate ? nil : repo,
                        shareRepo: repo,
                        isShareAvailable: isStarred
                    )
                }
            )
        }()

        return PageToolbarSpec(
            leadingPrimary: leading,
            trailingPrimary: trailing,
            searchField: AnyView(smartSearchField())
        )
    }

    @MainActor
    private func globalFilterMenu(includesStatusFilter: Bool = false) -> some View {
        let effectiveFilters = viewModel.effectiveGlobalFilterState

        return UnifiedFilterMenu(
            isAnyFilterActive: viewModel.hasActiveFilter,
            accessibilityLabel: includesStatusFilter && effectiveFilters.statusFilter != nil
                ? LocalizedStringKey(effectiveFilters.statusFilter?.localizedDisplayName ?? "list.filter.status")
                : "list.filter.status",
            onReset: { viewModel.resetAllFilters() }
        ) {
            globalFilterMenuContent(includesStatusFilter: includesStatusFilter)
        }
        // SVG 解析与 NSImage 缩放必须发生在用户点击之前；缓存有界且只随语言池变化预热。
        .onAppear {
            FilterMenuLanguageIconCache.prewarm(settings.interestedLanguages, size: 14)
        }
        .onChange(of: settings.interestedLanguages) { _, languages in
            FilterMenuLanguageIconCache.prewarm(languages, size: 14)
        }
        .onChange(of: viewModel.hideArchived) { _, newValue in
            settings.hideArchived = newValue
        }
        .onChange(of: viewModel.hideForks) { _, newValue in
            settings.hideForks = newValue
        }
        .onChange(of: viewModel.statusFilter) { _, newValue in
            settings.statusFilter = newValue
        }
        .onChange(of: viewModel.starFilter) { _, newValue in
            settings.starFilter = newValue
        }
        .onChange(of: viewModel.libraryFilter) { _, newValue in
            settings.libraryFilter = newValue
        }
        .onChange(of: viewModel.repoLanguageFilter) { _, newValue in
            settings.repoLanguageFilter = newValue
        }
        .onChange(of: viewModel.globalFilterLanguages) { _, newValue in
            settings.globalFilterLanguages = AppSettings.normalizedLanguageList(newValue)
        }
        .onChange(of: viewModel.wikiAvailabilityFilter) { _, newValue in
            settings.wikiAvailabilityFilter = newValue
        }
        .onChange(of: viewModel.healthAvailabilityFilter) { _, newValue in
            settings.healthAvailabilityFilter = newValue
        }
        .onChange(of: viewModel.openSSFAvailabilityFilter) { _, newValue in
            settings.openSSFAvailabilityFilter = newValue
        }
    }

    /// 固定结构直接交给 SwiftUI 的泛型 ViewBuilder，避免每次打开 popover 都从
    /// `[FilterMenuItem] + AnyView` 恢复整棵筛选树。Manage 只额外插入状态筛选。
    @ViewBuilder
    private func globalFilterMenuContent(includesStatusFilter: Bool) -> some View {
        if viewModel.selection == .myProjects {
            projectFilterSection()
            Divider()
        }

        starFilterSection(selection: globalFilterBinding(\.starFilter))
        Divider()

        if includesStatusFilter {
            statusFilterSection(selection: globalFilterBinding(\.statusFilter))
            Divider()
        }

        libraryFilterSection(selection: globalFilterBinding(\.libraryFilter))
        Divider()
        languageFilterSection()
        Divider()
        availabilityPicker(
            title: "list.filter.wikiAvailability",
            icon: "doc.text.magnifyingglass",
            selection: globalFilterBinding(\.wikiAvailabilityFilter)
        )
        availabilityPicker(
            title: "list.filter.healthAvailability",
            icon: "heart.text.square",
            selection: globalFilterBinding(\.healthAvailabilityFilter)
        )
        availabilityPicker(
            title: "list.filter.openSSFAvailability",
            icon: "checkmark.shield",
            selection: globalFilterBinding(\.openSSFAvailabilityFilter)
        )
        Divider()
        Toggle(isOn: globalFilterBinding(\.hideArchived)) {
            Label("settings.general.hideArchived", systemImage: "archivebox")
        }
        Toggle(isOn: globalFilterBinding(\.hideForks)) {
            Label("settings.general.hideForks", systemImage: "tuningfork")
        }
        if viewModel.selection == .myProjects {
            Toggle(isOn: onlyPrivateProjectsBinding) {
                Label("list.filter.project.onlyPrivate", systemImage: "lock.fill")
            }
        }
    }

    /// 项目关系维度只在“我的项目”出现，绑定 HomeViewModel 的会话内筛选状态。
    ///
    /// 布局取舍：不用默认 `.menu` Picker 的「标签+按钮贴在一起」单行（中文标签长短不一会
    /// 导致下拉错落），改成左标签 / 右对齐菜单的表单行，和设置页数值行同一视觉节奏。
    @ViewBuilder
    private func projectFilterSection() -> some View {
        @Bindable var vm = viewModel

        VStack(alignment: .leading, spacing: 8) {
            filterSectionHeader(
                title: "sidebar.myProjects",
                icon: SidebarItem.myProjects.systemImage
            )

            projectFilterMenuRow(title: "list.filter.project.affiliation") {
                Picker(selection: $vm.projectAffiliationFilter) {
                    Text("general.all").tag(nil as ProjectAffiliation?)
                    Text("list.filter.project.personal").tag(ProjectAffiliation.owner as ProjectAffiliation?)
                    Text("list.filter.project.organization").tag(
                        ProjectAffiliation.organizationMember as ProjectAffiliation?
                    )
                    Text("list.filter.project.collaborator").tag(
                        ProjectAffiliation.collaborator as ProjectAffiliation?
                    )
                } label: {
                    EmptyView()
                }
            }

            if !viewModel.projectFilterOptions.organizationLogins.isEmpty {
                projectFilterMenuRow(title: "list.filter.project.organizationName") {
                    Picker(selection: $vm.projectOrganizationFilter) {
                        Text("general.all").tag(nil as String?)
                        ForEach(viewModel.projectFilterOptions.organizationLogins, id: \.self) { login in
                            Text(verbatim: login).tag(login as String?)
                        }
                    } label: {
                        EmptyView()
                    }
                }
            }

            projectFilterMenuRow(title: "list.filter.project.visibility") {
                Picker(selection: $vm.projectVisibilityFilter) {
                    Text("general.all").tag(nil as ProjectVisibility?)
                    // 始终提供 Public / Private / Internal，不依赖当前库内已出现的可见性枚举；
                    // 否则授权前只有公开项目时，用户无法预先选「只看私有」。
                    ForEach(ProjectVisibility.allCases, id: \.self) { visibility in
                        Text(projectVisibilityLabel(visibility)).tag(visibility as ProjectVisibility?)
                    }
                } label: {
                    EmptyView()
                }
            }

            projectFilterMenuRow(title: "list.filter.project.permission") {
                Picker(selection: $vm.projectPermissionFilter) {
                    Text("general.all").tag(nil as ProjectPermission?)
                    ForEach(viewModel.projectFilterOptions.permissions, id: \.self) { permission in
                        Text(projectPermissionLabel(permission)).tag(permission as ProjectPermission?)
                    }
                } label: {
                    EmptyView()
                }
            }
        }
    }

    /// 左标签、右菜单：标签列与菜单列都固定宽度，选中长组织名时也不把某一行撑宽。
    ///
    /// 宽度按筛选浮层 260pt 内容区估算：标签「具体组织」≈72，剩余给菜单约 148。
    private static let projectFilterLabelWidth: CGFloat = 72
    private static let projectFilterMenuWidth: CGFloat = 148

    @ViewBuilder
    private func projectFilterMenuRow<Content: View>(
        title: LocalizedStringKey,
        @ViewBuilder picker: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: Self.projectFilterLabelWidth, alignment: .leading)

            picker()
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: Self.projectFilterMenuWidth, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func projectVisibilityLabel(_ visibility: ProjectVisibility) -> LocalizedStringKey {
        switch visibility {
        case .public: return "list.filter.project.visibility.public"
        case .private: return "list.filter.project.visibility.private"
        case .internal: return "list.filter.project.visibility.internal"
        }
    }

    private func projectPermissionLabel(_ permission: ProjectPermission) -> LocalizedStringKey {
        switch permission {
        case .admin: return "list.filter.project.permission.admin"
        case .maintain: return "list.filter.project.permission.maintain"
        case .push: return "list.filter.project.permission.push"
        case .triage: return "list.filter.project.permission.triage"
        case .pull: return "list.filter.project.permission.pull"
        case .unknown: return "list.filter.project.permission.unknown"
        }
    }

    private var canOpenSmartCollectionEditor: Bool {
        if case .userSmartCollection(let id) = viewModel.selection {
            return viewModel.userSmartCollection(id: id) != nil
        }
        switch viewModel.selection {
        case .allStars, .allLanguages, .untagged, .language, .tag:
            return true
        case .myProjects, .library, .trending, .smartCollectionsHome, .smartCollection,
             .githubStarList, .githubStarListUngrouped:
            return false
        case .userSmartCollection:
            return false
        }
    }

    /// 当前选中 repo 的 toolbar 操作组。
    ///
    /// Share 已从详情 hero 迁到 toolbar。公开仓库始终可复制基础 HTTPS 链接；只有
    /// AI 分享增强项继续要求登录且仓库已 Star。私有仓库不生成可被服务端抓取的链接。
    /// Trending / Weekly 的临时 Repo 自身 `isStarred` 恒为 false，所以调用方仍用
    /// `StarredRegistry` 派生 `isShareAvailable` 作为 AI 分享可用性。
    @ViewBuilder
    private func selectedRepoToolbarActions(
        selection: ToolbarRepoSelection,
        codeFlowRepo: Repo?,
        shareRepo: Repo,
        isShareAvailable: Bool
    ) -> some View {
        let actionIdentity = toolbarActionIdentity(selection: selection, repo: codeFlowRepo)
        ExternalLinksMenu(
            selection: selection,
            codeFlowRepo: codeFlowRepo,
            codebaseMemoryRepo: codeFlowRepo,
            onOpenCodeFlow: openCodeFlow(for:),
            onOpenCodebaseMemory: openCodebaseMemory(for:)
        )
        .id(actionIdentity)
        CloneMenu(selection: selection) { toastKey in
            RepoDetailToastRequest.post(repoID: shareRepo.id, messageKey: toastKey)
        }
        if !shareRepo.isPrivate,
           let deepLink = RepositoryDeepLink(fullName: shareRepo.fullName, repositoryID: shareRepo.id) {
            let canCreateAIShare = authSession.state.isAuthenticated && isShareAvailable
            let targetRepo = toolbarShareRepo(shareRepo, isStarred: canCreateAIShare)
            RepoShareMenu(
                publicURL: deepLink.publicURL,
                isSharing: shareTaskStore.isRunning(repoID: targetRepo.id),
                isShared: shareTaskStore.isSuccessful(repoID: targetRepo.id),
                canCreateAIShare: canCreateAIShare,
                createAIShare: {
                    presentOrStartShare(targetRepo)
                },
                onLinkCopied: {
                    RepoDetailToastRequest.post(
                        repoID: shareRepo.id,
                        messageKey: "repo.share.link.copied"
                    )
                }
            )
        }
    }

    /// Toolbar 菜单由 AppKit 承载，SwiftUI 切换选中 repo 时可能复用旧 NSMenu action。
    /// identity 必须包含当前 repo 快照，确保从 A 切到 B 后菜单闭包随选中项一起重建。
    private func toolbarActionIdentity(selection: ToolbarRepoSelection, repo: Repo?) -> String {
        let repoIdentity = repo.map { "\($0.id):\($0.fullName)" } ?? "none"
        return "\(selection.fullName)|\(repoIdentity)"
    }

    /// Ephemeral repo 不持有 star 状态；传给分享流程前补齐真实状态，保持与旧 hero
    /// `trailingActions` 的语义一致。
    private func toolbarShareRepo(_ repo: Repo, isStarred: Bool) -> Repo {
        var copy = repo
        copy.isStarred = isStarred
        return copy
    }

    /// 创建或恢复 repo 自己的分享任务。
    ///
    /// 先同步写入 task store 再设置 presentation，保证 Sheet 下一帧立即出现；任务持有
    /// 点击时的 Repo 值快照，因此 selectedRepo 随后切换也不会改变请求目标。
    @MainActor
    private func presentOrStartShare(_ repo: Repo) {
        do {
            // 分享页依赖 AI 摘要内容；先做 Pro preflight，免费用户仍走统一付费墙。
            try dependencies.entitlementGate.requirePro(.aiSummary)
        } catch let error as EntitlementGateError {
            paywallContext = ProPaywallContext(feature: error.feature, message: error.localizedDescription)
            return
        } catch {
            paywallContext = ProPaywallContext(feature: .aiSummary, message: error.localizedDescription)
            return
        }

        shareTaskStore.start(repo: repo, operations: shareOperations)
        sharePresentation = RepoSharePresentation(repoID: repo.id)
    }

    /// 失败重试复用原任务保存的 Repo 快照，不读取当前列表选择。
    @MainActor
    private func retryShare(repoID: Int64) {
        do {
            try dependencies.entitlementGate.requirePro(.aiSummary)
        } catch let error as EntitlementGateError {
            paywallContext = ProPaywallContext(feature: error.feature, message: error.localizedDescription)
            return
        } catch {
            paywallContext = ProPaywallContext(feature: .aiSummary, message: error.localizedDescription)
            return
        }

        shareTaskStore.retry(repoID: repoID, operations: shareOperations)
    }

    /// 生产环境操作直接桥接既有 service。摘要读取必须走 cachedInsightFast，复用其
    /// “当前语言优先、缺失时回退最近摘要”的规则，同时避免 makeSource/hash 的耗时准备。
    @MainActor
    private var shareOperations: RepoShareOperations {
        RepoShareOperations(
            cachedInsight: { repo in
                try await dependencies.repoAIInsightService.cachedInsightFast(for: repo)
            },
            generateInsight: { repo in
                (try await dependencies.repoAIInsightService.generateInsight(for: repo)).insight
            },
            createShare: { request in
                try await dependencies.shareAPI.shareRepo(request: request)
            }
        )
    }

    private func openSmartCollectionEditor() {
        let mode: SmartCollectionRuleEditorSheet.Mode
        if case .userSmartCollection(let id) = viewModel.selection,
           let collection = viewModel.userSmartCollection(id: id) {
            mode = .edit(collection)
        } else if let rule = viewModel.makeRuleFromCurrentManageFilters() {
            mode = .create(defaultName: defaultSmartCollectionName, initialRule: rule)
        } else {
            return
        }
        ruleEditorSheetItem = SmartCollectionRuleEditorItem(mode: mode)
    }

    private var defaultSmartCollectionName: String {
        // 创建时不用 sidebar 分类名（如「全部仓库」）当集合名，避免标题与侧边栏入口混淆。
        String.l10n("smartCollections.new.defaultName")
    }

    /// 中栏主体内容。
    ///
    /// 单独抽出是为了让 root page 分支保持清晰；
    /// Manage 内部 `List` 仍用 `itemsRevision` 重建快照，避免排序/过滤时几千行逐个 move；
    /// row 只做可视区域内的轻量 reveal。缓存命中分类不再跳过 row reveal：
    /// 保留行级 0.22s 动画不会回到整栏卡顿，同时能恢复列表加载的生命感。
    @ViewBuilder
    private var contentBody: some View {
        @Bindable var vm = viewModel

        Group {
            if selectedPage == .trending {
                ExploreView(
                    trendingRepository: trendingRepository,
                    githubAPIClient: githubAPIClient,
                    discoveryViewModel: discoveryViewModel,
                    trendingViewModel: $trendingViewModel,
                    weeklyViewModel: $weeklyViewModel,
                    selectedMode: $selectedExploreMode,
                    selectedTrendingLanguage: $selectedTrendingLanguage,
                    selectedTrendingRepoID: $selectedTrendingRepoID,
                    selectedTrendingRepo: $selectedTrendingRepo,
                    selectedDiscoveryLanguage: $selectedDiscoveryLanguage,
                    selectedDiscoveryTopic: $selectedDiscoveryTopic,
                    selectedDiscoveryPlatform: $selectedDiscoveryPlatform,
                    selectedDiscoveryRepoID: $selectedDiscoveryRepoID,
                    selectedDiscoveryRepo: $selectedDiscoveryRepo,
                    selectedWeeklyLanguage: $selectedWeeklyLanguage,
                    onRepoCountChange: { navigationMetrics.applyTrendingRepoCount($0) }
                )
            } else if selectedPage == .activity {
                ActivityView(
                    viewModel: $activityViewModel,
                    selectedCategory: $selectedActivityCategory,
                    selectedItem: $selectedActivityItem,
                    undoStarAutoSelectRequestID: undoStarAutoSelectRequestID,
                    onItemCountChange: { navigationMetrics.applyActivityItemCount($0) },
                    onSelectUndoStarRepo: { repo in
                        if let repo {
                            viewModel.selectedRepoID = repo.id
                            viewModel.externalSelectedRepo = repo
                        } else {
                            viewModel.selectedRepoID = nil
                            viewModel.externalSelectedRepo = nil
                        }
                    }
                )
            } else {
                // Manage：顶栏（排序 + 同步）始终可见，排序作用于当前侧边栏分类子集。
                manageCategoryContent(vm)
            }
        }
    }

    /// 账号 / 用户数据库边界必须硬失效，禁止跨用户复用 Explore / Activity 快照。
    private func resetRepoListModuleSession() {
        discoveryViewModel = ExploreDiscoveryViewModel()
        trendingViewModel = nil
        weeklyViewModel = nil
        activityViewModel = nil
    }

    /// Manage 全部分类共用：列表顶栏 + 下方内容（横幅 / 列表 / 骨架 / 空态）。
    @ViewBuilder
    private func manageCategoryContent(_ vm: HomeViewModel) -> some View {
        @Bindable var bindableVM = vm

        VStack(spacing: 0) {
            // 顶栏必须占据真实布局高度，而不是通过 `safeAreaInset` 叠在 List 上方。
            // macOS List 的滚动内容会绘制到透明 inset 背后；放进 VStack 后滚动边界从 Divider
            // 下方开始，保持与 Trending / Activity 中栏一致。
            manageListTopInset

            if viewModel.temporaryGlobalFilterSession?.returnPage == .insights {
                insightsDrillDownBanner
            }

            Group {
                if viewModel.selection.isSmartCollectionsSurface {
                    SmartCollectionsOverviewView()
                } else if viewModel.isGitHubStarListSwitchLoading && viewModel.items.isEmpty {
                    // 无缓存瞬切：空白会闪一帧「什么都没有」，与 VM 注释里的骨架屏意图对齐。
                    RepoSkeletonListView(rowCount: 10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if shouldShowInitialStarsLoading {
                    // 首次 stars 同步尚未写入列表时，与分类切换同款骨架，不用 ProgressView。
                    RepoSkeletonListView(rowCount: 10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.isLoading && viewModel.items.isEmpty {
                    RepoSkeletonListView(rowCount: 10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = viewModel.loadError, viewModel.items.isEmpty {
                    emptyState(systemImage: "exclamationmark.triangle", title: "error.loadFailed", subtitleText: error)
                } else if viewModel.items.isEmpty {
                    emptyState(systemImage: emptyImage, title: emptyTitle, subtitle: emptySubtitle)
                } else {
                    listWithOptionalBanner { unifiedListContent($bindableVM.selectedRepoID) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.clear)
        .starcatRefreshCommand(
            pane: .list,
            identity: "manage-\(String(describing: viewModel.selection))-\(isManageRefreshInProgress)",
            title: String.l10n("commands.actions.refreshCurrentList"),
            isEnabled: !isManageRefreshInProgress
        ) {
            refreshManageList()
        }
    }

    /// 洞察下钻是一次临时筛选会话。横幅同时提供“回到来源”和“留在 Manage 并清除”
    /// 两种结束方式，且两者都只恢复用户原有持久筛选，不重置 Toolbar 偏好。
    private var insightsDrillDownBanner: some View {
        HStack(spacing: 10) {
            Label("insights.drilldown.banner", systemImage: "gauge.with.dots.needle.bottom.0percent")
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Button("insights.drilldown.clear") {
                viewModel.clearTemporaryGlobalFilters()
            }
            .buttonStyle(.borderless)
            .controlSize(.small)

            Button("insights.drilldown.return") {
                onReturnToInsights?()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.08))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    /// Manage 分类来自本地标签 / 状态 / GitHub Star List 等投影，GitHub 无法按分类增量同步。
    /// 因此列表刷新先重读当前投影，同时发起一次完整 Stars 对比；同步完成后的既有监听会再刷新行缓存。
    private func refreshManageList() {
        Task { await viewModel.reloadItems(forceRefresh: true) }

        guard let user = authSession.state.user else {
            authSession.requestLoginSheet()
            return
        }
        syncManager.performFullSync(userID: user.id, force: true)
    }

    private var isManageRefreshInProgress: Bool {
        if case .syncing = syncManager.state { return true }
        return false
    }

    /// Manage 中栏列表顶栏（排序 / 同步 / Smart Collections 规则行）+ 底部分割线。
    @ViewBuilder
    private var manageListTopInset: some View {
        @Bindable var bindableVM = viewModel

        VStack(spacing: 0) {
            if viewModel.selection.isSmartCollectionsSurface {
                smartCollectionsSurfaceFilterBar
            } else {
                manageFilterBar(sortOption: $bindableVM.sortOption)
            }
            Divider()
        }
        // 顶栏背景透明，让外层 `detailHeroTintBackground` 光晕能透到标题 / 排序行背后。
        .background(.clear)
        .task(id: authSession.state) {
            await refreshLastSyncedAt()
        }
        .onChange(of: syncManager.state) { _, newState in
            if case .completed(let at) = newState {
                lastSyncedAt = at
            }
        }
    }

    /// Manage 列表顶栏：当前分类内排序 + 同步于 + Stars 同步按钮（对齐 Weekly / Activity）。
    private func manageFilterBar(sortOption: Binding<RepoSortOption>) -> some View {
        HStack(spacing: 10) {
            UnifiedSortMenu(
                selection: sortOption,
                options: RepoSortOption.manageOptions,
                displayName: { $0.displayName },
                systemImage: { $0.systemImage },
                dividerBefore: { $0.isManageSpecificSort && $0 == RepoSortOption.manageOptions.first(where: \.isManageSpecificSort) }
            )

            Spacer()

            if let lastSyncedAt {
                Text(String(format: String.l10n("list.lastSyncedFormat"), relativeDate(lastSyncedAt)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            StarsSyncButton()
        }
        .padding(.horizontal, ManageListFilterBarMetrics.horizontalPadding)
        .padding(.top, ManageListFilterBarMetrics.topPadding)
        .padding(.bottom, ManageListFilterBarMetrics.bottomPadding)
        .onAppear {
            if viewModel.sortOption != settings.repoSortOption {
                viewModel.sortOption = settings.repoSortOption
            }
        }
        .onChange(of: viewModel.sortOption) { _, newValue in
            settings.repoSortOption = newValue
        }
    }

    /// Smart Collections 总览顶栏：与 `manageFilterBar` 同高，保证中栏与「全部仓库」顶区对齐。
    private var smartCollectionsSurfaceFilterBar: some View {
        HStack(spacing: 10) {
            Text("smartCollections.builtIn.title")
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal, ManageListFilterBarMetrics.horizontalPadding)
        .padding(.top, ManageListFilterBarMetrics.topPadding)
        .padding(.bottom, ManageListFilterBarMetrics.bottomPadding)
    }

    private func refreshLastSyncedAt() async {
        if case .completed(let at) = syncManager.state {
            lastSyncedAt = at
            return
        }
        guard case .authenticated(let user) = authSession.state else {
            lastSyncedAt = nil
            return
        }
        if let iso = try? await dependencies.repoRepository.fetchLastSyncAt(userID: user.id),
           let date = ISO8601DateFormatter.shared.date(from: iso) {
            lastSyncedAt = date
        }
    }

    private func relativeDate(_ date: Date) -> String {
        RelativeTimeText.pastEvent(date, locale: locale)
    }

    /// HOM-52：仅在 Untagged 视图非空时，在列表顶部插入"批量 AI 整理"入口横幅。
    ///
    /// 之所以包成 ViewBuilder + closure 而不是把 banner 塞进每个 list view：
    /// unifiedListContent 是带泛型 selection 的 List，加 banner 会破坏 List 滚动语义；
    /// 在外层 VStack 拼接更稳，避免破坏 List 自身滚动与 selection 语义。
    @ViewBuilder
    private func listWithOptionalBanner<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if selectedPage == .manage, viewModel.selection == .untagged {
            VStack(spacing: 0) {
                BatchAIUntaggedBanner(
                    // 用 untaggedCount 而非 items.count：搜索过滤后 items 会少，
                    // 但 banner 反映的是"全部未分类仓库"总量，与"开始整理"动作语义一致。
                    untaggedCount: viewModel.untaggedCount,
                    service: dependencies.batchAIQueueService,
                    onStart: { onStartBatchAI?() },
                    onShowPanel: { onShowBatchAIPanel?() }
                )
                content()
            }
        } else {
            content()
        }
    }

    /// 给 `ForEach` 使用的带下标 repo。
    ///
    /// SwiftUI `List` 本身会按可视区域懒创建 row；这里补一个 index 只用于计算短暂
    /// stagger delay，让切分类后首屏 row 依次轻入场，滚动到新 row 时也能有渐进出现效果。
    private var indexedItems: [IndexedRepo] {
        viewModel.items.enumerated().map { IndexedRepo(index: $0.offset, repo: $0.element) }
    }

    /// 中栏内容状态签名，仅用于调试日志。
    ///
    /// 2026-06-19：这里不再挂到外层 `.id(...)`。
    /// 原先用这个 key 强制销毁重建 `contentBody`，从 Trending / Activity 回 Manage 时
    /// 会把中栏外壳、toolbar、列表 task 一起重挂，和 Manage selection 恢复叠加后形成
    /// 明显卡顿。现在只保留内层 `List.id(viewModel.itemsRevision)` 控制真正需要的
    /// 列表快照重建（排序/过滤后避免几千行逐个 move diff）。
    ///
    /// **HOM-46 性能补丁 #2（2026-06-02）**：移除 has-data 稳定态里的 selection / itemsRevision。
    /// - 之前包含 itemsRevision 会让"数据刷新"也触发外层 transition：
    ///   切分类（cache HIT）→ 第一次 body 渲（items 仍是旧分类）→ applyView 跑完 → itemsRev++ → animID 又变
    ///   → 外层 transition **再启动一次**（同一次切换叠两次 0.22s 动画）。
    /// - 现在外层 transition 只在**视图状态层级**（loading / empty / error / has-data）切换时跑；
    ///   已有缓存的分类之间切换保持同一个 `"repos-\(mode)"` 身份，交给内层 List 快照更新。
    /// - 用户感受：缓存命中时没有外层 transition，配合 didSet 急切缓存加载，第一次 body 渲染就是新数据。
    /// **Activity P0（2026-06-17 dong4j 切分类卡顿）**：本地聚合分类（全部/公告/星标…）
    /// 共享 `"activity-local"` identity，**不**再按 `selectedActivityCategory.id` 分 id。
    /// 旧写法 `activity-\(category.id)` 会让每次切分类销毁重建整棵 `ActivityView` + 跑
    /// 0.22s 外层 transition（Manage HOM-46 已在 has-data 态规避同类问题）。
    /// 仅 weekly ↔ 其它 数据源/根视图不同，保留 `"activity-weekly"` / `"activity-local"` 二分。
    private var contentStateKey: String {
        if selectedPage == .trending {
            if selectedExploreMode == .weekly {
                return "explore-weekly"
            }
            if selectedExploreMode == .trending {
                return "trending-\(selectedTrendingLanguage.id)"
            }
            return "explore-\(selectedExploreMode.id)"
        }
        if selectedPage == .activity {
            return "activity-local"
        }
        // W12 PR-5：多选状态迁到 manageMultiSelectionStore；状态签名用 store.isActive 派生。
        let mode = dependencies.manageMultiSelectionStore.isActive ? "multi" : "single"
        if viewModel.isLoading {
            return "loading-\(viewModel.selection.id)-\(mode)"
        }
        if let error = viewModel.loadError, viewModel.items.isEmpty {
            return "error-\(viewModel.selection.id)-\(error)"
        }
        if viewModel.items.isEmpty {
            return "empty-\(viewModel.selection.id)-\(mode)"
        }
        return "repos-\(mode)"
    }

    // MARK: - 顶部操作栏组件

    /// 可折叠智能搜索框。
    ///
    /// 2026-06-04 修订：dong4j 确认新原型后，搜索入口不再使用系统 `.searchable`。
    /// 原因是当前交互需要“默认折叠 + 模式切换内嵌 + AI 光晕 + 索引刷新内嵌”，这些能力
    /// 超出了 `NSSearchField` / SwiftUI `.searchable` 的定制范围。
    ///
    /// W12 PR-2：增加 `isDisabled` 参数。Trending / Activity 页面也会渲染本组件
    /// 作为常驻入口，但 mode 为 keyword/semantic 时禁用并显示 tooltip。
    private func smartSearchField(isDisabled: Bool = false) -> some View {
        @Bindable var vm = viewModel
        let historyRepository = dependencies.searchHistoryRepository
        // 直接读 `dependencies.entitlementGate.isProUser`(EntitlementGate 是
        // `@MainActor @Observable`),SwiftUI 通过访问追踪自动重渲染;
        // Pro 状态变化(订阅过期/降级)会自动反映到 SmartSearchField 下拉,
        // 由 SmartSearchField 内部的 .onChange(of: isProUser) 做 mode 回退 + 弹付费墙。
        let isProUser = dependencies.entitlementGate.isProUser
        return SmartSearchField(
            text: $vm.searchQuery,
            mode: $vm.smartSearchMode,
            semanticScope: $vm.semanticSearchScope,
            isIndexing: viewModel.isSemanticIndexing,
            indexingProgress: viewModel.semanticIndexProgress,
            isQuerying: viewModel.isSemanticQueryInFlight,
            onSubmitSearch: { query in
                viewModel.submitSearch(query)
                let submitted = query.trimmingCharacters(in: .whitespacesAndNewlines)
                if !submitted.isEmpty {
                    NotificationCenter.default.post(name: .gettingStartedDidUseSearch, object: nil)
                    Task {
                        try? await historyRepository.record(submitted)
                        await reloadToolbarSearchHistory()
                    }
                }
            },
            onRefreshSemanticIndex: {
                Task { await viewModel.refreshSemanticIndex() }
            },
            onOpenGlobalSearch: {
                onOpenSearchCenter?()
            },
            globalSearchShortcutDisplayText: settings.keyboardShortcutsEnabled && settings.globalSearchShortcutEnabled
                ? settings.globalSearchShortcut.displayText
                : nil,
            regularSearchShortcutDisplayText: settings.keyboardShortcutsEnabled && settings.regularSearchShortcutEnabled
                ? settings.regularSearchShortcut.displayText
                : nil,
            isProUser: isProUser,
            onRequestProUpgrade: {
                // 与现有 paywallContext 写入对齐(line 657 / 660 / 718 / 1490):
                // 给 .semanticSearch 弹付费墙,message 走 service 报的本地化错误文案,
                // 即便此处文案与执行时报错不一致,用户也能从弹窗明确"是 .semantic 触发的"。
                paywallContext = ProPaywallContext(
                    feature: .semanticSearch,
                    message: String.l10n("search.paywall.semantic.upgrade")
                )
            },
            isDisabled: isDisabled,
            collapseToken: viewModel.selectedRepoID,
            expandToken: smartSearchExpandToken,
            historyEntries: toolbarSearchHistory,
            onRefreshHistory: {
                Task { await reloadToolbarSearchHistory() }
            },
            onRemoveHistory: { entry in
                Task { await removeToolbarSearchHistory(entry) }
            }
        )
        .gettingStartedAnchor(.search)
        .onAppear {
            if viewModel.smartSearchMode != settings.smartSearchMode {
                viewModel.smartSearchMode = settings.smartSearchMode
            }
        }
        .onChange(of: viewModel.smartSearchMode) { _, newValue in
            settings.smartSearchMode = newValue
        }
    }

    /// Toolbar 搜索历史取自与 Search Center 相同的 SQLite 表，并沿用相同半衰期排序。
    @MainActor
    private func reloadToolbarSearchHistory() async {
        guard let entries = try? await dependencies.searchHistoryRepository.fetchAll() else {
            toolbarSearchHistory = []
            return
        }
        let now = Date()
        toolbarSearchHistory = entries.sorted { lhs, rhs in
            lhs.decayedScore(now: now) > rhs.decayedScore(now: now)
        }
    }

    @MainActor
    private func removeToolbarSearchHistory(_ entry: SearchHistory) async {
        try? await dependencies.searchHistoryRepository.remove(query: entry.queryLower)
        await reloadToolbarSearchHistory()
    }

    // MARK: - 列表主体

    /// 统一的 Manage 列表（W12 PR-5：替代原 `listContent(_:)` + `multiSelectList(_:)` 两条路径）。
    ///
    /// 单选 / 多选共用同一份 `List + ForEach + plain Button + UnifiedRepoRow` 结构，与
    /// TrendingView / WeeklyContentView / ActivityView 完全对齐：
    /// - 不用 `List(selection:)` —— 它会强制绘制 macOS 系统蓝色选中底色，把自定义 `RepoRowSurface`
    ///   的语言色 accent / 18% 底色 / 42% 描边完全压住，多选与 trending 视觉割裂的根因；
    /// - 单选模式（store.isActive == false）：Button action 写 `selectedRepoID`，HomeView 监听
    ///   该变化加载详情；
    /// - 多选模式（store.isActive == true）：Button action 调 `store.toggle(snapshot)` 切换选中态；
    ///   selectedRepoID 完全不动（对齐 Trending：退出多选后详情页保持），UnifiedRepoRow 的
    ///   isSelected 由 store.contains 派生；
    /// - 卡片视觉完全由 `UnifiedRepoRow.isSelected` 驱动（无 List 系统蓝），4 个分类长得一模一样。
    private func unifiedListContent(_ selection: Binding<Int64?>) -> some View {
        let store = dependencies.manageMultiSelectionStore
        // ScrollViewReader 包装的目的（dong4j 2026-06-13）：
        // 外部场景（命令面板 / SearchCenter 选中本地 repo，HomeView.openSearchCandidate
        // 写 viewModel.selectedRepoID）必须能让列表滚到目标行，否则用户只看到详情区切了过去，
        // 而列表里"被选中的那行"远在视口外，体感上像"啥也没发生"。
        // 用 ForEach 行的 `.id(repo.id)` 作为 scroll anchor —— Repo.id 是 GitHub repo id，
        // 全局唯一，不会与 trending / weekly / activity 的 id 域冲突。
        return ScrollViewReader { proxy in
            List {
                ForEach(indexedItems) { item in
                    let repo = item.repo
                    Button {
                        if store.isActive {
                            // 多选模式：toggle 该行选中态。Repo.id == ghRepoId == GitHub ID 同一 Int64 域。
                            store.toggle(SelectionSnapshot(
                                ghRepoId: repo.id,
                                owner: repo.owner,
                                name: repo.name
                            ))
                        } else {
                            selection.wrappedValue = repo.id
                        }
                    } label: {
                        // 行级状态 / badge 由独立子 View 观察，避免任意 Health/OpenSSF 快照更新
                        // 都让包含 toolbar、tint 与整棵 List 的 RepoListView 重新计算 body。
                        ManageRepoRowContent(
                            repo: repo,
                            viewModel: viewModel,
                            aiSummaryAvailability: aiSummaryAvailability,
                            isSelected: store.isActive
                                ? store.contains(ghRepoId: repo.id)
                                : (selection.wrappedValue == repo.id)
                        )
                        .background {
                            if item.index == 0 {
                                Color.clear
                                    .gettingStartedAnchor(.selectRepo)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .listRowReveal(
                        index: item.index,
                        snapshotID: viewModel.itemsRevision,
                        skipAnimation: viewModel.skipListRowReveal
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .id(repo.id)
                    // HOM-201 P1-1（2026-06-14）：hover 500ms 后预拉 README，
                    // softTtl 短路在 API 层做（命中 6h 内缓存不打 GitHub）。
                    .readmePrefetch { [readmeAPI = dependencies.readmeAPI] in
                        await readmeAPI.prefetch(for: repo)
                    }
                    .contextMenu {
                        repoContextMenu(for: repo)
                    }
                    // R-07：滚到倒数第 3 行 → 追加下一页（Weekly 同款范式）。
                    // 用 `viewModel.items.count` 实时读，配合 hasMore 守卫天然幂等：
                    // loadMoreIfNeeded 内部 guard hasMore 防止已加载完后继续追加。
                    // 用 item.index 比 indexOf(repo) 快（O(1)）。
                    .onAppear {
                        if viewModel.hasMore && item.index >= viewModel.items.count - 3 {
                            viewModel.loadMoreIfNeeded()
                        }
                    }
                }
            }
            .id(viewModel.listSnapshotIdentity)
            .listStyle(.inset)
            // 透出底层 `DetailHeroTintBackground`；系统 List 默认实色底会盖住顶栏光晕。
            .scrollContentBackground(.hidden)
            .alternatingRowBackgrounds()
            // 阅读状态 v2（2026-06-12）：订阅 .repoStatusDidChange，详情页改 status 后
            // HomeViewModel.statusMap 局部更新 → UnifiedRepoRow.readStatus 重渲染 → 角标即时刷新。
            // task 与 view lifetime 绑定（view 退出自动 cancel），不会泄漏 NotificationCenter observer。
            .task {
                await viewModel.observeRepoStatusChanges()
            }
            .task(id: dependencies.databaseScopeRevision) {
                // 以数据库真正完成 reopen 为准，不能使用可能提前恢复的登录 profile 作为切库信号。
                aiSummaryAvailability.resetForDatabaseChange()
                await aiSummaryAvailability.reload(from: dependencies.aiSummaryRepository)
            }
            .task {
                await observeAISummaryChanges()
            }
            // 知识库状态观察已上移到 HomeView：空库 / Smart Collections 总览时这里没有 List。
            .task(id: viewModel.items.map(\.id)) {
                await reloadVisibleBadgeCaches(forceReload: false)
            }
            .task {
                await observeRepoHealthBadgeChanges()
            }
            .task {
                await observeOpenSSFScoreChanges()
            }
            // Stars 同步、OpenSSF 和 Health 后台预热都会先写 SQLite；列表行同步读 Store 内存缓存。
            // 因此这些后台边沿完成后要强制重读当前 rows，否则卡片会停在旧内存状态。
            .task(id: syncManager.state) {
                guard case .completed = syncManager.state else { return }
                await reloadVisibleBadgeCaches(forceReload: true)
            }
            .task(id: dependencies.repoHealthPoller.lastRunAt) {
                guard dependencies.repoHealthPoller.lastRunAt != nil else { return }
                await reloadVisibleBadgeCaches(forceReload: true)
            }
            .task(id: dependencies.initialWarmupCoordinator.job?.updatedAt) {
                guard let phase = dependencies.initialWarmupCoordinator.job?.phase,
                      phase == .openSSF || phase == .health || phase == .completed else { return }
                await reloadVisibleBadgeCaches(forceReload: true)
            }
            // 仅外部导航（SearchCenter / 命令面板）递增 revision；列表行点击不发请求，
            // 避免 scrollTo(.center) 错位到下一卡片。使用 task(id:) 而不是监听 selection：
            // 相同 repo 重复打开时 selection 不变；目标页加载导致 List 重建时，task 也会在
            // 新实例挂载后执行，不会提前消费滚动意图。
            .task(id: viewModel.repoListScrollRequestRevision) {
                guard viewModel.repoListScrollRequestRevision > 0 else { return }
                guard let id = selection.wrappedValue else { return }
                guard viewModel.items.contains(where: { $0.id == id }) else { return }
                await Task.yield()
                if reduceMotion {
                    proxy.scrollTo(id, anchor: .center)
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
            // R-07.1 follow-up（2026-06-16 dong4j）：hasMore false → true 时主动 push 一次 loadMoreIfNeeded。
            //
            // 场景（dong4j 真机回归发现）：sync 还在跑期间用户已手动滚动到 items 尾部触发 loadMoreIfNeeded × N,
            // items 从 20 一路涨到 currentPage * 20,hasMore 在抵达 filteredSorted.count 那一刻翻 false。
            // 等 sync 完成（state = .completed）,HomeView 调 reloadItems(forceRefresh: true)：
            //   - filteredSorted 从快照 100 → 1800
            //   - currentPage 保留（preserveScrollPosition,R-07 既有设计）
            //   - sliceToCurrentPage 算出 newItems 与现有 items 前 N 条同 ID 同序 → itemsIdentical
            //     short-circuit → items 不变 / itemsRevision 不 bump
            //   - 但 hasMore 被无条件设置为 true（1800 > items.count）
            //
            // 后果：列表 UI 看似数据未变,但 hasMore 状态翻转后,已显示行的 .onAppear **不会** 重触发
            // （SwiftUI 只在 row 首次进入视口时调 onAppear）；用户被困在原 items 尾部,往下滚是橡皮筋
            // 回弹,无法触发后续 loadMore,"卡在 100 条尾部"无法看到完整 1800 条列表。
            //
            // 修复：监听 hasMore 边沿 false → true,主动调一次 loadMoreIfNeeded 让 items 增长一页。
            // sliceToCurrentPage(reason: .append) 不 bump itemsRevision,滚动位置自然保留；用户继续
            // 向下滚动时,新行的倒数第 3 个 .onAppear 会触发后续 loadMore,自然推进到 filteredSorted.count。
            //
            // 用 Task { @MainActor in } 包一层：避免在 SwiftUI body 更新期间同步写 viewModel 状态
            // 触发"Modifying state during view update"警告。loadMoreIfNeeded 内部 guard hasMore
            // 天然幂等,多次触发不会引发 currentPage 失控。
            //
            // 2026-07-18 性能专项：首次首页的 false→true 不再自动追加第二页。只有 ViewModel
            // 明确认定“刷新前用户已深滚动到末尾”时才消费恢复意图，避免一次点击连续发布两批数据。
            .onChange(of: viewModel.hasMore) { wasMore, hasMore in
                guard !wasMore, hasMore else { return }
                Task { @MainActor in
                    viewModel.recoverPaginationAfterRefreshIfNeeded()
                }
            }
        }
    }

    @MainActor
    private func reloadVisibleBadgeCaches(forceReload: Bool) async {
        let repoIDs = viewModel.items.map(\.id)
        guard !repoIDs.isEmpty else { return }
        await reloadBadgeCaches(for: repoIDs, forceReload: forceReload)
    }

    @MainActor
    private func reloadBadgeCaches(for repoIDs: [Int64], forceReload: Bool) async {
        guard !repoIDs.isEmpty else { return }
        async let openSSF: Void = dependencies.openSSFScoreStore.loadCachedScores(
            for: repoIDs,
            forceReload: forceReload
        )
        async let health: Void = dependencies.repoHealthStore.loadCachedSnapshots(
            for: repoIDs,
            forceReload: forceReload
        )
        _ = await (openSSF, health)
    }

    @MainActor
    private func observeRepoHealthBadgeChanges() async {
        let stream = NotificationCenter.default.notifications(named: .repoHealthSnapshotDidChange)
        for await note in stream {
            guard !Task.isCancelled else { break }
            guard let repoID = note.userInfo?["repoId"] as? Int64 else { continue }
            // 即使更新行当前不可见，也可能改变某个已缓存分类的筛选成员关系或排序。
            viewModel.invalidateDatabaseSnapshotsForHealthSignalChange()
            guard viewModel.items.contains(where: { $0.id == repoID }) else { continue }
            await dependencies.repoHealthStore.loadCachedSnapshots(for: [repoID], forceReload: true)
        }
    }

    @MainActor
    private func observeOpenSSFScoreChanges() async {
        let stream = NotificationCenter.default.notifications(named: .openSSFScoreDidChange)
        for await note in stream {
            guard !Task.isCancelled else { break }
            guard let repoID = note.userInfo?["repoId"] as? Int64 else { continue }
            viewModel.invalidateDatabaseSnapshotsForOpenSSFSignalChange()
            guard viewModel.items.contains(where: { $0.id == repoID }) else { continue }
            await dependencies.openSSFScoreStore.loadCachedScores(for: [repoID], forceReload: true)
        }
    }

    @MainActor
    private func observeAISummaryChanges() async {
        let stream = NotificationCenter.default.notifications(named: .aiSummaryDidChange)
        for await note in stream {
            guard !Task.isCancelled else { break }
            guard let repoID = note.userInfo?["repoId"] as? Int64 else { continue }
            // ai_summaries 当前只有 upsert 写入口；收到通知即可直接把该 repo 标为已有摘要，
            // 无需重新扫描整张表，也不会把摘要正文带入列表内存。
            aiSummaryAvailability.markAvailable(repoID: repoID)
        }
    }

    // MARK: - Repo 右键菜单

    /// Manage repo 列表右键菜单：Pin + 分组移入 / 移出 / 移动。
    ///
    /// **2026-07-05 优化（扁平化）**：
    /// 之前用 `Menu` 嵌套做「添加到... / 移动到...」子菜单，macOS 上层级展开箭头需要精确
    /// 鼠标横向移动，分组一多就容易滑错关闭。改为扁平 Button 列表：
    /// - 颜色圆点匹配侧边栏，一眼识别分组
    /// - 数量尾标辅助判断目标分组大小
    /// - 当前分组不可点（"移动到"模式），避免无意义操作
    @ViewBuilder
    private func repoContextMenu(for repo: Repo) -> some View {
        if selectedPage == .manage {
            if viewModel.isRepoPinned(repo.id) {
                Button {
                    mutateRepoPin(repo, pinned: false)
                } label: {
                    Label("repoList.context.unpin", systemImage: "pin.slash")
                }
            } else {
                Button {
                    mutateRepoPin(repo, pinned: true)
                } label: {
                    Label("repoList.context.pin", systemImage: "pin")
                }
            }

            Divider()

            if case .githubStarList(let currentListID) = viewModel.selection {
                // ──── 在某个分组内：移出 + 移到其他分组 ────
                if let currentList = viewModel.githubStarLists.first(where: { $0.id == currentListID }) {
                    Button {
                        mutateGitHubStarListMembership {
                            try await dependencies.githubStarListSyncService.removeRepo(repo, fromList: currentListID)
                        }
                    } label: {
                        Text(String(
                            format: String.l10n("githubStarLists.context.removeFromGroupFormat"),
                            currentList.name
                        ))
                    }
                }

                let targets = viewModel.githubStarLists.filter { $0.id != currentListID }
                if !targets.isEmpty {
                    Divider()
                    // section header：移到其他分组
                    Text("githubStarLists.context.moveToOtherGroupSection")
                    ForEach(targets) { list in
                        Button {
                            mutateGitHubStarListMembership {
                                try await dependencies.githubStarListSyncService.moveRepo(
                                    repo, from: currentListID, to: list.id
                                )
                            }
                        } label: {
                            gitHubStarListMenuItemLabel(list)
                        }
                    }
                }
            } else {
                // ──── 不在分组内（全部星标 / Tags / Languages）：添加到分组 ────
                if viewModel.githubStarLists.isEmpty {
                    Text("githubStarLists.context.noGroups")
                } else {
                    // section header：添加到分组
                    Text("githubStarLists.context.addToGroupSection")
                    ForEach(viewModel.githubStarLists) { list in
                        Button {
                            mutateGitHubStarListMembership {
                                try await dependencies.githubStarListSyncService.addRepo(repo, toList: list.id)
                            }
                        } label: {
                            gitHubStarListMenuItemLabel(list)
                        }
                    }
                }
            }
        }
    }

    /// Pin 写库成功后再发布列表顺序，避免数据库失败时 UI 与持久化状态分叉。
    private func mutateRepoPin(_ repo: Repo, pinned: Bool) {
        Task {
            do {
                try await viewModel.setRepoPinned(repoId: repo.id, pinned: pinned)
                repoPinToastMessage = pinned
                    ? "repoList.toast.pinned"
                    : "repoList.toast.unpinned"
            } catch {
                AppLog.database.error("Repo Pin mutation failed: \(error.localizedDescription, privacy: .public)")
                repoPinToastMessage = "repoList.toast.pinFailed"
            }
        }
    }

    /// 分组菜单项标签：颜色圆点（匹配侧边栏）+ 名称 + 数量。
    ///
    /// 颜色圆点使用非 template NSImage，确保在 NSMenuItem 中保留原色而非被系统 tint 覆盖。
    private func gitHubStarListMenuItemLabel(_ list: GitHubStarList) -> some View {
        let count = viewModel.githubStarListCounts[list.id] ?? 0
        return Label(
            title: { Text(verbatim: "\(list.name)  (\(count))") },
            icon: {
                if let dot = Self.colorDotImage(hex: list.colorHex) {
                    Image(nsImage: dot)
                }
            }
        )
    }

    /// 生成分组颜色圆点 NSImage（非 template，保留原色）。
    ///
    /// 必须设置 `isTemplate = false`，否则 AppKit 会按系统主题 tint 覆盖颜色，
    /// 导致所有圆点变成同色，失去分组辨识意义。
    private static func colorDotImage(hex: String) -> NSImage? {
        let nsColor = Self.nsColorFromHex(hex) ?? .controlAccentColor
        let size: CGFloat = 10
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            nsColor.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// 从 `#RRGGBB` 字符串创建 NSColor。
    private static func nsColorFromHex(_ hex: String) -> NSColor? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let rgb = UInt32(s, radix: 16) else { return nil }
        return NSColor(
            srgbRed: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0,
            alpha: 1.0
        )
    }

    private func mutateGitHubStarListMembership(_ operation: @escaping () async throws -> Void) {
        Task {
            do {
                try await operation()
                await viewModel.refreshSidebar()
                await viewModel.reloadItems(forceRefresh: true)
                toastMessage = "githubStarLists.toast.updated"
            } catch {
                AppLog.network.error("GitHub star list mutation failed: \(error.localizedDescription, privacy: .public)")
                if isGitHubOrganizationOAuthRestriction(error) {
                    showGitHubStarListOAuthRestrictionSheet = true
                } else {
                    toastMessage = "githubStarLists.toast.failed"
                }
            }
        }
    }

    private func isGitHubOrganizationOAuthRestriction(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("organization has enabled oauth app access restrictions")
            || message.contains("third-parties is limited")
    }

    private var manageNavigationSubtitle: String {
        // Smart Collections 总览：副标题是集合数量（与 sidebar 计数一致），不是仓库数。
        if case .smartCollectionsHome = viewModel.selection {
            return String(
                format: String.l10n("smartCollections.collectionCountFormat"),
                smartCollectionsTotalCount
            )
        }
        // **R-07.2 修订**：DB 分页模式下 filteredSorted 只镜像已加载前缀，标题数量
        // 必须读 ViewModel 的真实查询总数，避免 1800+ 仓库首屏只显示 20。
        let currentCount = viewModel.visibleRepoTotalCount
        if manageNavigationPresentation.isFilteredScope || viewModel.hasActiveFilter {
            return String(
                format: String.l10n("list.filteredRepoCountFormat"),
                currentCount,
                viewModel.totalCount
            )
        }
        return repoCountSubtitle(currentCount)
    }

    private func repoCountSubtitle(_ count: Int) -> String {
        String(
            format: String.l10n("list.repoCountFormat"),
            count
        )
    }

    /// 内置 + 自定义智能集合总数；与 `SidebarView` smartCollectionsHome 行计数同源。
    private var smartCollectionsTotalCount: Int {
        SmartCollectionKind.allCases.count + viewModel.userSmartCollections.count
    }

    // MARK: - 标题派生

    private var navigationTitle: Text {
        if selectedPage == .trending {
            return exploreNavigationTitle
        }
        if selectedPage == .activity {
            return highlightedNavigationTitle(
                prefix: String.l10n("activity.title"),
                thirdLevelTitle: selectedActivityCategory.localizedTitle
            )
        }
        return manageNavigationTitle
    }

    private var manageNavigationTitle: Text {
        let presentation = manageNavigationPresentation
        let prefix = [
            String.l10n("nav.manage"),
            presentation.secondLevelTitle
        ].joined(separator: Self.navigationBreadcrumbSeparator)
        return highlightedNavigationTitle(
            prefix: prefix,
            thirdLevelTitle: presentation.thirdLevelTitle
        )
    }

    private var manageNavigationPresentation: ManageNavigationPresentation {
        let filters = viewModel.effectiveGlobalFilterState
        var selectedLanguageTitles: [String] = []
        switch filters.repoLanguageFilter {
        case .all:
            break
        case .uncategorized:
            selectedLanguageTitles.append(String.l10n("trending.language.uncategorized"))
        case .language(let language):
            selectedLanguageTitles.append(LanguageDisplayName.shortened(for: language))
        }
        for language in filters.globalFilterLanguages {
            let title = LanguageDisplayName.shortened(for: language)
            if !selectedLanguageTitles.contains(where: {
                $0.caseInsensitiveCompare(title) == .orderedSame
            }) {
                selectedLanguageTitles.append(title)
            }
        }
        let selectedTagTitles = viewModel.tags
            .filter { viewModel.selectedTagIds.contains($0.id) }
            .map(\.name)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let searchTitle = viewModel.isSearching
            ? String(format: String.l10n("search.searching"), truncatedSearchQueryForTitle)
            : nil
        return ManageNavigationPresentation.make(
            selection: viewModel.selection,
            selectionTitle: localizedTitle(for: viewModel.selection),
            selectedLanguageTitles: selectedLanguageTitles,
            selectedTagTitles: selectedTagTitles,
            searchTitle: searchTitle
        )
    }

    private var exploreNavigationTitle: Text {
        let presentation = ExploreNavigationPresentation.make(
            mode: selectedExploreMode,
            trendingLanguage: selectedTrendingLanguage,
            discoveryLanguage: selectedDiscoveryLanguage,
            discoveryTopic: selectedDiscoveryTopic,
            discoveryPlatform: selectedDiscoveryPlatform,
            weeklyLanguage: selectedWeeklyLanguage,
            topics: dependencies.exploreCatalogStore.displayTopics,
            platforms: dependencies.exploreCatalogStore.displayPlatforms
        )
        let prefix = [
            String.l10n("nav.trending"),
            selectedExploreMode.localizedTitle
        ].joined(separator: Self.navigationBreadcrumbSeparator)
        return highlightedNavigationTitle(
            prefix: prefix,
            thirdLevelTitle: presentation.thirdLevelTitle
        )
    }

    /// 在唯一的原生 navigation title 内生成带第三级强调色的文本。
    private func highlightedNavigationTitle(
        prefix: String,
        thirdLevelTitle: String
    ) -> Text {
        let thirdLevelTitle = truncatedBreadcrumbSegment(thirdLevelTitle)
        var title = AttributedString("\(prefix)\(Self.navigationBreadcrumbSeparator)")
        var highlightedThirdLevel = AttributedString(thirdLevelTitle)
        highlightedThirdLevel.foregroundColor = .accentColor
        title.append(highlightedThirdLevel)

        // 不再增加 toolbar item；标题栏始终只有系统原生这一份导航。
        return Text(title)
    }

    /// 同搜索标题一样先在字符串层截断，避免长标签 / 智能集合名撑开系统标题栏。
    private func truncatedBreadcrumbSegment(_ raw: String) -> String {
        let limit = Self.navigationBreadcrumbSegmentLimit
        return raw.count > limit ? "\(raw.prefix(limit))…" : raw
    }

    /// 给 `.navigationTitle` 用的搜索词截断版本。
    ///
    /// **为什么必须在拼字符串时就截断**：`.navigationTitle(_:)` 接的是裸 `String`，
    /// 直接绑到 macOS 窗口 chrome / NavigationStack title 区，**SwiftUI 没有 modifier 能
    /// 在 view 层 truncate**（`.lineLimit` 对 system title 无效）。任由 query 过长会
    /// 把 toolbar 撑出列表栏右侧。
    ///
    /// **阈值 24 个 grapheme cluster**：经验值，覆盖典型搜索 90%+ 场景；中英混排在
    /// 280–400pt 列表栏宽度内不溢出。超长则后接 `…`（U+2026 HORIZONTAL ELLIPSIS
    /// 单字符省略号，符合 Apple HIG，不用三个 ASCII 点）。
    ///
    /// **不动 `viewModel.searchQuery` 本体**：截断仅作显示用，FTS / 语义搜索仍按完整
    /// query 跑；这里只防 title 视觉溢出。
    private var truncatedSearchQueryForTitle: String {
        let raw = viewModel.searchQuery
        let limit = 24
        return raw.count > limit ? "\(raw.prefix(limit))…" : raw
    }

    /// Navigation title 需要 plain String；静态入口走 localization，用户标签/语言按原样显示。
    private func localizedTitle(for item: SidebarItem) -> String {
        switch item {
        case .trending:
            return String.l10n("nav.trending")
        case .allStars:
            return String.l10n("sidebar.allRepos")
        case .myProjects:
            return String.l10n("sidebar.myProjects")
        case .allLanguages:
            return String.l10n("trending.allLanguages")
        case .untagged:
            return String.l10n("sidebar.untagged")
        case .library:
            return String.l10n("sidebar.library")
        case .smartCollectionsHome:
            return String.l10n("smartCollections.title")
        case .smartCollection(let kind):
            return String.l10n("smartCollections.\(kind.rawValue).title")
        case .userSmartCollection(let id):
            return viewModel.userSmartCollection(id: id)?.name ?? String.l10n("smartCollections.mine.fallback")
        case .language(let language):
            // Navigation title 同样走短名（详见 LanguageDisplayName）。
            // 无主语言（nil）统一硬编码为 "Uncategorized"（dong4j 2026-06-16，不做 i18n）。
            return language.map(LanguageDisplayName.shortened(for:)) ?? "Uncategorized"
        case .tag(let id):
            return viewModel.tags.first { $0.id == id }?.name ?? String.l10n("sidebar.tagFallback")
        case .githubStarListUngrouped:
            return String.l10n("sidebar.githubStarLists.ungrouped")
        case .githubStarList(let id):
            return viewModel.githubStarLists.first { $0.id == id }?.name ?? String.l10n("sidebar.githubStarLists.fallback")
        }
    }

    // MARK: - 空状态

    /// 首次同步还没写入首批 repo 时，列表自身没有 `isLoading`，但全局同步已经在跑。
    /// 这里把“真实加载中”挡在空态之前，避免误提示用户手动点击同步。
    private var shouldShowInitialStarsLoading: Bool {
        guard selectedPage == .manage, viewModel.items.isEmpty else { return false }
        guard case .syncing = syncManager.state else { return false }
        switch viewModel.selection {
        case .allStars, .allLanguages, .githubStarListUngrouped:
            return true
        default:
            return false
        }
    }

    private var emptyImage: String {
        if viewModel.isSearching { return "magnifyingglass" }
        switch viewModel.selection {
        case .trending:  return "chart.line.uptrend.xyaxis"
        case .allStars:  return "star"
        case .myProjects: return "folder"
        case .allLanguages: return "globe"
        case .untagged:  return "tag.slash"
        case .library:   return "heart.fill"
        case .smartCollectionsHome: return "line.3.horizontal.decrease.circle"
        case .smartCollection: return "tray"
        case .userSmartCollection: return "line.3.horizontal.decrease.circle"
        case .language:  return "chevron.left.forwardslash.chevron.right"
        case .tag:       return "tag.slash"
        case .githubStarListUngrouped: return "tray"
        case .githubStarList: return "folder"
        }
    }

    private var emptyTitle: LocalizedStringKey {
        if viewModel.isSearching { return "empty.noResults" }
        switch viewModel.selection {
        case .trending:        return "empty.trendingUnavailable"
        case .allStars:        return "empty.noStars"
        case .myProjects:      return "empty.noResults"
        case .allLanguages:    return "empty.noStars"
        case .untagged:        return "empty.allTagged"
        case .library:         return "empty.library.title"
        case .smartCollectionsHome: return "smartCollections.empty.title"
        case .smartCollection: return "smartCollections.empty.collection"
        case .userSmartCollection: return "smartCollections.empty.collection"
        case .language:        return "empty.noReposInLanguage"
        case .tag:             return "empty.noReposInTag"
        case .githubStarListUngrouped: return "empty.noStars"
        case .githubStarList:  return "empty.noReposInTag"
        }
    }

    private var emptySubtitle: LocalizedStringKey {
        if viewModel.isSearching { return "empty.tryAnother" }
        switch viewModel.selection {
        case .trending:        return "empty.trendingComingSoon"
        case .allStars:        return "empty.syncPrompt"
        case .myProjects:      return "empty.syncPrompt"
        case .allLanguages:    return "empty.syncPrompt"
        case .untagged:        return "empty.untaggedHint"
        case .library:         return "empty.library.subtitle"
        case .smartCollectionsHome: return "smartCollections.empty.subtitle"
        case .smartCollection: return "smartCollections.empty.collectionSubtitle"
        case .userSmartCollection: return "smartCollections.empty.collectionSubtitle"
        case .language:        return "empty.languageHint"
        case .tag:             return "empty.tagHint"
        case .githubStarListUngrouped: return "empty.syncPrompt"
        case .githubStarList:  return "empty.tagHint"
        }
    }

    private func emptyState(systemImage: String, title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
        EmptyStateView(
            systemImage: systemImage,
            title: title,
            subtitle: subtitle,
            spacing: 12
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func emptyState(systemImage: String, title: LocalizedStringKey, subtitleText: String) -> some View {
        EmptyStateView(
            systemImage: systemImage,
            title: title,
            subtitleText: subtitleText,
            spacing: 12
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func statusIcon(for status: RepoStatus) -> String {
        switch status {
        case .unread: return "envelope.badge"
        case .read:   return "envelope.open"
        case .using:  return "checkmark.seal"
        }
    }

    private func libraryFilterIcon(for filter: RepoLibraryFilter) -> String {
        switch filter {
        case .all: return "tray.full"
        case .inLibrary: return "heart.fill"
        case .outsideLibrary: return "heart"
        }
    }

    private func starFilterIcon(for filter: RepoStarFilter) -> String {
        switch filter {
        case .all: return "tray.full"
        case .starred: return "star.fill"
        case .unstarred: return "star"
        }
    }

    /// Toolbar setter 统一经过 ViewModel，确保用户操作能退出临时钻取会话并恢复持久语义。
    private func globalFilterBinding<Value>(
        _ keyPath: WritableKeyPath<GlobalRepoFilterState, Value>
    ) -> Binding<Value> {
        Binding(
            get: { viewModel.effectiveGlobalFilterState[keyPath: keyPath] },
            set: { viewModel.setGlobalFilterFromUser(keyPath, to: $0) }
        )
    }

    /// 「只看私有仓库」快捷开关，与可见性 Picker 共用 `projectVisibilityFilter`。
    private var onlyPrivateProjectsBinding: Binding<Bool> {
        Binding(
            get: { viewModel.projectVisibilityFilter == .private },
            set: { isOn in
                viewModel.projectVisibilityFilter = isOn ? .private : nil
            }
        )
    }

    private func globalLanguageBinding(for language: String) -> Binding<Bool> {
        Binding(
            get: {
                let filters = viewModel.effectiveGlobalFilterState
                if case .language(let selectedLanguage) = filters.repoLanguageFilter,
                   selectedLanguage.caseInsensitiveCompare(language) == .orderedSame {
                    return true
                }
                return filters.globalFilterLanguages.contains {
                    $0.caseInsensitiveCompare(language) == .orderedSame
                }
            },
            set: { isOn in
                let current = viewModel.effectiveGlobalFilterState.globalFilterLanguages
                let updated: [String]
                if isOn {
                    updated = AppSettings.normalizedLanguageList(
                        current + [language]
                    )
                } else {
                    updated = current.filter {
                        $0.caseInsensitiveCompare(language) != .orderedSame
                    }
                }
                viewModel.setCategorizedLanguageFiltersFromUser(updated)
            }
        )
    }

    private func statusFilterSection(selection: Binding<RepoStatus?>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            filterSectionHeader(title: "list.filter.status", icon: "tray.full")

            Picker(selection: selection) {
                // 「全部」也挂图标避免下拉里出现"3 个 Label + 1 个裸 Text"的不对齐视觉。
                // `tray.full` 与下方 envelope.badge / envelope.open / checkmark.seal
                // 同邮件视觉系统，语义"收件箱全在这"。
                Label("general.all", systemImage: "tray.full").tag(RepoStatus?.none)
                ForEach(RepoStatus.allCases, id: \.self) { st in
                    Label(st.displayName, systemImage: statusIcon(for: st))
                        .tag(RepoStatus?.some(st))
                }
            } label: {
                EmptyView()
            }
            .labelsHidden()
            .pickerStyle(.inline)
        }
    }

    private func starFilterSection(selection: Binding<RepoStarFilter>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            filterSectionHeader(title: "list.filter.starStatus", icon: "star.circle")

            Picker(selection: selection) {
                ForEach(RepoStarFilter.allCases, id: \.self) { filter in
                    Label(filter.displayName, systemImage: starFilterIcon(for: filter))
                        .tag(filter)
                }
            } label: {
                EmptyView()
            }
            .labelsHidden()
            .pickerStyle(.inline)
        }
    }

    private func libraryFilterSection(selection: Binding<RepoLibraryFilter>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            filterSectionHeader(title: "list.filter.library", icon: "heart.text.square")

            Picker(selection: selection) {
                ForEach(RepoLibraryFilter.allCases, id: \.self) { filter in
                    Label(filter.displayName, systemImage: libraryFilterIcon(for: filter))
                        .tag(filter)
                }
            } label: {
                EmptyView()
            }
            .labelsHidden()
            .pickerStyle(.inline)
        }
    }

    private func languageFilterSection() -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                filterSectionHeader(title: "list.filter.language", icon: "globe")
                Spacer(minLength: 0)
                Button {
                    interestedLanguageDraft = ""
                    showingInterestedLanguagePicker = true
                } label: {
                    // 与「语言」分类 globe 同规格，方便在全局筛选里直接加语言。
                    Label("settings.filters.interestedLanguages.add", systemImage: "plus.circle")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("settings.filters.interestedLanguages.add")
                .popover(isPresented: $showingInterestedLanguagePicker, arrowEdge: .trailing) {
                    interestedLanguagePickerPopover
                        .frame(width: 280, height: 300)
                        .padding(14)
                }
            }

            if viewModel.effectiveGlobalFilterState.repoLanguageFilter != .all
                || !viewModel.effectiveGlobalFilterState.globalFilterLanguages.isEmpty {
                Button {
                    viewModel.clearLanguageFiltersFromUser()
                } label: {
                    Label("list.filter.language.clearSelection", systemImage: "xmark.circle")
                }
            }

            if settings.interestedLanguages.isEmpty {
                Text("settings.filters.interestedLanguages.empty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(settings.interestedLanguages, id: \.self) { language in
                    Toggle(isOn: globalLanguageBinding(for: language)) {
                        Label {
                            Text(LanguageDisplayName.shortened(for: language))
                        } icon: {
                            FilterMenuLanguageIcon(language: language, size: 14)
                        }
                    }
                }
            }
        }
    }

    private var interestedLanguagePickerPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(
                "settings.filters.interestedLanguages.add.placeholder",
                text: $interestedLanguageDraft
            )
            .textFieldStyle(.roundedBorder)

            let query = interestedLanguageDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            let results = LinguistLanguageCatalog.search(query)
            if query.isEmpty {
                Text("settings.filters.interestedLanguages.add.placeholder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else if results.isEmpty {
                Text("settings.filters.interestedLanguages.search.empty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                List(results, id: \.self) { language in
                    Button {
                        toggleInterestedLanguageFromFilter(language)
                    } label: {
                        HStack(spacing: 8) {
                            // Menu 外的 popover 可用通用 LanguageIconView。
                            LanguageIconView(language: language, size: 16)
                            Text(language)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if isInterestedLanguage(language) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }
                .listStyle(.plain)
            }
        }
    }

    private func isInterestedLanguage(_ language: String) -> Bool {
        settings.interestedLanguages.contains {
            $0.caseInsensitiveCompare(language) == .orderedSame
        }
    }

    /// 多选追加感兴趣语言，并同步勾进当前全局语言筛选；不关闭 popover。
    private func toggleInterestedLanguageFromFilter(_ language: String) {
        if isInterestedLanguage(language) {
            settings.interestedLanguages = settings.interestedLanguages.filter {
                $0.caseInsensitiveCompare(language) != .orderedSame
            }
            let remaining = viewModel.effectiveGlobalFilterState.globalFilterLanguages.filter {
                $0.caseInsensitiveCompare(language) != .orderedSame
            }
            viewModel.setCategorizedLanguageFiltersFromUser(remaining)
        } else {
            settings.interestedLanguages = AppSettings.normalizedLanguageList(
                settings.interestedLanguages + [language]
            )
            let updated = AppSettings.normalizedLanguageList(
                viewModel.effectiveGlobalFilterState.globalFilterLanguages + [language]
            )
            viewModel.setCategorizedLanguageFiltersFromUser(updated)
        }
    }

    private func availabilityPicker(
        title: LocalizedStringKey,
        icon: String,
        selection: Binding<RepoSignalAvailabilityFilter>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            filterSectionHeader(title: title, icon: icon)

            Picker(selection: selection) {
                ForEach(RepoSignalAvailabilityFilter.allCases, id: \.self) { filter in
                    Label(availabilityFilterTitle(for: filter), systemImage: availabilityFilterIcon(for: filter, fallback: icon))
                        .tag(filter)
                }
            } label: {
                EmptyView()
            }
            .labelsHidden()
            .pickerStyle(.inline)
        }
    }

    private func filterSectionHeader(title: LocalizedStringKey, icon: String) -> some View {
        Label(title, systemImage: icon)
            .foregroundStyle(.secondary)
    }

    private func availabilityFilterTitle(for filter: RepoSignalAvailabilityFilter) -> LocalizedStringKey {
        switch filter {
        case .unknown: return "general.all"
        case .available: return "list.filter.availability.available"
        case .missing: return "list.filter.availability.missing"
        }
    }

    private func availabilityFilterIcon(for filter: RepoSignalAvailabilityFilter, fallback: String) -> String {
        switch filter {
        case .unknown: return "tray.full"
        case .available: return fallback
        case .missing: return "nosign"
        }
    }

    private func languageFilterIcon(for stat: LanguageStat) -> String {
        stat.language.isEmpty ? "questionmark.folder" : "chevron.left.forwardslash.chevron.right"
    }

    /// CodeFlow 为 Pro 能力：入口统一走权益门控，免费用户只看到付费墙。
    private func openCodeFlow(for repo: Repo) {
        do {
            try dependencies.entitlementGate.requirePro(.codeFlow)
            AppLog.ui.info("Open CodeFlow sheet repo=\(repo.fullName, privacy: .public) id=\(repo.id, privacy: .public)")
            codeFlowSheetItem = CodeGraphSheetItem(repo: repo)
        } catch {
            paywallContext = ProPaywallContext(feature: .codeFlow, message: error.localizedDescription)
        }
    }

    /// CodebaseMemory 为 Pro 能力：与 CodeFlow 同款门控。
    private func openCodebaseMemory(for repo: Repo) {
        do {
            try dependencies.entitlementGate.requirePro(.codebaseMemory)
            AppLog.ui.info("Open CodebaseMemory sheet repo=\(repo.fullName, privacy: .public) id=\(repo.id, privacy: .public)")
            codebaseMemorySheetItem = CodeGraphSheetItem(repo: repo)
        } catch {
            paywallContext = ProPaywallContext(feature: .codebaseMemory, message: error.localizedDescription)
        }
    }

    /// Chrome Companion 的 action route 运行在本机 HTTP 服务中; UI 呈现仍由页面根视图负责。
    /// 这里复用 toolbar 的门控与 sheet 承载逻辑, 避免多出一套 CodeFlow/Codebase 打开路径。
    private func handleCompanionActionRequest(_ request: CompanionActionDispatcher.Request?) {
        guard let request else { return }
        NSApp.activate(ignoringOtherApps: true)
        switch request.kind {
        case .openRepo:
            onOpenCompanionRepo?(request.repo)
        case .generateSummary:
            onGenerateCompanionSummary?(request.repo)
        case .codeflow:
            openCodeFlow(for: request.repo)
        case .codebase:
            openCodebaseMemory(for: request.repo)
        }
        dependencies.companionActionDispatcher.pendingRequest = nil
    }
}

/// Manage 行的最小观察边界。
///
/// `HomeViewModel` 的 status/library/semantic map 与两个 badge store 都只在本行 body 内读取；
/// 对应状态变化时 SwiftUI 可以只重算受影响的 row，而不是重新执行巨型 RepoListView body。
private struct ManageRepoRowContent: View {
    let repo: Repo
    let viewModel: HomeViewModel
    let aiSummaryAvailability: RepoListAISummaryAvailability
    let isSelected: Bool

    @Environment(AppDependencies.self) private var dependencies

    var body: some View {
        let project = viewModel.projectRelation(for: repo.id)
        let growth = viewModel.localStarGrowth30Days(for: repo.id)
        UnifiedRepoRow(
            card: repo.asCardData(
                inlineMetadata: project.map(projectMetadata),
                footerMetadata: growth.map(growthMetadata),
                readStatus: viewModel.readStatus(for: repo.id),
                isInLibrary: viewModel.libraryState(for: repo.id) == .inLibrary,
                openSSFScore: dependencies.openSSFScoreStore.badge(for: repo.id),
                healthBadge: dependencies.repoHealthStore.badge(for: repo.id)
            ),
            isSelected: isSelected,
            isPinned: viewModel.isRepoPinned(repo.id),
            semanticHit: viewModel.semanticHit(for: repo.id),
            showStarredCheckmark: viewModel.selection == .myProjects,
            hasAISummary: aiSummaryAvailability.contains(repo.id)
        )
    }

    /// 在 fullName 同行压成一个稳定徽章，避免为项目场景复制整张 Repo 卡片。
    private func projectMetadata(_ project: UserProject) -> RepoCardInlineMetadata {
        let affiliation: String
        let systemImage: String
        switch project.affiliation {
        case .owner:
            affiliation = String.l10n("list.filter.project.personal")
            systemImage = "person.fill"
        case .organizationMember:
            affiliation = project.ownerLogin
            systemImage = "building.2.fill"
        case .collaborator:
            affiliation = [
                String.l10n("list.filter.project.collaborator"),
                project.ownerLogin
            ].joined(separator: " · ")
            systemImage = "person.2.fill"
        }
        let visibility = String.l10n("list.filter.project.visibility.\(project.visibility.rawValue)")
        let permission = String.l10n("list.filter.project.permission.\(project.permission.rawValue)")
        return RepoCardInlineMetadata(
            systemImage: systemImage,
            text: [affiliation, visibility, permission].joined(separator: " · ")
        )
    }

    /// 30 天增长只来自本机已有历史；历史不足时 ViewModel 返回 nil，卡片不伪造 0。
    private func growthMetadata(_ growth: Int) -> RepoCardInlineMetadata {
        let value = growth > 0 ? "+\(growth.formattedShort)" : growth.formattedShort
        return RepoCardInlineMetadata(
            systemImage: growth >= 0 ? "chart.line.uptrend.xyaxis" : "chart.line.downtrend.xyaxis",
            text: String(format: String.l10n("project.card.growth30d"), value),
            tint: growth > 0 ? .green : .secondary
        )
    }
}

/// 筛选 Popover 挂载 Toggle label 时，直接使用通用 `LanguageIconView` 会让
/// 部分 SVG asset 被 AppKit 按原始矢量尺寸布局，导致图标撑爆菜单行。
/// 这里先把 NSImage 点尺寸收口到菜单需要的大小，再用固定容器裁切兜底。
private struct FilterMenuLanguageIcon: View {
    let language: String
    let size: CGFloat

    var body: some View {
        if UncategorizedLanguageKey.matches(language) {
            UncategorizedLanguageIcon(size: size)
                .frame(width: size, height: size)
                .fixedSize()
        } else {
            resolvedIcon
                .frame(width: size, height: size)
                .clipped()
                .fixedSize()
        }
    }

    @ViewBuilder
    private var resolvedIcon: some View {
        let result = LanguageIconResolver.resolve(language: language)

        switch result.type {
        case .localSVG(let assetName):
            if let image = FilterMenuLanguageIconCache.image(named: assetName, size: size) {
                Image(nsImage: image)
                    .frame(width: size, height: size)
            } else {
                fallbackBadge(colorHex: nil)
            }

        case .badge(let colorHex, _):
            fallbackBadge(colorHex: colorHex)
        }
    }

    private func fallbackBadge(colorHex: String?) -> some View {
        Circle()
            .fill(colorHex.flatMap(Color.init(hex:)) ?? .gray)
            .frame(width: size, height: size)
    }
}

/// Toolbar 语言图标的有界内存缓存。
///
/// `NSImage(named:)` + SVG copy/resize 都是同步 AppKit 工作；如果放在 popover 首次挂载
/// 路径，每个感兴趣语言都会阻塞一次主线程。缓存按 asset + 点尺寸区分，toolbar 出现时
/// 预热，语言池变化时只补新增项。
@MainActor
private enum FilterMenuLanguageIconCache {
    private static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 96
        return cache
    }()

    static func prewarm(_ languages: [String], size: CGFloat) {
        for language in languages where !UncategorizedLanguageKey.matches(language) {
            let result = LanguageIconResolver.resolve(language: language)
            if case .localSVG(let assetName) = result.type {
                _ = image(named: assetName, size: size)
            }
        }
    }

    static func image(named assetName: String, size: CGFloat) -> NSImage? {
        let key = NSString(string: "\(assetName)#\(size)")
        if let cached = images.object(forKey: key) {
            return cached
        }

        guard let base = NSImage(named: assetName) else { return nil }
        // 不允许直接改 `NSImage(named:)` 返回的共享实例，否则其他页面会继承菜单尺寸。
        guard let image = base.copy() as? NSImage else {
            images.setObject(base, forKey: key)
            return base
        }
        image.size = NSSize(width: size, height: size)
        image.isTemplate = false
        images.setObject(image, forKey: key)
        return image
    }
}

/// GitHub 组织限制 OAuth App 访问时的结构化说明。
///
/// 不使用系统 Alert：该错误不是一句失败文案能解释清楚，用户需要知道原因、影响范围和可执行处理方式。
private struct GitHubStarListOAuthRestrictionSheet: View {

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            details
            footer
        }
        .padding(22)
        .frame(width: 430)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(.orange.gradient)
                    .frame(width: 52, height: 52)
                    .shadow(color: .orange.opacity(0.28), radius: 18, x: 0, y: 8)
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("githubStarLists.error.orgOAuthRestricted.title")
                    .font(.title3.weight(.semibold))
                Text("githubStarLists.error.orgOAuthRestricted.subtitle")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            restrictionRow("exclamationmark.triangle.fill", "githubStarLists.error.orgOAuthRestricted.reason")
            restrictionRow("arrow.triangle.2.circlepath", "githubStarLists.error.orgOAuthRestricted.impact")
            restrictionRow("safari.fill", "githubStarLists.error.orgOAuthRestricted.githubOption")
            restrictionRow("person.badge.shield.checkmark.fill", "githubStarLists.error.orgOAuthRestricted.adminOption")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("githubStarLists.error.orgOAuthRestricted.note")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("common.close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func restrictionRow(_ systemImage: String, _ key: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.orange)
                .frame(width: 20)
            Text(key)
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 带可见顺序的 repo 包装。
///
/// `id` 仍然来自 repo.id，保证 SwiftUI row identity 不受下标影响；index 只用于计算
/// 入场 delay，避免排序后因为下标变化破坏选中 / 复用语义。
private struct IndexedRepo: Identifiable {
    let index: Int
    let repo: Repo

    var id: Int64 { repo.id }
}
