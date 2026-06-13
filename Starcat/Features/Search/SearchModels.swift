//
//  SearchModels.swift
//  Starcat
//
//  全局搜索中心的领域模型。
//
//  设计约束：
//  - Repo 与网页资料是两种不同候选，禁止把 Web Result 伪装成 Repo；
//  - GitHub 数字 ID 是首选身份，缺失时才退化到规范化 owner/name；
//  - 每个 Provider 独立维护状态，某个远端失败不能覆盖本地结果；
//  - 本文件不依赖 SwiftUI，保证 Coordinator 和单元测试可以直接复用。
//

import Foundation

enum SearchScope: String, CaseIterable, Identifiable, Codable, Sendable {
    case all
    case local
    case github
    case web

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .all: return "search.center.scope.all"
        case .local: return "search.center.scope.local"
        case .github: return "search.center.scope.github"
        case .web: return "search.center.scope.web"
        }
    }
}

enum SearchSource: String, CaseIterable, Codable, Hashable, Sendable {
    case localKeyword
    case localSemantic
    case github
    case web
}

/// 跨来源 Repo 身份。
///
/// `ghRepoID` 能跨 rename 保持稳定，所以只要存在就优先使用；网络来源缺 ID 时，
/// 才用 lowercased `owner/name`。不使用 title、网页 URL 等弱特征猜测身份。
struct RepoIdentity: Hashable, Sendable {
    let ghRepoID: Int64?
    let owner: String
    let name: String

    init(ghRepoID: Int64?, owner: String, name: String) {
        self.ghRepoID = ghRepoID
        self.owner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedFullName: String {
        "\(owner)/\(name)".lowercased()
    }

    static func == (lhs: RepoIdentity, rhs: RepoIdentity) -> Bool {
        if lhs.ghRepoID != nil || rhs.ghRepoID != nil {
            return lhs.ghRepoID == rhs.ghRepoID
        }
        return lhs.normalizedFullName == rhs.normalizedFullName
    }

    func hash(into hasher: inout Hasher) {
        if let ghRepoID {
            hasher.combine(0)
            hasher.combine(ghRepoID)
        } else {
            hasher.combine(1)
            hasher.combine(normalizedFullName)
        }
    }
}

/// 远端 repo 的「不入库瞬时态」字段。
///
/// 设计意图（SEARCH-RICH 2026-06-14）：
/// - GitHub `/search/repositories` 返回的 `disabled` / `is_template` / `score`
///   这三类字段在本地 `Repo` 表里没有列（`disabled` / `is_template` 频率低不值
///   建列；`score` 是查询相关度，与 repo 本身无关）。
/// - 把它们从 `Repo` 模型剥离 → 由 `RepositoryCandidate.remoteExtras` 旁挂，
///   仅在会话内的搜索弹窗使用，不污染数据库 schema 也不被 stars 同步消化。
/// - 全部 Optional：用 nil 表示「来源端点没返回 / 本地命中无远端字段」。
struct RemoteRepoExtras: Hashable, Sendable {
    /// GitHub `disabled`：仓库被官方停用（DMCA / 违规 / 长期无人维护）。
    let disabled: Bool?
    /// GitHub `is_template`：模板仓库（用户可一键派生）。
    let isTemplate: Bool?
    /// GitHub `score`：搜索相关度（best-match 排序时有意义；0.0 ~ 1.0+）。
    let score: Double?

    static let empty = RemoteRepoExtras(disabled: nil, isTemplate: nil, score: nil)

    /// 没有任何信号要展示时（全 nil 或 false）UI 可以直接整段隐藏。
    var hasAnyVisibleBadge: Bool {
        disabled == true || isTemplate == true
    }
}

struct RepositoryCandidate: Identifiable, Hashable, Sendable {
    var id: RepoIdentity { identity }

    let identity: RepoIdentity
    var card: RepoCardViewData
    var sources: Set<SearchSource>
    var localRepo: Repo?
    /// 远端完整元数据，仅用于会话内详情/AI，不代表已经写入本地数据库。
    var remoteRepo: Repo?
    var semanticScore: Double?
    /// 远端瞬时态字段（disabled / is_template / score）。默认 `.empty` 让现有
    /// 调用点零改动；GitHub Search Provider 显式填值后弹窗能渲染对应徽章。
    var remoteExtras: RemoteRepoExtras = .empty

    var isStarred: Bool { localRepo?.isStarred ?? card.isStarred }
    var displayRepo: Repo? { localRepo ?? remoteRepo }
}

struct ReferenceCandidate: Identifiable, Hashable, Sendable {
    var id: String { normalizedURL.absoluteString }

    let normalizedURL: URL
    let originalURL: URL
    let title: String
    let snippet: String?
    let domain: String
    let source: SearchSource
}

enum SearchCandidate: Identifiable, Hashable, Sendable {
    case repository(RepositoryCandidate)
    case reference(ReferenceCandidate)

    var id: String {
        switch self {
        case .repository(let candidate):
            return "repo:\(candidate.identity.normalizedFullName)"
        case .reference(let candidate):
            return "reference:\(candidate.id)"
        }
    }
}

enum GitHubSearchSort: String, CaseIterable, Identifiable, Codable, Sendable {
    case bestMatch
    case stars
    case forks
    case updated

    var id: String { rawValue }
}

enum SearchOrder: String, CaseIterable, Identifiable, Codable, Sendable {
    case descending = "desc"
    case ascending = "asc"

    var id: String { rawValue }
}

struct GitHubSearchFilters: Equatable, Hashable, Codable, Sendable {
    var language: String?
    var topic: String?
    var minimumStars: Int?
    var createdAfter: Date?
    var pushedAfter: Date?
    var sort: GitHubSearchSort = .bestMatch
    var order: SearchOrder = .descending

    static let empty = GitHubSearchFilters()
}

struct SearchRequest: Equatable, Hashable, Sendable {
    let query: String
    let scope: SearchScope
    let githubFilters: GitHubSearchFilters
    let page: Int
    let perPage: Int
    let includeWebInAll: Bool

    init(
        query: String,
        scope: SearchScope = .all,
        githubFilters: GitHubSearchFilters = .empty,
        page: Int = 1,
        perPage: Int = 30,
        includeWebInAll: Bool = false
    ) {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.scope = scope
        self.githubFilters = githubFilters
        self.page = max(1, page)
        self.perPage = min(max(1, perPage), 100)
        self.includeWebInAll = includeWebInAll
    }
}

struct SearchProviderPage: Equatable, Sendable {
    let repositories: [RepositoryCandidate]
    let references: [ReferenceCandidate]
    let totalCount: Int?
    let hasNextPage: Bool

    static let empty = SearchProviderPage(
        repositories: [],
        references: [],
        totalCount: 0,
        hasNextPage: false
    )
}

enum SearchProviderStatus: Equatable, Sendable {
    case idle
    case loading
    case loaded(SearchProviderPage)
    case failed(String)
}

protocol SearchProvider: Sendable {
    var source: SearchSource { get }
    func search(_ request: SearchRequest) async throws -> SearchProviderPage
}
