//
//  HomeView.swift
//  Starcat
//
//  登录后的主界面：NavigationSplitView 三栏。
//
//  布局（2026-06-23 调整 v11，默认外框约 1440×900，运行期硬下限仍为 content 1440×763）：
//  Sidebar（240-320pt, ideal 260）│ RepoList（420-520pt, ideal 420）│ RepoDetail（自适应）
//  - HomeView 首次进入默认 content 1440×878，换算外层窗口约 1440×900，方便直接截
//    Mac App Store 2880×1800 图
//  - 运行期 `NSWindow.contentMinSize` / `window.minSize` 固定为 1440×763
//    （见 `MainWindowFrameModifier.swift`，AppKit 层卡死，用户不能继续压缩中栏/右栏）
//  - **关键经验**：SwiftUI 的 `.navigationSplitViewColumnWidth(min:)` 和
//    `.frame(minWidth:)` 只是子视图布局提示，**不会反向约束 NSWindow 拖动下限**。
//    要真正卡死窗口最小尺寸必须走 `NSWindow.contentMinSize`（AppKit 层）。
//    2026-06-02 之前 v2 错误地以为 SwiftUI minWidth 能反向约束，dong4j 拖窗口拖到
//    ~920pt 后 sidebar 被压成不可见、列表行被裁掉，截图反馈后才发现此事。
//  - **启动宽度 == 硬下限**：1190 折叠态下限在重新展开 sidebar 时会让右上角
//    短暂出现 `>>` toolbar overflow；dong4j 手动拉到 1440 后问题消失，所以
//    直接把 AppKit 硬下限提升到 1440，不再做展开时扩窗或动态 minSize。
//  - RepoList 的 min == ideal == 420：默认贴 min 启动，往大可拖到 520，往小拖不动
//  - 最小高度 763pt：刚好够 Sidebar 完整渲染（头像+统计+主导航+Tags+Languages 前 ~10 项）
//  - 小屏限制：MacBook 13" 1280×800 仍低于 1440pt 最小宽度，需主屏横放或外接显示器
//
//  顶部操作按三栏职责拆分：
//  - Sidebar：同步、标签管理
//  - RepoList：搜索、状态筛选、排序、多选
//  - RepoDetail：打开外链、复制 clone URL
//
//  数据生命周期：
//  - onAppear：刷新 Sidebar + 列表
//  - 当 selection 变化或搜索框显式提交时 → 自动 reload
//  - 当 SyncManager.state 变为 completed → 刷新 Sidebar + 列表
//

import SwiftUI

struct HomeView: View {

    @Environment(AuthSession.self) private var authSession
    @Environment(SyncManager.self) private var syncManager
    @Environment(AppSettings.self) private var settings
    /// 2026-06-15:搜索浮层弹出/收起的 .snappy 动画在关动画时跳过。
    /// 与系统「减少动态效果」OR 合并(`AnimationOverrideModifier`)。
    @Environment(\.starcatReduceMotion) private var reduceMotion
    /// HOM-47：拿到 ReleasePoller 启动后台调度。
    @Environment(AppDependencies.self) private var dependencies

    /// HOM-47：Release 时间线 sheet 显示状态。
    @State private var showReleaseTimeline: Bool = false

    /// HomeViewModel 在 HomeView 内部持有；用 @State 让生命周期与该视图绑定。
    /// AppDependencies 不构造它，因为 ViewModel 是 view-scoped，没必要塞进全局容器。
    @State private var viewModel: HomeViewModel

    /// README 子视图模型；与 HomeViewModel 同级在 HomeView 持有，
    /// 通过 .environment(readmeVM) 注入到 RepoDetailView。
    ///
    /// 为何提到这一层：早期 RepoDetailView 用 .task 内部赋值 @State 创建 readmeVM，
    /// 但 @State 写入是异步的，下一行立刻调用 readmeVM?.load(...) 时仍为 nil，
    /// 导致首次点击 repo 后 README 无法加载。
    @State private var readmeVM: ReadmeViewModel

    /// HOM-68：README 翻译子视图模型。
    /// 持有理由与 `readmeVM` 一致——同步 init 注入 + 通过 environment 透传到详情页，
    /// 避免在 RepoDetailView 内部用 .task 异步 @State 赋值引发的"首次点击没初始化"问题。
    @State private var translationVM: ReadmeTranslationViewModel

    /// 搜索中心是主窗口级 overlay，生命周期与 HomeView 一致，跨 Manage / Trending /
    /// Activity 切换时不丢查询状态。
    @State private var searchCenterViewModel: SearchCenterViewModel

    /// W4 A2：标签管理 sheet 显示状态。
    @State private var showTagManagement: Bool = false
    /// 开始使用清单的“添加标签”应直接打开 Tags 管理里的新建标签 sheet。
    @State private var showNewTagSheetOnTagManagementOpen: Bool = false

    /// HOM-52：批量 AI 整理"操作选择" sheet 显示状态。
    @State private var showBatchAIOptions: Bool = false
    /// HOM-52：批量 AI 整理进度面板 sheet 显示状态。
    @State private var showBatchAIPanel: Bool = false
    /// HOM-52：当前正在编辑的 Options（启动 sheet 时初始化，跨 sheet 关闭保留以记住上次选择）。
    @State private var batchAIOptions: BatchAIQueueOptions = BatchAIQueueOptions()
    /// 当前需要展示的 Pro 付费墙上下文。由批量 AI 等主窗口入口触发。
    @State private var paywallContext: ProPaywallContext?
    /// Agent Workspace 覆盖主窗口的显示状态。
    ///
    /// Agent 是一个长任务工作模式，不适合塞进 sheet；这里用主窗口覆盖层承载，
    /// 让后续所有内置 Agent 共用同一套步骤时间线和 Artifact 预览。
    @State private var showAgentWorkspace: Bool = false
    /// 主界面首次操作清单。它是本机 UI 教程状态，不进入 AppDependencies，避免变成业务数据。
    @State private var gettingStartedStore = GettingStartedProgressStore()
    /// Agent 功能尚未进入正式上线面，toolbar 入口默认由 Debug 菜单隐藏。
    ///
    /// 这里用 HomeView 本地状态承接 `DebugFlags`，是因为 UserDefaults 写入不会自动触发
    /// SwiftUI 刷新；Debug 菜单广播后更新该状态，RepoListView 的 toolbar 立即重建。
    @State private var showsAgentToolbarEntry: Bool = DebugFlags.agentToolbarEntry

    /// 三栏显示状态。
    ///
    /// 为什么显式持有：
    /// `NavigationSplitView` 在窗口缩窄时会自动折叠 sidebar，并把可见性状态改成
    /// detail/content 优先。如果 AppKit autosave 曾保存过窄窗口，下次启动即使我们
    /// 立即把窗口放大回默认三栏尺寸，SplitView 也可能停留在折叠可见性，导致左栏以
    /// 抽屉/半截形态出现。启动时把它重置为 `.all`，让默认状态始终是三栏展开。
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// Sidebar 顶部三入口的当前页。
    ///
    /// 这层状态只描述“左栏正在展示哪组导航结构”，和 `HomeViewModel.selection`
    /// 分开维护，避免 Trending / Search 后续扩展时污染 repo 管理筛选模型。
    @State private var selectedSidebarPage: SidebarRootPage = .manage

    /// Trending 页从左侧语言列表驱动的语言筛选。
    @State private var selectedTrendingLanguage: TrendingLanguage = .all

    /// Explore 页二级模块。内部仍挂在 SidebarRootPage.trending 下，用户可见文案已升级为「探索」。
    @State private var selectedExploreMode: ExploreMode = .discover

    /// Trending 当前选中的 repo ID（用于驱动 README 加载）。
    @State private var selectedTrendingRepoID: String?

    /// Trending 当前选中的 repo 完整数据（用于右侧详情页展示元信息）。
    @State private var selectedTrendingRepo: TrendingRepo?

    /// Discovery API 三个模块（发现 / 热门 / 新发布）的左栏语言筛选。
    @State private var selectedDiscoveryLanguage: String?
    /// Discovery API 发现模块的主题筛选。
    @State private var selectedDiscoveryTopic: String?
    /// Discovery API 发现模块的平台筛选。
    @State private var selectedDiscoveryPlatform: String?
    /// Discovery API 当前选中的 repo ID。
    @State private var selectedDiscoveryRepoID: Int64?
    /// Discovery API 当前选中的完整 repo 数据，驱动右侧详情。
    @State private var selectedDiscoveryRepo: DiscoveryRepoDTO?

    /// Manage 页面记住上次选择的分类（language / tag / allStars / untagged）。
    /// 切换到 Trending 再回来时恢复，避免用户丢失浏览上下文。
    @State private var savedManageSelection: SidebarItem = .allStars

    /// 去重「会话恢复 / 登录」激活路径：`handleAuthenticatedEntry` 在 onChange 与
    /// `.task` 都可能被调到，用 user.id 记一次避免双份 refreshSidebar + reloadItems。
    @State private var lastActivatedUserID: Int64?

    /// Trending 页面记住上次选择的语言。
    /// 切换到 Manage 再回来时恢复，避免用户丢失浏览上下文。
    @State private var savedTrendingLanguage: TrendingLanguage = .all

    /// Activity 页面当前分类。
    @State private var selectedActivityCategory: ActivityCategory = .all

    /// Activity 页面记住上次选择的分类。
    /// 与 Manage / Trending 的恢复策略一致：切走保存，切回恢复。
    @State private var savedActivityCategory: ActivityCategory = .all

    /// Activity 中栏当前选中的活动项，用于右侧详情页按类型分发。
    @State private var selectedActivityItem: ActivityItem?

    /// W4 A2：TagManagementViewModel 实例，sheet 关掉再开时复用，
    /// 避免每次 sheet 都 new 导致选择/加载态被打断。
    @State private var tagMgmtVM: TagManagementViewModel

    /// HOM-54：TrendingRepository 实例，传给 RepoListView 用于渲染 Trending 页面。
    @State private var trendingRepository: any TrendingRepositoryProtocol
    /// HOM-54：Trending 一键订阅需要调用 GitHub Star API。
    @State private var githubAPIClient: any GitHubAPIClientProtocol

    /// D-01：repository 类型从具体 struct 改为协议，便于 Preview / 测试注入 Mock。
    /// W4 A6：HomeViewModel 也接收 tagRepository / repoTagRepository（Sidebar Tags 段 + 按 tag 过滤）。
    /// W4-4 D3：新增 repoNoteRepository（按状态过滤需要拉 status map）。
    init(
        repository: any RepoRepositoryProtocol,
        readmeAPI: ReadmeAPI,
        readmeAvailability: ReadmeAvailability,
        readmeOnHTMLLoaded: @escaping @MainActor (Repo) -> Void,
        tagRepository: any TagRepositoryProtocol,
        repoTagRepository: any RepoTagRepositoryProtocol,
        githubStarListRepository: any GitHubStarListRepositoryProtocol,
        repoNoteRepository: any RepoNoteRepositoryProtocol,
        repoHealthRepository: (any RepoHealthRepositoryProtocol)? = nil,
        releaseRepository: (any ReleaseRepositoryProtocol)? = nil,
        releaseSubscriptionRepository: (any ReleaseSubscriptionRepositoryProtocol)? = nil,
        openSSFScoreRepository: (any OpenSSFScoreRepositoryProtocol)? = nil,
        smartCollectionRepository: (any SmartCollectionRepositoryProtocol)? = nil,
        searchHistoryRepository: any SearchHistoryRepositoryProtocol,
        semanticSearchService: SemanticSearchService? = nil,
        trendingRepository: any TrendingRepositoryProtocol,
        githubAPIClient: any GitHubAPIClientProtocol,
        readmeTranslationService: ReadmeTranslationService,
        entitlementGate: EntitlementGate,
        telemetryManager: TelemetryManager? = nil
    ) {
        _viewModel = State(initialValue: HomeViewModel(
            repository: repository,
            tagRepository: tagRepository,
            repoTagRepository: repoTagRepository,
            githubStarListRepository: githubStarListRepository,
            repoNoteRepository: repoNoteRepository,
            repoHealthRepository: repoHealthRepository,
            releaseRepository: releaseRepository,
            releaseSubscriptionRepository: releaseSubscriptionRepository,
            openSSFScoreRepository: openSSFScoreRepository,
            smartCollectionRepository: smartCollectionRepository,
            semanticSearchService: semanticSearchService
        ))
        // HOM-201 P0-4（2026-06-14）：原 manage 路径 README 拉到后的 backfill closure
        // 由 ContentView 透过 `readmeOnHTMLLoaded` 注入；factory 由
        // `AppDependencies.makeReadmeOnHTMLLoadedHandler()` 统一构造,让 manage / active
        // 两个走 `loadInternal` 的路径行为一致（active 详情页之前漏接,导致已 star
        // 的 active 详情不会触发 markdown backfill / 向量重建——见 26-向量搜索改进.md §6）。
        _readmeVM = State(initialValue: ReadmeViewModel(
            api: readmeAPI,
            availability: readmeAvailability,
            onHTMLLoaded: readmeOnHTMLLoaded,
            telemetryManager: telemetryManager
        ))
        _translationVM = State(initialValue: ReadmeTranslationViewModel(service: readmeTranslationService))
        _searchCenterViewModel = State(initialValue: SearchCenterViewModel(
            coordinator: SearchCoordinator(providers: [
                LocalKeywordSearchProvider(repository: repository),
                GitHubRepositorySearchProvider(client: githubAPIClient),
                AnySearchWebProvider(entitlementGate: entitlementGate)
            ]),
            historyRepository: searchHistoryRepository,
            includeWebInAll: {
                AppSettings.shared.anySearchEnabled && AppSettings.shared.searchIncludeWebInAll
            },
            entitlementGate: entitlementGate,
            telemetryManager: telemetryManager
        ))
        _tagMgmtVM = State(initialValue: TagManagementViewModel(
            tagRepository: tagRepository,
            repoTagRepository: repoTagRepository
        ))
        _trendingRepository = State(initialValue: trendingRepository)
        _githubAPIClient = State(initialValue: githubAPIClient)
    }

    var body: some View {
        navigationWithLifecycle
    }

    private var baseNavigation: AnyView {
        // HomeView 的 modifier 链已经很长，新增后台任务监听后 Swift 6 容易在
        // 巨型泛型链上 type-check 超时。分段 AnyView 只用于切断编译期泛型推断，
        // 不改变三栏内容与状态流。
        AnyView(NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarColumn
        } content: {
            contentColumn
        } detail: {
            detailColumn
        }
        .environment(viewModel)
        .environment(readmeVM)
        .environment(translationVM))
    }

    private var navigationWithOverlays: AnyView {
        AnyView(baseNavigation
        // 调试用：右上角浮动 W×H 胶囊，仅 DEBUG 包 + 设了 launch arg `-DebugLayoutOverlay YES` 时显示。
        // 详见 `Shared/Utilities/DebugFlags.swift` 的类型文档（含 Xcode Scheme / LLDB / defaults 三种切换方式）。
        .overlay(alignment: .topTrailing) {
            if DebugFlags.layoutOverlay {
                LayoutDebugOverlay()
            }
        }
        .overlay(alignment: .bottomTrailing) {
            GettingStartedChecklistView(
                store: gettingStartedStore,
                isSignedIn: authSession.state.isAuthenticated,
                hasSyncedStars: gettingStartedStore.isCompleted(.syncStars) || viewModel.totalCount > 0,
                hasSelectedRepo: viewModel.selectedRepoID != nil,
                canSelectRepo: selectedSidebarPage == .manage && !viewModel.items.isEmpty,
                onSignIn: {
                    authSession.requestLoginSheet()
                },
                onSyncStars: {
                    guard let user = authSession.state.user else {
                        authSession.requestLoginSheet()
                        return
                    }
                    syncManager.performFullSync(userID: user.id, force: true)
                },
                onSelectRepo: {
                    selectFirstRepoForGettingStarted()
                },
                onAddTag: {
                    openNewTagSheetForGettingStarted()
                },
                onOpenSearch: {
                    searchCenterViewModel.present()
                },
                onOpenAI: {
                    openSelectedRepoAIForGettingStarted()
                }
            )
            .padding(.trailing, 18)
            .padding(.bottom, 18)
            .zIndex(80)
        }
        .overlay {
            if searchCenterViewModel.isPresented {
                SearchCenterView(
                    viewModel: searchCenterViewModel,
                    languages: viewModel.languageStats,
                    onOpenCandidate: openSearchCandidate,
                    onOpenURL: openSearchRepositoryURL,
                    onCopyURL: copySearchRepositoryURL,
                    onOpenAI: openSearchRepositoryAI,
                    onToggleStar: toggleSearchRepositoryStar,
                    isStarred: { dependencies.starredRegistry.contains(ghRepoId: $0) },
                    isGitHubAuthenticated: authSession.state.isAuthenticated
                )
                .zIndex(100)
            }
        }
        .overlay {
            if showAgentWorkspace {
                AgentWorkspaceView {
                    showAgentWorkspace = false
                }
                // Agent 工作台是沉浸式覆盖层。隐藏 window toolbar 后必须主动吃掉
                // titlebar safe area，否则系统仍会给顶部留出一整条空白。
                .ignoresSafeArea(.container, edges: .top)
                .transition(.opacity)
                .zIndex(200)
            }
        }
        // 弹出/关闭：纯淡入淡出，贴近 Spotlight / 命令面板；不再叠加 scale 弹入。
        .animation(reduceMotion ? nil : .easeOut(duration: 0.20), value: searchCenterViewModel.isPresented)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: showAgentWorkspace)
        .preference(key: AgentWorkspaceActivePreferenceKey.self, value: showAgentWorkspace)
        .onReceive(NotificationCenter.default.publisher(for: DebugFlags.agentToolbarEntryDidChangeNotification)) { _ in
            showsAgentToolbarEntry = DebugFlags.agentToolbarEntry
            if !showsAgentToolbarEntry {
                showAgentWorkspace = false
            }
        }
        // 隐藏按钮只用于向当前 window 注册快捷键；实际入口仍是 toolbar 按钮。
        .background {
            Button("") { searchCenterViewModel.present() }
                .keyboardShortcut(
                    settings.globalSearchShortcut.keyEquivalent,
                    modifiers: settings.globalSearchShortcut.eventModifiers
                )
                .hidden()
        }
        )
    }

    private var navigationWithSheets: AnyView {
        AnyView(navigationWithOverlays
        .sheet(isPresented: $showTagManagement, onDismiss: handleTagManagementDismissed) {
            TagManagementView(
                viewModel: tagMgmtVM,
                opensNewTagSheetOnAppear: showNewTagSheetOnTagManagementOpen
            )
                .appSheetRootEnvironment(dependencies)
        }
        // HOM-47：Release 时间线 sheet（独立窗口承载，不污染三栏布局）
        .sheet(isPresented: $showReleaseTimeline) {
            ReleaseTimelineView()
                .appSheetRootEnvironment(dependencies)
        }
        // HOM-52：批量 AI 整理"操作选择" sheet
        .sheet(isPresented: $showBatchAIOptions) {
            BatchAIOptionsSheet(
                pendingCount: viewModel.untaggedCount,
                options: $batchAIOptions,
                onCancel: {
                    showBatchAIOptions = false
                },
                onStart: {
                    showBatchAIOptions = false
                    Task {
                        await startBatchAIIntegration()
                    }
                }
            )
            .appLocaleEnvironment()
        }
        // HOM-52：批量 AI 整理进度面板
        .sheet(isPresented: $showBatchAIPanel) {
            BatchAIQueuePanel(
                service: dependencies.batchAIQueueService,
                onClose: { showBatchAIPanel = false }
            )
            .appLocaleEnvironment()
        }
        .sheet(item: homePaywallBinding) { context in
            ProPaywallSheet.hosted(context: context, dependencies: dependencies)
        }
        )
    }

    private var navigationWithLifecycle: AnyView {
        navigationWithRoutingLifecycle
    }

    private var navigationWithStartupLifecycle: AnyView {
        AnyView(navigationWithSheets
        // HOM-47：登录后启动后台 Release 轮询；登出时停。
        // 与 SyncManager 不同：Release Poller 自调度（NSBackgroundActivityScheduler），
        // 启动一次后由系统在后台触发；这里只负责启停门控。
        //
        // 2026-06-13 dong4j 补救 A：同一时机门控「启动时自动后台预拉」(`SemanticIndexBuilder`)。
        // - 登录恢复完成（首启异步路径）/ 重新登录 → 若 `aiIndexAutoPrefetchEnabled` 开启则
        //   调 `start()` 启动顺序补 README markdown + diff 判定向量重建。
        // - 登出 / 失效 → `cancel()` 重置 builder 状态，避免给下一个用户带进度残值。
        // - 测试 host 跳过（避免 `xcodebuild test` 触发后台任务 hang testmanagerd）。
        // - `start()` 内部对 `.running` 状态幂等，多次触发不会重启已在跑的任务。
        .onChange(of: authSession.state) { _, newState in
            handleBackgroundPollersAuthChange(newState)
        }
        // README 预拉是独立于 AI 向量索引的后台任务：默认开启，但用户可以在设置页关闭。
        // 开关只影响后台调度；详情页手动打开 repo 时仍走正常 SWR 加载链路。
        .onChange(of: settings.readmePrefetchEnabled) { _, newValue in
            applyReadmePrefetchSetting(newValue)
        }
        // 2026-06-13 dong4j 补救 A 配套：用户运行期切换「自动预拉」Toggle 即时生效。
        // 已登录态下勾选 Toggle → 立刻启动 Builder；取消勾选 → 立刻暂停。
        // 未登录态不动（避免误烧未来登录 user 的配额预期）。
        .onChange(of: settings.aiIndexAutoPrefetchEnabled) { _, newValue in
            guard !TestEnvironment.isRunning, authSession.state.isAuthenticated else { return }
            if newValue {
                dependencies.semanticIndexBuilder.start()
            } else {
                dependencies.semanticIndexBuilder.pause()
            }
        }
        .onAppear {
            // 首帧即拉回三栏展开，避免 autosave 折叠态与后续 `.task` 纠正之间
            // 出现中栏顶区（navigationTitle + 列表顶栏）错层跳动。
            columnVisibility = .all
        }
        .task {
            await bootstrapHome()
        }
        .task {
            await observeReleaseSubscriptionChanges()
        }
        // selection 变化 → 重新加载列表
        .task(id: viewModel.selection) {
            await reloadManageSelectionIfNeeded()
        }
        // 搜索框按 Return / 清空后才提交搜索；普通 FTS5 与 AI 语义搜索都不再逐字符实时查询。
        .task(id: viewModel.searchSubmissionID) {
            await reloadManageSearchIfNeeded()
        }
        // 搜索模式变化只更新持久化偏好，不立刻发起查询；用户按 Return 后才用新模式搜索。
        .task(id: viewModel.smartSearchMode) {
            syncSmartSearchModeToSettings()
        }
        // 同步完成 → 仅当本轮真的写入了 repo 行时才 forceRefresh 列表。
        // 304 早退 / performFullSyncIfStale 跳过等路径 lastRunWroteRepos=false，避免无谓 DB 重查。
        .task(id: syncManager.state) {
            await reloadAfterSyncIfNeeded()
        }
        // R-07（2026-06-15）：SyncManager 写完第一页后立即刷一次列表，让首次登录 1~2s 内看到前 20 条。
        //
        // 与上方 `.task(id: syncManager.state)` 的 `.completed` 分支协作：
        // - 此处 = 边沿"首页就绪" → 第一页 ~100 条立即上屏（HomeViewModel 客户端分页只渲染前 20 条）
        // - state == .completed = 收尾"全集就绪" → reloadItems(forceRefresh: true) 走 SWR 数据变化
        //   路径，applyView(resetPage: false) 保用户滚动位置，1800 全集对 items 切片影响通常为 0
        //
        // 304 早退 / 失败 / page 1 dtos 空都不会让 firstPageWrittenAt 翻边沿（详见 SyncManager.swift）。
        // guard isAuthenticated 防御：理论上 SyncManager 不会在未登录态跑，但加一手避免账号切换瞬间误触。
        .onChange(of: syncManager.firstPageWrittenAt) { _, newValue in
            handleFirstPageWrittenChange(newValue)
        }
        // HOM-126：把同步状态变化转发给 AutoTidyScheduler，让它做"同步完成 → 自动整理"
        // 边沿触发判定。scheduler 内部会先 guard `autoTidySettings.triggerOnSync`，
        // 用户关掉同步触发后这里仍调用但 scheduler no-op，避免 view 端再加 guard。
        // 用 .onChange 而非 .task(id:)：.task 会在 view 重建时也跑一次 if-completed
        // 分支，造成"切窗口/重进 HomeView 触发 N 次自动整理"。.onChange 只在
        // syncManager.state 真正变化的边沿触发。
        .onChange(of: syncManager.state) { _, newState in
            dependencies.autoTidyScheduler.notifySyncStateChanged(newState)
            if case .completed = newState {
                gettingStartedStore.markCompleted(.syncStars)
            }
        }
        // HOM-126：用户在 Settings 切换「定时」/触发开关后，让 scheduler 重新装载
        // 定时器与监听。settings.autoTidySettings 是结构体，赋值替换即触发 .onChange。
        .onChange(of: settings.autoTidySettings) { _, _ in
            dependencies.autoTidyScheduler.reconfigure()
        }
        )
    }

    private var navigationWithReadmeLifecycle: AnyView {
        AnyView(navigationWithStartupLifecycle
        // 选中 repo 变化（含 nil）→ 驱动 README 加载 / 重置
        // 监听 selectedRepoID（Int64?）而非 selectedRepo（Repo? 派生）：
        // - Int64 是 value type，equality 100% 确定
        // - readmeVM 在 HomeView 已构造完成，不存在"@State 异步赋值"竞态
        // - 即便 RepoDetailView 因 nil 走 emptyState 被销毁，本 onChange 仍稳定触发
        .onChange(of: viewModel.selectedRepoID) { _, newID in
            if newID != nil {
                gettingStartedStore.markCompleted(.selectRepo)
            }
            handleSelectedRepoIDChange(newID)
        }
        // Trending repo 选中变化 → 驱动 Trending README 加载
        .onChange(of: selectedTrendingRepoID) { _, newID in
            handleTrendingRepoIDChange(newID)
        }
        // HOM-68：README 加载完成后把源 HTML 喂给翻译 VM，用于刷新 cacheIsStale。
        // 仅 Manage 详情页（selectedRepo 非 nil）需要，Trending 路径不接翻译入口。
        .onChange(of: readmeStateSignature) { _, _ in
            refreshTranslationSourceIfNeeded()
        }
        // 用户在详情页切换目标语言 → 重新预载缓存并复位显示。
        .onChange(of: settings.readmeTranslationLanguage) { _, newLanguage in
            handleReadmeTranslationLanguageChange(newLanguage)
        }
        )
    }

    private var navigationWithRoutingLifecycle: AnyView {
        AnyView(navigationWithReadmeLifecycle
        // 监听完整登录态变化：任何登录都立刻切 Manage、登出时回 Trending。
        //
        // 为什么监听整个 state 而非 isAuthenticated（Bool）：
        // - 同时覆盖"启动期从 Keychain 异步恢复登录"与"用户手动 Device Flow 登录"两条路径,
        //   两者都把页面切到 Manage 并恢复上次分类（不存在则回落 allStars）。
        // - 用 oldUserID / newUserID 对比 user.id（而非 isAuthenticated Bool）来判定
        //   "真正的账号变化"。原因（D-30 follow-up, 2026-06-13）：
        //     ① 多账号下「退出 A → 登录 B」是核心场景，必须感知 user.id 从 A → B 的变化,
        //        而 isAuthenticated 在 A→B 之间会经历 false 中间态，用 Bool 无法表达;
        //     ② 同时天然滤掉 .unauthenticated → .awaitingUserCode 等中间态（user.id 都是 nil）。
        .onChange(of: authSession.state) { oldState, newState in
            if newState.isAuthenticated {
                gettingStartedStore.markCompleted(.signIn)
            }
            handleAuthRoutingChange(oldState: oldState, newState: newState)
        }
        .onAppear {
            syncGettingStartedProgressFromCurrentState()
        }
        // Manage 页分类变化 → 持久化为"上次分类"，供下次启动恢复。
        // 仅在 Manage 页且非 Trending 时记录，避免把 Trending 写成 Manage 分类。
        .onChange(of: viewModel.selection) { _, newSelection in
            handleManageSelectionChange(newSelection)
        }
        .onChange(of: viewModel.totalCount) { _, _ in
            syncGettingStartedProgressFromCurrentState()
        }
        .onChange(of: settings.smartSearchMode) { _, newMode in
            if viewModel.smartSearchMode != newMode {
                viewModel.smartSearchMode = newMode
            }
        }
        // HOM-197（2026-06-13 dong4j）：用户在 Settings 拖「搜索结果过滤阈值」滑杆时
        // 即时 re-filter 当前语义搜索结果。
        //
        // 设计取舍：监听 settings 的字段而非把 viewModel 直接绑 settings——
        // 与现有 sortOption / hideArchived / hideForks / statusFilter 同款"settings ↔ vm
        // 单向 mirror"模式，让 viewModel 在单测 / Preview 场景里能完全独立于 AppSettings。
        // viewModel 的 didSet 自动触发 applyView()，纯本地 filter 不调 embedding API。
        .onChange(of: settings.aiSemanticSearchScoreThreshold) { _, newValue in
            if viewModel.semanticScoreThreshold != newValue {
                viewModel.semanticScoreThreshold = newValue
            }
        }
        // Manage ↔ Trending 切换时，记住各自的上次选择，切换回来时恢复
        .onChange(of: selectedSidebarPage) { oldPage, newPage in
            handleSidebarPageChange(oldPage: oldPage, newPage: newPage)
        }
        .onReceive(NotificationCenter.default.publisher(for: FirstRunOnboardingPreferences.browseTrendingNotification)) { _ in
            openTrendingFromFirstRunOnboarding()
        }
        .onReceive(NotificationCenter.default.publisher(for: FirstRunOnboardingPreferences.debugReplayNotification)) { _ in
            gettingStartedStore.reset()
            syncGettingStartedProgressFromCurrentState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .starcatCommandOpenGlobalSearch)) { _ in
            searchCenterViewModel.present()
        }
        .onReceive(NotificationCenter.default.publisher(for: .gettingStartedDidOrganizeRepo)) { _ in
            gettingStartedStore.markCompleted(.organizeRepo)
        }
        .onReceive(NotificationCenter.default.publisher(for: .gettingStartedDidUseSearch)) { _ in
            gettingStartedStore.markCompleted(.useSearch)
        }
        .onReceive(NotificationCenter.default.publisher(for: .gettingStartedDidOpenAI)) { _ in
            gettingStartedStore.markCompleted(.useAI)
        }
        .onChange(of: selectedActivityCategory) { _, newCategory in
            handleActivityCategoryChange(newCategory)
        }
        )
    }

    /// 开始使用清单既要响应用户动作，也要吸收当前 App 状态。
    /// 否则用户已登录 / 已同步 / 已选仓库后再显示面板时，`onChange` 不会回放历史状态。
    private func syncGettingStartedProgressFromCurrentState() {
        if authSession.state.isAuthenticated {
            gettingStartedStore.markCompleted(.signIn)
        }
        if viewModel.totalCount > 0 {
            gettingStartedStore.markCompleted(.syncStars)
        }
        if viewModel.selectedRepoID != nil {
            gettingStartedStore.markCompleted(.selectRepo)
        }
    }

    /// 本地结果回到 Manage 并复用现有列表加载流程，确保列表与详情状态仍由
    /// HomeViewModel 单一维护；网页资料直接交给系统浏览器。
    ///
    /// 语义（dong4j 2026-06-13 选定方案 B "导航到 repo"）：
    /// - **不**回填工具栏搜索框（避免 `owner/name` 被 FTS5 短语搜索 → 命中 0 的 bug；
    ///   见 `RepoRepository.searchFTS` / `DatabaseMigrationsV1.createReposFTS`，
    ///   `repos_fts` 只索引 `name/description/language/topics`，没 owner / full_name，
    ///   且 `unicode61` tokenizer 默认把 `/` 当分隔符）；
    /// - 主动**清空**当前搜索词，让列表回到 "全部 Stars" 全量视图；
    /// - 切到 `allStars` 让目标 repo 必在列表中；
    /// - 强制 reload 后写 `selectedRepoID`，由 RepoListView 的 ScrollViewReader 滚到目标行。
    ///
    /// 关键约束：`submitSearch("")` 必须**先于** `reloadItems` 调用，否则 reloadItems
    /// 会先用旧 searchQuery（即用户上次输入的关键词）拉一遍数据，再被清空触发第二次
    /// 拉取，列表会闪烁。
    private func openSearchCandidate(_ candidate: SearchCandidate) {
        switch candidate {
        case .repository(let candidate):
            guard let repo = candidate.localRepo else {
                openSearchRepositoryURL(candidate)
                return
            }
            selectedSidebarPage = .manage
            viewModel.selection = .allStars
            viewModel.submitSearch("")
            searchCenterViewModel.dismiss()
            Task {
                await viewModel.reloadItems(forceRefresh: true)
                viewModel.shouldScrollSelectedRepoIntoView = true
                viewModel.selectedRepoID = repo.id
            }
        case .reference(let reference):
            NSWorkspace.shared.open(reference.originalURL)
        }
    }

    private func openSearchRepositoryURL(_ candidate: RepositoryCandidate) {
        guard let url = URL(string: "https://github.com/\(candidate.identity.owner)/\(candidate.identity.name)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Browser Plugin 的 “Open in Starcat” 只对本地已 starred repo 开放。
    /// 这里复用 Search Center 本地结果跳转语义：切到 Manage / All Stars，清空搜索，
    /// 强制 reload 后选中目标 repo，让中栏滚动和右栏详情都由 HomeViewModel 单一维护。
    private func openCompanionRepository(_ repo: Repo, generateSummary: Bool = false) {
        selectedSidebarPage = .manage
        viewModel.selection = .allStars
        viewModel.submitSearch("")
        Task {
            await viewModel.reloadItems(forceRefresh: true)
            viewModel.shouldScrollSelectedRepoIntoView = true
            viewModel.selectedRepoID = repo.id
            guard generateSummary else { return }
            NotificationCenter.default.post(name: .gettingStartedDidOpenAI, object: nil)
            dependencies.telemetryManager.track(
                .aiPanelOpened,
                properties: [.source: .string("browser-plugin")]
            )
            // 详情页底部横条入口随 selectedRepoID 渲染；排到下一轮 main queue 再发请求，
            // 避免通知早于 RepoAIFloatingOverlay 挂载而被丢弃。
            let repoID = repo.id
            await MainActor.run {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .repoAIInlineGenerateSummaryRequested,
                        object: nil,
                        userInfo: ["repoId": repoID]
                    )
                }
            }
        }
    }

    /// 首次引导的「先逛 Trending」选择只负责路由，不触发登录 / 同步副作用。
    ///
    /// 未登录首启时底层本来就停在 Trending；这个入口主要覆盖 Debug 重看引导、
    /// 或已登录用户首次看到新版引导后明确选择先浏览热门项目的场景。
    private func openTrendingFromFirstRunOnboarding() {
        guard selectedSidebarPage != .trending else { return }
        selectedSidebarPage = .trending
    }

    private func copySearchRepositoryURL(_ candidate: RepositoryCandidate) {
        let value = "https://github.com/\(candidate.identity.owner)/\(candidate.identity.name)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func openSearchRepositoryAI(_ repo: Repo) {
        NotificationCenter.default.post(name: .gettingStartedDidOpenAI, object: nil)
        dependencies.telemetryManager.track(
            .aiPanelOpened,
            properties: [.source: .string("search")]
        )
        RepoAIWindowController.show(
            repo: repo,
            dependencies: dependencies,
            homeViewModel: viewModel
        )
    }

    /// 开始使用清单里的「选择仓库」只做最小导航：切回 Manage，并选中当前页第一条。
    /// 不强制刷新列表，避免用户已经在某个过滤条件下浏览时被突兀打断。
    private func selectFirstRepoForGettingStarted() {
        if selectedSidebarPage != .manage {
            selectedSidebarPage = .manage
        }
        if viewModel.selection.isTrending {
            viewModel.selection = savedManageSelection
        }
        guard viewModel.selectedRepoID == nil, let first = viewModel.items.first else { return }
        viewModel.shouldScrollSelectedRepoIntoView = true
        viewModel.selectedRepoID = first.id
    }

    /// 开始使用清单里的“添加标签”复用左侧 Tags 的管理入口，并直接弹出新建标签 sheet。
    private func openNewTagSheetForGettingStarted() {
        if selectedSidebarPage != .manage {
            selectedSidebarPage = .manage
        }
        showNewTagSheetOnTagManagementOpen = true
        showTagManagement = true
    }

    /// 开始使用清单里的 AI 入口必须走详情页底部横条。
    /// 这里不复用搜索结果的独立窗口入口，避免最后一步和用户在详情页看到的 AI 入口不一致。
    private func openSelectedRepoAIForGettingStarted() {
        guard let repo = viewModel.selectedRepo else {
            selectFirstRepoForGettingStarted()
            return
        }
        NotificationCenter.default.post(name: .gettingStartedDidOpenAI, object: nil)
        dependencies.telemetryManager.track(
            .aiPanelOpened,
            properties: [.source: .string("getting-started")]
        )
        NotificationCenter.default.post(
            name: .repoAIInlineGenerateSummaryRequested,
            object: nil,
            userInfo: ["repoId": repo.id]
        )
    }

    private func toggleSearchRepositoryStar(_ repo: Repo) async throws -> Bool {
        try await dependencies.starActionService.toggle(repo: repo)
        await viewModel.refreshAfterExternalStarChange()
        applyManageDetailSelectionPolicy()
        return dependencies.starredRegistry.contains(ghRepoId: repo.id)
    }

    private var sidebarColumn: some View {
        SidebarView(
            selectedPage: $selectedSidebarPage,
            selectedExploreMode: $selectedExploreMode,
            selectedTrendingLanguage: $selectedTrendingLanguage,
            selectedDiscoveryLanguage: $selectedDiscoveryLanguage,
            selectedDiscoveryTopic: $selectedDiscoveryTopic,
            selectedDiscoveryPlatform: $selectedDiscoveryPlatform,
            selectedActivityCategory: $selectedActivityCategory,
            showTagManagement: $showTagManagement,
            showReleaseTimeline: $showReleaseTimeline,
            onSelectRootPage: selectSidebarRootPage,
            onShowBatchAIPanel: {
                showBatchAIPanel = true
            },
            // 2026-06-02 21:38：透传给 SidebarHeaderView 让头像背景的语言色在 Trending 页也能联动
            currentTrendingRepo: selectedTrendingRepo,
            // 2026-06-05：Activity 页没有统一 Repo 模型，直接透传 ActivityItem 收口后的 accent 色。
            // 2026-06-11 D-29：weekly 分类没有 selectedActivityItem，单独走 weekly project 语言色派生路径,
            // 让 sidebar 头像背景在 weekly 内切换 project 时也能跟着 GitHub 语言色联动,
            // 与 manage / trending / activity-repo-backed 三家行为同构(详见 derivedActivityTintColor doc)。
            currentActivityTintColor: derivedActivityTintColor
        )
        .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 320)
    }

    private var contentColumn: some View {
        RepoListView(
            trendingRepository: trendingRepository,
            githubAPIClient: githubAPIClient,
            selectedPage: selectedSidebarPage,
            selectedExploreMode: $selectedExploreMode,
            selectedTrendingLanguage: $selectedTrendingLanguage,
            selectedTrendingRepoID: $selectedTrendingRepoID,
            selectedTrendingRepo: $selectedTrendingRepo,
            selectedDiscoveryLanguage: $selectedDiscoveryLanguage,
            selectedDiscoveryTopic: $selectedDiscoveryTopic,
            selectedDiscoveryPlatform: $selectedDiscoveryPlatform,
            selectedDiscoveryRepoID: $selectedDiscoveryRepoID,
            selectedDiscoveryRepo: $selectedDiscoveryRepo,
            selectedActivityCategory: $selectedActivityCategory,
            selectedActivityItem: $selectedActivityItem,
            showsAgentToolbarEntry: showsAgentToolbarEntry,
            onStartBatchAI: {
                // HOM-52：点击 banner"开始整理" → 弹 Options sheet。
                // 复用上一次 batchAIOptions，让"再开一次"沿用最近偏好。
                showBatchAIOptions = true
            },
            onShowBatchAIPanel: {
                showBatchAIPanel = true
            },
            onOpenSearchCenter: {
                searchCenterViewModel.present()
            },
            onOpenAgentWorkspace: {
                showAgentWorkspace = true
            },
            onOpenCompanionRepo: { repo in
                openCompanionRepository(repo)
            },
            onGenerateCompanionSummary: { repo in
                openCompanionRepository(repo, generateSummary: true)
            }
        )
        .navigationSplitViewColumnWidth(min: 420, ideal: 420, max: 520)
    }

    @ViewBuilder
    private var detailColumn: some View {
        if selectedSidebarPage == .activity {
            if selectedActivityCategory == .weekly {
                // MUL-176 followup：weekly 分类右侧详情独立路由到 WeeklyDetailView，
                // 不复用 ActivityDetailView——weekly 项目没有本地 Repo 缓存，且要展示
                // 期号 / 周刊原文等专属字段（详情数据来自 WeeklySelectionService）。
                WeeklyDetailView(item: dependencies.weeklySelectionService.selectedItem)
            } else {
                ActivityDetailView(item: selectedActivityItem)
            }
        } else if selectedSidebarPage == .trending, selectedExploreMode != .trending {
            DiscoveryDetailView(item: selectedDiscoveryRepo)
        } else {
            RepoDetailView(
                selectedTrendingRepo: selectedTrendingRepo
            )
        }
    }

    private func handleBackgroundPollersAuthChange(_ newState: AuthState) {
        if newState.isAuthenticated {
            dependencies.releasePoller.start()
            dependencies.openSSFScorePoller.start()
            dependencies.repoHealthPoller.start()
            startReadmePrefetchIfNeeded()
            startInitialWarmupIfNeeded()
            if !TestEnvironment.isRunning, settings.aiIndexAutoPrefetchEnabled {
                dependencies.semanticIndexBuilder.start()
            }
        } else {
            dependencies.releasePoller.stop()
            dependencies.openSSFScorePoller.stop()
            dependencies.repoHealthPoller.stop()
            stopReadmePrefetch()
            dependencies.initialWarmupCoordinator.cancel()
            dependencies.semanticIndexBuilder.cancel()
        }
    }

    private func handleFirstPageWrittenChange(_ newValue: Date?) {
        guard newValue != nil, authSession.state.isAuthenticated else { return }
        Task { @MainActor in
            await viewModel.refreshSidebar()
            await viewModel.reloadItems(forceRefresh: true)
            applyManageDetailSelectionPolicy()
        }
    }

    private func handleSelectedRepoIDChange(_ newID: Int64?) {
        // R-07：外部赋值（SearchCenter / 详情页"上一篇下一篇"）可能选中 page > 1 的 repo。
        // 这里集中调一次 ensureRepoVisible，让列表把 currentPage 推到含 repo 的位置 → 后续
        // RepoListView 的 ScrollViewReader 才能 scrollTo（target row 已在 items 切片内）。
        // 已在 items 内（用户点行触发的常态）时 no-op，无副作用。
        if let id = newID {
            dependencies.telemetryManager.track(
                .repoDetailOpened,
                properties: [.source: .string("manage")]
            )
            viewModel.ensureRepoVisible(repoId: id)
        }
        if let repo = viewModel.selectedRepo {
            readmeVM.load(repo: repo, isLoggedIn: authSession.state.isAuthenticated)
            // HOM-68：repo 变化时重置翻译态。源 HTML 尚未拿到，这里只重置 UI
            // 占位；下方监听 `readmeVM.state` 会在 .loaded 时再补一次 prepare
            // 让 cacheIsStale 计算到位。
            translationVM.prepare(
                repo: repo,
                sourceHtml: nil,
                targetLanguage: settings.readmeTranslationLanguage
            )
        } else {
            readmeVM.reset()
            translationVM.prepare(
                repo: nil,
                sourceHtml: nil,
                targetLanguage: settings.readmeTranslationLanguage
            )
        }
    }

    private func handleTrendingRepoIDChange(_ newID: String?) {
        if let id = newID {
            dependencies.telemetryManager.track(
                .repoDetailOpened,
                properties: [.source: .string("trending")]
            )
            // id 格式是 "owner/repo"，需要拆分成 owner 和 repo
            let parts = id.split(separator: "/", maxSplits: 1)
            if parts.count == 2 {
                readmeVM.loadTrending(owner: String(parts[0]), repo: String(parts[1]), isLoggedIn: authSession.state.isAuthenticated)
            }
        } else {
            readmeVM.reset()
        }
        // Trending repo 没有本地 Repo.id，HOM-68 第一版不为 trending 提供翻译入口
        // （翻译缓存需要 repo_id 外键，trending 走独立 trending_readmes 表，
        //  避免引入复杂的双写路径；用户切到 Manage 后再翻译即可）。这里只清状态。
        translationVM.prepare(
            repo: nil,
            sourceHtml: nil,
            targetLanguage: settings.readmeTranslationLanguage
        )
    }

    private func refreshTranslationSourceIfNeeded() {
        guard let repo = viewModel.selectedRepo else { return }
        if case .loaded(let html, _) = readmeVM.state {
            translationVM.prepare(
                repo: repo,
                sourceHtml: html,
                targetLanguage: settings.readmeTranslationLanguage
            )
        }
    }

    private func handleReadmeTranslationLanguageChange(_ newLanguage: ReadmeTranslationLanguage) {
        guard let repo = viewModel.selectedRepo else { return }
        let html: String? = {
            if case .loaded(let value, _) = readmeVM.state { return value }
            return nil
        }()
        translationVM.changeLanguage(
            to: newLanguage,
            repo: repo,
            sourceHtml: html
        )
    }

    private func handleAuthRoutingChange(oldState: AuthState, newState: AuthState) {
        let oldUserID = oldState.user?.id
        let newUserID = newState.user?.id

        // user id 没变（如 unauthenticated ↔ awaitingUserCode 中间态、authenticated(A) 内部刷新）
        // → 不动任何业务状态，避免误清缓存导致 UI 无谓重渲。
        guard oldUserID != newUserID else { return }

        if let newUser = newState.user {
            // 登录态变化统一走 `handleAuthenticatedEntry`（区分会话恢复 vs 真换账号）。
            handleAuthenticatedEntry(oldUserID: oldUserID, user: newUser)
        } else if oldUserID != nil {
            lastActivatedUserID = nil
            // 登出（newUserID == nil 且 oldUserID != nil）：保存当前 Manage selection（排除
            // trending）, 强制切回 Trending 并清除选择 + 清缓存。
            //
            // 为什么登出也要 reset：D-30 把 DB 切到了 `_anonymous`，新 DB 是空的；
            // 但 viewModel 内的 items / sidebar 计数还是 A 的，trending 视图不看这些字段,
            // 看起来无害 —— 但如果用户登出后立即又点 sidebar 上的 "全部仓库" 之类的
            // 入口（虽然该入口在未登录态下被隐藏，但防御性编程），残留数据会闪现。
            if !viewModel.selection.isTrending {
                savedManageSelection = viewModel.selection
            }
            viewModel.resetAllStateForUserSwitch()
            selectedSidebarPage = .trending
            viewModel.selection = .trending
            viewModel.selectedRepoID = nil
        }
    }

    private func handleManageSelectionChange(_ newSelection: SidebarItem) {
        guard selectedSidebarPage == .manage, !newSelection.isTrending else { return }
        savedManageSelection = newSelection
        settings.lastManageSelectionRaw = newSelection.persistedRawValue
        resetSmartCollectionRepoSelectionIfNeeded(for: newSelection)
        applyManageDetailSelectionPolicy()
    }

    private func handleSidebarPageChange(oldPage: SidebarRootPage, newPage: SidebarRootPage) {
        trackSidebarPageOpened(newPage)

        // 保存旧页面的状态
        switch oldPage {
        case .manage:
            // 只记录真实的 Manage 分类。启动期 default(.manage) → .task 改成 .trending
            // 会让这里读到 .trending，必须排除，否则污染"上次分类"导致登录后恢复成 trending。
            if !viewModel.selection.isTrending {
                savedManageSelection = viewModel.selection
            }
        case .trending:
            savedTrendingLanguage = selectedTrendingLanguage
        case .activity:
            savedActivityCategory = selectedActivityCategory
        }

        // 清除所有 repo 选中状态，避免详情页显示残留
        viewModel.selectedRepoID = nil
        selectedTrendingRepoID = nil
        selectedTrendingRepo = nil
        selectedDiscoveryRepoID = nil
        selectedDiscoveryRepo = nil
        selectedActivityItem = nil
        // MUL-176 followup：切走 Activity 时一并清掉周刊选中，避免下次回 Activity
        // 时右侧详情停留在上次的周刊项目上。
        dependencies.weeklySelectionService.clearSelection()

        // 恢复新页面的状态
        switch newPage {
        case .manage:
            // 如果当前 selection 是 .trending（从 Trending 页切过来时设置的），
            // 恢复 Manage 上次的分类选择
            if viewModel.selection.isTrending {
                viewModel.selection = savedManageSelection
            }
        case .trending:
            // 确保 selection 标记为 trending，并恢复上次的语言选择
            viewModel.selection = .trending
            selectedTrendingLanguage = savedTrendingLanguage
        case .activity:
            selectedActivityCategory = savedActivityCategory
        }
    }

    private func trackSidebarPageOpened(_ page: SidebarRootPage) {
        switch page {
        case .manage:
            dependencies.telemetryManager.track(.manageOpened)
        case .trending:
            // 探索页沿用历史 `trending` root page，遥测事件使用用户可见的新语义。
            dependencies.telemetryManager.track(.exploreOpened)
        case .activity:
            dependencies.telemetryManager.track(.activityOpened)
        }
    }

    private func handleActivityCategoryChange(_ newCategory: ActivityCategory) {
        guard selectedSidebarPage == .activity else { return }
        savedActivityCategory = newCategory
        settings.lastActivityCategoryRaw = newCategory.persistedRawValue
        // Activity 分类切换先清空旧详情；是否在新列表稳定后自动选第一条由
        // settings.openFirstDetailOnCategoryChange 统一决定。
        selectedActivityItem = nil
        dependencies.weeklySelectionService.clearSelection()
        // 过渡期间仅抑制头像 tint 补间；草坪蛇不参与（见 SidebarAnimationCoordinator）。
        dependencies.sidebarAnimationCoordinator.beginActivityCategoryTransition()
    }

    /// Sidebar 顶部 root page 切换入口。
    ///
    /// 为什么不让 Sidebar 直接写 `selectedSidebarPage`：
    /// 从 Trending / Activity 回 Manage 时，Manage 中栏马上会重新挂载。如果先切
    /// `selectedSidebarPage`，再在 `.onChange` 里恢复 `viewModel.selection`，SwiftUI
    /// 可能经历一帧“Manage 页面 + 旧 selection”的中间态，随后又按真实 selection
    /// 重建列表。这里在进入 Manage 前先把 selection 准备好，让首帧就是目标分类。
    ///
    /// 只提前处理 `.manage`：切到 Trending 时仍由既有 `.onChange` 写 `.trending`，
    /// 避免当前 Manage 列表在离场前先被 `.trending` selection 清空。
    private func selectSidebarRootPage(_ page: SidebarRootPage) {
        guard selectedSidebarPage != page else { return }
        if page == .manage, viewModel.selection.isTrending {
            viewModel.selection = savedManageSelection
        }
        selectedSidebarPage = page
    }

    // MARK: - 辅助

    /// HomeView 首次挂载时的启动编排。
    ///
    /// 这段逻辑原本直接写在 `.task {}` modifier 内；随着主界面状态监听增加，
    /// SwiftUI 的整条 body modifier 链开始触发 type-check 超时。抽成普通 async 方法后，
    /// 业务顺序不变，但编译器不需要在巨型 View 表达式里推断整段启动流程。
    private func bootstrapHome() async {
        // 启动 / 重新进入 HomeView 时默认回三栏展开。运行期用户手动缩窗时，
        // 系统仍可按窗口宽度自动折叠 sidebar；这里只负责启动态保真。
        columnVisibility = .all

        // HOM-52：批量整理服务挂接 Sidebar 刷新回调。
        // 每应用一批标签就 refreshSidebar，让 Sidebar Tags 段计数实时跟随；
        // 不在 viewModel.reloadItems()——避免大批次每个 repo 都全量重拉列表。
        dependencies.batchAIQueueService.onTagsChanged = {
            Task { @MainActor in
                await viewModel.refreshSidebar()
            }
        }

        // HOM-126：启动自动后台 AI 整理调度器。
        // - `start()` 内部幂等，HomeView 多次进入只装一次。
        // - 启动后挂启动延迟（60s 后触发一次）+ 24h 定时器 + onBatchFinished 回调。
        // - 同步完成事件由下方 `.onChange(of: syncManager.state)` 转发给调度器
        //   （理由见 AutoTidyScheduler.notifySyncStateChanged 文档）。
        dependencies.autoTidyScheduler.start()

        // 2026-06-13 dong4j 补救 A：「启动时自动后台预拉」首启即时门控。
        // 多数首启场景下登录态恢复未完成，这里走不到 isAuthenticated 分支；
        // 实际启动由上方 `.onChange(of: authSession.state)` 在恢复完成后触发。
        // 当用户重进 HomeView 时（已登录态稳定）则在这里直接启动。
        // `start()` 对 `.running` 幂等，与 onChange 路径不会双启。
        // 首次 README / Health 预热不在这里直接安排：新用户首次登录后 stars 仍可能在分页同步，
        // 必须等 SyncManager 完整完成后交给 InitialRepoWarmupCoordinator 恢复/启动。
        if authSession.state.isAuthenticated {
            dependencies.releasePoller.start()
            dependencies.openSSFScorePoller.start()
            dependencies.repoHealthPoller.start()
        }
        startReadmePrefetchIfNeeded()
        startInitialWarmupIfNeeded()

        if !TestEnvironment.isRunning,
           authSession.state.isAuthenticated,
           settings.aiIndexAutoPrefetchEnabled {
            dependencies.semanticIndexBuilder.start()
        }

        syncViewModelSettingsFromAppSettings()

        // 恢复上次保存的 Manage 分类（跨启动）。无记录时 persistedRawValue 解码回落 allStars。
        savedManageSelection = SidebarItem(persistedRawValue: settings.lastManageSelectionRaw)
        savedActivityCategory = ActivityCategory(persistedRawValue: settings.lastActivityCategoryRaw)

        // 决定初始页面：
        // - 已登录 → Manage + 上次分类（同步策略见 `handleAuthenticatedEntry`）
        // - 未登录 → Trending
        //
        // 注意：启动期 Keychain 恢复登录是异步的（见 AuthSession.restoreSessionIfAvailable），
        // 多数情况下这里跑到时 state 还是 .unauthenticated（恢复未完成）→ 先进 Trending，
        // 待恢复完成由下方 onChange(of: authSession.state) 纠正到 Manage。
        if case .authenticated(let user) = authSession.state {
            handleAuthenticatedEntry(oldUserID: nil, user: user)
        } else {
            selectedSidebarPage = .trending
            viewModel.selection = .trending
            await viewModel.refreshSidebar()
        }

        // 2026-06-11 dong4j：trending sidebar 语言列表改用后端聚合接口驱动。
        // 启动后异步拉一次（不阻塞 UI），后端不可达 / 401 时 store 内部退化到 fallbackList。
        // 不放在 if isAuthenticated 分支：未登录用户进 Trending 也需要语言列表，
        // 而后端 `/api/v1/languages` 不依赖 GitHub OAuth，仅依赖 Bearer Auth（用户 API Key 已就位）。
        Task {
            await dependencies.trendingLanguageStore.reload()
            await dependencies.exploreCatalogStore.reload()
        }
    }

    /// README 预拉与 AI 语义索引是两条后台链路。这里单独封装预拉门控，
    /// 避免把登录态、测试 host、用户开关散落在 SwiftUI modifier 链里。
    ///
    /// 本方法只启动系统调度器，不安排首次 warmup；首次作业由
    /// `startInitialWarmupIfNeeded()` 在 stars 同步完成后触发。
    private func startReadmePrefetchIfNeeded() {
        guard !TestEnvironment.isRunning,
              authSession.state.isAuthenticated,
              settings.readmePrefetchEnabled else { return }
        dependencies.readmePrefetchPoller.start()
    }

    /// 登出或关闭设置时停止调度器。已完成的本地 README 缓存保留；
    /// 停止只表示不再继续后台消耗网络与 GitHub API 配额。
    private func stopReadmePrefetch() {
        dependencies.readmePrefetchPoller.stop()
    }

    /// 设置页 Toggle 的即时生效入口。未登录时只保存偏好，不提前启动后台任务；
    /// 等登录态恢复后再由 `startReadmePrefetchIfNeeded()` 统一判断。
    private func applyReadmePrefetchSetting(_ enabled: Bool) {
        guard !TestEnvironment.isRunning,
              authSession.state.isAuthenticated else { return }

        if enabled {
            dependencies.readmePrefetchPoller.start()
            startInitialWarmupIfNeeded()
        } else {
            dependencies.readmePrefetchPoller.stop()
            if let userID = authSession.state.user?.id {
                Task { @MainActor in
                    await dependencies.initialWarmupCoordinator.disable(userID: userID)
                }
            }
        }
    }

    /// stars 同步完成后，启动或恢复首次 README / Repo Health 预热作业。
    ///
    /// AuthSession 登录态只代表 token 可用，不代表用户的 stars 已经全部分页写入本地库。新用户首次
    /// 登录时 SyncManager 可能仍在同步后续页；如果 warmup 提前查候选项，会只覆盖部分 stars。
    /// 因此首次作业统一挂在 `.completed` 之后，并由 coordinator 持久化恢复点。
    private func startInitialWarmupIfNeeded() {
        guard !TestEnvironment.isRunning,
              let userID = authSession.state.user?.id,
              settings.readmePrefetchEnabled,
              case .completed = syncManager.state else { return }

        Task { @MainActor in
            await dependencies.initialWarmupCoordinator.startAfterStarsSyncIfNeeded(
                userID: userID,
                isEnabled: settings.readmePrefetchEnabled
            )
        }
    }

    /// 标签管理 sheet 关闭后刷新 Sidebar 与当前列表。放在独立方法里能减少
    /// `HomeView.body` 的闭包推断压力；行为仍保持 W4 A6 的原始约束。
    private func handleTagManagementDismissed() {
        showNewTagSheetOnTagManagementOpen = false
        Task {
            await viewModel.refreshSidebar()
            await viewModel.reloadItems(forceRefresh: true)
        }
    }

    private func syncViewModelSettingsFromAppSettings() {
        // W4-4 D1/D2:把持久化的视图偏好同步到 viewModel,避免首次 reloadItems 用默认值
        // 然后 onAppear 才纠正导致列表抖动一次。
        if viewModel.sortOption != settings.repoSortOption {
            viewModel.sortOption = settings.repoSortOption
        }
        if viewModel.hideArchived != settings.hideArchived {
            viewModel.hideArchived = settings.hideArchived
        }
        if viewModel.hideForks != settings.hideForks {
            viewModel.hideForks = settings.hideForks
        }
        if viewModel.statusFilter != settings.statusFilter {
            viewModel.statusFilter = settings.statusFilter
        }
        if viewModel.libraryFilter != settings.libraryFilter {
            viewModel.libraryFilter = settings.libraryFilter
        }
        if viewModel.smartSearchMode != settings.smartSearchMode {
            viewModel.smartSearchMode = settings.smartSearchMode
        }
        // HOM-197（2026-06-13 dong4j）：把语义搜索过滤阈值从 settings 注入 viewModel。
        // 与 sortOption / hideArchived / hideForks / statusFilter 同款"View 启动期单向同步"。
        // viewModel 内 didSet 会自动调 applyView()，但首启时 items 还没填充，applyView
        // 是 no-op；真正生效在第一次 reloadItems 完成 + applyView 后。
        if viewModel.semanticScoreThreshold != settings.aiSemanticSearchScoreThreshold {
            viewModel.semanticScoreThreshold = settings.aiSemanticSearchScoreThreshold
        }
    }

    private func reloadManageSelectionIfNeeded() async {
        // HOM-46：selection.didSet 已经把未过期缓存同步上屏。
        // 这里如果再进 reloadItems()，即便最终命中 cache early-return，也会创建一次
        // 无意义的异步任务并触发若干同值状态写入；这条路径在 1 条 repo 的分类上也会被用户感知为顿挫。
        // 过期缓存 / 无缓存仍继续 reload，保留首次加载和 SWR 刷新语义。
        guard selectedSidebarPage == .manage,
              !viewModel.hasCachedItems,
              !viewModel.isKnownEmptyGitHubStarListSelection else { return }
        await viewModel.reloadItems()
        applyManageDetailSelectionPolicy()
    }

    private func reloadManageSearchIfNeeded() async {
        // Trending / Activity 有自己的数据模型；这里不应触发 Manage reload。
        guard selectedSidebarPage == .manage else { return }
        await viewModel.reloadItems()
        applyManageDetailSelectionPolicy()
    }

    private func syncSmartSearchModeToSettings() {
        settings.smartSearchMode = viewModel.smartSearchMode
    }

    /// 监听详情页 Release 订阅状态变化，只刷新 Sidebar 统计。
    ///
    /// 订阅入口在详情页组件内，和 Sidebar 没有直接 binding；用轻量通知可以避免把
    /// HomeViewModel 传进 Release 组件，同时不触发中栏列表重载。
    private func observeReleaseSubscriptionChanges() async {
        let stream = NotificationCenter.default.notifications(named: .releaseSubscriptionDidChange)
        for await _ in stream {
            guard !Task.isCancelled else { break }
            await viewModel.refreshSidebar()
        }
    }

    private func reloadAfterSyncIfNeeded() async {
        guard case .completed = syncManager.state else { return }
        startInitialWarmupIfNeeded()
        if case .authenticated(let user) = authSession.state {
            await syncGitHubStarListsAndRefreshSidebar(login: user.login)
        } else {
            await viewModel.refreshSidebar()
        }
        guard syncManager.lastRunWroteRepos else { return }
        // GitHub Stars List 已在上方随 stars 同步完成刷新；这里只处理 repo 数据写入后的列表重载。
        await viewModel.reloadItems(forceRefresh: true)
        applyManageDetailSelectionPolicy()
    }

    private func applyManageDetailSelectionPolicy() {
        guard selectedSidebarPage == .manage else { return }
        guard settings.openFirstDetailOnCategoryChange else { return }
        // Smart Collections 的 nil selection 是右栏集合浏览入口，不能被“选第一条”覆盖。
        guard !viewModel.selection.isSmartCollectionsSurface else { return }
        guard !viewModel.isLoading, viewModel.loadError == nil else { return }
        guard viewModel.selectedRepo == nil, let first = viewModel.items.first else { return }
        viewModel.selectedRepoID = first.id
    }

    private func resetSmartCollectionRepoSelectionIfNeeded(for selection: SidebarItem) {
        guard selection.isSmartCollectionsSurface, viewModel.selectedRepoID != nil else { return }
        // Smart Collections 用 nil 表达两种产品态：
        // - 首页：右栏显示未选中占位示意图
        // - 具体集合：右栏显示集合浏览面板
        // 切入这个 surface 时必须退出上一分类/上一集合的 repo 详情，且不受“自动打开第一条”偏好影响。
        viewModel.selectedRepoID = nil
    }

    /// Activity 页面顶部头像卡的 tint 色派生（**D-29 修订**, 2026-06-11）。
    ///
    /// 取色优先级（与 `SidebarHeaderView.sidebarTintColor` 第 3 档对齐 — Activity 页面 5 类详情）：
    /// 1. **weekly 分类 + 已选中 weekly project**：
    ///    - 有语言 → `LanguageColor.color(for:)` 走 GitHub 语言色映射;
    ///    - 无语言 → `ActivityCategory.weekly.iconColor` 兜底分类色。
    /// 2. **其它分类**（公告 / 发布 / 关注 / 星标 / 仓库 / 建议）→ `selectedActivityItem?.accentColor`
    ///    （`ActivityItem.accentColor` 已在源头收口"语言色优先 / 分类色兜底"语义,详见
    ///    `ActivityModels.swift`）。
    ///
    /// **D-29 修复点**：weekly 分类下没有 `selectedActivityItem`（weekly 选中走
    /// `dependencies.weeklySelectionService.selectedProject` 真源,与 ActivityItem 模型解耦）,
    /// 此前 `currentActivityTintColor` 只透传 `selectedActivityItem?.accentColor` 永远 nil,
    /// 导致 sidebar 头像背景在 weekly 内切换 project 时不变(走系统 .accentColor 兜底)。
    /// 修法把 weekly project 的语言色派生收口到本 computed property,与 manage / trending /
    /// activity-repo-backed 三家行为同构 — 切 repo / project 时头像背景跟着 GitHub 语言色变化。
    ///
    /// 注:`WeeklySelectionService` 是 `@MainActor @Observable`,本 computed property 在 view body
    /// 内被读取时 SwiftUI Observation 框架自动订阅 `selectedProject` 变化 → 重新计算 →
    /// SidebarHeaderView 收到新 tint → 头像背景平滑过渡。
    private var derivedActivityTintColor: Color? {
        if selectedSidebarPage == .activity, selectedActivityCategory == .weekly,
           let project = dependencies.weeklySelectionService.selectedItem {
            if let language = project.language, !language.isEmpty {
                return LanguageColor.color(for: language)
            }
            return ActivityCategory.weekly.iconColor
        }
        return selectedActivityItem?.accentColor
    }

    /// README 加载状态的纯文本签名，用于驱动 `.onChange` 在 .loaded 切换时刷新翻译 VM。
    ///
    /// 不直接 `.onChange(of: readmeVM.state)`：`LoadState.loaded(html, cachedAt)` 的
    /// `html` 字段在 SWR 后台刷新 304 时会保留不变但 `cachedAt` 会变；用 html 的
    /// 长度 + 状态 case 名做签名即可在「真正拿到新 HTML」时触发一次回调，避免
    /// 304 时再做一遍 hash 比对。
    private var readmeStateSignature: String {
        switch readmeVM.state {
        case .idle:           return "idle"
        case .loading:        return "loading"
        case .empty:          return "empty"
        case .requiresLogin:  return "requires-login"
        case .error:          return "error"
        case .loaded(let html, _):
            return "loaded:\(html.count)"
        }
    }

    /// HOM-52：用户点击 banner"开始整理"后的真正启动入口。
    ///
    /// 流程：
    /// 1. 从 RepoRepository 拉取 fetchUntagged() 作为本次整理输入集（不依赖 viewModel.items，
    ///    避免搜索过滤后的子集被误处理）。
    /// 2. 调 BatchAIQueueService.start 启动队列。
    /// 3. 立刻打开进度面板让用户看到第一帧。
    ///
    /// 错误处理：fetchUntagged 失败仅记日志，不弹错——这是用户主动触发的场景，
    /// 失败时按钮仍可继续点（dependencies 状态未变，第二次点击会重试）。
    private func startBatchAIIntegration() async {
        do {
            try dependencies.entitlementGate.requirePro(.batchAI)
        } catch {
            paywallContext = ProPaywallContext(feature: .batchAI, message: error.localizedDescription)
            return
        }
        let untagged: [Repo]
        do {
            untagged = try await dependencies.repoRepository.fetchUntagged()
        } catch {
            AppLog.ai.error("[batch-ai] fetchUntagged failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard !untagged.isEmpty else { return }
        dependencies.batchAIQueueService.start(repos: untagged, options: batchAIOptions)
        showBatchAIPanel = true
    }

    private var homePaywallBinding: Binding<ProPaywallContext?> {
        Binding(
            get: {
                paywallContext ?? translationVM.paywallContext
            },
            set: { newValue in
                if newValue == nil {
                    paywallContext = nil
                    translationVM.dismissPaywall()
                } else {
                    paywallContext = newValue
                }
            }
        )
    }

    /// 登录态变为已认证时的统一入口（冷启动恢复 / Device Flow / 账号切换）。
    ///
    /// **关键分支**（2026-06-17 dong4j 回归修复）：
    /// - `oldUserID == nil` → 会话恢复或首次登录：进程内无旧账号内存快照，**不** reset；
    ///   走本地 DB 上屏 + `performFullSyncIfStale`（5min TTL）。
    /// - `oldUserID != nil && oldUserID != user.id` → 真换账号：reset + forceRefresh + 全量 sync。
    ///
    /// `lastActivatedUserID` 去重 onChange 与 `.task` 双路径重复激活。
    private func handleAuthenticatedEntry(oldUserID: Int64?, user: GitHubUserDTO) {
        guard lastActivatedUserID != user.id else { return }
        lastActivatedUserID = user.id

        let isAccountSwitch = oldUserID != nil && oldUserID != user.id
        if isAccountSwitch {
            viewModel.resetAllStateForUserSwitch()
        }

        let wasAlreadyOnManage = selectedSidebarPage == .manage
        selectedSidebarPage = .manage
        if wasAlreadyOnManage {
            dependencies.telemetryManager.track(.manageOpened)
        }
        viewModel.selection = savedManageSelection

        Task { @MainActor in
            await syncGitHubStarListsAndRefreshSidebar(login: user.login)

            if !isManageSelectionValid(viewModel.selection) {
                viewModel.selection = .allStars
            }

            if selectedSidebarPage == .manage {
                await viewModel.reloadItems(forceRefresh: isAccountSwitch)
                applyManageDetailSelectionPolicy()
            }

            if isAccountSwitch {
                syncManager.performFullSync(userID: user.id)
            } else {
                syncManager.performFullSyncIfStale(userID: user.id)
            }
        }
    }

    private func syncGitHubStarListsAndRefreshSidebar(login: String) async {
        await dependencies.githubStarListSyncService.sync(login: login)
        await viewModel.refreshSidebar()
    }

    /// 校验一个 Manage 分类当前是否仍然有效（用于跨启动恢复时兜底）。
    ///
    /// - `.allStars` / `.untagged` / `.trending` 恒有效（不依赖具体数据）。
    /// - `.language` / `.tag` 依赖本地库现状：tag 被删、或某语言已无 repo（如缓存被清）时视为无效。
    ///   调用方应在 `refreshSidebar()` 之后调用，确保 `viewModel.tags` / `languageStats` 已加载。
    /// 无效时调用方回落到 `.allStars`，对应需求"获取不到之前的分类 → allStars"。
    private func isManageSelectionValid(_ item: SidebarItem) -> Bool {
        switch item {
        case .trending:
            // .trending 不是合法的 Manage 分类（属于 Trending 页），恢复时应回落 allStars
            return false
        case .allStars, .untagged, .allLanguages, .smartCollectionsHome, .smartCollection:
            return true
        case .userSmartCollection(let id):
            return viewModel.userSmartCollections.contains { $0.id == id }
        case .language(let lang):
            // SidebarItem.language(nil) 对应 LanguageStat.language == ""（GitHub 无主语言）
            return viewModel.languageStats.contains { $0.language == (lang ?? "") }
        case .tag(let tagId):
            return viewModel.tags.contains { $0.id == tagId }
        case .githubStarListUngrouped:
            return true
        case .githubStarList(let id):
            return viewModel.githubStarLists.contains { $0.id == id }
        }
    }

}
