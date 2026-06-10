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
    // W4 B1：取消 star 需要的依赖
    @Environment(AppDependencies.self) private var dependencies
    /// 系统级"减少动效"开关，开启时详情页切换退化为仅 opacity 淡入（不再上滑）。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// v1.4 修订 (2026-06-10)：trailingActions(.share/.ai) 加 isAuthenticated 守卫的依赖。
    /// Manage 场景业务上必须登录才能看到 repo 列表（HomeViewModel 从本地 starred_repos
    /// 拉数据,登出会清 token + StarredRegistry,但本地 starred_repos 表不清,理论上多账号
    /// 切换时仍可能短暂看到已登出用户的数据）→ 加防御性守卫,与 trending/weekly 全场景一致。
    @Environment(AuthSession.self) private var authSession

    // R-01 §3.2.3 决策：unstar 即点即生效，不再有 confirm alert / unstarError 弹窗。
    // 失败由 StarActionService 内部记日志，UI 仅靠 hero ⭐ chip 抖动 + 短暂红色提示
    // （chip 抖动效果在 RepoMetadataHeaderView 内未来扩展；R-01 阶段先打日志即可）。
    //
    // R-01 v1.2 Phase B3（2026-06-10）：trending 详情页全部交给 `TrendingScaffoldShell`
    // 自治，本 view 不再持有 `isStarringTrending` / `trendingStarError` 等任何 trending
    // 相关状态；折叠面板状态由 `RepoDetailScaffold` 内部持有，本 view 也不再维护。

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
                        // v1.4 修订 (2026-06-10)：未登录时不展示分享/AI（语义上「分享我的
                        // 收藏」「AI 摘要」都是登录后的功能）。manage 场景理论必登录,
                        // 加守卫纯防御 + 与 trending/weekly 一致。
                        trailingActions: authSession.state.isAuthenticated ? [.share, .ai] : [],
                        translation: ReadmeTranslationContext(fullName: repo.fullName),
                        backendHint: nil
                    ),
                    onStarTapped: {
                        // §3.2.3 状态机：throws 让 StarStatChipButton 抖动 + 短暂红色（不弹 alert）
                        try await dependencies.starActionService.unstar(repo: repo)
                    },
                    onRefresh: {
                        // §3.2.9：右下浮动刷新按钮触发 → 强制刷当前 repo 视图数据
                        // （重拉缓存 repo + tags + notes + release 计数等）
                        await viewModel.reloadItems(forceRefresh: true)
                    }
                ) { onScrollOffset in
                    ManageDetailContent(repo: repo, onScrollOffset: onScrollOffset)
                }
                .transition(detailContentTransition)
            } else if let trending = selectedTrendingRepo {
                // R-01 §3.2.3 Phase B3（2026-06-10）：trending 详情切到 RepoDetailScaffold
                // + TrendingDetailContent 共用骨架。`TrendingScaffoldShell` 内部维护
                // `displayRepo` / `isLocalHit` 状态机，先查本地（已 star 拿真值，三段
                // 跟着渲染），未命中退化到 ephemeral Repo（id=0，三段隐藏）。
                TrendingScaffoldShell(trending: trending)
                    .id(trending.id)
                    .transition(detailContentTransition)
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

    // R-01 §3.2.3 Phase B3（2026-06-10）：本 view 的 trending 分支全部交给
    // `TrendingScaffoldShell`（同 module 平级文件）+ `RepoDetailScaffold` +
    // `TrendingDetailContent` + `TrendingContributorsSection` 共用骨架；
    // 历史 helper（collapsibleMetadataContainer / metadataAccentColor /
    // metadataGradientBackground / updateMetadataPanelVisibility / trendingHeader /
    // trendingStatsSection / trendingContributorsSection / contributorAvatar /
    // trendingReadmeSection / starTrending / TrendingHeroAvatarButton）已全部删除。

    // R-01 §3.2.3 Phase B5（2026-06-10）：原 `metadataCollapseProgress(for:)` 静态
    // helper 已删除——Manage / Trending / Weekly / Activity-repo-backed 全部走
    // `RepoDetailScaffold.metadataCollapseProgress(for:)`，单点维护折叠手感。

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

// R-01 §3.2.3 Phase B3（2026-06-10）：原 `TrendingHeroAvatarButton` 已删除。
// Trending 详情页左上角项目 logo 改由 `RepoMetadataHeaderView` 内置 hero 头像承接，
// 与 Manage / Weekly / Activity 视觉统一；外链跳转入口由 hero「在 GitHub 查看」chip 提供。
