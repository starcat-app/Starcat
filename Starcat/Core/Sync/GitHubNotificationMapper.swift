//
//  GitHubNotificationMapper.swift
//  Starcat
//
//  通知 JSON → 本地行、reason chip、降级 GitHub Web URL。
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
}

enum GitHubNotificationMapper {

    static let backfillLimit = 300
    static let pageSize = 50
    static let excerptLimit = 500
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
        }
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

    static func truncatedExcerpt(_ body: String?) -> String? {
        guard let body, !body.isEmpty else { return nil }
        if body.count <= excerptLimit { return body }
        let end = body.index(body.startIndex, offsetBy: excerptLimit)
        return String(body[..<end])
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
            excerpt: nil,
            hydratedAt: nil,
            updatedAt: dto.updatedAt,
            firstSeenAt: firstSeenAt,
            notifiedAt: nil,
            markReadState: GitHubNotificationMarkReadState.idle.rawValue,
            fetchedAt: fetchedAt
        )
    }
}

/// 通知分类内的分段筛选（全部 / 未读 / Mention / Review）。
enum GitHubNotificationSegment: String, CaseIterable, Identifiable, Sendable {
    case all
    case unread
    case mention
    case review

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .all: return "activity.notification.segment.all"
        case .unread: return "activity.notification.segment.unread"
        case .mention: return "activity.notification.segment.mention"
        case .review: return "activity.notification.segment.review"
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
