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
    case trending

    var apiSummaryMode: String {
        switch self {
        case .discover: return "discover"
        case .popular: return "popular"
        case .newReleases: return "new_releases"
        case .trending: return "trending"
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
        case "trending":
            self = .trending
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
