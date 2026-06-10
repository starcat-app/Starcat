//
//  TrendingView.swift
//  Starcat
//
//  GitHub Trending 页面视图。
//
//  功能：
//  - 日/周/月榜切换
//  - 按语言筛选（由左侧 Trending 语言列表驱动）
//  - 展示 Trending 仓库列表
//  - 显示 AI 评分
//  - 显示个性化推荐区块
//  - 点击星标直接订阅到 Stars
//
//  设计约束：
//  - 使用 SwiftUI
//  - 遵循项目 UI 规范（focus ring 等）
//

import SwiftUI

// MARK: - Environment Key

private struct TrendingViewModelKey: EnvironmentKey {
    static let defaultValue: TrendingViewModel? = nil
}

extension EnvironmentValues {
    var trendingViewModel: TrendingViewModel? {
        get { self[TrendingViewModelKey.self] }
        set { self[TrendingViewModelKey.self] = newValue }
    }
}

struct TrendingView: View {

    /// "为你推荐"卡片开关。暂时关闭（dong4j 2026-06-01），需要时改回 true 即可。
    private static let showsRecommendations = false

    @Environment(AuthSession.self) private var authSession
    @Environment(HomeViewModel.self) private var homeViewModel
    @Environment(AppSettings.self) private var settings
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewModel: TrendingViewModel
    @State private var showLoginSheet: Bool = false
    @Binding private var selectedLanguage: TrendingLanguage

    /// 当前选中的 Trending repo ID（驱动 README 加载）。
    @Binding private var selectedRepoID: String?

    /// 当前选中的 Trending repo 完整数据（用于右侧详情页元信息展示）。
    @Binding private var selectedTrendingRepo: TrendingRepo?

    init(
        repository: any TrendingRepositoryProtocol,
        githubAPIClient: any GitHubAPIClientProtocol,
        selectedLanguage: Binding<TrendingLanguage>,
        selectedRepoID: Binding<String?> = .constant(nil),
        selectedTrendingRepo: Binding<TrendingRepo?> = .constant(nil)
    ) {
        _viewModel = State(initialValue: TrendingViewModel(
            repository: repository,
            githubAPIClient: githubAPIClient
        ))
        _selectedLanguage = selectedLanguage
        _selectedRepoID = selectedRepoID
        _selectedTrendingRepo = selectedTrendingRepo
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部工具栏
            toolbarView

            Divider()

            // 主要内容
            mainContentView
                .id(contentAnimationID)
                .transition(contentTransition)
                .animation(contentAnimation, value: contentAnimationID)
        }
        .task {
            viewModel.updateLanguagePreferences(from: homeViewModel.languageStats)
            if viewModel.selectedLanguage != selectedLanguage {
                viewModel.selectedLanguage = selectedLanguage
            }
            // 切换语言或页面时，列表数据变化，清除之前的 repo 选中状态
            // 避免详情页显示不属于当前列表的 repo
            if selectedRepoID != nil {
                selectedRepoID = nil
                selectedTrendingRepo = nil
            }
            // 首次进入页面：有缓存就不自动拉（forceNetwork=false）
            // 这是消除"二次入场动画"的关键：原版在缓存命中后还会盲目走网络再 bump 一次 revision
            // 现在缓存命中时直接上屏完事，让用户主动按刷新按钮决定何时拉新
            await viewModel.reload(forceNetwork: false)
        }
        .onChange(of: homeViewModel.languageStats) { _, stats in
            viewModel.updateLanguagePreferences(from: stats)
        }
        .onChange(of: selectedLanguage) { _, language in
            viewModel.selectedLanguage = language
        }
        .sheet(isPresented: $showLoginSheet) {
            GithubAuthView()
        }
        .onChange(of: authSession.state.isAuthenticated) { _, isAuthenticated in
            if isAuthenticated {
                showLoginSheet = false
            }
        }
        // 选中 repo 变化时，同步更新 selectedTrendingRepo 供右侧详情页使用
        .onChange(of: selectedRepoID) { _, newID in
            if let id = newID {
                selectedTrendingRepo = viewModel.repos.first { $0.id == id }
            } else {
                selectedTrendingRepo = nil
            }
        }
        .environment(\.trendingViewModel, viewModel)
    }

    // MARK: - Toolbar

    /// 三段布局：周期 picker **真居中** / 刷新组（freshness 文本 + 刷新 icon）右上角浮动。
    ///
    /// 设计要点（2026-06-02 dong4j 反馈"应该固定周期切换组件"调整）：
    /// - **周期 picker 真居中**（左右 Spacer 各占一半），与 toolbar 整体宽度对齐，
    ///   不会因左右两侧内容长度变化而漂移位置
    /// - **刷新组用 `.overlay(alignment: .trailing)` 浮动**：与 picker 布局**完全解耦**，
    ///   新鲜度文本从"刚刚"变到"12 小时前"再到"3 天前"，picker 视觉位置岿然不动
    /// - 新鲜度文字常驻显示，>1 小时变橙色提示陈旧（`isStale`），无缓存时整组隐藏
    /// - 刷新 icon 单独一个 Button，isRefreshing 时图标旋转动画
    /// - 整组用 `.help()` 显示完整 tooltip "上次刷新于 X 月 Y 日 HH:MM"（精确时间，hover 才看）
    ///
    /// 为什么不用 HStack + Spacer：HStack 里 Spacer 与右侧组件协商空间会反向影响 picker 的
    /// 视觉中心（picker 占满 maxWidth: 320 后 Spacer 才生效，但右侧组宽度变化时整体对齐方式
    /// 仍跟着变）；用 ZStack/overlay 让两者**走两个独立 layout pass**，picker 永远居中。
    private var toolbarView: some View {
        HStack {
            Spacer()
            periodPicker
            Spacer()
        }
        .overlay(alignment: .trailing) {
            HStack(spacing: 8) {
                freshnessIndicator
                refreshButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var periodPicker: some View {
        @Bindable var vm = viewModel

        return Picker("", selection: $vm.selectedPeriod) {
            ForEach(TrendingPeriod.allCases) { period in
                Text(period.displayName)
                    .font(.headline)
                    .tag(period)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 320)
    }

    /// "12 分钟前" 新鲜度提示。
    /// - 没有 lastRefreshedAt 时整组隐藏（`formattedFreshness == nil`）
    /// - >1 小时（`isStale`）变橙色提示陈旧，但不强制刷新
    @ViewBuilder
    private var freshnessIndicator: some View {
        if let text = viewModel.formattedFreshness {
            Text(text)
                .font(.caption)
                .foregroundStyle(viewModel.isStale ? Color.orange : Color.secondary)
                .help(absoluteFreshnessHelpText)
        }
    }

    /// 刷新 icon Button：常驻显示，isRefreshing 时图标旋转。
    /// hover 时 tooltip 显示"刷新榜单"或"上次刷新于 X 月 Y 日 HH:MM"。
    /// 使用共享 `SyncIconButton`（与详情页 cacheFooter 同款图标 + 旋转动画）。
    private var refreshButton: some View {
        SyncIconButton(
            isRefreshing: viewModel.isRefreshing,
            disabled: viewModel.isRefreshing || viewModel.isLoading,
            tooltip: refreshButtonHelpText
        ) {
            Task {
                await viewModel.reload(forceNetwork: true)
            }
        }
    }

    /// hover tooltip：精确显示"上次刷新于 X 月 Y 日 HH:MM"（绝对时间）。
    /// 没有 lastRefreshedAt 时显示"还未刷新过"。
    private var absoluteFreshnessHelpText: String {
        guard let date = viewModel.lastRefreshedAt else {
            return String(localized: "trending.freshness.neverRefreshed")
        }
        return String(
            format: String(localized: "trending.freshness.lastRefreshedAtFormat"),
            absoluteTimeFormatter.string(from: date)
        )
    }

    /// 刷新按钮 tooltip：根据状态切换文案。
    private var refreshButtonHelpText: String {
        if viewModel.isRefreshing {
            return String(localized: "trending.refresh.inProgress")
        }
        if let date = viewModel.lastRefreshedAt {
            return String(
                format: String(localized: "trending.refresh.tooltipWithLastFormat"),
                absoluteTimeFormatter.string(from: date)
            )
        }
        return String(localized: "trending.refresh.tooltip")
    }

    /// 绝对时间格式化器（"6 月 2 日 22:48" 简洁形式）。
    private var absoluteTimeFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.locale = Locale.current
        return f
    }

    // MARK: - Content

    @ViewBuilder
    private var mainContentView: some View {
        if viewModel.isLoading && viewModel.repos.isEmpty {
            loadingView
        } else if let error = viewModel.loadError, viewModel.repos.isEmpty {
            errorView(message: error)
        } else {
            contentView
        }
    }

    /// Trending repo 的带下标快照。
    ///
    /// index 只用于 row reveal 的短 stagger；id 仍来自 repo.id，保证 selection 与 row
    /// identity 跟原先 TrendingRepo.fullName 保持一致。
    private var indexedRepos: [IndexedTrendingRepo] {
        viewModel.repos.enumerated().map { IndexedTrendingRepo(index: $0.offset, repo: $0.element) }
    }

    /// 中栏 Trending 内容过渡身份键。
    ///
    /// 与 Manage 列表保持同一策略：分类 / 周期 / reload 结果变化时做整块轻过渡，
    /// row 本身只做可视区域内 reveal，不引入真正分页。
    private var contentAnimationID: String {
        if viewModel.isLoading && viewModel.repos.isEmpty {
            return "trending-loading-\(viewModel.selectedPeriod.id)-\(viewModel.selectedLanguage.id)"
        }
        if let error = viewModel.loadError, viewModel.repos.isEmpty {
            return "trending-error-\(viewModel.selectedPeriod.id)-\(viewModel.selectedLanguage.id)-\(error)"
        }
        return "trending-repos-\(viewModel.selectedPeriod.id)-\(viewModel.selectedLanguage.id)-\(viewModel.reposRevision)"
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

    /// 单选列表使用手动 selection，而不是 `List(selection:)`。
    ///
    /// 原因（与 Manage `RepoListView.listContent(_:)` 对齐）：`List(selection:)` 会强制
    /// 绘制 macOS 系统蓝色选中底色，把 `RepoRowSurface` 自定义的语言色 accent bar /
    /// 轻 accent 底 / 细 accent 边框完全压住，导致两个列表视觉割裂。改用 plain Button
    /// 写 `selectedRepoID`，仍触发 HomeView 的 `.onChange(of: selectedRepoID)` 加载详情，
    /// 选中外观完全交给 `UnifiedRepoRow.isSelected` 驱动。
    ///
    /// **R-01 v1.2 Phase B2（2026-06-10）**：row 视图从 `TrendingRepoRowView` 切到
    /// `UnifiedRepoRow(card:isSelected:)`，与 Manage / Weekly / Activity-repo-backed
    /// 共用同一份卡片骨架。`StarredRegistry.contains(ghRepoId:)` 自动驱动 row 上的 ✓
    /// 标记：用户在详情页 star / unstar 后无需手动 reload，registry 是 `@Observable`，
    /// SwiftUI 会重新调用 `repo.asCardData(registry:)` 让 row 同步刷新。
    private var contentView: some View {
        List {
            // "为你推荐"卡片暂时隐藏（dong4j 2026-06-01）：当前推荐质量还不稳定，先关掉。
            // 重新启用：把 showsRecommendations 改回 true 即可，逻辑与 UI 均保留。
            if Self.showsRecommendations, !viewModel.recommendedRepos.isEmpty {
                personalizedSection
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            // Trending 列表：plain Button 包裹 UnifiedRepoRow，点击写 selectedRepoID。
            // 不用 `.tag(repo.id)`，selection 完全由 isSelected 入参驱动。
            //
            // 关键：**不**给 List 加 `.id(viewModel.reposRevision)`！
            // 给 List 绑定 id 会强制销毁重建整个 List 视图树，
            // 让 stars/forks 等数值字段变化也触发"全量重建"，导致用户感知"列表又重新加载了一次"。
            // 现在让 SwiftUI 走 ForEach + Identifiable 的天然 diff：
            // - 同 fullName 的 row 留在原地，stars 数等字段 in-place 更新（无动画）
            // - 新增/删除/换序的 row 才有动画（由 row reveal 处理）
            ForEach(indexedRepos) { item in
                let repo = item.repo
                Button {
                    selectedRepoID = repo.id
                } label: {
                    UnifiedRepoRow(
                        card: repo.asCardData(registry: dependencies.starredRegistry),
                        isSelected: selectedRepoID == repo.id
                    )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .listRowReveal(index: item.index, snapshotID: viewModel.reposRevision)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
        .refreshable {
            await viewModel.reload(forceNetwork: true)
        }
    }
    //
    // 历史：原本这里有 `.listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))`
    // 配合 `private var padding`，多塞了一层 12pt 左右内边距，造成 Trending 卡片整体比 Manage
    // 列表的卡片多缩一圈（dong4j 2026-06-02 反馈）。已移除——现在 Trending 和 Manage 共用
    // 系统 `.inset` listStyle 的默认行距 / 边距，两边视觉宽度对齐。

    private var personalizedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundStyle(.orange)
                Text("trending.recommendTitle")
                    .font(.headline)
                Spacer()
            }

            if viewModel.userLanguagePreferences.isEmpty {
                Text("trending.basedOnTrending")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("trending.basedOnPrefs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                ForEach(viewModel.recommendedRepos) { repo in
                    Text(repo.fullName)
                        .font(.caption)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(NSColor.controlBackgroundColor))
                        .clipShape(Capsule())
                }
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text("trending.loading")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Error

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)

            Text("trending.loadFailed")
                .font(.headline)

            Text(verbatim: message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("trending.retry") {
                Task {
                    await viewModel.reload(forceNetwork: true)
                }
            }
            .buttonStyle(.borderedProminent)
            .focusEffectDisabled()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 带可见顺序的 Trending repo 包装。
///
/// `id` 仍使用 repo.id，确保 `List(selection:)` 与 `.tag(repo.id)` 继续匹配；
/// index 只参与渐进式入场 delay 计算，不改变业务身份。
private struct IndexedTrendingRepo: Identifiable {
    let index: Int
    let repo: TrendingRepo

    var id: String { repo.id }
}

// MARK: - TrendingRepoCard 已删除（R-01 v1.2 Phase B2，2026-06-10）
//
// 该结构体作为 Trending 列表 row 的早期实现长期未被引用（grep 全项目零调用方），
// row 视图链路实际是 TrendingRepoRowView → R-01 切换到 UnifiedRepoRow。
// 删除以保持单一真源，避免后续协作者误读为「现行实现」。
// 历史代码仍可在 git blame / commit `TrendingRepoCard 死代码删除` 之前的版本里找回。
