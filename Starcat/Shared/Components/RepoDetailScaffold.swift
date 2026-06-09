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
//    - Hero header（复用 `RepoMetadataHeaderView`，传 `showLocalSections=false`
//      让 Hero 仅渲染元信息——三段 section 由 ContentView 自己决定是否渲染）
//    - 折叠面板（复用 `CollapsibleRepoMetadataPanel`）
//    - trailingActions 渲染（按 `RepoDetailAction` enum 派发）
//
//  Scaffold **不**负责：
//    - body 内部布局（ContentView 自己持有 ScrollView + sections + Readme）
//    - star/unstar 业务逻辑（由 onStarTapped 上层处理）
//    - 翻译浮动按钮 / 刷新浮动按钮（这两个是 ReadmeStateView 的内嵌 cacheFooter，
//      ContentView 渲染 ReadmeStateView 时已经包含；Scaffold 不重复渲染）
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
struct RepoDetailScaffold<Body: View>: View {

    /// 当前 repo（驱动 Hero header 视觉）。
    let repo: Repo

    /// 详情页通用视图数据（trailingActions / translation / backendHint）。
    let viewData: RepoDetailViewData

    /// Hero stats 行 ⭐/☆ chip 触发的回调。
    /// 设计 §3.2.3：仅 hero stats 行的 chip 是 star/unstar 入口，trailing actions
    /// 不重复包含 star。
    let onStarTapped: () -> Void

    /// Activity 等场景的 fallback 颜色（无语言时 Hero 渐变使用）。
    let fallbackAccentColor: Color

    /// Hero 是否渲染 tags / notes / release 三段（默认 false —— Step 6 接入时由
    /// ContentView 自己决定渲染位置）。
    let heroShowsLocalSections: Bool

    private let body_: () -> Body

    /// 顶部面板折叠进度（0 = 完全展开，1 = 完全折叠）。
    @State private var metadataPanelCollapseProgress: CGFloat = 0

    /// 顶部面板自然高度（由 CollapsibleRepoMetadataPanel 内部回填）。
    @State private var metadataPanelHeight: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 顶部面板折叠/展开动画。轻阻尼 spring，让 README WebView 让位时跟手。
    private var metadataPanelAnimation: Animation {
        .interactiveSpring(response: 0.32, dampingFraction: 0.9, blendDuration: 0.08)
    }

    init(
        repo: Repo,
        viewData: RepoDetailViewData,
        fallbackAccentColor: Color = .accentColor,
        heroShowsLocalSections: Bool = false,
        onStarTapped: @escaping () -> Void,
        @ViewBuilder body: @escaping () -> Body
    ) {
        self.repo = repo
        self.viewData = viewData
        self.fallbackAccentColor = fallbackAccentColor
        self.heroShowsLocalSections = heroShowsLocalSections
        self.onStarTapped = onStarTapped
        self.body_ = body
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            metadataPanel
            body_()
        }
        .id(repo.id)
        .navigationTitle(repo.name)
        .navigationSubtitle(repo.owner)
        .onChange(of: repo.id) { _, _ in
            withAnimation(metadataPanelAnimation) {
                metadataPanelCollapseProgress = 0
            }
        }
    }

    /// 顶部信息面板（折叠容器 + Hero 元信息）。
    @ViewBuilder
    private var metadataPanel: some View {
        CollapsibleRepoMetadataPanel(
            collapseProgress: $metadataPanelCollapseProgress,
            panelHeight: $metadataPanelHeight
        ) {
            RepoMetadataHeaderView(
                repo: repo,
                fallbackAccentColor: fallbackAccentColor,
                showLocalSections: heroShowsLocalSections,
                onStarTapped: onStarTapped
            ) {
                trailingActionsView
            }
        }
    }

    /// trailingActions 派发渲染（按 RepoDetailAction enum 类型）。
    @ViewBuilder
    private var trailingActionsView: some View {
        HStack(spacing: 8) {
            ForEach(viewData.trailingActions) { action in
                actionButton(for: action)
            }
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
