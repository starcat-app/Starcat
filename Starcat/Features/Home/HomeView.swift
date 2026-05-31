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
            SidebarView(showTagManagement: $showTagManagement)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } content: {
            RepoListView(
                trendingRepository: trendingRepository,
                githubAPIClient: githubAPIClient
            )
                .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 480)
        } detail: {
            RepoDetailView()
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
            
            // Default to trending if not authenticated
            if !authSession.state.isAuthenticated {
                viewModel.selection = .trending
            } else if viewModel.selection == .trending {
                // If authenticated and somehow still on trending initially, we can leave it
                // or let the user switch.
            } else {
                // App 打开且用户已登录 → 主动触发一次全量同步（后台静默执行）
                if case .authenticated(let user) = authSession.state {
                    syncManager.performFullSync(userID: user.id)
                }
            }

            await viewModel.refreshSidebar()
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
                readmeVM.load(repo: repo)
            } else {
                readmeVM.reset()
            }
        }
        // 监听登录态变化，退出登录时强制切换回 Trending 并清除选择
        .onChange(of: authSession.state.isAuthenticated) { _, isAuthenticated in
            if !isAuthenticated {
                viewModel.selection = .trending
                viewModel.selectedRepoID = nil
            }
        }
    }

}
