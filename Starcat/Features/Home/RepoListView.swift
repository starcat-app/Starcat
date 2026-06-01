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

struct RepoListView: View {

    @Environment(HomeViewModel.self) private var viewModel
    @Environment(AppSettings.self) private var settings

    /// HOM-54：TrendingRepository，用于渲染 Trending 页面。
    var trendingRepository: (any TrendingRepositoryProtocol)?
    /// HOM-54：Trending 一键订阅复用 GitHub API 的 star 端点。
    var githubAPIClient: (any GitHubAPIClientProtocol)?

    let selectedPage: SidebarRootPage
    @Binding var selectedTrendingLanguage: TrendingLanguage
    /// 当前选中的 Trending repo ID（用于卡片高亮和 README 加载）。
    @Binding var selectedTrendingRepoID: String?
    /// 当前选中的 Trending repo 完整数据（用于右侧详情页元信息展示）。
    @Binding var selectedTrendingRepo: TrendingRepo?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

        contentBody
        .id(contentAnimationID)
        .transition(contentTransition)
        .animation(contentAnimation, value: contentAnimationID)
        .navigationTitle(navigationTitle)
        .navigationSubtitle(navigationSubtitle)
        // W4 A5：多选模式底部浮动操作栏
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if viewModel.isMultiSelectMode {
                BatchActionBar()
            }
        }
        .toolbar {
            if selectedPage == .manage {
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
        }
        .toast(message: $toastMessage, icon: "doc.on.clipboard")
    }

    /// 中栏主体内容。
    ///
    /// 单独抽出是为了让外层用 `contentAnimationID` 给整块内容做过渡动画；
    /// `List` 本身仍用 `itemsRevision` 重建快照，避免排序/过滤时几千行逐个 move；
    /// row 只做可视区域内的轻量 reveal。
    @ViewBuilder
    private var contentBody: some View {
        @Bindable var vm = viewModel

        Group {
            if selectedPage == .trending {
                // HOM-54：Trending 页面
                if let repo = trendingRepository, let githubAPIClient {
                    TrendingView(
                        repository: repo,
                        githubAPIClient: githubAPIClient,
                        selectedLanguage: $selectedTrendingLanguage,
                        selectedRepoID: $selectedTrendingRepoID,
                        selectedTrendingRepo: $selectedTrendingRepo
                    )
                } else {
                    emptyState(systemImage: "chart.line.uptrend.xyaxis", title: "empty.trendingUnavailable", subtitle: "empty.trendingComingSoon")
                }
            } else if selectedPage == .search {
                searchPlaceholder
            } else if viewModel.isLoading {
                // HOM-46：无缓存分类加载时直接切到骨架屏，避免旧分类列表停留在中栏造成"没反应"的错觉。
                RepoSkeletonListView(density: settings.listDensity, rowCount: 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.loadError, viewModel.items.isEmpty {
                emptyState(systemImage: "exclamationmark.triangle", title: "error.loadFailed", subtitleText: error)
            } else if viewModel.items.isEmpty {
                emptyState(systemImage: emptyImage, title: emptyTitle, subtitle: emptySubtitle)
            } else if viewModel.isMultiSelectMode {
                // W4 A5：多选模式 List binding 类型不同，必须分开渲染
                multiSelectList($vm.multiSelectedRepoIDs)
            } else {
                listContent($vm.selectedRepoID)
            }
        }
    }

    /// 给 `ForEach` 使用的带下标 repo。
    ///
    /// SwiftUI `List` 本身会按可视区域懒创建 row；这里补一个 index 只用于计算短暂
    /// stagger delay，让切分类后首屏 row 依次轻入场，滚动到新 row 时也能有渐进出现效果。
    private var indexedItems: [IndexedRepo] {
        viewModel.items.enumerated().map { IndexedRepo(index: $0.offset, repo: $0.element) }
    }

    /// 中栏内容切换动画的身份键。
    ///
    /// 用 selection / page / itemsRevision 组合，而不是让 List 自己做行级 diff：
    /// - 切分类：loading skeleton → 新列表会有完整过渡；
    /// - 命中缓存：缓存列表立即轻入场，后台刷新完成后再用新快照替换；
    /// - 排序/过滤：仍是整块快照替换，不触发几千行逐个 move。
    private var contentAnimationID: String {
        if selectedPage == .trending {
            return "trending-\(selectedTrendingLanguage.id)"
        }
        if selectedPage == .search {
            return "search"
        }
        let mode = viewModel.isMultiSelectMode ? "multi" : "single"
        if viewModel.isLoading {
            return "loading-\(viewModel.selection.id)-\(mode)"
        }
        if let error = viewModel.loadError, viewModel.items.isEmpty {
            return "error-\(viewModel.selection.id)-\(error)"
        }
        if viewModel.items.isEmpty {
            return "empty-\(viewModel.selection.id)-\(viewModel.itemsRevision)-\(mode)"
        }
        return "repos-\(viewModel.selection.id)-\(viewModel.itemsRevision)-\(mode)"
    }

    private var contentAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.22)
    }

    private var contentTransition: AnyTransition {
        reduceMotion ? .identity : .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 8)),
            removal: .opacity
        )
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
                    Label("externalLinks.issues", systemImage: "exclamationmark.bubble")
                }
            }
            if let pulls = RepoExternalLinks.pulls(repo) {
                Button {
                    NSWorkspace.shared.open(pulls)
                } label: {
                    Label("externalLinks.pullRequests", systemImage: "arrow.triangle.pull")
                }
            }
            if let releases = RepoExternalLinks.releases(repo) {
                Button {
                    NSWorkspace.shared.open(releases)
                } label: {
                    Label("externalLinks.releases", systemImage: "tag.circle")
                }
            }
            if let homepage = RepoExternalLinks.homepage(repo) {
                Divider()
                Button {
                    NSWorkspace.shared.open(homepage)
                } label: {
                    Label("externalLinks.homepage", systemImage: "house")
                    Text(homepage.absoluteString)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            toolbarIcon("safari")
                .accessibilityLabel("externalLinks.openOnGithub")
        } primaryAction: {
            if let url = RepoExternalLinks.repo(repo) {
                NSWorkspace.shared.open(url)
            }
        }
        .help("externalLinks.hint")
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
                copy(https, success: "clone.copiedHttps")
            } label: {
                Label("clone.https", systemImage: "globe")
            }
            Text(https)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider()

            Button {
                copy(git, success: "clone.copiedGit")
            } label: {
                Label("clone.git", systemImage: "terminal")
            }
            Text(git)
                .font(.caption2)
                .foregroundStyle(.secondary)
        } label: {
            toolbarIcon("doc.on.clipboard")
                .accessibilityLabel("clone.hint")
        }
        .help("clone.hint")
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
                .accessibilityLabel(viewModel.isMultiSelectMode ? Text("batch.exitMultiSelect") : Text("batch.multiSelect"))
        }
        .help(viewModel.isMultiSelectMode ? Text("list.exitMultiSelectMode") : Text("list.multiSelectMode"))
        .keyboardShortcut("m", modifiers: [.command, .shift])
    }

    /// 阅读状态入口，同时保留 D2 的 Archived/Fork 列表过滤。
    /// 开启任一过滤时图标会切换为"已激活"形态，提示用户当前列表不是全集。
    /// - D2：Archived / Fork 两个 Toggle
    /// - D3：阅读状态 Picker(全部 + 4 状态)
    private var statusFilterMenu: some View {
        @Bindable var vm = viewModel
        return Menu {
            Picker("list.filter.status", selection: $vm.statusFilter) {
                Text("general.all").tag(RepoStatus?.none)
                ForEach(RepoStatus.allCases, id: \.self) { st in
                    Label(st.displayName, systemImage: statusIcon(for: st))
                        .tag(RepoStatus?.some(st))
                }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle(isOn: $vm.hideArchived) {
                Label("settings.general.hideArchived", systemImage: "archivebox")
            }
            Toggle(isOn: $vm.hideForks) {
                Label("settings.general.hideForks", systemImage: "tuningfork")
            }
        } label: {
            toolbarIcon(viewModel.hasActiveFilter ? "circle.grid.2x1.fill" : "circle.grid.2x1")
                .accessibilityLabel(viewModel.statusFilter?.localizedDisplayName ?? String(localized: "list.filter.status"))
        }
        .help(viewModel.hasActiveFilter ? Text("list.filter.active") : Text("list.filter.hint"))
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
            Picker("list.sort", selection: $vm.sortOption) {
                ForEach(RepoSortOption.allCases) { opt in
                    Label(opt.displayName, systemImage: opt.systemImage)
                        .tag(opt)
                }
            }
            .pickerStyle(.inline)
        } label: {
            toolbarIcon("arrow.up.arrow.down")
                .accessibilityLabel("list.sort")
        }
        .help("list.sortHint")
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

    /// 单选列表使用手动 selection，而不是 `List(selection:)`。
    ///
    /// 原因：`List(selection:)` 会强制绘制 macOS 系统蓝色选中底色，和 UI 升级后的
    /// 自定义左侧 accent 条叠加后视觉过重。这里用 plain Button 写入 `selectedRepoID`，
    /// 仍触发 HomeView 的 `.onChange(of: selectedRepoID)` 加载详情，但选中外观完全交给
    /// `RepoRowView` 控制。
    private func listContent(_ selection: Binding<Int64?>) -> some View {
        List {
            ForEach(indexedItems) { item in
                let repo = item.repo
                // UI 视觉升级：单选态不再使用 `List(selection:)`。
                // macOS 会强制绘制系统蓝色选中底色，和自定义左侧色条叠加后过重；
                // 改为 plain Button 手动写 selectedRepoID，保留点击打开详情，但视觉只由 RepoRowView 控制。
                Button {
                    selection.wrappedValue = repo.id
                } label: {
                    RepoRowView(
                        repo: repo,
                        density: settings.listDensity,
                        isSelected: selection.wrappedValue == repo.id
                    )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .listRowReveal(index: item.index, snapshotID: viewModel.itemsRevision)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .id(viewModel.itemsRevision)
        .listStyle(.inset)
        .alternatingRowBackgrounds()
    }

    /// W4 A5：多选 List。binding 类型 `Set<Int64>` → SwiftUI 自动启用多选行为。
    /// macOS 用户用 Cmd / Shift 加选，行级 checkbox 不必显式画。
    private func multiSelectList(_ selection: Binding<Set<Int64>>) -> some View {
        List(selection: selection) {
            ForEach(indexedItems) { item in
                let repo = item.repo
                RepoRowView(
                    repo: repo,
                    density: settings.listDensity,
                    isSelected: selection.wrappedValue.contains(repo.id)
                )
                .listRowReveal(index: item.index, snapshotID: viewModel.itemsRevision)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .id(viewModel.itemsRevision)
        .listStyle(.inset)
        .alternatingRowBackgrounds()
    }

    private var navigationSubtitle: String {
        if selectedPage == .trending {
            return selectedTrendingLanguage.localizedDisplayName
        }
        if selectedPage == .search {
            return String(localized: "empty.searchPlaceholder")
        }
        if viewModel.isMultiSelectMode {
            return String(
                format: String(localized: "list.selectedCountFormat"),
                viewModel.multiSelectedRepoIDs.count,
                viewModel.items.count
            )
        }
        if viewModel.isRefreshing {
            return String(
                format: String(localized: "list.refreshingFormat"),
                viewModel.items.count
            )
        }
        return String(
            format: String(localized: "list.repoCountFormat"),
            viewModel.items.count
        )
    }

    // MARK: - 标题派生

    private var navigationTitle: String {
        if selectedPage == .trending {
            return String(localized: "trending.title")
        }
        if selectedPage == .search {
            return String(localized: "search.title")
        }
        if viewModel.isSearching {
            return String(localized: "search.searching")
        }
        return localizedTitle(for: viewModel.selection)
    }

    /// Navigation title 需要 plain String；静态入口走 localization，用户标签/语言按原样显示。
    private func localizedTitle(for item: SidebarItem) -> String {
        switch item {
        case .trending:
            return String(localized: "trending.title")
        case .allStars:
            return String(localized: "sidebar.allRepos")
        case .untagged:
            return String(localized: "sidebar.untagged")
        case .language(let language):
            return language ?? String(localized: "sidebar.unknownLanguage")
        case .tag(let id):
            return viewModel.tags.first { $0.id == id }?.name ?? String(localized: "sidebar.tagFallback")
        }
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

    private var emptyTitle: LocalizedStringKey {
        if viewModel.isSearching { return "empty.noResults" }
        switch viewModel.selection {
        case .trending:        return "empty.trendingUnavailable"
        case .allStars:        return "empty.noStars"
        case .untagged:        return "empty.allTagged"
        case .language:        return "empty.noReposInLanguage"
        case .tag:             return "empty.noReposInTag"
        }
    }

    private var emptySubtitle: LocalizedStringKey {
        if viewModel.isSearching { return "empty.tryAnother" }
        switch viewModel.selection {
        case .trending:        return "empty.trendingComingSoon"
        case .allStars:        return "empty.syncPrompt"
        case .untagged:        return "empty.untaggedHint"
        case .language:        return "empty.languageHint"
        case .tag:             return "empty.tagHint"
        }
    }

    private func emptyState(systemImage: String, title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
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

    private func emptyState(systemImage: String, title: LocalizedStringKey, subtitleText: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(verbatim: subtitleText)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var searchPlaceholder: some View {
        emptyState(
            systemImage: "magnifyingglass",
            title: "search.title",
            subtitle: "empty.searchPlaceholder"
        )
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

/// 带可见顺序的 repo 包装。
///
/// `id` 仍然来自 repo.id，保证 SwiftUI row identity 不受下标影响；index 只用于计算
/// 入场 delay，避免排序后因为下标变化破坏选中 / 复用语义。
private struct IndexedRepo: Identifiable {
    let index: Int
    let repo: Repo

    var id: Int64 { repo.id }
}
