//
//  TrendingRepository.swift
//  Starcat
//
//  Trending 数据仓库（GRDB 持久化版）。
//
//  职责：
//  - 调用 TrendingAPI 获取榜单数据
//  - 持久化到 `trending_repos` 表（v4 迁移引入）
//  - 提供 SWR 模式所需的双方法：纯读缓存（立即上屏）+ 走网络刷新（覆盖缓存）
//
//  设计约束（dong4j 2026-06-15 R-06.1 修订）：
//  - **客户端 TTL = daily 1h / weekly 6h / monthly 24h**：
//    TTL 判断**放在 ViewModel 层**（`TrendingViewModel.ttl(for:)` + `TrendingCachePolicy`），
//    而非 Repository 内部。理由：ViewModel 已经持有 `lastRefreshedAt` 做新鲜度展示，
//    复用同一份数据判 TTL 最直接；Repository 协议保持纯净（cachedTrending /
//    fetchTrending / lastRefreshedAt 三方法语义不动），调用方按需自行决定何时调用 fetch。
//    这跟"加 cachePolicy 入参到 fetchTrending"的备选方案相比，避免引入"返回值标记
//    from-cache vs from-network"的额外复杂度（否则 ViewModel 不知道要不要更新
//    `lastRefreshedAt = Date()`，会出现 TTL 命中后死循环 always-fresh 的 bug）。
//  - **整批替换**：fetchTrending 拿到新数据后，先 DELETE 该 (period, language_filter) 下的
//    旧行再批量 INSERT 新行。同一榜单内排名可能整体洗牌，行级 upsert 反而会留下脏数据
//    （比如旧第 25 名今天掉出榜了，仅 upsert 不删则它在数据库里仍占第 25 名）。
//  - **网络失败 fallback**：fetchTrending 网络失败时回退到本地缓存，缓存非空就当本次结果返回，
//    否则把网络错误抛出去。这是"离线兜底"语义的关键 —— 用户看到的是上次成功的榜单而不是空白页。
//
//  与 manage 路径的对比（架构上故意保持隔离）：
//  - manage 用 `repos` 表 + `is_starred` 标记，trending 用独立 `trending_repos` 表
//  - manage 写 readme 用 `readmes`（PK repo_id），trending 用 `trending_readmes`（PK full_name）
//  - manage 同步入口是 `SyncManager`（含 ETag 早退 + 增量），trending 仅靠本类的 SWR
//

import Foundation
import GRDB

/// TrendingRepository 协议。
/// 便于测试时注入 Mock。
protocol TrendingRepositoryProtocol: Sendable {
    /// 纯读本地缓存，不发网络。
    /// 没缓存或解码失败时返回空数组（调用方据此判断"是否有可用快照"）。
    func cachedTrending(since: TrendingPeriod, language: TrendingLanguage) async -> [TrendingRepo]

    /// 走网络拉取榜单 + 整批替换缓存 + 返回结果（含网络失败时的缓存回退标记）。
    /// - 网络成功：覆盖该 (period, language_filter) 的本地缓存，`source == .network`
    /// - 网络失败且本地有缓存：返回缓存，`source == .cachedFallback`（不抛错）
    /// - 网络失败且缓存为空：抛出原网络错误
    func fetchTrending(since: TrendingPeriod, language: TrendingLanguage) async throws -> TrendingFetchResult

    /// 读取该 (period, language_filter) 桶的最近一次成功写入时间。
    ///
    /// 实现层取该桶下所有行的 `max(cached_at)`（同一次 fetch 的所有行 cached_at 一致，
    /// 取 max 与取 min 等价；为防御未来跨次部分写入，约定取 max）。
    /// 没缓存时返回 `nil`。永不抛错（DB 读失败仅记录日志后返回 nil）。
    ///
    /// 用途：UI 展示"上次刷新 X 分钟前"新鲜度提示；ViewModel 判断是否要在
    /// 进入页面时主动拉网络（首次入场策略）。
    func lastRefreshedAt(since: TrendingPeriod, language: TrendingLanguage) async -> Date?
}

/// `fetchTrending` 的回传：区分真·网络成功与「网络失败但用了本地缓存」。
///
/// 与 `DiscoveryBulkFetchResult` 同构，避免 ViewModel 把缓存回退误当成刷新成功
/// （否则会清空失败提示、并把 `lastRefreshedAt` 推成现在导致 TTL 假新鲜）。
struct TrendingFetchResult: Sendable {
    let repos: [TrendingRepo]
    let source: Source
    let fallbackErrorDescription: String?

    enum Source: Sendable, Equatable {
        case network
        case cachedFallback
    }
}

/// Trending 数据仓库实现。
actor TrendingRepository: TrendingRepositoryProtocol {

    // MARK: - Properties

    private let api: TrendingAPI
    private let database: any DatabaseManaging

    /// 全量化拉取「某周期全部语言」时使用的 limit，与后端 `HandleReposV1` 上限对齐。
    private static let fullLanguageLimit = 5000

    // MARK: - Initialization

    /// - Parameters:
    ///   - api: 注入的 TrendingAPI 实例。**没有默认参数**——上层（`AppDependencies` /
    ///     测试）必须显式传入，因为 `TrendingAPI()` 已经移除默认 baseURL，强制让
    ///     "端点决策"在调用处可见。
    ///   - database: 共享数据库句柄。
    init(api: TrendingAPI, database: any DatabaseManaging) {
        self.api = api
        self.database = database
    }

    // MARK: - Public API（SWR 接口）

    /// 纯读本地缓存（SWR 第一阶段：立即上屏）。
    ///
    /// 行为：
    /// - 按 (period, language_filter) 过滤，按 `rank` 升序读取
    /// - 解码失败的行被跳过（`toDomain()` 内部容错），避免单行脏数据让整页失败
    /// - 永不抛出：DB 读失败也只记录日志后返回空数组（缓存层降级，不打断 SWR 流程）
    func cachedTrending(
        since: TrendingPeriod,
        language: TrendingLanguage
    ) async -> [TrendingRepo] {
        let period = since.rawValue
        let langFilter = language.apiValue
        do {
            let records = try await database.writer.read { db in
                try TrendingRepoRecord
                    .filter(Column("period") == period && Column("language_filter") == langFilter)
                    .order(Column("rank").asc)
                    .fetchAll(db)
            }
            let repos = records.compactMap { $0.toDomain() }
            if !repos.isEmpty {
                AppLog.network.debug("Trending cache hit: \(period)/\(langFilter), \(repos.count) repos")
            }
            return repos
        } catch {
            AppLog.network.warning("Trending cache read failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// 走网络刷新榜单 + 整批替换缓存（SWR 第二阶段：后台覆盖）。
    ///
    /// 流程：
    /// 1. 调 `TrendingAPI.fetchTrending` 拿新数据
    /// 2. 在单事务内 DELETE 旧的 (period, language_filter) 行 → 按 rank 顺序 INSERT 新行
    /// 3. 写入失败 → 抛错（保留已上屏的缓存数据由调用方决定是否回滚 UI）
    /// 4. 网络失败 → 回退到 `cachedTrending`：非空则 `cachedFallback`；空则抛原网络错误
    ///
    /// 注意：网络成功 + DB 写入失败的极少数 case，这里把 DB 错误抛出，
    /// 因为内存里的新数据没有持久化失败兜底意义，且调用方需要知道"持久化没成功"。
    func fetchTrending(
        since: TrendingPeriod,
        language: TrendingLanguage
    ) async throws -> TrendingFetchResult {
        let period = since.rawValue
        let langFilter = language.apiValue

        // 第一步：拉网络
        let repos: [TrendingRepo]
        do {
            AppLog.network.info("Fetching trending: \(period)/\(langFilter)")
            // 全量化：language 为空（全部语言）时传大 limit 拉全量，与后端 5000 上限对齐。
            let limit = language.rawValue.isEmpty ? Self.fullLanguageLimit : 100
            repos = try await api.fetchTrending(since: since, language: language, limit: limit)
        } catch {
            // 网络失败 → 离线兜底：返回缓存（非空），并标记 source 供 UI 提示。
            let cached = await cachedTrending(since: since, language: language)
            if !cached.isEmpty {
                AppLog.network.warning("Trending network failed, falling back to cache (\(cached.count) repos): \(error.localizedDescription, privacy: .public)")
                return TrendingFetchResult(
                    repos: cached,
                    source: .cachedFallback,
                    fallbackErrorDescription: error.localizedDescription
                )
            }
            // 缓存也空 → 抛原网络错误
            throw error
        }

        // 第二步：整批替换缓存
        // 单事务内 DELETE + 多次 INSERT，保证原子性 —— 避免"删了没写入完"留下空榜单
        let now = Date()
        do {
            try await database.writer.write { db in
                try db.execute(
                    sql: "DELETE FROM trending_repos WHERE period = ? AND language_filter = ?",
                    arguments: [period, langFilter]
                )
                for (index, repo) in repos.enumerated() {
                    var record = TrendingRepoRecord.from(
                        repo,
                        period: since,
                        languageFilter: language,
                        rank: index,
                        cachedAt: now
                    )
                    try record.insert(db)
                }
            }
        } catch {
            AppLog.network.error("Trending cache write failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }

        return TrendingFetchResult(
            repos: repos,
            source: .network,
            fallbackErrorDescription: nil
        )
    }

    /// 读取该桶最近一次成功写入时间（trending_repos.cached_at 的 max）。
    ///
    /// 实现要点：
    /// - `cached_at` 在 schema 里是 `TEXT`，存的是 ISO8601 字符串（见 `TrendingRepoRecord.from(...)`
    ///   里调用 `ISO8601DateFormatter.shared.string(from:)`）。ISO8601 格式按字符串字典序与时间序一致，
    ///   所以可以直接 `ORDER BY cached_at DESC LIMIT 1` 拿最近一行
    /// - 走 GRDB FetchableRecord 拿到 record 后把 `cachedAt: String` 反解为 `Date?`，
    ///   解析失败时降级返回 nil（保持"永不抛错"语义）
    func lastRefreshedAt(
        since: TrendingPeriod,
        language: TrendingLanguage
    ) async -> Date? {
        let period = since.rawValue
        let langFilter = language.apiValue
        do {
            let record = try await database.writer.read { db in
                try TrendingRepoRecord
                    .filter(Column("period") == period && Column("language_filter") == langFilter)
                    .order(Column("cached_at").desc)
                    .fetchOne(db)
            }
            guard let str = record?.cachedAt else { return nil }
            return ISO8601DateFormatter.shared.date(from: str)
        } catch {
            AppLog.network.warning("Trending lastRefreshedAt read failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
