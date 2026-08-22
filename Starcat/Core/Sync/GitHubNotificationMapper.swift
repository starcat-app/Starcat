//
//  GitHubNotificationMapper.swift
//  Starcat
//
//  通知 JSON → 本地行、reason / 主体类型 chip、降级 GitHub Web URL。
//  当前用户 Star / Unstar / Fork 在独立账本，时间线两表 UNION 混排。
//  纯函数，单测不需要网络或数据库。
//
//  约束：通知列表没有 actor / body / html_url。人名和摘要只能在选中后从 subject.url 补。
//

import Foundation

enum GitHubNotificationChip: String, Sendable {
    case mention
    case review
    case assign
    case security
    case comment
    case pullRequest
    case issue
    case release
    case discussion
    /// 当前用户自己的 Unstar。GitHub 没有历史接口，只能记在本地账本。
    case unstar
    /// 当前用户自己的 Star。GitHub Notifications API 不给这条，时间线来自本地账本。
    case star
    /// 当前用户自己的 Fork。同样不是 GitHub inbox thread。
    case fork
}

enum GitHubNotificationPersonRole: String, Sendable {
    case author
    case commenter
    case reviewRequester
}

struct GitHubNotificationPerson: Equatable, Identifiable, Sendable {
    let login: String
    let role: GitHubNotificationPersonRole

    var id: String { "\(login)-\(role.rawValue)" }

    var avatarURLString: String {
        GitHubNotificationMapper.actorAvatarURL(login: login) ?? ""
    }
}

enum GitHubNotificationMapper {

    static let backfillLimit = 300
    static let pageSize = 50
    static let dwellNanoseconds: UInt64 = 400_000_000

    static let systemNotificationReasons: Set<String> = [
        "mention", "team_mention", "assign", "review_requested", "security_alert"
    ]

    static func chip(forReason reason: String) -> GitHubNotificationChip {
        switch reason {
        case "mention", "team_mention":
            return .mention
        case "review_requested", "review_submitted":
            return .review
        case "assign":
            return .assign
        case "security_alert":
            return .security
        default:
            return .comment
        }
    }

    static func chip(for record: GitHubNotificationThreadRecord) -> GitHubNotificationChip {
        if record.subjectType == "Release" {
            return .release
        }
        let reasonChip = chip(forReason: record.reason)
        // comment / subscribed / author 这类通用 reason 不能盖过主体类型：
        // PR 评论若显示「评论」，列表会把 Pull Request 误读成 Issue。
        guard reasonChip == .comment else { return reasonChip }
        switch record.subjectType {
        case "PullRequest":
            return .pullRequest
        case "Issue":
            return .issue
        case "Discussion":
            return .discussion
        case "Star":
            return .star
        case "Fork":
            return .fork
        default:
            return .comment
        }
    }

    /// 列表 / 详情顶栏的类型 chip：Issue / PR / Release / Discussion。
    /// Mention、Review 已经写在事件句里，不要再占一颗 reason 色标。
    static func subjectChip(for record: GitHubNotificationThreadRecord) -> GitHubNotificationChip {
        subjectChip(type: record.subjectType, reason: record.reason)
    }

    static func subjectChip(type: String, reason: String) -> GitHubNotificationChip {
        // 安全公告是状态，不是装饰色；即使 subject 像 Issue 也优先标出来。
        if chip(forReason: reason) == .security {
            return .security
        }
        switch type {
        case "PullRequest":
            return .pullRequest
        case "Issue":
            return .issue
        case "Release":
            return .release
        case "Discussion":
            return .discussion
        case "Star":
            return .star
        case "Fork":
            return .fork
        default:
            return .comment
        }
    }

    /// 列表主行：原型是「谁对你做了什么」，不是 GitHub subject.title。
    /// Catalog 本轮不能安全追加 key，文案按 locale 在这里分流。
    static func eventHeadline(for record: GitHubNotificationThreadRecord, locale: Locale) -> String {
        let someone = eventActor(for: record) ?? copy(locale, zh: "有人", en: "Someone")
        switch chip(for: record) {
        case .mention:
            if record.subjectType == "PullRequest" {
                return copy(locale, zh: "\(someone) 在 PR 里 @ 了你", en: "\(someone) mentioned you in a PR")
            }
            if record.subjectType == "Issue" {
                return copy(locale, zh: "\(someone) 在 Issue 里 @ 了你", en: "\(someone) mentioned you in an issue")
            }
            return copy(locale, zh: "\(someone) @ 了你", en: "\(someone) mentioned you")
        case .review:
            return copy(locale, zh: "\(someone) 请求你 Review 这个 PR", en: "\(someone) requested your review")
        case .assign:
            return copy(locale, zh: "\(someone) 把这个指派给你", en: "\(someone) assigned this to you")
        case .comment, .issue:
            return copy(locale, zh: "\(someone) 评论了这个 Issue", en: "\(someone) commented on this issue")
        case .pullRequest:
            return copy(locale, zh: "\(someone) 评论了这个 PR", en: "\(someone) commented on this PR")
        case .discussion:
            return copy(locale, zh: "\(someone) 评论了这个 Discussion", en: "\(someone) commented on this discussion")
        case .security:
            return copy(locale, zh: "仓库有安全公告", en: "Security alert")
        case .release:
            return copy(locale, zh: "发布了新的 Release", en: "New release published")
        case .star:
            return copy(locale, zh: "你 Star 了这个项目", en: "You starred this repository")
        case .fork:
            return copy(locale, zh: "你 Fork 了这个项目", en: "You forked this repository")
        case .unstar:
            return copy(locale, zh: "你 Unstar 了这个项目", en: "You unstarred this repository")
        }
    }

    static func userRepoActivityHeadline(kind: UserRepoActivityKind, locale: Locale) -> String {
        switch kind {
        case .star:
            return copy(locale, zh: "你 Star 了这个项目", en: "You starred this repository")
        case .unstar:
            return copy(locale, zh: "你 Unstar 了这个项目", en: "You unstarred this repository")
        case .fork:
            return copy(locale, zh: "你 Fork 了这个项目", en: "You forked this repository")
        }
    }

    /// 详情顶栏短句，比时间线事件句少「这个项目」。
    static func userRepoActivityShortAction(kind: UserRepoActivityKind, locale: Locale) -> String {
        switch kind {
        case .star:
            return copy(locale, zh: "你 Star 了", en: "You starred")
        case .unstar:
            return copy(locale, zh: "你 Unstar 了", en: "You unstarred")
        case .fork:
            return copy(locale, zh: "你 Fork 了", en: "You forked")
        }
    }

    static func userRepoActivityChip(kind: UserRepoActivityKind) -> GitHubNotificationChip {
        switch kind {
        case .star: return .star
        case .unstar: return .unstar
        case .fork: return .fork
        }
    }

    static func userRepoActivityBanner(kind: UserRepoActivityKind, relativeTime: String, locale: Locale) -> String {
        let action = userRepoActivityShortAction(kind: kind, locale: locale)
        if relativeTime.isEmpty { return action }
        return "\(action) · \(relativeTime)"
    }

    static func subjectHeading(type: String, number: Int?, locale: Locale) -> String {
        let name: String
        switch type {
        case "PullRequest":
            name = "Pull Request"
        case "Issue":
            name = "Issue"
        case "Discussion":
            name = "Discussion"
        case "Release":
            name = "Release"
        case "Star":
            name = "Star"
        case "Fork":
            name = "Fork"
        default:
            name = type
        }
        if let number {
            return "\(name) #\(number)"
        }
        return name
    }

    static func chipTitle(for chip: GitHubNotificationChip, locale: Locale) -> String {
        switch chip {
        case .release:
            return copy(locale, zh: "发行", en: "Release")
        case .discussion:
            return copy(locale, zh: "讨论", en: "Discussion")
        case .pullRequest:
            return "PR"
        case .issue:
            return "Issue"
        case .star:
            return "Star"
        case .unstar:
            return "Unstar"
        case .fork:
            return "Fork"
        default:
            return String.l10n(chipTitleKey(chip))
        }
    }

    /// GitHub REST 常见 `2026-08-19T14:32:00Z`（无毫秒）。
    /// `ISO8601DateFormatter.shared` 强制 `.withFractionalSeconds`，解析会失败，
    /// 时间线时钟和「2 小时前」会一起消失。
    static func parseDate(_ raw: String?) -> Date? {
        ISO8601DateFormatter.githubDate(from: raw)
    }

    static func repositoryOwner(fromFullName fullName: String) -> String? {
        let owner = fullName.split(separator: "/").first.map(String.init) ?? ""
        return owner.isEmpty ? nil : owner
    }

    static func repositoryAvatarURL(fromFullName fullName: String) -> String? {
        repositoryOwner(fromFullName: fullName).map { "https://github.com/\($0).png?size=80" }
    }

    static func actorAvatarURL(for record: GitHubNotificationThreadRecord) -> String? {
        guard let login = eventActor(for: record) else { return nil }
        return actorAvatarURL(login: login)
    }

    /// Dependabot 用本地 mark，不走远程 png（`dependabot[bot]` 不是合法 user login，会 404）。
    static func actorAvatarURL(login: String) -> String? {
        if actorAvatarAssetName(login: login) != nil { return nil }
        let trimmed = login.trimmingCharacters(in: .whitespacesAndNewlines)
        if let slug = githubAppSlug(login: trimmed) {
            return "https://github.com/\(slug).png?size=80"
        }
        guard isGitHubLogin(trimmed) else { return nil }
        return "https://github.com/\(trimmed).png?size=80"
    }

    /// GitHub 评论常夹 HTML `<img src="https://github.com/user-attachments/...">`。
    /// MarkdownUI 不会把裸 HTML 当图片，必须先收成 `![alt](url)`。
    static func prepareMarkdown(_ raw: String) -> String {
        var text = raw.replacingOccurrences(
            of: #"<br\s*/?>"#,
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        let imgTag = Self.htmlImageTagRegex
        let srcAttr = Self.htmlSrcRegex
        let altAttr = Self.htmlAltRegex
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in imgTag.matches(in: text, range: nsRange).reversed() {
            guard let range = Range(match.range, in: text) else { continue }
            let tag = String(text[range])
            let tagRange = NSRange(tag.startIndex..<tag.endIndex, in: tag)
            guard let srcMatch = srcAttr.firstMatch(in: tag, range: tagRange),
                  let srcRange = Range(srcMatch.range(at: 1), in: tag)
            else { continue }
            let src = String(tag[srcRange]).replacingOccurrences(of: "&amp;", with: "&")
            var alt = "Image"
            if let altMatch = altAttr.firstMatch(in: tag, range: tagRange),
               let altRange = Range(altMatch.range(at: 1), in: tag) {
                let value = String(tag[altRange])
                if !value.isEmpty { alt = value }
            }
            let escapedAlt = alt.replacingOccurrences(of: "]", with: "\\]")
            text.replaceSubrange(range, with: "\n\n![\(escapedAlt)](\(src))\n\n")
        }
        // GitHub 常把图包在 <a href="..."><img></a> 里；img 收成 Markdown 后要去掉外壳，
        // 否则 MarkdownUI 会把残留的 `<a>` 当正文显示。
        text = text.replacingOccurrences(
            of: #"</?a\b[^>]*>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: #"</?p\b[^>]*>"#,
            with: "\n\n",
            options: [.regularExpression, .caseInsensitive]
        )
        return text
    }

    /// GitHub 风格：把评论里的 `#20` / `owner/repo#20` 收成可点 Markdown 链接。
    ///
    /// CommonMark / MarkdownUI 不会把裸 `#20` 当链接，必须在渲染前自己收。
    /// 一律指向 `/issues/N`：GitHub 对 PR 编号会 302 到 `/pull/N`，和网页评论一致。
    /// 代码块、行内 code、现成链接、URL 片段不改，避免把示例或已有锚点再包一层。
    static func autolinkIssueReferences(_ markdown: String, repositoryFullName: String) -> String {
        guard !markdown.isEmpty else { return markdown }
        let ns = markdown as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        let protected = protectedMarkdownRanges(in: markdown)

        func overlapsProtected(_ range: NSRange) -> Bool {
            protected.contains { NSIntersectionRange($0, range).length > 0 }
        }

        var replacements: [(NSRange, String)] = []

        for match in crossRepoIssueRefRegex.matches(in: markdown, range: fullRange) {
            guard !overlapsProtected(match.range),
                  let repoRange = Range(match.range(at: 1), in: markdown),
                  let numberRange = Range(match.range(at: 2), in: markdown)
            else { continue }
            let repo = String(markdown[repoRange])
            let number = String(markdown[numberRange])
            let text = ns.substring(with: match.range)
            replacements.append((
                match.range,
                "[\(text)](https://github.com/\(repo)/issues/\(number))"
            ))
        }

        let sameRepoOK = repositoryFullName.split(separator: "/").count == 2
        if sameRepoOK {
            for match in hashIssueRefRegex.matches(in: markdown, range: fullRange) {
                guard !overlapsProtected(match.range),
                      let numberRange = Range(match.range(at: 1), in: markdown)
                else { continue }
                let overlapsCrossRepo = replacements.contains {
                    NSIntersectionRange($0.0, match.range).length > 0
                }
                guard !overlapsCrossRepo else { continue }
                let number = String(markdown[numberRange])
                let text = ns.substring(with: match.range)
                replacements.append((
                    match.range,
                    "[\(text)](https://github.com/\(repositoryFullName)/issues/\(number))"
                ))
            }
        }

        let mutable = NSMutableString(string: markdown)
        for (range, replacement) in replacements.sorted(by: { $0.0.location > $1.0.location }) {
            mutable.replaceCharacters(in: range, with: replacement)
        }
        return mutable as String
    }

    /// 代码、链接、URL 里的 `#20` 不是 Issue 引用。
    private static func protectedMarkdownRanges(in markdown: String) -> [NSRange] {
        let ns = markdown as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        var ranges: [NSRange] = []
        for regex in protectedMarkdownRegexes {
            for match in regex.matches(in: markdown, range: fullRange) {
                ranges.append(match.range)
            }
        }
        return ranges
    }

    static func copy(_ locale: Locale, zh: String, en: String) -> String {
        locale.identifier.lowercased().hasPrefix("zh") ? zh : en
    }

    /// 中栏面包屑下一行：时间线总数 + 真实通知未读。组织 Issue / 账本不伪造 unread。
    static func listCountSubtitle(total: Int, unread: Int, locale: Locale) -> String {
        copy(
            locale,
            zh: "\(total) 条事件 · \(unread) 未读",
            en: "\(total) events · \(unread) unread"
        )
    }

    /// 评论 / mention 优先用最新评论作者；否则用 hydrate 到的 subject.user。
    /// 通知列表里的「谁」：comment / mention 用最新评论作者。
    /// 详情里 Issue 正文的发布人不能走这个，否则会被最后一条回复盖掉。
    static func eventActor(for record: GitHubNotificationThreadRecord) -> String? {
        let comments = decodeComments(record.commentsJson)
        switch chip(for: record) {
        case .comment, .mention, .pullRequest, .issue, .discussion:
            if let login = comments.last?.login, !login.isEmpty {
                return login
            }
        default:
            break
        }
        if let login = record.actorLogin, !login.isEmpty {
            return login
        }
        return comments.last?.login
    }

    /// Issue / PR 开帖人：hydrate 时从 `subject.user` 写入 `actor_login`，不是评论区最后一人。
    static func openingPostAuthor(for record: GitHubNotificationThreadRecord) -> String? {
        if let login = record.actorLogin, !login.isEmpty {
            return login
        }
        return nil
    }

    static func clockLabel(date: Date, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// 时间线左侧只留 `HH:mm`。日期交给分组标题（今天 / 昨天 / 本周），不要再写年月日。
    static func timelineStamp(date: Date, locale: Locale) -> String {
        clockLabel(date: date, locale: locale)
    }

    /// 评论卡片右侧时间：相对时间不够时补绝对日期。
    static func commentTimeLabel(date: Date, locale: Locale) -> String {
        let relative = RelativeTimeText.pastEvent(date, locale: locale)
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "\(relative) · \(formatter.string(from: date))"
    }

    /// 列表摘录：第一行可见文字。跳过纯图片行，链接改成锚文本，大约 88 字。
    static func listSnippet(_ excerpt: String?) -> String? {
        guard let excerpt else { return nil }
        let prepared = prepareMarkdown(excerpt)
        for rawLine in prepared.split(whereSeparator: \.isNewline).map(String.init) {
            var line = rawLine
            if let imageRegex = try? NSRegularExpression(pattern: #"!\[[^\]]*\]\([^)]+\)"#) {
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                line = imageRegex.stringByReplacingMatches(in: line, range: range, withTemplate: "")
            }
            if let linkRegex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\([^)]+\)"#) {
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                line = linkRegex.stringByReplacingMatches(in: line, range: range, withTemplate: "$1")
            }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.lowercased().hasPrefix("<img") else { continue }
            if line.count > 88 {
                let end = line.index(line.startIndex, offsetBy: 88)
                return String(line[..<end]) + "…"
            }
            return line
        }
        return nil
    }

    static func detailTimeLabel(date: Date, locale: Locale) -> String {
        let relative = RelativeTimeText.pastEvent(date, locale: locale)
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return "\(relative) (\(formatter.string(from: date)))"
    }

    static func relatedPeople(for record: GitHubNotificationThreadRecord) -> [GitHubNotificationPerson] {
        var people: [GitHubNotificationPerson] = []
        var seen = Set<String>()
        func append(_ login: String, role: GitHubNotificationPersonRole) {
            let key = login.lowercased()
            guard !key.isEmpty, !seen.contains(key) else { return }
            seen.insert(key)
            people.append(GitHubNotificationPerson(login: login, role: role))
        }
        let chip = chip(for: record)
        if let actor = record.actorLogin {
            let role: GitHubNotificationPersonRole = chip == .review ? .reviewRequester : .author
            append(actor, role: role)
        }
        for comment in decodeComments(record.commentsJson) {
            append(comment.login, role: .commenter)
        }
        return people
    }

    static func matchesSegment(_ record: GitHubNotificationThreadRecord, segment: GitHubNotificationSegment) -> Bool {
        switch segment {
        case .all:
            return true
        case .unread:
            return record.unread
        case .mention:
            return chip(forReason: record.reason) == .mention
        case .review:
            return chip(forReason: record.reason) == .review
        case .issue:
            return record.subjectType == "Issue"
        case .pullRequest:
            return record.subjectType == "PullRequest"
        case .discussion:
            return record.subjectType == "Discussion"
        case .release:
            return record.subjectType == "Release"
        case .open, .closed, .merged:
            return normalizedIssueState(record.issueState) == segment.issueStateFilter
        case .star, .unstar, .fork, .inLibrary, .outsideLibrary:
            // 账本 / 知识库分段只含 `user_repo_activity`，GitHub thread 永远对不上。
            return false
        }
    }

    /// 本机曾插入过 `starcat-demo-` 前缀的演示 thread。永不打 GitHub API。
    static let demoThreadIDPrefix = "starcat-demo-"
    /// 通知时间线每页条数。两表 UNION 游标翻页，对齐 Manage 列表。
    static let timelinePageSize = 40
    /// 切打开 / 关闭 / 已合并时，同一会话最多补这么多条缺失 `issue_state`。
    /// GitHub 通知列表不带状态；补齐要打 subject GET，必须限次以免烧额度。
    static let issueStateBackfillLimit = 20
    /// 后台补状态并发。太大容易打满 secondary rate limit，太小又回到串行干等。
    static let issueStateBackfillConcurrency = 4

    static func isDemoThread(_ id: String) -> Bool {
        id.hasPrefix(demoThreadIDPrefix)
    }

    /// 时间线 / 详情只认这三态。其它 GitHub 值（draft、locked）不当状态画。
    static let displayableIssueStates: Set<String> = ["open", "closed", "merged"]

    static func normalizedIssueState(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return displayableIssueStates.contains(value) ? value : nil
    }

    /// PR 的 REST `state` 仍是 `closed`，要用 `merged` / `merged_at` 才能和 Closed 分开。
    static func resolvedIssueState(
        rawState: String?,
        merged: Bool?,
        mergedAt: String?
    ) -> String? {
        let hasMergedTimestamp = mergedAt?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        if merged == true || hasMergedTimestamp {
            return "merged"
        }
        return normalizedIssueState(rawState)
    }

    static func issueStateTitle(state: String, locale: Locale) -> String {
        switch normalizedIssueState(state) {
        case "open":
            return copy(locale, zh: "打开", en: "Open")
        case "closed":
            return copy(locale, zh: "已关闭", en: "Closed")
        case "merged":
            return copy(locale, zh: "已合并", en: "Merged")
        default:
            return state
        }
    }

    /// 时间列只有 52pt，英文不能用 `In Library`。
    static func libraryStateStampTitle(state: LibraryState, locale: Locale) -> String {
        switch state {
        case .inLibrary:
            return copy(locale, zh: "已入库", en: "In")
        case .outsideLibrary:
            return copy(locale, zh: "未入库", en: "Out")
        }
    }

    static func libraryStateFilterTitle(state: LibraryState, locale: Locale) -> String {
        switch state {
        case .inLibrary:
            return copy(locale, zh: "已入库", en: "In Library")
        case .outsideLibrary:
            return copy(locale, zh: "未入库", en: "Not in Library")
        }
    }

    /// 评论框状态按钮：对齐 GitHub 网页（Close issue / Reopen issue / Close with comment）。
    static func issueStateActionTitle(
        isClosed: Bool,
        isPullRequest: Bool,
        hasComment: Bool,
        locale: Locale
    ) -> String {
        if hasComment {
            return copy(
                locale,
                zh: isClosed ? "评论并重新打开" : "评论并关闭",
                en: isClosed ? "Reopen with comment" : "Close with comment"
            )
        }
        if isPullRequest {
            return copy(
                locale,
                zh: isClosed ? "重新打开 Pull Request" : "关闭 Pull Request",
                en: isClosed ? "Reopen pull request" : "Close pull request"
            )
        }
        return copy(
            locale,
            zh: isClosed ? "重新打开问题" : "关闭问题",
            en: isClosed ? "Reopen issue" : "Close issue"
        )
    }

    static func subjectNumber(fromApiURL url: String) -> Int? {
        guard let last = url.split(separator: "/").last else { return nil }
        return Int(last)
    }

    static func fallbackHTMLURL(
        fullName: String,
        subjectType: String,
        apiURL: String
    ) -> String {
        let number = subjectNumber(fromApiURL: apiURL)
        switch subjectType {
        case "PullRequest":
            if let number {
                return "https://github.com/\(fullName)/pull/\(number)"
            }
        case "Issue":
            if let number {
                return "https://github.com/\(fullName)/issues/\(number)"
            }
        case "Release":
            return "https://github.com/\(fullName)/releases"
        case "Discussion":
            if let number {
                return "https://github.com/\(fullName)/discussions/\(number)"
            }
            return "https://github.com/\(fullName)/discussions"
        case "Commit":
            if let sha = apiURL.split(separator: "/").last {
                return "https://github.com/\(fullName)/commit/\(sha)"
            }
        default:
            break
        }
        return "https://github.com/\(fullName)"
    }

    static func path(fromAbsoluteAPIURL urlString: String) -> String? {
        guard let url = URL(string: urlString), let host = url.host else {
            return urlString.hasPrefix("/") ? urlString : nil
        }
        guard host.contains("api.github.com") else { return nil }
        return url.path
    }

    /// 入库全文。GitHub Issue / comment body 上限约 65536，不再截 500 字。
    static func bodyMarkdown(_ body: String?) -> String? {
        guard let body else { return nil }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Issue 评论：`/repos/o/r/issues/30/comments`。
    /// PR 评论走同一套 issue comments API，把 `/pulls/N` 换成 `/issues/N`。
    static func issueCommentsPath(subjectType: String, subjectApiURL: String) -> String? {
        guard let path = path(fromAbsoluteAPIURL: subjectApiURL), !path.isEmpty else { return nil }
        switch subjectType {
        case "Issue":
            return path.hasSuffix("/comments") ? path : path + "/comments"
        case "PullRequest":
            let issuePath = path.replacingOccurrences(of: "/pulls/", with: "/issues/")
            return issuePath.hasSuffix("/comments") ? issuePath : issuePath + "/comments"
        default:
            return nil
        }
    }

    /// 关 Issue / PR：`/repos/o/r/issues/N`。PR 的 subject.url 是 `/pulls/N`，GitHub 允许改走 issues。
    static func issueResourcePath(subjectType: String, subjectApiURL: String) -> String? {
        guard let commentsPath = issueCommentsPath(subjectType: subjectType, subjectApiURL: subjectApiURL) else {
            return nil
        }
        let suffix = "/comments"
        guard commentsPath.hasSuffix(suffix) else { return commentsPath }
        return String(commentsPath.dropLast(suffix.count))
    }

    static func encodeComments(_ comments: [GitHubNotificationComment]) -> String? {
        guard !comments.isEmpty else { return nil }
        let data = try? JSONEncoder().encode(comments)
        return data.flatMap { String(data: $0, encoding: .utf8) }
    }

    static func decodeComments(_ json: String?) -> [GitHubNotificationComment] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([GitHubNotificationComment].self, from: data)) ?? []
    }

    /// GitHub 标签可以有多个，顺序跟网页一致。对象缺 `color` 或纯字符串都收成默认灰。
    static func labels(from raw: Any?) -> [GitHubNotificationIssueLabel] {
        guard let items = raw as? [Any] else { return [] }
        var result: [GitHubNotificationIssueLabel] = []
        result.reserveCapacity(min(items.count, 20))
        for item in items.prefix(20) {
            if let name = (item as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty {
                result.append(GitHubNotificationIssueLabel(name: name, colorHex: "6e7781"))
                continue
            }
            guard let obj = item as? [String: Any] else { continue }
            let name = ((obj["name"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            var color = ((obj["color"] as? String) ?? "6e7781")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if color.hasPrefix("#") {
                color.removeFirst()
            }
            if color.count != 6 {
                color = "6e7781"
            }
            result.append(GitHubNotificationIssueLabel(name: name, colorHex: color.lowercased()))
        }
        return result
    }

    static func labels(from organization: [GitHubOrganizationIssueLabel]) -> [GitHubNotificationIssueLabel] {
        organization.prefix(20).compactMap { label in
            let name = label.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            var color = label.colorHex.trimmingCharacters(in: .whitespacesAndNewlines)
            if color.hasPrefix("#") {
                color.removeFirst()
            }
            if color.count != 6 {
                color = "6e7781"
            }
            return GitHubNotificationIssueLabel(name: name, colorHex: color.lowercased())
        }
    }

    /// 空数组也写成 `[]`，用来区分「确认没标签」和「还没拉过」。
    static func encodeLabels(_ labels: [GitHubNotificationIssueLabel]) -> String {
        let data = (try? JSONEncoder().encode(labels)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    static func decodeLabels(_ json: String?) -> [GitHubNotificationIssueLabel] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([GitHubNotificationIssueLabel].self, from: data)) ?? []
    }

    static func subtitle(fullName: String, subjectType: String, number: Int?) -> String {
        if let number {
            switch subjectType {
            case "PullRequest", "Issue", "Discussion":
                return "\(fullName) #\(number)"
            default:
                break
            }
        }
        return fullName
    }

    /// 中栏次行：`owner/repo · PR #n · 相对时间`。不要单独再写时钟。
    static func timelineCaption(
        fullName: String,
        subjectType: String,
        number: Int?,
        relativeTime: String
    ) -> String {
        var parts: [String] = [fullName]
        if let number {
            switch subjectType {
            case "PullRequest":
                parts.append("PR #\(number)")
            case "Issue":
                parts.append("Issue #\(number)")
            case "Discussion":
                parts.append("Discussion #\(number)")
            default:
                parts.append("#\(number)")
            }
        }
        if !relativeTime.isEmpty {
            parts.append(relativeTime)
        }
        return parts.joined(separator: " · ")
    }

    /// 时间线分组：今天 / 昨天 / 本周 / 更早。
    static func dayGroup(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> GitHubNotificationDayGroup {
        if calendar.isDate(date, inSameDayAs: now) {
            return .today
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return .yesterday
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
            return .thisWeek
        }
        return .earlier
    }

    static func chipTitleKey(_ chip: GitHubNotificationChip) -> String {
        "activity.notification.chip.\(chip.rawValue)"
    }

    private static let htmlImageTagRegex = try! NSRegularExpression(
        pattern: #"<img\b[^>]*>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
    private static let htmlSrcRegex = try! NSRegularExpression(
        pattern: #"\bsrc\s*=\s*["']([^"']+)["']"#,
        options: .caseInsensitive
    )
    private static let htmlAltRegex = try! NSRegularExpression(
        pattern: #"\balt\s*=\s*["']([^"']*)["']"#,
        options: .caseInsensitive
    )
    /// `owner/repo#20`。先于裸 `#20` 匹配，避免把仓库前缀拆掉。
    private static let crossRepoIssueRefRegex = try! NSRegularExpression(
        pattern: #"\b([A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?/[A-Za-z0-9._-]+)#(\d{1,8})\b"#
    )
    /// 裸 `#20`。前面不能是标识符 / `&`，否则会误伤 `C#20`、`&#39;`。
    private static let hashIssueRefRegex = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_/&])#(\d{1,8})\b"#
    )
    private static let protectedMarkdownRegexes: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"```[\s\S]*?```"#),
        try! NSRegularExpression(pattern: #"~~~[\s\S]*?~~~"#),
        try! NSRegularExpression(pattern: #"`[^`\n]+`"#),
        try! NSRegularExpression(pattern: #"!\[[^\]]*\]\([^)]*\)"#),
        try! NSRegularExpression(pattern: #"(?<!!)\[[^\]]*\]\([^)]*\)"#),
        try! NSRegularExpression(pattern: #"https?://[^\s)<\]]+"#)
    ]

    static func canReply(subjectType: String, number: Int?) -> Bool {
        guard number != nil else { return false }
        return subjectType == "Issue" || subjectType == "PullRequest"
    }

    static func commentCardHeader(login: String, isOpeningPost: Bool, locale: Locale) -> String {
        "\(login) \(commentCardAction(isOpeningPost: isOpeningPost, locale: locale))"
    }

    /// 卡片里登录名单独成链接，动作文案跟在后面。
    static func commentCardAction(isOpeningPost: Bool, locale: Locale) -> String {
        if isOpeningPost {
            return copy(locale, zh: "发布了这条", en: "opened")
        }
        return copy(locale, zh: "评论", en: "commented")
    }

    /// GitHub 用户主页，或 GitHub App 主页（`foo[bot]` → `/apps/foo`）。
    /// 占位「有人 / Someone」或非法 login 返回 nil，避免打开坏链接。
    static func profileHTMLURL(login: String) -> URL? {
        let trimmed = login.trimmingCharacters(in: .whitespacesAndNewlines)
        if let slug = githubAppSlug(login: trimmed) {
            return GitHubURLs.githubApp(slug: slug)
        }
        guard isGitHubLogin(trimmed) else { return nil }
        return GitHubURLs.userProfile(login: trimmed)
    }

    /// GitHub App 登录名 `foo[bot]` → slug `foo`。方括号不是 user login，不能当用户主页。
    static func githubAppSlug(login: String) -> String? {
        let trimmed = login.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = "[bot]"
        guard trimmed.lowercased().hasSuffix(suffix) else { return nil }
        let slug = String(trimmed.dropLast(suffix.count))
        guard isGitHubLogin(slug) else { return nil }
        return slug
    }

    /// dong4j 提供的 Dependabot 官方 mark，资源名 `DependabotMark`。
    static func actorAvatarAssetName(login: String) -> String? {
        guard let slug = githubAppSlug(login: login) else { return nil }
        guard slug.compare("dependabot", options: .caseInsensitive) == .orderedSame else { return nil }
        return "DependabotMark"
    }

    /// GitHub login：1–39 位，字母数字和连字符，不能首尾是 `-`。纯数字账号（如 `493505110`）合法。
    /// `dependabot[bot]` 这类 App 账号走 `githubAppSlug`，不要用这条判断。
    static func isGitHubLogin(_ login: String) -> Bool {
        let count = login.utf8.count
        guard (1...39).contains(count) else { return false }
        let pattern = #"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$"#
        return login.range(of: pattern, options: .regularExpression) != nil
    }

    static func record(
        from dto: GitHubNotificationThreadDTO,
        fetchedAt: String,
        firstSeenAt: String
    ) -> GitHubNotificationThreadRecord {
        let fullName = dto.resolvedFullName
        let apiURL = dto.subject.url ?? ""
        return GitHubNotificationThreadRecord(
            id: dto.id,
            reason: dto.reason,
            unread: dto.unread,
            githubUnread: dto.unread,
            repositoryId: dto.repository.id,
            repositoryFullName: fullName,
            subjectTitle: dto.subject.title,
            subjectType: dto.subject.type,
            subjectApiUrl: apiURL,
            subjectNumber: subjectNumber(fromApiURL: apiURL),
            htmlUrl: fallbackHTMLURL(
                fullName: fullName,
                subjectType: dto.subject.type,
                apiURL: apiURL
            ),
            actorLogin: nil,
            subjectCreatedAt: nil,
            excerpt: nil,
            commentsJson: nil,
            hydratedAt: nil,
            updatedAt: dto.updatedAt,
            firstSeenAt: firstSeenAt,
            notifiedAt: nil,
            markReadState: GitHubNotificationMarkReadState.idle.rawValue,
            fetchedAt: fetchedAt
        )
    }
}

/// 通知 inbox 类型筛选。选项变多后顶栏用下拉，不再用分段控件。
///
/// `all` 两表 UNION；`unread` / 主体类型 / 打开·关闭·合并 / `mention` / `review` 只含 GitHub 通知；
/// `star` / `unstar` / `fork` / 入库只含账本。
enum GitHubNotificationSegment: String, CaseIterable, Identifiable, Sendable {
    case all
    case unread
    case issue
    case pullRequest
    case discussion
    case release
    case open
    case closed
    case merged
    case mention
    case review
    case star
    case unstar
    case fork
    case inLibrary
    case outsideLibrary

    var id: String { rawValue }

    /// Star / Unstar / Fork 只筛账本；其余筛 GitHub 通知（`all` 再 UNION 账本）。
    var ledgerKind: UserRepoActivityKind? {
        switch self {
        case .star: return .star
        case .unstar: return .unstar
        case .fork: return .fork
        case .all, .unread, .issue, .pullRequest, .discussion, .release,
             .open, .closed, .merged, .mention, .review, .inLibrary, .outsideLibrary:
            return nil
        }
    }

    /// Issue / PR 的 `issue_state`。`closed` 不含 `merged`。
    var issueStateFilter: String? {
        switch self {
        case .open: return "open"
        case .closed: return "closed"
        case .merged: return "merged"
        default: return nil
        }
    }

    var libraryStateFilter: LibraryState? {
        switch self {
        case .inLibrary: return .inLibrary
        case .outsideLibrary: return .outsideLibrary
        default: return nil
        }
    }

    /// 菜单分组：未读 / 主体类型 / 工作状态 / Mention·Review / 账本 / 知识库。
    var showsDividerBefore: Bool {
        self == .issue || self == .open || self == .mention || self == .star || self == .inLibrary
    }

    var systemImage: String {
        switch self {
        case .all: return "tray"
        case .unread: return "circle.inset.filled"
        case .issue: return "smallcircle.filled.circle"
        case .pullRequest: return "arrow.triangle.pull"
        case .discussion: return "text.bubble"
        case .release: return "tag.circle"
        case .open: return "circle"
        case .closed: return "checkmark.circle"
        case .merged: return "arrow.triangle.merge"
        case .mention: return "at"
        case .review: return "eye"
        case .star: return "star"
        case .unstar: return "star.slash"
        case .fork: return "arrow.triangle.branch"
        case .inLibrary: return "heart.fill"
        case .outsideLibrary: return "heart"
        }
    }

    /// All / Unread / Mention / Review 走已有 Catalog；主体类型与账本复用 chip 文案，不新增 key。
    func displayTitle(locale: Locale) -> String {
        switch self {
        case .all:
            return String.l10n("activity.notification.segment.all")
        case .unread:
            return String.l10n("activity.notification.segment.unread")
        case .issue:
            return GitHubNotificationMapper.chipTitle(for: .issue, locale: locale)
        case .pullRequest:
            return GitHubNotificationMapper.chipTitle(for: .pullRequest, locale: locale)
        case .discussion:
            return GitHubNotificationMapper.chipTitle(for: .discussion, locale: locale)
        case .release:
            return GitHubNotificationMapper.chipTitle(for: .release, locale: locale)
        case .mention:
            return String.l10n("activity.notification.segment.mention")
        case .review:
            return String.l10n("activity.notification.segment.review")
        case .star:
            return GitHubNotificationMapper.chipTitle(for: .star, locale: locale)
        case .unstar:
            return GitHubNotificationMapper.chipTitle(for: .unstar, locale: locale)
        case .fork:
            return GitHubNotificationMapper.chipTitle(for: .fork, locale: locale)
        case .open:
            return GitHubNotificationMapper.issueStateTitle(state: "open", locale: locale)
        case .closed:
            return GitHubNotificationMapper.issueStateTitle(state: "closed", locale: locale)
        case .merged:
            return GitHubNotificationMapper.issueStateTitle(state: "merged", locale: locale)
        case .inLibrary:
            return GitHubNotificationMapper.libraryStateFilterTitle(state: .inLibrary, locale: locale)
        case .outsideLibrary:
            return GitHubNotificationMapper.libraryStateFilterTitle(state: .outsideLibrary, locale: locale)
        }
    }
}

/// 通知时间线的日期分组。
enum GitHubNotificationDayGroup: String, CaseIterable, Identifiable, Sendable {
    case today
    case yesterday
    case thisWeek
    case earlier

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .today: return "activity.notification.group.today"
        case .yesterday: return "activity.notification.group.yesterday"
        case .thisWeek: return "activity.notification.group.thisWeek"
        case .earlier: return "activity.notification.group.earlier"
        }
    }
}
