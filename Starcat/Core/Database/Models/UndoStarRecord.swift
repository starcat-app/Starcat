//
//  UndoStarRecord.swift
//  Starcat
//
//  Unstar 历史记录模型，对应 `undo_star_history` 表。
//
//  生命周期：
//  - 用户 unstar 时写入（重复 unstar 更新 unstarred_at）
//  - 用户重新 star 时删除
//  - 7 天自动清理（后台定时任务）或用户手动清空
//

import Foundation
import GRDB

/// Undo Star 历史记录。
struct UndoStarRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "undo_star_history"

    /// GitHub repo ID（主键）。
    var ghRepoId: Int64
    var owner: String
    var name: String
    var fullName: String
    var repoDescription: String?
    var language: String?
    var starsCount: Int
    var forksCount: Int
    var watchersCount: Int
    var htmlUrl: String
    /// 最后一次 unstar 时间（ISO8601）。
    var unstarredAt: String

    var id: Int64 { ghRepoId }

    enum CodingKeys: String, CodingKey {
        case ghRepoId = "gh_repo_id"
        case owner
        case name
        case fullName = "full_name"
        case repoDescription = "description"
        case language
        case starsCount = "stars_count"
        case forksCount = "forks_count"
        case watchersCount = "watchers_count"
        case htmlUrl = "html_url"
        case unstarredAt = "unstarred_at"
    }
}

extension Notification.Name {
    /// Undo Star 历史记录变更（star 移除 / unstar 新增 / 清空）。
    static let undoStarHistoryDidChange = Notification.Name("StarcatUndoStarHistoryDidChange")
}
