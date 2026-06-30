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

struct DiscoveryRepoDTO: Codable, Identifiable, Hashable, Sendable {
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
    var trendingScore: Double? = nil
    var popularityScore: Double? = nil
    var releaseScore: Double? = nil
    var discoveryScore: Double? = nil
    var searchScore: Double? = nil
    let reasons: [String]
    let signals: [DiscoverySignalDTO]
    let categories: [String]
    let categoryRanks: [String: Int]

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
        case trendingScore = "trending_score"
        case popularityScore = "popularity_score"
        case releaseScore = "release_score"
        case discoveryScore = "discovery_score"
        case searchScore = "search_score"
        case reasons
        case signals
        case categories
        case categoryRanks = "category_ranks"
    }

    init(
        repoID: Int64,
        fullName: String,
        owner: String,
        name: String,
        description: String?,
        homepage: String?,
        language: String?,
        stars: Int,
        forks: Int,
        watchers: Int,
        subscribers: Int,
        openIssues: Int,
        ownerAvatar: String?,
        defaultBranch: String?,
        licenseSpdx: String?,
        topics: [String],
        platforms: [String],
        pushedAt: String?,
        updatedAt: String?,
        createdAt: String?,
        isArchived: Bool,
        isFork: Bool,
        latestReleaseTag: String?,
        latestReleaseAt: String?,
        latestReleaseURL: String?,
        releaseDownloadCount: Int,
        rank: Int?,
        score: Double?,
        trendingScore: Double? = nil,
        popularityScore: Double? = nil,
        releaseScore: Double? = nil,
        discoveryScore: Double? = nil,
        searchScore: Double? = nil,
        reasons: [String],
        signals: [DiscoverySignalDTO],
        categories: [String] = [],
        categoryRanks: [String: Int] = [:]
    ) {
        self.repoID = repoID
        self.fullName = fullName
        self.owner = owner
        self.name = name
        self.description = description
        self.homepage = homepage
        self.language = language
        self.stars = stars
        self.forks = forks
        self.watchers = watchers
        self.subscribers = subscribers
        self.openIssues = openIssues
        self.ownerAvatar = ownerAvatar
        self.defaultBranch = defaultBranch
        self.licenseSpdx = licenseSpdx
        self.topics = topics
        self.platforms = platforms
        self.pushedAt = pushedAt
        self.updatedAt = updatedAt
        self.createdAt = createdAt
        self.isArchived = isArchived
        self.isFork = isFork
        self.latestReleaseTag = latestReleaseTag
        self.latestReleaseAt = latestReleaseAt
        self.latestReleaseURL = latestReleaseURL
        self.releaseDownloadCount = releaseDownloadCount
        self.rank = rank
        self.score = score
        self.trendingScore = trendingScore
        self.popularityScore = popularityScore
        self.releaseScore = releaseScore
        self.discoveryScore = discoveryScore
        self.searchScore = searchScore
        self.reasons = reasons
        self.signals = signals
        self.categories = categories
        self.categoryRanks = categoryRanks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        repoID = try container.decode(Int64.self, forKey: .repoID)
        fullName = try container.decode(String.self, forKey: .fullName)
        owner = try container.decode(String.self, forKey: .owner)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        homepage = try container.decodeIfPresent(String.self, forKey: .homepage)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        stars = try container.decode(Int.self, forKey: .stars)
        forks = try container.decode(Int.self, forKey: .forks)
        watchers = try container.decode(Int.self, forKey: .watchers)
        subscribers = try container.decode(Int.self, forKey: .subscribers)
        openIssues = try container.decode(Int.self, forKey: .openIssues)
        ownerAvatar = try container.decodeIfPresent(String.self, forKey: .ownerAvatar)
        defaultBranch = try container.decodeIfPresent(String.self, forKey: .defaultBranch)
        licenseSpdx = try container.decodeIfPresent(String.self, forKey: .licenseSpdx)
        topics = try container.decodeIfPresent([String].self, forKey: .topics) ?? []
        platforms = try container.decodeIfPresent([String].self, forKey: .platforms) ?? []
        pushedAt = try container.decodeIfPresent(String.self, forKey: .pushedAt)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        isArchived = try container.decode(Bool.self, forKey: .isArchived)
        isFork = try container.decode(Bool.self, forKey: .isFork)
        latestReleaseTag = try container.decodeIfPresent(String.self, forKey: .latestReleaseTag)
        latestReleaseAt = try container.decodeIfPresent(String.self, forKey: .latestReleaseAt)
        latestReleaseURL = try container.decodeIfPresent(String.self, forKey: .latestReleaseURL)
        releaseDownloadCount = try container.decode(Int.self, forKey: .releaseDownloadCount)
        rank = try container.decodeIfPresent(Int.self, forKey: .rank)
        score = try container.decodeIfPresent(Double.self, forKey: .score)
        trendingScore = try container.decodeIfPresent(Double.self, forKey: .trendingScore)
        popularityScore = try container.decodeIfPresent(Double.self, forKey: .popularityScore)
        releaseScore = try container.decodeIfPresent(Double.self, forKey: .releaseScore)
        discoveryScore = try container.decodeIfPresent(Double.self, forKey: .discoveryScore)
        searchScore = try container.decodeIfPresent(Double.self, forKey: .searchScore)
        reasons = try container.decodeIfPresent([String].self, forKey: .reasons) ?? []
        signals = try container.decodeIfPresent([DiscoverySignalDTO].self, forKey: .signals) ?? []
        categories = try container.decodeIfPresent([String].self, forKey: .categories) ?? []
        categoryRanks = try container.decodeIfPresent([String: Int].self, forKey: .categoryRanks) ?? [:]
    }
}

struct DiscoverySignalDTO: Codable, Hashable, Sendable {
    let code: String
    let label: String
    let value: String?
}

struct DiscoveryLanguageDTO: Codable, Identifiable, Hashable, Sendable {
    let key: String
    let label: String
    let count: Int

    var id: String { key }
}

struct DiscoveryTopicDTO: Codable, Identifiable, Hashable, Sendable {
    let code: String
    let label: String

    var id: String { code }
}

struct DiscoveryPlatformDTO: Codable, Identifiable, Hashable, Sendable {
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

struct DiscoveryPage: Equatable, Sendable {
    let items: [DiscoveryRepoDTO]
    let total: Int
    let page: Int
    let pageSize: Int
    let nextPage: Int?
}

struct DiscoveryCachedPage: Sendable {
    let page: DiscoveryPage
    let cachedAt: Date
}

struct DiscoveryBulkCachedSnapshot: Sendable {
    let repos: [DiscoveryRepoDTO]
    let summary: DiscoverySummaryDTO
    let etag: String?
    let lastFetchedAt: Date
    let generatedAt: String?
    let total: Int
}

struct DiscoveryBulkResult: Sendable {
    let repos: [DiscoveryRepoDTO]
    let summary: DiscoverySummaryDTO
    let etag: String?
    let generatedAt: String?
    let total: Int
}

struct DiscoveryBulkDataDTO: Codable, Equatable, Sendable {
    let repos: [DiscoveryRepoDTO]
    let summary: DiscoverySummaryDTO
}

struct DiscoveryListQuery: Equatable, Hashable, Sendable {
    var language: String?
    var platform: String?
    var topic: String?
    var sort: String?
    var page: Int = 1
    var limit: Int = 20
}

enum DiscoveryListMode: String, Codable, CaseIterable, Sendable {
    case discover
    case popular
    case newReleases

    var apiSummaryMode: String {
        switch self {
        case .discover: return "discover"
        case .popular: return "popular"
        case .newReleases: return "new_releases"
        }
    }

    init?(apiSummaryMode: String) {
        switch apiSummaryMode {
        case "discover":
            self = .discover
        case "popular":
            self = .popular
        case "new_releases":
            self = .newReleases
        default:
            return nil
        }
    }
}

struct DiscoverySummaryDTO: Codable, Equatable, Sendable {
    let modes: [DiscoveryModeSummaryDTO]
    let generatedAt: String?

    enum CodingKeys: String, CodingKey {
        case modes
        case generatedAt = "generated_at"
    }

    func mode(_ mode: DiscoveryListMode) -> DiscoveryModeSummaryDTO? {
        modes.first { DiscoveryListMode(apiSummaryMode: $0.mode) == mode }
    }
}

struct DiscoveryModeSummaryDTO: Codable, Equatable, Sendable {
    let mode: String
    let total: Int
    let topics: [DiscoveryFacetCountDTO]?
    let platforms: [DiscoveryFacetCountDTO]?
    let languages: [DiscoveryFacetCountDTO]?
}

struct DiscoveryFacetCountDTO: Codable, Identifiable, Equatable, Hashable, Sendable {
    let key: String
    let label: String
    let count: Int
    let systemName: String?

    var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key
        case label
        case count
        case systemName = "system_name"
    }

    var asTopicDTO: DiscoveryTopicDTO {
        DiscoveryTopicDTO(code: key, label: label)
    }

    var asPlatformDTO: DiscoveryPlatformDTO {
        DiscoveryPlatformDTO(code: key, label: label, systemName: systemName)
    }

    var asLanguageDTO: DiscoveryLanguageDTO {
        DiscoveryLanguageDTO(key: key, label: label, count: count)
    }
}

extension DiscoveryRepoDTO {

    /// Discovery API 的列表 DTO 转成统一仓库卡片数据。
    ///
    /// Discovery endpoint 有自己的排名、平台和推荐原因语义，但列表卡片仍应复用
    /// `UnifiedRepoRow`，因此只在这里做薄适配，不把 discovery 字段塞进共享 DTO。
    @MainActor
    func asCardData(
        registry: StarredRegistry,
        openSSFScore: OpenSSFScoreBadgeData? = nil,
        healthBadge: RepoHealthBadgeData? = nil
    ) -> RepoCardViewData {
        RepoCardViewData(
            ghRepoId: repoID,
            fullName: fullName,
            owner: owner,
            repo: name,
            avatarURL: ownerAvatar.flatMap(URL.init(string:)),
            description: description,
            language: language,
            starsCount: stars,
            forksCount: forks,
            isArchived: isArchived,
            isFork: isFork,
            isPrivate: false,
            isStarred: registry.contains(ghRepoId: repoID),
            badge: nil,
            weeklySources: [],
            weeklySourceLabel: nil,
            inlineMetadata: latestReleaseAt.map {
                RepoCardInlineMetadata(systemImage: "shippingbox", text: $0)
            },
            readStatus: nil,
            openSSFScore: openSSFScore,
            healthBadge: healthBadge
        )
    }

    /// 构造只用于详情页展示和 star 操作的临时 Repo。
    ///
    /// 关键约束：Discovery API 返回的是公共仓库快照，不能直接落入本地 `repos` 表。
    /// Star 成功后仍由 `StarActionService` 通过 GitHub `/repos` 拉真值并写库。
    func toEphemeralRepo(isStarred: Bool) -> Repo {
        Repo(
            id: repoID,
            owner: owner,
            name: name,
            fullName: fullName,
            description: description,
            language: language,
            starsCount: stars,
            forksCount: forks,
            watchersCount: watchers,
            topics: topicsJSON,
            license: licenseSpdx,
            homepage: homepage,
            htmlUrl: GitHubURLs.repo(owner: owner, repo: name).absoluteString,
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: false,
            isFork: isFork,
            isArchived: isArchived,
            isStarred: isStarred,
            pushedAt: pushedAt,
            createdAt: createdAt,
            updatedAt: updatedAt,
            starredAt: nil,
            cachedAt: nil,
            ownerAvatar: ownerAvatar,
            subscribersCount: subscribers,
            defaultBranch: defaultBranch,
            openIssuesCount: openIssues
        )
    }

    var githubURL: URL {
        GitHubURLs.repo(owner: owner, repo: name)
    }

    var latestReleaseWebURL: URL? {
        latestReleaseURL.flatMap(URL.init(string:))
    }

    var latestReleaseDate: Date? {
        latestReleaseAt.flatMap(ISO8601DateFormatter.shared.date(from:))
    }

    private var topicsJSON: String? {
        guard !topics.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(topics),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }
}
