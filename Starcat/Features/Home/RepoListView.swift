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
//  - 用 SwiftUI List + selection binding，原生体验最佳
//  - 行密度由 AppSettings 注入，密度切换实时生效（@Observable 通知）
//

import SwiftUI
import AppKit

struct RepoListView: View {

    @Environment(HomeViewModel.self) private var viewModel
    @Environment(AppSettings.self) private var settings

    // 顶部 clone 按钮现在属于中栏 toolbar；复制成功提示也跟着放在列表栏上。
    @State private var toastMessage: String?

    /// toolbar 上 SF Symbol 的统一视觉尺寸。
    ///
    /// 不同 symbol 的默认 bounding box 差异很大（例如 `doc.on.clipboard` 会显得更高），
    /// 所以顶部按钮统一走这个 helper，而不是依赖各控件自己的 `imageScale`。
    private func toolbarIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .regular))
            .frame(width: 18, height: 18, alignment: .center)
            .contentShape(Rectangle())
    }

    var body: some View {
        @Bindable var vm = viewModel

        Group {
            if viewModel.isLoading && viewModel.items.isEmpty {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.loadError, viewModel.items.isEmpty {
                emptyState(systemImage: "exclamationmark.triangle", title: "加载失败", subtitle: error)
            } else if viewModel.items.isEmpty {
                emptyState(systemImage: emptyImage, title: emptyTitle, subtitle: emptySubtitle)
            } else if viewModel.isMultiSelectMode {
                // W4 A5：多选模式 List binding 类型不同，必须分开渲染
                multiSelectList($vm.multiSelectedRepoIDs)
            } else {
                listContent($vm.selectedRepoID)
            }
        }
        .navigationTitle(navigationTitle)
        .navigationSubtitle(navigationSubtitle)
        // W4 A5：多选模式底部浮动操作栏
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if viewModel.isMultiSelectMode {
                BatchActionBar()
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                statusFilterMenu
                sortMenu
                multiSelectButton
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if let repo = viewModel.selectedRepo {
                    // 这两个动作作用于右侧详情页，但视觉上要贴近最右搜索按钮。
                    externalLinksMenu(repo: repo)
                    cloneMenu(repo: repo)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                // 搜索入口单独作为最后一个 toolbar item，才能在 macOS toolbar 里稳定贴到最右侧。
                // 展开时输入框向左占位，放大镜按钮本身仍停在最右边。
                CollapsibleSearchBar(text: $vm.searchQuery)
            }
        }
        .toast(message: $toastMessage, icon: "doc.on.clipboard")
    }

    // MARK: - 顶部操作栏组件

    /// 顶部 "在 GitHub 打开" 菜单。
    ///
    /// 这个按钮从右侧详情页 toolbar 移到中栏 toolbar，是因为 NavigationSplitView 会把
    /// detail toolbar 渲染在右栏左边；dong4j 期望详情动作靠近最右搜索入口，形成一条统一操作区。
    @ViewBuilder
    private func externalLinksMenu(repo: Repo) -> some View {
        Menu {
            if let issues = RepoExternalLinks.issues(repo) {
                Button {
                    NSWorkspace.shared.open(issues)
                } label: {
                    Label("Issues", systemImage: "exclamationmark.bubble")
                }
            }
            if let pulls = RepoExternalLinks.pulls(repo) {
                Button {
                    NSWorkspace.shared.open(pulls)
                } label: {
                    Label("Pull Requests", systemImage: "arrow.triangle.pull")
                }
            }
            if let releases = RepoExternalLinks.releases(repo) {
                Button {
                    NSWorkspace.shared.open(releases)
                } label: {
                    Label("Releases", systemImage: "tag.circle")
                }
            }
            if let homepage = RepoExternalLinks.homepage(repo) {
                Divider()
                Button {
                    NSWorkspace.shared.open(homepage)
                } label: {
                    Label("Homepage", systemImage: "house")
                    Text(homepage.absoluteString)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            toolbarIcon("safari")
                .accessibilityLabel("在 GitHub 打开")
        } primaryAction: {
            if let url = RepoExternalLinks.repo(repo) {
                NSWorkspace.shared.open(url)
            }
        }
        .help("点击：打开仓库主页；展开：Issues / Releases / Homepage")
    }

    /// 顶部 clone URL 复制菜单。
    ///
    /// 地址优先使用 GitHub API 同步回来的字段；旧缓存缺字段时按 GitHub 规则兜底生成，
    /// 保证选中 repo 后复制按钮稳定可见。
    @ViewBuilder
    private func cloneMenu(repo: Repo) -> some View {
        let https = httpsCloneURL(for: repo)
        let git = gitCloneURL(for: repo)

        Menu {
            Button {
                copy(https, success: "已复制 HTTPS Clone URL")
            } label: {
                Label("HTTPS", systemImage: "globe")
            }
            Text(https)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider()

            Button {
                copy(git, success: "已复制 Git Clone URL")
            } label: {
                Label("Git / SSH", systemImage: "terminal")
            }
            Text(git)
                .font(.caption2)
                .foregroundStyle(.secondary)
        } label: {
            toolbarIcon("doc.on.clipboard")
                .accessibilityLabel("克隆地址")
        }
        .help("复制 HTTPS / Git clone 地址")
    }

    private func httpsCloneURL(for repo: Repo) -> String {
        let fromAPI = repo.cloneUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fromAPI, !fromAPI.isEmpty {
            return fromAPI
        }
        return "https://github.com/\(repo.owner)/\(repo.name).git"
    }

    private func gitCloneURL(for repo: Repo) -> String {
        let fromAPI = repo.sshUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fromAPI, !fromAPI.isEmpty {
            return fromAPI
        }
        return "git@github.com:\(repo.owner)/\(repo.name).git"
    }

    private func copy(_ string: String, success: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
        toastMessage = success
    }

    /// 用 SF Symbol `checklist` 表达"批量操作"语义；按钮在多选模式时强调显示。
    private var multiSelectButton: some View {
        Button {
            viewModel.toggleMultiSelectMode()
        } label: {
            toolbarIcon(viewModel.isMultiSelectMode ? "checklist.checked" : "checklist")
                .accessibilityLabel(viewModel.isMultiSelectMode ? "退出多选" : "多选")
        }
        .help(viewModel.isMultiSelectMode ? "退出多选模式" : "进入多选模式")
        .keyboardShortcut("m", modifiers: [.command, .shift])
    }

    /// 阅读状态入口，同时保留 D2 的 Archived/Fork 列表过滤。
    /// 开启任一过滤时图标会切换为"已激活"形态，提示用户当前列表不是全集。
    /// - D2：Archived / Fork 两个 Toggle
    /// - D3：阅读状态 Picker(全部 + 4 状态)
    private var statusFilterMenu: some View {
        @Bindable var vm = viewModel
        return Menu {
            Picker("阅读状态", selection: $vm.statusFilter) {
                Text("全部").tag(RepoStatus?.none)
                ForEach(RepoStatus.allCases, id: \.self) { st in
                    Label(st.displayName, systemImage: statusIcon(for: st))
                        .tag(RepoStatus?.some(st))
                }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle(isOn: $vm.hideArchived) {
                Label("隐藏 Archived", systemImage: "archivebox")
            }
            Toggle(isOn: $vm.hideForks) {
                Label("隐藏 Fork", systemImage: "tuningfork")
            }
        } label: {
            toolbarIcon(viewModel.hasActiveFilter ? "circle.grid.2x1.fill" : "circle.grid.2x1")
                .accessibilityLabel(viewModel.statusFilter?.displayName ?? "阅读状态")
        }
        .help(viewModel.hasActiveFilter ? "已启用阅读状态 / 列表过滤" : "按阅读状态过滤")
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
            toolbarIcon("arrow.up.arrow.down")
                .accessibilityLabel("排序")
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

    // MARK: - 列表主体

    /// 关键写法：`List(selection: Binding<Repo.ID?>)` + `ForEach(items)`，
    /// 不显式写 `.tag(...)`。ForEach 看到 `Repo: Identifiable` 会自动使用 `repo.id`
    /// 作为每行的 selection identifier，selection binding 类型 (`Int64?`) 与之严格匹配，
    /// SwiftUI 内部无需再做 Hashable/Equatable 校对，是 macOS List selection 的最稳写法。
    private func listContent(_ selection: Binding<Int64?>) -> some View {
        List(selection: selection) {
            ForEach(viewModel.items) { repo in
                RepoRowView(repo: repo, density: settings.listDensity)
            }
        }
        .id(viewModel.itemsRevision)
        .transaction { transaction in
            transaction.animation = nil
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
    }

    /// W4 A5：多选 List。binding 类型 `Set<Int64>` → SwiftUI 自动启用多选行为。
    /// macOS 用户用 Cmd / Shift 加选，行级 checkbox 不必显式画。
    private func multiSelectList(_ selection: Binding<Set<Int64>>) -> some View {
        List(selection: selection) {
            ForEach(viewModel.items) { repo in
                RepoRowView(repo: repo, density: settings.listDensity)
            }
        }
        .id(viewModel.itemsRevision)
        .transaction { transaction in
            transaction.animation = nil
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
    }

    private var navigationSubtitle: String {
        if viewModel.isMultiSelectMode {
            return "已选 \(viewModel.multiSelectedRepoIDs.count) / \(viewModel.items.count)"
        }
        return "\(viewModel.items.count) 个仓库"
    }

    // MARK: - 标题派生

    private var navigationTitle: String {
        if viewModel.isSearching {
            return "搜索：\(viewModel.searchQuery)"
        }
        return viewModel.selection.displayName
    }

    // MARK: - 空状态

    private var emptyImage: String {
        if viewModel.isSearching { return "magnifyingglass" }
        switch viewModel.selection {
        case .trending:  return "chart.line.uptrend.xyaxis"
        case .allStars:  return "star"
        case .untagged:  return "tag.slash"
        case .language:  return "chevron.left.forwardslash.chevron.right"
        case .tag:       return "tag.slash"
        }
    }

    private var emptyTitle: String {
        if viewModel.isSearching { return "无匹配结果" }
        switch viewModel.selection {
        case .trending:        return "Trending 数据暂不可用"
        case .allStars:        return "还没有 Stars"
        case .untagged:        return "所有仓库都已分类"
        case .language:        return "该语言下暂无仓库"
        case .tag:             return "该标签下暂无仓库"
        }
    }

    private var emptySubtitle: String {
        if viewModel.isSearching { return "试试别的关键词" }
        switch viewModel.selection {
        case .trending:        return "功能开发中，敬请期待"
        case .allStars:        return "点击侧边栏同步按钮拉取 GitHub Stars"
        case .untagged:        return "新增 Stars 默认进这里"
        case .language:        return "刷新或同步后试试"
        case .tag:             return "在仓库详情页给它打上该标签"
        }
    }

    private func emptyState(systemImage: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func statusIcon(for status: RepoStatus) -> String {
        switch status {
        case .unread:     return "envelope.badge"
        case .reading:    return "book"
        case .using:      return "checkmark.seal"
        case .deprecated: return "archivebox"
        }
    }
}
