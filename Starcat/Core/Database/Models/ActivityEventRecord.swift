//
//  ActivityEventRecord.swift
//  Starcat
//
//  Activity 公告与关注 PR-1（2026-06-16）：following 分类 GitHub Events feed
//  GRDB 持久化记录。对应 `activity_events` 表。
//
//  关键设计（详见 DatabaseMigrationsV1.createActivityEvents 注释）：
//  - `payloadJson` 全量直存 event payload，与 `releases.assets_json` 同款模式。
//    PR-2 在 ActivityViewModel 渲染时按 event_type 走 switch 反解码到具体子类型；
//    无法解码时 fallback 到事件名本身的文案，避免单行损坏阻塞整个 feed。
//  - `isRead` 是设备本地状态，**不挂 CloudKit**（dong4j 2026-06-16 决策 M2）。
//  - GitHub event id 是数字字符串（不是 Int64），所以 PK 用 String。
//  - `eventType` schema 不强制约束取值，由 Repository 写入层过滤 ReleaseEvent
//    （决策 Q1：避免与 `releases` 表双显）。
//

import Foundation
import GRDB

struct ActivityEventRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Identifiable {

    static let databaseTableName = "activity_events"

    /// GitHub event id（数字字符串，跨 actor 全局唯一）。
    var id: String

    /// GitHub Event 类型，如 "WatchEvent" / "ForkEvent" / "PushEvent" / "IssuesEvent" /
    /// "PullRequestEvent" / "CreateEvent" / "DiscussionEvent"。
    ///
    /// **schema 不强制约束**（SQLite 没 enum），由 Repository 层在写入前过滤掉
    /// `"ReleaseEvent"`（决策 Q1，避免与 `releases` 表双显）。
    /// 未来新增 event 类型只需在 Repository / UI 层加 case，不动 schema。
    var eventType: String

    /// 触发事件的 GitHub 用户登录名（如 `"ruanyf"`）。
    var actorLogin: String

    /// 触发用户头像 URL。可空：极个别历史 event 可能缺该字段。
    var actorAvatarUrl: String?

    /// `"owner/repo"` 形态全名，UI 直接渲染用。
    var repoName: String

    /// GitHub repo 数字 id，做反查索引用（如果 ViewModel 想在 feed 行点击后跳到该
    /// repo 详情，需要 id 而不是 name）。
    var repoId: Int64

    /// 完整 event payload 的 JSON 字符串。schema 因 eventType 而异——WatchEvent 只有
    /// `action`，PullRequestEvent 嵌套整个 `pull_request` 对象——UI 层按 event_type
    /// 走 switch 反解码。
    var payloadJson: String

    /// 用户已读状态。默认 false（未读）。device-local，不走 CloudKit。
    var isRead: Bool

    /// GitHub 事件触发时间（ISO8601 原文，原样保存）。
    /// 注意：GitHub events 服务端有 ~5 分钟缓存延迟，UI 不应承诺「实时」语义。
    var createdAt: String

    /// 本地拉取时间（ISO8601）。仅作 debug / 数据清理冷却判定用。
    var fetchedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case eventType = "event_type"
        case actorLogin = "actor_login"
        case actorAvatarUrl = "actor_avatar_url"
        case repoName = "repo_name"
        case repoId = "repo_id"
        case payloadJson = "payload_json"
        case isRead = "is_read"
        case createdAt = "created_at"
        case fetchedAt = "fetched_at"
    }
}
