//
//  RepoTag.swift
//  Starcat
//
//  repo-tag 多对多关联表，对应 `repo_tags`。
//
//  复合主键 (repo_id, tag_id)，双向 ON DELETE CASCADE。
//

import Foundation
import GRDB

struct RepoTag: Codable, FetchableRecord, MutablePersistableRecord, Equatable {

    static let databaseTableName = "repo_tags"

    var repoId: Int64
    var tagId: String
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case repoId = "repo_id"
        case tagId = "tag_id"
        case createdAt = "created_at"
    }
}

// MARK: - Notification.Name

extension Notification.Name {
    /// 仓库标签关联变更事件。
    ///
    /// **发射时机**：`RepoTagRepository` 的 add/remove/setTags 成功落库后。
    /// 事件只携带 repo.id，订阅方如 Browser Plugin 事件桥会自行重新读取当前标签，
    /// 避免把标签快照拼装逻辑散落在多个写入路径。
    static let repoTagsDidChange = Notification.Name("StarcatRepoTagsDidChange")
}
