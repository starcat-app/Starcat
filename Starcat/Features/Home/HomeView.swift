//
//  HomeView.swift
//  Starcat
//
//  登录后的主界面：NavigationSplitView 三栏。
//
//  布局：
//  Sidebar（240pt）│  RepoList（300-360pt）│  RepoDetail（剩余）
//
//  顶部操作按三栏职责拆分：
//  - Sidebar：同步、标签管理
//  - RepoList：搜索、状态筛选、排序、多选
//  - RepoDetail：打开外链、复制 clone URL
//
//  数据生命周期：
//  - onAppear：刷新 Sidebar + 列表
//  - 当 selection / searchQuery 变 → 自动 reload
//  - 当 SyncManager.state 变为 completed → 刷新 Sidebar + 列表
//

import SwiftUI

struct HomeView: View {

    @Environment(AuthSession.self) private var authSession
    @Environment(SyncManager.self) private var syncManager
    @Environment(AppSettings.self) private var settings

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

    /// W4 A2：标签管理 sheet 显示状态。
    @State private var showTagManagement: Bool = false

    /// Sidebar 顶部三入口的当前页。
    ///
    /// 这层状态只描述“左栏正在展示哪组导航结构”，和 `HomeViewModel.selection`
    /// 分开维护，避免 Trending / Search 后续扩展时污染 repo 管理筛选模型。
    @State private var selectedSidebarPage: SidebarRootPage = .manage

    /// Trending 页从左侧语言列表驱动的语言筛选。
    @State private var selectedTrendingLanguage: TrendingLanguage = .all

    /// Trending 当前选中的 repo ID（用于驱动 README 加载）。
    @State private var selectedTrendingRepoID: String?

    /// Trending 当前选中的 repo 完整数据（用于右侧详情页展示元信息）。
    @State private var selectedTrendingRepo: TrendingRepo?

    /// Manage 页面记住上次选择的分类（language / tag / allStars / untagged）。
    /// 切换到 Trending 再回来时恢复，避免用户丢失浏览上下文。
    @State private var savedManageSelection: SidebarItem = .allStars

    /// Trending 页面记住上次选择的语言。
    /// 切换到 Manage 再回来时恢复，避免用户丢失浏览上下文。
    @State private var savedTrendingLanguage: TrendingLanguage = .all

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
        tagRepository: any TagRepositoryProtocol,
        repoTagRepository: any RepoTagRepositoryProtocol,
        repoNoteRepository: any RepoNoteRepositoryProtocol,
        trendingRepository: any TrendingRepositoryProtocol,
        githubAPIClient: any GitHubAPIClientProtocol
    ) {
        _viewModel = State(initialValue: HomeViewModel(
            repository: repository,
            tagRepository: tagRepository,
            repoTagRepository: repoTagRepository,
            repoNoteRepository: repoNoteRepository
        ))
        _readmeVM = State(initialValue: ReadmeViewModel(api: readmeAPI))
        _tagMgmtVM = State(initialValue: TagManagementViewModel(
            tagRepository: tagRepository,
            repoTagRepository: repoTagRepository
        ))
        _trendingRepository = State(initialValue: trendingRepository)
        _githubAPIClient = State(initialValue: githubAPIClient)
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selectedPage: $selectedSidebarPage,
                selectedTrendingLanguage: $selectedTrendingLanguage,
                showTagManagement: $showTagManagement
            )
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } content: {
            RepoListView(
                trendingRepository: trendingRepository,
                githubAPIClient: githubAPIClient,
                selectedPage: selectedSidebarPage,
                selectedTrendingLanguage: $selectedTrendingLanguage,
                selectedTrendingRepoID: $selectedTrendingRepoID,
                selectedTrendingRepo: $selectedTrendingRepo
            )
                .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 480)
        } detail: {
            RepoDetailView(
                selectedTrendingRepo: selectedTrendingRepo
            )
        }
        .environment(viewModel)
        .environment(readmeVM)
        .mainWindowFrameAutosave()
        .sheet(isPresented: $showTagManagement, onDismiss: {
            // W4 A6：标签管理 sheet 关闭后 → 刷新 Sidebar Tags 段 + 当前列表
            // （用户可能在 sheet 里增删 / 合并标签，Sidebar 与列表都要跟着变）
            Task {
                await viewModel.refreshSidebar()
                await viewModel.reloadItems()
            }
        }) {
            TagManagementView(viewModel: tagMgmtVM)
        }
        .task {
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
            
            // 恢复上次保存的 Manage 分类（跨启动）。无记录时 persistedRawValue 解码回落 allStars。
            savedManageSelection = SidebarItem(persistedRawValue: settings.lastManageSelectionRaw)

            // 决定初始页面：
            // - 已登录 → Manage + 上次分类，并触发一次后台全量同步
            // - 未登录 → Trending
            //
            // 注意：启动期 Keychain 恢复登录是异步的（见 AuthSession.restoreSessionIfAvailable），
            // 多数情况下这里跑到时 state 还是 .unauthenticated（恢复未完成）→ 先进 Trending，
            // 待恢复完成由下方 onChange(of: authSession.state) 纠正到 Manage。
            if authSession.state.isAuthenticated {
                selectedSidebarPage = .manage
                viewModel.selection = savedManageSelection
                if case .authenticated(let user) = authSession.state {
                    syncManager.performFullSync(userID: user.id)
                }
            } else {
                selectedSidebarPage = .trending
                viewModel.selection = .trending
            }

            await viewModel.refreshSidebar()

            // 校验恢复的分类是否仍存在（如 tag / language 已被删 / 无 repo）→ 回落 allStars。
            // refreshSidebar 已把 tags / languageStats 从本地库加载完毕，可安全校验。
            if selectedSidebarPage == .manage, !isManageSelectionValid(viewModel.selection) {
                viewModel.selection = .allStars
            }

            await viewModel.reloadItems()
        }
        // selection 变化 → 重新加载列表
        .task(id: viewModel.selection) {
            await viewModel.reloadItems()
        }
        // searchQuery 变化 → 防抖 250ms → 重新加载
        .task(id: viewModel.searchQuery) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await viewModel.reloadItems()
        }
        // 同步完成 → 刷新 Sidebar + 当前列表
        .task(id: syncManager.state) {
            if case .completed = syncManager.state {
                await viewModel.refreshSidebar()
                await viewModel.reloadItems()
            }
        }
        // 选中 repo 变化（含 nil）→ 驱动 README 加载 / 重置
        // 监听 selectedRepoID（Int64?）而非 selectedRepo（Repo? 派生）：
        // - Int64 是 value type，equality 100% 确定
        // - readmeVM 在 HomeView 已构造完成，不存在"@State 异步赋值"竞态
        // - 即便 RepoDetailView 因 nil 走 emptyState 被销毁，本 onChange 仍稳定触发
        .onChange(of: viewModel.selectedRepoID) { _, _ in
            if let repo = viewModel.selectedRepo {
                readmeVM.load(repo: repo, isLoggedIn: authSession.state.isAuthenticated)
            } else {
                readmeVM.reset()
            }
        }
        // Trending repo 选中变化 → 驱动 Trending README 加载
        .onChange(of: selectedTrendingRepoID) { _, newID in
            if let id = newID {
                // id 格式是 "owner/repo"，需要拆分成 owner 和 repo
                let parts = id.split(separator: "/", maxSplits: 1)
                if parts.count == 2 {
                    readmeVM.loadTrending(owner: String(parts[0]), repo: String(parts[1]), isLoggedIn: authSession.state.isAuthenticated)
                }
            } else {
                readmeVM.reset()
            }
        }
        // 监听完整登录态变化：任何登录都立刻切 Manage、登出时回 Trending。
        //
        // 为什么监听整个 state 而非 isAuthenticated（Bool）：
        // - 同时覆盖"启动期从 Keychain 异步恢复登录"与"用户手动 Device Flow 登录"两条路径，
        //   两者都把页面切到 Manage 并恢复上次分类（不存在则回落 allStars）。
        // - 用 oldState.isAuthenticated 判断登出，避免 .unauthenticated → .awaitingUserCode
        //   等中间态被误判。
        .onChange(of: authSession.state) { oldState, newState in
            if newState.isAuthenticated {
                // 任何登录（启动恢复 / 手动登录）→ 默认 Manage + 上次分类
                selectedSidebarPage = .manage
                let restored = savedManageSelection
                viewModel.selection = isManageSelectionValid(restored) ? restored : .allStars
            } else if oldState.isAuthenticated {
                // 登出：保存当前 Manage selection，强制切回 Trending 并清除选择
                savedManageSelection = viewModel.selection
                selectedSidebarPage = .trending
                viewModel.selection = .trending
                viewModel.selectedRepoID = nil
            }
        }
        // Manage 页分类变化 → 持久化为"上次分类"，供下次启动恢复。
        // 仅在 Manage 页且非 Trending 时记录，避免把 Trending 写成 Manage 分类。
        .onChange(of: viewModel.selection) { _, newSelection in
            guard selectedSidebarPage == .manage, !newSelection.isTrending else { return }
            savedManageSelection = newSelection
            settings.lastManageSelectionRaw = newSelection.persistedRawValue
        }
        // Manage ↔ Trending 切换时，记住各自的上次选择，切换回来时恢复
        .onChange(of: selectedSidebarPage) { oldPage, newPage in
            // 保存旧页面的状态
            switch oldPage {
            case .manage:
                savedManageSelection = viewModel.selection
            case .trending:
                savedTrendingLanguage = selectedTrendingLanguage
            case .search:
                break
            }

            // 清除所有 repo 选中状态，避免详情页显示残留
            viewModel.selectedRepoID = nil
            selectedTrendingRepoID = nil
            selectedTrendingRepo = nil

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
            case .search:
                viewModel.searchQuery = ""
            }
        }
    }

    // MARK: - 辅助

    /// 校验一个 Manage 分类当前是否仍然有效（用于跨启动恢复时兜底）。
    ///
    /// - `.allStars` / `.untagged` / `.trending` 恒有效（不依赖具体数据）。
    /// - `.language` / `.tag` 依赖本地库现状：tag 被删、或某语言已无 repo（如缓存被清）时视为无效。
    ///   调用方应在 `refreshSidebar()` 之后调用，确保 `viewModel.tags` / `languageStats` 已加载。
    /// 无效时调用方回落到 `.allStars`，对应需求"获取不到之前的分类 → allStars"。
    private func isManageSelectionValid(_ item: SidebarItem) -> Bool {
        switch item {
        case .trending, .allStars, .untagged:
            return true
        case .language(let lang):
            // SidebarItem.language(nil) 对应 LanguageStat.language == ""（GitHub 无主语言）
            return viewModel.languageStats.contains { $0.language == (lang ?? "") }
        case .tag(let tagId):
            return viewModel.tags.contains { $0.id == tagId }
        }
    }

}
