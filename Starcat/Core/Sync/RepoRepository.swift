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

    /// 渲染用：空语言显示为本地化的 Unknown，真实语言名按 GitHub 返回值原样显示。
    var displayName: String { language.isEmpty ? String(localized: "sidebar.unknownLanguage") : language }

    /// 实际语言筛选用：空串对应数据库里 NULL（fetchByLanguage(nil)）。
    var languageOrNil: String? { language.isEmpty ? nil : language }
}

/// Repo Repository（GRDB 实现）。D-01：原名 `RepoRepository`，改名 `GRDBRepoRepository`，
/// 协议抽象 `RepoRepositoryProtocol` 见同目录另一文件。
struct GRDBRepoRepository {

    /// GRDB writer。
    private let writer: any DatabaseWriter

    init(database: any DatabaseManaging) {
        self.writer = database.writer
    }

    // MARK: - Upsert

    /// 批量 upsert 一组 starred repos。
    /// 同时维护 starred_repos 表（user-repo 关系 + starred_at）。
    /// 整批写入在一个事务里，保证原子性。
    func upsertStarred(_ dtos: [StarredRepoDTO], userID: Int64, syncedAt: Date) async throws {
        guard !dtos.isEmpty else { return }
        let cachedAtISO = ISO8601DateFormatter.shared.string(from: syncedAt)

        try await writer.write { db in
            for dto in dtos {
                var repo = Self.repoFromDTO(dto.repo, starredAt: dto.starredAt, cachedAt: cachedAtISO)
                try repo.save(db)

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
        try await writer.write { db in
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
        try await writer.write { db in
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

    // MARK: - 查询

    /// 当前用户已 star 的 repo 总数（is_starred = 1）。
    func starredCount() async throws -> Int {
        try await writer.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM repos WHERE is_starred = 1") ?? 0
        }
    }

    /// 仅供测试 / 调试：取前 N 个已 star 的 repo。
    func topStarred(limit: Int = 10) async throws -> [Repo] {
        try await writer.read { db in
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
        try await writer.read { db in
            try Repo.filter(Column("is_starred") == true)
                .order(Column("starred_at").desc)
                .fetchAll(db)
        }
    }

    /// 未打标签的 repo（Sidebar "Untagged" 入口）。
    /// 实现：左联 repo_tags 找出无关联记录的 repos。
    func fetchUntagged() async throws -> [Repo] {
        try await writer.read { db in
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
        try await writer.read { db in
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

    /// 语言聚合统计，按 count 倒序。
    /// 用于 Sidebar 的 Languages 分组展示。
    /// `language IS NULL` 的 repo 也单独统计为一项（caller 用 `("Unknown", count)` 渲染）。
    func languageStats() async throws -> [LanguageStat] {
        try await writer.read { db in
            try LanguageStat.fetchAll(db, sql: """
                SELECT COALESCE(language, '') AS language, COUNT(*) AS count
                FROM repos
                WHERE is_starred = 1
                GROUP BY language
                ORDER BY count DESC, language ASC
                """)
        }
    }

    /// FTS5 全文搜索。
    /// 在 `name / description / language / topics` 四列上搜索；空 query 直接退化为全量。
    /// 用户输入由 caller 用 `FTSQuery.sanitize` 转义，避免 FTS5 语法错误（如 `"`、`*`、`-` 等元字符）。
    func searchFTS(query: String) async throws -> [Repo] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return try await fetchAllStarred()
        }
        let ftsQuery = FTSQuery.sanitize(trimmed)
        return try await writer.read { db in
            try Repo.fetchAll(db, sql: """
                SELECT r.* FROM repos r
                JOIN repos_fts ON repos_fts.rowid = r.id
                WHERE repos_fts MATCH ? AND r.is_starred = 1
                ORDER BY r.starred_at DESC
                """, arguments: [ftsQuery])
        }
    }

    // MARK: - 同步状态

    /// 更新 sync_state 表中当前用户的统计。
    ///
    /// 注意：保留已有的 `stars_etag`（W4-4 C2）— 用 `update` 局部更新，避免 `save` 覆盖
    /// `nil` 把 ETag 抹掉。
    func updateSyncState(userID: Int64, starredCount: Int, syncedCount: Int, status: String) async throws {
        let nowISO = ISO8601DateFormatter.shared.string(from: Date())
        try await writer.write { db in
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
        try await writer.read { db in
            try SyncStateRecord.fetchOne(db, key: userID)?.starsEtag
        }
    }

    /// W4-4 C3：读 `last_sync_at`，供增量同步做 `starred_at` 切分点。
    func fetchLastSyncAt(userID: Int64) async throws -> String? {
        try await writer.read { db in
            try SyncStateRecord.fetchOne(db, key: userID)?.lastSyncAt
        }
    }

    /// 写 page 1 ETag。
    /// 若 sync_state 行不存在 → 用占位字段先插一行（其余统计字段后续会被 updateSyncState 覆写）。
    func updateStarsETag(userID: Int64, etag: String?) async throws {
        try await writer.write { db in
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

    /// 把 GitHubRepoDTO 映射为本地 Repo 模型。
    /// topics 数组序列化为 JSON 字符串入库。
    static func repoFromDTO(_ dto: GitHubRepoDTO, starredAt: String?, cachedAt: String) -> Repo {
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
            isStarred: true,
            pushedAt: dto.pushedAt,
            createdAt: dto.createdAt,
            updatedAt: dto.updatedAt,
            starredAt: starredAt,
            cachedAt: cachedAt
        )
    }
}

// MARK: - ISO8601 helper

extension ISO8601DateFormatter {
    /// 共享实例，线程安全。
    static let shared: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
