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
    /// HOM-68：README 翻译 VM（由 HomeView 持有 + environment 透传）。
    @Environment(ReadmeTranslationViewModel.self) private var translationVM
    /// 翻译目标语言 / 语言菜单 / 错误提示文案都依赖 AppSettings。
    @Environment(AppSettings.self) private var settings
    // W4 B1：取消 star 需要的依赖
    @Environment(AppDependencies.self) private var dependencies
    @Environment(AuthSession.self) private var authSession
    // Trending 页面 ViewModel（用于更新 stars 计数）
    @Environment(\.trendingViewModel) private var trendingViewModel
    /// 系统级"减少动效"开关，开启时详情页切换退化为仅 opacity 淡入（不再上滑）。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // R-01 §3.2.3 决策：unstar 即点即生效，不再有 confirm alert / unstarError 弹窗。
    // 失败由 StarActionService 内部记日志，UI 仅靠 hero ⭐ chip 抖动 + 短暂红色提示
    // （chip 抖动效果在 RepoMetadataHeaderView 内未来扩展；R-01 阶段先打日志即可）。

    /// Trending repo 一键 star 的 UI 状态
    @State private var isStarringTrending: Bool = false
    @State private var trendingStarError: String?

    /// README 向下滚动时折叠顶部信息面板的连续进度。
    ///
    /// 旧实现是 32pt / 8pt 两个阈值切 Bool，数据写入少，但视觉上会像“突然收起”。
    /// 这里改为 0...1 进度：滚动 8pt 后开始跟手压缩，72pt 左右完全收起。
    /// SwiftUI 只重排这一块顶部面板和 README 宿主高度，换取更顺滑的滚动反馈。
    @State private var metadataPanelCollapseProgress: CGFloat = 0

    /// 顶部信息面板的自然高度。
    ///
    /// 折叠动画需要从「真实高度」连续压到 0，而不是把 view 直接从树里移除。
    /// 这个高度由 `CollapsibleRepoMetadataPanel` 内部测量后回填。
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
        // 用 ZStack(alignment: .topLeading) 包裹三分支，而不是 Group。
        //
        // 关键差别（21:44 排查后修正）：
        // - Group 是 transparent container，不在 view tree 创建节点；
        //   `.transition` 落在各分支 view 上时，跨分支切换缺少"容器宿主"
        //   把 old view 的 removal 和 new view 的 insertion 同帧协调起来，
        //   实际表现是 "旧 view 直接被替换、新 view 直接出现"，几乎看不到动画。
        // - ZStack 是真正的 layout container；切换时 SwiftUI 会先把 new view
        //   叠加进 ZStack（触发 insertion transition），再把 old view 移除
        //   （触发 removal transition），两份内容在同一帧里完成进出，
        //   `.transition` 才能稳定触发。
        // alignment 选 `.topLeading` 是为了和 detail 内容固有的"从左上展开"
        // 布局一致（VStack(alignment: .leading) + 顶对齐），避免切换瞬间
        // 内容在 Z 轴上突然居中再回到左上。
        ZStack(alignment: .topLeading) {
            if let repo = viewModel.selectedRepo {
                // R-01 §3.2.3：Manage 详情迁移到 RepoDetailScaffold + ManageDetailContent。
                // - 删除原 `showUnstarConfirm` / `isUnstarring` / `unstarError` 三个 @State + 对应 alert
                //   （dong4j Q5-A 决策：unstar 即点即生效，无 confirm；失败时 chip 抖动 + 红色 ~600ms，不弹 toast）
                // - star/unstar 调用统一走 `dependencies.starActionService.unstar(repo:)`
                //   （由 StarringSubsystem 单点维护 registry / DB / 远端三方一致性）
                RepoDetailScaffold(
                    repo: repo,
                    viewData: RepoDetailViewData(
                        hero: RepoDetailHero(repo: repo),
                        trailingActions: [.share, .ai],
                        translation: ReadmeTranslationContext(fullName: repo.fullName),
                        backendHint: nil
                    ),
                    onStarTapped: {
                        Task {
                            do {
                                try await dependencies.starActionService.unstar(repo: repo)
                            } catch {
                                AppLog.sync.error("manage detail unstar failed: \(error.localizedDescription, privacy: .public)")
                            }
                        }
                    }
                ) { onScrollOffset in
                    ManageDetailContent(repo: repo, onScrollOffset: onScrollOffset)
                }
                .transition(detailContentTransition)
            } else if let trending = selectedTrendingRepo {
                // Trending repo 详情页（无本地数据，只显示 README）
                VStack(alignment: .leading, spacing: 0) {
                    collapsibleMetadataContainer {
                        trendingMetadataHeader(trending)
                    }
                    trendingReadmeSection(trending)
                }
                .id(trending.id)                            // 同 Manage 分支：强制 view 重建触发 transition
                .transition(detailContentTransition)
                .navigationTitle(trending.name)
                .navigationSubtitle(trending.owner)
                .onChange(of: trending.id) { _, _ in
                    // 切换 Trending repo 时把折叠状态重置回展开，与 Manage 侧
                    // `.onChange(of: repo.id)` 行为完全对齐，避免上一条 repo 的
                    // 折叠态污染下一条的首次展示。
                    withAnimation(metadataPanelAnimation) {
                        metadataPanelCollapseProgress = 0
                    }
                }
            } else {
                emptyState
                    .id("empty")
                    .transition(detailContentTransition)
            }
        }
        // 监听"当前显示的 detail 内容标识"变化，触发 .transition 动效。
        //
        // 严格只看 `detailContentID`（基于 selectedRepo.id / trending.id / "empty" 计算），
        // 避免让 .animation 把详情页内部的状态变化（编辑标签、输入笔记、折叠 hero
        // 等）也吃进 implicit 动画，那会引起意外的全局 fade/move 副作用。
        //
        // duration 0.4s（21:44 从 0.28s 调大）：
        // README WebView 启动有 100~200ms 白屏 → 加载 HTML → 渲染的延迟。
        // 之前 0.28s 太快，transition 在 WebView 还没出内容时就结束了，肉眼几乎
        // 看不见"轻轻落下"。0.4s 是经验值，比 README 首帧渲染稍慢一点，让用户
        // 能明确感受到内容从上方滑入。
        .animation(.easeOut(duration: 0.4), value: detailContentID)
    }

    /// 当前 detail 内容的标识符，用作 `.animation(_:value:)` 的触发 key。
    ///
    /// 三种状态：Manage repo（id 形如 "12345"）/ Trending repo（id 形如 "owner/name"）
    /// / 空态（"empty"）。任意一种切换到另一种 → 触发 view transition；同状态内
    /// 重新选同一条 → id 不变 → 无动画。
    private var detailContentID: String {
        if let id = viewModel.selectedRepo?.id { return "manage-\(id)" }
        if let id = selectedTrendingRepo?.id { return "trending-\(id)" }
        return "empty"
    }

    /// 详情页内容切换时的 view transition。
    ///
    /// **非对称设计**（重要）：
    /// - insertion 新内容：opacity 0→1 + offset y:8→0 滑入，让用户感觉"新内容轻轻落下"。
    /// - removal 旧内容：仅 opacity 1→0 直接淡出，**不滑动**——否则新旧两份内容同时
    ///   在 view tree 里漂移，视觉上很乱，特别是 README WebView 切换时容易显得抖动。
    ///
    /// reduceMotion 兜底：完全去掉 offset，只保留 opacity 淡入淡出，避免前庭不适。
    ///
    /// 14pt 的 offset（21:44 从 8pt 调大）：经验值，让"轻轻落下"明显可感知；
    /// 8pt 在 macOS 大屏 + WebView 渲染延迟下太微弱，肉眼几乎看不出来。
    /// 再大（>20pt）就像"页面跳"，14pt 是平衡点。
    private var detailContentTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 14)),
            removal: .opacity
        )
    }

    // R-01 §3.2.3：performUnstar / errorAlertBinding 已迁移到 StarActionService 单点维护
    // （RepoDetailView 不再持有 unstar 业务逻辑）。

    /// 顶部信息面板的通用折叠容器（Trending 分支用，Manage 已迁移到 RepoDetailScaffold）。
    ///
    /// 为什么不继续用 `if collapseProgress < 1 { ... }`：
    /// 直接插拔 view 会让整个 WKWebView 在同一帧拿到新高度，视觉上像"跳变"；
    /// 这里让面板始终留在 view tree 中，只把外层 frame 从自然高度动画到 0，
    /// 同时给内容做轻微上移和淡出，WebView 的高度变化会更连续。
    ///
    /// 抽成 helper 的理由：折叠逻辑（hide / height / preference / animation）跟
    /// 内容（Manage 的 `metadataHeader` 或 Trending 的 `trendingMetadataHeader`）
    /// 完全解耦，两边共用一个 helper 避免 25 行 view modifier chain 复制粘贴漂移
    /// （前车之鉴 06-02 00:48 Chip 抽公共组件）。
    /// 共享状态来自外层的 `metadataPanelCollapseProgress` / `metadataPanelHeight` `@State`，
    /// 上报通道由 `CollapsibleRepoMetadataPanel` 内部统一处理，所以 Manage 切 Trending
    /// （或反之）时折叠状态会被 `body` 里的 `.onChange(of: id)` 重置一次。
    @ViewBuilder
    private func collapsibleMetadataContainer<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        CollapsibleRepoMetadataPanel(
            collapseProgress: $metadataPanelCollapseProgress,
            panelHeight: $metadataPanelHeight
        ) {
            content()
        }
    }

    // R-01 §3.2.3：metadataHeader / metadataPanel 已废弃——Manage 走 RepoDetailScaffold 内置 hero。
    // Trending / Activity 仍在用 collapsibleMetadataContainer 等下方 helper（待后续 step 替换）。

    /// 详情页元信息面板的强调色（取色规则与列表 `RepoRowSurface.accentColor` 完全一致）。
    ///
    /// 选用语言色而不是"头像取色"的理由：① 零依赖，无需异步算色 / 缓存 / 边界情况兜底
    /// （透明 PNG / 单色 logo）；② 与列表视觉规则统一，用户认知不割裂。
    /// 无语言时回退 `.accentColor`（系统蓝），与列表逻辑保持一致。
    ///
    /// 接收 `String?` 而非具体 model（`Repo` / `TrendingRepo`），让 Manage 详情页
    /// 和 Trending 详情页能共用同一个 helper 与同一段渐变实现，避免两份复制粘贴漂移。
    private func metadataAccentColor(for language: String?) -> Color {
        if let language, !language.isEmpty {
            return LanguageColor.color(for: language)
        }
        return .accentColor
    }

    /// 详情页 hero 区"语言色 → 透明"线性渐变背景。
    ///
    /// 复用于 Manage `metadataHeader` 与 Trending `trendingMetadataPanel` 两处，
    /// 渐变形态、不透明度、命中测试规则均一致——以"详情页 hero 区有统一视觉语言"
    /// 为目标，不要为某一边单独调参。
    /// - opacity 0.18 顶部 → 0.0 底部，与列表 row 选中态强度对齐
    /// - `.allowsHitTesting(false)` 不挡上层 Button / Link 点击
    @ViewBuilder
    private func metadataGradientBackground(language: String?) -> some View {
        let tint = metadataAccentColor(for: language)
        LinearGradient(
            colors: [tint.opacity(0.18), tint.opacity(0.0)],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
    }

    /// README 区域。占据剩余高度，由 WebView 自己处理滚动。
    ///
    // R-01 §3.2.3：readmeSection (Manage) 已迁移到 ManageDetailContent。
    // Trending 分支仍用下方 trendingReadmeSection（待 Step 6.2 替换）。

    /// WebView 内部滚动位置 → 顶部信息面板折叠进度。
    ///
    /// 旧版只在 32pt / 8pt 两个阈值切换 Bool，布局更新少但手感偏硬。
    /// 现在用 8pt 起步、64pt 行程的连续进度：
    /// - 0...8pt：保留完整上下文，过滤触控板顶部轻微抖动；
    /// - 8...72pt：跟随滚动连续压缩卡片；
    /// - 72pt 以后：完全收起，README 获得最大阅读空间。
    private func updateMetadataPanelVisibility(offsetY: CGFloat) {
        let progress = Self.metadataCollapseProgress(for: offsetY)
        guard abs(progress - metadataPanelCollapseProgress) > 0.01 else { return }
        metadataPanelCollapseProgress = progress
    }

    /// 将 scroll offset 映射为顶部元信息面板的折叠进度。
    ///
    /// 抽成静态 helper 是为了让 Manage / Trending / Activity 保持同一参数口径；
    /// 后续如果 dong4j 继续调手感，只需要改这里这一处。
    static func metadataCollapseProgress(for offsetY: CGFloat) -> CGFloat {
        let normalizedOffset = max(offsetY, 0)
        let collapseStart: CGFloat = 8
        let collapseDistance: CGFloat = 64
        return min(max((normalizedOffset - collapseStart) / collapseDistance, 0), 1)
    }

    // MARK: - Trending Repo 支持

    /// Trending repo 顶部信息内容（命名对齐 Manage 的 `metadataHeader`）。
    ///
    /// 折叠机制（向下滚 README 自动收起、回顶展开）走与 Manage 完全相同的链路：
    /// 由外层 `collapsibleMetadataContainer` 接收 content、`trendingReadmeSection`
    /// 通过 `onScrollOffsetChange: updateMetadataPanelVisibility` 上报 scrollY，
    /// hysteresis 阈值（32pt 折叠 / 8pt 展开）也共用同一函数；本函数只关心内容渲染。
    ///
    /// 背景渐变也走共享 `metadataGradientBackground(language:)`，保持详情页 hero 区
    /// 统一视觉语言。`TrendingRepo.language` 是 `String?`，与 `Repo.language`
    /// 类型完全一致，直接复用 helper 无需为 Trending 单独写一份。
    private func trendingMetadataHeader(_ repo: TrendingRepo) -> some View {
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
        .background(alignment: .top) {
            metadataGradientBackground(language: repo.language)
        }
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
                // ZStack 而非 if/else：
                // 1) 消除 NSProgressIndicator 警告
                //    `<AppKitProgressView ...> has an maximum length (32.403423) that doesn't satisfy min (32.403423) <= max (32.403423).`
                //    旧写法 `ProgressView().scaleEffect(0.6)` 中 scaleEffect 只在渲染层缩放、不改 layout intrinsic
                //    size（仍是 ~32pt），父 stats `HStack(spacing: 24)` 又按相邻 StatItem 高度紧逼，
                //    导致 NSProgressIndicator 内部 min==max==32.403423 浮点等值 → NSLog 警告。
                //    显式给 ProgressView `.frame(width:height:)` 后 layout 不再被外部紧逼，警告消失。
                //    （项目内 RepoShareButton / ReadmeTranslationFooterButton 已是这个 pattern。）
                // 2) 消除 button 高度抖动：StatItem 始终占位决定 button 自然高度，
                //    star 切换时 ProgressView 只在原位淡入，stats 行宽不再跳变。
                ZStack {
                    StatItem(label: "repo.stars", value: repo.starsCount, systemImage: "star.fill", tint: .yellow)
                        .opacity(isStarringTrending ? 0 : 1)
                    if isStarringTrending {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 16, height: 16)
                    }
                }
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(isStarringTrending)
            .pressableHover()
            .help("trending.star")

            // 2026-06-02 dong4j 新增：Forks 从静态 `StatItem` 改为可点击 Button，
            // 点击跳 GitHub fork 页（与 Manage 详情页同款逻辑：`/fork` 不是 `/forks`，
            // 跟 Manage stats 行为对齐，由用户决策不自作主张）。
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
    ///
    /// R-01 v1.2（2026-06-10）：star 操作走 `StarActionService` 单点。
    /// 服务内部完成 GitHub `PUT /user/starred/...` + `GET /repos/{o}/{r}` 拉最新
    /// 字段 + DB upsert + StarredRegistry add。Registry 是 `@Observable`，所有列表
    /// 卡片（含 trending row 的 ✓ 标记）会自动响应；不再需要手动 `incrementStarsCount`
    /// 维护 trending 列表的本地 stars 计数 +1（trending 列表数字下次刷新自然同步）。
    private func starTrending(repo: TrendingRepo) async {
        guard authSession.state.isAuthenticated else {
            authSession.signIn()
            return
        }

        isStarringTrending = true
        trendingStarError = nil

        do {
            _ = try await dependencies.starActionService.star(owner: repo.owner, repo: repo.name)
            // StarActionService 内部已 add 进 StarredRegistry；HomeView 通过注入的
            // HomeRefreshing 钩子触发 `reloadItems`，trending 列表 row 通过 registry
            // 联动出现 ✓ 标记。本路径不需要再手动 reloadItems。
        } catch {
            trendingStarError = "repo.star.failed"
        }

        isStarringTrending = false
    }

    /// Trending repo README 区域。
    ///
    /// `onScrollOffsetChange` 接通共享的 `updateMetadataPanelVisibility`：
    /// 与 Manage `readmeSection` 走同一条 hysteresis 链路（32pt 折叠 / 8pt 展开），
    /// 让 Trending 详情页也具备"向下滚 README 自动收起 hero、回顶展开"的体验。
    private func trendingReadmeSection(_ repo: TrendingRepo) -> some View {
        ReadmeStateView(
            state: readmeVM.state,
            // 拼接 blob/HEAD：同上，Trending 的 repo.url 是仓库根 URL，
            // 补上 blob/HEAD 使相对链接正确解析。
            baseURL: URL(string: "\(repo.url.absoluteString)/blob/HEAD"),
            owner: repo.owner,
            repo: repo.name,
            onScrollOffsetChange: updateMetadataPanelVisibility,
            // HOM-68：Trending 没有本地 Repo.id，不接翻译入口；传 nil 让 footer
            // 跳过翻译控件，保持 trending 侧的简洁。
            translationControl: nil
        ) {
            // Trending README 刷新：直接调用 loadTrending
            readmeVM.loadTrending(owner: repo.owner, repo: repo.name, isLoggedIn: authSession.state.isAuthenticated)
        } onLogin: {
            authSession.signIn()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Repo 元信息面板已抽到 `RepoMetadataHeaderView.swift`，Manage / Activity 共用。

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

// MARK: - README 状态视图

/// 把 ReadmeViewModel.LoadState 翻译为视觉。
///
/// 拆成独立 View 的好处：
/// - 状态切换造成的 view tree 重建只影响这一块，元信息区不受波及
/// - 重试按钮的回调通过闭包传入，保持本组件无副作用
struct ReadmeStateView: View {

    @Environment(ReadmeViewModel.self) private var readmeVM

    let state: ReadmeViewModel.LoadState
    let baseURL: URL?
    /// 仓库 owner / name —— 透传给 ReadmeWebView 用于图片相对路径重写
    let owner: String
    let repo: String
    let onScrollOffsetChange: (CGFloat) -> Void
    /// HOM-68：可选的 README 翻译控件描述。nil 时不渲染翻译入口
    /// （Trending 详情页不接翻译，传 nil；Manage 详情页传具体值）。
    let translationControl: ReadmeTranslationControl?
    let onRetry: () -> Void
    /// 未登录用户点击"登录"按钮时的回调
    let onLogin: () -> Void

    init(
        state: ReadmeViewModel.LoadState,
        baseURL: URL?,
        owner: String,
        repo: String,
        onScrollOffsetChange: @escaping (CGFloat) -> Void,
        translationControl: ReadmeTranslationControl? = nil,
        onRetry: @escaping () -> Void,
        onLogin: @escaping () -> Void
    ) {
        self.state = state
        self.baseURL = baseURL
        self.owner = owner
        self.repo = repo
        self.onScrollOffsetChange = onScrollOffsetChange
        self.translationControl = translationControl
        self.onRetry = onRetry
        self.onLogin = onLogin
    }

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
                // HOM-68：当翻译已就绪且用户选择展示译文时，喂给 WebView 的就是
                // `translatedHtml`。源 `html` 仍由翻译 VM 之外的逻辑保留——切回
                // 原文不需要重新拉网络，只是 displayMode 切回 .showingOriginal。
                let renderedHtml = translationControl?.activeHtml(originalHtml: html) ?? html
                ReadmeWebView(
                    htmlFragment: renderedHtml,
                    baseURL: baseURL,
                    owner: owner,
                    repo: repo,
                    onScrollOffsetChange: onScrollOffsetChange
                )
                cacheFooter(cachedAt: cachedAt, sourceHtml: html)
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
    ///
    /// 右下角刷新按钮使用共享 `SyncIconButton`（与 Trending toolbar 同款图标 + 旋转动画）。
    /// 2026-06-02 替换前用的是 `arrow.clockwise` + `.symbolEffect(.variableColor.iterative)`，
    /// 视觉是颜色脉动而非旋转，与 dong4j 期望的"刷新中应该转圈"不符；统一为 `SyncIconButton` 后，
    /// manage / trending 两个详情页（共用 ReadmeStateView）+ Trending toolbar 三处行为完全一致。
    ///
    /// HOM-68：右下角追加翻译入口（仅 Manage 详情页传入 translationControl 时显示）。
    /// 把 `sourceHtml` 透给翻译按钮——按钮调 LLM 时需要把当前源 HTML 作为输入。
    private func cacheFooter(cachedAt: Date, sourceHtml: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "clock")
                .font(.caption2)
            Text(String(format: String(localized: "readme.cachedAtFormat"), cachedAt.formatted(.relative(presentation: .named))))
                .font(.caption2)
            Spacer()
            if let control = translationControl {
                ReadmeTranslationFooterButton(
                    control: control,
                    sourceHtml: sourceHtml
                )
                Divider().frame(height: 14)
            }
            SyncIconButton(
                isRefreshing: readmeVM.isRefreshing,
                disabled: readmeVM.isRefreshing,
                font: .caption2,
                frameSize: 18,
                tooltip: String(localized: "readme.refresh"),
                action: onRetry
            )
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 6)
        .foregroundStyle(.secondary)
        .background(.bar)
    }
}

// MARK: - HOM-68 翻译控件

/// 详情页注入 `ReadmeStateView` 的翻译控件描述（值类型 + closure 传递必要依赖）。
///
/// 不让 ReadmeStateView 直接依赖 `ReadmeTranslationViewModel` / `AppSettings` 的好处：
/// - ReadmeStateView 是个无副作用的状态视图，多个详情页（Manage / Trending）都在共用，
///   Trending 路径暂不接翻译；用可选值表达"是否需要翻译入口"比把环境注入条件化更直接；
/// - 单元测试 / Preview 可以传 nil 跳过翻译控件，不需要 mock 翻译 VM。
@MainActor
struct ReadmeTranslationControl {
    let repo: Repo
    let translationVM: ReadmeTranslationViewModel
    let settings: AppSettings

    /// 当前 WebView 应渲染的 HTML：用户选择展示译文时返回译文，否则 nil（外层使用原文）。
    ///
    /// 这里访问的 `translationVM.displayMode` 是 `@MainActor` 隔离的 `@Observable` 状态，
    /// 因此整个 control 必须标 `@MainActor`，否则 SwiftUI 在重新渲染时会从非隔离上下文调用，
    /// Swift 6 编译期就会报错。控件本身只在 View body 中读取，所以这条约束不会增加运行成本。
    func activeHtml(originalHtml: String) -> String? {
        if case .showingTranslation(let html, _, _) = translationVM.displayMode {
            return html
        }
        return nil
    }
}

/// README cacheFooter 区域的翻译入口按钮。
///
/// 设计：
/// - 一次点击 = toggle：未显示译文时点击触发翻译（命中缓存即时上屏，否则调 LLM），
///   已显示译文时点击切回原文，符合 dong4j Coding Style 里"最少操作即可完成任务"。
/// - 旁边的下拉菜单负责"选择目标语言"+"重新翻译"+"清除当前译文"，避免在 footer 里
///   堆出多个按钮抢空间。
/// - 翻译进行中切换为 ProgressView + 禁用，复用与同列其它按钮（SyncIconButton）一致的视觉。
/// - 错误条放在 footer 上方独立一行，避免压缩 footer 宽度；用户可主动 dismiss。
struct ReadmeTranslationFooterButton: View {

    let control: ReadmeTranslationControl
    let sourceHtml: String

    private var translationVM: ReadmeTranslationViewModel { control.translationVM }
    private var settings: AppSettings { control.settings }

    /// 判断当前是否展示译文，用于按钮文字 / icon 切换。
    private var isShowingTranslation: Bool {
        if case .showingTranslation = translationVM.displayMode { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 4) {
            if let message = translationVM.errorMessage {
                Button {
                    translationVM.dismissError()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(verbatim: message)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(.caption2)
                    .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("readme.translate.error.dismiss")
            }

            Button {
                translationVM.toggleTranslation(
                    repo: control.repo,
                    sourceHtml: sourceHtml,
                    targetLanguage: settings.readmeTranslationLanguage
                )
            } label: {
                HStack(spacing: 4) {
                    if translationVM.isTranslating {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: isShowingTranslation
                              ? "character.bubble.fill"
                              : "character.bubble")
                            .font(.caption2)
                    }
                    Text(buttonTitle)
                        .font(.caption2)
                }
                .foregroundStyle(isShowingTranslation ? .blue : .secondary)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(translationVM.isTranslating || sourceHtml.isEmpty)
            .help(buttonTooltip)

            languageMenu
        }
    }

    /// 主按钮文案：未翻译 → "翻译"；已翻译 → "原文"。
    /// 缓存与当前源不匹配时给 "翻译" 一个 stale 标记，引导用户主动 regenerate。
    private var buttonTitle: LocalizedStringKey {
        if isShowingTranslation { return "readme.translate.showOriginal" }
        if translationVM.cacheIsStale { return "readme.translate.staleAction" }
        return "readme.translate.action"
    }

    private var buttonTooltip: LocalizedStringKey {
        if isShowingTranslation { return "readme.translate.tooltip.showOriginal" }
        return "readme.translate.tooltip.translate"
    }

    /// 右侧 chevron 下拉菜单：切换目标语言、重新翻译。
    /// 不放更多按钮：footer 已足够小，再加按钮会和右边的刷新图标抢空间。
    private var languageMenu: some View {
        Menu {
            Picker(selection: Binding(
                get: { settings.readmeTranslationLanguage },
                set: { settings.readmeTranslationLanguage = $0 }
            )) {
                ForEach(ReadmeTranslationLanguage.allCases) { lang in
                    Text(verbatim: lang.displayName).tag(lang)
                }
            } label: {
                Text("readme.translate.menu.language")
            }
            .pickerStyle(.inline)

            Divider()

            Button {
                translationVM.regenerate(
                    repo: control.repo,
                    sourceHtml: sourceHtml,
                    targetLanguage: settings.readmeTranslationLanguage
                )
            } label: {
                Label("readme.translate.menu.regenerate", systemImage: "arrow.clockwise")
            }
            .disabled(translationVM.isTranslating || sourceHtml.isEmpty)
        } label: {
            Image(systemName: "chevron.down")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 16)
        .focusEffectDisabled()
        .help("readme.translate.menu.tooltip")
    }
}

// MARK: - 小组件

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
            // 404 在 GitHub Watch API 是预期行为：表示用户对这个 repo 没有显式
            // 订阅记录、保持默认 Participating 级别（不是"repo 不存在"）。
            // 完整语义见 `StarsAPI.getSubscription` 的 doc comment。
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
