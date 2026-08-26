//
//  GitHubStarListAIRule.swift
//  Starcat
//
//  GitHub List 的 Starcat 本地 AI 分组规则。
//
//  关键边界：
//  - 规则只保存在当前账号数据库，不属于 GitHub List 远端模型；
//  - 执行 AI 整理时规则会发送给用户配置的 AI Provider；
//  - 空规则表示该 List 不参与 AI 整理，自动应用默认关闭。
//

import Foundation
import GRDB

/// 用户为现有 GitHub List 定义的闭集分类规则。
struct GitHubStarListAIRule: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {

    static let databaseTableName = "github_star_list_ai_rules"

    var listId: String
    var instruction: String
    var autoApplyEnabled: Bool
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case listId = "list_id"
        case instruction
        case autoApplyEnabled = "auto_apply_enabled"
        case updatedAt = "updated_at"
    }
}
