//
//  Tag.swift
//  Starcat
//
//  用户自定义标签，对应 `tags` 表。
//
//  关键约束：
//  - id 用 UUID 字符串（用户数据，与 GitHub Int64 id 区分）
//  - parent_id 自引用，支持嵌套标签；ON DELETE SET NULL
//  - is_preset 标识预设分类（v1 暂不预设；后续 P1 14 分类时使用）
//

import Foundation
import GRDB

/// 标签。
///
/// 标签是用户数据，CloudKit 同步时与 RepoTag 一起走 user-data zone（见 CloudKit 设计文档）。
struct Tag: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {

    static let databaseTableName = "tags"

    /// UUID 字符串。新建时由业务层生成，不依赖 SQLite rowid。
    var id: String

    var name: String

    /// 颜色 hex，如 `#FF5722`；可空，UI 缺省取主题色。
    var color: String?

    /// SF Symbol 名，如 `tag`；可空。
    var icon: String?

    var sortOrder: Int

    /// 是否预设分类（1=预设，0=用户自定义）。
    var isPreset: Bool

    /// 父标签 ID，nil 表示根标签。
    var parentId: String?

    var createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case color
        case icon
        case sortOrder = "sort_order"
        case isPreset = "is_preset"
        case parentId = "parent_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
