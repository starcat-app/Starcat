//
//  RepoRepository.swift
//  Starcat
//
//  Repo 持久化 Repository（GRDB 实现）。
//
//  ⚠️ 命名注意（D-01）：
//  - 内部 struct 名为 `GRDBRepoRepository`（实现），协议层抽象为 `RepoRepositoryProtocol`
//    （定义见 `RepoRepositoryProtocol.swift`）
//  - 文件名仍叫 `RepoRepository.swift` 是为了避免大幅触动 .pbxproj
//    （本项目用 xcodegen，文件名变更后下次 `xcodegen generate` 会自动跟随，
//    但当前会话手改 pbxproj 成本高于收益）
//  - 调用方应依赖 `any RepoRepositoryProtocol`，仅 AppDependencies / 测试构造时
//    用具体类型 `GRDBRepoRepository(database:)`
//
//  职责：
//  - 将 GitHubRepoDTO / StarredRepoDTO 转换为本地 Repo / StarredRepo 模型并写库（批量 upsert）
//  - 检测远端缺失的本地 repo（用户取消 star）→ 标记 is_starred = false 而非删除（保留笔记/标签）
//  - 提供 SyncManager 需要的全部数据库操作
//
//  设计约束：
//  - 不直接持有 DatabaseManager 单例，依赖 DatabaseManaging 协议，便于内存测试
//  - DTO → Model 映射保持显式（不依赖 JSON 中间转换），避免无声字段丢失
//

import Foundation
import GRDB

// MARK: - 查询投影

/// `SELECT language, COUNT(*) FROM ...` 的行映射。
/// `language` 列在 SQL 里已 COALESCE 为空字符串以避免 NULL 比较坑。
struct LanguageStat: FetchableRecord, Codable, Equatable, Identifiable {
    /// 仓库主语言；空字符串表示 GitHub 上无主语言（纯文本/配置项目）。
    let language: String
    /// 该语言下已 star 的 repo 数量。
    let count: Int

    /// Identifiable id：直接用 language（空串也是合法 id）。
    var id: String { language }

    /// 渲染用：空语言统一硬编码显示为 "Uncategorized"（dong4j 2026-06-16 决定不做国际化，
    /// 中英文均显示英文原词），真实语言名按 GitHub 返回值原样显示。
    var displayName: String { language.isEmpty ? "Uncategorized" : language }

    /// 实际语言筛选用：空串对应数据库里 NULL（fetchByLanguage(nil)）。
    var languageOrNil: String? { language.isEmpty ? nil : language }
}

/// Repo Repository（GRDB 实现）。D-01：原名 `RepoRepository`，改名 `GRDBRepoRepository`，
/// 协议抽象 `RepoRepositoryProtocol` 见同目录另一文件。
struct GRDBRepoRepository {

    /// 数据库门面（持有协议引用，每次 query 通过 `database.writer` 拿到当前 pool）。
    /// 2026-06-12 多账号 DB 隔离改造：原 `private let writer: any DatabaseWriter`
    /// 切到协议引用是为了支持 DatabaseManager 内部 reopen 时切换 pool；
    /// **不要** 缓存 `database.writer` 为本地 let，否则切账号后还会写到老 DB。
    private let database: any DatabaseManaging

    init(database: any DatabaseManaging) {
        self.database = database
    }

    // MARK: - Upsert

    /// 批量 upsert 一组 starred repos。
    /// 同时维护 starred_repos 表（user-repo 关系 + starred_at）。
    /// 整批写入在一个事务里，保证原子性。
    func upsertStarred(_ dtos: [StarredRepoDTO], userID: Int64, syncedAt: Date) async throws {
        guard !dtos.isEmpty else { return }
        let cachedAtISO = ISO8601DateFormatter.shared.string(from: syncedAt)

        try await database.writer.write { db in
            for dto in dtos {
                var repo = Self.repoFromDTO(dto.repo, starredAt: dto.starredAt, cachedAt: cachedAtISO)
                try repo.save(db)
                try GRDBRepoStarHistoryRepository.saveLocalSnapshot(
                    repoId: dto.repo.id,
                    starsCount: dto.repo.stargazersCount,
                    observedAt: syncedAt,
                    fetchedAt: syncedAt,
                    db: db
                )

                var starred = StarredRepo(
                    repoId: dto.repo.id,
                    userId: userID,
                    starredAt: dto.starredAt,
                    syncStatus: "synced",
                    lastSyncAt: cachedAtISO
                )
                try starred.save(db)
            }
        }
    }

    // MARK: - 标记取消 star

    /// 将本地存在但不在传入 ID 集合中的 repo 标记为 is_starred = false。
    /// 同时清理 starred_repos 中相应行。
    /// 不删除 repo / 笔记 / 标签，确保用户数据安全。
    func markUnstarredExcept(remoteRepoIDs: Set<Int64>, userID: Int64) async throws {
        try await database.writer.write { db in
            let localIDs = try Int64.fetchSet(db, sql: "SELECT id FROM repos WHERE is_starred = 1")
            let toUnstar = localIDs.subtracting(remoteRepoIDs)
            guard !toUnstar.isEmpty else { return }

            // SQLite IN (...) 不支持数组绑定，手动展开占位符
            let placeholders = Array(repeating: "?", count: toUnstar.count).joined(separator: ",")
            let args = toUnstar.map { $0 as DatabaseValueConvertible }

            try db.execute(
                sql: "UPDATE repos SET is_starred = 0 WHERE id IN (\(placeholders))",
                arguments: StatementArguments(args)
            )
            try db.execute(
                sql: "DELETE FROM starred_repos WHERE user_id = ? AND repo_id IN (\(placeholders))",
                arguments: StatementArguments([userID] + args)
            )

            AppLog.sync.info("Marked \(toUnstar.count, privacy: .public) repos as unstarred")
        }
    }

    /// W4 B1：单个 repo unstar。
    /// 复用 markUnstarredExcept 的同款语义：UPDATE is_starred=0 + DELETE starred_repos 行。
    /// 不删 repo / 笔记 / 标签关联，给用户保留 re-star 后立刻恢复数据的可能。
    func markUnstarred(repoId: Int64, userID: Int64) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE repos SET is_starred = 0 WHERE id = ?",
                arguments: [repoId]
            )
            try db.execute(
                sql: "DELETE FROM starred_repos WHERE user_id = ? AND repo_id = ?",
                arguments: [userID, repoId]
            )
            AppLog.sync.info("Marked repo \(repoId, privacy: .public) as unstarred (user=\(userID, privacy: .public))")
        }
    }

    // MARK: - R-01：StarredRegistry 派生 + 单 repo star 写入

    /// R-01：拉取当前所有「已 star」的 GitHub repo id（is_starred = 1）。
    ///
    /// 用 `Int64.fetchAll(... ORDER BY id)` 单列返回，避免实例化 `Repo` 行（节省内存 + 反序列化）。
    /// 1.8K starred 的项目实测 ~5ms 内完成。
    func fetchStarredRepoIDs() async throws -> [Int64] {
        try await database.writer.read { db in
            try Int64.fetchAll(db, sql: "SELECT id FROM repos WHERE is_starred = 1 ORDER BY id")
        }
    }

    func fetchKnowledgeRepoIDs() async throws -> [Int64] {
        try await database.writer.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT r.id
                FROM repos r
                JOIN repo_notes rn ON rn.repo_id = r.id
                WHERE rn.library_state = 'in_library'
                ORDER BY r.id
                """)
        }
    }

    /// R-01：单个 repo star 时写入 `repos` + `starred_repos`。
    ///
    /// 调用链：`StarActionService.star(owner:repo:)`
    ///   1. PUT /user/starred/{o}/{r}（GitHub）
    ///   2. GET /repos/{o}/{r}（拉完整字段）
    ///   3. **本方法**：upsert + isStarred=1 + 写 starred_repos
    ///   4. registry._add(saved.id)
    ///
    /// `starredAt` 来源：GitHub `PUT /user/starred` 没有响应体，手动用「调用时刻」作为 starredAt
    /// （格式与 SyncManager 全量同步保持一致：ISO8601 带 Z），后续 SyncManager 增量同步会
    /// 用 GitHub 真值覆盖。
    func upsertSingleStarred(
        repoDTO: GitHubRepoDTO,
        starredAt: String?,
        userID: Int64,
        syncedAt: Date
    ) async throws -> Repo {
        let cachedAtISO = ISO8601DateFormatter.shared.string(from: syncedAt)
        let resolvedStarredAt = starredAt ?? cachedAtISO

        return try await database.writer.write { db in
            var repo = Self.repoFromDTO(repoDTO, starredAt: resolvedStarredAt, cachedAt: cachedAtISO, isStarred: true)
            try repo.save(db)
            try GRDBRepoStarHistoryRepository.saveLocalSnapshot(
                repoId: repoDTO.id,
                starsCount: repoDTO.stargazersCount,
                observedAt: syncedAt,
                fetchedAt: syncedAt,
                db: db
            )

            var starred = StarredRepo(
                repoId: repoDTO.id,
                userId: userID,
                starredAt: resolvedStarredAt,
                syncStatus: "synced",
                lastSyncAt: cachedAtISO
            )
            try starred.save(db)

            AppLog.sync.info("Upserted starred repo \(repoDTO.id, privacy: .public) (\(repoDTO.fullName, privacy: .public))")
            return repo
        }
    }

    /// 外部来源 repo 写入 `repos`，但不写 `starred_repos`。
    ///
    /// 关键约束：
    /// - 新 repo 一律以 `is_starred = false` 落库，避免把私有入库误写成 GitHub Star。
    /// - 如果本地已经是 starred，则只刷新 metadata，不把 `is_starred/starred_at` 降级。
    /// - `library_state` 仍由 `RepoNoteRepository.updateLibraryState` 写入，两个语义分层。
    func upsertExternalRepoForLibrary(repoDTO: GitHubRepoDTO, syncedAt: Date) async throws -> Repo {
        let cachedAtISO = ISO8601DateFormatter.shared.string(from: syncedAt)

        return try await database.writer.write { db in
            var repo = Self.repoFromDTO(repoDTO, starredAt: nil, cachedAt: cachedAtISO, isStarred: false)
            if let existing = try Repo.fetchOne(db, key: repo.id), existing.isStarred {
                repo.isStarred = true
                repo.starredAt = existing.starredAt
            }
            try repo.save(db)
            try GRDBRepoStarHistoryRepository.saveLocalSnapshot(
                repoId: repo.id,
                starsCount: repo.starsCount,
                observedAt: syncedAt,
                fetchedAt: syncedAt,
                db: db
            )
            return repo
        }
    }

    func upsertRepoMetadataForLibrary(repo: Repo, syncedAt: Date) async throws -> Repo {
        let cachedAtISO = ISO8601DateFormatter.shared.string(from: syncedAt)

        return try await database.writer.write { db in
            let existing = try Repo.fetchOne(db, key: repo.id)
            var saved = repo
            // “加入知识库”只能保证本地 metadata 存在，不能把 repo 写成 GitHub starred。
            // 已有 starred 事实必须保留；没有历史行时一律按未 star 入库。
            saved.isStarred = existing?.isStarred == true
            saved.starredAt = existing?.isStarred == true ? existing?.starredAt : nil
            saved.cachedAt = cachedAtISO
            try saved.save(db)
            try GRDBRepoStarHistoryRepository.saveLocalSnapshot(
                repoId: saved.id,
                starsCount: saved.starsCount,
                observedAt: syncedAt,
                fetchedAt: syncedAt,
                db: db
            )
            return saved
        }
    }

    func updateAccessState(repoId: Int64, state: RepoAccessState, reason: String?, checkedAt: Date) async throws {
        let checkedAtISO = ISO8601DateFormatter.shared.string(from: checkedAt)
        try await database.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE repos
                    SET access_state = ?,
                        access_reason = ?,
                        access_checked_at = ?
                    WHERE id = ?
                    """,
                arguments: [state.rawValue, reason, checkedAtISO, repoId]
            )
        }
    }

    // MARK: - 查询

    /// 当前用户已 star 的 repo 总数（is_starred = 1）。
    func starredCount() async throws -> Int {
        try await database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM repos WHERE is_starred = 1") ?? 0
        }
    }

    /// 当前用户私有知识库 repo 总数。
    func knowledgeCount() async throws -> Int {
        try await database.writer.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*)
                FROM repos r
                JOIN repo_notes rn ON rn.repo_id = r.id
                WHERE rn.library_state = 'in_library'
                """) ?? 0
        }
    }

    /// 仅供测试 / 调试：取前 N 个已 star 的 repo。
    func topStarred(limit: Int = 10) async throws -> [Repo] {
        try await database.writer.read { db in
            try Repo.filter(Column("is_starred") == true)
                .order(Column("starred_at").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// 全部已 star 的 repo，按 starred_at 倒序。
    /// Week 3 Sidebar "All Stars" 入口使用。
    /// 列表渲染采用 SwiftUI List 懒加载，1801 条数据一次性返回也无压力；
    /// 后续 (>10k) 数据量时再考虑游标 / 分页。
    func fetchAllStarred() async throws -> [Repo] {
        try await database.writer.read { db in
            try Repo.filter(Column("is_starred") == true)
                .order(Column("starred_at").desc)
                .fetchAll(db)
        }
    }

    func fetchKnowledgeRepos() async throws -> [Repo] {
        try await database.writer.read { db in
            try Repo.fetchAll(db, sql: """
                SELECT r.*
                FROM repos r
                JOIN repo_notes rn ON rn.repo_id = r.id
                WHERE rn.library_state = 'in_library'
                ORDER BY rn.library_updated_at DESC, r.id DESC
                """)
        }
    }

    /// Activity 首屏快路径：只拉最近 N 条 starred，避免全表读挡 UI。
    func fetchRecentStarred(limit: Int) async throws -> [Repo] {
        let safeLimit = max(1, limit)
        return try await database.writer.read { db in
            try Repo.filter(Column("is_starred") == true)
                .order(Column("starred_at").desc)
                .limit(safeLimit)
                .fetchAll(db)
        }
    }

    /// HOM-47：按 GitHub repo id 找单条记录（含 is_starred=0 的"曾经 star 过"行）。
    func findById(_ repoId: Int64) async throws -> Repo? {
        try await database.writer.read { db in
            try Repo.fetchOne(db, key: repoId)
        }
    }

    /// 按 owner / name 找单条 repo 记录（2026-06-08 引入，Weekly 详情页用）。
    ///
    /// 用 `full_name` 列一次定位，效率比 `owner = ? AND name = ?` 复合过滤高；
    /// 调用方传入 owner / name 由本方法内部拼 `owner/name` 字符串，避免散落拼接出错。
    /// GitHub / 浏览器 URL 可能把 owner 规范化成小写（例如 JetBrains -> jetbrains），
    /// 这里必须大小写不敏感，否则 Browser Plugin / Weekly / Trending 的本地命中会误判为 nil。
    /// 不限制 `is_starred = true`：用户 star 后取消的"墓碑行"也会命中，调用方按 `repo.isStarred` 决定 UI。
    func findByOwnerName(owner: String, name: String) async throws -> Repo? {
        let fullName = "\(owner)/\(name)"
        return try await database.writer.read { db in
            try Repo.fetchOne(
                db,
                sql: "SELECT * FROM repos WHERE LOWER(full_name) = LOWER(?) LIMIT 1",
                arguments: [fullName]
            )
        }
    }

    /// 未打标签的 repo（Sidebar "Untagged" 入口）。
    /// 实现：左联 repo_tags 找出无关联记录的 repos。
    func fetchUntagged() async throws -> [Repo] {
        try await database.writer.read { db in
            try Repo.fetchAll(db, sql: """
                SELECT r.* FROM repos r
                LEFT JOIN repo_tags rt ON rt.repo_id = r.id
                WHERE r.is_starred = 1 AND rt.tag_id IS NULL
                ORDER BY r.starred_at DESC
                """)
        }
    }

    /// 按语言筛选 repo。
    /// - Parameter language: nil 表示无语言（GitHub 上的纯文本/配置仓库），传字符串表示精确匹配。
    func fetchByLanguage(_ language: String?) async throws -> [Repo] {
        try await database.writer.read { db in
            if let language {
                return try Repo
                    .filter(Column("is_starred") == true && Column("language") == language)
                    .order(Column("starred_at").desc)
                    .fetchAll(db)
            } else {
                return try Repo
                    .filter(Column("is_starred") == true && Column("language") == nil)
                    .order(Column("starred_at").desc)
                    .fetchAll(db)
            }
        }
    }

    /// 语言聚合统计，用于 Sidebar 的 Languages 分组展示。
    ///
    /// 排序：`未分类`（`language IS NULL` 或空串）固定排第 1 位，其余按 count 倒序 + 语言名升序。
    /// `GROUP BY` / `ORDER BY` 必须统一走 `COALESCE(language, '')`：只判 `language = ''`
    /// 时 NULL 组匹配不到，仍会按 count 排在 Java 等语言后面（dong4j 2026-06-26 复现）。
    func languageStats() async throws -> [LanguageStat] {
        try await database.writer.read { db in
            try LanguageStat.fetchAll(db, sql: """
                SELECT COALESCE(language, '') AS language, COUNT(*) AS count
                FROM repos
                WHERE is_starred = 1
                GROUP BY COALESCE(language, '')
                ORDER BY CASE WHEN COALESCE(language, '') = '' THEN 0 ELSE 1 END ASC,
                         count DESC,
                         language ASC
                """)
        }
    }

    func knowledgeLanguageStats() async throws -> [LanguageStat] {
        try await database.writer.read { db in
            try LanguageStat.fetchAll(db, sql: """
                SELECT COALESCE(r.language, '') AS language, COUNT(*) AS count
                FROM repos r
                JOIN repo_notes rn ON rn.repo_id = r.id AND rn.library_state = 'in_library'
                GROUP BY COALESCE(r.language, '')
                ORDER BY CASE WHEN COALESCE(r.language, '') = '' THEN 0 ELSE 1 END ASC,
                         count DESC,
                         language ASC
                """)
        }
    }

    /// FTS5 全文搜索（2026-06-14 召回扩展）。
    ///
    /// **索引列**：
    /// - `repos_fts`：`name / full_name / description / language / topics`
    /// - `notes_fts`：`repo_notes.content`（用户私有笔记）
    ///
    /// **合并策略**（Q2 方案 a "OR 合并"）：两表 UNION ALL 后按 `repo_id` 聚合取最佳 BM25，
    /// 同一 repo 多源命中只返回一条；用户感知"找到了"最重要，不在乎来源是 repo 字段还是笔记。
    ///
    /// **排序**（Q3 改进）：`ORDER BY MIN(bm25) ASC, starred_at DESC`。
    /// SQLite FTS5 的 `bm25()` 返回**负数**，越小（越负）越相关。`ASC` 把最负的（最相关）
    /// 排第一；BM25 同分时回落 `starred_at` 让新 star 在前。
    ///
    /// 空 query 直接退化为全量；用户输入由 caller 用 `FTSQuery.sanitize` 转义，避免 FTS5
    /// 语法错误（如 `"`、`*`、`-` 等元字符）。
    func searchFTS(query: String) async throws -> [Repo] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return try await fetchAllStarred()
        }
        let ftsQuery = FTSQuery.sanitize(trimmed)
        return try await database.writer.read { db in
            // 用 CTE 把 "repos_fts 命中" 与 "notes_fts 命中" 摊平到同一关系
            // (repo_id, score)；外层按 repo_id 聚合取 MIN(score) = 最相关的来源分数。
            // bm25() 必须在原始 fts5 表上下文里调用，所以两路命中各自带分进 CTE，
            // 不能在外层重新对 hits.score 做 bm25() 调用。
            try Repo.fetchAll(db, sql: """
                WITH hits(repo_id, score) AS (
                    SELECT rowid, bm25(repos_fts) FROM repos_fts WHERE repos_fts MATCH ?
                    UNION ALL
                    SELECT rowid, bm25(notes_fts) FROM notes_fts WHERE notes_fts MATCH ?
                )
                SELECT r.* FROM repos r
                JOIN (
                    SELECT repo_id, MIN(score) AS best_score
                    FROM hits
                    GROUP BY repo_id
                ) m ON r.id = m.repo_id
                WHERE r.is_starred = 1
                ORDER BY m.best_score ASC, r.starred_at DESC
            """, arguments: [ftsQuery, ftsQuery])
        }
    }

    func searchKnowledgeFTS(query: String) async throws -> [Repo] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return try await fetchKnowledgeRepos()
        }
        let ftsQuery = FTSQuery.sanitize(trimmed)
        return try await database.writer.read { db in
            try Repo.fetchAll(db, sql: """
                WITH hits(repo_id, score) AS (
                    SELECT rowid, bm25(repos_fts) FROM repos_fts WHERE repos_fts MATCH ?
                    UNION ALL
                    SELECT rowid, bm25(notes_fts) FROM notes_fts WHERE notes_fts MATCH ?
                )
                SELECT r.* FROM repos r
                JOIN repo_notes rn ON rn.repo_id = r.id
                JOIN (
                    SELECT repo_id, MIN(score) AS best_score
                    FROM hits
                    GROUP BY repo_id
                ) m ON r.id = m.repo_id
                WHERE rn.library_state = 'in_library'
                ORDER BY m.best_score ASC,
                         rn.library_updated_at DESC,
                         r.id DESC
                """, arguments: [ftsQuery, ftsQuery])
        }
    }

    /// Manage 大数据量分页查询。
    ///
    /// 关键约束：列表主路径只取下一页需要的行，不再把所有 starred repo 拉到
    /// `HomeViewModel` 后做内存分页。调用方会传 `pageSize + 1`，多出来的一行
    /// 用于判断 `hasMore`，不会进入 UI。`offset` 是已经展示的行数，避免滚到底时
    /// 反复重查累计前 N 条导致 SwiftUI 大数组 diff 掉帧。
    func fetchListPage(
        scope: RepoListScope,
        filters: RepoListFilters,
        sort: RepoSortOption,
        limit: Int,
        offset: Int
    ) async throws -> [Repo] {
        let safeLimit = max(1, limit)
        let safeOffset = max(0, offset)
        let query = Self.makeListQuery(
            projection: "r.*",
            scope: scope,
            filters: filters,
            sort: sort,
            limit: safeLimit,
            offset: safeOffset
        )
        return try await database.writer.read { db in
            try Repo.fetchAll(db, sql: query.sql, arguments: query.arguments)
        }
    }

    /// 当前 Manage 查询下的真实总数。
    ///
    /// 只做 `COUNT(*)`，不实例化 repo 行；用于分页列表的标题/副标题展示。
    func fetchListCount(
        scope: RepoListScope,
        filters: RepoListFilters
    ) async throws -> Int {
        let query = Self.makeListQuery(
            projection: "COUNT(*)",
            scope: scope,
            filters: filters,
            sort: .starredAtDesc,
            limit: nil,
            offset: nil,
            includeOrderBy: false
        )
        return try await database.writer.read { db in
            try Int.fetchOne(db, sql: query.sql, arguments: query.arguments) ?? 0
        }
    }

    /// 当前 Manage 查询下的全部 repo id。
    ///
    /// 只投影 `r.id`，服务 Cmd+A 这类全集语义；避免重新加载完整 repo 行。
    func fetchListIDs(
        scope: RepoListScope,
        filters: RepoListFilters,
        sort: RepoSortOption
    ) async throws -> [Int64] {
        let query = Self.makeListQuery(
            projection: "r.id",
            scope: scope,
            filters: filters,
            sort: sort,
            limit: nil,
            offset: nil
        )
        return try await database.writer.read { db in
            try Int64.fetchAll(db, sql: query.sql, arguments: query.arguments)
        }
    }

    /// 当前 Manage 查询下的全部多选快照。
    ///
    /// Cmd+A 需要保持“当前筛选全集”语义，但批量操作只需要 id/owner/name。这里用
    /// Row projection 避免实例化完整 `Repo`，数据量 10k+ 时内存和解码成本都更可控。
    func fetchListSelectionSnapshots(
        scope: RepoListScope,
        filters: RepoListFilters,
        sort: RepoSortOption
    ) async throws -> [SelectionSnapshot] {
        let query = Self.makeListQuery(
            projection: "r.id AS id, r.owner AS owner, r.name AS name",
            scope: scope,
            filters: filters,
            sort: sort,
            limit: nil,
            offset: nil
        )
        return try await database.writer.read { db in
            let rows = try Row.fetchAll(db, sql: query.sql, arguments: query.arguments)
            return rows.map { row in
                SelectionSnapshot(
                    ghRepoId: row["id"],
                    owner: row["owner"],
                    name: row["name"]
                )
            }
        }
    }

    // MARK: - Manage Repo Pin

    /// 读取全部 Pin 很轻量：表中只保存用户主动置顶的少量 repo，不随 stars 总量线性膨胀。
    func fetchPinnedRepoTimestamps() async throws -> [Int64: TimeInterval] {
        try await database.writer.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT repo_id, pinned_at FROM repo_pins")
            return Dictionary(uniqueKeysWithValues: rows.map { row in
                (row["repo_id"] as Int64, row["pinned_at"] as TimeInterval)
            })
        }
    }

    /// Pin 属于用户整理状态，取消时只删关系行，不触碰 repo 元数据、标签或笔记。
    func setPinned(repoId: Int64, pinnedAt: Date?) async throws {
        try await database.writer.write { db in
            if let pinnedAt {
                try db.execute(
                    sql: """
                    INSERT INTO repo_pins (repo_id, pinned_at)
                    VALUES (?, ?)
                    ON CONFLICT(repo_id) DO UPDATE SET pinned_at = excluded.pinned_at
                    """,
                    arguments: [repoId, pinnedAt.timeIntervalSince1970]
                )
            } else {
                try db.execute(
                    sql: "DELETE FROM repo_pins WHERE repo_id = ?",
                    arguments: [repoId]
                )
            }
        }
    }

    private static func makeListQuery(
        projection: String,
        scope: RepoListScope,
        filters: RepoListFilters,
        sort: RepoSortOption,
        limit: Int?,
        offset: Int?,
        includeOrderBy: Bool = true
    ) -> (sql: String, arguments: StatementArguments) {
        var joins: [String] = []
        var whereClauses: [String] = []
        var args: [any DatabaseValueConvertible] = []

        switch scope {
        case .myProjects(let userID):
            joins.append(
                "JOIN user_projects up_scope ON up_scope.repo_id = r.id AND up_scope.user_id = ?"
            )
            args.append(userID)
            // 保证没有额外筛选时 WHERE 仍有合法谓词；项目成员关系已经由 JOIN 收窄。
            whereClauses.append("1 = 1")
        case .allStars:
            whereClauses.append("r.is_starred = 1")
        case .library:
            joins.append("JOIN repo_notes rn_scope ON rn_scope.repo_id = r.id AND rn_scope.library_state = 'in_library'")
            whereClauses.append("1 = 1")
        case .untagged:
            whereClauses.append("r.is_starred = 1")
            whereClauses.append("""
                NOT EXISTS (
                    SELECT 1 FROM repo_tags rt_scope
                    WHERE rt_scope.repo_id = r.id
                )
                """)
        case .language(let language):
            whereClauses.append("r.is_starred = 1")
            if let language {
                whereClauses.append("r.language = ?")
                args.append(language)
            } else {
                whereClauses.append("r.language IS NULL")
            }
        case .tag(let tagID):
            whereClauses.append("r.is_starred = 1")
            whereClauses.append("""
                EXISTS (
                    SELECT 1 FROM repo_tags rt_scope
                    WHERE rt_scope.repo_id = r.id AND rt_scope.tag_id = ?
                )
            """)
            args.append(tagID)
        case .githubStarList(let listID):
            whereClauses.append("r.is_starred = 1")
            whereClauses.append("""
                EXISTS (
                    SELECT 1 FROM repo_github_star_lists rgl_scope
                    WHERE rgl_scope.repo_id = r.id AND rgl_scope.list_id = ?
                )
            """)
            args.append(listID)
        case .githubStarListUngrouped:
            whereClauses.append("r.is_starred = 1")
            whereClauses.append("""
                NOT EXISTS (
                    SELECT 1 FROM repo_github_star_lists rgl_scope
                    WHERE rgl_scope.repo_id = r.id
                )
                """)
        }

        switch filters.star {
        case .all:
            break
        case .starred:
            whereClauses.append("r.is_starred = 1")
        case .unstarred:
            whereClauses.append("r.is_starred = 0")
        }

        if filters.hideArchived {
            whereClauses.append("r.is_archived = 0")
        }
        if filters.hideForks {
            whereClauses.append("r.is_fork = 0")
        }
        if let language = filters.language.queryLanguage {
            if let language {
                whereClauses.append("r.language = ?")
                args.append(language)
            } else {
                whereClauses.append("r.language IS NULL")
            }
        }
        if !filters.selectedLanguages.isEmpty {
            let placeholders = Array(repeating: "?", count: filters.selectedLanguages.count).joined(separator: ", ")
            whereClauses.append("r.language IN (\(placeholders))")
            args.append(contentsOf: filters.selectedLanguages.sorted())
        }
        if let status = filters.status {
            if status == .unread {
                whereClauses.append("""
                    COALESCE((
                        SELECT rn.status FROM repo_notes rn
                        WHERE rn.repo_id = r.id
                    ), 'unread') = ?
                    """)
            } else {
                whereClauses.append("""
                    EXISTS (
                        SELECT 1 FROM repo_notes rn
                        WHERE rn.repo_id = r.id AND rn.status = ?
                    )
                    """)
            }
            args.append(status.rawValue)
        }
        switch filters.library {
        case .all:
            break
        case .inLibrary:
            whereClauses.append("""
                EXISTS (
                    SELECT 1 FROM repo_notes rn_library
                    WHERE rn_library.repo_id = r.id
                      AND rn_library.library_state = 'in_library'
                )
                """)
        case .outsideLibrary:
            whereClauses.append("""
                NOT EXISTS (
                    SELECT 1 FROM repo_notes rn_library
                    WHERE rn_library.repo_id = r.id
                      AND rn_library.library_state = 'in_library'
                )
                """)
        }
        switch filters.healthAvailability {
        case .unknown:
            break
        case .available:
            whereClauses.append("""
                EXISTS (
                    SELECT 1 FROM repo_health_snapshots h_filter
                    WHERE h_filter.repo_id = r.id
                      AND h_filter.fetch_status != 'failed'
                )
                """)
        case .missing:
            whereClauses.append("""
                NOT EXISTS (
                    SELECT 1 FROM repo_health_snapshots h_filter
                    WHERE h_filter.repo_id = r.id
                      AND h_filter.fetch_status != 'failed'
                )
                """)
        }
        switch filters.openSSFAvailability {
        case .unknown:
            break
        case .available:
            whereClauses.append("""
                EXISTS (
                    SELECT 1 FROM open_ssf_scores ossf_filter
                    WHERE ossf_filter.repo_id = r.id
                      AND ossf_filter.fetch_status = 'success'
                      AND ossf_filter.aggregate_score IS NOT NULL
                )
                """)
        case .missing:
            whereClauses.append("""
                NOT EXISTS (
                    SELECT 1 FROM open_ssf_scores ossf_filter
                    WHERE ossf_filter.repo_id = r.id
                      AND ossf_filter.fetch_status = 'success'
                      AND ossf_filter.aggregate_score IS NOT NULL
                )
                """)
        }
        switch filters.tagAvailability {
        case .unknown:
            break
        case .available:
            whereClauses.append("""
                EXISTS (
                    SELECT 1 FROM repo_tags rt_insights
                    WHERE rt_insights.repo_id = r.id
                )
                """)
        case .missing:
            whereClauses.append("""
                NOT EXISTS (
                    SELECT 1 FROM repo_tags rt_insights
                    WHERE rt_insights.repo_id = r.id
                )
                """)
        }
        switch filters.readmeAvailability {
        case .unknown:
            break
        case .available:
            whereClauses.append("""
                EXISTS (
                    SELECT 1 FROM rag_chunks c_readme
                    WHERE c_readme.repo_id = r.id AND c_readme.source = 'readme'
                )
                """)
        case .missing:
            whereClauses.append("""
                NOT EXISTS (
                    SELECT 1 FROM rag_chunks c_readme
                    WHERE c_readme.repo_id = r.id AND c_readme.source = 'readme'
                )
                """)
        }
        switch filters.indexableSourceAvailability {
        case .unknown:
            break
        case .available:
            whereClauses.append("""
                EXISTS (
                    SELECT 1 FROM rag_chunks c_indexable
                    WHERE c_indexable.repo_id = r.id
                      AND NOT EXISTS (
                          SELECT 1 FROM rag_chunk_overrides o_indexable
                          WHERE o_indexable.chunk_id = c_indexable.id
                            AND o_indexable.is_excluded = 1
                      )
                )
                """)
        case .missing:
            whereClauses.append("""
                NOT EXISTS (
                    SELECT 1 FROM rag_chunks c_indexable
                    WHERE c_indexable.repo_id = r.id
                      AND NOT EXISTS (
                          SELECT 1 FROM rag_chunk_overrides o_indexable
                          WHERE o_indexable.chunk_id = c_indexable.id
                            AND o_indexable.is_excluded = 1
                      )
                )
                """)
        }
        switch filters.ragIndexState {
        case .unknown:
            break
        case .issues(let embeddingModel):
            whereClauses.append("""
                EXISTS (
                    SELECT 1 FROM rag_chunks c_rag
                    WHERE c_rag.repo_id = r.id
                      AND NOT EXISTS (
                          SELECT 1 FROM rag_chunk_overrides o_rag
                          WHERE o_rag.chunk_id = c_rag.id
                            AND o_rag.is_excluded = 1
                      )
                      AND (
                          c_rag.embedding_status IN ('failed', 'stale')
                          OR (
                              c_rag.embedding_status = 'ready'
                              AND c_rag.embedding_model IS NOT NULL
                              AND c_rag.embedding_model != ?
                          )
                      )
                )
                """)
            args.append(embeddingModel)
        }
        switch filters.insightsRisk {
        case .unknown:
            break
        case .maintenance:
            whereClauses.append("""
                EXISTS (
                    SELECT 1 FROM repo_health_snapshots h_risk
                    WHERE h_risk.repo_id = r.id
                      AND h_risk.fetch_status != 'failed'
                      AND h_risk.maintenance_score < 50
                )
                """)
        case .security:
            whereClauses.append("""
                EXISTS (
                    SELECT 1 FROM open_ssf_scores ossf_risk
                    WHERE ossf_risk.repo_id = r.id
                      AND ossf_risk.fetch_status = 'success'
                      AND ossf_risk.aggregate_score IS NOT NULL
                      AND ossf_risk.aggregate_score < 5
                )
                """)
        }
        if !filters.selectedTagIDs.isEmpty {
            let tagIDs = Array(filters.selectedTagIDs).sorted()
            let placeholders = Array(repeating: "?", count: tagIDs.count).joined(separator: ", ")
            whereClauses.append("""
                EXISTS (
                    SELECT 1 FROM repo_tags rt_filter
                    WHERE rt_filter.repo_id = r.id
                      AND rt_filter.tag_id IN (\(placeholders))
                )
                """)
            args.append(contentsOf: tagIDs)
        }

        if sort == .healthScoreDesc {
            joins.append("LEFT JOIN repo_health_snapshots h_sort ON h_sort.repo_id = r.id")
        } else if sort == .openSSFScoreDesc {
            joins.append("LEFT JOIN open_ssf_scores ossf_sort ON ossf_sort.repo_id = r.id AND ossf_sort.fetch_status = 'success'")
        } else if sort == .libraryUpdatedAtDesc, scope != .library {
            // 知识库 scope 已 JOIN rn_scope；其它 scope 单独左连，避免未入库仓库丢行。
            joins.append("LEFT JOIN repo_notes rn_library_sort ON rn_library_sort.repo_id = r.id")
        }

        // Pin 只改变排序，不改变分类成员关系。COUNT 查询不需要这张表，避免无意义 JOIN；
        // 分页、Cmd+A ID 和多选快照都走 includeOrderBy=true，因此会共享完全一致的顺序。
        if includeOrderBy {
            joins.append("LEFT JOIN repo_pins rp_sort ON rp_sort.repo_id = r.id")
        }

        let orderBy: String
        switch sort {
        case .starredAtDesc:
            // 「默认」始终表示最近 star；知识库默认改走 libraryUpdatedAtDesc。
            orderBy = "r.starred_at DESC, r.id DESC"
        case .starredAtAsc:
            orderBy = "r.starred_at IS NULL ASC, r.starred_at ASC, r.id ASC"
        case .libraryUpdatedAtDesc:
            if scope == .library {
                orderBy = "rn_scope.library_updated_at DESC, r.id DESC"
            } else {
                orderBy = "rn_library_sort.library_updated_at IS NULL ASC, rn_library_sort.library_updated_at DESC, r.id DESC"
            }
        case .nameAsc:
            orderBy = "LOWER(r.full_name) ASC, r.id ASC"
        case .nameDesc:
            orderBy = "LOWER(r.full_name) DESC, r.id DESC"
        case .starsDesc:
            orderBy = "r.stars_count DESC, r.id DESC"
        case .starsAsc:
            orderBy = "r.stars_count ASC, r.id ASC"
        case .updatedDesc:
            orderBy = "r.pushed_at DESC, r.id DESC"
        case .updatedAsc:
            orderBy = "r.pushed_at IS NULL ASC, r.pushed_at ASC, r.id ASC"
        case .createdDesc:
            orderBy = "r.created_at DESC, r.id DESC"
        case .createdAsc:
            orderBy = "r.created_at IS NULL ASC, r.created_at ASC, r.id ASC"
        case .healthScoreDesc:
            orderBy = "h_sort.repo_id IS NULL ASC, h_sort.overall_score DESC, r.starred_at DESC, r.id DESC"
        case .openSSFScoreDesc:
            orderBy = "ossf_sort.aggregate_score IS NULL ASC, ossf_sort.aggregate_score DESC, r.starred_at DESC, r.id DESC"
        }

        var sql = """
            SELECT \(projection)
            FROM repos r
            \(joins.joined(separator: "\n"))
            WHERE \(whereClauses.joined(separator: "\nAND "))
            """
        if includeOrderBy {
            // 多个 Pin 按最近置顶时间排序；未 Pin 的仓库继续严格遵守用户当前排序选项。
            sql += "\nORDER BY rp_sort.pinned_at IS NULL ASC, rp_sort.pinned_at DESC, \(orderBy)"
        }
        if let limit {
            sql += "\nLIMIT ?"
            args.append(limit)
        }
        if let offset {
            sql += "\nOFFSET ?"
            args.append(offset)
        }
        return (sql, StatementArguments(args))
    }

    // MARK: - 同步状态

    /// 更新 sync_state 表中当前用户的统计。
    ///
    /// 注意：保留已有的 `stars_etag`（W4-4 C2）— 用 `update` 局部更新，避免 `save` 覆盖
    /// `nil` 把 ETag 抹掉。
    func updateSyncState(userID: Int64, starredCount: Int, syncedCount: Int, status: String) async throws {
        let nowISO = ISO8601DateFormatter.shared.string(from: Date())
        try await database.writer.write { db in
            let existing = try SyncStateRecord.fetchOne(db, key: userID)
            var state = SyncStateRecord(
                userId: userID,
                lastSyncAt: nowISO,
                lastIncrementalAt: existing?.lastIncrementalAt,
                starredCount: starredCount,
                syncedCount: syncedCount,
                failedCount: 0,
                syncStatus: status,
                errorMessage: nil,
                starsEtag: existing?.starsEtag
            )
            try state.save(db)
        }
    }

    // MARK: - W4-4 C2：Stars ETag 读写

    /// 读 page 1 ETag。
    /// 无 sync_state 行或字段为 NULL → 返回 nil（首次同步无条件请求）。
    func fetchStarsETag(userID: Int64) async throws -> String? {
        try await database.writer.read { db in
            try SyncStateRecord.fetchOne(db, key: userID)?.starsEtag
        }
    }

    /// W4-4 C3：读 `last_sync_at`，供增量同步做 `starred_at` 切分点。
    func fetchLastSyncAt(userID: Int64) async throws -> String? {
        try await database.writer.read { db in
            try SyncStateRecord.fetchOne(db, key: userID)?.lastSyncAt
        }
    }

    /// 写 page 1 ETag。
    /// 若 sync_state 行不存在 → 用占位字段先插一行（其余统计字段后续会被 updateSyncState 覆写）。
    func updateStarsETag(userID: Int64, etag: String?) async throws {
        try await database.writer.write { db in
            if var existing = try SyncStateRecord.fetchOne(db, key: userID) {
                existing.starsEtag = etag
                try existing.update(db)
            } else {
                var state = SyncStateRecord(
                    userId: userID,
                    lastSyncAt: nil,
                    lastIncrementalAt: nil,
                    starredCount: 0,
                    syncedCount: 0,
                    failedCount: 0,
                    syncStatus: "idle",
                    errorMessage: nil,
                    starsEtag: etag
                )
                try state.insert(db)
            }
        }
    }

    // MARK: - DTO → Model 映射

    /// 把 GitHubRepoDTO 映射为本地 Repo 模型（**不入库** / 入库通用 builder）。
    ///
    /// ⚠️ 2026-06-08 起函数语义扩展：
    /// 旧版（HOM-47 之前）仅用于"starred 同步入库"路径，调用方一定走 `upsertStarred`，所以
    /// `isStarred` 写死为 `true`。
    /// 新增 `isStarred: Bool = true` 可选参数：Weekly 详情页（D-21 候选）需要把 `repo(owner:repo:)`
    /// 拉回的 DTO 转成一个"用于 UI 展示但不入库"的临时 `Repo`——这种场景 `isStarred=false`、
    /// `starredAt=nil`，避免误造成"已 star"的视觉假象。
    /// 默认 `true` 让旧调用点（`upsertStarred`）完全不动；新场景显式传 `false`。
    ///
    /// topics 数组序列化为 JSON 字符串（与 GRDB 行映射保持一致；UI 侧 `Repo.topicsArray` 反序列化）。
    static func repoFromDTO(_ dto: GitHubRepoDTO, starredAt: String?, cachedAt: String, isStarred: Bool = true) -> Repo {
        let topicsJSON: String? = {
            guard let topics = dto.topics, !topics.isEmpty else { return nil }
            guard let data = try? JSONEncoder().encode(topics),
                  let str = String(data: data, encoding: .utf8) else {
                return nil
            }
            return str
        }()

        return Repo(
            id: dto.id,
            owner: dto.owner.login,
            name: dto.name,
            fullName: dto.fullName,
            description: dto.description,
            language: dto.language,
            starsCount: dto.stargazersCount,
            forksCount: dto.forksCount,
            watchersCount: dto.watchersCount,
            topics: topicsJSON,
            license: dto.license?.spdxId ?? dto.license?.name,
            homepage: dto.homepage,
            htmlUrl: dto.htmlUrl,
            cloneUrl: dto.cloneUrl,
            sshUrl: dto.sshUrl,
            isPrivate: dto.isPrivate,
            isFork: dto.fork,
            isArchived: dto.archived,
            isStarred: isStarred,
            pushedAt: dto.pushedAt,
            createdAt: dto.createdAt,
            updatedAt: dto.updatedAt,
            starredAt: starredAt,
            cachedAt: cachedAt,
            // SEARCH-RICH 2026-06-14：接通 3 个零额外网络成本的字段。
            // - `ownerAvatar` 来自 `dto.owner.avatarUrl`，stars 同步嵌套 owner 也带；
            //   过去 mapper 没传 → `repos.owner_avatar` 列对所有同步入库的 repo 都是 NULL，
            //   逼着搜索弹窗 / 详情页只能用 `https://github.com/{login}.png` 拼凑。
            //   现在搭车每次同步自然回填，不增加任何 API 调用。
            // - `subscribersCount` 仅 `/repos/{owner}/{name}` 端点返回，stars / search
            //   嵌套 repo 都不含 → 保持 nil（保留为 Optional 字段供后续 D-21 之类的
            //   懒加载场景填）。
            // - `defaultBranch` / `openIssuesCount`：DTO 已扩，搭车回填。
            ownerAvatar: dto.owner.avatarUrl,
            subscribersCount: nil,
            defaultBranch: dto.defaultBranch,
            openIssuesCount: dto.openIssuesCount
        )
    }
}

// MARK: - Sendable

/// `Sendable` conformance 必须与 `GRDBRepoRepository` 定义同文件（Swift 6 严格模式约束，
/// 跨文件 conformance 会触发 "conformance to 'Sendable' must occur in the same source
/// file" 警告）。所以即便 `RepoRepositoryProtocol`（继承 `Sendable`）的实现声明保留在
/// `RepoRepositoryProtocol.swift`（D-01 决策），`Sendable` 这一条仍要单独在这里声明。
///
/// 安全性：本 struct 唯一存储属性 `database: any DatabaseManaging` —— `DatabaseManaging`
/// 协议本身 `: Sendable`，所以编译器可自动合成 Sendable（不需要 `@unchecked`）。
extension GRDBRepoRepository: Sendable {}

// MARK: - ISO8601 helper

extension ISO8601DateFormatter {
    /// 兼容既有 `.shared` 调用点的工厂属性。
    ///
    /// 注意：这里故意不是 stored singleton。`ISO8601DateFormatter` 是可变引用类型，
    /// Swift 6 不允许把它作为全局共享状态暴露。保留 `.shared` 名称是为了控制迁移 diff，
    /// 但每次访问都会创建独立实例，从根上避免跨线程共享 formatter。
    static var shared: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    /// 解析 GitHub REST 返回的 ISO8601 时间字符串。
    ///
    /// Swift 6 下 `ISO8601DateFormatter` 不能作为全局 shared 暴露：它是可变引用类型，
    /// 编译器无法证明跨线程共享安全。这里改为函数内局部 formatter，避免为一个轻量
    /// helper 引入锁或 `@unchecked Sendable`。双 try:先 fractional,再纯 internet date time。
    static func githubDate(from raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: raw)
    }
}
