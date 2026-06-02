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
//  设计约束（dong4j 2026-06-02 决策）：
//  - **不设 TTL**（决策 ttl_c）：每次进 Trending 都强制走网络重拉，本地缓存只承担
//    "离线兜底 + 快速首屏 SWR"角色。所以本类没有"是否过期"的判断逻辑，只有
//    "有没有缓存"和"网络是否成功"两个状态。
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

    /// 走网络拉取榜单 + 整批替换缓存 + 返回新数据。
    /// - 网络成功：覆盖该 (period, language_filter) 的本地缓存，返回新数据
    /// - 网络失败：回退到本地缓存（非空则返回缓存，等价于"上次成功的快照"）；缓存为空才把错误抛出
    func fetchTrending(since: TrendingPeriod, language: TrendingLanguage) async throws -> [TrendingRepo]
}

/// Trending 数据仓库实现。
actor TrendingRepository: TrendingRepositoryProtocol {

    // MARK: - Properties

    private let api: TrendingAPI
    private let writer: any DatabaseWriter

    // MARK: - Initialization

    init(api: TrendingAPI = TrendingAPI(), database: any DatabaseManaging) {
        self.api = api
        self.writer = database.writer
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
            let records = try await writer.read { db in
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
    /// 4. 网络失败 → 回退到 `cachedTrending`：非空返回缓存（"离线兜底"），空则抛原网络错误
    ///
    /// 注意：网络成功 + DB 写入失败的极少数 case，这里把 DB 错误抛出，
    /// 因为内存里的新数据没有持久化失败兜底意义，且调用方需要知道"持久化没成功"。
    func fetchTrending(
        since: TrendingPeriod,
        language: TrendingLanguage
    ) async throws -> [TrendingRepo] {
        let period = since.rawValue
        let langFilter = language.apiValue

        // 第一步：拉网络
        let repos: [TrendingRepo]
        do {
            AppLog.network.info("Fetching trending: \(period)/\(langFilter)")
            repos = try await api.fetchTrending(since: since, language: language)
        } catch {
            // 网络失败 → 离线兜底：返回缓存（非空）
            let cached = await cachedTrending(since: since, language: language)
            if !cached.isEmpty {
                AppLog.network.warning("Trending network failed, falling back to cache (\(cached.count) repos): \(error.localizedDescription, privacy: .public)")
                return cached
            }
            // 缓存也空 → 抛原网络错误
            throw error
        }

        // 第二步：整批替换缓存
        // 单事务内 DELETE + 多次 INSERT，保证原子性 —— 避免"删了没写入完"留下空榜单
        let now = Date()
        do {
            try await writer.write { db in
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

        return repos
    }
}
