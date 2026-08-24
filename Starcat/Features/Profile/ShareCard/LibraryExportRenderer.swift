//
//  LibraryExportRenderer.swift
//  Starcat
//
//  PR-9：Starcat 私有知识库文件导出渲染器。
//
//  模块职责：
//  - 把 `libraryState == .inLibrary` 的 repo 渲染为独立 Markdown / HTML 文档；
//  - 展示知识库专属字段：状态、标签、私有笔记、是否 GitHub starred、library_updated_at；
//  - 只消费本地已有缓存与用户数据，不触发 README / AI / Health / OpenSSF 等远程刷新。
//

import Foundation

/// 知识库导出需要的附加数据。
///
/// 这些字段来自 repo 之外的用户私有表或缓存表。它们集中在一个结构里，是为了让 renderer
/// 保持纯函数：导出前由 `StarredExporter` 负责读取，renderer 只管格式化。
struct LibraryExportSupplements {
    var aiSummaries: [Int64: String]
    var repoTags: [Int64: [String]]
    var notes: [Int64: String]
    var statuses: [Int64: RepoStatus]
    var libraryUpdatedAt: [Int64: String]
    var readmeExcerpts: [Int64: String]
    var healthSnapshots: [Int64: RepoHealthSnapshot]
    var openSSFScores: [Int64: OpenSSFScoreRecord]
    var avatarDataURI: String?
    var ownerAvatars: [String: String]

    static let empty = LibraryExportSupplements(
        aiSummaries: [:],
        repoTags: [:],
        notes: [:],
        statuses: [:],
        libraryUpdatedAt: [:],
        readmeExcerpts: [:],
        healthSnapshots: [:],
        openSSFScores: [:],
        avatarDataURI: nil,
        ownerAvatars: [:]
    )
}

/// 把知识库 repo 渲染为 Markdown 文档。输出面向归档和二次编辑，优先保持文本可读。
enum LibraryMarkdownRenderer {

    static func render(
        repos: [Repo],
        user: GitHubUserDTO,
        exportedAt: Date = Date(),
        supplements: LibraryExportSupplements = .empty,
        includeAttribution: Bool = true
    ) -> String {
        var out: [String] = []
        out.append(buildHeader(repos: repos, user: user, exportedAt: exportedAt))
        out.append(buildOverview(repos: repos, supplements: supplements))
        out.append(buildRepoEntries(repos: repos, supplements: supplements))
        if includeAttribution {
            out.append(attributionFooter)
        }
        return out.joined(separator: "\n\n") + "\n"
    }

    private static func buildHeader(repos: [Repo], user: GitHubUserDTO, exportedAt: Date) -> String {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]
        let exportedISO = dateFormatter.string(from: exportedAt)
        let displayName = nonEmpty(user.name) ?? user.login

        return """
        # Starcat Knowledge Library

        **[@\(escape(user.login))](\(user.htmlUrl ?? "https://github.com/\(user.login)"))** · \(escape(displayName)) · **\(repos.count)** repos

        _Exported on `\(exportedISO)` with Starcat. This file represents your private Starcat library, not your GitHub Starred list._

        ---
        """
    }

    /// 默认附带、可由导出菜单关闭的开源归因。
    private static var attributionFooter: String {
        "---\n\nMade with [Starcat](\(AppWebsiteLinks.sourceRepository.absoluteString)) · Open source on GitHub"
    }

    private static func buildOverview(repos: [Repo], supplements: LibraryExportSupplements) -> String {
        guard !repos.isEmpty else { return "_(No repositories in your Starcat library yet.)_" }
        let languages = languageDistribution(repos)
        let statusCounts = statusDistribution(repos: repos, supplements: supplements)
        let mainLanguage = languages.first?.0 ?? "Other"

        var lines: [String] = ["## Overview", ""]
        lines.append("| Metric | Value |")
        lines.append("|---|---|")
        lines.append("| Total library repos | **\(repos.count)** |")
        lines.append("| Main language | **\(escape(mainLanguage))** |")
        lines.append("| Unique languages | **\(languages.count)** |")
        lines.append("| GitHub starred too | **\(repos.filter { $0.isStarred }.count)** |")
        lines.append("| With notes | **\(supplements.notes.count)** |")
        lines.append("")
        lines.append("### Status distribution")
        lines.append("")
        lines.append("| Status | Repos |")
        lines.append("|---|---:|")
        for status in RepoStatus.allCases {
            lines.append("| \(englishStatus(status)) | \(statusCounts[status, default: 0]) |")
        }
        lines.append("")
        lines.append("### Top languages")
        lines.append("")
        lines.append("| Language | Repos |")
        lines.append("|---|---:|")
        for (language, count) in languages.prefix(10) {
            lines.append("| \(escape(language)) | \(count) |")
        }
        lines.append("")
        lines.append("---")
        return lines.joined(separator: "\n")
    }

    private static func buildRepoEntries(repos: [Repo], supplements: LibraryExportSupplements) -> String {
        guard !repos.isEmpty else { return "" }
        var lines: [String] = ["## Repositories", ""]
        for repo in repos {
            let status = supplements.statuses[repo.id] ?? .unread
            let tags = supplements.repoTags[repo.id, default: []]
            let notes = supplements.notes[repo.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let aiSummary = supplements.aiSummaries[repo.id]?.trimmingCharacters(in: .whitespacesAndNewlines)

            lines.append("### [\(escape(repo.fullName))](\(repo.htmlUrl))")
            if let description = nonEmpty(repo.description) {
                lines.append("")
                lines.append(escape(description))
            }
            lines.append("")
            lines.append("- Owner/name: `\(escape(repo.owner))/\(escape(repo.name))`")
            lines.append("- Language: \(escape(nonEmpty(repo.language) ?? "Other"))")
            lines.append("- Status: \(englishStatus(status))")
            lines.append("- GitHub starred: \(repo.isStarred ? "yes" : "no")")
            lines.append("- Library updated: `\(escape(supplements.libraryUpdatedAt[repo.id] ?? "unknown"))`")
            if !tags.isEmpty {
                lines.append("- Tags: \(tags.map { "`\(escape($0))`" }.joined(separator: " "))")
            }
            if let notes, !notes.isEmpty {
                lines.append("")
                lines.append("#### Notes")
                lines.append("")
                lines.append(escape(notes))
            }
            if let aiSummary, !aiSummary.isEmpty {
                lines.append("")
                lines.append("#### Cached AI Summary")
                lines.append("")
                lines.append(escape(aiSummary))
            }
            if let readme = supplements.readmeExcerpts[repo.id] {
                lines.append("")
                lines.append("#### Cached README Excerpt")
                lines.append("")
                lines.append(escape(readme))
            }
            if let health = supplements.healthSnapshots[repo.id] {
                lines.append("")
                lines.append("#### Cached Repo Health")
                lines.append("")
                lines.append("- Grade: \(escape(health.grade))")
                lines.append("- Score: \(health.overallScore)")
            }
            if let score = supplements.openSSFScores[repo.id] {
                lines.append("")
                lines.append("#### Cached OpenSSF Scorecard")
                lines.append("")
                if let aggregate = score.aggregateScore {
                    lines.append("- Score: \(String(format: "%.1f", aggregate))")
                }
                lines.append("- Status: \(escape(score.fetchStatus.rawValue))")
            }
            lines.append("")
            lines.append("---")
        }
        return lines.joined(separator: "\n")
    }

    private static func languageDistribution(_ repos: [Repo]) -> [(String, Int)] {
        Dictionary(grouping: repos) { repo in nonEmpty(repo.language) ?? "Other" }
            .map { ($0.key, $0.value.count) }
            .sorted { lhs, rhs in lhs.1 == rhs.1 ? lhs.0 < rhs.0 : lhs.1 > rhs.1 }
    }

    private static func statusDistribution(
        repos: [Repo],
        supplements: LibraryExportSupplements
    ) -> [RepoStatus: Int] {
        var result: [RepoStatus: Int] = [:]
        for repo in repos {
            result[supplements.statuses[repo.id] ?? .unread, default: 0] += 1
        }
        return result
    }

    private static func englishStatus(_ status: RepoStatus) -> String {
        switch status {
        case .unread: return "Unread"
        case .read: return "Read"
        case .using: return "Using"
        }
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
    }
}

/// 把知识库 repo 渲染为自包含 HTML。相比 Starred HTML 的搜索/排序工具型页面，这里强调
/// “个人知识库档案”：overview、状态分布、逐仓库笔记和缓存摘要直接展开，便于离线阅读。
enum LibraryHTMLRenderer {

    private static var starcatWebsiteURL: String {
        AppWebsiteLinks.current.home.absoluteString
    }

    static func render(
        repos: [Repo],
        user: GitHubUserDTO,
        exportedAt: Date = Date(),
        supplements: LibraryExportSupplements = .empty,
        includeAttribution: Bool = true
    ) -> String {
        let displayName = nonEmpty(user.name) ?? user.login
        let title = "\(htmlEscape(displayName))'s Starcat Library"
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <title>\(title)</title>
          <meta name="generator" content="Starcat (\(starcatWebsiteURL))">
          <style>\(stylesheet())</style>
        </head>
        <body>
          <main class="shell">
            \(hero(repos: repos, user: user, exportedAt: exportedAt, supplements: supplements))
            \(overview(repos: repos, supplements: supplements))
            \(repoGrid(repos: repos, supplements: supplements))
            \(attributionFooter(includeAttribution: includeAttribution))
          </main>
        </body>
        </html>
        """
    }

    private static func attributionFooter(includeAttribution: Bool) -> String {
        guard includeAttribution else { return "" }
        return """
        <footer class="attribution">
          Made with <a href="\(AppWebsiteLinks.sourceRepository.absoluteString)" target="_blank" rel="noopener">Starcat</a>
          · Open source on GitHub
        </footer>
        """
    }

    private static func hero(
        repos: [Repo],
        user: GitHubUserDTO,
        exportedAt: Date,
        supplements: LibraryExportSupplements
    ) -> String {
        let displayName = nonEmpty(user.name) ?? user.login
        let profileURL = user.htmlUrl ?? "https://github.com/\(user.login)"
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]
        let exportedISO = dateFormatter.string(from: exportedAt)
        let avatar: String
        if let avatarDataURI = supplements.avatarDataURI {
            avatar = "<img src=\"\(htmlEscape(avatarDataURI))\" alt=\"\(htmlEscape(displayName))\">"
        } else {
            avatar = "<span>\(htmlEscape(String(displayName.prefix(2)).uppercased()))</span>"
        }

        return """
        <header class="hero">
          <a class="avatar" href="\(htmlEscape(profileURL))" target="_blank" rel="noopener">\(avatar)</a>
          <div>
            <p class="eyebrow">Starcat Knowledge Library</p>
            <h1>\(htmlEscape(displayName))'s Library</h1>
            <p class="subtitle">@\(htmlEscape(user.login)) · \(repos.count.formattedWithSeparator()) repos · exported <time datetime="\(exportedISO)">\(exportedISO)</time></p>
            <p class="note">This export is your private Starcat library, not your GitHub Starred list.</p>
          </div>
        </header>
        """
    }

    private static func overview(repos: [Repo], supplements: LibraryExportSupplements) -> String {
        let languages = languageDistribution(repos)
        let mainLanguage = languages.first?.0 ?? "Other"
        let statusCounts = statusDistribution(repos: repos, supplements: supplements)
        let statusText = RepoStatus.allCases
            .map { "\(englishStatus($0)): \(statusCounts[$0, default: 0])" }
            .joined(separator: " · ")
        let topLanguages = languages.prefix(8)
            .map { "<span class=\"chip\">\(htmlEscape($0.0)) <b>\($0.1)</b></span>" }
            .joined()

        return """
        <section class="overview">
          <div class="metric"><span>Total</span><strong>\(repos.count.formattedWithSeparator())</strong></div>
          <div class="metric"><span>Main language</span><strong>\(htmlEscape(mainLanguage))</strong></div>
          <div class="metric"><span>GitHub starred too</span><strong>\(repos.filter { $0.isStarred }.count.formattedWithSeparator())</strong></div>
          <div class="metric"><span>With notes</span><strong>\(supplements.notes.count.formattedWithSeparator())</strong></div>
          <div class="wide">
            <h2>Status distribution</h2>
            <p>\(htmlEscape(statusText))</p>
          </div>
          <div class="wide">
            <h2>Top languages</h2>
            <div class="chips">\(topLanguages)</div>
          </div>
        </section>
        """
    }

    private static func repoGrid(repos: [Repo], supplements: LibraryExportSupplements) -> String {
        guard !repos.isEmpty else {
            return "<section class=\"empty\">No repositories in your Starcat library yet.</section>"
        }
        let cards = repos.map { repoCard(repo: $0, supplements: supplements) }.joined(separator: "\n")
        return """
        <section class="repos">
          <h2>Repositories</h2>
          <div class="repo-grid">
            \(cards)
          </div>
        </section>
        """
    }

    private static func repoCard(repo: Repo, supplements: LibraryExportSupplements) -> String {
        let status = supplements.statuses[repo.id] ?? .unread
        let tags = supplements.repoTags[repo.id, default: []]
        let notes = supplements.notes[repo.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let aiSummary = supplements.aiSummaries[repo.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let readme = supplements.readmeExcerpts[repo.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let health = supplements.healthSnapshots[repo.id]
        let openSSF = supplements.openSSFScores[repo.id]
        let ownerAvatar = supplements.ownerAvatars[repo.owner]
        let logo: String
        if let ownerAvatar {
            logo = "<img src=\"\(htmlEscape(ownerAvatar))\" alt=\"\(htmlEscape(repo.owner))\">"
        } else {
            logo = "<span>\(htmlEscape(String(repo.owner.prefix(1)).uppercased()))</span>"
        }

        let tagHTML = tags.isEmpty
            ? "<span class=\"muted\">No tags</span>"
            : tags.map { "<span class=\"tag\">\(htmlEscape($0))</span>" }.joined()
        let notesHTML = (notes?.isEmpty == false)
            ? markdownBlock(title: "Notes", markdown: notes!)
            : ""
        let aiHTML = (aiSummary?.isEmpty == false)
            ? markdownBlock(title: "Cached AI Summary", markdown: aiSummary!)
            : ""
        let readmeHTML = (readme?.isEmpty == false)
            ? markdownBlock(title: "Cached README Excerpt", markdown: readme!)
            : ""
        let healthHTML = health.map {
            "<section class=\"block\"><h3>Cached Repo Health</h3><p>Grade \(htmlEscape($0.grade)) · Score \(String(format: "%.1f", $0.overallScore))</p></section>"
        } ?? ""
        let openSSFHTML = openSSF.map { record -> String in
            let scoreText = record.aggregateScore.map { String(format: "%.1f", $0) } ?? "unavailable"
            return "<section class=\"block\"><h3>Cached OpenSSF Scorecard</h3><p>Score \(scoreText) · Status \(htmlEscape(record.fetchStatus.rawValue))</p></section>"
        } ?? ""

        return """
        <article class="repo-card">
          <div class="repo-head">
            <div class="repo-logo">\(logo)</div>
            <div>
              <a class="repo-name" href="\(htmlEscape(repo.htmlUrl))" target="_blank" rel="noopener">\(htmlEscape(repo.fullName))</a>
              <p class="repo-desc">\(htmlEscape(nonEmpty(repo.description) ?? "No description"))</p>
            </div>
          </div>
          <dl class="facts">
            <div><dt>Owner/name</dt><dd>\(htmlEscape(repo.owner))/\(htmlEscape(repo.name))</dd></div>
            <div><dt>Language</dt><dd>\(htmlEscape(nonEmpty(repo.language) ?? "Other"))</dd></div>
            <div><dt>Status</dt><dd>\(englishStatus(status))</dd></div>
            <div><dt>GitHub starred</dt><dd>\(repo.isStarred ? "Yes" : "No")</dd></div>
            <div><dt>Library updated</dt><dd>\(htmlEscape(supplements.libraryUpdatedAt[repo.id] ?? "unknown"))</dd></div>
          </dl>
          <div class="tags">\(tagHTML)</div>
          \(notesHTML)
          \(aiHTML)
          \(readmeHTML)
          \(healthHTML)
          \(openSSFHTML)
        </article>
        """
    }

    private static func markdownBlock(title: String, markdown: String) -> String {
        """
        <section class="block">
          <h3>\(htmlEscape(title))</h3>
          <div class="markdown-body">\(renderMarkdown(markdown))</div>
        </section>
        """
    }

    /// 知识库 HTML 是离线单文件导出，不能依赖运行时 WebView 或外部 JS 库。
    /// 这里采用和 Starred HTML 同口径的安全子集：先 escape 原文，再只恢复明确支持的
    /// Markdown 结构，避免用户笔记/README 片段里的 HTML 形成可执行内容。
    private static func renderMarkdown(_ markdown: String) -> String {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var output: [String] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if let language = fencedCodeLanguage(trimmed) {
                var buffer: [String] = []
                index += 1
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    buffer.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                output.append("<pre><code class=\"lang-\(htmlEscape(language))\">\(htmlEscape(buffer.joined(separator: "\n")))</code></pre>")
                continue
            }

            if let heading = headingHTML(for: trimmed) {
                output.append(heading)
                index += 1
                continue
            }

            if isHorizontalRule(trimmed) {
                output.append("<hr>")
                index += 1
                continue
            }

            if unorderedListItem(trimmed) != nil {
                var items: [String] = []
                while index < lines.count,
                      let item = unorderedListItem(lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append("<li>\(processInlineMarkdown(item))</li>")
                    index += 1
                }
                output.append("<ul>\(items.joined())</ul>")
                continue
            }

            if orderedListItem(trimmed) != nil {
                var items: [String] = []
                while index < lines.count,
                      let item = orderedListItem(lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append("<li>\(processInlineMarkdown(item))</li>")
                    index += 1
                }
                output.append("<ol>\(items.joined())</ol>")
                continue
            }

            var paragraph = [trimmed]
            index += 1
            while index < lines.count {
                let next = lines[index].trimmingCharacters(in: .whitespaces)
                if next.isEmpty
                    || fencedCodeLanguage(next) != nil
                    || headingHTML(for: next) != nil
                    || isHorizontalRule(next)
                    || unorderedListItem(next) != nil
                    || orderedListItem(next) != nil {
                    break
                }
                paragraph.append(next)
                index += 1
            }
            output.append("<p>\(processInlineMarkdown(paragraph.joined(separator: " ")))</p>")
        }

        return output.joined(separator: "\n")
    }

    private static func fencedCodeLanguage(_ line: String) -> String? {
        guard line.hasPrefix("```") else { return nil }
        return String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
    }

    private static func headingHTML(for line: String) -> String? {
        guard line.hasPrefix("#") else { return nil }
        let markerCount = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(markerCount),
              line.dropFirst(markerCount).first == " " else {
            return nil
        }
        let title = line.dropFirst(markerCount).trimmingCharacters(in: .whitespaces)
        return "<h\(markerCount)>\(processInlineMarkdown(title))</h\(markerCount)>"
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        line == "---" || line == "***" || line == "___"
    }

    private static func unorderedListItem(_ line: String) -> String? {
        guard line.count > 2 else { return nil }
        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            return String(line.dropFirst(2))
        }
        return nil
    }

    private static func orderedListItem(_ line: String) -> String? {
        guard let dotIndex = line.firstIndex(of: ".") else { return nil }
        let prefix = line[..<dotIndex]
        let afterDot = line.index(after: dotIndex)
        guard !prefix.isEmpty,
              prefix.allSatisfy(\.isNumber),
              afterDot < line.endIndex,
              line[afterDot] == " " else {
            return nil
        }
        return String(line[line.index(after: afterDot)...])
    }

    private static func processInlineMarkdown(_ raw: String) -> String {
        var value = htmlEscape(raw)
        value = replaceRegex(#"`([^`\n]+)`"#, in: value) { match in
            "<code>\(match[1])</code>"
        }
        value = replaceRegex(#"\*\*([^*\n]+)\*\*"#, in: value) { match in
            "<strong>\(match[1])</strong>"
        }
        value = replaceRegex(#"(^|[^*])\*([^*\n]+)\*(?!\*)"#, in: value) { match in
            "\(match[1])<em>\(match[2])</em>"
        }
        value = replaceRegex(#"\[([^\]]+)\]\(([^)\s]+)\)"#, in: value) { match in
            let text = match[1]
            let url = match[2]
            guard url.range(of: #"^(https?:|mailto:)"#, options: [.regularExpression, .caseInsensitive]) != nil else {
                return text
            }
            return "<a href=\"\(url)\" target=\"_blank\" rel=\"noopener noreferrer\">\(text)</a>"
        }
        return value
    }

    private static func replaceRegex(
        _ pattern: String,
        in input: String,
        transform: ([String]) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        let nsInput = input as NSString
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: nsInput.length))
        var result = input
        for match in matches.reversed() {
            var captures: [String] = []
            for rangeIndex in 0..<match.numberOfRanges {
                let range = match.range(at: rangeIndex)
                captures.append(range.location == NSNotFound ? "" : nsInput.substring(with: range))
            }
            let replacement = transform(captures)
            if let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: replacement)
            }
        }
        return result
    }

    private static func stylesheet() -> String {
        """
        :root { color-scheme: dark; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", Inter, sans-serif; background: #0d1117; color: #f0f6fc; }
        body { margin: 0; background: radial-gradient(circle at top left, #14314f 0, #0d1117 34rem); }
        .shell { width: min(1120px, calc(100vw - 48px)); margin: 0 auto; padding: 48px 0 64px; }
        .hero { display: flex; gap: 20px; align-items: center; padding: 28px; border: 1px solid rgba(255,255,255,.12); border-radius: 18px; background: rgba(22,27,34,.78); box-shadow: 0 20px 60px rgba(0,0,0,.28); }
        .avatar { width: 76px; height: 76px; border-radius: 22px; display: grid; place-items: center; overflow: hidden; background: linear-gradient(135deg, #58a6ff, #3fb950); color: #061017; font-weight: 800; text-decoration: none; flex: 0 0 auto; }
        .avatar img { width: 100%; height: 100%; object-fit: cover; }
        .eyebrow { margin: 0 0 8px; color: #7ee787; font-size: 12px; font-weight: 700; letter-spacing: .08em; text-transform: uppercase; }
        h1 { margin: 0; font-size: 38px; line-height: 1.05; letter-spacing: 0; }
        .subtitle, .note { margin: 10px 0 0; color: #8b949e; }
        .overview { display: grid; grid-template-columns: repeat(4, 1fr); gap: 14px; margin: 22px 0; }
        .metric, .wide, .repo-card, .empty { border: 1px solid rgba(255,255,255,.10); border-radius: 14px; background: rgba(22,27,34,.78); padding: 18px; }
        .metric span { display: block; color: #8b949e; font-size: 12px; }
        .metric strong { display: block; margin-top: 8px; font-size: 26px; }
        .wide { grid-column: span 2; }
        .wide h2, .repos h2 { margin: 0 0 10px; font-size: 16px; }
        .chips, .tags { display: flex; flex-wrap: wrap; gap: 8px; }
        .chip, .tag { display: inline-flex; gap: 6px; align-items: center; padding: 5px 9px; border-radius: 999px; background: rgba(88,166,255,.12); color: #c9d1d9; font-size: 12px; }
        .repo-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); gap: 16px; }
        .repo-head { display: flex; gap: 12px; align-items: flex-start; }
        .repo-logo { width: 42px; height: 42px; flex: 0 0 auto; display: grid; place-items: center; overflow: hidden; border-radius: 12px; background: #30363d; color: #f0f6fc; font-weight: 800; }
        .repo-logo img { width: 100%; height: 100%; object-fit: cover; }
        .repo-name { color: #58a6ff; font-weight: 700; text-decoration: none; }
        .repo-desc { margin: 6px 0 0; color: #c9d1d9; line-height: 1.45; }
        .facts { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px; margin: 16px 0; }
        .facts div { min-width: 0; }
        dt { color: #8b949e; font-size: 11px; margin-bottom: 4px; }
        dd { margin: 0; color: #f0f6fc; font-size: 13px; overflow-wrap: anywhere; }
        .block { margin-top: 14px; padding-top: 12px; border-top: 1px solid rgba(255,255,255,.08); }
        .block h3 { margin: 0 0 8px; font-size: 13px; color: #7ee787; }
        .block p { margin: 0; color: #c9d1d9; line-height: 1.5; }
        .markdown-body { color: #c9d1d9; overflow-wrap: anywhere; }
        .markdown-body h1, .markdown-body h2, .markdown-body h3, .markdown-body h4, .markdown-body h5, .markdown-body h6 { margin: 14px 0 8px; color: #f0f6fc; line-height: 1.3; }
        .markdown-body h1 { font-size: 18px; padding-bottom: 6px; border-bottom: 1px solid rgba(255,255,255,.08); }
        .markdown-body h2 { font-size: 16px; }
        .markdown-body h3 { font-size: 14px; color: #f0f6fc; }
        .markdown-body p { margin: 8px 0; white-space: normal; }
        .markdown-body ul, .markdown-body ol { margin: 8px 0; padding-left: 20px; }
        .markdown-body li { margin: 3px 0; }
        .markdown-body a { color: #58a6ff; text-decoration: none; }
        .markdown-body a:hover { text-decoration: underline; }
        .markdown-body strong { color: #f0f6fc; font-weight: 700; }
        .markdown-body em { color: #c9d1d9; }
        .markdown-body code { padding: 2px 5px; border-radius: 5px; background: rgba(110,118,129,.18); color: #f0f6fc; font-family: ui-monospace, SFMono-Regular, SF Mono, Menlo, monospace; font-size: .88em; }
        .markdown-body pre { margin: 10px 0; padding: 12px; overflow-x: auto; border-radius: 10px; border: 1px solid rgba(255,255,255,.08); background: rgba(13,17,23,.72); }
        .markdown-body pre code { padding: 0; border-radius: 0; background: transparent; }
        .markdown-body hr { border: 0; border-top: 1px solid rgba(255,255,255,.08); margin: 12px 0; }
        .muted { color: #8b949e; font-size: 12px; }
        .attribution { margin-top: 22px; color: #8b949e; font-size: 12px; text-align: center; }
        .attribution a { color: #58a6ff; text-decoration: none; }
        @media (max-width: 760px) { .shell { width: min(100vw - 28px, 1120px); padding-top: 24px; } .hero { align-items: flex-start; } h1 { font-size: 28px; } .overview { grid-template-columns: 1fr; } .wide { grid-column: auto; } .facts { grid-template-columns: 1fr; } }
        """
    }

    private static func languageDistribution(_ repos: [Repo]) -> [(String, Int)] {
        Dictionary(grouping: repos) { repo in nonEmpty(repo.language) ?? "Other" }
            .map { ($0.key, $0.value.count) }
            .sorted { lhs, rhs in lhs.1 == rhs.1 ? lhs.0 < rhs.0 : lhs.1 > rhs.1 }
    }

    private static func statusDistribution(
        repos: [Repo],
        supplements: LibraryExportSupplements
    ) -> [RepoStatus: Int] {
        var result: [RepoStatus: Int] = [:]
        for repo in repos {
            result[supplements.statuses[repo.id] ?? .unread, default: 0] += 1
        }
        return result
    }

    private static func englishStatus(_ status: RepoStatus) -> String {
        switch status {
        case .unread: return "Unread"
        case .read: return "Read"
        case .using: return "Using"
        }
    }

    private static func htmlEscape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

private extension Int {
    func formattedWithSeparator() -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: NSNumber(value: self)) ?? "\(self)"
    }
}

private func nonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
        return nil
    }
    return trimmed
}
