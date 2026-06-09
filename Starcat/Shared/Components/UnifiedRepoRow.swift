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
//  - 「已 star ✓」 标记紧贴 fullName 是关键视觉（让用户在 trending / weekly 列表
//    一眼能认出哪些已 star，无需打开详情）—— 这是 R-01「跨场景标记」设计的核心收益
//

import SwiftUI

/// R-01 统一卡片视图。
///
/// 入参 `RepoCardViewData` 由各场景 ViewModel 通过
/// `Repo.asCardData()` / `StarcatRepoCardDTO.asCardData(registry:badge:)` 适配生成。
struct UnifiedRepoRow: View {

    let card: RepoCardViewData

    /// 是否选中（驱动 RepoRowSurface 视觉变化）。
    let isSelected: Bool

    /// 语义搜索命中（仅 Manage 场景非 nil；其它场景一律 nil）。
    /// chip 行右侧紧跟 SemanticScoreBadge 显示相似度分数。
    let semanticHit: SemanticSearchHit?

    init(card: RepoCardViewData, isSelected: Bool = false, semanticHit: SemanticSearchHit? = nil) {
        self.card = card
        self.isSelected = isSelected
        self.semanticHit = semanticHit
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

                        if card.isStarred {
                            // 紧贴 fullName 右侧 4pt（设计 §3.1.5）
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.green)
                                .accessibilityLabel(Text("repo.card.alreadyStarred"))
                        }

                        if card.isFork {
                            MetaBadge(systemImage: "tuningfork", text: "Fork", tint: .secondary)
                        }

                        Spacer(minLength: 0)

                        // Activity 场景右上角相对时间（与 kind icon 在头像角分开）
                        if case .activityKind(_, let date) = card.badge {
                            RelativeDateBadge(date: date)
                        }
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
                            ArchivedBadge()
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
        if case .activityKind(let category, _) = card.badge {
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
            HStack(spacing: 4) {
                Image(systemName: "newspaper")
                    .font(.system(size: 10, weight: .semibold))
                Text("# \(number)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(.purple)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.purple.opacity(0.12))
            }

        case .activityKind, .none:
            EmptyView()
        }
    }
}
