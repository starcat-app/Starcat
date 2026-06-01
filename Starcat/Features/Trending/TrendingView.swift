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
            await viewModel.reload()
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

    private var toolbarView: some View {
        HStack {
            Spacer()
            periodPicker
            Spacer()
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
    /// 绘制 macOS 系统蓝色选中底色，把 `TrendingRepoRowSurface` 自定义的语言色
    /// accent bar / 轻 accent 底 / 细 accent 边框完全压住，导致两个列表视觉割裂
    /// （Trending 卡片像一整块强蓝色，Manage 卡片是克制的语言色）。
    /// 改用 plain Button 写 `selectedRepoID`，仍触发 HomeView 的
    /// `.onChange(of: selectedRepoID)` 加载详情，但选中外观完全交给 `TrendingRepoRowView`。
    private var contentView: some View {
        List {
            // "为你推荐"卡片暂时隐藏（dong4j 2026-06-01）：当前推荐质量还不稳定，先关掉。
            // 重新启用：把 showsRecommendations 改回 true 即可，逻辑与 UI 均保留。
            if Self.showsRecommendations, !viewModel.recommendedRepos.isEmpty {
                personalizedSection
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            // Trending 列表：plain Button 包裹 row，点击写 selectedRepoID。
            // 不用 `.tag(repo.id)`，selection 完全由 isSelected 入参驱动。
            ForEach(indexedRepos) { item in
                let repo = item.repo
                Button {
                    selectedRepoID = repo.id
                } label: {
                    TrendingRepoRowView(
                        repo: repo,
                        density: settings.listDensity,
                        isSelected: selectedRepoID == repo.id
                    )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .listRowReveal(index: item.index, snapshotID: viewModel.reposRevision)
                .listRowInsets(padding)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .id(viewModel.reposRevision)
        .listStyle(.inset)
        .alternatingRowBackgrounds()
        .refreshable {
            await viewModel.reload()
        }
    }

    /// 每个卡片的 list row insets，决定卡片间距。
    private var padding: EdgeInsets {
        EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
    }

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
                    await viewModel.reload()
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

// MARK: - TrendingRepoCard

/// Trending 仓库卡片
/// 使用 List(selection:) 原生 selection 样式，无需自定义选中高亮。
struct TrendingRepoCard: View {

    let repo: TrendingRepo
    let score: TrendingScore
    let isSubscribing: Bool
    let isSubscribed: Bool
    let onSubscribe: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 头部：名称 + 语言
            headerView

            // 描述
            if let desc = repo.description, !desc.isEmpty {
                Text(desc)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            // 统计信息
            statsView

            // AI 评分
            scoreView
        }
        .padding(16)
    }

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(repo.name)
                    .font(.headline)

                Text(repo.owner)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let lang = repo.language {
                HStack(spacing: 4) {
                    Circle()
                        .fill(languageColor(for: lang))
                        .frame(width: 8, height: 8)
                    Text(lang)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(NSColor.quaternaryLabelColor))
                .clipShape(Capsule())
            }
        }
    }

    private var statsView: some View {
        HStack(spacing: 16) {
            // Stars - 点击直接订阅
            Button {
                if !isSubscribed && !isSubscribing {
                    onSubscribe()
                }
            } label: {
                HStack(spacing: 4) {
                    if isSubscribing {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: isSubscribed ? "star.fill" : "star")
                            .foregroundStyle(isSubscribed ? .orange : .secondary)
                    }
                    Text("\(repo.starsCount)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(isSubscribing || isSubscribed)

            // Forks
            HStack(spacing: 4) {
                Image(systemName: "tuningfork")
                    .foregroundStyle(.secondary)
                Text("\(repo.forksCount)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            // 周期增长
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.right")
                    .foregroundStyle(.green)
                Text(repo.periodText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // 贡献者头像
            if !repo.contributors.isEmpty {
                HStack(spacing: -6) {
                    ForEach(repo.contributors.prefix(5)) { contributor in
                        AsyncImage(url: contributor.avatarURL) { image in
                            image
                                .resizable()
                                .scaledToFit()
                        } placeholder: {
                            Circle()
                                .fill(Color.gray.opacity(0.3))
                        }
                        .frame(width: 20, height: 20)
                        .clipShape(Circle())
                        .overlay(
                            Circle()
                                .stroke(Color(NSColor.windowBackgroundColor), lineWidth: 1)
                        )
                    }

                    if repo.contributors.count > 5 {
                        Text("+\(repo.contributors.count - 5)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var scoreView: some View {
        HStack(spacing: 8) {
            // AI 评分
            HStack(spacing: 4) {
                Text("trending.aiScore")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("\(score.total)")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(scoreColor)

                Text(score.level.displayName)
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(scoreColor.opacity(0.2))
                    .foregroundStyle(scoreColor)
                    .clipShape(Capsule())
            }

            Spacer()

            // GitHub 链接
            Link(destination: repo.url) {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                    Text("trending.view")
                }
                .font(.caption)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .foregroundStyle(Color.accentColor)
        }
    }

    private var scoreColor: Color {
        switch score.level {
        case .excellent: return .green
        case .good: return .blue
        case .average: return .orange
        case .low: return .gray
        }
    }

    private func languageColor(for language: String) -> Color {
        // 常用语言颜色映射
        switch language.lowercased() {
        case "swift": return .red
        case "python": return .blue
        case "typescript", "javascript": return .yellow
        case "go": return .cyan
        case "rust": return .orange
        case "java": return .brown
        case "kotlin": return .purple
        case "dart": return .teal
        default: return .gray
        }
    }
}
