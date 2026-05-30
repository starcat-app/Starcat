//
//  RepoNote.swift
//  Starcat
//
//  仓库私有笔记 + 状态，对应 `repo_notes` 表。
//
//  关键约束：
//  - 一个 repo 对应至多一条笔记，故 repo_id 直接作主键
//  - status 用字符串而非 enum 入库，避免 schema 与 Swift enum 强耦合；解析在业务层
//

import Foundation
import GRDB

struct RepoNote: Codable, FetchableRecord, MutablePersistableRecord, Equatable {

    static let databaseTableName = "repo_notes"

    /// 关联 repos.id。
    var repoId: Int64

    /// Markdown 笔记正文。
    var content: String?

    /// 状态字符串，参考 `RepoStatus`；存裸字符串以便 SQL 直接过滤。
    var status: String

    /// 是否 AI 生成（P1+ 使用，v1 始终为 false）。
    var isAIGenerated: Bool

    /// 最后编辑时间，ISO8601。
    var editedAt: String?

    enum CodingKeys: String, CodingKey {
        case repoId = "repo_id"
        case content
        case status
        case isAIGenerated = "is_ai_generated"
        case editedAt = "edited_at"
    }
}

/// 仓库阅读 / 使用状态。
///
/// 用 String enum 让 UI 端类型安全，落库时用 `rawValue`。
enum RepoStatus: String, CaseIterable, Codable {
    case unread     // 未读
    case reading    // 阅读中
    case using      // 已采用
    case deprecated // 已废弃

    var displayName: String {
        switch self {
        case .unread: return "未读"
        case .reading: return "阅读中"
        case .using: return "已采用"
        case .deprecated: return "已废弃"
        }
    }
}
