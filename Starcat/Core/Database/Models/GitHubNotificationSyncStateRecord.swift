//
//  GitHubNotificationSyncStateRecord.swift
//  Starcat
//
//  通知时间线单行 meta。不塞进 `activity_sync_state`，避免和 following events 的 ETag 缠在一起。
//

import Foundation
import GRDB

struct GitHubNotificationSyncStateRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {

    static let singletonID = "singleton"
    static let databaseTableName = "github_notification_sync_state"

    var id: String
    var lastModified: String?
    var watermarkUpdatedAt: String?
    var lastFetchedAt: String?
    var backfillCompletedAt: String?
    var lastPollIntervalSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case lastModified = "last_modified"
        case watermarkUpdatedAt = "watermark_updated_at"
        case lastFetchedAt = "last_fetched_at"
        case backfillCompletedAt = "backfill_completed_at"
        case lastPollIntervalSeconds = "last_poll_interval_seconds"
    }
}
