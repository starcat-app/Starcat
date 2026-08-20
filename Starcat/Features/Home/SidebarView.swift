//
//  SidebarView.swift
//  Starcat
//
//  左栏：侧边栏。
//
//  Week 3 三个分组：
//  - 主：All Stars / Untagged
//  - Languages：按语言聚合，每项带计数
//
//  设计约束：
//  - 不直接做查询，数据来自 HomeViewModel
//  - 用 NavigationSplitView 的 selection binding 与 ViewModel 联动
//  - Languages 行点击 → 设置 selection 为 .language(lang)
//

import SwiftUI

/// GitHub Stars List 编辑器 Sheet 载荷。
///
/// 使用 `sheet(item:)` 而不是 `sheet(isPresented:) + 另一个 @State list`：
/// SwiftUI 首次构建 sheet 内容时可能先看到 isPresented=true，但另一个 state 还没完成同帧更新，
/// 导致编辑分组第一次被当成新增分组初始化。把 list 放进 item 本身可消除这个首帧竞态。
private struct GitHubStarListEditorItem: Identifiable {
    let id = UUID()
    let list: GitHubStarList?
}

/// 探索页左侧列表的系统选中项。
///
/// 星标模块依赖 `List(selection:) + .tag(...)` 让 macOS 绘制原生 sidebar 选中条；
/// 探索页也复用同一机制，而不是在 row 内手写浅蓝背景。这个 enum 只描述“哪个探索行
/// 应被系统高亮”，真正的业务筛选状态仍保留在 `selectedExploreMode` /
/// `selectedDiscoveryTopic` / `selectedDiscoveryPlatform` / `selectedDiscoveryLanguage`
/// / `selectedWeeklyLanguage` 等现有 binding 中，避免把视觉选中态改成新的数据源。
private enum ExploreSidebarSelection: Hashable {
    case mode(ExploreMode)
    case topic(String?)
    case platform(String?)
    case language(String?)
    case trendingLanguage(TrendingLanguage)
    case weeklyLanguage(String?)
}

/// 探索侧栏图标色：未选中用语义色；明亮主题选中时跟系统蓝底反成白色。
///
/// 实现已收口到共享 `SidebarSemanticIconStyle`（星标 / 活动等 SF Symbol 行共用）。
/// 语言 Devicon 不走反白，见 `LanguageIconView` 选中白底托盘。
typealias ExploreSidebarIconStyle = SidebarSemanticIconStyle

struct SidebarView: View {

    @Environment(HomeViewModel.self) private var viewModel
    @Environment(AuthSession.self) private var authSession
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.openSettings) private var openSettings
    /// 系统级"减少动效"开关。开启时把 spring 折叠动画退化为瞬切，避免给晕动症 / 偏好
    /// 静态界面的用户增加负担。与项目内 `ListRowRevealModifier` / `RepoLocalSections`
    /// / `SmartSearchField` 等动画路径处理方式一致。
    @Environment(\.starcatReduceMotion) private var reduceMotion
    /// HOM-126：自动整理调度器。Sidebar 底部观察 `isAutoTidyRunning` 决定是否
    /// 显示「AI 自动整理中 N/M」轻量行；点击 / hover 可查看 popover 详情。
    @Environment(AutoTidyScheduler.self) private var autoTidyScheduler
    /// Activity 分类计数徽章数据源。
    /// Weekly 已迁移到 Explore,这里只读 ActivityViewModel 已发布的本地分类统计，
    /// 不在 sidebar 里主动触发任何加载。
    @Environment(AppDependencies.self) private var dependencies

    /// 当前打开/收起 Languages 组的状态。
    @State private var languagesExpanded: Bool = true
    /// W4 A6：Tags 组展开/收起状态，由主窗口持有以支持跨窗口导航后展开。
    /// 默认 **折叠**（2026-06-11 dong4j 体验优化）：tag 数量多时全展开会挤掉
    /// Languages / Activity / Trending 等同级 section 的视觉权重，初始折叠让用户
    /// 一眼看到全局结构，需要时再展开。会话内不持久化，重启 App 后仍回到折叠默认值。
    @Binding var tagsExpanded: Bool
    /// GitHub Stars List（Repository groups）展开/收起状态。默认折叠，与 Tags 一致。
    @State private var githubStarListsExpanded: Bool = false
    /// Trending 语言列表展开/收起状态。和 Manage 的 Languages 分开，避免互相影响。
    @State private var trendingLanguagesExpanded: Bool = true
    /// Explore 发现模块主题分类展开/收起状态。
    @State private var exploreTopicsExpanded: Bool = true
    /// Explore 发现模块平台分类展开/收起状态。
    @State private var explorePlatformsExpanded: Bool = true
    /// Activity 分类列表展开/收起状态。Activity 是独立 root，不能复用 Trending 的展开态。
    @State private var activityCategoriesExpanded: Bool = true

    @Binding var selectedPage: SidebarRootPage
    @Binding var selectedExploreMode: ExploreMode
    @Binding var selectedTrendingLanguage: TrendingLanguage
    @Binding var selectedDiscoveryLanguage: String?
    @Binding var selectedDiscoveryTopic: String?
    @Binding var selectedDiscoveryPlatform: String?
    @Binding var selectedWeeklyLanguage: String?
    @Binding var selectedActivityCategory: ActivityCategory
    /// 洞察中心二级主题。只负责左栏选择，不在 Sidebar 内持有统计数据。
    @Binding var selectedInsightsTopic: InsightsTopic
    @Binding var showTagManagement: Bool
    /// HOM-47：触发 Release 时间线 sheet。
    @Binding var showReleaseTimeline: Bool
    /// Root page 切换允许 HomeView 在写入 `selectedPage` 前先准备跨页状态。
    ///
    /// 这里保持 Sidebar 只表达“用户想切到哪个 root page”，真正的 Manage /
    /// Trending 状态恢复仍由 HomeView 统一处理，避免 Sidebar 持有 saved selection。
    var onSelectRootPage: ((SidebarRootPage) -> Void)?
    /// HOM-126 follow-up：Sidebar 自动整理 popover 的「查看队列」入口。
    /// 由 HomeView 承载 sheet 状态，Sidebar 只发起动作，避免左栏持有批量整理面板。
    var onShowBatchAIPanel: (() -> Void)?
    /// 后台单仓摘要点击后，由 HomeView 负责切换到目标 repo 并展开摘要面板。
    var onOpenSummaryTask: ((Repo) -> Void)?

    /// 当前在 Trending 页面选中的 repo，仅用于透传给 `SidebarHeaderView` 让头像背景的
    /// 语言色在 Trending 页也能联动（2026-06-02 21:38 接入）。Manage 页面应为 nil。
    /// 真源在 `HomeView.@State selectedTrendingRepo`，通过普通参数（非 binding）透传。
    var currentTrendingRepo: TrendingRepo?
    /// 当前 Activity 选中卡片的强调色，透传给顶部头像卡背景。
    ///
    /// 只传最终颜色而不传 `ActivityItem`，避免 Sidebar 需要理解 Activity 的详情模型。
    var currentActivityTintColor: Color?

    /// HOM-73：控制登录 sheet 的显示。
    @State private var showLoginSheet: Bool = false
    /// 底部状态条 popover：承载自动/手动整理详情，以及面板已关闭的单仓摘要任务列表。
    @State private var showBackgroundTaskPopover: Bool = false
    /// popover 内摘要任务行的 hover 高亮；用 id 而不是 index，避免列表刷新时错位。
    @State private var hoveredSummaryTaskID: RepoAISummaryBackgroundTask.ID?
    /// GitHub Stars List 创建 / 编辑 Sheet。
    @State private var gitHubStarListEditorItem: GitHubStarListEditorItem?
    /// “我的项目”独立授权和同步状态 Sheet。
    @State private var showProjectAccessSheet = false
    /// 探索页当前由系统 `List(selection:)` 高亮的行。
    ///
    /// 探索页可能同时保留“当前模式”和“当前筛选项”两类业务状态；系统 sidebar 选中条
    /// 应只有一条。因此这里记录用户最后点击的探索行，让视觉行为与星标模块一样走
    /// 系统 selection，同时不强行清空已有筛选状态。
    @State private var exploreListSelection: ExploreSidebarSelection?
    /// 顶部三入口点击反馈。用计数 token 驱动 symbolEffect，避免把动效状态混进业务 selection。
    @State private var rootNavigationBounceTokens: [SidebarRootPage: Int] = [:]

    /// row() / tagRow() 内 trailing 区域（sync icon + count）的**整体固定宽度**（pt）。
    ///
    /// 2026-06-06 抖动**三次**修复（这次彻底）：
    ///
    /// 演进史：
    /// - v1：count Text 没保护 → 数字溢出 sidebar 右沿
    /// - v2：count Text 加 `.fixedSize(horizontal: true)` + trailing HStack 整体 `.fixedSize`
    ///   → 修了溢出和同位数同步累加抖动，但**漏掉跨位数（9 → 10、999 → 1000）抖动**
    /// - v3：count Text 改 `.frame(minWidth: 40, alignment: .trailing)` 配合外层
    ///   `.fixedSize` → 跨位数不抖了，**但** List selection 切换时 SwiftUI 在
    ///   `fixedSize`+`minWidth` 的双约束下做 layout 重测，反复在 ideal 和 minimum
    ///   之间插值，引发"切到 Languages 后 All Stars 数字闪烁 / 切回 All Stars 后
    ///   数字从右往左反复移动"的新现象（dong4j 2026-06-06 21:09 反馈）
    /// - **v4（当前）**：放弃 `fixedSize` + `minWidth` 的组合，直接把 trailing 整体
    ///   用 `.frame(width:, alignment: .trailing)` 锁死。内部用 `Spacer` 把 sync icon
    ///   推到左、count 推到右；不管 count 几位、不管 sync icon 是否显示，trailing
    ///   容器对外宽度永远是这个常量值，外部 layout 完全感知不到内部变化 → 100% 不抖。
    ///
    /// 关键 lesson：`fixedSize` 在 List 内不可靠——List 会因 selection / inset / scroll
    /// 等多种原因在 row 上反复发起 layout 测量，`fixedSize` 子树的"ideal width"
    /// 每次测量都会被重新求值，如果该 ideal 不是真正常量（如依赖 Text 内容长度）
    /// 就会反复插值。**真正常量化的方式只有 `.frame(width:)` 锁死整个外层容器。**
    ///
    /// 数值 60 的取值依据：sync icon(18) + spacing(4) + count Text 预留宽度(38) ≈ 60pt。
    /// 38pt 在 `.caption` + `monospacedDigit` 下能容纳 "99,999" 等 6 字符（5 位数 + 千分位
    /// 逗号），对绝大多数 starred 数都够。超过时 Text 会被截到 60pt 容器内，但实际
    /// 用户超过 100,000 stars 概率极低，不需要为此牺牲稳定性。
    private static let trailingFixedWidth: CGFloat = 60

    // MARK: - 折叠动画规格（2026-06-11 dong4j 体验优化：对齐 Xcode 文件树的丝滑感）

    /// Sidebar 折叠/展开统一动画曲线。
    ///
    /// 选用 `.spring(response: 0.28, dampingFraction: 0.86)` 的依据：
    /// - 与 `Starcat/Shared/Components/RepoLocalSections.swift` 三段
    ///   `.spring(response: 0.25, dampingFraction: 0.85)` 同族,保证全 App 的"展开/收起"
    ///   节奏一致(都是"短促 spring + 微回弹")。
    /// - response 比 RepoLocalSections 略放宽到 0.28s：sidebar 折叠的内容比详情页三段
    ///   更细粒度(单条行 ~28pt 高,每个 section 可能十几行),稍长一点能让 row 的
    ///   move transition 看得清,而不是"几乎瞬切"。
    /// - dampingFraction 0.86：相比纯 easeInOut 会有~3% 的回弹幅度,刚好让 chevron 旋转和
    ///   行滑出有一点物理感,但不会"晃动两下"。Xcode 文件树的折叠也是这种感觉。
    ///
    /// 历史：2026-06-11 之前用 `.easeInOut(duration: 0.2)`,体验偏"硬"且 chevron / 行
    /// 用同曲线但 List 内 row insertion 默认动画并未被替换 → 视觉上 chevron 转完了但行
    /// 还在缓慢淡入,节奏脱节。改 spring 后曲线统一,且与项目内其他展开/收起动画对齐。
    private static let disclosureSpring: Animation = .spring(response: 0.28, dampingFraction: 0.78)

    /// 被折叠的 row(languageRow / trendingLanguageRow / activityCategoryRow / TagWallView)
    /// 入场/出场 transition：从顶部滑入 + 淡入,出场反向。
    ///
    /// 与 `RepoLocalSections.swift` 三段的 transition 完全一致(`.move(edge: .top).combined(with: .opacity)`),
    /// 视觉语言统一。macOS 上 SwiftUI `List(.sidebar)` 对 row `.transition` 的支持自
    /// macOS 14 起趋于稳定,实测 macOS 15+ 上 row 滑入/滑出和 chevron 旋转能精准同步。
    ///
    /// 注：这个 transition 必须与 `withAnimation(disclosureSpring)` 配合才会用 spring
    /// 曲线播放;否则 SwiftUI 会用默认曲线,效果退化为单纯的 fade。
    private static let disclosureRowTransition: AnyTransition =
        .move(edge: .top).combined(with: .opacity)

    /// 根据 reduceMotion 返回应使用的动画(开启时返回 nil 让 SwiftUI 瞬切)。
    private var disclosureAnimation: Animation? {
        reduceMotion ? nil : Self.disclosureSpring
    }

    var body: some View {
        VStack(spacing: 0) {
            sidebarFixedHeader
            sidebarList
            // 后台任务区统一承载自动/手动整理与面板已关闭的单仓摘要。
            // 手动整理会抢占本轮自动整理，因此两者不会同时出现。
            backgroundTaskFooter
        }
        .background(.bar)
        .sheet(isPresented: $showLoginSheet) {
            GithubAuthView()
                .appLocaleEnvironment()
        }
        .sheet(item: $gitHubStarListEditorItem) { item in
            GitHubStarListEditorSheet(
                list: item.list,
                service: dependencies.githubStarListSyncService,
                onSaved: {
                    await viewModel.refreshSidebar()
                    await viewModel.reloadItems(forceRefresh: true)
                }
            )
            .appLocaleEnvironment()
        }
        .sheet(isPresented: $showProjectAccessSheet) {
            ProjectAccessSheet {
                // 授权 / 同步后关系表可能新增 Private 仓库：先清快照，再按需重查中栏。
                viewModel.invalidateDatabaseSnapshotsForMyProjectsChange()
                await viewModel.refreshSidebar()
                if viewModel.selection == .myProjects {
                    await viewModel.reloadItems(forceRefresh: true, reason: .sync)
                }
            }
            .appLocaleEnvironment()
        }
        .onChange(of: hasAnyBackgroundTask) { _, hasTask in
            if !hasTask {
                showBackgroundTaskPopover = false
            }
        }
    }

    // MARK: - 底部后台任务状态条

    /// 是否有需要在侧栏底栏展示的后台任务。
    ///
    /// 手动整理会抢占本轮自动整理，因此 `isManualBatchRunning` 与
    /// `isAutoTidyRunning` 不会同时为 true；摘要任务可与整理并存。
    private var isManualBatchRunning: Bool {
        let service = dependencies.batchAIQueueService
        return service.isRunning && !service.silent
    }

    private var summaryBackgroundTasks: [RepoAISummaryBackgroundTask] {
        dependencies.repoAIInsightSessionStore.backgroundTasks
    }

    private var hasAnyBackgroundTask: Bool {
        isManualBatchRunning
            || autoTidyScheduler.isAutoTidyRunning
            || !summaryBackgroundTasks.isEmpty
    }

    /// 底栏只放一条紧凑状态行；详情（整理进度 / 摘要列表）一律进 popover。
    ///
    /// 对齐原「AI 自动整理中 N/M」：侧栏不膨胀成任务列表；
    /// **仅点击**状态行才展开详情（不做 hover 自动弹出），点击摘要行再跳回对应仓库。
    @ViewBuilder
    private var backgroundTaskFooter: some View {
        if hasAnyBackgroundTask {
            Button {
                showBackgroundTaskPopover.toggle()
            } label: {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 12, height: 12)
                    Text(backgroundTaskStatusText)
                        .font(interfaceScale.font(.captionSmall))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .monospacedDigit()
                    Spacer(minLength: 0)
                    Image(systemName: "info.circle")
                        .font(interfaceScale.font(.captionSmall, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.06))
            .help(Text(backgroundTaskTooltipKey))
            .popover(isPresented: $showBackgroundTaskPopover, arrowEdge: .bottom) {
                backgroundTaskPopover
                    .appLocaleEnvironment()
            }
            .transition(reduceMotion ? .identity : .move(edge: .bottom).combined(with: .opacity))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: hasAnyBackgroundTask)
        }
    }

    private var backgroundTaskStatusText: String {
        let summaryCount = summaryBackgroundTasks.count
        if isManualBatchRunning {
            let service = dependencies.batchAIQueueService
            let tidy = String(
                format: String.l10n("sidebar.background.manual.runningFormat"),
                service.finishedCount,
                service.totalCount
            )
            if summaryCount > 0 {
                return String(
                    format: String.l10n("sidebar.background.combinedFormat"),
                    tidy,
                    summaryCount
                )
            }
            return tidy
        }
        if autoTidyScheduler.isAutoTidyRunning {
            let tidy = String(
                format: String.l10n("sidebar.autoTidy.runningFormat"),
                autoTidyScheduler.autoTidyProgressText
            )
            if summaryCount > 0 {
                return String(
                    format: String.l10n("sidebar.background.combinedFormat"),
                    tidy,
                    summaryCount
                )
            }
            return tidy
        }
        if summaryCount == 1, let only = summaryBackgroundTasks.first {
            return String(
                format: String.l10n("sidebar.background.summary.singleFormat"),
                only.repo.fullName
            )
        }
        return String(
            format: String.l10n("sidebar.background.summary.countFormat"),
            summaryCount
        )
    }

    private var backgroundTaskTooltipKey: LocalizedStringKey {
        if isManualBatchRunning {
            return "sidebar.background.manual.tooltip"
        }
        if autoTidyScheduler.isAutoTidyRunning {
            return "sidebar.autoTidy.tooltip"
        }
        return "sidebar.background.summary.tooltip"
    }

    private var backgroundTaskPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
                Text(backgroundTaskPopoverTitleKey)
                    .font(interfaceScale.font(.body))
                Spacer()
                Button {
                    showBackgroundTaskPopover = false
                } label: {
                    Image(systemName: "xmark")
                        .font(interfaceScale.font(.captionSmall, weight: .semibold))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }

            if isManualBatchRunning {
                manualBatchPopoverSection
            } else if autoTidyScheduler.isAutoTidyRunning {
                autoTidyPopoverSection
            }

            if !summaryBackgroundTasks.isEmpty {
                if isManualBatchRunning || autoTidyScheduler.isAutoTidyRunning {
                    Divider()
                }
                summaryTasksPopoverSection
            }
        }
        .padding(14)
        .frame(width: 290)
    }

    private var backgroundTaskPopoverTitleKey: LocalizedStringKey {
        if isManualBatchRunning {
            "sidebar.background.manual.popover.title"
        } else if autoTidyScheduler.isAutoTidyRunning {
            "sidebar.autoTidy.popover.title"
        } else {
            "sidebar.background.summary.popover.title"
        }
    }

    private var manualBatchPopoverSection: some View {
        let service = dependencies.batchAIQueueService
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(
                    value: Double(service.finishedCount),
                    total: Double(max(service.totalCount, 1))
                )
                Text(String(
                    format: String.l10n("sidebar.autoTidy.popover.progressFormat"),
                    service.finishedCount,
                    service.totalCount
                ))
                .font(interfaceScale.font(.captionSmall))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }

            // 与自动整理同一套三卡片口径：已应用 / 已忽略 / 失败。
            HStack(spacing: 8) {
                autoTidyCounter(
                    title: "sidebar.autoTidy.popover.completed",
                    count: service.completedCount,
                    color: .green,
                    backgroundOpacity: 0.12
                )
                autoTidyCounter(
                    title: "sidebar.autoTidy.popover.ignored",
                    count: service.ignoredCount,
                    color: .secondary,
                    backgroundOpacity: 0.08
                )
                autoTidyCounter(
                    title: "sidebar.autoTidy.popover.failed",
                    count: service.failedCount,
                    color: .red,
                    backgroundOpacity: 0.12
                )
            }

            HStack(spacing: 8) {
                Button {
                    showBackgroundTaskPopover = false
                    onShowBatchAIPanel?()
                } label: {
                    Label("sidebar.autoTidy.popover.viewQueue", systemImage: "rectangle.stack")
                }

                Button {
                    showBackgroundTaskPopover = false
                    openAISettings()
                } label: {
                    Label("sidebar.autoTidy.popover.openAISettings", systemImage: "gearshape")
                }
            }
            .controlSize(.small)
        }
    }

    private var autoTidyPopoverSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(
                    value: Double(autoTidyScheduler.autoTidyFinishedCount),
                    total: Double(max(autoTidyScheduler.autoTidyTotalCount, 1))
                )
                Text(String(
                    format: String.l10n("sidebar.autoTidy.popover.progressFormat"),
                    autoTidyScheduler.autoTidyFinishedCount,
                    autoTidyScheduler.autoTidyTotalCount
                ))
                .font(interfaceScale.font(.captionSmall))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }

            HStack(spacing: 8) {
                autoTidyCounter(
                    title: "sidebar.autoTidy.popover.completed",
                    count: autoTidyScheduler.autoTidyCompletedCount,
                    color: .green,
                    backgroundOpacity: 0.12
                )
                autoTidyCounter(
                    title: "sidebar.autoTidy.popover.ignored",
                    count: autoTidyScheduler.autoTidyIgnoredCount,
                    color: .secondary,
                    backgroundOpacity: 0.08
                )
                autoTidyCounter(
                    title: "sidebar.autoTidy.popover.failed",
                    count: autoTidyScheduler.autoTidyFailedCount,
                    color: .red,
                    backgroundOpacity: 0.12
                )
            }

            HStack(spacing: 8) {
                Button {
                    showBackgroundTaskPopover = false
                    onShowBatchAIPanel?()
                } label: {
                    Label("sidebar.autoTidy.popover.viewQueue", systemImage: "rectangle.stack")
                }

                Button {
                    showBackgroundTaskPopover = false
                    openAISettings()
                } label: {
                    Label("sidebar.autoTidy.popover.openAISettings", systemImage: "gearshape")
                }
            }
            .controlSize(.small)
        }
    }

    private var summaryTasksPopoverSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 与上方「AI 自动整理」标题行对齐：图标 + 文案，避免分组看起来像纯文字标签。
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .foregroundStyle(.purple)
                Text("sidebar.background.summary.section")
                    .font(interfaceScale.font(.captionSmall, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(summaryBackgroundTasks.enumerated()), id: \.element.id) { index, task in
                        summaryTaskRow(task, rowIndex: index)
                    }
                }
            }
            .frame(maxHeight: 160)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    /// 摘要任务行：斑马纹便于扫读多仓并发；hover 用 accent 浅底提示可点。
    private func summaryTaskRow(
        _ task: RepoAISummaryBackgroundTask,
        rowIndex: Int
    ) -> some View {
        let isHovered = hoveredSummaryTaskID == task.id
        return Button {
            showBackgroundTaskPopover = false
            onOpenSummaryTask?(task.repo)
        } label: {
            HStack(spacing: 8) {
                summaryTaskIcon(task.state)
                    .frame(width: 14, height: 14)

                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: task.repo.fullName)
                        .font(interfaceScale.font(.captionSmall, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(summaryTaskStatusKey(task.state))
                        .font(interfaceScale.font(.captionSmall))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(interfaceScale.font(.captionSmall, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(summaryTaskRowBackground(isHovered: isHovered, rowIndex: rowIndex))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering in
            hoveredSummaryTaskID = hovering ? task.id : nil
        }
        .onDisappear {
            if hoveredSummaryTaskID == task.id {
                hoveredSummaryTaskID = nil
            }
        }
        .help(Text("sidebar.background.summary.tooltip"))
    }

    /// 斑马纹用 primary 极低透明；hover 优先于斑马纹，避免明暗主题下交替色被盖没。
    private func summaryTaskRowBackground(isHovered: Bool, rowIndex: Int) -> Color {
        if isHovered {
            return Color.accentColor.opacity(0.10)
        }
        return rowIndex.isMultiple(of: 2) ? .clear : Color.primary.opacity(0.045)
    }

    @ViewBuilder
    private func summaryTaskIcon(_ state: RepoAISummaryBackgroundTask.State) -> some View {
        switch state {
        case .running:
            ProgressView()
                .controlSize(.mini)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private func summaryTaskStatusKey(
        _ state: RepoAISummaryBackgroundTask.State
    ) -> LocalizedStringKey {
        switch state {
        case .running:
            "sidebar.background.summary.running"
        case .completed:
            "sidebar.background.summary.completed"
        case .failed:
            "sidebar.background.summary.failed"
        }
    }

    private func autoTidyCounter(
        title: LocalizedStringKey,
        count: Int,
        color: Color,
        backgroundOpacity: Double
    ) -> some View {
        VStack(spacing: 2) {
            Text(verbatim: "\(count)")
                .font(interfaceScale.font(.body, weight: .semibold).monospacedDigit())
                .foregroundStyle(color)
            Text(title)
                .font(interfaceScale.font(.captionSmall))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(color.opacity(backgroundOpacity), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func openAISettings() {
        openSettings()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .starcatJumpToSettingsTab, object: "ai")
        }
    }

    /// Sidebar 固定顶部区：用户卡 + 贡献草坪 + 一级入口。
    ///
    /// 这里不再用 `safeAreaInset`，因为新增一级入口后列表滚动内容会进入 inset 区域下方，
    /// 视觉上和入口行重叠。固定 header 与下方 List 分开布局，可以让滚动边界由 SwiftUI
    /// 正常计算，同时统一背景材质，避免统计数据与入口行之间出现色差。
    ///
    /// HOM-PROFILE 2026-06-05：在 rootNavigationBar 上方插入贡献草坪。
    /// 仅当已登录时显示（未登录拿不到 user.login，也没必要展示）。
    private var sidebarFixedHeader: some View {
        VStack(spacing: 0) {
            SidebarHeaderView(
                trendingRepo: currentTrendingRepo,
                activityTintColor: currentActivityTintColor
            )

            // 贡献草坪：与 Activity 选中/tint 完全解耦；固定 id 保持 TimelineView identity。
            SidebarContributionGraphSection()
                .id("sidebar-contribution-graph")

            rootNavigationBar
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 8)
        }
        .background(.bar)
    }

    private var exploreSidebarSelectionBinding: Binding<ExploreSidebarSelection?> {
        Binding {
            if let exploreListSelection,
               isExploreSelectionCurrent(exploreListSelection) {
                return exploreListSelection
            }
            return defaultExploreSidebarSelection
        } set: { newSelection in
            guard let newSelection else { return }
            exploreListSelection = newSelection
            applyExploreSelection(newSelection)
        }
    }

    private var defaultExploreSidebarSelection: ExploreSidebarSelection {
        switch selectedExploreMode {
        case .discover:
            if let selectedDiscoveryTopic {
                return .topic(selectedDiscoveryTopic)
            }
            if let selectedDiscoveryPlatform {
                return .platform(selectedDiscoveryPlatform)
            }
            return .mode(.discover)
        case .popular, .newReleases:
            if let selectedDiscoveryLanguage {
                return .language(selectedDiscoveryLanguage)
            }
            return .mode(selectedExploreMode)
        case .trending:
            return .trendingLanguage(selectedTrendingLanguage)
        case .weekly:
            return .weeklyLanguage(selectedWeeklyLanguage)
        }
    }

    private func isExploreSelectionCurrent(_ selection: ExploreSidebarSelection) -> Bool {
        switch selection {
        case .mode(let mode):
            return selectedExploreMode == mode
        case .topic(let code):
            return selectedExploreMode == .discover && selectedDiscoveryTopic == code
        case .platform(let code):
            return selectedExploreMode == .discover && selectedDiscoveryPlatform == code
        case .language(let key):
            return selectedExploreMode != .discover
                && selectedExploreMode != .trending
                && selectedExploreMode != .weekly
                && selectedDiscoveryLanguage == key
        case .trendingLanguage(let language):
            return selectedExploreMode == .trending && selectedTrendingLanguage == language
        case .weeklyLanguage(let key):
            return selectedExploreMode == .weekly && selectedWeeklyLanguage == key
        }
    }

    private func applyExploreSelection(_ selection: ExploreSidebarSelection) {
        switch selection {
        case .mode(let mode):
            guard selectedExploreMode != mode else { return }
            selectedExploreMode = mode
        case .topic(let code):
            selectedExploreMode = .discover
            selectedDiscoveryTopic = code
        case .platform(let code):
            selectedExploreMode = .discover
            selectedDiscoveryPlatform = code
        case .language(let key):
            selectedDiscoveryLanguage = key
        case .trendingLanguage(let language):
            selectedExploreMode = .trending
            selectedTrendingLanguage = language
        case .weeklyLanguage(let key):
            selectedExploreMode = .weekly
            selectedWeeklyLanguage = key
        }
    }

    @ViewBuilder
    private var sidebarList: some View {
        @Bindable var vm = viewModel

        switch selectedPage {
        case .manage:
            List(selection: $vm.selection) {
                manageSidebarContent
            }
            .listStyle(.sidebar)
        case .trending:
            List(selection: exploreSidebarSelectionBinding) {
                exploreModeSidebarContent
                exploreSidebarContent
            }
            .listStyle(.sidebar)
            // 分类行自身挂有折叠/展开 transition；切 Explore mode 时不能复用
            // List(selection:) 的系统选中动画，否则旧筛选 section 退场与新 section
            // 入场会连续触发整窗 layout。手动点 header 的 disclosureSpring 是另一笔
            // transaction，不受这里影响。
            .transaction(value: selectedExploreMode) { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        case .activity:
            List(selection: $selectedActivityCategory) {
                activitySidebarContent
            }
            .listStyle(.sidebar)
        case .insights:
            List(selection: $selectedInsightsTopic) {
                insightsSidebarContent
            }
            .listStyle(.sidebar)
        }
    }

    /// 洞察主题继续使用系统 Sidebar selection，不手绘选中背景。
    @ViewBuilder
    private var insightsSidebarContent: some View {
        Section("insights.sidebar.section") {
            ForEach(InsightsTopic.allCases) { topic in
                Label {
                    Text(topic.titleKey)
                        .lineLimit(1)
                } icon: {
                    // 与星标 / 探索 / 活动侧栏一致：未选中保留语义色，明亮选中反白。
                    Image(systemName: topic.systemImage)
                        .foregroundStyle(
                            SidebarSemanticIconStyle(semanticColor: topic.semanticIconColor)
                        )
                }
                .tag(topic)
            }
        }
    }

    @ViewBuilder
    private var manageSidebarContent: some View {
        if authSession.state.isAuthenticated {
            Section("sidebar.mainNavigation") {
                myProjectsRow
                row(.allStars, count: viewModel.totalCount)
                row(.untagged, count: viewModel.untaggedCount)
                row(.library, count: viewModel.libraryCount)
                row(.smartCollectionsHome, count: SmartCollectionKind.allCases.count + viewModel.userSmartCollections.count)
                // HOM-47：Release 时间线入口（独立 sheet 承载，避免与三栏导航 selection 冲突）
                releaseTimelineRow
            }

            Section {
                if githubStarListsExpanded {
                    githubStarListUngroupedRow
                        .transition(Self.disclosureRowTransition)
                    ForEach(viewModel.githubStarLists) { list in
                        githubStarListRow(list)
                            .transition(Self.disclosureRowTransition)
                    }
                }
            } header: {
                githubStarListSectionHeader
            }

            // W4 A6：Tags 段。
            // HOM-179：改为标签墙形式，横向排列自动换行；多选 OR 过滤。
            // HOM-43：折叠按钮始终可见，不依赖 hover；图标在右侧；点击整个区域可折叠
            // 2026-06-11：TagWallView 加 disclosureRowTransition,折叠时整块标签墙
            // 从顶部滑入 + 淡入,与 RepoLocalSections 三段的展开节奏对齐。
            Section {
                if tagsExpanded && !viewModel.tags.isEmpty {
                    TagWallView(
                        tags: viewModel.tags,
                        tagCounts: viewModel.tagCounts,
                        selectedTagIds: viewModel.selectedTagIds,
                        onTagTap: { tagId in
                            viewModel.toggleSelectedTag(tagId)
                        }
                    )
                    .transition(Self.disclosureRowTransition)
                }
            } header: {
                tagSectionHeader
            }

            if !viewModel.languageStats.isEmpty {
                // HOM-43：折叠按钮始终可见，不依赖 hover；图标在右侧；点击整个区域可折叠
                // 2026-06-11：每行加 disclosureRowTransition,展开时逐行从顶部滑入。
                // List 内 row .transition 在 macOS 14+ 趋于稳定,与 chevron 旋转 + spring
                // 节奏完全同步,接近 Xcode 文件树的体验。
                Section {
                    allLanguagesRow

                    if languagesExpanded {
                        ForEach(viewModel.languageStats) { stat in
                            languageRow(stat)
                                .transition(Self.disclosureRowTransition)
                        }
                    }
                } header: {
                    languageSectionHeader
                }
            }
        } else {
            Section {
                Text("sidebar.loginPrompt")
                    .font(interfaceScale.font(.caption))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private var exploreModeSidebarContent: some View {
        Section("nav.trending") {
            ForEach(ExploreMode.allCases) { mode in
                exploreModeRow(mode)
            }
        }
    }

    private func exploreModeRow(_ mode: ExploreMode) -> some View {
        exploreSelectableRow(
            selection: .mode(mode),
            count: exploreModeCount(mode)
        ) {
            exploreSidebarSystemIcon(mode.systemImage, color: mode.sidebarIconColor)
        } title: {
            HStack(spacing: 5) {
                Text(mode.titleKey)
                    .lineLimit(1)
                // 信息按钮紧跟分类名，计数仍由外层 row 固定在最右侧，避免五行对齐被打散。
                ExploreModeInfoButton(mode: mode)
            }
        }
    }

    private func exploreModeCount(_ mode: ExploreMode) -> Int? {
        switch mode {
        case .trending:
            return dependencies.trendingLanguageStore.sidebarTotalCount
        case .discover, .popular, .newReleases:
            return dependencies.exploreCatalogStore.total(for: mode)
        case .weekly:
            return dependencies.weeklySelectionService.total
        }
    }

    @ViewBuilder
    private var exploreSidebarContent: some View {
        switch selectedExploreMode {
        case .discover:
            exploreDiscoverySidebarContent
        case .popular, .newReleases:
            exploreLanguageSidebarContent
        case .trending:
            trendingSidebarContent
        case .weekly:
            weeklyLanguageSidebarContent
        }
    }

    @ViewBuilder
    private var exploreDiscoverySidebarContent: some View {
        Section {
            exploreTopicRow(nil)

            if exploreTopicsExpanded {
                ForEach(dependencies.exploreCatalogStore.displayTopics) { topic in
                    exploreTopicRow(topic)
                        .transition(Self.disclosureRowTransition)
                }
            }
        } header: {
            exploreTopicSectionHeader
        }

        Section {
            explorePlatformRow(nil)

            if explorePlatformsExpanded {
                ForEach(dependencies.exploreCatalogStore.displayPlatforms) { platform in
                    explorePlatformRow(platform)
                        .transition(Self.disclosureRowTransition)
                }
            }
        } header: {
            explorePlatformSectionHeader
        }
    }

    @ViewBuilder
    private var exploreLanguageSidebarContent: some View {
        Section {
            exploreLanguageRow(nil)

            if trendingLanguagesExpanded {
                ForEach(dependencies.exploreCatalogStore.displayLanguages(for: selectedExploreMode)) { language in
                    exploreLanguageRow(language)
                        .transition(Self.disclosureRowTransition)
                }
            }
        } header: {
            exploreLanguageSectionHeader
        }
    }

    @ViewBuilder
    private var trendingSidebarContent: some View {
        Section {
            trendingLanguageRow(.all, count: exploreModeCount(.trending))

            if trendingLanguagesExpanded {
                // 2026-06-11 改造：列表数据从后端 `/api/v1/languages` 聚合而来（含 __uncategorized__）。
                // 后端返空 / 不可达时 store 内部自动退化到 fallbackList，所以这里 displayList 永远非空。
                // disclosureRowTransition：每行折叠/展开时从顶部滑入 + 淡入,与 chevron 旋转 spring 同步。
                ForEach(dependencies.trendingLanguageStore.displayList, id: \.key) { agg in
                    let language = agg.asTrendingLanguage
                    // count = 0 时不展示数字（fallback 列表 / 后端尚未返回时）；> 0 才展示
                    trendingLanguageRow(language, count: agg.count > 0 ? agg.count : nil)
                        .transition(Self.disclosureRowTransition)
                }
            }
        } header: {
            trendingLanguageSectionHeader
        }
    }

    @ViewBuilder
    private var weeklyLanguageSidebarContent: some View {
        Section {
            weeklyLanguageRow(nil)

            if trendingLanguagesExpanded {
                ForEach(dependencies.weeklyLanguageStore.displayList, id: \.key) { aggregate in
                    weeklyLanguageRow(aggregate)
                        .transition(Self.disclosureRowTransition)
                }
            }
        } header: {
            weeklyLanguageSectionHeader
        }
    }

    @ViewBuilder
    private var activitySidebarContent: some View {
        Section {
            activityCategoryRow(.notification)
            activityCategoryRow(.undoStar)

            if activityCategoriesExpanded {
                ForEach(activityLeafCategories) { category in
                    activityCategoryRow(category)
                        .transition(Self.disclosureRowTransition)
                }
            }
        } header: {
            activityCategorySectionHeader
        }
    }

    private var activityCategorySectionHeader: some View {
        Button {
            withAnimation(disclosureAnimation) {
                activityCategoriesExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                // 不设显式 `.font`：继承 List `.sidebar` 的 section header 字体，
                // 与星标模块 `Section("sidebar.mainNavigation")` 的「主导航」文本一致。
                Text("activity.category.section")

                Spacer(minLength: 8)

                Text(activityLeafCategories.count.formatted())
                    .font(interfaceScale.font(.captionSmall))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                disclosureChevron(isExpanded: activityCategoriesExpanded)
                    .frame(width: 20, height: 20)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(disclosureHelp(isExpanded: activityCategoriesExpanded))
    }

    /// `.all` 只隐藏入口，不删除聚合逻辑；时间线作为 Activity 的默认常驻入口。
    private var activityLeafCategories: [ActivityCategory] {
        ActivityCategory.allCases.filter {
            $0 != .all && $0 != .notification && $0 != .undoStar
        }
    }

    @ViewBuilder
    private func activityCategoryRow(_ category: ActivityCategory) -> some View {
        Label {
            activityCategoryLabel(category)
        } icon: {
            // Activity 分类使用系统语义图标，不复用 LanguageIconView，避免渲染出语言 logo。
            // 明亮选中态反白：与探索「发现 / 趋势 / …」同一套 SidebarSemanticIconStyle。
            Image(systemName: category.systemImage)
                .font(interfaceScale.font(size: 14, weight: .semibold))
                .foregroundStyle(SidebarSemanticIconStyle(semanticColor: category.iconColor))
                .frame(width: 16, height: 16)
        }
        .tag(category)
    }

    @ViewBuilder
    private func activityCategoryLabel(_ category: ActivityCategory) -> some View {
        if let count = activityCategoryCount(for: category) {
            HStack {
                Text(category.titleKey)
                    .lineLimit(1)
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    Spacer(minLength: 0)
                    Text(count.formatted())
                        .font(interfaceScale.font(.captionSmall))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .frame(width: Self.trailingFixedWidth, alignment: .trailing)
            }
        } else {
            Text(category.titleKey)
                .lineLimit(1)
        }
    }

    /// Activity 行右侧数量。nil 表示对应数据源尚未加载，sidebar 保持空白。
    private func activityCategoryCount(for category: ActivityCategory) -> Int? {
        return dependencies.activityCategoryCountService.count(for: category)
    }

    /// 头像 / 统计数据下方的三入口切换。
    ///
    /// 使用独立按钮而不是 `Picker`，是为了匹配参考图里"图标在上、文字在下"的入口形态。
    private var rootNavigationBar: some View {
        HStack(spacing: 0) {
            ForEach(SidebarRootPage.allCases) { page in
                rootNavigationButton(page)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func rootNavigationButton(_ page: SidebarRootPage) -> some View {
        let isSelected = selectedPage == page
        // HOM-73 / HOM-163：Manage、Activity 与 Insights 都读取用户本地数据，需要登录；
        // Trending 有公开/本地空态，始终可打开。
        let needsLogin = !authSession.state.isAuthenticated
            && (page == .manage || page == .activity || page == .insights)

        return Button {
            rootNavigationBounceTokens[page, default: 0] += 1
            if needsLogin {
                showLoginSheet = true
            } else {
                selectRootPage(page)
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: page.systemImage)
                    // 圆形 SF Symbol 的有效墨迹面积比 folder / bell.badge 小，三入口局部放大避免视觉塌陷。
                    .font(interfaceScale.font(size: 30, weight: .medium))
                    .symbolEffect(.bounce, value: rootNavigationBounceTokens[page, default: 0])
                    .frame(height: 30)
                Text(page.titleKey)
                    // 四入口文案比 body 小一号：图标仍占主视觉，标签只做识别不抢权重。
                    .font(interfaceScale.font(.captionStrong))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.accentColor : (needsLogin ? Color.primary.opacity(0.3) : Color.primary.opacity(0.75)))
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        // 2026-06-02 dong4j 要求统一 hover 反馈：sidebar 三入口（Manage / Trending / Search）
        // 加 `.pressableHover()`，与详情页 / sidebar 头像 / Stats 保持同款交互反馈。
        // 关键约束：scale 1.06 + opacity 0.7 是临时反馈，鼠标移开恢复，不影响 isSelected
        // 的 accent color 视觉表达；needsLogin 的灰态按钮（点击会触发登录 sheet）也加 hover，
        // 因为它仍然是可点击元素。
        .pressableHover()
    }

    private func selectRootPage(_ page: SidebarRootPage) {
        guard selectedPage != page else { return }
        if let onSelectRootPage {
            onSelectRootPage(page)
        } else {
            selectedPage = page
        }
    }

    /// HOM-43：Tags header 需要同时有折叠入口和独立的标签管理按钮。
    /// 避免把 `Button` 嵌在另一个 `Button` 里，否则 SwiftUI 事件命中会不稳定。
    ///
    /// 整行可点（对齐 `docs/5-规范/UI-折叠展开-规范.md`）：标题与「空白 + 计数 + chevron」
    /// 各用独立 expand Button 覆盖命中区；`+` / 清除保留各自点击区，不误触发展开。
    private var tagSectionHeader: some View {
        HStack(spacing: 6) {
            Button {
                toggleTags()
            } label: {
                Text("sidebar.tags")
                    .font(interfaceScale.font(.body))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(disclosureHelp(isExpanded: tagsExpanded))

            Button {
                showTagManagement = true
            } label: {
                // 2026-06-06 dong4j 反馈：原来的细线 `plus`(.small) 在 sidebar headline
                // 字号下视觉过弱，与右侧 chevron 几乎齐平，看不出是个可点击按钮。
                // 换成 `plus.circle.fill` + hierarchical + .secondary，14pt medium。
                // 与 SidebarHeaderView 的 ellipsis.circle.fill / square.and.arrow.up
                // 保持同款"填充圆形 hierarchical"语言，加强 affordance 同时不喧宾夺主。
                Image(systemName: "plus.circle.fill")
                    .font(interfaceScale.font(.iconMedium, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(Text("sidebar.tagManagement"))

            // HOM-179：仅当有 tag 被选中时显示"清除"按钮，避免空状态下噪声。
            // 与 `+` / chevron 同款 14pt hierarchical 语言，hover 反馈复用 pressableHover。
            if !viewModel.selectedTagIds.isEmpty {
                Button {
                    viewModel.clearSelectedTags()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(interfaceScale.font(.iconMedium, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(Text("sidebar.clearSelectedTags"))
            }

            // 右侧剩余行宽（空白 / 计数 / chevron）整块可点，避免只点得到小 chevron。
            Button {
                toggleTags()
            } label: {
                HStack(spacing: 6) {
                    Spacer(minLength: 8)

                    Text(viewModel.tags.count.formatted())
                        .font(interfaceScale.font(.captionSmall))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(minWidth: 18, alignment: .trailing)

                    disclosureChevron(isExpanded: tagsExpanded)
                        .frame(width: 20, height: 20)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(disclosureHelp(isExpanded: tagsExpanded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 6)
    }

    /// GitHub Stars List 分组 header：折叠入口 + 独立新增 / 刷新按钮。
    /// 整行可点策略与 `tagSectionHeader` 一致：标题与右侧剩余行宽各自 expand，操作按钮独立命中。
    private var githubStarListSectionHeader: some View {
        HStack(spacing: 6) {
            Button {
                toggleGitHubStarLists()
            } label: {
                Text("sidebar.githubStarLists")
                    .font(interfaceScale.font(.body))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(disclosureHelp(isExpanded: githubStarListsExpanded))

            Button {
                gitHubStarListEditorItem = GitHubStarListEditorItem(list: nil)
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(interfaceScale.font(.iconMedium, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(Text("sidebar.githubStarLists.add"))

            SyncIconButton(
                isRefreshing: dependencies.githubStarListSyncService.isSyncing,
                disabled: dependencies.githubStarListSyncService.isSyncing || authSession.state.user == nil,
                tooltip: String.l10n("sidebar.githubStarLists.refresh"),
                action: { refreshGitHubStarLists() }
            )

            // 右侧剩余行宽（空白 / 计数 / chevron）整块可点，与 Tags / Languages 手感对齐。
            Button {
                toggleGitHubStarLists()
            } label: {
                HStack(spacing: 6) {
                    Spacer(minLength: 8)

                    // 仓库分组数量包含固定的"未分组"入口，保证 header 数字与展开后的分组行一致。
                    Text((viewModel.githubStarLists.count + 1).formatted())
                        .font(interfaceScale.font(.captionSmall))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(minWidth: 18, alignment: .trailing)

                    disclosureChevron(isExpanded: githubStarListsExpanded)
                        .frame(width: 20, height: 20)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(disclosureHelp(isExpanded: githubStarListsExpanded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 6)
    }

    /// HOM-43：Languages 数字是"语言类别数量"，放在右侧 accessory 区域，
    /// 与 Tags header 的 `+` 按钮占位一致，而不是紧跟标题。
    private var languageSectionHeader: some View {
        Button {
            toggleLanguages()
        } label: {
            HStack(spacing: 6) {
                Text("sidebar.languages")
                    .font(interfaceScale.font(.body))

                Spacer(minLength: 8)

                Text(viewModel.languageStats.count.formatted())
                    .font(interfaceScale.font(.captionSmall))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 18, alignment: .trailing)

                disclosureChevron(isExpanded: languagesExpanded)
                    .frame(width: 20, height: 20)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(disclosureHelp(isExpanded: languagesExpanded))
    }

    private var exploreTopicSectionHeader: some View {
        Button {
            withAnimation(disclosureAnimation) {
                exploreTopicsExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Text("explore.sidebar.categories")
                    .font(interfaceScale.font(.body))

                Spacer(minLength: 8)

                Text(dependencies.exploreCatalogStore.displayTopics.count.formatted())
                    .font(interfaceScale.font(.captionSmall))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                disclosureChevron(isExpanded: exploreTopicsExpanded)
                    .frame(width: 20, height: 20)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(disclosureHelp(isExpanded: exploreTopicsExpanded))
    }

    private var explorePlatformSectionHeader: some View {
        Button {
            withAnimation(disclosureAnimation) {
                explorePlatformsExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Text("explore.sidebar.platforms")
                    .font(interfaceScale.font(.body))

                Spacer(minLength: 8)

                Text(dependencies.exploreCatalogStore.displayPlatforms.count.formatted())
                    .font(interfaceScale.font(.captionSmall))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                disclosureChevron(isExpanded: explorePlatformsExpanded)
                    .frame(width: 20, height: 20)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(disclosureHelp(isExpanded: explorePlatformsExpanded))
    }

    private var exploreLanguageSectionHeader: some View {
        Button {
            withAnimation(disclosureAnimation) {
                trendingLanguagesExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Text("sidebar.languages")
                    .font(interfaceScale.font(.body))

                Spacer(minLength: 8)

                Text(dependencies.exploreCatalogStore.displayLanguages(for: selectedExploreMode).count.formatted())
                    .font(interfaceScale.font(.captionSmall))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                disclosureChevron(isExpanded: trendingLanguagesExpanded)
                    .frame(width: 20, height: 20)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(disclosureHelp(isExpanded: trendingLanguagesExpanded))
    }

    private var trendingLanguageSectionHeader: some View {
        Button {
            withAnimation(disclosureAnimation) {
                trendingLanguagesExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Text("sidebar.languages")
                    .font(interfaceScale.font(.body))

                Spacer(minLength: 8)

                // 显示「当前展示的语言条数」=（后端真实聚合时）trendingLanguageStore.aggregates.count，
                // 兜底状态下用 displayList.count（fallbackList 元素数）。两条路径都用 displayList，
                // 与下方 ForEach 渲染数完全一致，避免 header 计数与列表行数对不上的撕裂感。
                Text(dependencies.trendingLanguageStore.displayList.count.formatted())
                    .font(interfaceScale.font(.captionSmall))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                disclosureChevron(isExpanded: trendingLanguagesExpanded)
                    .frame(width: 20, height: 20)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(disclosureHelp(isExpanded: trendingLanguagesExpanded))
    }

    private var weeklyLanguageSectionHeader: some View {
        Button {
            withAnimation(disclosureAnimation) {
                trendingLanguagesExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Text("sidebar.languages")
                    .font(interfaceScale.font(.body))

                Spacer(minLength: 8)

                Text(dependencies.weeklyLanguageStore.displayList.count.formatted())
                    .font(interfaceScale.font(.captionSmall))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                disclosureChevron(isExpanded: trendingLanguagesExpanded)
                    .frame(width: 20, height: 20)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(disclosureHelp(isExpanded: trendingLanguagesExpanded))
    }

    private func disclosureHelp(isExpanded: Bool) -> Text {
        isExpanded ? Text("sidebar.collapse") : Text("sidebar.expand")
    }

    private func disclosureChevron(isExpanded: Bool) -> some View {
        Image(systemName: "chevron.right")
            .font(interfaceScale.font(.captionSmall))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            // 2026-06-11：chevron 旋转与行展开/收起共用 disclosureSpring,保证转动节奏
            // 与行的 move+opacity transition 完全同步。详情见 disclosureSpring 注释。
            .animation(disclosureAnimation, value: isExpanded)
    }

    private func toggleTags() {
        withAnimation(disclosureAnimation) {
            tagsExpanded.toggle()
        }
    }

    private func toggleGitHubStarLists() {
        withAnimation(disclosureAnimation) {
            githubStarListsExpanded.toggle()
        }
    }

    private func refreshGitHubStarLists() {
        guard let login = authSession.state.user?.login else { return }
        Task {
            await dependencies.githubStarListSyncService.sync(login: login)
            await viewModel.refreshSidebar()
            if viewModel.selection.isGitHubStarListContext {
                await viewModel.reloadItems(forceRefresh: true)
            }
        }
    }

    private func toggleLanguages() {
        withAnimation(disclosureAnimation) {
            languagesExpanded.toggle()
        }
    }

    // 2026-06-11 改造：`trendingLanguages` 计算属性已删除——
    // 历史实现从 `viewModel.languageStats`（用户本地 stars 聚合）取语言，但与 trending 后端
    // 实际是否有该语言的 repo 完全脱钩（Swift 开发者本周可能 0 个 Swift trending repo，
    // 列表展示 Swift 但点进去 0 条）。新实现走 `dependencies.trendingLanguageStore.displayList`，
    // 直接消费后端 `/api/v1/languages` 聚合接口的结果（含 `__uncategorized__` 项）。
    // 历史代码可在 git blame / commit `trending sidebar 切换到后端聚合接口` 之前的版本里找回。

    private func exploreTopicRow(_ topic: DiscoveryTopicDTO?) -> some View {
        let code = topic?.code
        return exploreSelectableRow(
            selection: .topic(code),
            count: dependencies.exploreCatalogStore.topicCount(for: code)
        ) {
            exploreSidebarSystemIcon(
                exploreTopicSystemImage(for: code),
                color: exploreTopicIconColor(for: code)
            )
        } title: {
            if let topic {
                exploreTopicTitle(topic)
            } else {
                Text("explore.allCategories")
            }
        }
    }

    @ViewBuilder
    private func exploreTopicTitle(_ topic: DiscoveryTopicDTO) -> some View {
        // Discovery topic code 是后端筛选契约；固定内置分类用本地化 key，
        // 未知动态分类继续显示后端 label，避免把服务端数据误当成 String Catalog key。
        if let key = exploreTopicLocalizationKey(topic.code) {
            Text(key)
        } else {
            Text(verbatim: topic.label)
        }
    }

    private func exploreTopicLocalizationKey(_ code: String) -> LocalizedStringKey? {
        switch code {
        case "ai": return "explore.topic.ai"
        case "privacy": return "explore.topic.privacy"
        case "networking": return "explore.topic.networking"
        case "media": return "explore.topic.media"
        case "social": return "explore.topic.social"
        case "reading": return "explore.topic.reading"
        case "tools": return "explore.topic.tools"
        default: return nil
        }
    }

    private func exploreTopicSystemImage(for code: String?) -> String {
        switch code {
        case nil: return "square.grid.2x2"
        case "ai": return "sparkles"
        case "privacy": return "lock.shield"
        case "networking": return "network"
        case "media": return "play.rectangle"
        case "social": return "person.2"
        case "reading": return "book"
        case "tools": return "wrench.and.screwdriver"
        default:
            // 后端 topic 可动态增加；未知分类保留通用圆点，避免空图标破坏侧栏行对齐。
            return "circle.fill"
        }
    }

    private func exploreTopicIconColor(for code: String?) -> Color {
        // 已知分类使用中性色突出图标语义；未知动态分类继续用蓝点提示它来自后端扩展。
        exploreTopicLocalizationKey(code ?? "") == nil && code != nil ? .accentColor.opacity(0.7) : .secondary
    }

    private func explorePlatformRow(_ platform: DiscoveryPlatformDTO?) -> some View {
        let code = platform?.code
        return exploreSelectableRow(
            selection: .platform(code),
            count: dependencies.exploreCatalogStore.platformCount(for: code)
        ) {
            exploreSidebarSystemIcon(
                platform?.systemName ?? "square.stack.3d.up",
                color: .secondary
            )
        } title: {
            if let platform {
                Text(verbatim: platform.label)
                    .lineLimit(1)
            } else {
                Text("explore.allPlatforms")
                    .lineLimit(1)
            }
        }
    }

    private func exploreLanguageRow(_ language: DiscoveryLanguageDTO?) -> some View {
        let key = language?.key
        // 语言 logo 不是 SF Symbol，不能塞进 systemImage 字符串；仍走 Label icon 槽，
        // 与趋势/周刊语言行、星标主导航同一套 sidebar 图标列对齐。
        return exploreSelectableRow(
            selection: .language(key),
            count: dependencies.exploreCatalogStore.languageCount(for: key, mode: selectedExploreMode)
        ) {
            if let language {
                exploreLanguageIcon(language)
            } else {
                AllLanguagesIcon(size: 14)
            }
        } title: {
            if let language {
                Text(verbatim: exploreLanguageTitle(language))
                    .lineLimit(1)
            } else {
                Text("explore.allLanguages")
                    .lineLimit(1)
            }
        }
    }

    /// 探索侧栏 SF Symbol：语义色 + 明亮主题选中反白（见 `ExploreSidebarIconStyle`）。
    @ViewBuilder
    private func exploreSidebarSystemIcon(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(interfaceScale.font(.iconSmall, weight: .semibold))
            // 必须走 ShapeStyle.resolve(backgroundProminence)，不能手写 binding == selection：
            // macOS List 蓝底高亮与 selection binding 不同步（按下即高亮、抬起才写 binding；
            // 切换 mode 时下方 section 重建还会让旧行卡在「选中白」直到数据加载触发重绘）。
            .foregroundStyle(ExploreSidebarIconStyle(semanticColor: color))
            .frame(width: 16, height: 16)
    }

    /// 与星标 / 活动侧栏一致：用 `Label` 走系统 sidebar 图标列，避免手写 HStack 把整行顶到更靠左。
    private func exploreSelectableRow<Title: View, Icon: View>(
        selection: ExploreSidebarSelection,
        count: Int?,
        @ViewBuilder icon: () -> Icon,
        @ViewBuilder title: () -> Title
    ) -> some View {
        Label {
            HStack(spacing: 4) {
                title()
                    .lineLimit(1)

                Spacer(minLength: 4)

                if let count {
                    Text(count.formatted())
                        .font(interfaceScale.font(.captionSmall))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
        } icon: {
            icon()
        }
        .tag(selection)
    }

    @ViewBuilder
    private func exploreLanguageIcon(_ language: DiscoveryLanguageDTO) -> some View {
        if language.key == TrendingLanguage.uncategorizedKey {
            UncategorizedLanguageIcon(size: 14)
        } else {
            LanguageIconView(language: language.key, size: 14)
        }
    }

    private func exploreLanguageTitle(_ language: DiscoveryLanguageDTO) -> String {
        if language.key == TrendingLanguage.uncategorizedKey {
            return String.l10n("trending.language.uncategorized")
        }
        return LanguageDisplayName.shortened(for: language.key)
    }

    /// Trending 语言行。`count` 为 nil 时不展示行尾计数（fallbackList / All 行）。
    @ViewBuilder
    private func trendingLanguageRow(_ language: TrendingLanguage, count: Int?) -> some View {
        Label {
            HStack(spacing: 4) {
                trendingLanguageTitle(language)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if let count, count > 0 {
                    Text(count.formatted())
                        .font(interfaceScale.font(.captionSmall))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        } icon: {
            trendingLanguageIcon(language)
        }
        .tag(ExploreSidebarSelection.trendingLanguage(language))
    }

    /// Weekly 语言行。nil 表示 `All Languages`,具体语言来自 WeeklyLanguageStore 聚合结果。
    @ViewBuilder
    private func weeklyLanguageRow(_ aggregate: TrendingLanguageAggregateDTO?) -> some View {
        let key = aggregate?.key
        Label {
            HStack(spacing: 4) {
                if let aggregate {
                    Text(verbatim: aggregate.label)
                        .lineLimit(1)
                } else {
                    Text("trending.allLanguages")
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if let aggregate, aggregate.count > 0 {
                    Text(aggregate.count.formatted())
                        .font(interfaceScale.font(.captionSmall))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else if aggregate == nil, let total = dependencies.weeklySelectionService.total {
                    Text(total.formatted())
                        .font(interfaceScale.font(.captionSmall))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        } icon: {
            weeklyLanguageIcon(aggregate)
        }
        .tag(ExploreSidebarSelection.weeklyLanguage(key))
    }

    @ViewBuilder
    private func weeklyLanguageIcon(_ aggregate: TrendingLanguageAggregateDTO?) -> some View {
        if let aggregate {
            if aggregate.key == TrendingLanguage.uncategorizedKey {
                UncategorizedLanguageIcon(size: 14)
            } else {
                LanguageIconView(language: aggregate.key, size: 14)
            }
        } else {
            AllLanguagesIcon(size: 14)
        }
    }

    @ViewBuilder
    private func trendingLanguageIcon(_ language: TrendingLanguage) -> some View {
        if language == .all {
            AllLanguagesIcon(size: 14)
        } else if language.isUncategorized {
            UncategorizedLanguageIcon(size: 14)
        } else {
            LanguageIconView(language: language.rawValue, size: 14)
        }
    }

    @ViewBuilder
    private func trendingLanguageTitle(_ language: TrendingLanguage) -> some View {
        if language == .all {
            Text("trending.allLanguages")
        } else if language.isUncategorized {
            Text("trending.language.uncategorized")
        } else {
            // Trending 语言 picker label：同样走短名（详见 LanguageDisplayName）。
            Text(verbatim: LanguageDisplayName.shortened(for: language.rawValue))
        }
    }

    @ViewBuilder
    private func row(_ item: SidebarItem,
                     displayOverride: String? = nil,
                     count: Int? = nil) -> some View {
        Label {
            // Sidebar count 溢出 + 抖动 bugfix（dong4j 2026-06-06 三次修复，演进史见
            // `trailingFixedWidth` 常量上方的大注释）。
            //
            // 当前 v4 策略：trailing 整体用 `.frame(width: trailingFixedWidth, alignment: .trailing)`
            // 锁死宽度，**完全放弃** `.fixedSize` + `.minWidth` 的组合（在 List 内不可靠，
            // selection 切换时 SwiftUI 反复发起 layout 测量、在 ideal/minimum 之间插值，
            // 引发"切 Languages 后数字闪烁 + 切 All Stars 后数字从右往左反复"的新现象）。
            //
            // 新 trailing 内部结构：
            //   [sync icon(18×18, 仅 .allStars)] [Spacer(0)] [count Text 右对齐]
            //
            // - 有 sync icon：icon 贴左、count 贴右、中间 Spacer 自动撑开
            // - 无 sync icon：Spacer 占满左半部，count 仍紧贴右边
            // - count 位数变化（9 → 10 → 100）：仅在 Text intrinsic 内部伸缩，对外宽度不变
            // - sync icon SF Symbol 切换：外层 18×18 frame 锁死，对外宽度不变
            //
            // trailing 容器对外宽度永远 = trailingFixedWidth = 60pt，外层 HStack 看到的
            // layout 完全恒定 → 真正"零抖动"。
            //
            // 三个**关键**约束（已踩坑）：
            //  1. **不要**给 trailing HStack 用 `.fixedSize(horizontal: true)`——在 List 内
            //     SwiftUI 会反复测量 ideal width，若 ideal 依赖 Text 内容长度就会反复插值
            //  2. **不要**给 count Text 用 `.frame(minWidth:, alignment:)`——同上原因
            //  3. **必须**用 `.frame(width:)` 显式锁死外层容器宽度——这是 List 内**唯一**
            //     可靠的"对外宽度恒定"方式
            //
            // 副作用：60pt 对所有 row 生效，count 较小时右侧留空白；这其实让所有 sidebar row
            // 的数字纵向严格对齐，视觉反而更整齐——有意保留。
            HStack(spacing: 4) {
                if let override = displayOverride {
                    Text(verbatim: override)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text(item.displayName)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 4)

                HStack(spacing: 4) {
                    Spacer(minLength: 0)

                    if let count {
                        Text(count.formatted())
                            .font(interfaceScale.font(.captionSmall))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
                .frame(width: Self.trailingFixedWidth, alignment: .trailing)
            }
        } icon: {
            Image(systemName: item.systemImage)
                .foregroundStyle(
                    SidebarSemanticIconStyle(semanticColor: item.semanticIconColor ?? .secondary)
                )
        }
        .tag(item)
        // HOM-46 优化：鼠标悬停时预取相邻分类数据，降低点击后的感知延迟
        .onHover { isHovering in
            if isHovering {
                for candidate in item.prefetchCandidates {
                    viewModel.prefetch(selection: candidate)
                }
            }
        }
    }

    /// “我的项目”复用系统 Sidebar selection，授权入口紧跟标题，右侧固定区域只保留计数。
    /// 刷新统一由中栏承担，避免同一个列表在 Sidebar 出现重复操作。
    private var myProjectsRow: some View {
        Label {
            HStack(spacing: 4) {
                Text(SidebarItem.myProjects.displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Button {
                    showProjectAccessSheet = true
                } label: {
                    Image(systemName: projectAccessSystemImage)
                        .font(interfaceScale.font(.captionSmall))
                        // 授权成功用绿色勾表达「已可用」；其它状态沿用 statusTone（灰 / 橙 / 红）。
                        // 必须走 SidebarSemanticIconStyle：明亮主题选中蓝底会把系统绿几乎吃掉，
                        // 不能手写 selection == .myProjects（按下高亮与 binding 不同步）。
                        .foregroundStyle(
                            SidebarSemanticIconStyle(semanticColor: projectAccessIconColor)
                        )
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(Text("project.access.manage"))
                .accessibilityLabel(Text("project.access.manage"))

                Spacer(minLength: 4)

                HStack(spacing: 4) {
                    Spacer(minLength: 0)

                    Text(viewModel.myProjectsCount.formatted())
                        .font(interfaceScale.font(.captionSmall))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .frame(width: Self.trailingFixedWidth, alignment: .trailing)
            }
        } icon: {
            Image(systemName: SidebarItem.myProjects.systemImage)
                .foregroundStyle(
                    SidebarSemanticIconStyle(
                        semanticColor: SidebarItem.myProjects.semanticIconColor ?? .secondary
                    )
                )
        }
        .tag(SidebarItem.myProjects)
        .onHover { isHovering in
            guard isHovering else { return }
            for candidate in SidebarItem.myProjects.prefetchCandidates {
                viewModel.prefetch(selection: candidate)
            }
        }
    }

    private var projectAccessSystemImage: String {
        dependencies.projectAccessSession.state.statusSymbolName
    }

    private var projectAccessIconColor: Color {
        dependencies.projectAccessSession.state.statusTone.foregroundColor
    }

    /// HOM-47：Release 时间线入口行。
    ///
    /// 设计取舍：把入口放在 Manage 的"主导航"段而不是单独的根页（`SidebarRootPage`），
    /// 是因为 Release 时间线属于 Stars 数据的衍生视图，跟 All Stars / Untagged 同源；
    /// 用 `Button` + sheet 而不是 `selection` 行，避免插入新 case 牵动 HomeViewModel
    /// reload 路径。
    @ViewBuilder
    private var releaseTimelineRow: some View {
        Button {
            showReleaseTimeline = true
        } label: {
            Label {
                HStack(spacing: 4) {
                    Text("sidebar.releaseTimeline")
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 4)

                    HStack(spacing: 4) {
                        Spacer(minLength: 0)

                        Text(viewModel.releaseSubscriptionCount.formatted())
                            .font(interfaceScale.font(.captionSmall))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    .frame(width: Self.trailingFixedWidth, alignment: .trailing)
                }
            } icon: {
                // 与探索「新发布」同语义色；对齐主导航其它行的彩色图标。
                Image(systemName: "shippingbox.fill")
                    .foregroundStyle(SidebarSemanticIconStyle(semanticColor: .cyan))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    @ViewBuilder
    private var githubStarListUngroupedRow: some View {
        row(.githubStarListUngrouped, count: viewModel.githubStarListUngroupedCount)
    }

    /// GitHub Stars List 真实分组行：颜色点 + 名称 + 编辑按钮 + 计数。
    @ViewBuilder
    private func githubStarListRow(_ list: GitHubStarList) -> some View {
        let item = SidebarItem.githubStarList(list.id)
        Label {
            HStack(spacing: 4) {
                Text(verbatim: list.name)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Button {
                    gitHubStarListEditorItem = GitHubStarListEditorItem(list: list)
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(interfaceScale.font(.captionSmall))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(Text("sidebar.githubStarLists.edit"))

                Spacer(minLength: 4)

                HStack(spacing: 4) {
                    Spacer(minLength: 0)

                    Text((viewModel.githubStarListCounts[list.id] ?? 0).formatted())
                        .font(interfaceScale.font(.captionSmall))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .frame(width: Self.trailingFixedWidth, alignment: .trailing)
            }
        } icon: {
            Circle()
                .fill(
                    SidebarSemanticIconStyle(
                        semanticColor: Color(hex: list.colorHex) ?? .accentColor
                    )
                )
                .frame(width: 14, height: 14)
        }
        .tag(item)
        .onHover { isHovering in
            if isHovering {
                for candidate in item.prefetchCandidates {
                    viewModel.prefetch(selection: candidate)
                }
            }
        }
    }

    /// W4 A6：tag 专属行——
    /// 用户配色（左侧色块）+ 用户自定义图标（若有）+ 名字 + 计数
    /// 复用通用 row() 不合适，因为 tag 的图标 / 颜色都是动态的
    @ViewBuilder
    private func tagRow(tag: Tag, count: Int) -> some View {
        let item = SidebarItem.tag(tag.id)
        Label {
            // Sidebar count bugfix v4：与 row() 同款保护——trailing 容器整体用
            // `.frame(width: trailingFixedWidth)` 锁死，避免 List selection 切换时
            // SwiftUI 反复发起 layout 测量引起的"数字反复移动 / 闪烁"。
            // 详细根因 + 演进史见 `trailingFixedWidth` 常量上方的大注释。
            HStack {
                Text(verbatim: tag.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    Spacer(minLength: 0)
                    Text(count.formatted())
                        .font(interfaceScale.font(.captionSmall))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .frame(width: Self.trailingFixedWidth, alignment: .trailing)
            }
        } icon: {
            // 优先 user-defined SF Symbol；否则 fallback "tag.fill"
            // 明亮选中反白，避免彩色 icon 叠在系统蓝底上看不清。
            Image(systemName: tag.icon ?? "tag.fill")
                .foregroundStyle(
                    SidebarSemanticIconStyle(
                        semanticColor: Color(hex: tag.color ?? TagColorPalette.defaultHex) ?? .accentColor
                    )
                )
        }
        .tag(item)
        // HOM-46 优化：hover 时预取相邻分类
        .onHover { isHovering in
            if isHovering {
                for candidate in item.prefetchCandidates {
                    viewModel.prefetch(selection: candidate)
                }
            }
        }
    }

    /// Languages 专属筛选行。
    ///
    /// 语言是当前基础仓库范围上的附加条件，不能再通过 `.tag(.language(...))`
    /// 写入 `List(selection:)`，否则会把“未分类 / 知识库”等主导航选择覆盖掉。
    @ViewBuilder
    private func languageRow(_ stat: LanguageStat) -> some View {
        let language = stat.languageOrNil
        let isSelected = isManageLanguageFilterSelected(language)

        Button {
            viewModel.toggleLanguageFilterFromUser(language)
        } label: {
            Label {
                // Sidebar count bugfix v4：trailing 容器整体 fixed width 锁死，
                // 避免选中筛选后计数位数变化导致标题横向跳动。
                HStack {
                    Text(verbatim: LanguageDisplayName.shortened(for: stat.displayName))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    HStack(spacing: 4) {
                        Spacer(minLength: 0)
                        Text(stat.count.formatted())
                            .font(interfaceScale.font(.captionSmall))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    .frame(width: Self.trailingFixedWidth, alignment: .trailing)
                }
            } icon: {
                if let language, !language.isEmpty {
                    LanguageIconView(language: language, size: 14)
                } else {
                    UncategorizedLanguageIcon(size: 14)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        // 基础范围继续使用系统 List selection；语言只用轻量 accent 背景表达独立筛选态。
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    /// “全部语言”只清空语言条件，不改变当前基础仓库范围。
    private var allLanguagesRow: some View {
        Button {
            viewModel.clearLanguageFiltersFromUser()
        } label: {
            Label {
                HStack(spacing: 4) {
                    Text("trending.allLanguages")
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 4)

                    HStack(spacing: 4) {
                        Spacer(minLength: 0)
                        Text(viewModel.totalCount.formatted())
                            .font(interfaceScale.font(.captionSmall))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    .frame(width: Self.trailingFixedWidth, alignment: .trailing)
                }
            } icon: {
                AllLanguagesIcon(size: 14)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    /// Sidebar 的语言高亮读取真实有效筛选，确保 Toolbar 修改后这里同步反馈。
    private func isManageLanguageFilterSelected(_ language: String?) -> Bool {
        let filters = viewModel.effectiveGlobalFilterState
        guard let language, !language.isEmpty else {
            return filters.repoLanguageFilter == .uncategorized
        }

        let matchesSingleLanguage: Bool
        if case .language(let selectedLanguage) = filters.repoLanguageFilter {
            matchesSingleLanguage = selectedLanguage.caseInsensitiveCompare(language) == .orderedSame
        } else {
            matchesSingleLanguage = false
        }
        return matchesSingleLanguage || filters.globalFilterLanguages.contains {
            $0.caseInsensitiveCompare(language) == .orderedSame
        }
    }
}
