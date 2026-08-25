//
//  RepositorySpotlightSnapshot.swift
//  Starcat
//
//  Spotlight 索引使用的本地仓库快照。它只连接 repos 与 repo_notes，避免为了批量
//  建索引逐仓查询数据库；凭据、AI 对话、诊断日志等数据不会进入此模型。
//

import Foundation
import GRDB

/// 从当前用户数据库读取的 Spotlight 最小输入。
///
/// private repository 与用户笔记属于用户明确启用 Spotlight 后允许索引的本机内容；
/// `is_starred` 与 `access_state` 则在 SQL 层过滤，保证 Unstar 或不可访问仓库不会被构造。
struct RepositorySpotlightSnapshot: Decodable, FetchableRecord, Equatable, Sendable {
    let repositoryID: Int64
    let owner: String
    let name: String
    let repositoryDescription: String?
    let language: String?
    let topicsJSON: String?
    let note: String?

    enum CodingKeys: String, CodingKey {
        case repositoryID = "repository_id"
        case owner
        case name
        case repositoryDescription = "repository_description"
        case language
        case topicsJSON = "topics_json"
        case note
    }

    /// GitHub topics 在 repos 中以 JSON 数组保存；损坏数据不阻断整个 Spotlight 重建。
    var topics: [String] {
        guard let topicsJSON, let data = topicsJSON.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    var entity: RepositorySpotlightEntity {
        RepositorySpotlightEntity(
            repositoryID: repositoryID,
            owner: owner,
            name: name,
            repositoryDescription: repositoryDescription,
            language: language,
            topics: topics,
            note: note
        )
    }
}
