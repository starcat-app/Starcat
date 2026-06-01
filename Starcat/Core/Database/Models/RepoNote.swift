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
import SwiftUI

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

    /// SwiftUI 控件里展示的本地化标题。
    ///
    /// 这里保留 rawValue 作为落库值，显示文案单独走 localization key，
    /// 避免把中文 UI 文案写进数据库枚举协议里。
    var displayName: LocalizedStringKey {
        switch self {
        case .unread: return "repo.status.unread"
        case .reading: return "repo.status.reading"
        case .using: return "repo.status.using"
        case .deprecated: return "repo.status.deprecated"
        }
    }

    /// 需要 plain String 的 API（例如 accessibilityLabel / navigationSubtitle）使用。
    var localizedDisplayName: String {
        switch self {
        case .unread: return String(localized: "repo.status.unread")
        case .reading: return String(localized: "repo.status.reading")
        case .using: return String(localized: "repo.status.using")
        case .deprecated: return String(localized: "repo.status.deprecated")
        }
    }
}
