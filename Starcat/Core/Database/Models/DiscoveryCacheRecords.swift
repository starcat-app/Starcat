//
//  DiscoveryCacheRecords.swift
//  Starcat
//
//  starcat-discovery-api 客户端 SQLite 缓存 record。
//
//  设计约束:
//  - 这些表只保存公开探索服务返回的可重建快照,不与用户 starred repos 主表混用;
//  - 缓存 key 由 mode + filter + sort 决定,page 单独入主键,支持分页缓存;
//  - topics / platforms / reasons / signals 保持 JSON 字符串,避免为 endpoint-specific payload
//    拆出一组没有业务复用价值的子表。
//

import Foundation
import GRDB

/// `discovery_list_pages` 表行映射。
struct DiscoveryListPageRecord: Codable, FetchableRecord, PersistableRecord, Equatable {

    static let databaseTableName = "discovery_list_pages"

    var cacheKey: String
    var page: Int
    var total: Int
    var pageSize: Int
    var nextPage: Int?
    var cachedAt: String

    enum CodingKeys: String, CodingKey {
        case cacheKey = "cache_key"
        case page
        case total
        case pageSize = "page_size"
        case nextPage = "next_page"
        case cachedAt = "cached_at"
    }
}

/// `discovery_list_items` 表行映射。
struct DiscoveryListItemRecord: Codable, FetchableRecord, PersistableRecord, Equatable {

    static let databaseTableName = "discovery_list_items"

    var cacheKey: String
    var page: Int
    var sortOrder: Int
    var repoID: Int64
    var fullName: String
    var owner: String
    var name: String
    var description: String?
    var homepage: String?
    var language: String?
    var stars: Int
    var forks: Int
    var watchers: Int
    var subscribers: Int
    var openIssues: Int
    var ownerAvatar: String?
    var defaultBranch: String?
    var licenseSpdx: String?
    var topicsJSON: String
    var platformsJSON: String
    var pushedAt: String?
    var updatedAt: String?
    var createdAt: String?
    var isArchived: Bool
    var isFork: Bool
    var latestReleaseTag: String?
    var latestReleaseAt: String?
    var latestReleaseURL: String?
    var releaseDownloadCount: Int
    var itemRank: Int?
    var score: Double?
    var reasonsJSON: String
    var signalsJSON: String
    var cachedAt: String

    enum CodingKeys: String, CodingKey {
        case cacheKey = "cache_key"
        case page
        case sortOrder = "sort_order"
        case repoID = "repo_id"
        case fullName = "full_name"
        case owner
        case name
        case description
        case homepage
        case language
        case stars
        case forks
        case watchers
        case subscribers
        case openIssues = "open_issues"
        case ownerAvatar = "owner_avatar"
        case defaultBranch = "default_branch"
        case licenseSpdx = "license_spdx"
        case topicsJSON = "topics_json"
        case platformsJSON = "platforms_json"
        case pushedAt = "pushed_at"
        case updatedAt = "updated_at"
        case createdAt = "created_at"
        case isArchived = "is_archived"
        case isFork = "is_fork"
        case latestReleaseTag = "latest_release_tag"
        case latestReleaseAt = "latest_release_at"
        case latestReleaseURL = "latest_release_url"
        case releaseDownloadCount = "release_download_count"
        case itemRank = "item_rank"
        case score
        case reasonsJSON = "reasons_json"
        case signalsJSON = "signals_json"
        case cachedAt = "cached_at"
    }

    func toDomain() -> DiscoveryRepoDTO {
        DiscoveryRepoDTO(
            repoID: repoID,
            fullName: fullName,
            owner: owner,
            name: name,
            description: description,
            homepage: homepage,
            language: language,
            stars: stars,
            forks: forks,
            watchers: watchers,
            subscribers: subscribers,
            openIssues: openIssues,
            ownerAvatar: ownerAvatar,
            defaultBranch: defaultBranch,
            licenseSpdx: licenseSpdx,
            topics: Self.decode([String].self, from: topicsJSON) ?? [],
            platforms: Self.decode([String].self, from: platformsJSON) ?? [],
            pushedAt: pushedAt,
            updatedAt: updatedAt,
            createdAt: createdAt,
            isArchived: isArchived,
            isFork: isFork,
            latestReleaseTag: latestReleaseTag,
            latestReleaseAt: latestReleaseAt,
            latestReleaseURL: latestReleaseURL,
            releaseDownloadCount: releaseDownloadCount,
            rank: itemRank,
            score: score,
            reasons: Self.decode([String].self, from: reasonsJSON) ?? [],
            signals: Self.decode([DiscoverySignalDTO].self, from: signalsJSON) ?? []
        )
    }

    static func from(
        _ dto: DiscoveryRepoDTO,
        cacheKey: String,
        page: Int,
        sortOrder: Int,
        cachedAt: Date
    ) -> DiscoveryListItemRecord {
        DiscoveryListItemRecord(
            cacheKey: cacheKey,
            page: page,
            sortOrder: sortOrder,
            repoID: dto.repoID,
            fullName: dto.fullName,
            owner: dto.owner,
            name: dto.name,
            description: dto.description,
            homepage: dto.homepage,
            language: dto.language,
            stars: dto.stars,
            forks: dto.forks,
            watchers: dto.watchers,
            subscribers: dto.subscribers,
            openIssues: dto.openIssues,
            ownerAvatar: dto.ownerAvatar,
            defaultBranch: dto.defaultBranch,
            licenseSpdx: dto.licenseSpdx,
            topicsJSON: encode(dto.topics),
            platformsJSON: encode(dto.platforms),
            pushedAt: dto.pushedAt,
            updatedAt: dto.updatedAt,
            createdAt: dto.createdAt,
            isArchived: dto.isArchived,
            isFork: dto.isFork,
            latestReleaseTag: dto.latestReleaseTag,
            latestReleaseAt: dto.latestReleaseAt,
            latestReleaseURL: dto.latestReleaseURL,
            releaseDownloadCount: dto.releaseDownloadCount,
            itemRank: dto.rank,
            score: dto.score,
            reasonsJSON: encode(dto.reasons),
            signalsJSON: encode(dto.signals),
            cachedAt: ISO8601DateFormatter.shared.string(from: cachedAt)
        )
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }

    private static func decode<T: Decodable>(_ type: T.Type, from string: String) -> T? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

/// `discovery_summary_modes` 表行映射。
struct DiscoverySummaryModeRecord: Codable, FetchableRecord, PersistableRecord, Equatable {

    static let databaseTableName = "discovery_summary_modes"

    var mode: String
    var total: Int
    var generatedAt: String?
    var cachedAt: String

    enum CodingKeys: String, CodingKey {
        case mode
        case total
        case generatedAt = "generated_at"
        case cachedAt = "cached_at"
    }
}

/// `discovery_summary_facets` 表行映射。
struct DiscoverySummaryFacetRecord: Codable, FetchableRecord, PersistableRecord, Equatable {

    static let databaseTableName = "discovery_summary_facets"

    var mode: String
    var facet: String
    var key: String
    var label: String
    var systemName: String?
    var count: Int
    var sortOrder: Int
    var cachedAt: String

    enum CodingKeys: String, CodingKey {
        case mode
        case facet
        case key
        case label
        case systemName = "system_name"
        case count
        case sortOrder = "sort_order"
        case cachedAt = "cached_at"
    }

    var toFacetDTO: DiscoveryFacetCountDTO {
        DiscoveryFacetCountDTO(key: key, label: label, count: count, systemName: systemName)
    }
}

/// `discovery_bulk_repos` 表行映射。
///
/// bulk 表保存 discovery catalog 的完整公开快照；它与按页缓存表分开，避免 sort/filter
/// 切换时继续被远端分页语义牵制。
struct DiscoveryBulkRepoRecord: Codable, FetchableRecord, PersistableRecord, Equatable {

    static let databaseTableName = "discovery_bulk_repos"

    var repoID: Int64
    var fullName: String
    var owner: String
    var name: String
    var description: String?
    var homepage: String?
    var language: String?
    var stars: Int
    var forks: Int
    var watchers: Int
    var subscribers: Int
    var openIssues: Int
    var ownerAvatar: String?
    var defaultBranch: String?
    var licenseSpdx: String?
    var topicsJSON: String
    var platformsJSON: String
    var pushedAt: String?
    var updatedAt: String?
    var createdAt: String?
    var isArchived: Bool
    var isFork: Bool
    var latestReleaseTag: String?
    var latestReleaseAt: String?
    var latestReleaseURL: String?
    var releaseDownloadCount: Int
    var itemRank: Int?
    var score: Double?
    var trendingScore: Double
    var popularityScore: Double
    var releaseScore: Double
    var discoveryScore: Double
    var searchScore: Double
    var reasonsJSON: String
    var signalsJSON: String
    var cachedAt: String

    enum CodingKeys: String, CodingKey {
        case repoID = "repo_id"
        case fullName = "full_name"
        case owner
        case name
        case description
        case homepage
        case language
        case stars
        case forks
        case watchers
        case subscribers
        case openIssues = "open_issues"
        case ownerAvatar = "owner_avatar"
        case defaultBranch = "default_branch"
        case licenseSpdx = "license_spdx"
        case topicsJSON = "topics_json"
        case platformsJSON = "platforms_json"
        case pushedAt = "pushed_at"
        case updatedAt = "updated_at"
        case createdAt = "created_at"
        case isArchived = "is_archived"
        case isFork = "is_fork"
        case latestReleaseTag = "latest_release_tag"
        case latestReleaseAt = "latest_release_at"
        case latestReleaseURL = "latest_release_url"
        case releaseDownloadCount = "release_download_count"
        case itemRank = "item_rank"
        case score
        case trendingScore = "trending_score"
        case popularityScore = "popularity_score"
        case releaseScore = "release_score"
        case discoveryScore = "discovery_score"
        case searchScore = "search_score"
        case reasonsJSON = "reasons_json"
        case signalsJSON = "signals_json"
        case cachedAt = "cached_at"
    }

    func toDomain(
        categories: [String] = [],
        categoryRanks: [String: Int] = [:]
    ) -> DiscoveryRepoDTO {
        DiscoveryRepoDTO(
            repoID: repoID,
            fullName: fullName,
            owner: owner,
            name: name,
            description: description,
            homepage: homepage,
            language: language,
            stars: stars,
            forks: forks,
            watchers: watchers,
            subscribers: subscribers,
            openIssues: openIssues,
            ownerAvatar: ownerAvatar,
            defaultBranch: defaultBranch,
            licenseSpdx: licenseSpdx,
            topics: Self.decode([String].self, from: topicsJSON) ?? [],
            platforms: Self.decode([String].self, from: platformsJSON) ?? [],
            pushedAt: pushedAt,
            updatedAt: updatedAt,
            createdAt: createdAt,
            isArchived: isArchived,
            isFork: isFork,
            latestReleaseTag: latestReleaseTag,
            latestReleaseAt: latestReleaseAt,
            latestReleaseURL: latestReleaseURL,
            releaseDownloadCount: releaseDownloadCount,
            rank: itemRank,
            score: score,
            trendingScore: trendingScore,
            popularityScore: popularityScore,
            releaseScore: releaseScore,
            discoveryScore: discoveryScore,
            searchScore: searchScore,
            reasons: Self.decode([String].self, from: reasonsJSON) ?? [],
            signals: Self.decode([DiscoverySignalDTO].self, from: signalsJSON) ?? [],
            categories: categories,
            categoryRanks: categoryRanks
        )
    }

    static func from(_ dto: DiscoveryRepoDTO, cachedAt: Date) -> DiscoveryBulkRepoRecord {
        DiscoveryBulkRepoRecord(
            repoID: dto.repoID,
            fullName: dto.fullName,
            owner: dto.owner,
            name: dto.name,
            description: dto.description,
            homepage: dto.homepage,
            language: dto.language,
            stars: dto.stars,
            forks: dto.forks,
            watchers: dto.watchers,
            subscribers: dto.subscribers,
            openIssues: dto.openIssues,
            ownerAvatar: dto.ownerAvatar,
            defaultBranch: dto.defaultBranch,
            licenseSpdx: dto.licenseSpdx,
            topicsJSON: encode(dto.topics),
            platformsJSON: encode(dto.platforms),
            pushedAt: dto.pushedAt,
            updatedAt: dto.updatedAt,
            createdAt: dto.createdAt,
            isArchived: dto.isArchived,
            isFork: dto.isFork,
            latestReleaseTag: dto.latestReleaseTag,
            latestReleaseAt: dto.latestReleaseAt,
            latestReleaseURL: dto.latestReleaseURL,
            releaseDownloadCount: dto.releaseDownloadCount,
            itemRank: dto.rank,
            score: dto.score,
            trendingScore: dto.trendingScore ?? 0,
            popularityScore: dto.popularityScore ?? 0,
            releaseScore: dto.releaseScore ?? 0,
            discoveryScore: dto.discoveryScore ?? dto.score ?? 0,
            searchScore: dto.searchScore ?? Double(dto.stars),
            reasonsJSON: encode(dto.reasons),
            signalsJSON: encode(dto.signals),
            cachedAt: ISO8601DateFormatter.shared.string(from: cachedAt)
        )
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }

    private static func decode<T: Decodable>(_ type: T.Type, from string: String) -> T? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

/// `discovery_bulk_category_memberships` 表行映射。
///
/// 这张表只保存 bulk 快照里每个 repo 进入哪些探索子模块，以及该子模块里的全量 rank。
/// 客户端筛选热门 / 新发布时只看这里，避免把同一 catalog 误当成多个榜单。
struct DiscoveryBulkCategoryMembershipRecord: Codable, FetchableRecord, PersistableRecord, Equatable {

    static let databaseTableName = "discovery_bulk_category_memberships"

    var repoID: Int64
    var category: String
    var itemRank: Int?
    var cachedAt: String

    enum CodingKeys: String, CodingKey {
        case repoID = "repo_id"
        case category
        case itemRank = "item_rank"
        case cachedAt = "cached_at"
    }
}

/// `discovery_bulk_meta` 单行表行映射（PK = "singleton"）。
struct DiscoveryBulkMetaRecord: Codable, FetchableRecord, PersistableRecord, Equatable {

    static let databaseTableName = "discovery_bulk_meta"
    static let singletonID = "singleton"

    var id: String
    var etag: String?
    var lastFetchedAt: String
    var generatedAt: String?
    var total: Int

    enum CodingKeys: String, CodingKey {
        case id
        case etag
        case lastFetchedAt = "last_fetched_at"
        case generatedAt = "generated_at"
        case total
    }
}
