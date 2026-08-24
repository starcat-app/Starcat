//
//  AwesomeRecords.swift
//  Starcat
//
//  Awesome 来源目录、账户订阅和 README 条目的 GRDB 行映射。
//
//  当前登录账户拥有独立数据库，因此这里不重复保存 account_id。精选目录属于可重建缓存，
//  订阅、自定义来源和首次设置状态属于用户本地配置；它们都不会进入 CloudKit 或 Discovery API。
//

import Foundation
import GRDB

struct AwesomeSourceRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "awesome_sources"

    var sourceID: String
    var kind: String
    var displayName: String
    var repoFullName: String
    var repoURL: String
    var repoDescription: String?
    var imageURL: String?
    var summaryZH: String?
    var summaryEN: String?
    var featured: Bool
    var sortOrder: Int
    var sourceStars: Int
    var githubRepoCount: Int
    var externalEntryCount: Int
    var isAvailable: Bool
    var catalogETag: String?
    var entriesETag: String?
    var entriesCheckedAt: String?
    var addedAt: String
    var lastSyncedAt: String?
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case kind
        case displayName = "display_name"
        case repoFullName = "repo_full_name"
        case repoURL = "repo_url"
        case repoDescription = "repo_description"
        case imageURL = "image_url"
        case summaryZH = "summary_zh"
        case summaryEN = "summary_en"
        case featured
        case sortOrder = "sort_order"
        case sourceStars = "source_stars"
        case githubRepoCount = "github_repo_count"
        case externalEntryCount = "external_entry_count"
        case isAvailable = "is_available"
        case catalogETag = "catalog_etag"
        case entriesETag = "entries_etag"
        case entriesCheckedAt = "entries_checked_at"
        case addedAt = "added_at"
        case lastSyncedAt = "last_synced_at"
        case updatedAt = "updated_at"
    }
}

struct AwesomeSubscriptionRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "awesome_source_subscriptions"

    var sourceID: String
    var isEnabled: Bool
    var enabledAt: String?

    enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case isEnabled = "is_enabled"
        case enabledAt = "enabled_at"
    }
}

struct AwesomeEntryRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "awesome_entries"

    var sourceID: String
    var ghRepoID: Int64
    var owner: String
    var name: String
    var fullName: String
    var description: String?
    var ownerAvatar: String?
    var homepage: String?
    var language: String?
    var stars: Int
    var forks: Int
    var watchers: Int
    var subscribers: Int
    var openIssues: Int
    var defaultBranch: String?
    var licenseSpdx: String?
    var topicsJSON: String
    var isArchived: Bool
    var isFork: Bool
    var pushedAt: String?
    var repoUpdatedAt: String?
    var createdAt: String?
    var entryTitle: String
    var entryDescription: String?
    var sectionPathJSON: String
    var entryOrder: Int
    var sourceAnchorURL: String?
    var cachedAt: String

    enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case ghRepoID = "gh_repo_id"
        case owner
        case name
        case fullName = "full_name"
        case description
        case ownerAvatar = "owner_avatar"
        case homepage
        case language
        case stars
        case forks
        case watchers
        case subscribers
        case openIssues = "open_issues"
        case defaultBranch = "default_branch"
        case licenseSpdx = "license_spdx"
        case topicsJSON = "topics_json"
        case isArchived = "is_archived"
        case isFork = "is_fork"
        case pushedAt = "pushed_at"
        case repoUpdatedAt = "repo_updated_at"
        case createdAt = "created_at"
        case entryTitle = "entry_title"
        case entryDescription = "entry_description"
        case sectionPathJSON = "section_path_json"
        case entryOrder = "entry_order"
        case sourceAnchorURL = "source_anchor_url"
        case cachedAt = "cached_at"
    }
}

struct AwesomeStateRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "awesome_state"
    static let singletonID = 1

    var id: Int
    var hasCompletedSourceSetup: Bool
    var catalogETag: String?
    var catalogCheckedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case hasCompletedSourceSetup = "has_completed_source_setup"
        case catalogETag = "catalog_etag"
        case catalogCheckedAt = "catalog_checked_at"
    }
}
