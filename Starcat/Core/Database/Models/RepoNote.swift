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
/// **2026-06-12 重新设计**（dong4j 反馈）：原四态 `unread/reading/using/deprecated`
/// 简化为三态 `unread/read/using`，状态机：
/// ```
/// unread ──(README 加载完成自动)──▶ read ──(用户点击)──▶ using
///                                    ▲                    │
///                                    └──(× 取消)──────────┘
/// ```
/// - `.unread` —— 从未在详情页打开过 README（初始态；列表里"未写过 repo_notes 行"也按此处理）
/// - `.read`   —— README 已加载完毕（自动提升）
/// - `.using`  —— 用户显式标记"正在使用"（仅手动；× 按钮可降回 `.read`）
///
/// **存量数据兼容**：旧 rawValue `reading` / `deprecated` 通过 `parse(_:)` 统一回落到
/// `.read`（被动归一，不写迁移 SQL；下次用户改了再覆盖落库）。所有从 DB / UserDefaults
/// 读取裸 status 字符串的地方都必须用 `RepoStatus.parse(_:)`，**不能再用
/// `RepoStatus(rawValue:)`**——后者对旧值会返回 nil，造成静默丢状态。
///
/// 用 String enum 让 UI 端类型安全，落库时用 `rawValue`。
enum RepoStatus: String, CaseIterable, Codable {
    case unread // 未读
    case read   // 已读（v2 新增）
    case using  // 正在使用

    /// 把数据库 / UserDefaults 里的裸 status 字符串解析为枚举（lenient）。
    ///
    /// - `unread` / `read` / `using` → 对应 case
    /// - `reading` / `deprecated`    → `.read`（v1 → v2 兼容映射）
    /// - 其他未知值                  → `.read`（保守回落；避免无主状态丢失）
    static func parse(_ raw: String) -> RepoStatus {
        if let v = RepoStatus(rawValue: raw) { return v }
        // v1 旧值兼容
        switch raw {
        case "reading", "deprecated":
            return .read
        default:
            return .read
        }
    }

    /// SwiftUI 控件里展示的本地化标题。
    ///
    /// 这里保留 rawValue 作为落库值，显示文案单独走 localization key，
    /// 避免把中文 UI 文案写进数据库枚举协议里。
    var displayName: LocalizedStringKey {
        switch self {
        case .unread: return "repo.status.unread"
        case .read:   return "repo.status.read"
        case .using:  return "repo.status.using"
        }
    }

    /// 需要 plain String 的 API（例如 accessibilityLabel / navigationSubtitle）使用。
    var localizedDisplayName: String {
        switch self {
        case .unread: return String(localized: "repo.status.unread")
        case .read:   return String(localized: "repo.status.read")
        case .using:  return String(localized: "repo.status.using")
        }
    }
}

// MARK: - Notification.Name

extension Notification.Name {

    /// 仓库阅读状态变更事件（v2，2026-06-12 引入）。
    ///
    /// **发射时机**：`RepoNotesSectionViewModel` 的 `setStatus(...)` 与
    /// `markAsReadIfNeeded(...)` 落库 + `loadFor(...)` 重新加载 note 后立即 post。
    /// 即便 SQL 是 no-op（如 markAsReadIfNeeded 命中 using/read 行），post 也会执行
    /// —— 订阅方有 `applyStatusChange` 的二次幂等守卫，重复 post 不会产生副作用。
    ///
    /// **userInfo**：
    /// - `"repoId": Int64`  —— 状态变更对应的 repo.id
    /// - `"status": String` —— 落库后真实的 status rawValue（用 `RepoStatus.parse` 反解析）
    ///
    /// **订阅方**：`HomeViewModel.observeRepoStatusChanges()`，
    /// 收到后局部更新 `statusMap[repoId]` 并触发 `applyView()`，
    /// 让主列表 row 上的"未读 / 在用"角标即时刷新，无需 reloadItems 全量重拉。
    ///
    /// **为什么用 NotificationCenter 而非 environment 注入回调**：与 `.readmeDidLoad`
    /// 同理 —— 详情页（`RepoNotesSection`）和主列表（`RepoListView`）的 environment
    /// 链不直达，单纯为这个轻量信号挂 environment binding 过度工程。
    static let repoStatusDidChange = Notification.Name("StarcatRepoStatusDidChange")
}
