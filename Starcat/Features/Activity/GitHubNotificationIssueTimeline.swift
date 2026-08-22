//
//  GitHubNotificationIssueTimeline.swift
//  Starcat
//
//  GitHub Issue Timeline 的内存模型与松散 JSON 解析。
//
//  只服务设置里打开的 Issue 事件流，不入库、不改 `comments_json`。
//  未知 `event` 直接丢掉；白名单见 `Kind`。
//  `referenced` 只留 commit SHA，不拉 commit message。
//

import Foundation

/// Timeline 一行：评论卡或一条系统事件。
enum GitHubNotificationIssueTimelineItem: Equatable, Sendable, Identifiable, Codable {
    case comment(GitHubNotificationComment)
    case event(GitHubNotificationIssueTimelineEvent)

    private enum CodingKeys: String, CodingKey {
        case type
        case comment
        case event
    }

    private enum ItemType: String, Codable {
        case comment
        case event
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ItemType.self, forKey: .type) {
        case .comment:
            self = .comment(try container.decode(GitHubNotificationComment.self, forKey: .comment))
        case .event:
            self = .event(try container.decode(GitHubNotificationIssueTimelineEvent.self, forKey: .event))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .comment(let comment):
            try container.encode(ItemType.comment, forKey: .type)
            try container.encode(comment, forKey: .comment)
        case .event(let event):
            try container.encode(ItemType.event, forKey: .type)
            try container.encode(event, forKey: .event)
        }
    }

    var id: String {
        switch self {
        case .comment(let comment):
            return "comment-\(comment.id)"
        case .event(let event):
            return event.id
        }
    }
}

/// 一条 GitHub 系统事件。字段按 kind 选用，其余为 nil。
struct GitHubNotificationIssueTimelineEvent: Equatable, Sendable, Identifiable, Codable {
    enum Kind: String, Equatable, Sendable, Codable {
        case labeled
        case unlabeled
        case closed
        case reopened
        case renamed
        case referenced
        case crossReferenced
    }

    let id: String
    let kind: Kind
    let actorLogin: String
    let createdAt: String?
    let label: GitHubNotificationIssueLabel?
    let commitSHA: String?
    let renameFrom: String?
    let renameTo: String?
    let crossRefNumber: Int?
    let crossRefURL: String?
    let isCrossRefPullRequest: Bool
}

enum GitHubNotificationIssueTimelineParser {
    /// `GET /repos/{owner}/{repo}/issues/{n}/timeline`。PR 也走 issues 路径。
    static func resourcePath(repositoryFullName: String, number: Int) -> String {
        "/repos/\(repositoryFullName)/issues/\(number)/timeline"
    }

    /// `#N` / `PR #N`。Catalog 占位是 `%@`，必须传 `String`。
    /// `String(format: "%@", 4)` 会把 Int 当成对象指针，Issue #3 的 PR #4 会 SIGSEGV。
    static func crossRefTitle(number: Int, isPullRequest: Bool) -> String {
        let key = isPullRequest
            ? "activity.notification.timeline.crossRefPR"
            : "activity.notification.timeline.crossRefIssue"
        return String(format: String.l10n(key), String(number))
    }

    /// GitHub 网页短 SHA：前 7 位。不足 7 位原样返回。
    static func shortSHA(_ sha: String) -> String {
        let trimmed = sha.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 7 else { return trimmed }
        return String(trimmed.prefix(7))
    }

    static func commitHTMLURL(repositoryFullName: String, sha: String) -> URL? {
        let trimmed = sha.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repositoryFullName.isEmpty, !trimmed.isEmpty else { return nil }
        return URL(string: "https://github.com/\(repositoryFullName)/commit/\(trimmed)")
    }

    /// 只认白名单 event；其余（Projects v2 / assigned / subscribed…）丢掉。
    static func parse(_ data: Data) -> [GitHubNotificationIssueTimelineItem] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return []
        }
        return rows.compactMap { row in
            guard let obj = row as? [String: Any] else { return nil }
            return parseItem(obj)
        }
    }

    private static func parseItem(_ obj: [String: Any]) -> GitHubNotificationIssueTimelineItem? {
        let event = (obj["event"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch event {
        case "commented":
            return parseComment(obj)
        case "labeled":
            return parseEvent(obj, kind: .labeled)
        case "unlabeled":
            return parseEvent(obj, kind: .unlabeled)
        case "closed":
            return parseEvent(obj, kind: .closed)
        case "reopened":
            return parseEvent(obj, kind: .reopened)
        case "renamed":
            return parseEvent(obj, kind: .renamed)
        case "referenced":
            return parseEvent(obj, kind: .referenced)
        case "cross-referenced":
            return parseEvent(obj, kind: .crossReferenced)
        default:
            return nil
        }
    }

    private static func parseComment(_ obj: [String: Any]) -> GitHubNotificationIssueTimelineItem? {
        guard let id = int64Value(obj["id"]) else { return nil }
        let user = obj["user"] as? [String: Any]
        let actor = obj["actor"] as? [String: Any]
        let login = (user?["login"] as? String) ?? (actor?["login"] as? String) ?? ""
        guard !login.isEmpty else { return nil }
        let comment = GitHubNotificationComment(
            id: id,
            login: login,
            body: GitHubNotificationMapper.bodyMarkdown(obj["body"] as? String) ?? "",
            htmlURL: obj["html_url"] as? String,
            createdAt: obj["created_at"] as? String
        )
        return .comment(comment)
    }

    private static func parseEvent(
        _ obj: [String: Any],
        kind: GitHubNotificationIssueTimelineEvent.Kind
    ) -> GitHubNotificationIssueTimelineItem? {
        let actor = ((obj["actor"] as? [String: Any])?["login"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let createdAt = obj["created_at"] as? String
        let rawID = int64Value(obj["id"]).map(String.init) ?? createdAt ?? kind.rawValue
        var label: GitHubNotificationIssueLabel?
        var commitSHA: String?
        var renameFrom: String?
        var renameTo: String?
        var crossRefNumber: Int?
        var crossRefURL: String?
        var isCrossRefPullRequest = false

        switch kind {
        case .labeled, .unlabeled:
            label = parseLabel(obj["label"])
            guard label != nil else { return nil }
        case .referenced:
            let sha = (obj["commit_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !sha.isEmpty else { return nil }
            commitSHA = sha
        case .renamed:
            let rename = obj["rename"] as? [String: Any]
            renameFrom = (rename?["from"] as? String) ?? ""
            renameTo = (rename?["to"] as? String) ?? ""
        case .crossReferenced:
            let issue = (obj["source"] as? [String: Any])?["issue"] as? [String: Any]
            guard let number = intValue(issue?["number"]) else { return nil }
            crossRefNumber = number
            crossRefURL = issue?["html_url"] as? String
            isCrossRefPullRequest = issue?["pull_request"] != nil
        case .closed, .reopened:
            break
        }

        let event = GitHubNotificationIssueTimelineEvent(
            id: "event-\(kind.rawValue)-\(rawID)",
            kind: kind,
            actorLogin: actor,
            createdAt: createdAt,
            label: label,
            commitSHA: commitSHA,
            renameFrom: renameFrom,
            renameTo: renameTo,
            crossRefNumber: crossRefNumber,
            crossRefURL: crossRefURL,
            isCrossRefPullRequest: isCrossRefPullRequest
        )
        return .event(event)
    }

    private static func parseLabel(_ raw: Any?) -> GitHubNotificationIssueLabel? {
        GitHubNotificationMapper.labels(from: raw.map { [$0] }).first
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? Int64 { return Int(value) }
        if let value = raw as? NSNumber { return value.intValue }
        return nil
    }

    private static func int64Value(_ raw: Any?) -> Int64? {
        if let value = raw as? Int64 { return value }
        if let value = raw as? Int { return Int64(value) }
        if let value = raw as? NSNumber { return value.int64Value }
        return nil
    }
}
