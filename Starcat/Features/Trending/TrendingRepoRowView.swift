//
//  TrendingRepoRowView.swift
//  Starcat
//
//  Trending 列表行视图，遵循 RepoRowView 的设计模式并根据 UI 优化指导手册进行增强。
//
//  提供两种密度，由 AppSettings.listDensity 切换：
//  - compact：单行，name / lang / stars / periodText
//  - card：多行，头像 + full_name + description + 属性条 + 周期增长 + 贡献者
//
//  设计约束：
//  - 行视图本身无状态，纯函数式渲染
//  - 样式与 RepoRowView 保持高度一致，形成统一的 Starcat 卡片语言
//
//  共享组件（2026-06-02 Step 2 抽取）：
//  - chip 视图（`LanguageBadge` / `StarsBadge` / `MetaBadge`）、`BadgeStyle` /
//    `LanguageColor` / `RepoAvatarURL` / `Int.formattedShort` 已统一搬到
//    `Shared/Components/RepoRowComponents.swift`，与 Manage `RepoRowView` /
//    `RepoDetailView` 共享同一份定义。
//  - 仅 `TrendingPeriodBadge`（Trending 独有的 "+N 周期增长" 徽章）保留在本文件，
//    它不在 Manage / Detail 中使用，没有抽出的必要。
//
//  chip 排列顺序对齐 Manage Card：
//    Language → Stars → Forks（共享 MetaBadge）→ TrendingPeriod → Contributors
//  让两侧列表的"基础 chip 集"完全一致，Trending 独有的"+N + 贡献者"作为后缀附加。
//

import SwiftUI

// MARK: - Trending 独有 chip

/// Trending 周期增长徽章（"↗ +3086" 等）。
/// 只在 Trending 列表使用，不抽到 Shared/Components/RepoRowComponents.swift。
///
/// 抗压缩约定：内部 `Text` 加 `.lineLimit(1)`、外层加 `.fixedSize(horizontal: true)`，
/// 与共享 chip 保持一致行为。详见 `RepoRowComponents.swift` 顶部注释。
private struct TrendingPeriodBadge: View {
    let text: String
    let style: BadgeStyle

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "arrow.up.right")
                .font(.system(size: style == .full ? 10 : 9))
            Text(text)
                .font(style == .full ? .caption : .caption2)
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(.green)
        .padding(.horizontal, style == .full ? 7 : 0)
        .padding(.vertical, style == .full ? 3 : 0)
        .background {
            if style == .full {
                Capsule()
                    .fill(Color.green.opacity(0.12))
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - 入口

/// TrendingRepo 行视图入口：根据密度参数选子视图。
///
/// `isSelected` 由外层 `TrendingView` 的手写 selection（plain Button + selectedRepoID）
/// 驱动；不再依赖 `List(selection:)` 的系统蓝色高亮，避免与 Manage 列表视觉不一致。
struct TrendingRepoRowView: View {
    let repo: TrendingRepo
    let density: RepoListDensity
    let isSelected: Bool

    init(repo: TrendingRepo, density: RepoListDensity, isSelected: Bool = false) {
        self.repo = repo
        self.density = density
        self.isSelected = isSelected
    }

    var body: some View {
        // R-01 §3.1.1：仅 .card 单 case 保留。
        switch density {
        case .card: TrendingRepoRowCard(repo: repo, isSelected: isSelected)
        }
    }
}

// MARK: - Card

/// 卡片行：3-4 行高，包含描述、属性条、周期增长和贡献者。
struct TrendingRepoRowCard: View {
    let repo: TrendingRepo
    let isSelected: Bool

    var body: some View {
        TrendingRepoRowSurface(repo: repo, isSelected: isSelected, density: .card) {
            HStack(alignment: .center, spacing: 12) {
                RemoteAvatar(
                    urlString: RepoAvatarURL.from(owner: repo.owner),
                    size: 40
                )

                VStack(alignment: .leading, spacing: 5) {
                    Text(repo.fullName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let description = repo.description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    // chip 排列顺序与 Manage Card 完全对齐：
                    //   Language → Stars → Forks → TrendingPeriod
                    // Contributors 头像组在 2026-06-02 移到详情页 trendingContributorsSection
                    // （dong4j 反馈：窄宽度下贡献者头像会先被 List 水平裁剪，体验差；
                    // 详情页空间更宽裕，头像放大 + 可点击跳 GitHub profile 更有价值）。
                    HStack(spacing: 8) {
                        if let language = repo.language, !language.isEmpty {
                            LanguageBadge(language: language, style: .full)
                        }

                        StarsBadge(count: repo.starsCount, style: .full)

                        MetaBadge(
                            systemImage: "tuningfork",
                            text: repo.forksCount.formattedShort,
                            tint: .secondary
                        )

                        TrendingPeriodBadge(text: repo.periodText, style: .full)
                    }
                }

                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - 视觉容器

/// TrendingRepo 行的统一视觉容器。
///
/// 同步自 `RepoRowView.RepoRowSurface`，让 Manage / Trending 两份列表共用同一套
/// "选中态视觉语言"：语言色驱动的左侧 accent bar + 轻 accent 底 + 细 accent 边框，
/// 完全不依赖 macOS `List(selection:)` 的系统蓝色高亮。
///
/// 关键约束（与 Manage 一致，复制时不要回退）：
/// - 选中态由外部 `isSelected` 入参驱动，本视图不持有 selection 状态，便于 caller
///   用 plain Button + 手写 selectedRepoID 替代 `List(selection:)`。
/// - 普通态 / hover 态 / 选中态的 backgroundOpacity / borderOpacity 三档曲线必须与
///   `RepoRowSurface` 对齐，否则两边列表会出现细微视觉漂移。
/// - 选中态 `padding(.leading, 5)` 给 3pt 左侧 accent bar 让出绘制空间。
/// - 不在这里叠加 `DragGesture(minimumDistance: 0)` 做 pressed 反馈，外层 plain
///   Button 的点击事件已足够；引入零距离 drag 会抢走 List 行手势。
private struct TrendingRepoRowSurface<Content: View>: View {
    let repo: TrendingRepo
    let isSelected: Bool
    let density: RepoListDensity
    private let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    init(repo: TrendingRepo, isSelected: Bool, density: RepoListDensity, @ViewBuilder content: () -> Content) {
        self.repo = repo
        self.isSelected = isSelected
        self.density = density
        self.content = content()
    }

    private var accentColor: Color {
        if let language = repo.language, !language.isEmpty {
            return LanguageColor.color(for: language)
        }
        return .accentColor
    }

    private var cornerRadius: CGFloat {
        density == .card ? 10 : 8
    }

    private var verticalPadding: CGFloat {
        density == .card ? 8 : 4
    }

    private var horizontalPadding: CGFloat {
        density == .card ? 10 : 8
    }

    private var backgroundOpacity: Double {
        if isSelected { return 0.18 }
        if isHovered { return 0.08 }
        return density == .card ? 0.045 : 0.0
    }

    private var borderOpacity: Double {
        if isSelected { return 0.42 }
        if isHovered { return 0.18 }
        return density == .card ? 0.10 : 0.0
    }

    var body: some View {
        content
            .padding(.vertical, verticalPadding)
            .padding(.horizontal, horizontalPadding)
            .padding(.leading, isSelected ? 5 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(accentColor.opacity(backgroundOpacity))
                    .background {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(isSelected || isHovered ? 0.40 : 0.0))
                    }
            }
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(accentColor)
                    .frame(width: isSelected ? 3 : 0)
                    .padding(.vertical, 8)
                    .opacity(isSelected ? 1 : 0)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(accentColor.opacity(borderOpacity), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onHover { hovering in
                withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.14)) {
                    isHovered = hovering
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.82), value: isSelected)
    }
}
