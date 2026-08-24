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
    /// GitHub Repository API 返回的仓库真实描述，与内容管理精选说明分离。
    let repoDescription: String?
    let imageURL: String?
    let summaryZH: String?
    let summaryEN: String?
    let featured: Bool
    let sortOrder: Int
    /// 精选来源必须来自已核验的 GitHub Repo，因此 Stars 是公共目录的必返事实字段。
    let sourceStars: Int
    let githubRepoCount: Int
    let externalEntryCount: Int
    let lastSyncedAt: String?
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
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
    let homepage: String?
    let language: String?
    let stars: Int
    let forks: Int
    let watchers: Int
    let subscribers: Int
    let openIssues: Int
    let defaultBranch: String
    let licenseSpdx: String?
    let topics: [String]
    let isArchived: Bool
    let isFork: Bool
    let pushedAt: String?
    let updatedAt: String
    let createdAt: String
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
        case homepage
        case language
        case stars
        case forks
        case watchers
        case subscribers
        case openIssues = "open_issues"
        case defaultBranch = "default_branch"
        case licenseSpdx = "license_spdx"
        case topics
        case isArchived = "is_archived"
        case isFork = "is_fork"
        case pushedAt = "pushed_at"
        case updatedAt = "updated_at"
        case createdAt = "created_at"
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
    let repoDescription: String?
    let imageURL: URL?
    let summaryZH: String?
    let summaryEN: String?
    let featured: Bool
    let sortOrder: Int
    let sourceStars: Int
    let githubRepoCount: Int
    let externalEntryCount: Int
    let isAvailable: Bool
    let isEnabled: Bool
    let addedAt: Date
    let lastSyncedAt: Date?
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
    let homepage: String?
    let language: String?
    let stars: Int
    let forks: Int
    let watchers: Int
    let subscribers: Int
    let openIssues: Int
    let defaultBranch: String?
    let licenseSpdx: String?
    let topics: [String]
    let isArchived: Bool
    let isFork: Bool
    let pushedAt: Date?
    let updatedAt: Date?
    let createdAt: Date?
    let evidence: [AwesomeEntryEvidence]

    /// 默认值仅服务于迁移前的离线缓存和测试夹具；网络快照与自定义来源映射必须显式传入事实字段。
    init(
        id: Int64,
        owner: String,
        name: String,
        fullName: String,
        description: String?,
        ownerAvatarURL: URL?,
        homepage: String? = nil,
        language: String?,
        stars: Int,
        forks: Int = 0,
        watchers: Int = 0,
        subscribers: Int = 0,
        openIssues: Int = 0,
        defaultBranch: String? = nil,
        licenseSpdx: String? = nil,
        topics: [String] = [],
        isArchived: Bool,
        isFork: Bool = false,
        pushedAt: Date? = nil,
        updatedAt: Date?,
        createdAt: Date? = nil,
        evidence: [AwesomeEntryEvidence]
    ) {
        self.id = id
        self.owner = owner
        self.name = name
        self.fullName = fullName
        self.description = description
        self.ownerAvatarURL = ownerAvatarURL
        self.homepage = homepage
        self.language = language
        self.stars = stars
        self.forks = forks
        self.watchers = watchers
        self.subscribers = subscribers
        self.openIssues = openIssues
        self.defaultBranch = defaultBranch
        self.licenseSpdx = licenseSpdx
        self.topics = topics
        self.isArchived = isArchived
        self.isFork = isFork
        self.pushedAt = pushedAt
        self.updatedAt = updatedAt
        self.createdAt = createdAt
        self.evidence = evidence
    }

    /// 复用 Discovery 现有统一卡片与详情 scaffold；所有 GitHub 仓库事实都来自
    /// Discovery 中央缓存或用户自定义来源的本地 GitHub 响应，不用占位值伪造。
    var discoveryDTO: DiscoveryRepoDTO {
        DiscoveryRepoDTO(
            repoID: id,
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
            ownerAvatar: ownerAvatarURL?.absoluteString,
            defaultBranch: defaultBranch,
            licenseSpdx: licenseSpdx,
            topics: topics,
            platforms: [],
            pushedAt: pushedAt.map { ISO8601DateFormatter.shared.string(from: $0) },
            updatedAt: updatedAt.map { ISO8601DateFormatter.shared.string(from: $0) },
            createdAt: createdAt.map { ISO8601DateFormatter.shared.string(from: $0) },
            isArchived: isArchived,
            isFork: isFork,
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
