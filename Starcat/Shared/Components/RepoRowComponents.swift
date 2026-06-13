//
//  RepoRowComponents.swift
//  Starcat
//
//  仓库列表行的共享 chip / 工具集合。
//
//  历史：本文件由 Step 2（2026-06-02）抽取自原先各自重复的 `Features/Home/RepoRowView.swift`
//  和 `Features/Trending/TrendingRepoRowView.swift`，以及 `Features/Home/RepoDetailView.swift`
//  内嵌的相同定义。统一后，Manage / Trending / Detail 三处共享一份 chip 视觉语言，
//  解决 dong4j 在 2026-06-02 反馈的"Trending 卡片 chip 与 Manage 不一致 + 窗口拖窄时
//  chip 变成竖立彩色胶囊"问题（详见 §7.4 同日变更日志）。
//
//  导出内容：
//  - `BadgeStyle`：紧凑 / 完整两档样式
//  - chip 视图：`LanguageBadge` / `StarsBadge` / `MetaBadge` / `ArchivedBadge` /
//    `RelativeDateBadge`（每个都强制 `.lineLimit(1)` + `.fixedSize(horizontal:)`)
//  - `LanguageColor`：GitHub 主流语言色卡映射
//  - `Int.formattedShort`：1234 → "1.2k" 短格式
//  - `RepoAvatarURL`：owner login 转头像 URL
//
//  关键约束（写新 chip 时必须遵守）：
//  - chip 内部 `Text` **必须**加 `.lineLimit(1)`，禁止竖向换行
//  - chip 视图最外层 **必须**加 `.fixedSize(horizontal: true, vertical: false)`，
//    保证 chip 维持自然宽度，宁可整行被 List 水平裁剪带走最后一个 chip，
//    也不让 chip 被压扁 / 拉高
//

import SwiftUI

// MARK: - BadgeStyle

/// chip 显示样式。
/// - `compact`：紧凑模式（单行高 row），只显示 icon + 文字，无 Capsule 背景
/// - `full`：完整模式（多行高 row 的属性条），icon + 文字 + 颜色化 Capsule 背景
public enum BadgeStyle {
    case compact
    case full
}

// MARK: - LanguageBadge

/// 编程语言徽章：GitHub 风格的小圆点 + 语言名。
/// 颜色映射来自 https://github.com/ozh/github-colors（精简集），未命中走 Gray。
public struct LanguageBadge: View {
    let language: String
    let style: BadgeStyle

    public init(language: String, style: BadgeStyle) {
        self.language = language
        self.style = style
    }

    public var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(LanguageColor.color(for: language))
                .frame(width: 8, height: 8)
            // 颜色查表（上一行 LanguageColor.color）必须传 raw 名，
            // 文字显示走短名（"Jupyter Notebook" → "Jupyter"），详见 LanguageDisplayName。
            Text(LanguageDisplayName.shortened(for: language))
                .font(style == .full ? .caption : .caption2)
                .foregroundStyle(style == .full ? .primary : .secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, style == .full ? 7 : 0)
        .padding(.vertical, style == .full ? 3 : 0)
        .background {
            if style == .full {
                Capsule()
                    .fill(LanguageColor.color(for: language).opacity(0.13))
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - StarsBadge

/// Stars 计数徽章。
public struct StarsBadge: View {
    let count: Int
    let style: BadgeStyle

    public init(count: Int, style: BadgeStyle) {
        self.count = count
        self.style = style
    }

    public var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "star.fill")
                .font(.system(size: style == .full ? 10 : 9))
                .foregroundStyle(.yellow)
            Text(count.formattedShort)
                .font(style == .full ? .caption : .caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, style == .full ? 7 : 0)
        .padding(.vertical, style == .full ? 3 : 0)
        .background {
            if style == .full {
                Capsule()
                    .fill(.yellow.opacity(0.12))
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - MetaBadge

/// 通用小型信息徽章。用于 fork count / tuningfork 等次要元数据。
/// 显示效果：icon + text，胶囊背景使用 `tint` 的 12% opacity。
public struct MetaBadge: View {
    let systemImage: String
    let text: String
    let tint: Color

    public init(systemImage: String, text: String, tint: Color) {
        self.systemImage = systemImage
        self.text = text
        self.tint = tint
    }

    public var body: some View {
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
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - ArchivedBadge

/// Archived 状态徽章。
///
/// 之所以单独抽出而不复用 `MetaBadge`：`repo.archived` 是本地化 key，需要保留
/// `Text("repo.archived")` 的静态字符串形态以便 SwiftUI / Xcode 自动提取本地化字符串。
/// 若改成 `MetaBadge(text: "repo.archived")`，参数类型是 `String`（非 `LocalizedStringKey`），
/// 字符串提取语义就会丢失。
///
/// `iconOnly`（2026-06-11 引入）：
/// - 设计动机：仓库**卡片**（UnifiedRepoRow）一行可能并排 4+ chip
///   （Language + Stars + Forks + Archived + sceneBadge），中等列宽下
///   "Archived" 文字会把整行挤换行（见 dong4j 截图反馈）。
/// - 仅 chip 文字消失，**保留** Capsule 背景 + 橙色 tint：用户对"archived
///   = 橙色"的色觉识别记忆要保住；同时无障碍语义不能丢，所以图标-only
///   模式仍然挂 `accessibilityLabel(Text("repo.archived"))`，VoiceOver
///   依旧能播报"已归档"。
/// - **关键边界**：默认 `iconOnly == false`，保证既有调用（活动详情面板
///   / 任何后续 detail-style 场景）不受影响 —— dong4j 明确要求"只是
///   repo 卡片，别给我把详情页里面的文字也删除了"。
/// - 详情页 hero 用的是另一个组件 `RepoBadgeChip`（与本组件平行），
///   不会被这里的改动波及。
public struct ArchivedBadge: View {
    let iconOnly: Bool

    public init(iconOnly: Bool = false) {
        self.iconOnly = iconOnly
    }

    public var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "archivebox")
                .font(.system(size: 9, weight: .medium))
            if !iconOnly {
                Text("repo.archived")
                    .font(.caption2)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.orange.opacity(0.12), in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("repo.archived"))
    }
}

// MARK: - RelativeDateBadge

/// 相对时间徽章。当前用于 starred_at 的"3 天前"等相对显示。
/// 后续若有更完整的同步 / star 时间表达，可统一替换。
public struct RelativeDateBadge: View {
    let date: Date

    public init(date: Date) {
        self.date = date
    }

    public var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "clock")
                .font(.system(size: 9, weight: .medium))
            Text(date, style: .relative)
                .font(.caption2)
                .lineLimit(1)
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.primary.opacity(0.06), in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - WebSourceBadge

/// 网页搜索类目徽章：globe icon + "Web"。
///
/// 设计意图：在搜索中心 reference 卡片的标题右侧，与 `LanguageBadge` 同档级
/// 显示，使得用户在 `.all` scope 下能一眼区分"这是网页结果"vs"这是仓库结果"。
///
/// 视觉系统：
/// - 蓝色 = "Web" 类目色（与 `RepoRowSurface(accentColor: .blue)` 同源）
/// - capsule + icon + 文字，与 LanguageBadge 完全同档
/// - 文字走 i18n key `search.web.badge`（en: "Web" / zh-Hans: "网页"）
public struct WebSourceBadge: View {
    public init() {}

    public var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "globe")
                .font(.system(size: 9, weight: .medium))
            Text("search.web.badge")
                .font(.caption2)
                .lineLimit(1)
        }
        .foregroundStyle(.blue)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.blue.opacity(0.12), in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - LanguageColor

/// GitHub 主流语言色卡映射；未命中走 Gray。
///
/// 精简集合，覆盖 stars 前 30 语言；未来可改为读 JSON 资源。
/// 颜色值来自 https://github.com/ozh/github-colors，与 GitHub 站内 language stats
/// 视觉保持一致，让用户在 Starcat 列表的色条 / 圆点和 GitHub 上看到的是同一种颜色。
public enum LanguageColor {
    public static func color(for language: String) -> Color {
        switch language {
        case "Swift":            return Color(red: 0.94, green: 0.31, blue: 0.20)
        case "Objective-C":      return Color(red: 0.27, green: 0.50, blue: 0.92)
        case "Kotlin":           return Color(red: 0.62, green: 0.42, blue: 0.99)
        case "Java":             return Color(red: 0.69, green: 0.38, blue: 0.12)
        case "Go":               return Color(red: 0.00, green: 0.68, blue: 0.84)
        case "Rust":             return Color(red: 0.86, green: 0.41, blue: 0.27)
        case "Python":           return Color(red: 0.23, green: 0.46, blue: 0.69)
        case "JavaScript":       return Color(red: 0.94, green: 0.86, blue: 0.32)
        case "TypeScript":       return Color(red: 0.18, green: 0.46, blue: 0.78)
        case "C":                return Color(red: 0.33, green: 0.34, blue: 0.36)
        case "C++":              return Color(red: 0.95, green: 0.21, blue: 0.41)
        case "C#":               return Color(red: 0.10, green: 0.55, blue: 0.20)
        case "Ruby":             return Color(red: 0.84, green: 0.12, blue: 0.18)
        case "PHP":              return Color(red: 0.30, green: 0.34, blue: 0.59)
        case "Shell":            return Color(red: 0.55, green: 0.85, blue: 0.31)
        case "HTML":             return Color(red: 0.90, green: 0.32, blue: 0.13)
        case "CSS":              return Color(red: 0.34, green: 0.46, blue: 0.78)
        case "Vue":              return Color(red: 0.25, green: 0.72, blue: 0.51)
        case "Lua":              return Color(red: 0.00, green: 0.00, blue: 0.50)
        case "Dart":             return Color(red: 0.00, green: 0.71, blue: 0.83)
        case "R":                return Color(red: 0.12, green: 0.39, blue: 0.65)
        case "Scala":            return Color(red: 0.76, green: 0.20, blue: 0.16)
        case "Elixir":           return Color(red: 0.42, green: 0.30, blue: 0.51)
        case "Haskell":          return Color(red: 0.36, green: 0.41, blue: 0.66)
        case "Zig":              return Color(red: 0.94, green: 0.65, blue: 0.10)
        case "Solidity":         return Color(red: 0.67, green: 0.67, blue: 0.67)
        case "MDX":              return Color(red: 0.99, green: 0.66, blue: 0.32)
        case "Markdown":         return Color(red: 0.32, green: 0.32, blue: 0.32)
        case "Jupyter Notebook": return Color(red: 0.86, green: 0.49, blue: 0.16)
        case "Vim Script":       return Color(red: 0.10, green: 0.62, blue: 0.16)
        default:                 return Color.gray.opacity(0.7)
        }
    }
}

// MARK: - RepoAvatarURL

/// owner login 转头像 URL。
///
/// GitHub 提供 `https://github.com/<login>.png` 的公开 302 重定向，无需 user id 也能拿头像；
/// 比 `https://avatars.githubusercontent.com/u/{id}` 更通用（拿不到 id 也能用）。
/// 加 `?size=80` 是为了提示 CDN 返回小图，减小列表头像加载流量。
public enum RepoAvatarURL {
    public static func from(owner: String) -> String {
        "https://github.com/\(owner).png?size=80"
    }
}

// MARK: - Int Formatting

public extension Int {
    /// 短格式：`1234` → `"1.2k"`、`12345` → `"12k"`、`1234567` → `"1.2M"`。
    /// 列表 chip 里宽度有限，统一用短格式避免 chip 撑得过长。
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

// MARK: - LanguageDisplayName

/// 编程语言 UI 显示短名映射（raw → short）。
///
/// 设计动机（dong4j 2026-06-11 反馈）：
/// GitHub Linguist 官方名如 "Jupyter Notebook" / "Visual Basic .NET" 在卡片 chip、
/// 侧边栏窄行、Trending / Weekly picker label 这些**横向受限**场景下，会被
/// SwiftUI 的 `.lineLimit(1) + .truncationMode(.tail)` 切成 "Jupyter Note…" /
/// "Visual Basic …" —— 比直接显示 "Jupyter" / "VB.NET" 还难看。
///
/// 关键约束（**写新代码 / 加新调用点必须遵守**）：
/// - **仅显示层用**。底层数据通道**绝对保留 raw 名**：
///     - GRDB `repos.language` 列 / 数据库查询 / sidebar `LanguageStat.language`
///     - GitHub API 请求 / 响应反序列化
///     - `LanguageColor.color(for:)` 颜色查表（switch case key 是 raw "Jupyter Notebook"）
///     - `LinguistLanguages.all` 元数据查询
///     - `LanguageIconView(language:)` 图标查表
///     - `RepoMetadataGradientBackground(language:)` 渐变背景
///     - AI prompt 拼接的 "Language: ..." 字段
///     - 分享卡 / Markdown / HTML 导出的 group key
///   一旦把短名落到这些通道，会跟 GitHub Linguist 规范名对不上，破坏数据一致性。
/// - 短名表是**保守白名单**，未命中一律 `default: return raw`，
///   不做模糊截断 / 启发式短化（避免误伤本身就短的名字）。
/// - i18n：短名都是英文专有名词（语言 / 框架名），不走 String Catalog；
///   未来如需本地化，把返回值改成 `LocalizedStringKey` 再适配调用点。
///
/// 当前白名单（dong4j 2026-06-11 确认）：
/// - Jupyter Notebook → Jupyter
/// - Vim Script       → Vim
/// - Emacs Lisp       → Elisp
/// - Visual Basic .NET → VB.NET
/// - Common Lisp      → Lisp
public enum LanguageDisplayName {
    /// 把 GitHub Linguist raw 名映射成 UI 显示短名；未命中原样返回。
    public static func shortened(for raw: String) -> String {
        switch raw {
        case "Jupyter Notebook":   return "Jupyter"
        case "Vim Script":         return "Vim"
        case "Emacs Lisp":         return "Elisp"
        case "Visual Basic .NET":  return "VB.NET"
        case "Common Lisp":        return "Lisp"
        default:                   return raw
        }
    }
}
