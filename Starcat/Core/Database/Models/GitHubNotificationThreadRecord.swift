//
//  GitHubNotificationThreadRecord.swift
//  Starcat
//
//  GitHub 通知时间线：`github_notification_threads` 一行。
//
//  为什么单独建表：活动「关注」用的 `activity_events` 来自 received_events，
//  actor 是「被关注的人」，并且会丢掉 ReleaseEvent。通知 inbox 是「别人对当前用户
//  做的事」，按 thread id upsert，不能混进那张表。
//

import Foundation
import GRDB

/// GitHub thread 在本地的已读同步状态。
///
/// `pending`：用户已停在这一行、PATCH 还没回来。增量同步不得把蓝点打回去。
/// `synced`：已经 PATCH 成功。GitHub 列表短暂仍 unread 时也不能闪回蓝点。
/// `failed`：PATCH 失败，下次同步结束后重试；本地保持已读，等重试，不拿 GitHub unread 校准回来。
enum GitHubNotificationMarkReadState: String, Codable, Sendable {
    case idle
    case pending
    case synced
    case failed
}

struct GitHubNotificationThreadRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Identifiable, Sendable {

    static let databaseTableName = "github_notification_threads"

    var id: String
    var reason: String
    var unread: Bool
    var githubUnread: Bool
    var repositoryId: Int64?
    var repositoryFullName: String
    var subjectTitle: String
    var subjectType: String
    var subjectApiUrl: String
    var subjectNumber: Int?
    var htmlUrl: String?
    var actorLogin: String?
    var subjectCreatedAt: String?
    var excerpt: String?
    var commentsJson: String?
    var hydratedAt: String?
    var updatedAt: String
    var firstSeenAt: String
    var notifiedAt: String?
    var markReadState: String
    var fetchedAt: String

    var markReadStateValue: GitHubNotificationMarkReadState {
        GitHubNotificationMarkReadState(rawValue: markReadState) ?? .idle
    }

    enum CodingKeys: String, CodingKey {
        case id
        case reason
        case unread
        case githubUnread = "github_unread"
        case repositoryId = "repository_id"
        case repositoryFullName = "repository_full_name"
        case subjectTitle = "subject_title"
        case subjectType = "subject_type"
        case subjectApiUrl = "subject_api_url"
        case subjectNumber = "subject_number"
        case htmlUrl = "html_url"
        case actorLogin = "actor_login"
        case subjectCreatedAt = "subject_created_at"
        case excerpt
        case commentsJson = "comments_json"
        case hydratedAt = "hydrated_at"
        case updatedAt = "updated_at"
        case firstSeenAt = "first_seen_at"
        case notifiedAt = "notified_at"
        case markReadState = "mark_read_state"
        case fetchedAt = "fetched_at"
    }
}
