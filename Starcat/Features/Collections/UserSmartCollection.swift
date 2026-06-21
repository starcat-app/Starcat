//
//  UserSmartCollection.swift
//  Starcat
//
//  用户自定义智能集合的数据模型。
//
//  第一版只保存"当前 Manage 筛选快照"，不做任意条件树。这样可以复用现有列表过滤
//  能力，同时避免一开始就引入复杂 rule builder。
//

import Foundation
import GRDB

/// 用户自定义智能集合。
///
/// `ruleJSON` 存结构化规则而不是一整段查询字符串：后续要加可视化编辑器、AI 生成规则草稿
/// 或 CloudKit 同步时，都能明确知道每个条件字段的含义。
struct UserSmartCollection: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable, Sendable {
    static let databaseTableName = "smart_collections"

    var id: String
    var name: String
    var icon: String
    var color: String?
    var ruleJSON: String
    var sortOrder: Int
    var createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case icon
        case color
        case ruleJSON = "rule_json"
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var rule: SmartCollectionRule? {
        guard let data = ruleJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SmartCollectionRule.self, from: data)
    }
}

/// 用户智能集合第一版规则。
///
/// 规则只表达当前 Manage 列表已经存在的筛选能力；不支持 OR / nested group，是刻意收窄。
struct SmartCollectionRule: Codable, Equatable, Sendable {
    enum Scope: Codable, Equatable, Sendable {
        case allStars
        case untagged
        case language(String?)
        case tag(String)
    }

    var scope: Scope
    var query: String?
    var searchModeRaw: String
    var statusRaw: String?
    var selectedTagIDs: [String]
    var hideArchived: Bool
    var hideForks: Bool
    var sortRaw: String

    var searchMode: SmartSearchMode {
        SmartSearchMode(rawValue: searchModeRaw) ?? .keyword
    }

    var status: RepoStatus? {
        statusRaw.map(RepoStatus.parse)
    }

    var sortOption: RepoSortOption {
        RepoSortOption(rawValue: sortRaw) ?? .starredAtDesc
    }

    static func encode(_ rule: SmartCollectionRule) throws -> String {
        let data = try JSONEncoder().encode(rule)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CocoaError(.coderInvalidValue)
        }
        return json
    }
}
