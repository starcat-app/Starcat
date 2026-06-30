//
//  ReadmePrefetchRepository.swift
//  Starcat
//
//  README 后台预拉 Repository。
//
//  模块级说明：
//  - 负责从 SQLite 中挑选需要预拉的 starred repo；
//  - 负责持久化 `readme_prefetch_states` 的调度状态；
//  - 不发网络、不处理 UI 状态，保持与 `ReadmePrefetchService` 分层。
//

import Foundation
import GRDB

/// README 后台预拉持久化层。
struct ReadmePrefetchRepository: Sendable {

    private let database: any DatabaseManaging

    init(database: any DatabaseManaging) {
        self.database = database
    }

    /// 取一批当前应处理的 starred repo。
    ///
    /// 排序策略：
    /// 1. 缺 HTML 的 repo 最优先，因为详情页秒开依赖它；
    /// 2. 已有 HTML 但缺 Markdown 的 repo 次之；
    /// 3. HTML 超过 soft TTL 的 repo 最后做条件刷新；
    /// 4. 同级按最近 star 优先，符合用户近期打开概率更高的直觉。
    func fetchCandidates(now: Date, htmlStaleBefore: Date, limit: Int) async throws -> [Repo] {
        let nowISO = ISO8601DateFormatter.shared.string(from: now)
        let staleISO = ISO8601DateFormatter.shared.string(from: htmlStaleBefore)
        let safeLimit = max(1, limit)

        return try await database.writer.read { db in
            try Repo.fetchAll(
                db,
                sql: """
                SELECT r.*
                FROM repos r
                LEFT JOIN readmes rm ON rm.repo_id = r.id
                LEFT JOIN readme_contents rc ON rc.repo_id = r.id
                LEFT JOIN readme_prefetch_states ps ON ps.repo_id = r.id
                WHERE r.is_starred = 1
                  AND (ps.next_retry_at IS NULL OR ps.next_retry_at <= ?)
                  AND (
                        rm.repo_id IS NULL
                     OR rc.repo_id IS NULL
                     OR rm.cached_at <= ?
                  )
                ORDER BY
                  CASE WHEN rm.repo_id IS NULL THEN 0 ELSE 1 END,
                  CASE WHEN rc.repo_id IS NULL THEN 0 ELSE 1 END,
                  rm.cached_at ASC,
                  r.starred_at DESC
                LIMIT ?
                """,
                arguments: [nowISO, staleISO, safeLimit]
            )
        }
    }

    /// 读取单仓库预拉状态。测试和状态面板细节排查使用。
    func state(repoId: Int64) async throws -> ReadmePrefetchStateRecord? {
        try await database.writer.read { db in
            try ReadmePrefetchStateRecord.fetchOne(db, key: repoId)
        }
    }

    /// 写入单仓库预拉结果。
    ///
    /// 成功时清掉 `next_retry_at`，失败时由 service 传入退避后的时间。这里不自己计算退避，
    /// 是为了让网络错误、404、rate limit 能在业务层按不同规则处理。
    func upsert(_ record: ReadmePrefetchStateRecord) async throws {
        try await database.writer.write { db in
            var copy = record
            try copy.upsert(db)
        }
    }
}
