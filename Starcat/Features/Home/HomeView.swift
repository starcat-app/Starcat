//
//  HomeView.swift
//  Starcat
//
//  登录后的主界面：NavigationSplitView 三栏。
//
//  布局：
//  Sidebar（240pt）│  RepoList（300-360pt）│  RepoDetail（剩余）
//
//  Toolbar：
//  - 搜索框：FTS5 搜索（防抖 250ms）
//  - 同步按钮：触发 SyncManager.performFullSync
//  - 头像菜单：用户信息 + 退出登录
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

    /// 防抖用：跟踪搜索 query 变化，task(id:) 触发延迟搜索。
    @State private var searchDebounceID = UUID()

    init(repository: RepoRepository, readmeAPI: ReadmeAPI) {
        _viewModel = State(initialValue: HomeViewModel(repository: repository))
        _readmeVM = State(initialValue: ReadmeViewModel(api: readmeAPI))
    }

    var body: some View {
        @Bindable var vm = viewModel

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } content: {
            RepoListView()
                .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 480)
        } detail: {
            RepoDetailView()
        }
        .environment(viewModel)
        .environment(readmeVM)
        .searchable(text: $vm.searchQuery, placement: .toolbar, prompt: "搜索仓库")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                syncButton
            }
        }
        .task {
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
    }

    // MARK: - Toolbar 子组件

    @ViewBuilder
    private var syncButton: some View {
        if syncManager.isSyncing {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Button {
                    syncManager.cancel()
                } label: {
                    Label("取消同步", systemImage: "xmark")
                }
                .help("取消同步")
            }
        } else {
            Button {
                if case .authenticated(let user) = authSession.state {
                    syncManager.performFullSync(userID: user.id)
                }
            } label: {
                Label("同步 Stars", systemImage: "arrow.triangle.2.circlepath")
            }
            .help("拉取 GitHub Stars")
        }
    }

}
