//
//  StarredMarkdownRenderer.swift
//  Starcat
//
//  HOM-174：把已 star 的 repo 列表渲染成一份 self-contained Markdown 文档。
//
//  设计目标：
//  - **可读性优先**：能直接贴到 GitHub README / Gist / Obsidian / 任何 Markdown 阅读器里，
//    不依赖任何 viewer 插件 / extension。
//  - **信息密度高**：把 Repo 表里能拿到的字段尽量都用上——description / language / stars /
//    forks / watchers / license / topics / homepage / 创建/更新/star 时间 / archived / fork
//    都体现在文档里，这样用户分享给别人时不只是个 URL 集合，是一份"我的技术阅读地图"。
//  - **结构清晰**：开头 overview → 语言 TOC → 按语言分组的 repo 列表。
//    阅读者可以从顶部跳到任意语言段，也可以顺序通读。
//  - **国际化**：文档正文一律英文（GitHub 用户群体跨语言，导出给海外朋友/上 Gist 用英文更通用）。
//
//  设计权衡：
//  - 不附加用户笔记 / 标签（v1）：保持 export 路径只读 `repos` 表，避免与
//    `RepoTagRepository` / `RepoNoteRepository` 耦合；用户笔记可能含个人/敏感信息，
//    显式让用户在 v2 决定要不要外露。如果后续要加，扩展 `Section` 的 builder 即可。
//  - Markdown 表格而非纯文本列表：`stars / forks / watchers / license / dates` 用一张表
//    展示，肉眼对比多个 repo 时更直观；表格在所有主流 Markdown 渲染器都支持。
//  - 不嵌图（README banner / avatar）：避免出网拉远端资源造成离线打不开。
//

import Foundation

/// 把 [Repo] 渲染为 Markdown 文档。无状态，所有方法都是 pure function。
enum StarredMarkdownRenderer {

    /// 主入口。
    /// - Parameters:
    ///   - repos: 待导出的 starred repos。**调用方**负责保证全部 `isStarred == true`，
    ///     本函数不再二次过滤（性能 + 单一职责）。
    ///   - user: 当前登录用户，用于文档顶部 hero 段。
    ///   - exportedAt: 导出时间戳，注入便于测试；默认 `Date()`。
    /// - Returns: 完整的 Markdown 文档字符串（UTF-8 友好，已包含末尾换行）。
    static func render(repos: [Repo], user: GitHubUserDTO, exportedAt: Date = Date()) -> String {
        var out: [String] = []

        out.append(buildHeader(repos: repos, user: user, exportedAt: exportedAt))
        out.append(buildOverview(repos: repos))
        out.append(buildLanguageTOC(repos: repos))
        out.append(buildLanguageSections(repos: repos))

        return out.joined(separator: "\n\n") + "\n"
    }

    // MARK: - Header（用户身份 + 导出元信息）

    /// 文档开头的 hero 段：标题、用户身份链接、bio、导出元信息。
    private static func buildHeader(repos: [Repo], user: GitHubUserDTO, exportedAt: Date) -> String {
        let displayName = (user.name?.isEmpty == false ? user.name! : user.login)
        let title = "# ⭐ Starred Repositories by \(escape(displayName))"

        var lines: [String] = [title, ""]

        // bio quote
        if let bio = user.bio?.trimmingCharacters(in: .whitespacesAndNewlines), !bio.isEmpty {
            lines.append("> \(escape(bio))")
            lines.append("")
        }

        // identity badges 行：login + 主页 + repos/followers/following 数字
        var idParts: [String] = []
        let profileURL = user.htmlUrl ?? "https://github.com/\(user.login)"
        idParts.append("**[@\(user.login)](\(profileURL))**")
        idParts.append("**\(repos.count)** repositories starred")
        if let followers = user.followers { idParts.append("**\(followers)** followers") }
        if let following = user.following { idParts.append("**\(following)** following") }
        lines.append(idParts.joined(separator: " · "))
        lines.append("")

        // bio meta：location / blog / email / twitter（任一存在才加，避免空行）
        var metaParts: [String] = []
        if let location = user.location?.nonEmpty { metaParts.append("📍 \(escape(location))") }
        if let company = user.company?.nonEmpty { metaParts.append("🏢 \(escape(company))") }
        if let blog = user.blog?.nonEmpty {
            let url = blog.hasPrefix("http") ? blog : "https://\(blog)"
            metaParts.append("🔗 [\(escape(blog))](\(url))")
        }
        if let email = user.email?.nonEmpty { metaParts.append("✉️ [\(escape(email))](mailto:\(email))") }
        if let twitter = user.twitterUsername?.nonEmpty { metaParts.append("🐦 [@\(twitter)](https://x.com/\(twitter))") }
        if !metaParts.isEmpty {
            lines.append(metaParts.joined(separator: " · "))
            lines.append("")
        }

        // 导出时间 + Powered by Starcat
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]
        let exportedISO = dateFormatter.string(from: exportedAt)
        lines.append("_Exported on `\(exportedISO)` by [Starcat](https://github.com/dong4j/Starcat) — a native macOS app to manage your GitHub stars._")

        lines.append("")
        lines.append("---")

        return lines.joined(separator: "\n")
    }

    // MARK: - Overview（统计摘要表）

    /// 全局摘要表：repo 总数 / 语言数 / 主语言 / 最受欢迎 / 最新 star 等关键指标。
    /// 让阅读者 10 秒内对这份 starred 列表有整体认知。
    private static func buildOverview(repos: [Repo]) -> String {
        guard !repos.isEmpty else { return "_(No starred repositories yet.)_" }

        var lines: [String] = ["## 📊 Overview", ""]

        // 关键指标表
        let langCount = Set(repos.compactMap { $0.language?.nonEmpty }).count
        let archived = repos.filter { $0.isArchived }.count
        let forks = repos.filter { $0.isFork }.count
        let withHomepage = repos.filter { ($0.homepage ?? "").trimmingCharacters(in: .whitespaces).isEmpty == false }.count
        let totalStars = repos.reduce(0) { $0 + $1.starsCount }
        let totalForks = repos.reduce(0) { $0 + $1.forksCount }

        let topByStars = repos.max(by: { $0.starsCount < $1.starsCount })
        let topByForks = repos.max(by: { $0.forksCount < $1.forksCount })
        let mostRecent = repos.compactMap { r -> (Repo, String)? in
            guard let s = r.starredAt else { return nil }
            return (r, s)
        }.max(by: { $0.1 < $1.1 })?.0
        let oldest = repos.compactMap { r -> (Repo, String)? in
            guard let c = r.createdAt else { return nil }
            return (r, c)
        }.min(by: { $0.1 < $1.1 })?.0

        lines.append("| Metric | Value |")
        lines.append("|---|---|")
        lines.append("| Total starred | **\(repos.count)** |")
        lines.append("| Unique languages | **\(langCount)** |")
        lines.append("| Total upstream stars | **\(totalStars.formattedWithSeparator())** |")
        lines.append("| Total upstream forks | **\(totalForks.formattedWithSeparator())** |")
        lines.append("| Archived | \(archived) |")
        lines.append("| Forks of other projects | \(forks) |")
        lines.append("| With homepage | \(withHomepage) |")
        if let topByStars {
            lines.append("| Most starred repo | [\(escape(topByStars.fullName))](\(topByStars.htmlUrl)) — \(topByStars.starsCount.formattedWithSeparator())★ |")
        }
        if let topByForks {
            lines.append("| Most forked repo | [\(escape(topByForks.fullName))](\(topByForks.htmlUrl)) — \(topByForks.forksCount.formattedWithSeparator()) forks |")
        }
        if let mostRecent {
            lines.append("| Most recently starred | [\(escape(mostRecent.fullName))](\(mostRecent.htmlUrl)) — `\(mostRecent.starredAt ?? "?")` |")
        }
        if let oldest {
            lines.append("| Oldest in collection | [\(escape(oldest.fullName))](\(oldest.htmlUrl)) — created `\(yearOnly(oldest.createdAt))` |")
        }
        lines.append("")

        // Top 语言
        let langDist = languageDistribution(repos)
        if !langDist.isEmpty {
            lines.append("### Top languages")
            lines.append("")
            lines.append("| Language | Repos | Share |")
            lines.append("|---|---:|---:|")
            for (lang, count) in langDist.prefix(10) {
                let pct = String(format: "%.1f%%", Double(count) / Double(repos.count) * 100)
                lines.append("| \(escape(lang)) | \(count) | \(pct) |")
            }
            lines.append("")
        }

        // Top topics
        let topicDist = topicDistribution(repos)
        if !topicDist.isEmpty {
            lines.append("### Top topics")
            lines.append("")
            lines.append(topicDist.prefix(20).map { "`\($0.0)` (\($0.1))" }.joined(separator: " · "))
            lines.append("")
        }

        lines.append("---")
        return lines.joined(separator: "\n")
    }

    // MARK: - Language TOC

    /// 按语言分组的快速跳转目录。
    private static func buildLanguageTOC(repos: [Repo]) -> String {
        let langDist = languageDistribution(repos)
        guard !langDist.isEmpty else { return "" }

        var lines: [String] = ["## 📚 Table of Contents", ""]
        let items = langDist.map { (lang, count) -> String in
            let anchor = anchorFor(language: lang)
            return "- [\(escape(lang)) (\(count))](#\(anchor))"
        }
        lines.append(contentsOf: items)
        lines.append("")
        lines.append("---")
        return lines.joined(separator: "\n")
    }

    // MARK: - 语言分组 + repo 详情

    /// 按语言分组渲染每个 repo。语言段顺序与 TOC 完全一致（按 count 倒序）。
    /// 语言段内部按 stars 倒序排（让"重磅项目"出现在每段开头，便于扫读）。
    private static func buildLanguageSections(repos: [Repo]) -> String {
        let langDist = languageDistribution(repos)
        guard !langDist.isEmpty else { return "" }

        var sections: [String] = []

        for (lang, _) in langDist {
            let group = repos.filter { ($0.language?.nonEmpty ?? "Other") == lang }
                .sorted { $0.starsCount > $1.starsCount }

            var section: [String] = []
            section.append("## \(languageEmoji(lang)) \(escape(lang))")
            section.append("")
            section.append("_\(group.count) repositor\(group.count == 1 ? "y" : "ies")_")
            section.append("")

            for repo in group {
                section.append(renderRepo(repo))
            }

            sections.append(section.joined(separator: "\n"))
        }

        return sections.joined(separator: "\n\n---\n\n")
    }

    /// 单个 repo 的 Markdown 片段。
    /// 排版：标题 + 描述 quote + 元数据表 + topics 行 + 链接行 + 状态徽章。
    private static func renderRepo(_ repo: Repo) -> String {
        var lines: [String] = []

        // 标题：[owner/name](url)
        lines.append("### [\(escape(repo.fullName))](\(repo.htmlUrl))")
        lines.append("")

        // 描述 quote
        if let desc = repo.description?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
            lines.append("> \(escape(desc))")
            lines.append("")
        }

        // 元数据表（紧凑型）
        lines.append("| ⭐ Stars | 🍴 Forks | 👁 Watchers | License | Last push | Starred at |")
        lines.append("|---:|---:|---:|---|---|---|")
        lines.append("| \(repo.starsCount.formattedWithSeparator()) | \(repo.forksCount.formattedWithSeparator()) | \(repo.watchersCount.formattedWithSeparator()) | \(repo.license?.nonEmpty ?? "—") | \(dateOnly(repo.pushedAt)) | \(dateOnly(repo.starredAt)) |")
        lines.append("")

        // Topics
        let topics = repo.topicsArray
        if !topics.isEmpty {
            lines.append("**Topics:** " + topics.map { "`\($0)`" }.joined(separator: " "))
            lines.append("")
        }

        // 附加链接 / 状态
        var meta: [String] = []
        if let homepage = repo.homepage?.nonEmpty {
            let url = homepage.hasPrefix("http") ? homepage : "https://\(homepage)"
            meta.append("🏠 [\(escape(homepage))](\(url))")
        }
        if repo.isArchived { meta.append("🗄 Archived") }
        if repo.isFork { meta.append("🍴 Fork") }
        if repo.isPrivate { meta.append("🔒 Private") }
        if !meta.isEmpty {
            lines.append(meta.joined(separator: " · "))
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// 按出现频率倒序返回 `[(语言, 数量)]`。无语言（GitHub 上没有主语言）的 repo 归入 `Other`。
    private static func languageDistribution(_ repos: [Repo]) -> [(String, Int)] {
        var counts: [String: Int] = [:]
        for repo in repos {
            let key = repo.language?.nonEmpty ?? "Other"
            counts[key, default: 0] += 1
        }
        return counts.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }.map { ($0.key, $0.value) }
    }

    /// 所有 repo 的 topics 出现频次倒序。
    private static func topicDistribution(_ repos: [Repo]) -> [(String, Int)] {
        var counts: [String: Int] = [:]
        for repo in repos {
            for topic in repo.topicsArray {
                counts[topic, default: 0] += 1
            }
        }
        return counts.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }.map { ($0.key, $0.value) }
    }

    /// 语言名 → Markdown anchor。GitHub 风格：lowercased, 非字母数字替换为 `-`。
    /// 例如 `C++` → `c`（GitHub 把 `+` 去掉，与官方 anchor 行为一致）。
    private static func anchorFor(language: String) -> String {
        let lowered = language.lowercased()
        var result = ""
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                result.append(ch)
            } else if ch == " " || ch == "-" {
                result.append("-")
            }
            // 其他符号丢弃（`+`、`#`、`.` 等），与 GitHub anchor 行为对齐
        }
        return result
    }

    /// 语言主题 emoji。命中映射的语言显示带色 emoji，未命中显示通用 📦。
    /// 不是 anchor 用，仅用于段落标题视觉锚点。
    private static func languageEmoji(_ language: String) -> String {
        switch language.lowercased() {
        case "swift": return "🟧"
        case "objective-c": return "🟦"
        case "javascript": return "🟨"
        case "typescript": return "🟦"
        case "python": return "🐍"
        case "ruby": return "💎"
        case "go": return "🐹"
        case "rust": return "🦀"
        case "java": return "☕️"
        case "kotlin": return "🟪"
        case "c", "c++", "cpp": return "🔧"
        case "c#": return "🟩"
        case "shell", "bash": return "🐚"
        case "html": return "🌐"
        case "css", "scss": return "🎨"
        case "vue": return "💚"
        case "dart": return "🎯"
        case "php": return "🐘"
        case "lua": return "🌙"
        case "other": return "📦"
        default: return "💻"
        }
    }

    /// ISO8601 字符串 → `YYYY-MM-DD`。解析失败 / nil 返回 `—`。
    private static func dateOnly(_ iso: String?) -> String {
        guard let iso, !iso.isEmpty else { return "—" }
        // GitHub 的时间格式形如 `2026-05-12T08:23:11Z`；截 10 字符即日期段
        return String(iso.prefix(10))
    }

    /// ISO8601 字符串 → 年份。失败返回 `?`。
    private static func yearOnly(_ iso: String?) -> String {
        guard let iso, iso.count >= 4 else { return "?" }
        return String(iso.prefix(4))
    }

    /// 转义 Markdown 元字符：管道 `|`（会破坏表格列）、反引号 `` ` ``（行内代码）。
    /// 其他 Markdown 字符在引用 / 标题 / 链接里被吞掉的概率低，不做过度转义以保留可读性。
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "\\|")
         .replacingOccurrences(of: "`", with: "\\`")
         .replacingOccurrences(of: "\n", with: " ")
    }
}

// MARK: - 小工具

private extension String {
    /// 去掉两端空白后非空的字符串；否则 nil。
    var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

private extension Int {
    /// `1234567` → `1,234,567`。Locale 用 POSIX 确保导出文档跨地区一致（不会出现中文千位分隔符变体）。
    func formattedWithSeparator() -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: self)) ?? "\(self)"
    }
}
