//
//  UnifiedRepoRow.swift
//  Starcat
//
//  R-01「三场景共用架构」统一卡片视图（仅 card 密度）。
//
//  ────────────────────────────────────────────────────────────────────────────
//  替代以下 row 视图（设计 §3.1.5）
//  ────────────────────────────────────────────────────────────────────────────
//
//  - `RepoRowCard` (Manage)
//  - `TrendingRepoRowView` 大体内容
//  - `WeeklyProjectRow` 卡片部分
//  - Activity-repo-backed 卡片
//
//  ────────────────────────────────────────────────────────────────────────────
//  视觉骨架（与原 RepoRowCard 100% 对齐 + 增强）
//  ────────────────────────────────────────────────────────────────────────────
//
//  - 40pt 头像（来自 owner 拼接 GitHub 公开重定向 URL）
//  - 已 star → fullName 右侧紧贴 ✓ 标记（systemGreen 11pt，gap 4pt）
//  - 描述 2 行截断
//  - chip 行：Lang → Stars → Forks → archived（如有）→ 场景独有徽章 (badge)
//  - 不渲染 star/unstar 按钮（设计 §3.1.6 决策：交互入口仅在详情页 hero stats 行）
//
//  ────────────────────────────────────────────────────────────────────────────
//  v1.8 修订（2026-06-10, dong4j bug 反馈）：✓ 标记可见性 view 层显式控制
//  ────────────────────────────────────────────────────────────────────────────
//
//  设计意图：「已 star ✓」标记紧贴 fullName 让用户在 **trending / weekly 列表**
//  一眼能认出哪些已 star,无需打开详情 —— 这是 R-01「跨场景标记」设计的核心收益。
//
//  R-01 P0 落地时,实现把 ✓ 渲染条件挂在 `card.isStarred` 上,但 `Repo.asCardData()`
//  直接读 `self.isStarred`,Manage 列表所有 row 来自本地 `repos.is_starred=1` 表
//  → 永远 isStarred=true → **Manage 列表 row 全显 ✓ → 视觉冗余**(Manage 本就是
//  已 star 列表,挂 ✓ 没意义)。
//
//  v1.8 修订:加入参 `showStarredCheckmark: Bool = false`(默认不显)。调用方按
//  场景显式传:
//  - **Manage** (`RepoListView`):不传 → 默认 false → 全部不显 ✓(因为本就已 star)
//  - **Trending** (`TrendingView`):传 `true` → 已 star 的 row 显 ✓
//  - **Weekly** (`WeeklyContentView`):传 `true` → 已 star 的 row 显 ✓
//
//  默认 false 的语义是「除非显式声明,否则不显」—— 安全策略:后续新加场景
//  必须显式决定,避免再次出现「全显 ✓」式的实现疏忽。
//
//  `RepoCardViewData.isStarred` 字段保留(详情页 / 跨页同步可能用),只是 row
//  渲染不再单独以它为唯一条件,而是 `showStarredCheckmark && card.isStarred`
//  双条件 AND。
//
//  ────────────────────────────────────────────────────────────────────────────
//  v1.9 修订（2026-06-10, dong4j「四场景统一 row」遗留 bug 反馈）：Activity 接入完成
//  ────────────────────────────────────────────────────────────────────────────
//
//  R-01 设计意图本就包含「Activity-repo-backed 卡片」（见上面 line 14 替代列表），
//  但 P0 落地时 Activity 全走 `ActivityRowView` 老路径 —— `UnifiedRepoRow` 的
//  `case .activityKind = card.badge` 分支（avatarWithKindBadge 头像角圆角标）
//  一直没真正被消费。
//
//  v1.9 在 `Features/Activity/ActivityView.rowContent(for:)` 按 `item.kind` 派发：
//  - `star` / `repository` / `suggestion`（**纯仓库型**）→ UnifiedRepoRow，
//    视觉与 Manage / Trending / Weekly 100% 一致；
//  - `release` / `announcement` / `following` → 保留 `ActivityRowView`：
//    release 主体是 release name + 未读 chip（与 UnifiedRepoRow「以仓库为主体」
//    语义冲突）；announcement / following 无 `item.repo` 无法构造 RepoCardViewData。
//
//  Activity row 不传 `showStarredCheckmark`（默认 false）—— `ActivityViewModel.filter
//  { $0.isStarred }` 已过滤 100% starred,挂 ✓ 视觉冗余,与 Manage 同策略。
//
//  ────────────────────────────────────────────────────────────────────────────
//  v2.0 修订（2026-06-11, dong4j 反馈）：Activity 右上 RelativeDateBadge 删除
//  ────────────────────────────────────────────────────────────────────────────
//
//  dong4j 体测后判定：Activity 卡片右上角的相对时间戳信息密度低且语义漂移
//  严重 —— `.star` 时戳是 `starredAt`（用户行为）/ `.repository` & `.suggestion`
//  时戳都是 `pushedAt`（仓库代码推送）/ `.release` 走老的 `ActivityRowView`
//  根本不进这里。在 `.all` 视图同框时用户无法分辨「5 分钟前」对应哪种事件。
//
//  v2.0 把 `CardBadge.activityKind(ActivityCategory, Date)` 改为
//  `.activityKind(ActivityCategory)` 删 Date 参数，UnifiedRepoRow 内
//  RelativeDateBadge 整段渲染移除。`.release` / `.announcement` 的时间戳
//  在 `ActivityRowView` 内不动（release name + publishedAt 是该 kind 核心信息）。
//
//  设计反思：原 R-01 v1.2 §3.1.5 表格规划「Activity 卡片：头像 kind icon +
//  右上相对时间」是按 kind 时戳「都是该事件发生时间」想当然的均质假设。
//  落地后才发现 `.repository` / `.suggestion` 都用 `pushedAt`（非用户视角的
//  「事件发生」），且 `.suggestion` 是启发式推荐而非时间事件 —— v2.0 整列删除
//  是承认这个时戳维度不够强一致来支持统一渲染。
//

import SwiftUI

/// R-01 统一卡片视图。
///
/// 入参 `RepoCardViewData` 由各场景 ViewModel 通过
/// `Repo.asCardData()` / `StarcatRepoCardDTO.asCardData(registry:badge:)` 适配生成。
struct UnifiedRepoRow: View {

    /// Weekly 期号 chip 的薰衣草紫，#9F80DB。
    ///
    /// 替换 SwiftUI 系统 `.purple`（#BF5AF2 在暗模式下饱和度过高，反差刺眼，
    /// dong4j 2026-06-11 截图反馈）。同色相但降饱和与亮度，保留"紫 =
    /// Weekly 精选"的视觉系统。引用方仅本 file `case .weeklyIssue`（line 230 段）。
    fileprivate static let weeklyChipTint = Color(red: 159 / 255, green: 128 / 255, blue: 219 / 255)

    let card: RepoCardViewData

    /// 是否选中（驱动 RepoRowSurface 视觉变化）。
    let isSelected: Bool

    /// 语义搜索命中（仅 Manage 场景非 nil；其它场景一律 nil）。
    /// chip 行右侧紧跟 SemanticScoreBadge 显示相似度分数。
    let semanticHit: SemanticSearchHit?

    /// 是否在 row 上显示「已 star ✓」标记(v1.8 修订, 2026-06-10)。
    ///
    /// **默认 false** —— 调用方必须显式按场景决定:
    /// - Manage:不传(默认 false),Manage 本就是已 star 列表,挂 ✓ 视觉冗余;
    /// - Trending / Weekly:传 `true`,让用户在列表里一眼认出哪些已 star;
    /// - 后续新场景:必须显式决定,避免「全显 ✓」式实现疏忽。
    ///
    /// 渲染条件是 `showStarredCheckmark && card.isStarred` 双条件 AND——
    /// `card.isStarred` 仍由调用方派生(Manage 读 self,Trending/Weekly 走 registry)。
    let showStarredCheckmark: Bool

    init(
        card: RepoCardViewData,
        isSelected: Bool = false,
        semanticHit: SemanticSearchHit? = nil,
        showStarredCheckmark: Bool = false
    ) {
        self.card = card
        self.isSelected = isSelected
        self.semanticHit = semanticHit
        self.showStarredCheckmark = showStarredCheckmark
    }

    var body: some View {
        RepoRowSurface(isSelected: isSelected, accentColor: accentColor) {
            HStack(alignment: .center, spacing: 12) {

                // 头像 + 「activity kind icon」徽章覆盖（仅 Activity 场景）
                avatarWithKindBadge

                VStack(alignment: .leading, spacing: 5) {

                    // fullName + 已 star ✓ 标记 + Fork 徽章
                    HStack(spacing: 4) {
                        Text(card.fullName)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(1)

                        if showStarredCheckmark && card.isStarred {
                            // 紧贴 fullName 右侧 4pt（设计 §3.1.2 表格：图标 = checkmark.circle.fill / systemGreen / 11pt）
                            // v1.8 修订(2026-06-10):双条件 AND——Manage 不传 showStarredCheckmark
                            // 默认 false 即不显;Trending / Weekly 显式传 true,再由 card.isStarred 决定单 row。
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.green)
                                .accessibilityLabel(Text("repo.card.alreadyStarred"))
                        }

                        if card.isFork {
                            MetaBadge(systemImage: "tuningfork", text: "Fork", tint: .secondary)
                        }

                        if !card.weeklySources.isEmpty {
                            WeeklySourceInlineBadge(
                                sources: card.weeklySources,
                                label: card.weeklySourceLabel
                            )
                            .padding(.leading, 3)
                        }

                        Spacer(minLength: 0)

                        // v2.0（2026-06-11 dong4j 决策）：Activity 卡片右上角 RelativeDateBadge 已删。
                        // 原渲染 `item.createdAt` 在 `.star`(=starredAt) / `.repository` & `.suggestion`
                        // (=pushedAt) 之间语义漂移，`.all` 视图同框时用户分不清「5 分钟前」指 star
                        // 行为还是 repo push；信息密度低 + 语义漂移得不偿失。头像左下 kind icon +
                        // 行内 chip 区已能传达足够信号。`.release` / `.announcement` 走老的
                        // `ActivityRowView`（不进 UnifiedRepoRow）的时间戳保留不动。
                    }

                    if let description = card.description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    // chip 行
                    HStack(spacing: 8) {
                        if let language = card.language, !language.isEmpty {
                            LanguageBadge(language: language, style: .full)
                        }
                        StarsBadge(count: card.starsCount, style: .full)
                        MetaBadge(systemImage: "tuningfork", text: card.forksCount.formattedShort, tint: .secondary)
                        if card.isArchived {
                            // 卡片走 iconOnly：4+ chip 同行（Language + Stars + Forks + Archived
                            // + sceneBadge）下 "Archived" 文字会挤换行。详情页 / 活动详情面板
                            // 仍走默认 ArchivedBadge() 保留文字，详见 RepoRowComponents.swift。
                            ArchivedBadge(iconOnly: true)
                        }
                        sceneBadgeChip
                        if let semanticHit {
                            SemanticScoreBadge(hit: semanticHit)
                        }
                        Spacer(minLength: 0)
                    }
                }

                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - 派生属性

    /// accent 颜色：优先 language；nil 时让 RepoRowSurface 用系统色
    private var accentColor: Color? {
        guard let language = card.language, !language.isEmpty else { return nil }
        return LanguageColor.color(for: language)
    }

    /// 头像 + Activity kind icon 角标
    @ViewBuilder
    private var avatarWithKindBadge: some View {
        if case .activityKind(let category) = card.badge {
            // 头像右下角 kind icon 圆形小角标
            ZStack(alignment: .bottomTrailing) {
                RemoteAvatar(urlString: RepoAvatarURL.from(owner: card.owner), size: 40)
                Image(systemName: category.systemImage)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(Circle().fill(category.iconColor))
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                    .offset(x: 2, y: 2)
            }
        } else {
            RemoteAvatar(urlString: RepoAvatarURL.from(owner: card.owner), size: 40)
        }
    }

    /// 场景独有徽章 chip（trending +N / weekly 第 N 期 / activity kind 已在头像）
    @ViewBuilder
    private var sceneBadgeChip: some View {
        switch card.badge {
        case .trendingChange(let change):
            HStack(spacing: 3) {
                Image(systemName: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 9, weight: .bold))
                Text("\(change >= 0 ? "+" : "")\(change.formattedShort)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(change >= 0 ? Color.green : Color.red)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background {
                Capsule(style: .continuous)
                    .fill((change >= 0 ? Color.green : Color.red).opacity(0.12))
            }

        case .weeklyIssue(let number):
            // 配色（dong4j 2026-06-11 反馈）：SwiftUI 系统 .purple 在暗模式
            // 下饱和度过高，跟卡片其他低饱和 chip 反差刺眼。换成 #9F80DB
            // 薰衣草紫（同色相但降饱和与亮度），保留"紫 = Weekly 精选"的
            // 视觉系统。两处引用统一走 Self.weeklyChipTint，避免不一致。
            //
            // 注：同文件 SemanticScoreBadge (line 270/275) 仍用 .purple，
            // 视觉行为同源问题，但 dong4j 本次未要求改 —— 留作后续。
            HStack(spacing: 4) {
                Image(systemName: "newspaper")
                    .font(.system(size: 10, weight: .semibold))
                Text("# \(number)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(Self.weeklyChipTint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background {
                Capsule(style: .continuous)
                    .fill(Self.weeklyChipTint.opacity(0.12))
            }

        case .activityKind, .none:
            EmptyView()
        }
    }
}

// MARK: - WeeklySourceInlineBadge

private struct WeeklySourceInlineBadge: View {
    let sources: [WeeklySource]
    let label: String?

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: -4) {
                ForEach(Array(sources.prefix(4).enumerated()), id: \.offset) { _, source in
                    sourceIcon(source)
                }
            }
            if let label, !label.isEmpty {
                Text(label)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background {
            Capsule(style: .continuous)
                .fill(Color.secondary.opacity(0.10))
        }
        .help(sources.map(\.displayName).joined(separator: " / "))
    }

    @ViewBuilder
    private func sourceIcon(_ source: WeeklySource) -> some View {
        switch source {
        case .unknown:
            Image(systemName: source.assetName)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
        default:
            Image(source.assetName)
                .resizable()
                .scaledToFill()
                .frame(width: 16, height: 16)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
        }
    }
}

// MARK: - SemanticScoreBadge

/// 语义搜索命中分数 chip。
///
/// 紫色 capsule + sparkles + 百分比，悬停 tooltip 显示命中原因（reason）。
/// 仅在 Manage 场景的 RepoListView 通过 `viewModel.semanticHit(for:)` 注入。
///
/// R-01 §3.1.5 之前定义在 `Features/Home/RepoRowView.swift`，Step 7.2 删除该旧文件后
/// 一并迁移到 UnifiedRepoRow.swift（唯一调用方），保持单一真源。
struct SemanticScoreBadge: View {
    let hit: SemanticSearchHit

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles")
                .font(.system(size: 9, weight: .bold))
            Text(scoreText)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(.purple)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background {
            Capsule(style: .continuous)
                .fill(Color.purple.opacity(0.12))
        }
        .help(hit.reason)
    }

    private var scoreText: String {
        "\(Int((max(0, min(hit.score, 1)) * 100).rounded()))%"
    }
}
