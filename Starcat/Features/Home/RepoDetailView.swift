//
//  RepoDetailView.swift
//  Starcat
//
//  右栏：仓库详情。
//
//  Week 3：基础元信息卡片（头像、名称、描述、stats、topics、外链）。
//  Week 4：接入 README WebView 渲染 + ETag 缓存。
//
//  布局策略：
//  - 元信息卡片默认在顶部展示，README 区域占满剩余高度独立滚动
//  - README 向下滚动后收起元信息卡片，把阅读空间还给内容；回到顶部再展开
//
//  设计约束：
//  - 无选中行时显示空态
//  - 顶部外链 / clone 按钮由 RepoListView toolbar 统一承载，避免 detail toolbar 落到右栏左边
//  - README 加载通过 ReadmeViewModel 协调（由 HomeView 持有并通过 .onChange 驱动）
//
//  状态归属：
//  - HomeViewModel：列表 / sidebar / selectedRepo（环境注入）
//  - ReadmeViewModel：README 加载状态机（环境注入；HomeView 持有）
//  - 本 view 自身无状态
//

import SwiftUI
import AppKit

struct RepoDetailView: View {

    @Environment(HomeViewModel.self) private var viewModel
    @Environment(ReadmeViewModel.self) private var readmeVM
    // W4 B1：取消 star 需要的依赖
    @Environment(AppDependencies.self) private var dependencies
    @Environment(AuthSession.self) private var authSession
    // Trending 页面 ViewModel（用于更新 stars 计数）
    @Environment(\.trendingViewModel) private var trendingViewModel

    // W4 B1：取消 star 流程的 UI 状态
    @State private var showUnstarConfirm: Bool = false
    @State private var isUnstarring: Bool = false
    @State private var unstarError: String?

    /// Trending repo 一键 star 的 UI 状态
    @State private var isStarringTrending: Bool = false
    @State private var trendingStarError: String?

    /// README 向下滚动时折叠顶部信息面板。
    ///
    /// 这里用 Bool 而不是把 offset 存成状态，是为了避免 WebView 每个滚动像素都触发
    /// SwiftUI 重绘；只有跨过阈值时才改变布局。
    @State private var isMetadataPanelHidden: Bool = false

    /// 顶部信息面板的自然高度。
    ///
    /// 折叠动画需要从「真实高度」连续压到 0，而不是把 view 直接从树里移除。
    /// 这个高度由 `MetadataPanelHeightPreferenceKey` 在首次布局后回填。
    @State private var metadataPanelHeight: CGFloat = 0

    /// 顶部面板折叠/展开动画。
    ///
    /// 用轻阻尼 spring 比 easeInOut 更适合这里：面板高度变化会带动 WKWebView 重新分配空间，
    /// spring 能让读者感觉内容是在跟手让位，而不是突然跳一下。
    private var metadataPanelAnimation: Animation {
        .interactiveSpring(response: 0.32, dampingFraction: 0.9, blendDuration: 0.08)
    }

    /// Trending repo 的元信息（当从 Trending 列表选中时非 nil）。
    var selectedTrendingRepo: TrendingRepo?

    init(selectedTrendingRepo: TrendingRepo? = nil) {
        self.selectedTrendingRepo = selectedTrendingRepo
    }

    var body: some View {
        if let repo = viewModel.selectedRepo {
            VStack(alignment: .leading, spacing: 0) {
                metadataPanel(repo)
                readmeSection(repo)
            }
            .navigationTitle(repo.name)
            .navigationSubtitle(repo.owner)
            .alert("repo.unstar.confirm", isPresented: $showUnstarConfirm, presenting: repo) { repo in
                Button("repo.unstar.action", role: .destructive) {
                    Task { await performUnstar(repo: repo) }
                }
                Button("repo.unstar.dontUnstar", role: .cancel) {}
            } message: { repo in
                Text("repo.unstar.message \(repo.fullName)")
            }
            .alert("repo.unstar.failed", isPresented: errorAlertBinding, presenting: unstarError) { _ in
                Button("general.ok") { unstarError = nil }
            } message: { msg in
                Text(LocalizedStringKey(msg))
            }
            .onChange(of: repo.id) { _, _ in
                withAnimation(metadataPanelAnimation) {
                    isMetadataPanelHidden = false
                }
            }
        } else if let trending = selectedTrendingRepo {
            // Trending repo 详情页（无本地数据，只显示 README）
            VStack(alignment: .leading, spacing: 0) {
                trendingMetadataPanel(trending)
                trendingReadmeSection(trending)
            }
            .navigationTitle(trending.name)
            .navigationSubtitle(trending.owner)
        } else {
            emptyState
        }
    }

    // MARK: - W4 B1：Unstar 流程

    /// 1. 调 GitHub API 远端解除（失败：alert 报错、不动本地）
    /// 2. 调本地 markUnstarred（保留 tag / note，给 re-star 留后路）
    /// 3. 触发 Sidebar + 列表刷新（HomeViewModel 自带 race 防护）
    private func performUnstar(repo: Repo) async {
        guard case .authenticated(let user) = authSession.state else {
            unstarError = "auth.needLogin"
            return
        }
        isUnstarring = true
        defer { isUnstarring = false }
        do {
            try await dependencies.apiClient.unstar(owner: repo.owner, repo: repo.name)
            try await dependencies.repoRepository.markUnstarred(repoId: repo.id, userID: user.id)
            // 刷新 Sidebar 计数 + 列表（reloadItems 内部会清掉已不在列表的 selection）
            await viewModel.refreshSidebar()
            await viewModel.reloadItems()
        } catch {
            unstarError = "repo.unstar.actionFailed"
            AppLog.sync.error("unstar failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 错误 alert 的 isPresented binding —— 让 unstarError 非 nil 时弹窗
    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { unstarError != nil },
            set: { if !$0 { unstarError = nil } }
        )
    }

    /// 顶部信息面板容器。
    ///
    /// 为什么不继续用 `if !isMetadataPanelHidden { ... }`：
    /// 直接插拔 view 会让整个 WKWebView 在同一帧拿到新高度，视觉上像“跳变”；
    /// 这里让面板始终留在 view tree 中，只把外层 frame 从自然高度动画到 0，
    /// 同时给内容做轻微上移和淡出，WebView 的高度变化会更连续。
    private func metadataPanel(_ repo: Repo) -> some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                metadataHeader(repo)
                Divider()
                    .opacity(isMetadataPanelHidden ? 0 : 1)
            }
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: MetadataPanelHeightPreferenceKey.self,
                        value: proxy.size.height
                    )
                }
            }
            .opacity(isMetadataPanelHidden ? 0 : 1)
            .offset(y: isMetadataPanelHidden ? -min(metadataPanelHeight * 0.18, 28) : 0)
            .allowsHitTesting(!isMetadataPanelHidden)
            .accessibilityHidden(isMetadataPanelHidden)
        }
        .frame(
            height: isMetadataPanelHidden
                ? 0
                : (metadataPanelHeight > 0 ? metadataPanelHeight : nil),
            alignment: .top
        )
        .clipped()
        .animation(metadataPanelAnimation, value: isMetadataPanelHidden)
        .onPreferenceChange(MetadataPanelHeightPreferenceKey.self) { height in
            guard height > 0, abs(height - metadataPanelHeight) > 0.5 else { return }
            metadataPanelHeight = height
        }
    }

    /// 元信息区域（不滚动，固定在顶部）。
    private func metadataHeader(_ repo: Repo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(repo)
            descriptionSection(repo)
            statsSection(repo)
            // W4 A3：用户自定义标签段；GitHub topics 已收进 header 的单行信息。
            RepoTagsSection(repo: repo)
            // W4 A4：私有笔记 + 状态段
            RepoNotesSection(repo: repo)
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// README 区域。占据剩余高度，由 WebView 自己处理滚动。
    ///
    /// 把 `owner` / `name` 透传给 ReadmeWebView 用于图片相对路径重写
    /// （GitHub HTML render 端点对原生 `<img src="./xx">` 不做绝对化，
    /// 必须客户端补一次 raw URL 改写）。
    private func readmeSection(_ repo: Repo) -> some View {
        ReadmeStateView(
            state: readmeVM.state,
            baseURL: URL(string: repo.htmlUrl),
            owner: repo.owner,
            repo: repo.name,
            onScrollOffsetChange: updateMetadataPanelVisibility
        ) {
            readmeVM.reload(repo: repo, isLoggedIn: authSession.state.isAuthenticated)
        } onLogin: {
            authSession.signIn()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// WebView 内部滚动位置 → 顶部信息面板显示状态。
    ///
    /// 使用两个阈值形成 hysteresis：
    /// - 继续向下读到 32pt 后才隐藏，避免刚滚动一点就抢走上下文；
    /// - 回到 8pt 内才展开，避免触控板在顶部附近轻微回弹导致反复闪动。
    private func updateMetadataPanelVisibility(offsetY: CGFloat) {
        let shouldHide = isMetadataPanelHidden ? offsetY > 8 : offsetY > 32
        guard shouldHide != isMetadataPanelHidden else { return }
        withAnimation(metadataPanelAnimation) {
            isMetadataPanelHidden = shouldHide
        }
    }

    // MARK: - Trending Repo 支持

    /// Trending repo 顶部信息面板。
    private func trendingMetadataPanel(_ repo: TrendingRepo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            trendingHeader(repo)
            trendingStatsSection(repo)
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Trending repo 头部信息。
    private func trendingHeader(_ repo: TrendingRepo) -> some View {
        HStack(alignment: .top, spacing: 16) {
            RemoteAvatar(
                urlString: TrendingRepoAvatarURL.from(owner: repo.owner),
                size: 64
            )
            VStack(alignment: .leading, spacing: 5) {
                Text(repo.fullName)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                    .help(repo.fullName)

                if let desc = repo.description, !desc.isEmpty {
                    Text(desc)
                        .font(.body)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
        }
    }

    /// Trending repo 统计信息。
    private func trendingStatsSection(_ repo: TrendingRepo) -> some View {
        HStack(alignment: .center, spacing: 24) {
            Button {
                Task { await starTrending(repo: repo) }
            } label: {
                if isStarringTrending {
                    ProgressView()
                        .scaleEffect(0.6)
                } else {
                    StatItem(label: "repo.stars", value: repo.starsCount, systemImage: "star.fill", tint: .yellow)
                }
            }
            .buttonStyle(.plain)
            .disabled(isStarringTrending)
            .help("trending.star")

            StatItem(label: "repo.forks", value: repo.forksCount, systemImage: "tuningfork", tint: .secondary)

            if let language = repo.language, !language.isEmpty {
                HStack(spacing: 4) {
                    Circle()
                        .fill(LanguageColor.color(for: language))
                        .frame(width: 8, height: 8)
                    Text(language)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 2) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
                Text(repo.periodText)
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
            }

            Link(destination: repo.url) {
                HStack(spacing: 4) {
                    Image(systemName: "safari")
                    Text("repo.openOnGithub")
                }
                .font(.caption)
            }
            .buttonStyle(.bordered)
            .focusEffectDisabled()

            Spacer()
        }
    }

    /// 执行 Trending repo 的 star 操作。
    private func starTrending(repo: TrendingRepo) async {
        guard authSession.state.isAuthenticated else {
            trendingStarError = "auth.needLogin"
            return
        }

        isStarringTrending = true
        trendingStarError = nil

        do {
            try await dependencies.apiClient.star(owner: repo.owner, repo: repo.name)
            // 成功：本地 stars 计数 +1
            trendingViewModel?.incrementStarsCount(fullName: repo.fullName)
            // 刷新用户 Stars 列表
            await viewModel.reloadItems()
        } catch {
            trendingStarError = "repo.star.failed"
        }

        isStarringTrending = false
    }

    /// Trending repo README 区域。
    private func trendingReadmeSection(_ repo: TrendingRepo) -> some View {
        ReadmeStateView(
            state: readmeVM.state,
            baseURL: repo.url,
            owner: repo.owner,
            repo: repo.name,
            onScrollOffsetChange: { _ in }
        ) {
            // Trending README 刷新：直接调用 loadTrending
            readmeVM.loadTrending(owner: repo.owner, repo: repo.name, isLoggedIn: authSession.state.isAuthenticated)
        } onLogin: {
            authSession.signIn()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Trending repo 头像 URL。
    private enum TrendingRepoAvatarURL {
        static func from(owner: String) -> String {
            "https://github.com/\(owner).png?size=80"
        }
    }

    /// Trending repo 语言颜色。
    private enum LanguageColor {
        static func color(for language: String) -> Color {
            switch language {
            case "Swift":        return Color(red: 0.94, green: 0.31, blue: 0.20)
            case "Python":       return Color(red: 0.23, green: 0.46, blue: 0.69)
            case "JavaScript":   return Color(red: 0.94, green: 0.86, blue: 0.32)
            case "TypeScript":   return Color(red: 0.18, green: 0.46, blue: 0.78)
            case "Go":           return Color(red: 0.00, green: 0.68, blue: 0.84)
            case "Rust":         return Color(red: 0.86, green: 0.41, blue: 0.27)
            case "Java":         return Color(red: 0.69, green: 0.38, blue: 0.12)
            default:             return Color.gray
            }
        }
    }

    // MARK: - 子段

    private func header(_ repo: Repo) -> some View {
        HStack(alignment: .top, spacing: 16) {
            RemoteAvatar(urlString: RepoAvatarURL.from(owner: repo.owner), size: 64)
            VStack(alignment: .leading, spacing: 5) {
                Text(repo.fullName)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                    .help(repo.fullName)
                badgeRow(repo)
                inlineTopicsRow(repo)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
        }
    }

    @ViewBuilder
    private func badgeRow(_ repo: Repo) -> some View {
        HStack(spacing: 10) {
            if repo.isArchived {
                BadgeChip(text: "repo.archived", systemImage: "archivebox", tint: .orange)
            }
            if repo.isFork {
                BadgeChip(text: "repo.fork", systemImage: "tuningfork", tint: .gray)
            }
            if repo.isPrivate {
                BadgeChip(text: "repo.private", systemImage: "lock.fill", tint: .purple)
            }
            RawBadgeChip(
                text: repo.license.flatMap { value in
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                } ?? "N/A",
                systemImage: "scale.3d",
                tint: .secondary
            )
        }
        .lineLimit(1)
        .frame(minHeight: 18, maxHeight: 18, alignment: .leading)
    }

    @ViewBuilder
    private func inlineTopicsRow(_ repo: Repo) -> some View {
        let topics = repo.topicsArray
        let topicText = topics.isEmpty ? "N/A" : topics.joined(separator: "  ·  ")
        HStack(spacing: 6) {
            Text("repoTopics.label")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(topicText)
                .font(.caption)
                .foregroundStyle(topics.isEmpty ? Color.secondary : Color.blue)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(Text(verbatim: topics.isEmpty ? "N/A" : topics.joined(separator: ", ")))
        }
        .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 18, alignment: .leading)
    }

    @ViewBuilder
    private func descriptionSection(_ repo: Repo) -> some View {
        if let desc = repo.description, !desc.isEmpty {
            Text(desc)
                .font(.body)
                .textSelection(.enabled)
        }
    }

    private func statsSection(_ repo: Repo) -> some View {
        HStack(alignment: .center, spacing: 24) {
            Button {
                showUnstarConfirm = true
            } label: {
                StatItem(label: "repo.stars", value: repo.starsCount, systemImage: "star.fill", tint: .yellow)
            }
            .buttonStyle(.plain)
            .help("repo.unstar")

            Button {
                if let url = URL(string: "\(repo.htmlUrl)/fork") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                StatItem(label: "repo.forks", value: repo.forksCount, systemImage: "tuningfork", tint: .secondary)
            }
            .buttonStyle(.plain)
            .help("repo.forkAction")

            WatchersMenu(repo: repo)

            DateStatItem(label: "repo.created", value: repo.createdAt, systemImage: "calendar.badge.plus")
            DateStatItem(label: "repo.updated", value: repo.updatedAt, systemImage: "clock.arrow.circlepath")
        }
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
            Text("empty.noSelection")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("empty.selectFromList")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}

private struct MetadataPanelHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - README 状态视图

/// 把 ReadmeViewModel.LoadState 翻译为视觉。
///
/// 拆成独立 View 的好处：
/// - 状态切换造成的 view tree 重建只影响这一块，元信息区不受波及
/// - 重试按钮的回调通过闭包传入，保持本组件无副作用
private struct ReadmeStateView: View {

    @Environment(ReadmeViewModel.self) private var readmeVM

    let state: ReadmeViewModel.LoadState
    let baseURL: URL?
    /// 仓库 owner / name —— 透传给 ReadmeWebView 用于图片相对路径重写
    let owner: String
    let repo: String
    let onScrollOffsetChange: (CGFloat) -> Void
    let onRetry: () -> Void
    /// 未登录用户点击"登录"按钮时的回调
    let onLogin: () -> Void

    var body: some View {
        switch state {
        case .idle, .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text("readme.loading")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded(let html, let cachedAt):
            VStack(spacing: 0) {
                ReadmeWebView(
                    htmlFragment: html,
                    baseURL: baseURL,
                    owner: owner,
                    repo: repo,
                    onScrollOffsetChange: onScrollOffsetChange
                )
                cacheFooter(cachedAt: cachedAt)
            }

        case .empty:
            VStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
                Text("readme.empty")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("readme.emptyDescription")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .requiresLogin:
            VStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 36))
                    .foregroundStyle(.blue)
                Text("readme.requiresLogin")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("readme.requiresLoginDescription")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button("action.login", action: onLogin)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .focusEffectDisabled()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .error(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36))
                    .foregroundStyle(.orange)
                Text("readme.failed")
                    .font(.headline)
                Text(verbatim: message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button("action.retry", action: onRetry)
                    .controlSize(.small)
                    .focusEffectDisabled()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 缓存时间脚注，便于用户判断是否需要手动刷新。
    private func cacheFooter(cachedAt: Date) -> some View {
        HStack {
            Image(systemName: "clock")
                .font(.caption2)
            Text("readme.cachedAt \(cachedAt.formatted(.relative(presentation: .named)))")
                .font(.caption2)
            Spacer()
            Button {
                onRetry()
            } label: {
                if readmeVM.isRefreshing {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2)
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2)
                }
            }
            .buttonStyle(.borderless)
            .focusEffectDisabled()
            .disabled(readmeVM.isRefreshing)
            .help("readme.refresh")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 6)
        .foregroundStyle(.secondary)
        .background(.bar)
    }
}

// MARK: - 小组件

/// 通用胶囊徽章；命名避开 `Tag`（与 Core/Database/Models/Tag 冲突）。
private struct BadgeChip: View {
    let text: LocalizedStringKey
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage).font(.caption2)
            Text(text).font(.caption2)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(tint.opacity(0.15), in: Capsule())
        .foregroundStyle(tint)
    }
}

private struct RawBadgeChip: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage).font(.caption2)
            Text(verbatim: text).font(.caption2)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(tint.opacity(0.15), in: Capsule())
        .foregroundStyle(tint)
    }
}

private struct StatItem: View {
    let label: LocalizedStringKey
    let value: Int
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .center, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .font(.system(size: 14))
                Text(value, format: .number)
                    .monospacedDigit()
                    .font(.system(size: 14, weight: .medium))
            }
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

private struct DateStatItem: View {
    let label: LocalizedStringKey
    let value: String?
    let systemImage: String

    var body: some View {
        VStack(alignment: .center, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                Text(formattedDate)
                    .monospacedDigit()
                    .lineLimit(1)
                    .font(.system(size: 12, weight: .medium))
            }
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var formattedDate: String {
        guard let value, let date = ISO8601DateFormatter().date(from: value) else {
            return "-"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

struct WatchersMenu: View {
    let repo: Repo
    @Environment(AppDependencies.self) private var dependencies
    
    enum WatchState: Equatable {
        case loading
        case participating // un-watched (default)
        case allActivity // subscribed: true, ignored: false
        case ignore // subscribed: false, ignored: true
        case custom // other states
        case error
    }
    
    @State private var watchState: WatchState = .loading
    
    var body: some View {
        Menu {
            switch watchState {
            case .loading:
                Text("watch.loading")
            case .error:
                Button("action.retry") {
                    Task { await fetchSubscription() }
                }
            default:
                Button {
                    Task { await updateSubscription(subscribed: false, ignored: false) }
                } label: {
                    if watchState == .participating {
                        Label("watch.participating", systemImage: "checkmark")
                    } else {
                        Text("watch.participating")
                    }
                }

                Button {
                    Task { await updateSubscription(subscribed: true, ignored: false) }
                } label: {
                    if watchState == .allActivity {
                        Label("watch.allActivity", systemImage: "checkmark")
                    } else {
                        Text("watch.allActivity")
                    }
                }

                Button {
                    Task { await updateSubscription(subscribed: false, ignored: true) }
                } label: {
                    if watchState == .ignore {
                        Label("watch.ignore", systemImage: "checkmark")
                    } else {
                        Text("watch.ignore")
                    }
                }

                Divider()

                Button {
                    if let url = URL(string: "\(repo.htmlUrl)/watchers") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("watch.viewOnGithub", systemImage: "safari")
                }
            }
        } label: {
            StatItem(label: "repo.watchers", value: repo.watchersCount, systemImage: "eye.fill", tint: .secondary)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("repo.watch")
        .task(id: repo.id) {
            await fetchSubscription()
        }
    }
    
    private func fetchSubscription() async {
        watchState = .loading
        do {
            let dto = try await dependencies.apiClient.getSubscription(owner: repo.owner, repo: repo.name)
            if dto.subscribed {
                watchState = .allActivity
            } else if dto.ignored {
                watchState = .ignore
            } else {
                watchState = .custom
            }
        } catch NetworkError.notFound {
            watchState = .participating
        } catch {
            watchState = .error
        }
    }
    
    private func updateSubscription(subscribed: Bool, ignored: Bool) async {
        let previousState = watchState
        watchState = .loading
        do {
            if !subscribed && !ignored {
                try await dependencies.apiClient.deleteSubscription(owner: repo.owner, repo: repo.name)
                watchState = .participating
            } else {
                let dto = try await dependencies.apiClient.putSubscription(
                    owner: repo.owner,
                    repo: repo.name,
                    subscribed: subscribed,
                    ignored: ignored
                )
                if dto.subscribed {
                    watchState = .allActivity
                } else if dto.ignored {
                    watchState = .ignore
                } else {
                    watchState = .custom
                }
            }
        } catch {
            AppLog.sync.error("Update subscription failed: \(error.localizedDescription, privacy: .public)")
            watchState = previousState
        }
    }
}
