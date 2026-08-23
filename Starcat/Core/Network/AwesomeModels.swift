//
//  AwesomeModels.swift
//  Starcat
//
//  Awesome 公共接口与客户端聚合领域模型。
//
//  精选来源目录来自 Discovery API；订阅、自定义来源与来源条目只保存在当前账户数据库。
//  Repo 使用 GitHub 稳定 ID 去重，同时保留每个来源的 README 证据，避免把“被 Awesome
//  收录”错误等同于已 Star 或已进入用户知识库。
//

import Foundation

enum AwesomeSourceKind: String, Codable, Sendable {
    case managed
    case custom
}

struct AwesomeSourceDTO: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let repoFullName: String
    let repoURL: String
    let imageURL: String?
    let summaryZH: String?
    let summaryEN: String?
    let featured: Bool
    let sortOrder: Int
    let githubRepoCount: Int
    let externalEntryCount: Int
    let lastSyncedAt: String?
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case repoFullName = "repo_full_name"
        case repoURL = "repo_url"
        case imageURL = "image_url"
        case summaryZH = "summary_zh"
        case summaryEN = "summary_en"
        case featured
        case sortOrder = "sort_order"
        case githubRepoCount = "github_repo_count"
        case externalEntryCount = "external_entry_count"
        case lastSyncedAt = "last_synced_at"
        case updatedAt = "updated_at"
    }
}

struct AwesomeEntryDTO: Codable, Hashable, Sendable {
    let ghRepoID: Int64
    let owner: String
    let name: String
    let fullName: String
    let description: String?
    let ownerAvatar: String?
    let language: String?
    let stars: Int
    let isArchived: Bool
    let updatedAt: String?
    let entryTitle: String
    let entryDescription: String?
    let sectionPath: [String]
    let entryOrder: Int
    let sourceAnchorURL: String?

    enum CodingKeys: String, CodingKey {
        case ghRepoID = "gh_repo_id"
        case owner
        case name
        case fullName = "full_name"
        case description
        case ownerAvatar = "owner_avatar"
        case language
        case stars
        case isArchived = "is_archived"
        case updatedAt = "updated_at"
        case entryTitle = "entry_title"
        case entryDescription = "entry_description"
        case sectionPath = "section_path"
        case entryOrder = "entry_order"
        case sourceAnchorURL = "source_anchor_url"
    }
}

struct AwesomeEntriesSnapshotDTO: Codable, Sendable {
    let source: AwesomeEntriesSourceDTO
    let entries: [AwesomeEntryDTO]
}

struct AwesomeEntriesSourceDTO: Codable, Sendable {
    let id: String
    let displayName: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case updatedAt = "updated_at"
    }
}

struct AwesomeCatalogResult: Sendable {
    let sources: [AwesomeSourceDTO]
    let etag: String?
    let generatedAt: String?
    let notModified: Bool
}

struct AwesomeEntriesResult: Sendable {
    let snapshot: AwesomeEntriesSnapshotDTO?
    let etag: String?
    let generatedAt: String?
    let notModified: Bool
}

/// 左栏与来源管理 Sheet 共用的本地来源模型。
struct AwesomeSource: Identifiable, Hashable, Sendable {
    let id: String
    let kind: AwesomeSourceKind
    let displayName: String
    let repoFullName: String
    let repoURL: URL
    let imageURL: URL?
    let summaryZH: String?
    let summaryEN: String?
    let featured: Bool
    let sortOrder: Int
    let githubRepoCount: Int
    let externalEntryCount: Int
    let isAvailable: Bool
    let isEnabled: Bool
    let addedAt: Date
    let updatedAt: Date

    func localizedSummary(languageCode: String?) -> String? {
        let prefersChinese = languageCode?.lowercased().hasPrefix("zh") == true
        let candidates = prefersChinese ? [summaryZH, summaryEN] : [summaryEN, summaryZH]
        return candidates.compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }.first
    }
}

/// 单个 Repo 在一个来源中的原始条目事实。
struct AwesomeEntryEvidence: Hashable, Sendable {
    let source: AwesomeSource
    let entryTitle: String
    let entryDescription: String?
    let sectionPath: [String]
    let entryOrder: Int
    let sourceAnchorURL: URL?
}

/// 中栏使用的去重 Repo。GitHub metadata 是公开快照，不写入用户 starred repos 表。
struct AwesomeRepositoryItem: Identifiable, Hashable, Sendable {
    let id: Int64
    let owner: String
    let name: String
    let fullName: String
    let description: String?
    let ownerAvatarURL: URL?
    let language: String?
    let stars: Int
    let isArchived: Bool
    let updatedAt: Date?
    let evidence: [AwesomeEntryEvidence]

    /// 复用 Discovery 现有统一卡片与详情 scaffold 所需的最小公共 Repo 投影。
    /// Awesome API 不提供 forks/watchers/release 等字段，明确以 0/nil 降级而不是伪造数据。
    var discoveryDTO: DiscoveryRepoDTO {
        DiscoveryRepoDTO(
            repoID: id,
            fullName: fullName,
            owner: owner,
            name: name,
            description: description,
            homepage: nil,
            language: language,
            stars: stars,
            forks: 0,
            watchers: 0,
            subscribers: 0,
            openIssues: 0,
            ownerAvatar: ownerAvatarURL?.absoluteString,
            defaultBranch: nil,
            licenseSpdx: nil,
            topics: [],
            platforms: [],
            pushedAt: nil,
            updatedAt: updatedAt.map { ISO8601DateFormatter.shared.string(from: $0) },
            createdAt: nil,
            isArchived: isArchived,
            isFork: false,
            latestReleaseTag: nil,
            latestReleaseAt: nil,
            latestReleaseURL: nil,
            releaseDownloadCount: 0,
            rank: evidence.first?.entryOrder,
            score: nil,
            reasons: [],
            signals: []
        )
    }
}
