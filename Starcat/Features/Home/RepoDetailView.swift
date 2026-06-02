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
        // 当前不要给 detail 再加 `.frame(minWidth:)`。
        //
        // 之前尝试用 770pt 固定 detail 可读宽度，但它会和 NavigationSplitView 的
        // sidebar 折叠/展开协商叠加：窗口缩到 1190 后再展开左栏时，SwiftUI 需要同时
        // 满足左栏、列表和 detail 的下限，容易出现左栏抽屉或窗口宽度跳动。
        // 运行期硬下限统一交给 `MainWindowFrameModifier` 的 AppKit `contentMinSize`，
        // detail 在这个边界内自适应。
        Group {
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
                    Text(String(format: String(localized: "repo.unstar.messageFormat"), repo.fullName))
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
            // Contributors 头像组（2026-06-02 从卡片移过来）。
            // 卡片窄宽度下贡献者头像会被 List 水平裁剪，详情页空间更宽裕，
            // 用稍大的 24pt 头像 + 可点击跳 GitHub profile + hover 显示 username。
            if !repo.contributors.isEmpty {
                trendingContributorsSection(repo)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Trending repo 贡献者头像组。
    ///
    /// 设计要点（与原卡片版差异）：
    /// - 头像 32pt（卡片版 16pt / 旧版 24pt），与上方 `.title3` Stars/Forks 数字
    ///   视觉权重对齐；旧版 24pt 在大字号统计旁显得太弱，dong4j 2026-06-02 反馈
    /// - 最多显示 6 个（卡片版 3），溢出用 "+N" 提示
    /// - 每个头像包在 `Button { NSWorkspace.open(profileURL) }` 里，点击跳 GitHub profile
    ///   （不用 `Link(destination:)`，原因见 `contributorAvatar` 内的详细注释）
    /// - `.help(username)` 鼠标 hover 显示用户名，比卡片头像更有信息密度
    /// - 头像之间负 spacing -10 实现 GitHub PR 卡片风格的重叠效果
    ///   （随头像放大同步从 -6 增到 -10，保持视觉重叠比例）
    ///
    /// 关于"贡献者非常多"的兜底：当前数据源是 GitHub Trending 页面的 `buildBy`，
    /// 上限实测就是 5 人，所以 `prefix(6)` 在当前数据下永远不会触发裁切。
    /// 保留 `prefix(6)` + "+N" 仅作防御性兜底，不为未发生的场景过度设计。
    /// 未来若接入 GitHub `/contributors` API（可能上百人），届时再加 Popover 展开。
    private func trendingContributorsSection(_ repo: TrendingRepo) -> some View {
        HStack(spacing: -10) {
            ForEach(repo.contributors.prefix(6)) { contributor in
                contributorAvatar(contributor)
            }

            if repo.contributors.count > 6 {
                Text(verbatim: "+\(repo.contributors.count - 6)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 10)
            }
        }
    }

    /// 单个贡献者头像。
    /// - 有 profileURL 时包 Button + NSWorkspace.open 让头像可点击跳 GitHub
    /// - 无 profileURL 时退化为静态图（容错路径，正常不会触发）
    ///
    /// **为什么用 Button 而不是 `Link(destination:)`**：
    /// SwiftUI 的 `Link` 在 macOS 上有个已知问题——外层 `.help()` 的 NSView.toolTip
    /// 传不到 Link 内部，hover 不会弹 tooltip。项目内其他能正常弹 tooltip 的圆形头像
    /// （`Shared/Components/RemoteAvatar.swift` 的 `OwnerAvatarButton`、
    /// `Features/Tags/SFSymbolPicker.swift`、`Features/Tags/TagEditorView.swift` 等）
    /// 全部用 `Button { NSWorkspace.shared.open(url) }` 模式，已验证 tooltip 可正常弹。
    /// 此处对齐同款实现，避免重蹈 `Link` 的 tooltip 失效坑。
    /// 2026-06-02 dong4j 反馈"hover 没弹 username"，根因即是上一版用了 `Link`。
    @ViewBuilder
    private func contributorAvatar(_ contributor: TrendingRepo.Contributor) -> some View {
        if let profileURL = contributor.profileURL {
            Button {
                NSWorkspace.shared.open(profileURL)
            } label: {
                contributorAvatarImage(contributor)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            // 2026-06-02 dong4j 要求统一 hover 反馈：跟 hero logo / stats Button
            // 用同一套 `.pressableHover()`，让用户能感知贡献者头像可点击跳 profile。
            .pressableHover()
            .help(contributor.username)
        } else {
            contributorAvatarImage(contributor)
                .help(contributor.username)
        }
    }

    /// 贡献者头像图片本体（带边框 + 圆形裁切）。
    ///
    /// 尺寸 32pt：与详情页 `.title3` 量级 Stars/Forks 数字视觉权重对齐。
    /// 边框 2pt：头像放大后 1.5pt 边框显瘦，2pt 才能撑起"叠片"分隔感。
    private func contributorAvatarImage(_ contributor: TrendingRepo.Contributor) -> some View {
        AsyncImage(url: contributor.avatarURL) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            Circle().fill(Color.gray.opacity(0.3))
        }
        .frame(width: 32, height: 32)
        .clipShape(Circle())
        .overlay(
            Circle()
                .stroke(Color(NSColor.controlBackgroundColor).opacity(0.9), lineWidth: 2)
        )
    }

    /// Trending repo 头部信息。
    ///
    /// 2026-06-02 dong4j 调整：原 `trendingStatsSection` 末尾的 `.buttonStyle(.bordered)`
    /// "在 GitHub 查看"独立 CTA 视觉太重、不协调；改为把跳转动作落到左上角项目 logo 上
    /// （`TrendingHeroAvatarButton`）—— logo 本来就指代仓库，点击它跳 GitHub 符合直觉，
    /// stats 行同时变得更干净（只剩 Stars / Forks / Language / +N 周期增长）。
    private func trendingHeader(_ repo: TrendingRepo) -> some View {
        HStack(alignment: .top, spacing: 16) {
            TrendingHeroAvatarButton(repo: repo)
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
            // 2026-06-02 dong4j 要求统一 hover 反馈：Stars 加 `.pressableHover()`，
            // 跟 Manage 详情页保持一致。详见 `Shared/Components/PressableHover.swift`。
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
            .focusEffectDisabled()
            .disabled(isStarringTrending)
            .pressableHover()
            .help("trending.star")

            // 2026-06-02 dong4j 新增：Forks 从静态 `StatItem` 改为可点击 Button，
            // 点击跳 GitHub fork 页（与 Manage 详情页同款逻辑：`/fork` 不是 `/forks`，
            // 跟 Manage `statsSection` 行为对齐，由用户决策不自作主张）。
            // URL 拼接：`TrendingRepo.url` 是 URL 类型，用 `appendingPathComponent`
            // 比字符串拼接更安全（自动处理末尾斜杠）。
            //
            // 未登录校验（dong4j 2026-06-02 追加）：fork 操作需要 GitHub 账号，
            // 未登录时不跳 GitHub 网页登录（用户会脱离 App 流程），而是调
            // `authSession.signIn()` 触发 App 内 Device Flow，登录完用户可以重新点击。
            Button {
                guard authSession.state.isAuthenticated else {
                    authSession.signIn()
                    return
                }
                NSWorkspace.shared.open(repo.url.appendingPathComponent("fork"))
            } label: {
                StatItem(label: "repo.forks", value: repo.forksCount, systemImage: "tuningfork", tint: .secondary)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pressableHover()
            .help("repo.forkAction")

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

            // 2026-06-02 dong4j 删除原 `Link "在 GitHub 查看"` 按钮（`.buttonStyle(.bordered)`
            // 在 plain 风格 stats 行里视觉权重过重，像独立 CTA 显得突兀）；跳转动作下沉到
            // `trendingHeader` 的左上角 logo（`TrendingHeroAvatarButton`）。

            Spacer()
        }
    }

    /// 执行 Trending repo 的 star 操作。
    ///
    /// 未登录处理（dong4j 2026-06-02 修复隐藏 bug）：
    /// 旧版赋值 `trendingStarError = "auth.needLogin"` 但该状态从未在任何 UI 被渲染
    /// （grep 全项目确认是 dead write），导致未登录用户点击 Star 静默无反应。
    /// 现在改为调 `authSession.signIn()` 触发 App 内 Device Flow 登录，
    /// 与 Trending Forks Button 的未登录处理保持一致。
    private func starTrending(repo: TrendingRepo) async {
        guard authSession.state.isAuthenticated else {
            authSession.signIn()
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

    // 头像 URL 与语言色：统一使用 Shared/Components/RepoRowComponents.swift
    // 中的 `RepoAvatarURL` 和 `LanguageColor`。后者从原来 7 种语言扩展到 30+ 种，
    // 详情页的语言色覆盖范围与列表行保持一致（顺手修：原 fallback 是纯 gray，
    // 现在与列表用同一个 30 色精简集，少数语言不再退化为灰色）。

    // MARK: - 子段

    private func header(_ repo: Repo) -> some View {
        HStack(alignment: .top, spacing: 16) {
            // 2026-06-02 dong4j 调整：logo 改为可点击跳 GitHub 主页，与 Trending
            // 详情页 `TrendingHeroAvatarButton` 保持一致的交互模式。
            RepoHeroAvatarButton(repo: repo)
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
            // 2026-06-02 dong4j 要求统一 hover 反馈：所有可点击的 stat（Stars /
            // Forks / Watchers）都加 `.pressableHover()`，让用户能感知"这是可点击的"。
            // 详见 `Shared/Components/PressableHover.swift`。
            Button {
                showUnstarConfirm = true
            } label: {
                StatItem(label: "repo.stars", value: repo.starsCount, systemImage: "star.fill", tint: .yellow)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pressableHover()
            .help("repo.unstar")

            Button {
                if let url = URL(string: "\(repo.htmlUrl)/fork") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                StatItem(label: "repo.forks", value: repo.forksCount, systemImage: "tuningfork", tint: .secondary)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pressableHover()
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
            Text(String(format: String(localized: "readme.cachedAtFormat"), cachedAt.formatted(.relative(presentation: .named))))
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
        .focusEffectDisabled()
        .fixedSize()
        // 2026-06-02 dong4j 要求统一 hover 反馈：跟 Stars / Forks 一样加
        // `.pressableHover()`，让用户感知 Watchers 数字是可点击的（点开下拉菜单）。
        .pressableHover()
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

// MARK: - Trending Hero Avatar Button

/// Trending repo 详情页左上角的项目 logo 按钮（hero 元素）。
///
/// 2026-06-02 由 dong4j 主导的 UX 调整：原 stats 行末尾有一个独立的
/// `Link "在 GitHub 查看"` 按钮（`.buttonStyle(.bordered)`），在 plain 风格 stats 行里
/// 视觉权重过重显得突兀；改为删除按钮 + 把跳转动作落到本组件（项目 logo）上。
/// logo 本来就指代仓库，点击它跳 GitHub 符合直觉。
///
/// 设计要点：
/// - **沿用 18:35 修好的"Button + NSWorkspace"模式**，不用 `Link(destination:)`——
///   后者外层 `.help()` toolTip 在 macOS 上传不进 Link 内部，hover 不弹 tooltip
///   （详见 `contributorAvatar` 内的注释）
/// - **hover 视觉反馈必要**：logo 包成 Button 后视觉上跟静态图无异，用户无法感知
///   "这是可点击的"。加 `.opacity(0.78)` 的轻微变暗（不加 scale 避免太花），
///   是 macOS 经典 image-button 模式（系统 Preview.app / Finder 同款）
/// - **尊重 accessibilityReduceMotion**：reduceMotion 用户不做 0.15s 缓动，避免动效
/// - `.help("repo.openOnGithub")` 直接复用原按钮的本地化文案，无需新增 i18n key
///
/// 没抽到 `Shared/Components/RemoteAvatar.swift`：本组件强绑 `TrendingRepo` 模型 +
/// 详情页 hero 语义，复用面窄；如未来 Manage detail 也需要"可点击 owner avatar"，
/// 再抽通用版（接受 `URL` + `tooltipKey` 参数）。
private struct TrendingHeroAvatarButton: View {
    let repo: TrendingRepo

    var body: some View {
        Button {
            NSWorkspace.shared.open(repo.url)
        } label: {
            RemoteAvatar(
                urlString: RepoAvatarURL.from(owner: repo.owner),
                size: 64
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pressableHover()
        .help("repo.openOnGithub")
    }
}

// MARK: - Repo Hero Avatar Button (Manage)

/// Manage repo 详情页左上角的项目 logo 按钮（hero 元素）。
///
/// 2026-06-02 dong4j 要求：Manage 详情页 logo 也要可点击跳 GitHub 主页，
/// 跟 Trending 详情页保持一致的交互模式。
///
/// 与 `TrendingHeroAvatarButton` 几乎一样，差异只是接收的 model 类型不同
/// （`Repo` vs `TrendingRepo`），URL 来源不同（`RepoExternalLinks.repo(repo)` vs
/// `repo.url`）。**没抽通用 `ClickableAvatar`**：两个 hero button 强绑各自的
/// model 类型，强行参数化反而要传 URL + tooltipKey 抹平差异；共享 hover 反馈
/// 已通过 `.pressableHover()` modifier 解决了重复，结构层面不需要再抽。
/// 如未来真出现第 3 个 hero avatar 用例再抽通用版（YAGNI）。
private struct RepoHeroAvatarButton: View {
    let repo: Repo

    var body: some View {
        Button {
            if let url = RepoExternalLinks.repo(repo) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            RemoteAvatar(
                urlString: RepoAvatarURL.from(owner: repo.owner),
                size: 64
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pressableHover()
        .help("repo.openOnGithub")
    }
}
