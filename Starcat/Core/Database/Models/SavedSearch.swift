//
//  SavedSearch.swift
//  Starcat
//
//  保存的搜索条件，对应 `saved_searches` 表。
//
//  query 字段存 JSON 字符串，包含字段名、过滤条件、排序等。
//  这里不固化 query 的 Swift 结构（避免每次扩展过滤条件都改 schema），由搜索模块自行解析。
//

import Foundation
import GRDB

struct SavedSearch: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {

    static let databaseTableName = "saved_searches"

    var id: String

    var name: String

    /// 搜索条件 JSON。
    var query: String

    var createdAt: String
    var updatedAt: String
    var lastUsedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case query
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastUsedAt = "last_used_at"
    }
}
