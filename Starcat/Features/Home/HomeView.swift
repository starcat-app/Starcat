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

    /// W4 A2：标签管理 sheet 显示状态。
    @State private var showTagManagement: Bool = false

    /// W4 A2：TagManagementViewModel 实例，sheet 关掉再开时复用，
    /// 避免每次 sheet 都 new 导致选择/加载态被打断。
    @State private var tagMgmtVM: TagManagementViewModel

    /// D-01：repository 类型从具体 struct 改为协议，便于 Preview / 测试注入 Mock。
    /// W4 A6：HomeViewModel 也接收 tagRepository / repoTagRepository（Sidebar Tags 段 + 按 tag 过滤）。
    /// W4-4 D3：新增 repoNoteRepository（按状态过滤需要拉 status map）。
    init(
        repository: any RepoRepositoryProtocol,
        readmeAPI: ReadmeAPI,
        tagRepository: any TagRepositoryProtocol,
        repoTagRepository: any RepoTagRepositoryProtocol,
        repoNoteRepository: any RepoNoteRepositoryProtocol
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
                filterMenu
                sortMenu
                multiSelectButton
                tagManagementButton
                syncButton
            }
        }
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

    /// W4 A5：多选模式 toggle。开启后列表切换到多选 + 弹出底部操作栏。
    /// 用 SF Symbol `checklist` 表达"批量操作"语义；按钮在多选模式时强调显示。
    private var multiSelectButton: some View {
        Button {
            viewModel.toggleMultiSelectMode()
        } label: {
            Label(
                viewModel.isMultiSelectMode ? "退出多选" : "多选",
                systemImage: viewModel.isMultiSelectMode ? "checklist.checked" : "checklist"
            )
        }
        .help(viewModel.isMultiSelectMode ? "退出多选模式" : "进入多选模式")
        .keyboardShortcut("m", modifiers: [.command, .shift])
    }

    /// W4-4 D2/D3：过滤入口。开启任一过滤时图标会切换为"已激活"形态,
    /// 提示用户当前列表不是全集。
    /// - D2：Archived / Fork 两个 Toggle
    /// - D3：阅读状态 Picker(全部 + 4 状态)
    private var filterMenu: some View {
        @Bindable var vm = viewModel
        return Menu {
            Toggle(isOn: $vm.hideArchived) {
                Label("隐藏 Archived", systemImage: "archivebox")
            }
            Toggle(isOn: $vm.hideForks) {
                Label("隐藏 Fork", systemImage: "tuningfork")
            }
            Divider()
            Picker("阅读状态", selection: $vm.statusFilter) {
                Text("全部").tag(RepoStatus?.none)
                ForEach(RepoStatus.allCases, id: \.self) { st in
                    Text(st.displayName).tag(RepoStatus?.some(st))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(
                "过滤",
                systemImage: viewModel.hasActiveFilter
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle"
            )
        }
        .help(viewModel.hasActiveFilter ? "已启用列表过滤" : "过滤列表(Archived / Fork / 阅读状态)")
        .onChange(of: viewModel.hideArchived) { _, newValue in
            settings.hideArchived = newValue
        }
        .onChange(of: viewModel.hideForks) { _, newValue in
            settings.hideForks = newValue
        }
        .onChange(of: viewModel.statusFilter) { _, newValue in
            settings.statusFilter = newValue
        }
    }

    /// W4-4 D1：排序入口。Picker 显示当前选中(系统会自动加 ✓ 标记)。
    /// 与 AppSettings.repoSortOption 双向同步：
    /// - 用户改 → onChange 写 settings(落盘)
    /// - settings 变 → onAppear / onChange 同步回 viewModel
    /// 不在 Picker binding 里直接绑 settings,是因为 viewModel 才是排序的"事实源",
    /// settings 只负责跨会话恢复。
    private var sortMenu: some View {
        @Bindable var vm = viewModel
        return Menu {
            Picker("排序", selection: $vm.sortOption) {
                ForEach(RepoSortOption.allCases) { opt in
                    Label(opt.displayName, systemImage: opt.systemImage)
                        .tag(opt)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("排序", systemImage: "arrow.up.arrow.down")
        }
        .help("选择列表排序方式")
        .onAppear {
            // 首次进入 / sheet 关闭重建时,把已持久化的偏好同步到 viewModel
            if viewModel.sortOption != settings.repoSortOption {
                viewModel.sortOption = settings.repoSortOption
            }
        }
        .onChange(of: viewModel.sortOption) { _, newValue in
            settings.repoSortOption = newValue
        }
    }

    /// W4 A2：标签管理入口。点击弹 sheet。
    private var tagManagementButton: some View {
        Button {
            showTagManagement = true
        } label: {
            Label("标签管理", systemImage: "tag")
        }
        .help("管理标签（创建 / 编辑 / 合并 / 删除）")
        .keyboardShortcut("t", modifiers: [.command, .shift])
    }

    @ViewBuilder
    private var syncButton: some View {
        // W4-4 C1：state 多了 .rateLimited(retryAt:)，需要单独渲染倒计时 UI 提示
        // "GitHub 已限流，正在等待配额恢复"，让用户知道这不是卡死。
        switch syncManager.state {
        case .syncing:
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
        case .rateLimited(let retryAt):
            // TimelineView 让倒计时每秒自动刷新而无需主动 setState。
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, Int(retryAt.timeIntervalSince(context.date)))
                HStack(spacing: 6) {
                    Image(systemName: "hourglass")
                        .foregroundStyle(.orange)
                    Text("配额恢复中 \(formatCountdown(seconds: remaining))")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button {
                        syncManager.cancel()
                    } label: {
                        Label("取消", systemImage: "xmark")
                    }
                    .help("取消等待并停止同步")
                }
            }
        case .idle, .completed, .failed:
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

    /// 把秒数格式化为 mm:ss / hh:mm:ss（GitHub Rate Limit 重置最长 1 小时）。
    private func formatCountdown(seconds: Int) -> String {
        let s = seconds % 60
        let m = (seconds / 60) % 60
        let h = seconds / 3600
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%d:%02d", m, s)
        }
    }

}
