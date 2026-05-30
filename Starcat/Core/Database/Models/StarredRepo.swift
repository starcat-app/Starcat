//
//  StarredRepo.swift
//  Starcat
//
//  用户 star 记录，对应 `starred_repos` 表。
//
//  设计意图：
//  - `repos` 表存仓库本身的元数据（可重建），`starred_repos` 存用户与仓库的关系（用户 star 时间、同步状态）
//  - 拆开是为了多账号场景（未来支持）和 user data 分区
//

import Foundation
import GRDB

/// star 关联记录。
struct StarredRepo: Codable, FetchableRecord, MutablePersistableRecord, Equatable {

    static let databaseTableName = "starred_repos"

    /// 关联 `repos.id`，同时也是本表主键（一个用户对同一 repo 只有一条记录）。
    var repoId: Int64

    /// GitHub 用户 ID（Int64）。
    var userId: Int64

    /// star 时间，ISO8601。
    var starredAt: String

    /// 同步状态：synced / pending / failed。MVP 实际只用到 synced。
    var syncStatus: String

    /// 最近一次同步成功时间。
    var lastSyncAt: String?

    enum CodingKeys: String, CodingKey {
        case repoId = "repo_id"
        case userId = "user_id"
        case starredAt = "starred_at"
        case syncStatus = "sync_status"
        case lastSyncAt = "last_sync_at"
    }
}
