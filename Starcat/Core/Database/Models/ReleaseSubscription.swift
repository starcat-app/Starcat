//
//  ReleaseSubscription.swift
//  Starcat
//
//  Release 订阅记录（HOM-47）。对应 `release_subscriptions` 表。
//
//  关键约束：
//  - 一个 repo 最多对应一条订阅记录，故 repo_id 直接做主键
//  - `lastKnownReleaseId` / `lastKnownTagName` 是后台轮询的"上次见过的最新 Release"游标，
//    用来在下次轮询比对："出现了哪个 release_id ≠ lastKnown 的新 Release 需要通知"
//    （不能仅靠时间戳判断：作者可以 backdate published_at；用 release id 单调递增更稳）
//  - 与 CloudKit 同步设计 §2.7 对齐：`isSubscribed` / `notifyEnabled` / `modifiedAt` 都是
//    跨端同步字段，CloudKit 接入时直接映射
//

import Foundation
import GRDB

struct ReleaseSubscription: Codable, FetchableRecord, MutablePersistableRecord, Equatable {

    static let databaseTableName = "release_subscriptions"

    /// 关联 repos.id。
    var repoId: Int64

    /// 是否订阅。取消订阅时 UI 应保留行（仅置 false），便于用户重新订阅时恢复
    /// `lastKnownReleaseId` 不重新触发"补发历史 Release 通知"。
    var isSubscribed: Bool

    /// 是否在新 Release 出现时推送系统通知（与 isSubscribed 解耦，未来可"订阅但静默"）。
    var notifyEnabled: Bool

    /// 上次轮询时见过的最新 Release id（GitHub 全局唯一）。
    /// 首次订阅时会立即拉一页 releases 并把最新一条写入这里，避免给用户补推一堆历史 Release。
    var lastKnownReleaseId: Int64?

    /// 上次见过的最新 tag_name，仅作辅助日志 / UI 展示，不参与新旧判定。
    var lastKnownTagName: String?

    /// 上次后台轮询完成时间（ISO8601）。
    var lastPolledAt: String?

    /// 订阅创建时间（ISO8601），CloudKit 同步用。
    var createdAt: String

    /// 最近修改时间（ISO8601），CloudKit Last-Write-Wins 用。
    var modifiedAt: String

    enum CodingKeys: String, CodingKey {
        case repoId = "repo_id"
        case isSubscribed = "is_subscribed"
        case notifyEnabled = "notify_enabled"
        case lastKnownReleaseId = "last_known_release_id"
        case lastKnownTagName = "last_known_tag_name"
        case lastPolledAt = "last_polled_at"
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
    }
}

// MARK: - Notification.Name

extension Notification.Name {

    /// Release 订阅状态变更事件。
    ///
    /// 只在用户主动订阅 / 取消订阅成功后发射，用来让 Sidebar 的订阅总数即时刷新。
    /// 后台轮询只更新游标，不改变 `isSubscribed`，因此不需要发射这个通知。
    static let releaseSubscriptionDidChange = Notification.Name("StarcatReleaseSubscriptionDidChange")
}
