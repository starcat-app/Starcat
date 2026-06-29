//
//  WeeklyModels.swift
//  Starcat
//
//  Activity / Weekly 三源聚合 feed 的网络 DTO 与 UI 领域模型。
//
//  数据源：starcat-weekly-api R-04 聚合接口。
//  关键约束：
//  - 后端 wire JSON 是扁平对象：同一个对象同时包含 `StarcatRepoCardDTO`
//    字段和 feed 专属字段；前端用自定义解码组合成 `card + feed fields`，
//    不污染通用 Repo Card schema。
//  - `gh_repo_id` 是唯一稳定身份；owner/name/full_name 只用于显示和跳转。
//  - source enum 必须容忍未知值，后端未来新增来源时旧客户端不应整批解码失败。
//

import Foundation

// MARK: - Source

enum WeeklySource: Decodable, Hashable, Sendable {
    case weekly
    case zread
    case discovery
    case unknown(String)

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "weekly": self = .weekly
        case "zread": self = .zread
        case "discovery": self = .discovery
        default: self = .unknown(raw)
        }
    }

    var rawValue: String {
        switch self {
        case .weekly: return "weekly"
        case .zread: return "zread"
        case .discovery: return "discovery"
        case .unknown(let raw): return raw
        }
    }

    var displayName: String {
        switch self {
        case .weekly: return String.l10n("weekly.source.ruanyf")
        case .zread: return "ZRead"
        case .discovery: return "Hacker News"
        case .unknown(let raw): return raw
        }
    }

    var assetName: String {
        switch self {
        case .weekly: return "WeeklySources/ruanyf"
        case .zread: return "WeeklySources/zread"
        case .discovery: return "WeeklySources/hackernews"
        case .unknown: return "questionmark.circle.fill"
        }
    }
}

/// Weekly 列表顶部的来源筛选。
///
/// 它刻意独立于 `WeeklySource`：`WeeklySource` 表示后端 wire 里的真实来源，
/// 而这里多了 `.all` 这个 UI 哨兵值。这样可以把"全部来源"留在前端状态层，
/// 不污染后端 source 枚举，也避免把来源筛选误当成排序。
enum WeeklySourceFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case weekly
    case zread
    case discovery

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .all:
            return String.l10n("weekly.filter.source.all")
        case .weekly:
            return String.l10n("weekly.filter.source.ruanyf")
        case .zread:
            return "ZRead"
        case .discovery:
            return "Hacker News"
        }
    }

    /// 后端 `/api/v1/repos` 的 `source` 参数值；`.all` 不发送参数。
    var queryValue: String? {
        source?.rawValue
    }

    /// 对应的真实 wire source。`.all` 是 UI 哨兵，不映射到后端枚举。
    private var source: WeeklySource? {
        switch self {
        case .all:       return nil
        case .weekly:    return .weekly
        case .zread:     return .zread
        case .discovery: return .discovery
        }
    }

    func matches(_ item: WeeklyFeedItem) -> Bool {
        guard let source else { return true }
        return item.sourceTypes.contains(source)
    }
}

/// 来源覆盖强度筛选。
///
/// 这里看的是同一个 GitHub repo 被几个发现源收录，不关心具体来源是哪一个。
/// 和 `WeeklySourceFilter` 可以组合使用：例如“ZRead + 多来源”表示“出现在 ZRead，
/// 且至少还被另一个来源收录”。
enum WeeklySourceCoverageFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case multipleSources
    case singleSource

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .all:
            return String.l10n("weekly.filter.coverage.all")
        case .multipleSources:
            return String.l10n("weekly.filter.coverage.multiple")
        case .singleSource:
            return String.l10n("weekly.filter.coverage.single")
        }
    }

    func matches(_ item: WeeklyFeedItem) -> Bool {
        switch self {
        case .all:
            return true
        case .multipleSources:
            return item.sourceTypes.count >= 2
        case .singleSource:
            return item.sourceTypes.count == 1
        }
    }
}

/// Stars 阈值筛选。
///
/// 使用固定档位而不是任意数字输入，是为了让菜单保持轻量；复杂数值筛选更适合
/// Manage 的高级筛选，不适合 Weekly 这个发现流入口。
enum WeeklyStarsFilter: Int, CaseIterable, Identifiable, Sendable {
    case all = 0
    case min100 = 100
    case min1000 = 1_000
    case min10000 = 10_000

    var id: Int { rawValue }

    var localizedTitle: String {
        switch self {
        case .all:
            return String.l10n("weekly.filter.stars.all")
        case .min100:
            return String.l10n("weekly.filter.stars.min100")
        case .min1000:
            return String.l10n("weekly.filter.stars.min1k")
        case .min10000:
            return String.l10n("weekly.filter.stars.min10k")
        }
    }

    func matches(_ item: WeeklyFeedItem) -> Bool {
        guard rawValue > 0 else { return true }
        return item.stars >= rawValue
    }
}

/// 最近 push 时间窗筛选。
///
/// `pushed_at` 是 GitHub 原生 metadata。这里筛的是仓库代码推送时间，不是周刊来源的
/// 收录时间；缺失时按“不满足时间窗”处理，避免未 enrich 完整的项目误进结果。
enum WeeklyPushedRecencyFilter: Int, CaseIterable, Identifiable, Sendable {
    case all = 0
    case days30 = 30
    case days90 = 90
    case days365 = 365

    var id: Int { rawValue }

    var localizedTitle: String {
        switch self {
        case .all:
            return String.l10n("weekly.filter.activity.all")
        case .days30:
            return String.l10n("weekly.filter.activity.pushed30d")
        case .days90:
            return String.l10n("weekly.filter.activity.pushed90d")
        case .days365:
            return String.l10n("weekly.filter.activity.pushed365d")
        }
    }

    func matches(_ item: WeeklyFeedItem, now: Date = Date()) -> Bool {
        guard rawValue > 0 else { return true }
        guard let raw = item.card.pushedAt,
              let pushedAt = String.weeklyDate(from: raw),
              let cutoff = Calendar(identifier: .gregorian).date(byAdding: .day, value: -rawValue, to: now) else {
            return false
        }
        return pushedAt >= cutoff
    }
}

// MARK: - Snapshots

// R-06.4：三个 Snapshot 都升级到 `Codable`（= `Decodable + Encodable`）。
// 原 wire 解码只需要 `Decodable`，但 R-06.4 客户端 bulk 缓存表把整个 snapshot 序列化
// 成 JSON 字符串落 SQLite（`WeeklyBulkRepoRecord.weeklySnapshotJSON` 等），落盘路径
// 需要 `Encodable`。加 `Encodable` 用 synthesized impl，CodingKeys 复用同套 snake_case
// 映射，与 wire 完全等价 round-trip。
struct WeeklySnapshot: Codable, Hashable, Sendable {
    let issueNumber: Int
    let issueURL: URL?
    let recommendation: String?

    enum CodingKeys: String, CodingKey {
        case issueNumber = "issue_number"
        case issueURL = "issue_url"
        case recommendation
    }
}

struct ZreadSnapshot: Codable, Hashable, Sendable {
    let weekStart: String
    let weekEnd: String?
    let weekLabel: String?
    let rankInWeek: Int
    let descriptionZh: String?

    enum CodingKeys: String, CodingKey {
        case weekStart = "week_start"
        case weekEnd = "week_end"
        case weekLabel = "week_label"
        case rankInWeek = "rank_in_week"
        case descriptionZh = "description_zh"
    }
}

struct DiscoverySnapshot: Codable, Hashable, Sendable {
    let hnID: Int64
    let title: String
    let score: Int
    let comments: Int
    let publishedAt: String

    enum CodingKeys: String, CodingKey {
        case hnID = "hn_id"
        case title
        case score
        case comments
        case publishedAt = "published_at"
    }
}

// MARK: - DTO

struct WeeklyFeedRepoDTO: Decodable, Equatable, Sendable {
    let card: StarcatRepoCardDTO
    let name: String
    let isAvailable: Bool
    let sourceTypes: [WeeklySource]
    let firstEventAt: String
    let latestEventAt: String
    let weekly: WeeklySnapshot?
    let zread: ZreadSnapshot?
    let discovery: DiscoverySnapshot?

    enum CodingKeys: String, CodingKey {
        case name
        case isAvailable = "is_available"
        case sourceTypes = "source_types"
        case firstEventAt = "first_event_at"
        case latestEventAt = "latest_event_at"
        case weekly
        case zread
        case discovery
    }

    enum CardCodingKeys: String, CodingKey {
        case ghRepoId = "gh_repo_id"
        case fullName = "full_name"
        case owner
        case repo
        case ownerAvatar = "owner_avatar"
        case description
        case language
        case stars
        case forks
        case watchers
        case subscribers
        case topics
        case homepage
        case licenseSpdx = "license_spdx"
        case isArchived = "is_archived"
        case isFork = "is_fork"
        case isPrivate = "is_private"
        case defaultBranch = "default_branch"
        case openIssues = "open_issues"
        case pushedAt = "pushed_at"
        case updatedAt = "updated_at"
        case createdAt = "created_at"
        case htmlUrl = "html_url"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.card = try Self.decodeCard(from: decoder)
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? card.repo
        self.isAvailable = try c.decodeIfPresent(Bool.self, forKey: .isAvailable) ?? true
        self.sourceTypes = try c.decodeIfPresent([WeeklySource].self, forKey: .sourceTypes) ?? []
        self.firstEventAt = try c.decode(String.self, forKey: .firstEventAt)
        self.latestEventAt = try c.decode(String.self, forKey: .latestEventAt)
        self.weekly = try c.decodeIfPresent(WeeklySnapshot.self, forKey: .weekly)
        self.zread = try c.decodeIfPresent(ZreadSnapshot.self, forKey: .zread)
        self.discovery = try c.decodeIfPresent(DiscoverySnapshot.self, forKey: .discovery)
    }

    /// 从同一个扁平 JSON object 解出共享 Repo Card 字段。
    ///
    /// 不能直接调用 `StarcatRepoCardDTO(from:)`：R-04 后端的 `weekly` 字段已经改成
    /// aggregate snapshot（`issue_number`），而旧通用 DTO 的 `WeeklyExtension` 仍是
    /// R-01 语义（`first_issue`）。这里显式只取 GitHub repo metadata 字段，避免
    /// feed 专属 `weekly/zread/discovery` 扩展段污染通用 Card DTO。
    private static func decodeCard(from decoder: Decoder) throws -> StarcatRepoCardDTO {
        let c = try decoder.container(keyedBy: CardCodingKeys.self)
        return StarcatRepoCardDTO(
            ghRepoId: try c.decode(Int64.self, forKey: .ghRepoId),
            fullName: try c.decode(String.self, forKey: .fullName),
            owner: try c.decode(String.self, forKey: .owner),
            repo: try c.decode(String.self, forKey: .repo),
            ownerAvatar: try decodeOptionalURL(c, forKey: .ownerAvatar),
            description: try c.decodeIfPresent(String.self, forKey: .description),
            language: try c.decodeIfPresent(String.self, forKey: .language),
            stars: try c.decodeIfPresent(Int.self, forKey: .stars) ?? 0,
            forks: try c.decodeIfPresent(Int.self, forKey: .forks) ?? 0,
            watchers: try c.decodeIfPresent(Int.self, forKey: .watchers) ?? 0,
            subscribers: try c.decodeIfPresent(Int.self, forKey: .subscribers) ?? 0,
            topics: try c.decodeIfPresent([String].self, forKey: .topics) ?? [],
            homepage: try decodeOptionalURL(c, forKey: .homepage),
            licenseSpdx: try c.decodeIfPresent(String.self, forKey: .licenseSpdx),
            isArchived: try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false,
            isFork: try c.decodeIfPresent(Bool.self, forKey: .isFork) ?? false,
            isPrivate: try c.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false,
            defaultBranch: try c.decodeIfPresent(String.self, forKey: .defaultBranch),
            openIssues: try c.decodeIfPresent(Int.self, forKey: .openIssues) ?? 0,
            pushedAt: try c.decodeIfPresent(String.self, forKey: .pushedAt),
            updatedAt: try c.decodeIfPresent(String.self, forKey: .updatedAt),
            createdAt: try c.decodeIfPresent(String.self, forKey: .createdAt),
            htmlUrl: try decodeOptionalURL(c, forKey: .htmlUrl)
        )
    }

    private static func decodeOptionalURL(
        _ container: KeyedDecodingContainer<CardCodingKeys>,
        forKey key: CardCodingKeys
    ) throws -> URL? {
        guard let raw = try container.decodeIfPresent(String.self, forKey: key) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    init(
        card: StarcatRepoCardDTO,
        name: String? = nil,
        isAvailable: Bool = true,
        sourceTypes: [WeeklySource],
        firstEventAt: String,
        latestEventAt: String,
        weekly: WeeklySnapshot? = nil,
        zread: ZreadSnapshot? = nil,
        discovery: DiscoverySnapshot? = nil
    ) {
        self.card = card
        self.name = name ?? card.repo
        self.isAvailable = isAvailable
        self.sourceTypes = sourceTypes
        self.firstEventAt = firstEventAt
        self.latestEventAt = latestEventAt
        self.weekly = weekly
        self.zread = zread
        self.discovery = discovery
    }
}

struct WeeklyRepoDetail: Decodable, Equatable, Sendable {
    let repo: WeeklyFeedRepoDTO
    let events: [WeeklySourceEvent]
}

struct WeeklySourceEvent: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let source: WeeklySource
    let occurredAt: String
    let url: URL?
    let weekly: WeeklyEventPayload?
    let zread: ZreadEventPayload?
    let discovery: DiscoveryEventPayload?

    enum CodingKeys: String, CodingKey {
        case id
        case source
        case occurredAt = "occurred_at"
        case url
        case weekly
        case zread
        case discovery
    }
}

struct WeeklyEventPayload: Decodable, Hashable, Sendable {
    let issueNumber: Int
    let recommendation: String?

    enum CodingKeys: String, CodingKey {
        case issueNumber = "issue_number"
        case recommendation
    }
}

struct ZreadEventPayload: Decodable, Hashable, Sendable {
    let weekStart: String
    let weekEnd: String?
    let rankInWeek: Int
    let descriptionZh: String?

    enum CodingKeys: String, CodingKey {
        case weekStart = "week_start"
        case weekEnd = "week_end"
        case rankInWeek = "rank_in_week"
        case descriptionZh = "description_zh"
    }
}

struct DiscoveryEventPayload: Decodable, Hashable, Sendable {
    let hnID: Int64
    let title: String
    let score: Int
    let comments: Int

    enum CodingKeys: String, CodingKey {
        case hnID = "hn_id"
        case title
        case score
        case comments
    }
}

// MARK: - Domain

struct WeeklyFeedItem: Identifiable, Equatable, Sendable {
    var id: Int64 { ghRepoId }

    let card: StarcatRepoCardDTO
    let isAvailable: Bool
    let sourceTypes: [WeeklySource]
    let firstEventAt: String
    let latestEventAt: String
    let weekly: WeeklySnapshot?
    let zread: ZreadSnapshot?
    let discovery: DiscoverySnapshot?

    var ghRepoId: Int64 { card.ghRepoId }
    var owner: String { card.owner }
    var name: String { card.repo }
    var fullName: String { card.fullName }
    var url: URL { card.htmlUrl ?? GitHubURLs.repo(owner: card.owner, repo: card.repo) }
    var description: String? { card.description }
    var language: String? { card.language }
    var stars: Int { card.stars }

    /// 列表行右侧短标签：按最有代表性的已知来源选择，保持极短避免挤压 repo name。
    var shortSourceLabel: String? {
        if let issueNumber = weekly?.issueNumber {
            return "\(issueNumber)"
        }
        if let label = zread?.weekLabel, !label.isEmpty {
            return label
        }
        if let date = discovery?.publishedAt.shortMonthDayString {
            return date
        }
        return nil
    }

    init(dto: WeeklyFeedRepoDTO) {
        self.card = dto.card
        self.isAvailable = dto.isAvailable
        self.sourceTypes = dto.sourceTypes
        self.firstEventAt = dto.firstEventAt
        self.latestEventAt = dto.latestEventAt
        self.weekly = dto.weekly
        self.zread = dto.zread
        self.discovery = dto.discovery
    }
}

// MARK: - Query parameters

struct WeeklyFeedQuery: Equatable, Sendable {
    let source: WeeklySourceFilter
    let language: String?
    let sort: WeeklyFeedSort
    let order: WeeklyFeedOrder
    let page: Int
    let pageSize: Int

    init(
        source: WeeklySourceFilter = .all,
        language: String? = nil,
        sort: WeeklyFeedSort = .latestEventAt,
        order: WeeklyFeedOrder = .desc,
        page: Int = 1,
        pageSize: Int = WeeklyAPI.defaultPageSize
    ) {
        self.source = source
        self.language = language
        self.sort = sort
        self.order = order
        self.page = page
        self.pageSize = pageSize
    }
}

enum WeeklyFeedSort: String, CaseIterable, Identifiable, Sendable {
    case latestEventAt = "latest_event_at"
    case stars
    case pushedAt = "pushed_at"

    var id: String { rawValue }
}

enum WeeklyFeedOrder: String, Sendable {
    case asc
    case desc
}

// MARK: - Display helpers

extension String {
    fileprivate var shortMonthDayString: String? {
        guard let date = Self.weeklyDate(from: self) else { return nil }
        let components = Calendar(identifier: .gregorian).dateComponents([.month, .day], from: date)
        guard let month = components.month, let day = components.day else { return nil }
        return "\(month).\(day)"
    }

    fileprivate var fullYearMonthDayString: String? {
        guard let date = Self.weeklyDate(from: self) else { return nil }
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else { return nil }
        return "\(year).\(month).\(day)"
    }

    private static func makeWeeklyDateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    private static func makeWeeklyFractionalDateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    fileprivate static func weeklyDate(from raw: String) -> Date? {
        makeWeeklyDateFormatter().date(from: raw) ?? makeWeeklyFractionalDateFormatter().date(from: raw)
    }
}
