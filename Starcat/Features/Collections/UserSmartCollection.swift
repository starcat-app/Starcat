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

/// 用户智能集合规则（scope + Manage 筛选 + 高阶 metadata / Health predicate）。
///
/// 高阶字段可选；nil 表示不参与过滤。字段之间 AND，不支持 OR / 嵌套组。
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

    // MARK: - 高阶 predicate（v2.1+）

    var starsMin: Int? = nil
    var starsMax: Int? = nil
    var pushedWithinDays: Int? = nil
    var pushedOlderThanDays: Int? = nil
    var healthScoreMin: Int? = nil
    var healthScoreMax: Int? = nil
    /// 项目健康度等级（A–E），空 = 不过滤。
    var healthGrades: [String] = []
    var requireLicense: Bool? = nil
    var requireTopics: Bool? = nil
    var requireNote: Bool? = nil

    // MARK: - v2.2 metadata / 时间

    var starredWithinDays: Int? = nil
    var starredOlderThanDays: Int? = nil
    var forksMin: Int? = nil
    var forksMax: Int? = nil
    var watchersMin: Int? = nil
    var watchersMax: Int? = nil
    /// scope 收窄后的额外语言过滤（空 = 不过滤）。
    var filterLanguages: [String] = []
    var requireDescription: Bool? = nil
    var requireHomepage: Bool? = nil

    // MARK: - v2.3 质量 / Release

    var maintenanceScoreMin: Int? = nil
    var popularityScoreMin: Int? = nil
    var qualityScoreMin: Int? = nil
    var securityScoreMin: Int? = nil
    var openSSFScoreMin: Int? = nil
    var releaseWithinDays: Int? = nil
    var updatedWithinDays: Int? = nil
    var updatedOlderThanDays: Int? = nil
    var createdWithinDays: Int? = nil
    var createdOlderThanDays: Int? = nil

    // MARK: - v2.4 标签 / 搜索

    var tagMatchModeRaw: String = SmartCollectionTagMatchMode.any.rawValue
    var excludedTagIDs: [String] = []
    var topicContains: String? = nil
    /// 语义搜索展示分阈值（0–100），仅 searchMode == semantic 且有 query 时生效。
    var semanticScoreMin: Int? = nil

    var tagMatchMode: SmartCollectionTagMatchMode {
        SmartCollectionTagMatchMode(rawValue: tagMatchModeRaw) ?? .any
    }

    var searchMode: SmartSearchMode {
        SmartSearchMode(rawValue: searchModeRaw) ?? .keyword
    }

    var status: RepoStatus? {
        statusRaw.map(RepoStatus.parse)
    }

    var sortOption: RepoSortOption {
        RepoSortOption(rawValue: sortRaw) ?? .starredAtDesc
    }

    /// 从已保存规则合并全部高阶 predicate；toolbar 快照只覆盖 Manage 基础字段。
    func mergingAdvanced(from stored: SmartCollectionRule) -> SmartCollectionRule {
        var merged = self
        merged.starsMin = stored.starsMin
        merged.starsMax = stored.starsMax
        merged.pushedWithinDays = stored.pushedWithinDays
        merged.pushedOlderThanDays = stored.pushedOlderThanDays
        merged.healthScoreMin = stored.healthScoreMin
        merged.healthScoreMax = stored.healthScoreMax
        merged.healthGrades = stored.healthGrades
        merged.requireLicense = stored.requireLicense
        merged.requireTopics = stored.requireTopics
        merged.requireNote = stored.requireNote
        merged.starredWithinDays = stored.starredWithinDays
        merged.starredOlderThanDays = stored.starredOlderThanDays
        merged.forksMin = stored.forksMin
        merged.forksMax = stored.forksMax
        merged.watchersMin = stored.watchersMin
        merged.watchersMax = stored.watchersMax
        merged.filterLanguages = stored.filterLanguages
        merged.requireDescription = stored.requireDescription
        merged.requireHomepage = stored.requireHomepage
        merged.maintenanceScoreMin = stored.maintenanceScoreMin
        merged.popularityScoreMin = stored.popularityScoreMin
        merged.qualityScoreMin = stored.qualityScoreMin
        merged.securityScoreMin = stored.securityScoreMin
        merged.openSSFScoreMin = stored.openSSFScoreMin
        merged.releaseWithinDays = stored.releaseWithinDays
        merged.updatedWithinDays = stored.updatedWithinDays
        merged.updatedOlderThanDays = stored.updatedOlderThanDays
        merged.createdWithinDays = stored.createdWithinDays
        merged.createdOlderThanDays = stored.createdOlderThanDays
        merged.tagMatchModeRaw = stored.tagMatchModeRaw
        merged.excludedTagIDs = stored.excludedTagIDs
        merged.topicContains = stored.topicContains
        merged.semanticScoreMin = stored.semanticScoreMin
        return merged
    }

    /// Health 总分与各维度 + Security 维为 Pro 能力。
    var usesProPredicates: Bool {
        healthScoreMin != nil
            || healthScoreMax != nil
            || !healthGrades.isEmpty
            || maintenanceScoreMin != nil
            || popularityScoreMin != nil
            || qualityScoreMin != nil
            || securityScoreMin != nil
    }

    /// @deprecated 命名保留一版，避免漏改调用点。
    var usesHealthPredicates: Bool { usesProPredicates }

    var needsOpenSSFContext: Bool { openSSFScoreMin != nil }

    var needsReleaseContext: Bool { releaseWithinDays != nil }

    var needsHealthSnapshots: Bool { usesProPredicates }

    static func encode(_ rule: SmartCollectionRule) throws -> String {
        let data = try JSONEncoder().encode(rule)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CocoaError(.coderInvalidValue)
        }
        return json
    }
}
