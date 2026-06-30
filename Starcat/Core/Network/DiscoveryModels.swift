//
//  DiscoveryModels.swift
//  Starcat
//
//  starcat-discovery-api 的 endpoint-specific DTO。
//
//  约束：Discovery 字段不要塞进 StarcatRepoCardDTO。探索页需要的排名、平台、原因、
//  release 信号只属于 discovery endpoint，保持独立模型可以避免污染 Weekly / Trending 共享契约。
//

import Foundation

struct DiscoveryRepoDTO: Decodable, Identifiable, Hashable {
    let repoID: Int64
    let fullName: String
    let owner: String
    let name: String
    let description: String?
    let homepage: String?
    let language: String?
    let stars: Int
    let forks: Int
    let watchers: Int
    let subscribers: Int
    let openIssues: Int
    let ownerAvatar: String?
    let defaultBranch: String?
    let licenseSpdx: String?
    let topics: [String]
    let platforms: [String]
    let pushedAt: String?
    let updatedAt: String?
    let createdAt: String?
    let isArchived: Bool
    let isFork: Bool
    let latestReleaseTag: String?
    let latestReleaseAt: String?
    let latestReleaseURL: String?
    let releaseDownloadCount: Int
    let rank: Int?
    let score: Double?
    let reasons: [String]
    let signals: [DiscoverySignalDTO]

    var id: Int64 { repoID }

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
        case topics
        case platforms
        case pushedAt = "pushed_at"
        case updatedAt = "updated_at"
        case createdAt = "created_at"
        case isArchived = "is_archived"
        case isFork = "is_fork"
        case latestReleaseTag = "latest_release_tag"
        case latestReleaseAt = "latest_release_at"
        case latestReleaseURL = "latest_release_url"
        case releaseDownloadCount = "release_download_count"
        case rank
        case score
        case reasons
        case signals
    }
}

struct DiscoverySignalDTO: Decodable, Hashable {
    let code: String
    let label: String
    let value: String?
}

struct DiscoveryLanguageDTO: Decodable, Identifiable, Hashable {
    let key: String
    let label: String
    let count: Int

    var id: String { key }
}

struct DiscoveryTopicDTO: Decodable, Identifiable, Hashable {
    let code: String
    let label: String

    var id: String { code }
}

struct DiscoveryPlatformDTO: Decodable, Identifiable, Hashable {
    let code: String
    let label: String
    let systemName: String?

    var id: String { code }

    enum CodingKeys: String, CodingKey {
        case code
        case label
        case systemName = "system_name"
    }
}

struct DiscoveryPage: Equatable {
    let items: [DiscoveryRepoDTO]
    let total: Int
    let page: Int
    let pageSize: Int
    let nextPage: Int?
}

struct DiscoveryListQuery: Equatable, Hashable {
    var language: String?
    var platform: String?
    var topic: String?
    var sort: String?
    var page: Int = 1
    var limit: Int = 20
}
