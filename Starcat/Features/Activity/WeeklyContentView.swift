//
//  WeeklyContentView.swift
//  Starcat
//
//  Activity 页 `weekly` 分类的中栏视图 + ViewModel。
//
//  数据源：阮一峰周刊（ruanyf/weekly）通过独立 Go 后端服务暴露的 REST API。
//  契约见 `WeeklyAPI.swift` / 后端仓库 README。
//
//  设计约束：
//  - 不复用 ActivityViewModel 的本地聚合逻辑：weekly 是远端分页 + 筛选 + 排序，
//    塞进 ActivityViewModel 会污染其"本地缓存聚合"语义。
//  - 列表点击 → 写入 `WeeklySelectionService.selectedProject`，由 HomeView 详情区
//    路由到 `WeeklyDetailView`（不再直接外链）。详情页内才提供"在 GitHub 打开"按钮。
//    这次改动前是 `NSWorkspace.open(project.url)` 直接跳浏览器，被反馈无法预览所以
//    重新接回 detail pane；新建 `WeeklyDetailView` 而非复用 `ActivityDetailView`，
//    因为 weekly 还要展示期号 / 周刊原文等专属字段。
//  - 分页是"无限滚动"：到达列表底部时自动加载下一页；不放手动"加载更多"按钮，
//    与 macOS 上 List 的自然滚动体验一致。
//  - 列表顶部 toolbar 只保留"筛选 + 刷新"，移除了"x 项"文本——计数挪到 sidebar 的
//    周刊分类右侧徽章（仿 manage Languages 计数样式），见 `WeeklySelectionService`。
//

import SwiftUI
import AppKit

// MARK: - View

/// Activity 页 weekly 分类的内容视图。
struct WeeklyContentView: View {

    @Environment(AppDependencies.self) private var dependencies
    @Environment(AppSettings.self) private var settings

    @State private var viewModel: WeeklyContentViewModel?

    // R-01 §3.1.4 Step 7.3：refreshAngle / reduceMotion 已无外层用途，统一由 SyncIconButton 内部处理。
    // WeeklyProjectRow 内部仍保留自己的 reduceMotion env 处理 isSelected 动画。

    var body: some View {
        Group {
            if let viewModel {
                content(viewModel)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            let model = ensureViewModel()
            await model.loadInitialIfNeeded()
        }
    }

    @ViewBuilder
    private func content(_ viewModel: WeeklyContentViewModel) -> some View {
        VStack(spacing: 0) {
            filterBar(viewModel)
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 6)

            Divider()

            if viewModel.isLoading && viewModel.items.isEmpty {
                RepoSkeletonListView(rowCount: 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.loadError, viewModel.items.isEmpty {
                emptyState(systemImage: "exclamationmark.triangle", title: "activity.error.title", subtitleText: error) {
                    Task { await viewModel.reload() }
                }
            } else if viewModel.items.isEmpty {
                emptyState(systemImage: "newspaper", title: "weekly.empty.title", subtitle: "weekly.empty.subtitle") {
                    Task { await viewModel.reload() }
                }
            } else {
                projectList(viewModel)
            }
        }
        .task {
            await viewModel.loadLanguagesIfNeeded()
        }
    }

    // MARK: - Filter Bar

    /// 顶部筛选栏：排序 + 语言下拉。
    ///
    /// 期号筛选目前没有用 picker 暴露——后端 `/issues` 还在补，列表也不强需要；
    /// 后续要做时增加一个 Menu 即可，结构上已经在 ViewModel 留了 `selectedIssue`。
    private func filterBar(_ viewModel: WeeklyContentViewModel) -> some View {
        HStack(spacing: 10) {
            Picker(selection: Binding(
                get: { viewModel.selectedSort },
                set: { viewModel.changeSort(to: $0) }
            )) {
                ForEach(WeeklyFeedSort.allCases) { sort in
                    Text(sort.localizedTitle).tag(sort)
                }
            } label: {
                Text("weekly.filter.sort")
            }
            .pickerStyle(.menu)
            .fixedSize()

            Picker(selection: Binding(
                get: { viewModel.selectedLanguage },
                set: { viewModel.changeLanguage(to: $0) }
            )) {
                ForEach(viewModel.languageOptions, id: \.self) { lang in
                    Text(languageDisplayName(lang)).tag(lang)
                }
            } label: {
                Text("weekly.filter.language")
            }
            .pickerStyle(.menu)
            .fixedSize()

            Spacer()

            refreshButton(viewModel)
        }
    }

    /// 顶部刷新按钮。
    ///
    /// R-01 §3.1.4 Step 7.3：自写 rotationEffect + 0.9s repeatForever 改用统一的
    /// SyncIconButton（图标 / 旋转动画 / hover / disabled / reduceMotion 全套统一）。
    /// 节奏从 0.9s 改为 1.0s（与 SidebarSyncButton / TrendingView toolbar / cacheFooter 对齐）。
    @ViewBuilder
    private func refreshButton(_ viewModel: WeeklyContentViewModel) -> some View {
        SyncIconButton(
            isRefreshing: viewModel.isLoading,
            disabled: viewModel.isLoading,
            tooltip: String(localized: "weekly.refresh")
        ) {
            Task { await viewModel.reload() }
        }
    }

    private func languageDisplayName(_ raw: String) -> String {
        if raw.isEmpty {
            return String(localized: "weekly.filter.allLanguages")
        }
        if raw == TrendingLanguage.uncategorizedKey {
            return String(localized: "trending.language.uncategorized")
        }
        // 短名（"Jupyter Notebook" → "Jupyter"），picker label 宽度有限，详见 LanguageDisplayName。
        return LanguageDisplayName.shortened(for: raw)
    }

    // MARK: - Project List

    private func projectList(_ viewModel: WeeklyContentViewModel) -> some View {
        let selection = dependencies.weeklySelectionService
        let registry = dependencies.starredRegistry
        // W12 PR-4：weekly 多选 store。多选模式下点击行 toggle 选中，否则进入详情。
        let multiStore = dependencies.weeklyMultiSelectionStore
        return List {
            ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { index, project in
                Button {
                    if multiStore.isActive {
                        multiStore.toggle(SelectionSnapshot(
                            ghRepoId: project.ghRepoId,
                            owner: project.owner,
                            name: project.name
                        ))
                    } else {
                        selection.select(project)
                    }
                } label: {
                    // R-01 v1.2 Phase B4（2026-06-10）：weekly row 切到 UnifiedRepoRow，
                    // 与 manage / trending 视觉同款；周刊期号通过 `CardBadge.weeklyIssue`
                    // 在 chip 行显示，星标 ✓ 由 `StarredRegistry` 驱动联动。
                    UnifiedRepoRow(
                        card: project.asCardData(registry: registry),
                        isSelected: multiStore.isActive
                            ? multiStore.contains(ghRepoId: project.ghRepoId)
                            : (selection.selectedItem?.id == project.id),
                        showStarredCheckmark: true
                    )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                // HOM-201 P1-1（2026-06-14）：weekly 行 hover 500ms 后预拉 trending README，
                // 与 trending 列表同款（weekly 详情走 loadTrending 命中 trending_readmes 表）。
                .readmePrefetch { [readmeAPI = dependencies.readmeAPI, owner = project.owner, name = project.name] in
                    await readmeAPI.prefetchTrending(owner: owner, repo: name)
                }
                .contextMenu {
                    Button(action: { open(project.url) }) {
                        Text("weekly.action.openRepo")
                    }
                    if let issueURL = project.weekly?.issueURL {
                        Button(action: { open(issueURL) }) {
                            Text("weekly.action.openIssue")
                        }
                    }
                    Button(action: { copy(project.url.absoluteString) }) {
                        Text("weekly.action.copyURL")
                    }
                }
                .listRowReveal(index: index, snapshotID: viewModel.itemsRevision)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .onAppear {
                    // 到达接近底部时触发下一页：用倒数第 3 行作触发点，给网络一点提前量，
                    // 避免用户滚到最后一行才看到 ProgressView。
                    if viewModel.shouldTriggerLoadMore(at: index) {
                        Task { await viewModel.loadMoreIfNeeded() }
                    }
                }
            }

            if viewModel.isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Spacer()
                }
                .padding(.vertical, 8)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
        // W12 PR-5：Cmd+A 全选当前可见 weekly project（仅 multi-select active 时生效）。
        // 4 场景同款机制：隐藏按钮 + keyboardShortcut。
        .background {
            Button {
                let snapshots = viewModel.items.map {
                    SelectionSnapshot(ghRepoId: $0.ghRepoId, owner: $0.owner, name: $0.name)
                }
                multiStore.selectAll(snapshots)
            } label: {
                EmptyView()
            }
            .keyboardShortcut("a", modifiers: .command)
            .disabled(!multiStore.isActive)
            .hidden()
        }
    }

    // MARK: - Helpers

    private func ensureViewModel() -> WeeklyContentViewModel {
        if let viewModel { return viewModel }
        let model = WeeklyContentViewModel(
            api: dependencies.weeklyAPI,
            selectionService: dependencies.weeklySelectionService,
            languageStore: dependencies.weeklyLanguageStore
        )
        viewModel = model
        return model
    }

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// 空 / 错误状态视图。
    /// retry 闭包给 Button 直接调用，错误态需要"重试"，空态默认只是再刷一次。
    private func emptyState(
        systemImage: String,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        subtitleText: String? = nil,
        retry: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            } else if let subtitleText {
                Text(verbatim: subtitleText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            if let retry {
                Button(action: retry) {
                    Text("weekly.action.retry")
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// R-01 v1.2 Phase B4（2026-06-10）：原 `WeeklyProjectRow` 已删除，
// row 视觉统一由 `UnifiedRepoRow + project.asCardData(registry:)` 承接。
// 周刊期号徽章通过 `CardBadge.weeklyIssue` 在 chip 行展示，accent 颜色由
// `RepoCardViewData.accentColor` 计算（语言色优先 → 系统强调色，与列表统一）。

// MARK: - ViewModel

/// Weekly 分类专用 ViewModel。
///
/// 设计要点：
/// - 单一桶（sort + language 组合），切换筛选会清空当前项目并从 page=1 重新拉；
/// - 分页采用追加式：滚到底部触发 `loadMoreIfNeeded`，把新 page 追加到 items 尾部；
/// - `itemsRevision` 与 Activity / Trending 同款语义：用于 `listRowReveal` 决定是否
///   重播入场动画——筛选切换 / 重新加载时 bump，分页追加时**不** bump。
@MainActor
@Observable
final class WeeklyContentViewModel {

    // MARK: - State

    private(set) var items: [WeeklyFeedItem] = []
    private(set) var total: Int = 0
    private(set) var page: Int = 1
    private(set) var hasMore: Bool = false

    private(set) var isLoading: Bool = false
    private(set) var isLoadingMore: Bool = false
    private(set) var loadError: String?
    /// 入场动画 / row-reveal 用的"身份快照"版本，仅在筛选切换 / 重新加载时 bump。
    private(set) var itemsRevision: Int = 0

    /// 排序当前值；setter 由 `changeSort(to:)` 控制以保证副作用统一。
    private(set) var selectedSort: WeeklyFeedSort = .latestEventAt
    private(set) var selectedLanguage: String = ""
    var languageOptions: [String] {
        [""] + languageStore.displayList.map(\.key)
    }

    // MARK: - Dependencies

    private let api: WeeklyAPI
    /// 把 total 推到外部 sidebar 计数徽章 / detail pane 路由的共享状态。
    /// 解耦 sidebar 与列表 ViewModel：sidebar 不直接持有 ViewModel，避免双向依赖。
    private let selectionService: WeeklySelectionService?
    private let languageStore: WeeklyLanguageStore

    /// 标记当前 in-flight 请求的代次；切换筛选 / reload 时 bump，
    /// 旧请求即便回来也会因为代次不匹配而被丢弃，避免顺序错乱。
    private var generation: Int = 0

    init(
        api: WeeklyAPI,
        selectionService: WeeklySelectionService? = nil,
        languageStore: WeeklyLanguageStore
    ) {
        self.api = api
        self.selectionService = selectionService
        self.languageStore = languageStore
    }

    // MARK: - Public

    /// 首次进入页面调用；如果已有数据就跳过，避免重新进入时把缓存丢掉。
    func loadInitialIfNeeded() async {
        guard items.isEmpty, !isLoading else { return }
        await reload()
    }

    func loadLanguagesIfNeeded() async {
        await languageStore.reloadIfNeeded()
        if !selectedLanguage.isEmpty, !languageOptions.contains(selectedLanguage) {
            selectedLanguage = ""
            await reload()
        }
    }

    /// 主动刷新：清空当前数据，从第一页重新拉。
    func reload() async {
        let myGen = bumpGeneration()
        isLoading = true
        isLoadingMore = false
        loadError = nil

        do {
            let result = try await api.fetchRepos(
                query: WeeklyFeedQuery(
                    language: selectedLanguage.isEmpty ? nil : selectedLanguage,
                    sort: selectedSort,
                    page: 1
                )
            )
            guard myGen == generation else { return }
            items = result.items
            total = result.total
            page = result.page
            hasMore = result.hasMore
            itemsRevision += 1
            selectionService?.applyTotal(result.total)
        } catch {
            guard myGen == generation else { return }
            loadError = error.localizedDescription
            if items.isEmpty {
                total = 0
                hasMore = false
            }
        }
        if myGen == generation {
            isLoading = false
        }
    }

    /// 滚到底部触发的"加载下一页"。
    func loadMoreIfNeeded() async {
        guard hasMore, !isLoading, !isLoadingMore else { return }
        let myGen = generation
        isLoadingMore = true
        defer {
            if myGen == generation {
                isLoadingMore = false
            }
        }

        let nextPage = page + 1
        do {
            let result = try await api.fetchRepos(
                query: WeeklyFeedQuery(
                    language: selectedLanguage.isEmpty ? nil : selectedLanguage,
                    sort: selectedSort,
                    page: nextPage
                )
            )
            guard myGen == generation else { return }
            // 同 id 项目可能因为后端排序变动并发出现重复，去一次重保险。
            let existingIDs = Set(items.map(\.id))
            let appended = result.items.filter { !existingIDs.contains($0.id) }
            items.append(contentsOf: appended)
            page = result.page
            total = result.total
            hasMore = result.hasMore
            selectionService?.applyTotal(result.total)
        } catch {
            guard myGen == generation else { return }
            loadError = error.localizedDescription
            // 分页失败保留已有数据与 hasMore，用户滚动/刷新可继续重试。
        }
    }

    func changeSort(to newValue: WeeklyFeedSort) {
        guard newValue != selectedSort else { return }
        selectedSort = newValue
        Task { await reload() }
    }

    func changeLanguage(to newValue: String) {
        guard newValue != selectedLanguage else { return }
        selectedLanguage = newValue
        Task { await reload() }
    }

    /// 给 List `.onAppear` 判断是否该触发下一页。
    /// 倒数第 3 行（或最后一行不足 3 时直接最后一行）触发，留一点网络余量。
    func shouldTriggerLoadMore(at index: Int) -> Bool {
        guard hasMore, !isLoading, !isLoadingMore else { return false }
        let threshold = max(items.count - 3, 0)
        return index >= threshold
    }

    // MARK: - Private

    private func bumpGeneration() -> Int {
        generation += 1
        return generation
    }
}

// MARK: - WeeklyFeedSort localized

extension WeeklyFeedSort {
    var localizedTitle: String {
        switch self {
        case .latestEventAt:
            return String(localized: "weekly.sort.latestEvent")
        case .stars:
            return String(localized: "weekly.sort.starsDesc")
        case .pushedAt:
            return String(localized: "weekly.sort.pushedAt")
        }
    }
}
