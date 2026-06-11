//
//  TrendingRepoRecord.swift
//  Starcat
//
//  Trending 仓库 GRDB 持久化记录，对应 v4 迁移的 `trending_repos` 表。
//
//  设计动机：
//  - `TrendingRepo`（见 `TrendingModels.swift`）是 UI 层值对象：含派生属性
//    （`periodText` / `id` 计算属性）+ 嵌套 `Contributor` struct + URL 类型字段，
//    直接挂 `FetchableRecord/PersistableRecord` 会引出 Codable / 字符串编码 / URL ↔ TEXT
//    桥接的一堆杂事，且让 UI 模型与 db schema 强耦合。
//  - 拆出 `TrendingRepoRecord` 作为"db 行模型"专门承担 GRDB 持久化职责，
//    通过 `init(from: TrendingRepo, ...)` / `toDomain()` 与 UI 模型双向转换。
//    这与 `Repo`（直接挂 FetchableRecord，因字段简单）刻意不同，trending 复杂度高一档。
//
//  关键约束：
//  - 复合 PK `(period, language_filter, rank)`：同一榜单内由 rank 唯一定位，
//    需要在 SQLite 表层面声明，所以 `databaseTableName` 配合 schema 里的 `t.primaryKey([...])`。
//  - `MutablePersistableRecord` 但不需要 rowID 回填（复合 PK 表 GRDB 默认不写 rowid），
//    `didInsert` 留空。
//  - `contributorsJSON` 存 JSON 数组字符串，业务层用 `contributorsArray` 派生为 `[Contributor]`。
//  - 时间字段 `cachedAt` 存 ISO8601 字符串（与 `repos.cached_at` 对齐，避免时区/格式分歧）。
//

import Foundation
import GRDB

/// `trending_repos` 表行映射。
struct TrendingRepoRecord: Codable, FetchableRecord, MutablePersistableRecord, Equatable {

    static let databaseTableName = "trending_repos"

    // MARK: - 榜单维度

    /// `TrendingPeriod.rawValue`：daily / weekly / monthly
    var period: String
    /// `TrendingLanguage.apiValue`：空串 `""` = 全部语言；具体语言名按 GitHub 原样
    var languageFilter: String
    /// 在该 (period, languageFilter) 列表内的排名（0-based）
    var rank: Int

    // MARK: - repo 维度

    /// GitHub repo 数字 id（R-01 v1.2 GRDB v9，2026-06-10）。
    ///
    /// **NULL 容忍**：v9 ALTER TABLE ADD COLUMN 时未指定 NOT NULL，老缓存行该列
    /// 为 NULL；toDomain() 时退化为 `0`（哨兵），新行（下次 fetchTrending 整批替换）
    /// 永远填实。
    var ghRepoId: Int64?

    var fullName: String
    var owner: String
    var name: String
    var description: String?
    var language: String?
    var starsCount: Int
    var forksCount: Int
    var starsInPeriod: Int
    /// JSON 数组字符串：`[{"username":..., "avatarURL":..., "profileURL":...}]`
    var contributorsJSON: String?

    // MARK: - R-01 v1.2 GRDB v8 新字段（2026-06-10）
    //
    // 与 `repos` 表的对应字段同名同语义（owner_avatar / subscribers_count /
    // default_branch / open_issues_count），全部 Optional 兼容老缓存行 NULL。

    var ownerAvatar: String?
    var subscribersCount: Int?
    var defaultBranch: String?
    var openIssuesCount: Int?

    // MARK: - R-05 trending 详情页字段补齐（2026-06-11，直接进 v4 建表）
    //
    // 与 `repos` 表的对应字段同名同语义，全部 Optional 容 trending-api 偶发字段缺失。
    //
    // **R-05 动机**：trending 详情页 hero 区显示 watchers / topics / license / homepage /
    // created / updated 等字段；之前 ephemeral fallback 路径填 0 / nil，dong4j 真机看
    // 到"Watchers 0 / Created - / Topics N/A"才发现 trending-api 后端早就返这些字段
    // 了，是客户端 `TrendingRepo` 转换层丢字段。详见 `TrendingModels.swift` 同期注释。
    //
    // **schema 落地**：直接写在 v4 `createTrendingRepos` 建表 SQL 里，无独立迁移版本
    // （dong4j 决策「产品都没有上线，直接改 schema 就可以了」）。本地需删一次 sqlite
    // 重建：`~/Library/Containers/com.starcat.app/Data/Library/.../starcat.sqlite`。
    //
    // **持久化语义**：
    // - `topics` TEXT：JSON 数组字符串（如 `["ai","swift"]`），与 `repos.topics` 完全
    //   一致；不另起 trending_topics 明细表，保持持久化 1:1 映射 DTO。
    // - `is_archived / is_fork / is_private` INTEGER（SQLite 用 0/1 存 Bool，GRDB 自动桥）。
    // - 时间字段 ISO8601 字符串，与 `repos.created_at / updated_at / pushed_at` 对齐。

    var watchersCount: Int?
    var topics: String?
    var license: String?
    var homepage: String?
    var isArchived: Bool?
    var isFork: Bool?
    var isPrivate: Bool?
    var pushedAt: String?
    var createdAt: String?
    var updatedAt: String?

    // MARK: - 缓存维度

    /// ISO8601 字符串。仅用于"缓存于 X 前"展示，不参与 TTL 判断（dong4j 决策 ttl_c：不设 TTL）。
    var cachedAt: String

    // MARK: - Codable Keys（snake_case 与表列对齐）

    enum CodingKeys: String, CodingKey {
        case period
        case languageFilter = "language_filter"
        case rank
        // R-01 v1.2 GRDB v9 新增（2026-06-10）
        case ghRepoId = "gh_repo_id"
        case fullName = "full_name"
        case owner
        case name
        case description
        case language
        case starsCount = "stars_count"
        case forksCount = "forks_count"
        case starsInPeriod = "stars_in_period"
        case contributorsJSON = "contributors_json"
        // R-01 v1.2 GRDB v8 新增（2026-06-10）
        case ownerAvatar = "owner_avatar"
        case subscribersCount = "subscribers_count"
        case defaultBranch = "default_branch"
        case openIssuesCount = "open_issues_count"
        // R-05 trending 详情页字段补齐（2026-06-11，直接进 v4 建表）
        case watchersCount = "watchers_count"
        case topics
        case license
        case homepage
        case isArchived = "is_archived"
        case isFork = "is_fork"
        case isPrivate = "is_private"
        case pushedAt = "pushed_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case cachedAt = "cached_at"
    }

    // MARK: - 派生属性

    /// 解析 contributors JSON 字符串为业务模型数组；解析失败返回空数组。
    /// 不持久化此属性。
    var contributorsArray: [TrendingRepo.Contributor] {
        guard let json = contributorsJSON, let data = json.data(using: .utf8) else { return [] }
        let dtos = (try? JSONDecoder().decode([ContributorJSON].self, from: data)) ?? []
        return dtos.map { dto in
            TrendingRepo.Contributor(
                username: dto.username,
                avatarURL: dto.avatarURL.flatMap(URL.init(string:)),
                profileURL: dto.profileURL.flatMap(URL.init(string:))
            )
        }
    }

    /// 转回 UI 模型 `TrendingRepo`。
    ///
    /// 注：`TrendingRepo.url` 是必需字段，从 fullName 重建为 `https://github.com/owner/name`，
    /// 与 `TrendingRepo(card:since:)` 初始化路径一致。URL 拼接走 `GitHubURLs.repo(fullName:)`
    /// 集中目录（2026-06-08 起），原 `URL(string:)` 失败返回 nil 的防御性 guard 移除——
    /// fullName 是 PK 列、入库前已校验非空，URL.init 对 ASCII fullName 不可能失败。
    func toDomain() -> TrendingRepo? {
        let url = GitHubURLs.repo(fullName: fullName)

        let starsInPeriodValue = self.starsInPeriod
        let prefix = starsInPeriodValue > 0 ? "+" : ""
        let periodText = "\(prefix)\(starsInPeriodValue)"

        return TrendingRepo(
            ghRepoId: ghRepoId ?? 0,
            fullName: fullName,
            owner: owner,
            name: name,
            url: url,
            description: description,
            language: language,
            starsCount: starsCount,
            forksCount: forksCount,
            starsInPeriod: starsInPeriodValue,
            periodText: periodText,
            contributors: contributorsArray,
            // R-01 v1.2 GRDB v8 4 字段透传（持久化 → 内存领域模型）
            ownerAvatar: ownerAvatar.flatMap(URL.init(string:)),
            subscribersCount: subscribersCount,
            defaultBranch: defaultBranch,
            openIssuesCount: openIssuesCount,
            // R-05 trending 详情页字段补齐 10 字段透传（持久化 → 内存领域模型）
            watchersCount: watchersCount,
            topics: topics,
            license: license,
            homepage: homepage.flatMap(URL.init(string:)),
            isArchived: isArchived,
            isFork: isFork,
            isPrivate: isPrivate,
            pushedAt: pushedAt,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    // MARK: - 工厂方法

    /// 从业务模型 + 榜单维度构造一行 record。
    ///
    /// - Parameters:
    ///   - repo: UI 层 `TrendingRepo`
    ///   - period: 当前榜单时间维度
    ///   - languageFilter: 当前语言筛选（空串表示全部）
    ///   - rank: 在该榜单内的排名（0-based）
    ///   - cachedAt: 持久化时间（一般传 `Date()` 转 ISO8601）
    static func from(
        _ repo: TrendingRepo,
        period: TrendingPeriod,
        languageFilter: TrendingLanguage,
        rank: Int,
        cachedAt: Date
    ) -> TrendingRepoRecord {
        let contributorsJSON: String? = {
            guard !repo.contributors.isEmpty else { return nil }
            let dtos = repo.contributors.map { c in
                ContributorJSON(
                    username: c.username,
                    avatarURL: c.avatarURL?.absoluteString,
                    profileURL: c.profileURL?.absoluteString
                )
            }
            guard let data = try? JSONEncoder().encode(dtos),
                  let str = String(data: data, encoding: .utf8) else {
                return nil
            }
            return str
        }()

        return TrendingRepoRecord(
            period: period.rawValue,
            languageFilter: languageFilter.apiValue,
            rank: rank,
            // R-01 v1.2 GRDB v9：ghRepoId 持久化以支撑 RepoCardViewData.id + 跨场景 ✓
            ghRepoId: repo.ghRepoId,
            fullName: repo.fullName,
            owner: repo.owner,
            name: repo.name,
            description: repo.description,
            language: repo.language,
            starsCount: repo.starsCount,
            forksCount: repo.forksCount,
            starsInPeriod: repo.starsInPeriod,
            contributorsJSON: contributorsJSON,
            // R-01 v1.2 GRDB v8 4 字段（领域模型 → 持久化）
            ownerAvatar: repo.ownerAvatar?.absoluteString,
            subscribersCount: repo.subscribersCount,
            defaultBranch: repo.defaultBranch,
            openIssuesCount: repo.openIssuesCount,
            // R-05 trending 详情页字段补齐 10 字段（领域模型 → 持久化）
            watchersCount: repo.watchersCount,
            topics: repo.topics,
            license: repo.license,
            homepage: repo.homepage?.absoluteString,
            isArchived: repo.isArchived,
            isFork: repo.isFork,
            isPrivate: repo.isPrivate,
            pushedAt: repo.pushedAt,
            createdAt: repo.createdAt,
            updatedAt: repo.updatedAt,
            cachedAt: ISO8601DateFormatter.shared.string(from: cachedAt)
        )
    }
}

// MARK: - Contributor JSON 编解码

/// 嵌套 JSON 编解码占位（避免 URL 类型 ↔ JSON 桥接的边界处理）。
private struct ContributorJSON: Codable {
    let username: String
    let avatarURL: String?
    let profileURL: String?
}

// MARK: - TrendingRepo 反向构造扩展

extension TrendingRepo {
    /// 从持久化字段直接构造（GRDB 行 → 业务模型），与 DTO 初始化路径并存。
    ///
    /// R-01 v1.2 GRDB v8（2026-06-10）：扩 4 字段（ownerAvatar / subscribersCount /
    /// defaultBranch / openIssuesCount）；所有字段 Optional，老缓存行 NULL 不影响构造。
    ///
    /// R-05（2026-06-11，10 列直接进 v4 建表）：再扩 10 字段（watchersCount / topics /
    /// license / homepage / isArchived / isFork / isPrivate / pushedAt / createdAt /
    /// updatedAt）；全部 default = nil，老 callsite 无需逐个补参。
    init(
        ghRepoId: Int64,
        fullName: String,
        owner: String,
        name: String,
        url: URL,
        description: String?,
        language: String?,
        starsCount: Int,
        forksCount: Int,
        starsInPeriod: Int,
        periodText: String,
        contributors: [Contributor],
        ownerAvatar: URL? = nil,
        subscribersCount: Int? = nil,
        defaultBranch: String? = nil,
        openIssuesCount: Int? = nil,
        watchersCount: Int? = nil,
        topics: String? = nil,
        license: String? = nil,
        homepage: URL? = nil,
        isArchived: Bool? = nil,
        isFork: Bool? = nil,
        isPrivate: Bool? = nil,
        pushedAt: String? = nil,
        createdAt: String? = nil,
        updatedAt: String? = nil
    ) {
        self.ghRepoId = ghRepoId
        self.fullName = fullName
        self.owner = owner
        self.name = name
        self.url = url
        self.description = description
        self.language = language
        self.starsCount = starsCount
        self.forksCount = forksCount
        self.starsInPeriod = starsInPeriod
        self.periodText = periodText
        self.contributors = contributors
        self.ownerAvatar = ownerAvatar
        self.subscribersCount = subscribersCount
        self.defaultBranch = defaultBranch
        self.openIssuesCount = openIssuesCount
        self.watchersCount = watchersCount
        self.topics = topics
        self.license = license
        self.homepage = homepage
        self.isArchived = isArchived
        self.isFork = isFork
        self.isPrivate = isPrivate
        self.pushedAt = pushedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
