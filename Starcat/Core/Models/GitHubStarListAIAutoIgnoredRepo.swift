//
//  GitHubStarListAIAutoIgnoredRepo.swift
//  Starcat
//
//  AI 仓库分组的持久化自动忽略标记。
//
//  仅记录可确定复现、重复调用也不会恢复的仓库级失败。当前只有 GitHub 组织
//  OAuth 限制属于这一类；普通网络或分析失败仍留在本轮任务中供重试。
//

import Foundation
import GRDB

enum GitHubStarListAIAutoIgnoreReason: String, Codable, Sendable {
    case organizationOAuthRestriction = "organization_oauth_restriction"
}

struct GitHubStarListAIAutoIgnoredRepo: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    static let databaseTableName = "github_star_list_ai_auto_ignored_repos"

    let repoId: Int64
    let reason: GitHubStarListAIAutoIgnoreReason
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case repoId = "repo_id"
        case reason
        case updatedAt = "updated_at"
    }
}
