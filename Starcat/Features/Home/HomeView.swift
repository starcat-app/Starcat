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

    /// 防抖用：跟踪搜索 query 变化，task(id:) 触发延迟搜索。
    @State private var searchDebounceID = UUID()

    init(repository: RepoRepository) {
        _viewModel = State(initialValue: HomeViewModel(repository: repository))
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
