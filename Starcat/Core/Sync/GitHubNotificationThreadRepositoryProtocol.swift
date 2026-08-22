//
//  GitHubNotificationThreadRepositoryProtocol.swift
//  Starcat
//
//  通知 thread 本地缓存。同步策略（回填 300 / 水位 / PATCH）在 InboxService，这里只做 CRUD。
//

import Foundation

enum GitHubTimelineCredentialSource: String, Sendable {
    case primaryOAuth = "primary_oauth"
    case projectAccess = "project_access"
}

struct GitHubOrganizationIssueSyncStateRecord: Equatable, Sendable {
    let organizationLogin: String
    let credentialSource: GitHubTimelineCredentialSource
    let nextPage: Int?
    let watermarkUpdatedAt: String?
    let backfillCompletedAt: String?
    let lastFetchedAt: String?
    let lastError: String?
}

protocol GitHubNotificationThreadRepositoryProtocol: Sendable {
    func fetchAll(limit: Int) async throws -> [GitHubNotificationThreadRecord]
    func fetch(id: String) async throws -> GitHubNotificationThreadRecord?
    func unreadCount() async throws -> Int
    /// 中栏面包屑副标题用总数；侧栏角标仍走 `unreadCount()`。
    func totalCount() async throws -> Int
    func upsertMany(_ records: [GitHubNotificationThreadRecord]) async throws
    /// 组织 Issue 与通知按 `subject_api_url` 合并；没有通知来源时 unread 永远为 false。
    func upsertOrganizationIssues(
        _ issues: [GitHubOrganizationIssue],
        credentialSource: GitHubTimelineCredentialSource,
        fetchedAt: String
    ) async throws
    func updateLocalUnread(
        id: String,
        unread: Bool,
        markReadState: GitHubNotificationMarkReadState,
        githubUnread: Bool?
    ) async throws
    func updateHydration(
        id: String,
        actorLogin: String?,
        excerpt: String?,
        commentsJson: String?,
        htmlUrl: String?,
        subjectCreatedAt: String?,
        hydratedAt: String,
        labelsJson: String?
    ) async throws
    /// 把 hydrate / 关闭 / 重开得到的 `open|closed|merged` 写回 `issue_state`。
    /// 通知增量 upsert 用 COALESCE 保这列，避免列表 API 没有状态时把已知值抹掉。
    func updatePersistedIssueState(id: String, state: String) async throws
    /// 打开 / 关闭 / 已合并筛选前，先给还没有 `issue_state` 的 Issue / PR 补 GET。
    func fetchIDsMissingIssueState(limit: Int) async throws -> [String]

    func markNotified(ids: [String], notifiedAt: String) async throws
    func fetchFailedMarkRead() async throws -> [GitHubNotificationThreadRecord]
    /// 还没发过系统通知的 thread。回填入库后会先 markNotified，避免历史条目在增量里补发。
    func fetchUnnotified() async throws -> [GitHubNotificationThreadRecord]
    func maxUpdatedAt() async throws -> String?
    func organizationIssueSyncState(
        organization: String,
        credentialSource: GitHubTimelineCredentialSource
    ) async throws -> GitHubOrganizationIssueSyncStateRecord?
    func updateOrganizationIssueSyncState(
        organization: String,
        credentialSource: GitHubTimelineCredentialSource,
        nextPage: Int?,
        watermarkUpdatedAt: String?,
        backfillCompletedAt: String?,
        lastFetchedAt: String?,
        lastError: String?
    ) async throws
    /// 清掉本机演示 thread。前缀由调用方保证是 `starcat-demo-` 这种字面量。
    func deleteIDs(withPrefix prefix: String) async throws
    /// 标 Done 成功后删这一行。空 id 直接忽略。
    func delete(id: String) async throws
    /// Done 只移除通知 overlay；同一会话仍由组织 Issue 可见时必须保留本地会话。
    func removeNotificationThread(id: String) async throws
}

extension GitHubNotificationThreadRepositoryProtocol {
    func updateLocalUnread(
        id: String,
        unread: Bool,
        markReadState: GitHubNotificationMarkReadState
    ) async throws {
        try await updateLocalUnread(id: id, unread: unread, markReadState: markReadState, githubUnread: nil)
    }
}

protocol GitHubNotificationSyncStateRepositoryProtocol: Sendable {
    func current() async throws -> GitHubNotificationSyncStateRecord?
    /// 只清同步游标，让下一次同步重新走历史回填；通知行和本地已读状态必须保留。
    func resetForBackfill() async throws
    func updateAfterFetch(
        lastModified: String?,
        watermarkUpdatedAt: String?,
        lastFetchedAt: Date,
        backfillCompleted: Bool,
        pollIntervalSeconds: Int?
    ) async throws
}
