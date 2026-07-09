//
//  WeeklyBulkRepository.swift
//  Starcat
//
//  Weekly 客户端 bulk 缓存仓库（R-06.4 渐进式 SWR 双轨制核心）。
//
//  职责：
//  - 调用 `WeeklyAPI.fetchBulkRepos` 一次性拉全量 weekly 聚合数据
//  - 持久化到 `weekly_bulk_repos` / `weekly_bulk_languages` / `weekly_bulk_meta` 三表
//  - 提供 SWR 模式所需的双方法：纯读缓存（立即上屏）+ 走网络刷新（覆盖缓存）
//  - 暴露 `lastRefreshedAt` 给 ViewModel 判 12h TTL（与 TrendingRepository 同款语义）
//
//  设计约束（dong4j R-06.4）：
//  - **客户端 TTL = 12h**：TTL 判断**放在 ViewModel 层**（`WeeklyContentViewModel.bulkTTL` +
//    `WeeklyCachePolicy`），Repository 协议保持纯净。与 `TrendingRepository` 同款分层。
//  - **整批替换语义**：bulk endpoint 返回的是"当前全量快照"，本地写入走"先 DELETE 三张表
//    + 再批量 INSERT"，单 transaction 内完成；不做增量 upsert，因为 server 端语义就是全量。
//  - **网络失败 fallback**：fetchBulk 网络失败时回退到本地缓存；缓存非空就当本次结果返回，
//    否则把网络错误抛出（"离线兜底"语义，与 TrendingRepository 一致）。
//  - **languages 与 repos 同步落盘**：weekly_bulk_languages 与 weekly_bulk_repos 是同一次
//    bulk fetch 的两个副产物，必须在同一 transaction 内一起写入，避免"repos 是新的、languages
//    是旧的"分裂。
//  - **meta 表单行覆写**：weekly_bulk_meta 是 PK = "singleton" 的单行表，每次写入都
//    `save(...)` 整行覆盖即可。
//
//  与 `TrendingRepository` 的差异：
//  - trending 按 (period, language) 分桶缓存，多个并存；weekly bulk 只有一个全量 bucket，
//    所以 Repository 接口更简单（无 since/language 入参）。
//  - trending 返回 `[TrendingRepo]`，weekly 返回 `[WeeklyFeedItem] + [LanguageAggregate]`
//    两段（一次拉两个聚合，省一次网络往返）。
//

import Foundation
import GRDB

/// WeeklyBulkRepository 协议。便于测试时注入 Mock。
protocol WeeklyBulkRepositoryProtocol: Sendable {
    /// 只读取本地 bulk meta 里的 total，不加载 repos / languages。
    ///
    /// Sidebar 只需要周刊总数时走这个轻路径，避免为了一个数字把本地 bulk 明细全读出来。
    func cachedTotal() async -> Int?

    /// 纯读本地缓存，不发网络。
    ///
    /// 返回结构与 `WeeklyAPI.fetchBulkRepos` 等价；缓存为空时返回 `nil`。
    ///
    /// 解码失败的行被跳过（容错），永不抛出（DB 读失败仅记录日志后返回 nil）。
    func cachedBulk() async -> WeeklyBulkCachedSnapshot?

    /// 分页读取本地 bulk cache。
    ///
    /// Weekly 入场首屏只需要 20 条，不能为了首屏把 `weekly_bulk_repos`
    /// 全表 decode 成 `WeeklyFeedItem`。这个路径把筛选 / 排序 / 分页下推给 SQLite，
    /// 只 decode 当前页，显著降低切到 Weekly 分类时的主线程等待体感。
    func cachedPage(query: WeeklyBulkCacheQuery) async -> WeeklyBulkPageSnapshot?

    /// 走网络拉新 + 整批替换缓存 + 返回新数据。
    ///
    /// - 网络成功：覆盖缓存，返回新数据
    /// - 网络失败：fallback 到本地缓存（非空则返回缓存）；缓存为空才把错误抛出
    func fetchBulk() async throws -> WeeklyBulkResult

    /// 读取最近一次成功 bulk 拉取的客户端时间戳。
    ///
    /// 没缓存时返回 nil；永不抛错（DB 读失败仅记录日志后返回 nil）。
    /// 用途：ViewModel 判 12h TTL；UI 显示"上次刷新 X 小时前"。
    func lastRefreshedAt() async -> Date?

    /// 清空 bulk cache（设置页"清除全部缓存"路径走这里）。
    func clearCache() async
}

/// 缓存读出的快照——repos + languages + 元信息 1:1 反映服务端 bulk 响应。
struct WeeklyBulkCachedSnapshot: Sendable {
    let items: [WeeklyFeedItem]
    let languages: [TrendingLanguageAggregateDTO]
    let etag: String?
    let lastFetchedAt: Date
    let generatedAt: String?
    let total: Int
}

struct WeeklyBulkPageSnapshot: Sendable {
    let items: [WeeklyFeedItem]
    let etag: String?
    let lastFetchedAt: Date
    let generatedAt: String?
    let filteredTotal: Int
    let catalogTotal: Int
}

struct WeeklyBulkCacheQuery: Sendable {
    let source: WeeklySourceFilter
    let coverage: WeeklySourceCoverageFilter
    let hideArchived: Bool
    let hideForks: Bool
    let starsFilter: WeeklyStarsFilter
    let pushedRecency: WeeklyPushedRecencyFilter
    let language: String
    let sort: WeeklyFeedSort
    let page: Int
    let pageSize: Int
    let now: Date
}

/// Weekly bulk 数据仓库实现。
actor WeeklyBulkRepository: WeeklyBulkRepositoryProtocol {

    // MARK: - Properties

    private let api: WeeklyAPI
    private let database: any DatabaseManaging

    // MARK: - Initialization

    /// - Parameters:
    ///   - api: 注入的 WeeklyAPI 实例（与 `WeeklyContentViewModel` 共享同一个 actor 实例）。
    ///   - database: 共享数据库句柄。
    init(api: WeeklyAPI, database: any DatabaseManaging) {
        self.api = api
        self.database = database
    }

    // MARK: - SWR

    func cachedTotal() async -> Int? {
        do {
            let meta = try await database.writer.read { db in
                try WeeklyBulkMetaRecord
                    .filter(Column("id") == WeeklyBulkMetaRecord.singletonID)
                    .fetchOne(db)
            }
            return meta?.total
        } catch {
            AppLog.network.warning("WeeklyBulk cachedTotal read failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func cachedBulk() async -> WeeklyBulkCachedSnapshot? {
        do {
            let snapshot = try await database.writer.read { db -> WeeklyBulkCachedSnapshot? in
                guard let meta = try WeeklyBulkMetaRecord
                    .filter(Column("id") == WeeklyBulkMetaRecord.singletonID)
                    .fetchOne(db)
                else {
                    return nil
                }
                guard let lastFetchedAt = ISO8601DateFormatter.shared.date(from: meta.lastFetchedAt) else {
                    AppLog.network.warning(
                        "WeeklyBulk cachedBulk: invalid lastFetchedAt='\(meta.lastFetchedAt, privacy: .public)', treating as empty cache"
                    )
                    return nil
                }
                let repoRecords = try WeeklyBulkRepoRecord
                    .order(Column("latest_event_at").desc)
                    .fetchAll(db)
                let languageRecords = try WeeklyBulkLanguageRecord
                    .order(Column("sort_order").asc)
                    .fetchAll(db)

                let items = repoRecords.compactMap { $0.toDomain() }
                let languages = languageRecords.map { record in
                    TrendingLanguageAggregateDTO(
                        key: record.key,
                        label: record.label,
                        count: record.count
                    )
                }
                return WeeklyBulkCachedSnapshot(
                    items: items,
                    languages: languages,
                    etag: meta.etag,
                    lastFetchedAt: lastFetchedAt,
                    generatedAt: meta.generatedAt,
                    total: meta.total
                )
            }
            if let snapshot {
                AppLog.network.debug("WeeklyBulk cache hit: \(snapshot.items.count) repos / \(snapshot.languages.count) languages")
            }
            return snapshot
        } catch {
            AppLog.network.warning("WeeklyBulk cache read failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func cachedPage(query: WeeklyBulkCacheQuery) async -> WeeklyBulkPageSnapshot? {
        do {
            return try await database.writer.read { db -> WeeklyBulkPageSnapshot? in
                guard let meta = try WeeklyBulkMetaRecord
                    .filter(Column("id") == WeeklyBulkMetaRecord.singletonID)
                    .fetchOne(db)
                else {
                    return nil
                }
                guard let lastFetchedAt = ISO8601DateFormatter.shared.date(from: meta.lastFetchedAt) else {
                    AppLog.network.warning(
                        "WeeklyBulk cachedPage: invalid lastFetchedAt='\(meta.lastFetchedAt, privacy: .public)', treating as empty cache"
                    )
                    return nil
                }

                let page = max(query.page, 1)
                let pageSize = max(query.pageSize, 1)
                let filter = Self.makeSQLFilter(for: query)
                let total = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM weekly_bulk_repos" + filter.whereSQL,
                    arguments: filter.arguments
                ) ?? 0

                let records = try WeeklyBulkRepoRecord.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM weekly_bulk_repos
                    \(filter.whereSQL)
                    ORDER BY \(Self.orderSQL(for: query.sort))
                    LIMIT ? OFFSET ?
                    """,
                    arguments: filter.arguments + [pageSize, (page - 1) * pageSize]
                )
                let items = records.compactMap { $0.toDomain() }
                return WeeklyBulkPageSnapshot(
                    items: items,
                    etag: meta.etag,
                    lastFetchedAt: lastFetchedAt,
                    generatedAt: meta.generatedAt,
                    filteredTotal: total,
                    catalogTotal: meta.total
                )
            }
        } catch {
            AppLog.network.warning("WeeklyBulk cachedPage read failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func fetchBulk() async throws -> WeeklyBulkResult {
        // 第一步：拉网络
        let result: WeeklyBulkResult
        do {
            AppLog.network.info("Fetching weekly bulk")
            result = try await api.fetchBulkRepos()
        } catch {
            // 网络失败 → 离线兜底：返回缓存（非空）
            if let cached = await cachedBulk(), !cached.items.isEmpty {
                AppLog.network.warning("WeeklyBulk network failed, falling back to cache (\(cached.items.count) repos): \(error.localizedDescription, privacy: .public)")
                return WeeklyBulkResult(
                    items: cached.items,
                    languages: cached.languages,
                    etag: cached.etag,
                    generatedAt: cached.generatedAt,
                    total: cached.total
                )
            }
            throw error
        }

        // 第二步：整批替换缓存（repos + languages + meta 同一 transaction）
        let now = Date()
        do {
            try await database.writer.write { db in
                try db.execute(sql: "DELETE FROM weekly_bulk_repos")
                try db.execute(sql: "DELETE FROM weekly_bulk_languages")

                for item in result.items {
                    let record = WeeklyBulkRepoRecord.from(item, cachedAt: now)
                    try record.insert(db)
                }
                for (index, lang) in result.languages.enumerated() {
                    let record = WeeklyBulkLanguageRecord(
                        key: lang.key,
                        label: lang.label,
                        count: lang.count,
                        sortOrder: index
                    )
                    try record.insert(db)
                }

                let meta = WeeklyBulkMetaRecord(
                    id: WeeklyBulkMetaRecord.singletonID,
                    etag: result.etag,
                    lastFetchedAt: ISO8601DateFormatter.shared.string(from: now),
                    generatedAt: result.generatedAt,
                    total: result.total
                )
                // PK 已固定为 singleton，save 等价于 upsert（PK 冲突时覆写）。
                try meta.save(db)
            }
        } catch {
            AppLog.network.error("WeeklyBulk cache write failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }

        return result
    }

    func lastRefreshedAt() async -> Date? {
        do {
            let meta = try await database.writer.read { db in
                try WeeklyBulkMetaRecord
                    .filter(Column("id") == WeeklyBulkMetaRecord.singletonID)
                    .fetchOne(db)
            }
            guard let str = meta?.lastFetchedAt else { return nil }
            return ISO8601DateFormatter.shared.date(from: str)
        } catch {
            AppLog.network.warning("WeeklyBulk lastRefreshedAt read failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func clearCache() async {
        do {
            try await database.writer.write { db in
                try db.execute(sql: "DELETE FROM weekly_bulk_repos")
                try db.execute(sql: "DELETE FROM weekly_bulk_languages")
                try db.execute(sql: "DELETE FROM weekly_bulk_meta")
            }
            AppLog.network.info("WeeklyBulk cache cleared")
        } catch {
            AppLog.network.error("WeeklyBulk clearCache failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func makeSQLFilter(for query: WeeklyBulkCacheQuery) -> (whereSQL: String, arguments: StatementArguments) {
        var clauses: [String] = []
        var arguments = StatementArguments()

        if query.source != .all {
            clauses.append("source_types_json LIKE ?")
            _ = arguments.append(contentsOf: ["%\"\(query.source.rawValue)\"%"])
        }

        switch query.coverage {
        case .all:
            break
        case .multipleSources:
            clauses.append("json_array_length(COALESCE(source_types_json, '[]')) >= 2")
        case .singleSource:
            clauses.append("json_array_length(COALESCE(source_types_json, '[]')) = 1")
        }

        if query.hideArchived {
            clauses.append("is_archived = 0")
        }
        if query.hideForks {
            clauses.append("is_fork = 0")
        }
        if query.starsFilter.rawValue > 0 {
            clauses.append("stars >= ?")
            _ = arguments.append(contentsOf: [query.starsFilter.rawValue])
        }
        if query.pushedRecency.rawValue > 0,
           let cutoff = Calendar(identifier: .gregorian).date(byAdding: .day, value: -query.pushedRecency.rawValue, to: query.now) {
            clauses.append("pushed_at >= ?")
            _ = arguments.append(contentsOf: [ISO8601DateFormatter.shared.string(from: cutoff)])
        }
        if !query.language.isEmpty {
            if query.language == TrendingLanguage.uncategorizedKey {
                clauses.append("(language IS NULL OR language = '')")
            } else {
                clauses.append("lower(language) = lower(?)")
                _ = arguments.append(contentsOf: [query.language])
            }
        }

        guard !clauses.isEmpty else { return ("", arguments) }
        return (" WHERE " + clauses.joined(separator: " AND "), arguments)
    }

    private static func orderSQL(for sort: WeeklyFeedSort) -> String {
        switch sort {
        case .defaultOrder:
            return "latest_event_at DESC, gh_repo_id DESC"
        case .starsDesc:
            return "stars DESC, gh_repo_id DESC"
        case .starsAsc:
            return "stars ASC, gh_repo_id DESC"
        case .updatedDesc:
            return "COALESCE(updated_at, '') DESC, gh_repo_id DESC"
        case .updatedAsc:
            return "COALESCE(updated_at, '\u{FFFD}') ASC, gh_repo_id DESC"
        case .createdDesc:
            return "COALESCE(created_at, '') DESC, gh_repo_id DESC"
        case .createdAsc:
            return "COALESCE(created_at, '\u{FFFD}') ASC, gh_repo_id DESC"
        case .nameAsc:
            return "lower(full_name) ASC, gh_repo_id DESC"
        case .nameDesc:
            return "lower(full_name) DESC, gh_repo_id DESC"
        }
    }
}
