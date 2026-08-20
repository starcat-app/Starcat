//
//  UserRepoActivityRecord.swift
//  Starcat
//
//  当前用户自己的 Star / Unstar / Fork 账本，对应 `user_repo_activity`。
//
//  为什么单独建表：通知时间线要混入这些事件，但 `github_notification_threads`
//  的主键和 PATCH / Done 都按 GitHub thread。`starred_repos` 是当前关系快照，
//  unstar 后行会消失；`undo_star_history` 每个仓库只留一条，给撤销列表用。
//  本表只追加，同一仓库可以 Star → Unstar → Star 多行。
//

import Foundation
import GRDB

enum UserRepoActivityKind: String, Codable, Sendable {
    case star
    case unstar
    case fork
}

enum UserRepoActivitySource: String, Codable, Sendable {
    /// App 内 `StarActionService` 成功之后立刻写入。
    case starcat
    /// Stars / 我的项目同步发现的网页操作或历史回填。
    case githubSync = "github_sync"
}

/// 当前登录用户。GitHub `id` 稳定；`userName` 存 `login`（可改名），给人看和导出用。
struct UserRepoActivityActor: Equatable, Sendable {
    let userID: Int64
    let userName: String

    init(userID: Int64, userName: String) {
        self.userID = userID
        self.userName = userName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isIdentified: Bool { !userName.isEmpty }
}

/// 账本一行。id 按 kind/source/repo/时间拼，重复回填可以 INSERT OR IGNORE。
struct UserRepoActivityRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Identifiable, Sendable {

    static let databaseTableName = "user_repo_activity"

    var id: String
    var kind: UserRepoActivityKind
    var source: UserRepoActivitySource
    var repoId: Int64
    var fullName: String
    var htmlUrl: String
    var occurredAt: String
    var createdAt: String
    /// GitHub 数字 id。v24 旧行在打开时间线回填前可能为 nil。
    var userId: Int64?
    /// GitHub `login`。列名按产品约定叫 `user_name`。
    var userName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case source
        case repoId = "repo_id"
        case fullName = "full_name"
        case htmlUrl = "html_url"
        case occurredAt = "occurred_at"
        case createdAt = "created_at"
        case userId = "user_id"
        case userName = "user_name"
    }

    /// 时间线 / 回填共用：不要带小数秒，才能和 GitHub 通知的 `updated_at` 按字符串混排。
    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Stars 同步的 `starred_at` 可能带小数秒；先解析再格式化，避免和通知时间对不上。
    static func normalizedTimestamp(_ raw: String, fallback: Date = Date()) -> String {
        if let date = ISO8601DateFormatter.githubDate(from: raw) {
            return timestamp(date)
        }
        return timestamp(fallback)
    }

    static func makeID(
        kind: UserRepoActivityKind,
        source: UserRepoActivitySource,
        repoID: Int64,
        occurredAt: String
    ) -> String {
        "\(kind.rawValue):\(source.rawValue):\(repoID):\(occurredAt)"
    }
}

/// 时间线列表用：账本行 + 本地仓库说明（没有仓库行时 snippet 为空）。
struct UserRepoActivityListItem: Equatable, Identifiable, Sendable {
    let record: UserRepoActivityRecord
    let snippet: String?
    let ownerLogin: String?
    /// 本地 `repos.language`；没有仓库行或语言为空时为 nil。
    let language: String?

    var id: String { record.id }
}

extension Notification.Name {
    /// 账本新增 Star / Unstar / Fork。通知时间线听这个刷新第一页。
    static let userRepoActivityDidChange = Notification.Name("starcat.userRepoActivityDidChange")
}
