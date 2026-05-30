//
//  RepoRepository.swift
//  Starcat
//
//  Repo 持久化 Repository。
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

/// Repo Repository。
struct RepoRepository {

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

    // MARK: - 同步状态

    /// 更新 sync_state 表中当前用户的统计。
    func updateSyncState(userID: Int64, starredCount: Int, syncedCount: Int, status: String) async throws {
        let nowISO = ISO8601DateFormatter.shared.string(from: Date())
        try await writer.write { db in
            var state = SyncStateRecord(
                userId: userID,
                lastSyncAt: nowISO,
                lastIncrementalAt: nil,
                starredCount: starredCount,
                syncedCount: syncedCount,
                failedCount: 0,
                syncStatus: status,
                errorMessage: nil
            )
            try state.save(db)
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
