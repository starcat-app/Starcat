//
//  ReleaseRepositoryProtocol.swift
//  Starcat
//
//  Release 元数据缓存 Repository 协议（HOM-47）。
//
//  关注点：
//  - 缓存"已订阅 repo 的 Release 列表"，时间线视图直接读，不打 GitHub API
//  - 已读 / 未读由 `markRead(_:)` 显式翻转
//  - Repository 不感知"何时应该再次拉取"——那是 ReleaseMonitor 的责任
//

import Foundation

/// 时间线视图行：把 Release + 它所属的 repo 一起返回，避免 UI 端再做 N+1 查询。
struct ReleaseTimelineEntry: Equatable, Identifiable {
    var release: ReleaseRecord
    var repo: Repo

    /// 复用 release.id 作为 SwiftUI list identity。
    var id: Int64 { release.id }
}

protocol ReleaseRepositoryProtocol: Sendable {

    // MARK: - 查询

    /// 取某 repo 缓存到的最新一条 Release（按 published_at desc 取首条）。
    func latest(forRepo repoId: Int64) async throws -> ReleaseRecord?

    /// 批量取各 repo 最新 release 时间（ISO8601），无缓存则不含该 repo_id。
    func latestPublishedAtByRepoIds(_ repoIds: [Int64]) async throws -> [Int64: String]

    /// 取某 repo 缓存到的所有 Releases，按 published_at desc。
    func fetch(forRepo repoId: Int64, limit: Int) async throws -> [ReleaseRecord]

    /// 时间线主查询：仅返回当前订阅且 is_subscribed=1 的 repo 的所有 Release。
    /// 联表 repos + release_subscriptions，按 published_at desc 排序，limit 截断。
    func fetchTimeline(limit: Int) async throws -> [ReleaseTimelineEntry]

    /// 当前未读 release 总数（用于 Sidebar Badge）。
    /// 仅统计当前订阅 repo（is_subscribed=1）下的 is_read=0 行。
    func unreadCount() async throws -> Int

    // MARK: - 写入

    /// 把后台轮询拿到的 Release 列表写库（INSERT OR REPLACE 形式）。
    /// `isReadDefault` 控制新插入行的 is_read：
    /// - 后台轮询发现新 Release：传 false（保持未读，让用户看 badge）
    /// - 首次订阅 priming 拉取（不通知用户）：传 true（直接标已读，避免一打开时间线全是高亮）
    func upsertMany(_ records: [ReleaseRecord], isReadDefault: Bool) async throws

    /// 标记单个 Release 为已读 / 未读。
    func markRead(releaseId: Int64, isRead: Bool) async throws

    /// 标记某 repo 下所有 Release 为已读（详情页"清未读"按钮）。
    func markAllRead(forRepo repoId: Int64) async throws

    /// 标记所有订阅下的 Release 为已读（时间线"全部已读"）。
    func markAllRead() async throws
}
