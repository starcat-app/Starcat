//
//  GitHubNotificationThreadRepositoryProtocol.swift
//  Starcat
//
//  通知 thread 本地缓存。同步策略（回填 300 / 水位 / PATCH）在 InboxService，这里只做 CRUD。
//

import Foundation

protocol GitHubNotificationThreadRepositoryProtocol: Sendable {
    func fetchAll(limit: Int) async throws -> [GitHubNotificationThreadRecord]
    func fetch(id: String) async throws -> GitHubNotificationThreadRecord?
    func unreadCount() async throws -> Int
    /// 中栏面包屑副标题用总数；侧栏角标仍走 `unreadCount()`。
    func totalCount() async throws -> Int
    func upsertMany(_ records: [GitHubNotificationThreadRecord]) async throws
    func updateLocalUnread(id: String, unread: Bool, markReadState: GitHubNotificationMarkReadState) async throws
    func updateHydration(
        id: String,
        actorLogin: String?,
        excerpt: String?,
        commentsJson: String?,
        htmlUrl: String?,
        subjectCreatedAt: String?,
        hydratedAt: String
    ) async throws

    func markNotified(ids: [String], notifiedAt: String) async throws
    func fetchFailedMarkRead() async throws -> [GitHubNotificationThreadRecord]
    /// 还没发过系统通知的 thread。回填入库后会先 markNotified，避免历史条目在增量里补发。
    func fetchUnnotified() async throws -> [GitHubNotificationThreadRecord]
    func maxUpdatedAt() async throws -> String?
    /// 清掉本机演示 thread。前缀由调用方保证是 `starcat-demo-` 这种字面量。
    func deleteIDs(withPrefix prefix: String) async throws
}

protocol GitHubNotificationSyncStateRepositoryProtocol: Sendable {
    func current() async throws -> GitHubNotificationSyncStateRecord?
    func updateAfterFetch(
        lastModified: String?,
        watermarkUpdatedAt: String?,
        lastFetchedAt: Date,
        backfillCompleted: Bool,
        pollIntervalSeconds: Int?
    ) async throws
}
