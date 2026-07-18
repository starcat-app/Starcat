//
//  WeeklyBulkRepoRecord.swift
//  Starcat
//
//  weekly_bulk_repos / weekly_bulk_languages / weekly_bulk_meta 三张表的 GRDB
//  持久化记录（R-06.4 客户端 bulk 缓存层）。
//
//  设计动机：
//  - `WeeklyFeedItem`（见 `WeeklyModels.swift`）是 UI 层值对象：含派生属性
//    （`shortSourceLabel` / 计算属性）+ URL / 嵌套 snapshot struct，直接挂
//    `FetchableRecord/PersistableRecord` 会引入 Codable / URL ↔ TEXT / 嵌套
//    snapshot 怎么入库的一堆杂事。
//  - 拆出 `WeeklyBulkRepoRecord` 作为"db 行模型"专门承担 GRDB 持久化职责，
//    通过 `init(from: WeeklyFeedItem, ...)` / `toDomain()` 与 UI 模型双向转换。
//  - 三个 snapshot（weekly / zread / discovery）存 JSON 字符串而不是拆子表：
//    snapshot 是 weekly 专属 wire payload（issueURL / weekLabel / publishedAt），
//    分表毫无业务价值还引入 N+1 + cascade；JSON 透传到 UI 模型即可。
//
//  关键约束:
//  - 与 `WeeklyFeedItem` 的字段顺序严格 1:1 对齐，新增/删除字段需同步两端 + migration。
//  - 时间字段 `cachedAt` / `firstEventAt` / `latestEventAt` 全部 ISO8601 字符串。
//  - URL 字段（ownerAvatar / homepage / htmlUrl）入库 String 形态，toDomain 时
//    `URL(string:)`，与 `Repo.swift` / `TrendingRepoRecord.swift` 同款桥接策略。
//

import Foundation
import GRDB

// MARK: - weekly_bulk_repos 行映射

/// `weekly_bulk_repos` 表行映射。
struct WeeklyBulkRepoRecord: Codable, FetchableRecord, PersistableRecord, Equatable {

    static let databaseTableName = "weekly_bulk_repos"

    // MARK: - 标识

    /// GitHub repo 数字 id（PK，stable identity）
    var ghRepoId: Int64
    var fullName: String
    var owner: String
    var repo: String
    var name: String

    // MARK: - Card 基础字段

    var ownerAvatar: String?
    var description: String?
    var language: String?
    var stars: Int
    var forks: Int
    var watchers: Int
    var subscribers: Int
    var topicsJSON: String?
    var homepage: String?
    var licenseSpdx: String?
    var isArchived: Bool
    var isFork: Bool
    var isPrivate: Bool
    var defaultBranch: String?
    var openIssues: Int
    var pushedAt: String?
    var updatedAt: String?
    var createdAt: String?
    var htmlUrl: String?

    // MARK: - Feed 专属

    var isAvailable: Bool
    var sourceTypesJSON: String?
    var firstEventAt: String
    var latestEventAt: String
    var weeklySnapshotJSON: String?
    var zreadSnapshotJSON: String?
    var discoverySnapshotJSON: String?
    var sourceEntriesJSON: String?
    var isPinned: Bool
    var pinPosition: Int?

    // MARK: - 缓存维度

    var cachedAt: String

    // MARK: - Codable Keys（snake_case 对齐表列）

    enum CodingKeys: String, CodingKey {
        case ghRepoId = "gh_repo_id"
        case fullName = "full_name"
        case owner
        case repo
        case name
        case ownerAvatar = "owner_avatar"
        case description
        case language
        case stars
        case forks
        case watchers
        case subscribers
        case topicsJSON = "topics_json"
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
        case isAvailable = "is_available"
        case sourceTypesJSON = "source_types_json"
        case firstEventAt = "first_event_at"
        case latestEventAt = "latest_event_at"
        case weeklySnapshotJSON = "weekly_snapshot_json"
        case zreadSnapshotJSON = "zread_snapshot_json"
        case discoverySnapshotJSON = "discovery_snapshot_json"
        case sourceEntriesJSON = "source_entries_json"
        case isPinned = "is_pinned"
        case pinPosition = "pin_position"
        case cachedAt = "cached_at"
    }

    // MARK: - 持久化 → 领域模型

    /// 把行模型转回 UI 层 `WeeklyFeedItem`。
    ///
    /// 三个 snapshot JSON 字段在这里反解码到 `WeeklySnapshot / ZreadSnapshot /
    /// DiscoverySnapshot`；解析失败按 nil 处理（与 wire JSON `weekly: null` 等价）。
    func toDomain() -> WeeklyFeedItem? {
        let decoder = JSONDecoder()

        let topics: [String] = {
            guard let json = topicsJSON,
                  let data = json.data(using: .utf8) else { return [] }
            return (try? decoder.decode([String].self, from: data)) ?? []
        }()

        let sourceTypes: [WeeklySource] = {
            guard let json = sourceTypesJSON,
                  let data = json.data(using: .utf8) else { return [] }
            return (try? decoder.decode([WeeklySource].self, from: data)) ?? []
        }()

        let card = StarcatRepoCardDTO(
            ghRepoId: ghRepoId,
            fullName: fullName,
            owner: owner,
            repo: repo,
            ownerAvatar: ownerAvatar.flatMap(URL.init(string:)),
            description: description,
            language: language,
            stars: stars,
            forks: forks,
            watchers: watchers,
            subscribers: subscribers,
            topics: topics,
            homepage: homepage.flatMap(URL.init(string:)),
            licenseSpdx: licenseSpdx,
            isArchived: isArchived,
            isFork: isFork,
            isPrivate: isPrivate,
            defaultBranch: defaultBranch,
            openIssues: openIssues,
            pushedAt: pushedAt,
            updatedAt: updatedAt,
            createdAt: createdAt,
            htmlUrl: htmlUrl.flatMap(URL.init(string:))
        )

        let dto = WeeklyFeedRepoDTO(
            card: card,
            name: name,
            isAvailable: isAvailable,
            sourceTypes: sourceTypes,
            firstEventAt: firstEventAt,
            latestEventAt: latestEventAt,
            weekly: decodeSnapshot(WeeklySnapshot.self, from: weeklySnapshotJSON, decoder: decoder),
            zread: decodeSnapshot(ZreadSnapshot.self, from: zreadSnapshotJSON, decoder: decoder),
            discovery: decodeSnapshot(DiscoverySnapshot.self, from: discoverySnapshotJSON, decoder: decoder),
            sourceEntries: decodeSnapshot([WeeklySourceEntry].self, from: sourceEntriesJSON, decoder: decoder) ?? [],
            isPinned: isPinned,
            pinPosition: pinPosition
        )
        return WeeklyFeedItem(dto: dto)
    }

    private func decodeSnapshot<T: Decodable>(_ type: T.Type, from json: String?, decoder: JSONDecoder) -> T? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    // MARK: - 领域模型 → 持久化

    /// 从 UI 层 `WeeklyFeedItem` + 缓存时间构造一行 record。
    ///
    /// JSON 编码所有嵌套字段（topics / sourceTypes / 三个 snapshot）；编码失败按 nil
    /// 处理（极小概率，typed Codable 编码不会失败）。
    static func from(_ item: WeeklyFeedItem, cachedAt: Date) -> WeeklyBulkRepoRecord {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let topicsJSON = encodeJSON(item.card.topics, encoder: encoder)
        let sourceTypesJSON = encodeJSON(item.sourceTypes.map(\.rawValue), encoder: encoder)
        let weeklyJSON = encodeJSON(item.weekly, encoder: encoder)
        let zreadJSON = encodeJSON(item.zread, encoder: encoder)
        let discoveryJSON = encodeJSON(item.discovery, encoder: encoder)
        let sourceEntriesJSON = encodeJSON(item.sourceEntries, encoder: encoder)

        return WeeklyBulkRepoRecord(
            ghRepoId: item.ghRepoId,
            fullName: item.fullName,
            owner: item.owner,
            repo: item.card.repo,
            name: item.name,
            ownerAvatar: item.card.ownerAvatar?.absoluteString,
            description: item.description,
            language: item.language,
            stars: item.stars,
            forks: item.card.forks,
            watchers: item.card.watchers,
            subscribers: item.card.subscribers,
            topicsJSON: topicsJSON,
            homepage: item.card.homepage?.absoluteString,
            licenseSpdx: item.card.licenseSpdx,
            isArchived: item.card.isArchived,
            isFork: item.card.isFork,
            isPrivate: item.card.isPrivate,
            defaultBranch: item.card.defaultBranch,
            openIssues: item.card.openIssues,
            pushedAt: item.card.pushedAt,
            updatedAt: item.card.updatedAt,
            createdAt: item.card.createdAt,
            htmlUrl: item.card.htmlUrl?.absoluteString,
            isAvailable: item.isAvailable,
            sourceTypesJSON: sourceTypesJSON,
            firstEventAt: item.firstEventAt,
            latestEventAt: item.latestEventAt,
            weeklySnapshotJSON: weeklyJSON,
            zreadSnapshotJSON: zreadJSON,
            discoverySnapshotJSON: discoveryJSON,
            sourceEntriesJSON: sourceEntriesJSON,
            isPinned: item.isPinned,
            pinPosition: item.pinPosition,
            cachedAt: ISO8601DateFormatter.shared.string(from: cachedAt)
        )
    }

    private static func encodeJSON<T: Encodable>(_ value: T?, encoder: JSONEncoder) -> String? {
        guard let value else { return nil }
        guard let data = try? encoder.encode(value),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }
}

// MARK: - weekly_bulk_sources 行映射

/// bulk v2 来源目录缓存。筛选项来自该表而不是客户端硬编码，新增来源只需后端发布目录。
struct WeeklyBulkSourceRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "weekly_bulk_sources"

    var code: String
    var displayNameZH: String
    var displayNameEN: String
    var iconKey: String
    var sortOrder: Int
    var count: Int

    enum CodingKeys: String, CodingKey {
        case code
        case displayNameZH = "display_name_zh"
        case displayNameEN = "display_name_en"
        case iconKey = "icon_key"
        case sortOrder = "sort_order"
        case count
    }

    init(_ descriptor: WeeklySourceDescriptor) {
        code = descriptor.code
        displayNameZH = descriptor.displayNameZH
        displayNameEN = descriptor.displayNameEN
        iconKey = descriptor.iconKey
        sortOrder = descriptor.sortOrder
        count = descriptor.count
    }

    var descriptor: WeeklySourceDescriptor {
        WeeklySourceDescriptor(
            code: code,
            displayNameZH: displayNameZH,
            displayNameEN: displayNameEN,
            iconKey: iconKey,
            sortOrder: sortOrder,
            count: count
        )
    }
}

// MARK: - weekly_bulk_languages 行映射

/// `weekly_bulk_languages` 表行映射。
///
/// 直接对应 `TrendingLanguageAggregateDTO`（与 weekly /languages endpoint 返回同款
/// schema）+ 一个 `sortOrder` 保留后端原始顺序（DESC count + 未分类置底等业务逻辑
/// 后端做完，客户端只透传）。
struct WeeklyBulkLanguageRecord: Codable, FetchableRecord, PersistableRecord, Equatable {

    static let databaseTableName = "weekly_bulk_languages"

    var key: String
    var label: String
    var count: Int
    var sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case key
        case label
        case count
        case sortOrder = "sort_order"
    }
}

// MARK: - weekly_bulk_meta 行映射

/// `weekly_bulk_meta` 单行表行映射（PK = "singleton"）。
///
/// 全表只有 1 行，存"上次什么时候拉的 / 拉了多少条 / 后端 ETag"，让 ViewModel 跨 App
/// 重启都能读到 lastFetchedAt 判断 6h TTL。
struct WeeklyBulkMetaRecord: Codable, FetchableRecord, PersistableRecord, Equatable {

    /// 固定主键值——meta 表设计为只存一行，所有写入都用这个 id 覆写。
    static let singletonID = "singleton"

    static let databaseTableName = "weekly_bulk_meta"

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
