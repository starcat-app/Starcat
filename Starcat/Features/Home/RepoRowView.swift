//
//  RepoRowView.swift
//  Starcat
//
//  仓库列表行视图。
//
//  提供两种密度，由 AppSettings.listDensity 切换：
//  - compact：单行，name / lang / stars，扫读 + 列表里看更多条目
//  - card：多行，头像 + full_name + description + 属性条，信息更丰富
//
//  设计约束：
//  - 行视图只持有 hover / press 这类局部视觉状态，不参与业务数据流
//  - 头像 owner URL 不在 Repo 模型里（owner 只是字符串）；用 GitHub 约定 URL
//    https://avatars.githubusercontent.com/u/{user_id}?v=4 取不到（缺 owner.id），
//    所以用 https://github.com/{owner}.png 这个 GitHub 公开重定向作为头像源
//  - 时间字段 starred_at 是 ISO8601 字符串，转人类可读相对时间
//
//  共享组件（2026-06-02 Step 2 抽取）：
//  - chip 视图（`LanguageBadge` / `StarsBadge` / `MetaBadge` / `ArchivedBadge` /
//    `RelativeDateBadge`）、`BadgeStyle` / `LanguageColor` / `RepoAvatarURL` /
//    `Int.formattedShort` 已统一搬到 `Shared/Components/RepoRowComponents.swift`，
//    Manage / Trending / RepoDetailView 三处共享同一份定义，杜绝复制粘贴漂移。
//
//  当前文件只保留 row 视图本体和 `RepoRowSurface` 视觉容器；后者与
//  `TrendingRepoRowSurface` 仍有 90% 重复，登记为 D-17 技术债待后续抽象。
//

import SwiftUI

/// 行视图入口：根据密度参数选子视图。
/// caller 不需要关心密度切换逻辑。
struct RepoRowView: View {
    let repo: Repo
    let density: RepoListDensity
    let isSelected: Bool
    let semanticHit: SemanticSearchHit?

    init(repo: Repo, density: RepoListDensity, isSelected: Bool = false, semanticHit: SemanticSearchHit? = nil) {
        self.repo = repo
        self.density = density
        self.isSelected = isSelected
        self.semanticHit = semanticHit
    }

    var body: some View {
        switch density {
        case .compact: RepoRowCompact(repo: repo, isSelected: isSelected, semanticHit: semanticHit)
        case .card:    RepoRowCard(repo: repo, isSelected: isSelected, semanticHit: semanticHit)
        }
    }
}

// MARK: - Compact

/// 紧凑行：1 行高，扫读优先。
struct RepoRowCompact: View {
    let repo: Repo
    let isSelected: Bool
    let semanticHit: SemanticSearchHit?

    var body: some View {
        LegacyRepoRowSurface(repo: repo, isSelected: isSelected, density: .compact) {
            HStack(spacing: 10) {
                RemoteAvatar(urlString: RepoAvatarURL.from(owner: repo.owner), size: 22, showBorder: false)

                Text(repo.fullName)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                if let language = repo.language, !language.isEmpty {
                    LanguageBadge(language: language, style: .compact)
                }
                if let semanticHit {
                    SemanticScoreBadge(hit: semanticHit)
                }

                StarsBadge(count: repo.starsCount, style: .compact)
            }
        }
    }
}

// MARK: - Card

/// 卡片行：3-4 行高，包含描述、属性条。
struct RepoRowCard: View {
    let repo: Repo
    let isSelected: Bool
    let semanticHit: SemanticSearchHit?

    var body: some View {
        LegacyRepoRowSurface(repo: repo, isSelected: isSelected, density: .card) {
            HStack(alignment: .center, spacing: 12) {
                RemoteAvatar(urlString: RepoAvatarURL.from(owner: repo.owner), size: 40)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(repo.fullName)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if repo.isFork {
                            MetaBadge(systemImage: "tuningfork", text: "Fork", tint: .secondary)
                        }
                    }

                    if let description = repo.description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    HStack(spacing: 8) {
                        if let language = repo.language, !language.isEmpty {
                            LanguageBadge(language: language, style: .full)
                        }
                        StarsBadge(count: repo.starsCount, style: .full)
                        MetaBadge(systemImage: "tuningfork", text: repo.forksCount.formattedShort, tint: .secondary)
                        if repo.isArchived {
                            ArchivedBadge()
                        }
                        if let starredAt = repo.starredAt, let date = ISO8601DateFormatter.shared.date(from: starredAt) {
                            RelativeDateBadge(date: date)
                        }
                    }

                    if let semanticHit {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 10, weight: .semibold))
                            Text(semanticHit.reason)
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                            Text(Self.scoreText(semanticHit.score))
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private static func scoreText(_ score: Double) -> String {
        "\(Int((max(0, min(score, 1)) * 100).rounded()))%"
    }
}

// MARK: - 子组件

/// Repo 行的统一视觉容器。
///
/// 这里把 hover / selected 局部视觉状态限制在 row 内部，避免污染 HomeViewModel。
/// 选中态不依赖系统蓝色高亮，而是用语言色或 accent 生成左侧色条和轻背景，
/// 普通单选列表由外层 plain Button 写 selection；多选列表才保留 macOS List selection。
///
/// 注意：不要在这里叠加 `DragGesture(minimumDistance: 0)` 做 pressed 反馈。
/// macOS `List(selection:)` 的行点击依赖系统内部手势，零距离 drag 会抢事件，
/// 导致部分 repo 点击后不更新 selection，右侧详情无法打开。
/// R-01 过渡期遗留命名（原 `RepoRowSurface`）。Step 7.2 删除整个旧 row surface 后会一并删除本类型。
/// 临时改名是为了与 Shared/Components/RepoRowSurface.swift 中的新统一容器避免符号冲突。
private struct LegacyRepoRowSurface<Content: View>: View {
    let repo: Repo
    let isSelected: Bool
    let density: RepoListDensity
    private let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    init(repo: Repo, isSelected: Bool, density: RepoListDensity, @ViewBuilder content: () -> Content) {
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

// 共享 chip / 工具已搬到 Shared/Components/RepoRowComponents.swift。

private struct SemanticScoreBadge: View {
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
