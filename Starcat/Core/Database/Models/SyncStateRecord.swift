//
//  SyncStateRecord.swift
//  Starcat
//
//  同步状态持久化记录，对应 `sync_state` 表。
//
//  命名加 Record 后缀是因为 `SyncState` 在 SyncManager 里用作 enum 类型，避免歧义。
//

import Foundation
import GRDB

struct SyncStateRecord: Codable, FetchableRecord, MutablePersistableRecord, Equatable {

    static let databaseTableName = "sync_state"

    var userId: Int64
    var lastSyncAt: String?
    var lastIncrementalAt: String?

    /// 远端 stars 总数。
    var starredCount: Int

    /// 本地已同步数。
    var syncedCount: Int

    /// 失败计数（用于 UI 显示同步健康度）。
    var failedCount: Int

    /// 状态：idle / syncing / failed。
    var syncStatus: String

    /// 上次失败的错误消息（脱敏后）。
    var errorMessage: String?

    /// W4-4 C2：上次同步 `/user/starred?page=1` 时服务端返回的 ETag（含双引号原样保留）。
    /// 用于下次同步带 `If-None-Match`，命中 304 时早退跳过全量。
    /// 仅记录 page 1 的 ETag —— 见 SyncManager 头部对 ETag 早退语义的说明。
    var starsEtag: String?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case lastSyncAt = "last_sync_at"
        case lastIncrementalAt = "last_incremental_at"
        case starredCount = "starred_count"
        case syncedCount = "synced_count"
        case failedCount = "failed_count"
        case syncStatus = "sync_status"
        case errorMessage = "error_message"
        case starsEtag = "stars_etag"
    }
}
