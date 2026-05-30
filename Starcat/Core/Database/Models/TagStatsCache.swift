//
//  TagStatsCache.swift
//  Starcat
//
//  标签统计缓存，对应 `tag_stats_cache` 表。
//
//  避免 Sidebar 每次进入都 COUNT(*) 全表扫描；在 RepoTag 增删时由业务层维护。
//

import Foundation
import GRDB

struct TagStatsCache: Codable, FetchableRecord, MutablePersistableRecord, Equatable {

    static let databaseTableName = "tag_stats_cache"

    var tagId: String
    var repoCount: Int
    var cachedAt: String

    enum CodingKeys: String, CodingKey {
        case tagId = "tag_id"
        case repoCount = "repo_count"
        case cachedAt = "cached_at"
    }
}
