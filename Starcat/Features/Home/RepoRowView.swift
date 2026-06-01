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
//  - 行视图本身无状态，纯函数式渲染
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

    var body: some View {
        switch density {
        case .compact: RepoRowCompact(repo: repo)
        case .card:    RepoRowCard(repo: repo)
        }
    }
}

// MARK: - Compact

/// 紧凑行：1 行高，扫读优先。
struct RepoRowCompact: View {
    let repo: Repo

    var body: some View {
        HStack(spacing: 10) {
            RemoteAvatar(urlString: RepoAvatarURL.from(owner: repo.owner), size: 22, showBorder: false)

            Text(repo.fullName)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if let language = repo.language, !language.isEmpty {
                LanguageBadge(language: language, style: .compact)
            }

            StarsBadge(count: repo.starsCount, style: .compact)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// MARK: - Card

/// 卡片行：3-4 行高，包含描述、属性条。
struct RepoRowCard: View {
    let repo: Repo

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            RemoteAvatar(urlString: RepoAvatarURL.from(owner: repo.owner), size: 40)

            VStack(alignment: .leading, spacing: 4) {
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
                    if repo.isArchived {
                        Text("repo.archived")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.orange.opacity(0.15), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                    if let starredAt = repo.starredAt, let date = ISO8601DateFormatter.shared.date(from: starredAt) {
                        Text(date, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

// MARK: - 子组件

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
                .foregroundStyle(.secondary)
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
