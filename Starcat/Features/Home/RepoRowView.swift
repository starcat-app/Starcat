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

import SwiftUI

/// 行视图入口：根据密度参数选子视图。
/// caller 不需要关心密度切换逻辑。
struct RepoRowView: View {
    let repo: Repo
    let density: RepoListDensity
    let isSelected: Bool

    init(repo: Repo, density: RepoListDensity, isSelected: Bool = false) {
        self.repo = repo
        self.density = density
        self.isSelected = isSelected
    }

    var body: some View {
        switch density {
        case .compact: RepoRowCompact(repo: repo, isSelected: isSelected)
        case .card:    RepoRowCard(repo: repo, isSelected: isSelected)
        }
    }
}

// MARK: - Compact

/// 紧凑行：1 行高，扫读优先。
struct RepoRowCompact: View {
    let repo: Repo
    let isSelected: Bool

    var body: some View {
        RepoRowSurface(repo: repo, isSelected: isSelected, density: .compact) {
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

    var body: some View {
        RepoRowSurface(repo: repo, isSelected: isSelected, density: .card) {
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
                }
                Spacer(minLength: 0)
            }
        }
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
private struct RepoRowSurface<Content: View>: View {
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

/// 语言徽章，带 GitHub 风格的小圆点。
/// 颜色映射来自 https://github.com/ozh/github-colors（精简集）。
fileprivate struct LanguageBadge: View {
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
fileprivate struct StarsBadge: View {
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

/// 通用小型信息徽章，用于 fork / archived / forks count 等次要元数据。
fileprivate struct MetaBadge: View {
    let systemImage: String
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .medium))
            Text(text)
                .font(.caption2)
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

/// Archived 是本地化 key，用独立组件保留 `Text("repo.archived")` 的静态 key 形态，
/// 避免把本地化字符串先转成 `String` 后失去 SwiftUI 的自动提取语义。
fileprivate struct ArchivedBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "archivebox")
                .font(.system(size: 9, weight: .medium))
            Text("repo.archived")
                .font(.caption2)
                .lineLimit(1)
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.orange.opacity(0.12), in: Capsule())
    }
}

/// 相对时间徽章。单独抽出是为了后续统一替换为更完整的同步 / star 时间表达。
fileprivate struct RelativeDateBadge: View {
    let date: Date

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "clock")
                .font(.system(size: 9, weight: .medium))
            Text(date, style: .relative)
                .font(.caption2)
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.primary.opacity(0.06), in: Capsule())
    }
}

fileprivate enum BadgeStyle {
    case compact, full
}

// MARK: - 工具

/// owner login 转头像 URL。
/// GitHub 提供 `https://github.com/<login>.png` 的公开 302 重定向，无需 id 也能拿头像。
enum RepoAvatarURL {
    static func from(owner: String) -> String {
        "https://github.com/\(owner).png?size=80"
    }
}

/// GitHub 主流语言色卡映射；未命中走 Gray。
/// 精简集合，覆盖 stars 前 30 语言；未来可改为读 JSON 资源。
fileprivate enum LanguageColor {
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

// MARK: - 数字格式化

private extension Int {
    /// 短格式：`1234` → `"1.2k"`、`12345` → `"12k"`、`1234567` → `"1.2M"`。
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
