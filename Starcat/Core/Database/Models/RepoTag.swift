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
