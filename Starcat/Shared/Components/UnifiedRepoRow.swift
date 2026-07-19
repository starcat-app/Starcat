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

    /// 是否在头像左上角显示“已加入知识库”角标。
    /// 知识库自身列表会关闭该标记，避免所有行重复同一个无区分度信号。
    let showLibraryBadge: Bool

    /// 是否显示阅读状态标记。知识库浏览器负责索引与分片浏览，不承担阅读进度管理，
    /// 因此会关闭该标记；主窗口等原有场景继续使用默认值。
    let showReadStatusBadge: Bool

    /// 当前仓库是否至少存在一份 AI 摘要。
    /// 默认关闭，只有星标管理列表显式注入，避免 Trending / Weekly 等共享行误显示本地状态。
    let hasAISummary: Bool

    /// 右侧 overlay 图标需要的内容安全边界。默认 0，只有 Search Center「全部」
    /// Tab 的来源图标会传入，避免长描述延伸到右侧 overlay 下方。
    let trailingReservedWidth: CGFloat
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    init(
        card: RepoCardViewData,
        isSelected: Bool = false,
        semanticHit: SemanticSearchHit? = nil,
        showStarredCheckmark: Bool = false,
        showLibraryBadge: Bool = true,
        showReadStatusBadge: Bool = true,
        hasAISummary: Bool = false,
        trailingReservedWidth: CGFloat = 0
    ) {
        self.card = card
        self.isSelected = isSelected
        self.semanticHit = semanticHit
        self.showStarredCheckmark = showStarredCheckmark
        self.showLibraryBadge = showLibraryBadge
        self.showReadStatusBadge = showReadStatusBadge
        self.hasAISummary = hasAISummary
        self.trailingReservedWidth = trailingReservedWidth
    }

    var body: some View {
        RepoRowSurface(isSelected: isSelected, accentColor: accentColor) {
            HStack(alignment: .center, spacing: 12) {

                // 头像 + 知识库 ❤️ + 「activity kind icon」徽章覆盖（仅 Activity 场景）
                avatarWithKindBadge

                VStack(alignment: .leading, spacing: 5) {

                    // fullName + 已 star ✓ 标记 + Fork 徽章
                    HStack(spacing: 4) {
                        Text(card.fullName)
                            .font(interfaceScale.font(.body, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(1)

                        if showStarredCheckmark && card.isStarred {
                            // 紧贴 fullName 右侧 4pt（设计 §3.1.2 表格：图标 = checkmark.circle.fill / systemGreen / 11pt）
                            // v1.8 修订(2026-06-10):双条件 AND——Manage 不传 showStarredCheckmark
                            // 默认 false 即不显;Trending / Weekly 显式传 true,再由 card.isStarred 决定单 row。
                            Image(systemName: "checkmark.circle.fill")
                                .font(interfaceScale.font(.captionSmall, weight: .semibold))
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

                        if let metadata = card.inlineMetadata {
                            RepoCardInlineMetadataBadge(metadata: metadata)
                                .padding(.leading, 3)
                        }

                        Spacer(minLength: 8)

                        if let score = card.openSSFScore {
                            OpenSSFScoreBadge(score: score)
                        }

                        // Repo Health 聚合健康度徽章（2026-06-21 接入）。
                        // 位置：紧跟 OpenSSF 之后,与详情页 hero 顺序保持一致。
                        // gate: 缓存未命中(card.healthBadge == nil)→ 不渲染;
                        // Pro 用户权限校验由详情页入口负责,列表行不做 gate。
                        if let health = card.healthBadge {
                            RepoHealthBadge(data: health)
                        }

                        // v2.0（2026-06-11 dong4j 决策）：Activity 卡片右上角 RelativeDateBadge 已删。
                        // 原渲染 `item.createdAt` 在 `.star`(=starredAt) / `.repository` & `.suggestion`
                        // (=pushedAt) 之间语义漂移，`.all` 视图同框时用户分不清「5 分钟前」指 star
                        // 行为还是 repo push；信息密度低 + 语义漂移得不偿失。头像左下 kind icon +
                        // 行内 chip 区已能传达足够信号。`.release` / `.announcement` 走老的
                        // `ActivityRowView`（不进 UnifiedRepoRow）的时间戳保留不动。
                    }

                    if let description = card.description, !description.isEmpty {
                        Text(description)
                            .font(interfaceScale.font(.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // chip 行：宽栏完整展示；窄栏 ViewThatFits 只对左簇降级
                    // （依次丢掉 Forks → footer 仅图标），避免 fixedSize chip 撑破卡片。
                    // Spacer / SemanticScoreBadge 放在 ViewThatFits 外，否则 Spacer 会干扰 ideal 测宽。
                    //
                    // 布局分区（v2.1，2026-06-13 dong4j 反馈）：
                    // - **左簇**：Language / Stars / Forks / Archived / sceneBadge / RepoStatusChip
                    // - `Spacer(minLength: 8)` 分隔
                    // - **右簇**：SemanticScoreBadge
                    HStack(spacing: 8) {
                        ViewThatFits(in: .horizontal) {
                            metadataChipCluster(includeForks: true, footerIconOnly: false)
                            metadataChipCluster(includeForks: false, footerIconOnly: false)
                            metadataChipCluster(includeForks: false, footerIconOnly: true)
                        }
                        Spacer(minLength: 8)
                        if let semanticHit {
                            SemanticScoreBadge(hit: semanticHit)
                        }
                    }
                }
                // minWidth: 0 允许 HStack 内文字区压缩到可用宽度；否则 chip 固有宽度会撑破卡片。
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, trailingReservedWidth)

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

    /// 头像 + 知识库/Activity 角标。
    ///
    /// 知识库 ❤️ 固定在左上角且不可点击；Activity kind icon 保留右下角，避免两个语义
    /// 抢同一个角。入库/移出操作只在详情页按钮执行，列表 row 仍保持原有选择行为。
    @ViewBuilder
    private var avatarWithKindBadge: some View {
        ZStack(alignment: .bottomTrailing) {
            RemoteAvatar(urlString: RepoAvatarURL.from(owner: card.owner), size: 40)
            if case .activityKind(let category) = card.badge {
                // 角标只在「全部分类」有辨识价值；尺寸刻意压到头像 ~1/4，避免抢 owner 头像。
                Image(systemName: category.systemImage)
                    .font(interfaceScale.font(size: 8, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(2)
                    .background(Circle().fill(category.iconColor))
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
                    .offset(x: 1, y: 1)
            }
        }
        .overlay(alignment: .topLeading) {
            if showLibraryBadge && card.isInLibrary {
                Image(systemName: "heart.fill")
                    .font(interfaceScale.font(.captionSmall, weight: .bold))
                    .foregroundStyle(Color.fromHex6(0xE11D48))
                    .padding(2)
                    .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
                    .offset(x: -2, y: -2)
                    .accessibilityLabel(Text("repo.card.inLibrary"))
                    .help(Text("repo.card.inLibrary"))
            }
        }
    }

    /// chip 左簇变体：供 `ViewThatFits` 在窄栏依次降级（无 Spacer，保证 ideal 测宽可信）。
    /// - `includeForks == false`：去掉 Forks 计数，先省约 40–50pt
    /// - `footerIconOnly == true`：footer 元数据（如 RAG 索引 pill）只留图标，完整文案走 tooltip
    @ViewBuilder
    private func metadataChipCluster(includeForks: Bool, footerIconOnly: Bool) -> some View {
        HStack(spacing: 8) {
            if let language = card.language, !language.isEmpty {
                LanguageBadge(language: language, style: .full)
            }
            StarsBadge(count: card.starsCount, style: .full)
            if includeForks {
                MetaBadge(systemImage: "tuningfork", text: card.forksCount.formattedShort, tint: .secondary)
            }
            if hasAISummary {
                // 与 RAG 仓库选择器复用同一 `sparkles` 语义；只显示图标，完整含义通过
                // tooltip 与 accessibility label 提供，避免在窄栏挤占 metadata 行。
                MetaBadge(
                    systemImage: "sparkles",
                    text: "",
                    tint: .accentColor,
                    iconOnly: true,
                    accessibilityLabel: "repo.card.aiSummaryAvailable"
                )
                .help("repo.card.aiSummaryAvailable")
            }
            if let metadata = card.footerMetadata {
                RepoCardInlineMetadataBadge(metadata: metadata, iconOnly: footerIconOnly)
            }
            if card.isArchived {
                // 卡片走 iconOnly：4+ chip 同行下 "Archived" 文字会挤换行。
                // 详情页仍走默认 ArchivedBadge() 保留文字，详见 RepoRowComponents.swift。
                ArchivedBadge(iconOnly: true)
            }
            sceneBadgeChip
            // 阅读状态：场景允许 && isStarred && 已注入 && 非 .read 默认态
            if showReadStatusBadge,
               card.isStarred,
               let readStatus = card.readStatus,
               readStatus != .read {
                RepoStatusChip(status: readStatus)
            }
        }
    }

    /// 场景独有徽章 chip（trending +N / weekly 第 N 期 / activity kind 已在头像）
    @ViewBuilder
    private var sceneBadgeChip: some View {
        switch card.badge {
        case .trendingChange(let change):
            // 与同行 Language / Stars / Forks 统一：captionSmall + 常规字重。
            // 旧实现用 .code(12pt) + semibold，视觉上明显偏大偏粗。
            HStack(spacing: 3) {
                Image(systemName: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(interfaceScale.font(.captionSmall))
                Text("\(change >= 0 ? "+" : "")\(change.formattedShort)")
                    .font(interfaceScale.font(.captionSmall))
                    .monospacedDigit()
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
                    .font(interfaceScale.font(.captionSmall, weight: .semibold))
                Text("# \(number)")
                    .font(interfaceScale.font(.code, weight: .semibold))
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
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: -4) {
                ForEach(Array(sources.prefix(4).enumerated()), id: \.offset) { _, source in
                    sourceIcon(source)
                }
            }
            if let label, !label.isEmpty {
                Text(label)
                    .font(interfaceScale.font(.code, weight: .semibold))
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
        .help(sources.map(\.presentation.displayName).joined(separator: " / "))
    }

    @ViewBuilder
    private func sourceIcon(_ source: WeeklySource) -> some View {
        if let assetName = source.presentation.assetName {
            Image(assetName)
                .resizable()
                .scaledToFill()
                .frame(width: 16, height: 16)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
        } else {
            Image(systemName: source.presentation.systemImage)
                .font(interfaceScale.font(.captionSmall, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
        }
    }
}

// MARK: - RepoCardInlineMetadataBadge

private struct RepoCardInlineMetadataBadge: View {
    let metadata: RepoCardInlineMetadata
    /// 窄栏降级：只显示图标，完整 `metadata.text` 走 help / VoiceOver。
    var iconOnly: Bool = false
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: metadata.systemImage)
                .font(interfaceScale.font(.captionSmall, weight: .semibold))
            if !iconOnly {
                Text(verbatim: metadata.text)
                    .font(interfaceScale.font(.code, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, iconOnly ? 4 : 5)
        .padding(.vertical, 2)
        .background {
            Capsule(style: .continuous)
                .fill(tint.opacity(0.10))
        }
        .frame(maxWidth: iconOnly ? nil : 96, alignment: .leading)
        .fixedSize(horizontal: iconOnly, vertical: false)
        .help(metadata.text)
        .accessibilityLabel(Text(verbatim: metadata.text))
    }

    private var tint: Color {
        switch metadata.tint {
        case .secondary:
            return .secondary
        case .green:
            return .green
        }
    }
}

// MARK: - SemanticScoreBadge

/// 语义搜索命中分数 chip。
///
/// 紫色 capsule + sparkles + 百分比，悬停 tooltip 显示命中原因（reason）。
/// 仅在 Manage 场景的 RepoListView 通过 `viewModel.semanticHit(for:)` 注入。
///
/// **2026-06-14 dong4j 改造（A 重标定）**：
/// - 百分数源从原始 cosine `hit.score` 改成重标定后的 `hit.displayScore`，
///   与设置页 75% 阈值滑杆同语义。原始 cosine 在文本 embedding 模型下值域偏移大
///   （0.30 ≈ 完全无关，0.95 ≈ 高度相关），直接 ×100 显示反直觉。
///
/// **2026-06-28 修订（dong4j 截图反馈，star 噪声大）**：
/// 移除 1-4 档文本星号 ★★★★，只保留 ✨ + 96%。tier 字段仍保留在 `SemanticSearchHit` 数据模型
/// 中（未来若需要回退可零成本恢复），UI 层不再消费。
///
/// R-01 §3.1.5 之前定义在 `Features/Home/RepoRowView.swift`，Step 7.2 删除该旧文件后
/// 一并迁移到 UnifiedRepoRow.swift（唯一调用方），保持单一真源。
struct SemanticScoreBadge: View {
    let hit: SemanticSearchHit
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles")
                .font(interfaceScale.font(.captionSmall, weight: .bold))
            Text(scoreText)
                .font(interfaceScale.font(.code, weight: .semibold))
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
        "\(Int((max(0, min(hit.displayScore, 1)) * 100).rounded()))%"
    }
}

// MARK: - OpenSSFScoreBadge

/// OpenSSF Scorecard 行内评分徽章。
///
/// 只展示图标 + 分数，不带说明文字；放在 `full_name` 行最右侧，避免占用 chip 行。
/// 颜色只用于背景/描边表达风险层级，文字保持 `.primary` 遵守浅色主题对比度规则。
///
/// ## v3 修订（2026-06-16, dong4j 反馈）
///
/// 1. **盾牌图标改"镭射"渐变填充**：`checkmark.shield.fill` 用 `Self.iridescentForeground`
///    （粉/紫/蓝/青/薄荷线性渐变）着色，与 Apple Intelligence 同款 iridescent 视觉。
///    数字仍走 `.primary` 保持对比度。
/// 2. **新增 `size` 入参**：`.compact`（列表卡片 9pt 图标 + caption2 数字）与
///    `.regular`（详情页 hero 11pt 图标 + footnote 数字）—— 让卡片和详情页用同一个
///    View 类型，只在尺寸维度做适配，避免两边视觉风格漂移。
struct OpenSSFScoreBadge: View {

    enum Size {
        /// 列表卡片用：9pt 图标 + caption2 数字。
        case compact
        /// 详情页 hero 用：11pt 图标 + footnote 数字。
        case regular
    }

    let score: OpenSSFScoreBadgeData
    let size: Size
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    init(score: OpenSSFScoreBadgeData, size: Size = .compact) {
        self.score = score
        self.size = size
    }

    /// 镭射渐变前景。详情页 fallback 图标也复用同一引用，保证两处视觉一致。
    ///
    /// 取色思路：粉/紫/蓝/青/薄荷绿 = Apple Intelligence 同款 iridescent 色域，
    /// 左上→右下 45° 走向避免与水平 capsule 长轴平行造成视觉单调。
    static let iridescentForeground = LinearGradient(
        colors: [.pink, .purple, .blue, .cyan, .mint],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    private var tint: Color {
        if score.score >= 7.5 { return .green }
        if score.score >= 5 { return .yellow }
        return .red
    }

    private var textFont: Font {
        interfaceScale.font(size == .compact ? .captionSmall : .caption)
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "checkmark.shield.fill")
                .font(interfaceScale.font(size == .compact ? .captionSmall : .caption, weight: .semibold))
                .foregroundStyle(Self.iridescentForeground)
            Text(verbatim: score.formattedScore)
                .font(textFont)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.13), in: Capsule())
        .overlay {
            Capsule()
                .stroke(tint.opacity(0.32), lineWidth: 0.5)
        }
        .fixedSize(horizontal: true, vertical: false)
        .help("openssf.badge.help")
        .accessibilityLabel(Text("openssf.badge.accessibility"))
        .accessibilityValue(Text(verbatim: score.formattedScore))
    }
}

// MARK: - RepoStatusChip

/// 阅读状态角标（v2，2026-06-12）。
///
/// **设计意图**：在 row chip 行末尾以最小视觉权重传达「这个 starred repo 我还没看 / 正在用」
/// 两个稀有信号。`.read` **不渲染**（默认态，绝大多数 row 都是这个，渲染反而成噪音）。
///
/// **可见性条件**：由调用方（UnifiedRepoRow chip 行）守卫：
/// 1. `card.isStarred == true`（trending/weekly ephemeral row 不显）
/// 2. `card.readStatus != nil`（调用方已显式注入状态信号）
/// 3. `card.readStatus != .read`
///
/// **视觉规格**：
/// - `.unread`：蓝色实心圆点（7pt），与邮件 / RSS "未读"视觉系统一致；不带文字保持紧凑
/// - `.using`：`checkmark.seal.fill` 图标 + accent 色 capsule + "在用"短文本
///   （与详情页 `RepoNotesSection` 状态 pill 同源，避免主窗口 / 详情视觉分叉）
/// - `.read`：EmptyView（不应被调用方传入，但守卫住做兜底）
fileprivate struct RepoStatusChip: View {

    let status: RepoStatus
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        switch status {
        case .unread:
            // 圆点 + accessibility label / help 提示。
            // 不挂背景 capsule —— 跟其他 chip（Language / Stars / Forks 带背景）对比成"原子"信号，
            // 视觉上跟 macOS 邮件未读蓝点同语义。
            Circle()
                .fill(Color.accentColor)
                .frame(width: 7, height: 7)
                .padding(.horizontal, 3)
                .accessibilityLabel(Text("repo.status.unread"))
                .help(Text("repo.status.unread"))

        case .using:
            // capsule chip（与 sceneBadge / SemanticScoreBadge 同视觉档），accent 色
            // 高亮 —— 这是用户主动标的"重点 repo"，应该比 unread 更突出。
            HStack(spacing: 3) {
                Image(systemName: "checkmark.seal.fill")
                    .font(interfaceScale.font(.captionSmall, weight: .semibold))
                Text("repo.status.using")
                    .font(interfaceScale.font(.captionSmall, weight: .semibold))
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
            }
            .accessibilityLabel(Text("repo.status.using"))

        case .read:
            // 守卫兜底：调用方应该已经过滤掉 .read，这里返回 EmptyView 保持 enum 完备性。
            EmptyView()
        }
    }
}
