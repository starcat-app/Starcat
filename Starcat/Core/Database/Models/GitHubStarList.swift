//
//  GitHubStarList.swift
//  Starcat
//
//  GitHub Stars List 本地镜像模型。
//
//  设计边界：
//  - GitHub List 是远端对象，id 使用 GraphQL node id 字符串，不自造本地 id。
//  - GitHub 没有颜色字段；colorHex 是 Starcat 本地 UI 字段，不参与上传。
//  - repo 与 list 是多对多关系；远端快照落 `repo_github_star_lists`，组织限制下的
//    本地期望独立落 `repo_github_star_list_overrides`，两者不能混写。
//

import Foundation
import GRDB

/// GitHub Stars List 元数据。
struct GitHubStarList: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable, Sendable {

    static let databaseTableName = "github_star_lists"

    /// 现有 color_hex 列要求 NOT NULL，以空字符串持久化「无图标」，无需改动已发布 schema
    static let noColorHex = ""

    /// GitHub GraphQL `UserList.id`。
    var id: String
    var name: String
    var description: String?
    var isPrivate: Bool

    /// Starcat 本地颜色；空字符串表示不显示颜色图标，GitHub API 不提供这个字段
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

/// GitHub List 成员关系的本地覆盖状态。
enum GitHubStarListLocalOverrideSyncState: String, Codable, Sendable {
    /// GitHub 组织限制仍未解除，当前关系只在 Starcat 内生效。
    case pendingAuthorization = "pending_authorization"
    /// 远端 List 已删除等情况导致原意图无法继续合并，需要用户重新选择。
    case conflict
}

/// repo ↔ GitHub List 的本地期望差异。
///
/// 只保存与远端快照不同的行：`desiredPresent = true` 表示本地新增，`false` 表示
/// 本地移除。远端确认后 Repository 会删除已经收敛的覆盖行。
struct GitHubStarListLocalOverride: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    static let databaseTableName = "repo_github_star_list_overrides"

    var repoId: Int64
    var listId: String
    var desiredPresent: Bool
    var syncState: GitHubStarListLocalOverrideSyncState
    var failureReason: String?
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case repoId = "repo_id"
        case listId = "list_id"
        case desiredPresent = "desired_present"
        case syncState = "sync_state"
        case failureReason = "failure_reason"
        case updatedAt = "updated_at"
    }
}

/// 一次本地覆盖回写所需的完整仓库与目标集合。
struct GitHubStarListPendingMembershipSync: Equatable, Sendable {
    let repo: Repo
    let desiredListIDs: Set<String>
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
