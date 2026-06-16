//
//  RepoDetailScaffold.swift
//  Starcat
//
//  R-01「三场景共用架构」详情页通用骨架（Hero header + trailing actions + body slot）。
//
//  ────────────────────────────────────────────────────────────────────────────
//  设计意图（详细设计 §3.2）
//  ────────────────────────────────────────────────────────────────────────────
//
//  各场景详情页（Manage / Trending / Weekly / Activity-repo-backed）只需提供：
//    1. 当前 `Repo` 实例（驱动 Hero header 视觉 + ⭐/☆ chip）
//    2. `RepoDetailViewData`（trailingActions 列表 + 翻译 context + backendHint）
//    3. `onStarTapped` 闭包（Hero stats 行 ⭐/☆ chip 触发 star/unstar）
//    4. `body` view-builder（ContentView 插槽，自由渲染 ScrollView + sections + README）
//
//  Scaffold 负责：
//    - Hero header（复用 `RepoMetadataHeaderView`,渲染元信息 + ⭐/☆ chip + trailing actions）
//    - 折叠面板（复用 `CollapsibleRepoMetadataPanel`）
//    - heroExtension slot（场景特化的 hero 后内容,如 Trending Contributors）
//    - **RepoLocalSections（v1.5 修订, 2026-06-10）**：Tags / Notes (含阅读状态) /
//      Releases 订阅三段内置渲染在 metadataPanel 内,跟随 hero **整段折叠**;
//      4 场景同构（Manage / Trending / Weekly / Activity-repo-backed 都是同样
//      `RepoLocalSections(repo: repo)` 调用）,内置消除 4 场景重复 + 解决「滚动
//      README 时三段挤压阅读区」bug。详见下方 v1.5 修订段。
//    - trailingActions 渲染（按 `RepoDetailAction` enum 派发）
//
//  Scaffold **不**负责：
//    - body 内部布局（ContentView 自己持有 ScrollView + Readme）
//    - star/unstar 业务逻辑（由 onStarTapped 上层处理）
//    - 翻译浮动按钮 / 刷新浮动按钮（这两个是 ReadmeStateView 的内嵌 cacheFooter,
//      ContentView 渲染 ReadmeStateView 时已经包含;Scaffold 不重复渲染）
//
//  ────────────────────────────────────────────────────────────────────────────
//  v2.1 修订（2026-06-11, dong4j bug 反馈「右下角多了一个一模一样的刷新图标」）：
//  ────────────────────────────────────────────────────────────────────────────
//
//  撤销 P0-E（2026-06-10）的 §3.2.9「右下角浮动刷新按钮」设计 —— 删除 `onRefresh:`
//  入参 + `.overlay(alignment: .bottomTrailing)` 浮动 SyncIconButton + 内部 isRefreshing
//  状态机。回归本文件头一开始就声明的设计原则:「翻译浮动按钮 / 刷新浮动按钮 ... Scaffold
//  不重复渲染」。
//
//  当时（P0-E）加这个浮动按钮的目的是给 Manage 详情提供「整页刷新」入口，但同位置
//  `ReadmeStateView.cacheFooter` **始终**也渲染一个同款 `SyncIconButton`(只刷 README) →
//  视觉上同位置叠两个一样的图标,用户分不清职责差异,反馈为 bug。
//
//  修复方向(dong4j 选 A:合并)：cacheFooter 内那个按钮在 Manage 场景**同时**刷 README
//  + reloadItems(整页 repo 视图数据)。Manage 路径下已通过 `ManageDetailContent` 注入
//  `HomeViewModel` + onRetry 闭包内并发触发 `readmeVM.reload(...)` + `Task { await
//  viewModel.reloadItems(forceRefresh: true) }` 实现(详见 `ManageDetailContent.swift`
//  文件头 v2.1 修订段)。Trending / Activity / Weekly 三场景的 cacheFooter onRetry 不变,
//  仍只刷 README,符合各自语义。
//
//  关键约束:
//  - i18n key `repo.detail.refresh`(P0-E 引入,en「Refresh details」/zh-Hans「刷新详情」)
//    在本次修订中一并删除,无残留引用。
//  - cacheFooter 按钮的 tooltip 仍是 `readme.refresh`(无文案修改)——避免影响其他 3 个
//    共用 `ReadmeStateView` 的场景的语义;Manage 下「事实上扩展到整页刷新」是合理的,
//    用户在详情页点刷新自然期望全刷。
//  - 后续若再有「需要在详情页提供独立刷新入口」的诉求,先优先看 cacheFooter onRetry 闭包
//    能否承担,而不是再加 Scaffold overlay。
//
//  ────────────────────────────────────────────────────────────────────────────
//  v1.5 修订（2026-06-10, dong4j bug 反馈）：RepoLocalSections 迁回折叠面板内
//  ────────────────────────────────────────────────────────────────────────────
//
//  v1.2 P0（2026-06-10 上午）把 RepoLocalSections 三段从 hero 下沉到 ContentView,
//  理由是「各场景的 section 集合不同,hero 不该知道有几段要展开」。但实际落地后
//  4 场景的 ContentView body 里 RepoLocalSections 调用 100% 一致（`RepoLocalSections(repo: repo)`
//  无任何场景特化参数）—— 抽象层"灵活性"在事实上没有被使用。
//
//  v1.5 上午用户反馈：滚动 README 时只有 hero 一段折叠,中间三段仍占据屏幕中部
//  挤压 README 阅读区。根因 = 三段在 ContentView body 里、不在折叠面板（CollapsibleRepoMetadataPanel）
//  内 → scroll progress 驱不动它。
//
//  权衡：方案 A（Scaffold 内置 RepoLocalSections,跟随折叠）vs 方案 B（slot 化,
//  调用方传 RepoLocalSections）vs 方案 C（透传 progress 自己衰减）。dong4j 拍板
//  方案 A —— 折叠一致性 > 抽象灵活性,4 场景同构事实推翻了原 v1.2 P0「Scaffold
//  不该知道有几段」原则。
//
//  v1.5 实现：本组件直接挂 `RepoLocalSections(repo: repo)` 在 metadataPanel 内
//  hero + heroExtension 之后,跟随 `CollapsibleRepoMetadataPanel` 的 progress
//  自然折叠（panel 按 PreferenceKey 测三段加入后的高度,visibleHeight = panelHeight ×
//  (1 - progress) 同步衰减,opacity / offset 也同步）。
//
//  4 个 ContentView body 删去自己的 `RepoLocalSections(repo:)` 调用,只剩 ReadmeStateView。
//
//  RepoLocalSections 内部的 v1.4 守卫（`isAuthenticated && repo.id != 0`）+ spring
//  0.25s star 后展开转场动画都保留 —— 用户在 trending/weekly 详情点 star 后,
//  panelHeight 会随三段加入而增长,折叠面板与 spring 转场协同（两层动画都是
//  short-duration spring,叠加视觉 OK）。
//
//  ────────────────────────────────────────────────────────────────────────────
//  与现有 RepoDetailView (Manage / Trending) 的迁移路径
//  ────────────────────────────────────────────────────────────────────────────
//
//  Step 6 接入时：
//  - Manage `RepoDetailView` 拆为：`RepoDetailScaffold` + `ManageDetailContent`（body slot）
//  - Trending `TrendingView` 详情拆为：`RepoDetailScaffold` + `TrendingDetailContent`
//  - Weekly `WeeklyDetailView` 拆为：`RepoDetailScaffold` + `WeeklyDetailContent`
//  - Activity-repo-backed 详情拆为：`RepoDetailScaffold` + `ActivityRepoDetailContent`
//
//  各 ContentView 自主判断 `resolution.isLocalHit` 决定是否渲染 tags / notes / release
//  三段（设计 §3.2.3 决策：Scaffold 不带 sections 配置，避免 god view）。
//

import SwiftUI

/// R-01 详情页通用骨架。
///
/// body slot 接受一个 `(CGFloat) -> Void` 闭包参数 —— body 里的 ReadmeStateView 等
/// 滚动型组件应该把 scroll offset 通过这个闭包回传，Scaffold 内部把它换算成顶部
/// 折叠面板的 collapse progress（0...1）。
///
/// 这样设计的理由（vs PreferenceKey）：
/// - PreferenceKey 需要在 body 里手动叠 `.preference(...)`，对调用方不友好
/// - closure 入参显式契约，VS Code 跳定义时一眼看出"是要我把 scroll offset 喂进来"
/// - Scaffold 内部 progress 状态保持 private，body 完全无感
struct RepoDetailScaffold<Body: View, HeroExt: View>: View {

    /// 当前 repo（驱动 Hero header 视觉）。
    let repo: Repo

    /// 详情页通用视图数据（trailingActions / translation / backendHint）。
    let viewData: RepoDetailViewData

    /// Hero stats 行 ⭐/☆ chip 触发的异步动作（设计 §3.2.3 状态机）。
    ///
    /// - 成功（不抛错）→ chip 自动退出 loading；UI 由 `StarredRegistry` /
    ///   `Repo.isStarred` 字段变更驱动重渲染（API 200 才变 UI 原则）
    /// - 抛错 → chip 抖动 + 短暂红色 600ms，不弹 toast / alert
    /// - 闭包内部应：① 未登录走 `authSession.signIn()` 后 return（不抛错）
    ///   ② 已 star 调 `dependencies.starActionService.unstar(repo:)`
    ///   ③ 未 star 调 `dependencies.starActionService.star(owner:repo:)`
    let onStarTapped: () async throws -> Void

    /// Activity 等场景的 fallback 颜色（无语言时 Hero 渐变使用）。
    let fallbackAccentColor: Color

    /// Stars stat chip 的 tooltip 本地化键（透传给 RepoMetadataHeaderView）。
    let starHelpKey: LocalizedStringKey

    // v2.1 修订（2026-06-11）：原 `onRefresh: (() async -> Void)?` 入参已删除。
    // 该字段曾给 §3.2.9「右下角浮动刷新按钮」用,但与 cacheFooter 内置 SyncIconButton
    // 视觉重叠造成 bug,详见文件头 v2.1 修订段。现刷新入口统一收口到 cacheFooter
    // (4 场景共用),Manage 场景下 onRetry 闭包内并发触发 README + reloadItems。

    private let heroExtension_: () -> HeroExt
    private let body_: (@escaping (CGFloat) -> Void) -> Body

    /// 顶部面板折叠进度（0 = 完全展开，1 = 完全折叠）。
    @State private var metadataPanelCollapseProgress: CGFloat = 0

    /// 顶部面板自然高度（由 CollapsibleRepoMetadataPanel 内部回填）。
    @State private var metadataPanelHeight: CGFloat = 0

    /// OpenSSF Scorecard 安全评估 sheet。
    @State private var showSecurityScoreSheet = false

    // v2.1 修订（2026-06-11）：原 `@State private var isRefreshing: Bool` 已删除。
    // 该状态曾给浮动刷新按钮用,现统一由 cacheFooter 内的 `readmeVM.isRefreshing` 驱动。

    @Environment(\.starcatReduceMotion) private var reduceMotion

    /// 顶部面板折叠/展开动画。轻阻尼 spring，让 README WebView 让位时跟手。
    private var metadataPanelAnimation: Animation {
        .interactiveSpring(response: 0.32, dampingFraction: 0.9, blendDuration: 0.08)
    }

    init(
        repo: Repo,
        viewData: RepoDetailViewData,
        fallbackAccentColor: Color = .accentColor,
        starHelpKey: LocalizedStringKey = "repo.unstar",
        onStarTapped: @escaping () async throws -> Void,
        @ViewBuilder heroExtension: @escaping () -> HeroExt,
        @ViewBuilder body: @escaping (@escaping (CGFloat) -> Void) -> Body
    ) {
        self.repo = repo
        self.viewData = viewData
        self.fallbackAccentColor = fallbackAccentColor
        self.starHelpKey = starHelpKey
        self.onStarTapped = onStarTapped
        self.heroExtension_ = heroExtension
        self.body_ = body
    }

    /// 便捷构造：无 heroExtension 的常用场景（Manage / Weekly / Activity-repo-backed）。
    init(
        repo: Repo,
        viewData: RepoDetailViewData,
        fallbackAccentColor: Color = .accentColor,
        starHelpKey: LocalizedStringKey = "repo.unstar",
        onStarTapped: @escaping () async throws -> Void,
        @ViewBuilder body: @escaping (@escaping (CGFloat) -> Void) -> Body
    ) where HeroExt == EmptyView {
        self.init(
            repo: repo,
            viewData: viewData,
            fallbackAccentColor: fallbackAccentColor,
            starHelpKey: starHelpKey,
            onStarTapped: onStarTapped,
            heroExtension: { EmptyView() },
            body: body
        )
    }

    var body: some View {
        // v2.1 修订（2026-06-11）：原 `.overlay(alignment: .bottomTrailing)` 浮动刷新
        // 按钮已删除（与 cacheFooter 内置按钮视觉重叠造成 bug,详见文件头 v2.1 修订段）。
        VStack(alignment: .leading, spacing: 0) {
            metadataPanel
            body_(updateScrollOffset)
        }
        .id(repo.id)
        .navigationTitle(repo.name)
        .navigationSubtitle(repo.owner)
        .sheet(isPresented: $showSecurityScoreSheet) {
            OpenSSFScoreSheet(repo: repo)
                .appLocaleEnvironment()
        }
        .onChange(of: repo.id) { _, _ in
            withAnimation(reduceMotion ? nil : metadataPanelAnimation) {
                metadataPanelCollapseProgress = 0
            }
        }
    }

    /// 接收 body 内部上报的 scroll offset，换算成顶部面板折叠 progress。
    ///
    /// 与现有 `RepoDetailView.updateMetadataPanelVisibility` 函数一致的算法（8pt 起步、
    /// 64pt 行程、变化 < 0.01 跳过避免过密 SwiftUI 重排）。
    private func updateScrollOffset(_ offsetY: CGFloat) {
        let progress = Self.metadataCollapseProgress(for: offsetY)
        guard abs(progress - metadataPanelCollapseProgress) > 0.01 else { return }
        metadataPanelCollapseProgress = progress
    }

    /// 将 scroll offset 映射为顶部元信息面板的折叠进度。
    /// 0...8pt 保留上下文，8...72pt 跟随压缩，72pt+ 完全收起。
    static func metadataCollapseProgress(for offsetY: CGFloat) -> CGFloat {
        let normalizedOffset = max(offsetY, 0)
        let collapseStart: CGFloat = 8
        let collapseDistance: CGFloat = 64
        return min(max((normalizedOffset - collapseStart) / collapseDistance, 0), 1)
    }

    /// 顶部信息面板（折叠容器 + Hero 元信息 + heroExtension slot + RepoLocalSections）。
    ///
    /// 渲染顺序（自上而下）：
    /// 1. `RepoMetadataHeaderView` —— Hero 元信息 + ⭐/☆ chip + trailingActions
    /// 2. `heroExtension_()` —— 场景特化扩展（如 Trending Contributors）
    /// 3. `RepoLocalSections(repo:)` —— **v1.5 内置（2026-06-10）**：Tags / Notes /
    ///    Releases 订阅三段。**4 场景同构**,内置消除 4 个 ContentView 重复 + 解决
    ///    「滚动 README 时三段挤压阅读区」bug —— 三段现在跟随面板整段折叠。
    ///    可见性由 RepoLocalSections 内部 `isAuthenticated && repo.id != 0` 守卫
    ///    自动判定（v1.4 决策）,Scaffold 无条件挂载即可。
    ///
    /// 全部内容包在 `CollapsibleRepoMetadataPanel` 里,内部 PreferenceKey 测自然
    /// 高度 → 按 `metadataPanelCollapseProgress` (0...1) 同步衰减 visibleHeight /
    /// opacity / offset,实现「滚动 README 时整段面板折叠让位阅读」体验。
    ///
    /// **调用方 / heroExtension 需自行处理 horizontal padding**——RepoMetadataHeaderView
    /// 与 RepoLocalSections 内部都用 `.padding(.horizontal, 24)`,extension 也应保持
    /// 这个值以视觉对齐。
    @ViewBuilder
    private var metadataPanel: some View {
        CollapsibleRepoMetadataPanel(
            collapseProgress: $metadataPanelCollapseProgress,
            panelHeight: $metadataPanelHeight
        ) {
            VStack(alignment: .leading, spacing: 0) {
                RepoMetadataHeaderView(
                    repo: repo,
                    fallbackAccentColor: fallbackAccentColor,
                    starHelpKey: starHelpKey,
                    headerSourceBadge: viewData.headerSourceBadge,
                    onStarTapped: onStarTapped
                ) {
                    trailingActionsView
                }
                heroExtension_()
                // v1.5（2026-06-10）：RepoLocalSections 内置渲染,跟随面板整段折叠。
                // 可见性 + spring 0.25s star 后展开转场都由组件内部自治,Scaffold 无脑挂。
                RepoLocalSections(repo: repo)
            }
        }
    }

    /// trailingActions 派发渲染（按 RepoDetailAction enum 类型）。
    ///
    /// Wiki 评审约束（2026-06-11）：Weekly Issue 是 Weekly 分组特有入口，必须永远排第一。
    /// 因此先渲染 `.weeklyIssue`，再渲染统一 `RepoWikiMenu`，最后渲染 share / ai / custom。
    /// 其他详情页没有 weeklyIssue，自然得到 `Wiki -> Share -> AI`。这里按 action 类型分组，
    /// 不引入 priority 数字，也不要求四个场景调用方改造数据模型。
    @ViewBuilder
    private var trailingActionsView: some View {
        HStack(spacing: 8) {
            ForEach(weeklyIssueActions) { action in
                actionButton(for: action)
            }
            RepoWikiMenu(repo: repo)
            ForEach(remainingActions) { action in
                actionButton(for: action)
            }
        }
    }

    /// Weekly 特有 action，固定放在 Wiki 之前。
    private var weeklyIssueActions: [RepoDetailAction] {
        viewData.trailingActions.filter { action in
            if case .weeklyIssue = action { return true }
            return false
        }
    }

    /// 除 Weekly Issue 外的通用/场景 action，固定放在 Wiki 之后。
    private var remainingActions: [RepoDetailAction] {
        viewData.trailingActions.filter { action in
            if case .weeklyIssue = action { return false }
            return true
        }
    }

    @ViewBuilder
    private func actionButton(for action: RepoDetailAction) -> some View {
        switch action {
        case .share:
            // 复用现有 RepoShareButton：自带分享 API 调用 + alert 状态机。
            // share 行为对所有 repo 一致，不需要场景级 handler 注入。
            RepoShareButton(repo: repo)

        case .ai:
            // 复用现有 RepoAIOpenButton：内部通过 RepoAIWindowController 弹窗。
            RepoAIOpenButton(repo: repo)

        case .securityScore:
            Button {
                showSecurityScoreSheet = true
            } label: {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pressableHover()
            .help("openssf.action.securityScore")

        case .weeklyIssue(let number, let url):
            Link(destination: url) {
                HStack(spacing: 4) {
                    Image(systemName: "newspaper")
                        .font(.system(size: 12, weight: .semibold))
                    Text("# \(number)")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                }
                .foregroundStyle(.purple)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background {
                    Capsule(style: .continuous)
                        .fill(Color.purple.opacity(0.12))
                }
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(Text("weekly.detail.openIssue"))

        case .custom(_, let label, let systemImage, let handler):
            Button {
                handler()
            } label: {
                Label(label, systemImage: systemImage)
                    .font(.body)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pressableHover()
        }
    }
}
