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
    let providerID: ExternalSearchProviderID?

    init(
        normalizedURL: URL,
        originalURL: URL,
        title: String,
        snippet: String?,
        domain: String,
        source: SearchSource,
        providerID: ExternalSearchProviderID? = nil
    ) {
        self.normalizedURL = normalizedURL
        self.originalURL = originalURL
        self.title = title
        self.snippet = snippet
        self.domain = domain
        self.source = source
        self.providerID = providerID
    }
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

/// AnySearch 网关支持的地理路由分区。
///
/// - `cn`：国内优先（中文资料、本地化结果倾向）
/// - `intl`：海外优先
/// - nil（未传）：网关按 query 和 IP 自动路由（推荐默认）
enum AnySearchZone: String, CaseIterable, Identifiable, Codable, Sendable {
    case cn
    case intl

    var id: String { rawValue }
}

/// AnySearch 搜索筛选条件（用户在搜索弹窗 UI 调整的可选参数）。
///
/// 设计与 `GitHubSearchFilters` 对称：默认值 = `.empty`，全部 Optional / 空集合
/// → provider 翻译时不传给 API → 网关走自动路由。这样用户「什么都不选」=「跟
/// 当前默认行为完全一致」，无功能回退。
///
/// **字段开放范围（dong4j 2026-06-14 拍板）**：
/// - 开放：`domain` / `contentTypes` / `zone` / `maxResults` —— 用户最常调的 4 个
/// - 不开放：`tag`（依赖 domain 联动，格式复杂）/ `params`（文档未给可选键全集）/
///   `language`（隐式跟随 `Locale.current`，UI 上无开关）
///
/// **持久化（dong4j 2026-06-14 拍板）**：对齐 `GitHubSearchFilters`，会话级即可
/// —— 挂在 `SearchCenterViewModel` 的 `@Observable` 属性上，App 重启清零，不写
/// `AppSettings`。
struct AnySearchFilters: Equatable, Hashable, Codable, Sendable {
    /// AnySearch 22 个 domain 之一（general / code / tech / ...）。
    /// nil = 自动（不传给 API，网关按 query 路由到最优数据源）。
    var domain: String?

    /// 内容类型过滤（如 `["web", "news", "doc"]`）。
    /// 空集合 = 自动（不传 API）；非空时只显示命中的类型。
    /// 官方文档未给完整枚举，UI 当前开放 `web` / `news` / `doc` 三个常见值。
    var contentTypes: Set<String> = []

    /// 地理分区路由。nil = 跟随网关自动路由。
    var zone: AnySearchZone?

    /// 单次返回结果数。范围 1–100（对齐官方 API），default 10 与原硬编码行为对齐。
    /// UI Stepper 在 `SearchCenterView.anySearchMaxResultsField` 钳到同样区间。
    var maxResults: Int = 10

    static let empty = AnySearchFilters()

    /// 用于 cache key 的稳定指纹。
    ///
    /// `SearchSessionCache` 现在按 `query + credentialVersion` 做 key，filters
    /// 变化必须让 key 自然 miss，否则用户切 domain 后还返回旧结果。
    /// 用 sorted+join 而不是直接 `hashValue`：后者跨进程不稳定，且容易因
    /// `Set` 迭代顺序不稳定造成 cache miss 率虚高。
    var fingerprint: String {
        let parts: [String] = [
            "d=\(domain ?? "")",
            "ct=\(contentTypes.sorted().joined(separator: ","))",
            "z=\(zone?.rawValue ?? "")",
            "n=\(maxResults)"
        ]
        return parts.joined(separator: "|")
    }
}

/// External Search 的 Provider 无关筛选条件。
///
/// 这里只放四个可以跨 Provider 表达的公共字段；AnySearch 的 domain/contentTypes/zone
/// 仍保留在 `AnySearchFilters` 中，避免把 AnySearch 专属枚举强行塞给 Tavily/Exa/Brave。
/// 筛选值由 SearchCenter ViewModel 持有，属于会话状态，不写入 AppSettings。
struct ExternalSearchFilters: Equatable, Hashable, Codable, Sendable {
    enum Freshness: String, CaseIterable, Identifiable, Codable, Sendable {
        case any
        case day
        case week
        case month
        case year

        var id: String { rawValue }
    }

    /// 单次返回结果数。范围 1–100，默认 10。
    var maxResults: Int = 10
    /// 第一版只作为通用模型和 cache fingerprint；具体 provider 参数接入以后续官方文档为准。
    var freshness: Freshness = .any
    /// 域名白名单。空集合 = 不限制。
    var includeDomains: Set<String> = []
    /// 域名黑名单。空集合 = 不限制。
    var excludeDomains: Set<String> = []

    static let empty = ExternalSearchFilters()

    var fingerprint: String {
        [
            "n=\(maxResults)",
            "freshness=\(freshness.rawValue)",
            "include=\(includeDomains.sorted().joined(separator: ","))",
            "exclude=\(excludeDomains.sorted().joined(separator: ","))"
        ].joined(separator: "|")
    }

    func clampedMaxResults() -> Int {
        min(max(maxResults, 1), 100)
    }
}

struct SearchRequest: Equatable, Hashable, Sendable {
    let query: String
    let scope: SearchScope
    let githubFilters: GitHubSearchFilters
    /// AnySearch 筛选条件。默认 `.empty` 让所有既有调用点零改动 —— 与未传时
    /// 的「全部走默认」行为完全一致。
    let anySearchFilters: AnySearchFilters
    /// Provider 无关的 External Search 公共筛选条件。
    let externalSearchFilters: ExternalSearchFilters
    /// 本次 Web provider view 使用的外部搜索 Provider。
    ///
    /// `.web` scope 使用 SearchCenter 会话态 provider；`.all` scope 使用设置页默认
    /// provider。默认 AnySearch 让现有测试和调用点保持稳定。
    let externalSearchProvider: ExternalSearchProviderID
    let page: Int
    let perPage: Int
    let includeWebInAll: Bool

    init(
        query: String,
        scope: SearchScope = .all,
        githubFilters: GitHubSearchFilters = .empty,
        anySearchFilters: AnySearchFilters = .empty,
        externalSearchFilters: ExternalSearchFilters = .empty,
        externalSearchProvider: ExternalSearchProviderID = .anySearch,
        page: Int = 1,
        perPage: Int = 30,
        includeWebInAll: Bool = false
    ) {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.scope = scope
        self.githubFilters = githubFilters
        self.anySearchFilters = anySearchFilters
        self.externalSearchFilters = externalSearchFilters
        self.externalSearchProvider = externalSearchProvider
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
    /// 网页搜索专属元信息（命中数 / 用时 / 限流）。
    ///
    /// 仅 `ExternalSearchWebProvider` 会填值，其它 provider（local / github）传 nil。
    /// 显式 default `nil` 让 GitHub / Local provider 调用点零改动。
    let webMetadata: WebSearchMetadata?

    init(
        repositories: [RepositoryCandidate],
        references: [ReferenceCandidate],
        totalCount: Int?,
        hasNextPage: Bool,
        webMetadata: WebSearchMetadata? = nil
    ) {
        self.repositories = repositories
        self.references = references
        self.totalCount = totalCount
        self.hasNextPage = hasNextPage
        self.webMetadata = webMetadata
    }

    static let empty = SearchProviderPage(
        repositories: [],
        references: [],
        totalCount: 0,
        hasNextPage: false
    )
}

/// 网页搜索的页级元信息。
///
/// 与 vendor-specific 的 `AnySearchMetadata` / `AnySearchRateLimit` 解耦：
/// 后续若引入 Tavily / Brave / Bing 等替代 provider，只需要保持 provider 适配
/// 出同样的 `WebSearchMetadata`，上层 `SearchCoordinator` / ViewModel / View
/// 零改动。
struct WebSearchMetadata: Equatable, Sendable {
    /// API 报告的总命中数（不一定等于实际返回结果数；可能更多）。
    let totalResults: Int?
    /// 远端搜索耗时（毫秒）。
    let searchTimeMs: Int?
    /// HTTP 层限流配额信息（来源：`x-ratelimit-*` header）。三字段缺一即 nil。
    let rateLimit: WebRateLimit?
}

/// 通用网页搜索限流配额（领域层模型）。
///
/// **重要语义说明（dong4j 2026-06-14）**：
/// - `limit` 来源：API 响应头 `x-ratelimit-limit`，反映服务端真实窗口上限（匿名 10 / Bearer 20）。
/// - `sessionUsed` 来源：旧 AnySearch 本地计数。External Search 第一版不再展示统一
///   quota，字段保留给将来 provider 暴露稳定 quota header 时复用。
/// - `resetAt` 来源：API 响应头 `x-ratelimit-reset`（Unix 秒戳）。
///
/// **为什么不直接用 API 返回的 remaining**：实测匿名模式 `remaining` 恒为 8、Bearer 模式恒为 18，
/// API 端并不按真实调用计数更新。展示给用户会产生「为什么数字不变」的困惑（dong4j 2026-06-14 反馈）。
/// 因此领域层放弃 vendor 的 remaining，改用本地计数，更贴合用户「我已经搜了 N 次」的直观感受。
/// 进程重启自然归零（counter 不持久化），符合「会话内配额追踪」的轻量定位。
struct WebRateLimit: Equatable, Sendable {
    let limit: Int
    let sessionUsed: Int
    let resetAt: Date

    /// 剩余配额数（用于 exhausted 分支判定）。允许为负——本地计数若超过 API 上限，
    /// 视为「用尽」状态，UI 钳到 0 后落入红色 chip + 重置时间的展示。
    var sessionRemaining: Int { max(0, limit - sessionUsed) }

    /// 是否已用尽：本地计数 >= 上限。落入 UI 的「额度用尽 · HH:mm 重置」分支。
    var isExhausted: Bool { sessionUsed >= limit && limit > 0 }

    /// 剩余比例，归一化到 [0, 1]，用于 UI 着色阈值判断（绿/橙/红三档）。
    /// limit==0 时返回 0（视为"无可用配额"，染色逻辑会落入"用尽"分支）。
    var fractionRemaining: Double {
        guard limit > 0 else { return 0 }
        return min(max(0, Double(sessionRemaining) / Double(limit)), 1)
    }
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
