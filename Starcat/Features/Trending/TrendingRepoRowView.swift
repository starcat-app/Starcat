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

import SwiftUI

// MARK: - 共享组件

private enum BadgeStyle {
    case compact, full
}

/// 语言徽章，带 GitHub 风格的小圆点。
private struct LanguageBadge: View {
    let language: String
    let style: BadgeStyle

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(LanguageColor.color(for: language))
                .frame(width: 8, height: 8)
            Text(language)
                .font(style == .full ? .caption : .caption2)
                .foregroundStyle(style == .full ? .primary : .secondary)
        }
        .padding(.horizontal, style == .full ? 7 : 0)
        .padding(.vertical, style == .full ? 3 : 0)
        .background {
            if style == .full {
                Capsule()
                    .fill(LanguageColor.color(for: language).opacity(0.13))
            }
        }
    }
}

/// stars 计数徽章。
private struct StarsBadge: View {
    let count: Int
    let style: BadgeStyle

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "star.fill")
                .font(.system(size: style == .full ? 10 : 9))
                .foregroundStyle(.yellow)
            Text(count.formattedShort)
                .font(style == .full ? .caption : .caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, style == .full ? 7 : 0)
        .padding(.vertical, style == .full ? 3 : 0)
        .background {
            if style == .full {
                Capsule()
                    .fill(.yellow.opacity(0.12))
            }
        }
    }
}

/// Trending 周期增长徽章。
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
    }
}

/// GitHub 主流语言色卡映射；未命中走 Gray。
private enum LanguageColor {
    static func color(for language: String) -> Color {
        switch language {
        case "Swift":        return Color(red: 0.94, green: 0.31, blue: 0.20)
        case "Objective-C":  return Color(red: 0.27, green: 0.50, blue: 0.92)
        case "Kotlin":       return Color(red: 0.62, green: 0.42, blue: 0.99)
        case "Java":         return Color(red: 0.69, green: 0.38, blue: 0.12)
        case "Go":           return Color(red: 0.00, green: 0.68, blue: 0.84)
        case "Rust":         return Color(red: 0.86, green: 0.41, blue: 0.27)
        case "Python":       return Color(red: 0.23, green: 0.46, blue: 0.69)
        case "JavaScript":   return Color(red: 0.94, green: 0.86, blue: 0.32)
        case "TypeScript":   return Color(red: 0.18, green: 0.46, blue: 0.78)
        case "C":            return Color(red: 0.33, green: 0.34, blue: 0.36)
        case "C++":          return Color(red: 0.95, green: 0.21, blue: 0.41)
        case "C#":           return Color(red: 0.10, green: 0.55, blue: 0.20)
        case "Ruby":         return Color(red: 0.84, green: 0.12, blue: 0.18)
        case "PHP":          return Color(red: 0.30, green: 0.34, blue: 0.59)
        case "Shell":        return Color(red: 0.55, green: 0.85, blue: 0.31)
        case "HTML":         return Color(red: 0.90, green: 0.32, blue: 0.13)
        case "CSS":          return Color(red: 0.34, green: 0.46, blue: 0.78)
        case "Vue":          return Color(red: 0.25, green: 0.72, blue: 0.51)
        case "Lua":          return Color(red: 0.00, green: 0.00, blue: 0.50)
        case "Dart":         return Color(red: 0.00, green: 0.71, blue: 0.83)
        case "R":            return Color(red: 0.12, green: 0.39, blue: 0.65)
        case "Scala":        return Color(red: 0.76, green: 0.20, blue: 0.16)
        case "Elixir":       return Color(red: 0.42, green: 0.30, blue: 0.51)
        case "Haskell":      return Color(red: 0.36, green: 0.41, blue: 0.66)
        case "Zig":          return Color(red: 0.94, green: 0.65, blue: 0.10)
        case "Solidity":     return Color(red: 0.67, green: 0.67, blue: 0.67)
        case "MDX":          return Color(red: 0.99, green: 0.66, blue: 0.32)
        case "Markdown":     return Color(red: 0.32, green: 0.32, blue: 0.32)
        case "Jupyter Notebook": return Color(red: 0.86, green: 0.49, blue: 0.16)
        case "Vim Script":   return Color(red: 0.10, green: 0.62, blue: 0.16)
        default:             return Color.gray.opacity(0.7)
        }
    }
}

/// owner login 转头像 URL。
private enum TrendingRepoAvatarURL {
    static func from(owner: String) -> String {
        "https://github.com/\(owner).png?size=80"
    }
}

/// 数字短格式格式化。
private extension Int {
    var formattedShort: String {
        let n = Double(self)
        if n >= 1_000_000 {
            return String(format: "%.1fM", n / 1_000_000)
        } else if n >= 10_000 {
            return "\(self / 1_000)k"
        } else if n >= 1_000 {
            return String(format: "%.1fk", n / 1_000)
        } else {
            return "\(self)"
        }
    }
}

// MARK: - 入口

/// TrendingRepo 行视图入口：根据密度参数选子视图。
struct TrendingRepoRowView: View {
    let repo: TrendingRepo
    let density: RepoListDensity

    var body: some View {
        switch density {
        case .compact: TrendingRepoRowCompact(repo: repo)
        case .card:    TrendingRepoRowCard(repo: repo)
        }
    }
}

// MARK: - Compact

/// 紧凑行：1 行高，扫读优先。
struct TrendingRepoRowCompact: View {
    let repo: TrendingRepo

    var body: some View {
        TrendingRepoRowSurface(repo: repo, density: .compact) {
            HStack(spacing: 10) {
                RemoteAvatar(
                    urlString: TrendingRepoAvatarURL.from(owner: repo.owner),
                    size: 22,
                    showBorder: false
                )

                Text(repo.fullName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                if let language = repo.language, !language.isEmpty {
                    LanguageBadge(language: language, style: .compact)
                }

                StarsBadge(count: repo.starsCount, style: .compact)

                TrendingPeriodBadge(text: repo.periodText, style: .compact)
            }
        }
    }
}

// MARK: - Card

/// 卡片行：3-4 行高，包含描述、属性条、周期增长和贡献者。
struct TrendingRepoRowCard: View {
    let repo: TrendingRepo

    var body: some View {
        TrendingRepoRowSurface(repo: repo, density: .card) {
            HStack(alignment: .center, spacing: 12) {
                RemoteAvatar(
                    urlString: TrendingRepoAvatarURL.from(owner: repo.owner),
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

                    HStack(spacing: 8) {
                        if let language = repo.language, !language.isEmpty {
                            LanguageBadge(language: language, style: .full)
                        }

                        StarsBadge(count: repo.starsCount, style: .full)

                        TrendingPeriodBadge(text: repo.periodText, style: .full)

                        // 贡献者头像（最多显示 3 个）
                        if !repo.contributors.isEmpty {
                            contributorsView
                        }
                    }
                }

                Spacer(minLength: 0)
            }
        }
    }

    /// 贡献者头像列表
    private var contributorsView: some View {
        HStack(spacing: -4) {
            ForEach(repo.contributors.prefix(3)) { contributor in
                AsyncImage(url: contributor.avatarURL) { image in
                    image
                        .resizable()
                        .scaledToFit()
                } placeholder: {
                    Circle()
                        .fill(Color.gray.opacity(0.3))
                }
                .frame(width: 16, height: 16)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(Color(NSColor.controlBackgroundColor).opacity(0.8), lineWidth: 1)
                )
            }

            if repo.contributors.count > 3 {
                Text("+\(repo.contributors.count - 3)")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
        }
    }
}

// MARK: - 视觉容器

/// TrendingRepo 行的统一视觉容器。
/// 同步自 RepoRowView.RepoRowSurface。
private struct TrendingRepoRowSurface<Content: View>: View {
    let repo: TrendingRepo
    let density: RepoListDensity
    private let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    init(repo: TrendingRepo, density: RepoListDensity, @ViewBuilder content: () -> Content) {
        self.repo = repo
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
        if isHovered { return 0.08 }
        return density == .card ? 0.045 : 0.0
    }

    private var borderOpacity: Double {
        if isHovered { return 0.18 }
        return density == .card ? 0.10 : 0.0
    }

    var body: some View {
        content
            .padding(.vertical, verticalPadding)
            .padding(.horizontal, horizontalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(accentColor.opacity(backgroundOpacity))
                    .background {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(isHovered ? 0.40 : 0.0))
                    }
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
    }
}
