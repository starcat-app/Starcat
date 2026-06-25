//
//  GitHubStarList.swift
//  Starcat
//
//  GitHub Stars List 本地镜像模型。
//
//  设计边界：
//  - GitHub List 是远端对象，id 使用 GraphQL node id 字符串，不自造本地 id。
//  - GitHub 没有颜色字段；colorHex 是 Starcat 本地 UI 字段，不参与上传。
//  - repo 与 list 是多对多关系，所以关联独立落 `repo_github_star_lists`。
//

import Foundation
import GRDB

/// GitHub Stars List 元数据。
struct GitHubStarList: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable, Sendable {

    static let databaseTableName = "github_star_lists"

    /// GitHub GraphQL `UserList.id`。
    var id: String
    var name: String
    var description: String?
    var isPrivate: Bool

    /// Starcat 本地颜色；GitHub API 不提供这个字段。
    var colorHex: String

    /// 远端列表顺序。GitHub `lists` connection 没有 order 参数，按返回顺序落库。
    var position: Int

    var createdAt: String?
    var updatedAt: String?
    var syncedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case isPrivate = "is_private"
        case colorHex = "color_hex"
        case position
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case syncedAt = "synced_at"
    }
}

/// repo ↔ GitHub Stars List 关联。
struct GitHubStarListMembership: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {

    static let databaseTableName = "repo_github_star_lists"

    var repoId: Int64
    var listId: String

    enum CodingKeys: String, CodingKey {
        case repoId = "repo_id"
        case listId = "list_id"
    }
}

/// GitHub 远端 list 快照中的单个 list。
///
/// 这个类型不是数据库记录；Repository 会把它和已有本地颜色合并后转成 `GitHubStarList`。
struct GitHubStarListRemoteRecord: Equatable, Sendable {
    var id: String
    var name: String
    var description: String?
    var isPrivate: Bool
    var position: Int
    var createdAt: String?
    var updatedAt: String?
}

/// GitHub 远端 list membership。
///
/// 使用 `owner/name` 映射到本地 `repos.full_name`，避免把 GraphQL node id 混进
/// 当前以 REST numeric id 为主键的 repo 表。
struct GitHubStarListRemoteMembership: Equatable, Sendable {
    var listId: String
    var repoFullName: String
}

/// GitHub Stars List 颜色辅助。
///
/// Core 层不能反向依赖 `Features/Tags/TagColorPalette`，这里保留一份轻量候选色。
/// 颜色一旦落库后不会因为候选集调整自动变化；hash 只影响首次见到的远端 list。
enum GitHubStarListColor {
    static let defaultHex = "#0A84FF"

    private static let palette = [
        "#FF453A", "#FF9F0A", "#FFD60A", "#30D158",
        "#66D4CF", "#40C8E0", "#64D2FF", "#0A84FF",
        "#5E5CE6", "#BF5AF2", "#FF375F", "#AC8E68"
    ]

    /// 按 GitHub list id 做稳定 hash。不能用 Swift `Hasher`，因为它每进程随机播种。
    static func defaultColorHex(forListID id: String) -> String {
        guard !palette.isEmpty else { return defaultHex }
        var hash: UInt32 = 2166136261
        for byte in id.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16777619
        }
        return palette[Int(hash % UInt32(palette.count))]
    }
}

