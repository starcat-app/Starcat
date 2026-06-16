//
//  ActivitySyncStateRecord.swift
//  Starcat
//
//  Activity 公告与关注 PR-1（2026-06-16）：Activity 数据接入的单行 meta 表
//  GRDB 持久化记录。对应 `activity_sync_state` 表。
//
//  设计动机（详见 DatabaseMigrationsV1.createActivitySyncState 注释）：
//  - **ETag 304 短路**（dong4j 2026-06-16 决策 P3）：GitHub Events / Blog RSS 都支持
//    `If-None-Match` → 304 短路。落库让跨 App 重启复用，省 rate limit + 网络带宽。
//    参考 `sync_state.stars_etag` W4-4 C2 同款模式。
//  - **数据清理 ≥ 24h 判定**（决策 P6）：30 天数据清理不放主刷新路径，由 ViewModel
//    `reload` 完成网络刷新后异步派发 `cleanupIfNeeded()`——读 `last_cleanup_at`
//    判断「距上次清理 > 24h」才跑。
//
//  单行表设计：PK 固定字符串 `"singleton"`（与 `weekly_bulk_meta` 同款风格）。
//  所有写入都用 `singletonID` 做 PK，`save(_:)` 等价于 upsert。
//

import Foundation
import GRDB

struct ActivitySyncStateRecord: Codable, FetchableRecord, PersistableRecord, Equatable {

    /// 固定主键值——meta 表设计为只存一行，所有写入都用这个 id 覆写。
    static let singletonID = "singleton"

    static let databaseTableName = "activity_sync_state"

    var id: String

    /// `GET /users/{username}/received_events/public` 的 ETag（原样保留双引号）。
    /// 下次拉取走 `If-None-Match`，304 时 ViewModel 直接消费本地 `activity_events` 表。
    var eventsEtag: String?

    /// `github.blog/feed/` 的 ETag。
    var blogRssEtag: String?

    /// 上次成功拉 events 时间（ISO8601）。UI 显示「上次刷新 X 分钟前」+ TTL 判定。
    var lastEventsFetchedAt: String?

    /// 上次成功拉 blog rss 时间（ISO8601）。
    var lastBlogFetchedAt: String?

    /// 上次成功跑 security advisory 范围扫描时间（ISO8601）。
    /// 注意：security advisory 是 per-repo 端点（每个 starred repo 一次独立请求），
    /// 这里只记录「整批扫描」完成时间，单 repo 的 ETag / 304 短路如未来需要支持
    /// 应该走独立的 `activity_security_etag(repo_id, etag, ...)` 表。
    var lastSecurityFetchedAt: String?

    /// 上次跑 30 天数据清理时间（ISO8601）。`cleanupIfNeeded()` 读这个字段判定
    /// 「距上次清理 > 24h」才执行 `DELETE ... WHERE created_at < datetime('now', '-30 days')`。
    var lastCleanupAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case eventsEtag = "events_etag"
        case blogRssEtag = "blog_rss_etag"
        case lastEventsFetchedAt = "last_events_fetched_at"
        case lastBlogFetchedAt = "last_blog_fetched_at"
        case lastSecurityFetchedAt = "last_security_fetched_at"
        case lastCleanupAt = "last_cleanup_at"
    }
}
