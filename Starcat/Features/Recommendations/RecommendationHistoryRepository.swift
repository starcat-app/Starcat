//
//  RecommendationHistoryRepository.swift
//  Starcat
//
//  账号内的长期推荐事实与负反馈。与可清理的 repo 缓存解耦，旧 JSON 只导入一次。
//

import Foundation
import GRDB

/// 保存推荐当时的公开快照；缺资料的旧 ID 仍然是有效历史，不能从去重集合中消失。
struct RecommendationHistoryEntry: Identifiable, Sendable, Equatable {
    let id: Int64
    let item: RepoRecommendationItem?
    let recommendedAt: Date?
    let recommendedDay: String?
    let batchID: String?
    let isDismissed: Bool

    /// 已 Star 是外部真值，不能把浏览/跳过或取消 Star 推断为负反馈。
    func feedback(starredIDs: Set<Int64>) -> RecommendationHistoryFilter {
        if starredIDs.contains(id) { return .starred }
        return isDismissed ? .dismissed : .unanswered
    }
}

/// 历史页筛选与反馈使用同一组语义；“全部”仅作为查询条件。
enum RecommendationHistoryFilter: String, CaseIterable, Identifiable, Sendable {
    case all, starred, unanswered, dismissed
    var id: String { rawValue }
    var titleKey: String { "recommendations.history.\(rawValue)" }
}

/// 每次操作绑定当时的账号 writer，禁止在 await 后重新取新账号的数据库再写入旧请求。
/// 不长期缓存 writer；切账号后下一次操作必须走 DatabaseManaging 的最新实例。
struct RecommendationHistoryRepository: Sendable {
    let database: any DatabaseManaging

    /// 旧快照只有最后记录日期；不伪装成精确时间，也不把当前模型理由套到旧历史上。
    /// 导入标记和所有行在一个事务内提交，重试或旧 JSON 残留不会恢复已撤销的反馈。
    @MainActor
    func importLegacy(_ state: DailyRecommendationState, accountID: Int64) async throws {
        guard database.currentUserId == accountID else { throw CancellationError() }
        try await database.writer.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT legacy_imported FROM recommendation_history_state WHERE id = 1") != true else { return }
            let snapshots = Dictionary(
                (state.items + (state.candidatePool?.items ?? [])).map { ($0.repoID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for id in state.recommendedIDs.union(state.dismissedIDs).sorted() where id > 0 {
                let day = state.recommendedDays[String(id)]
                let item: RepoRecommendationItem?
                if let recovered = snapshots[id] {
                    item = Self.legacyItem(recovered)
                } else if let repo = try Repo.fetchOne(db, key: id) {
                    item = Self.item(from: repo)
                } else {
                    item = nil
                }
                let snapshot = try item.map { try JSONEncoder().encode($0) }
                try db.execute(sql: """
                    INSERT OR IGNORE INTO recommendation_history
                        (repo_id, snapshot, recommended_day, sort_day, dismissed)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [id, snapshot, day, Self.sortDay(day), state.dismissedIDs.contains(id)])
            }
            try db.execute(sql: "INSERT INTO recommendation_history_state (id, legacy_imported) VALUES (1, 1)")
        }
    }

    /// 真正展示整批后登记；重复展示只补缺失资料，不改写原推荐时间。
    @MainActor
    func record(_ items: [RepoRecommendationItem], day: String, date: Date, batchID: String, accountID: Int64) async throws {
        guard database.currentUserId == accountID else { throw CancellationError() }
        try await database.writer.write { db in
            for item in items {
                let snapshot = try JSONEncoder().encode(item)
                try db.execute(sql: """
                    INSERT INTO recommendation_history
                        (repo_id, snapshot, recommended_at, recommended_day, sort_day, batch_id)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(repo_id) DO UPDATE SET snapshot = COALESCE(recommendation_history.snapshot, excluded.snapshot)
                    """, arguments: [item.repoID, snapshot, date.timeIntervalSince1970, day, Self.sortDay(day), batchID])
            }
        }
    }

    /// 查询不依赖 repos；清理普通缓存后仍能离线看到推荐名称、简介及真实依据。
    @MainActor
    func fetchAll(accountID: Int64) async throws -> [RecommendationHistoryEntry] {
        guard database.currentUserId == accountID else { throw CancellationError() }
        return try await database.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM recommendation_history
                ORDER BY sort_day DESC, recommended_at DESC, repo_id DESC
                """).map { row in
                    let data: Data? = row["snapshot"]
                    let timestamp: Double? = row["recommended_at"]
                    return RecommendationHistoryEntry(
                        id: row["repo_id"],
                        item: try data.map { try JSONDecoder().decode(RepoRecommendationItem.self, from: $0) },
                        recommendedAt: timestamp.map(Date.init(timeIntervalSince1970:)),
                        recommendedDay: row["recommended_day"], batchID: row["batch_id"],
                        isDismissed: row["dismissed"]
                    )
                }
        }
    }

    /// 只允许修改既有历史；未知 ID 不能凭一次操作创建伪推荐记录。
    @MainActor
    func setDismissed(_ dismissed: Bool, id: Int64, accountID: Int64) async throws {
        guard database.currentUserId == accountID else { throw CancellationError() }
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE recommendation_history SET dismissed = ? WHERE repo_id = ?", arguments: [dismissed, id])
        }
    }

    /// 无补零的旧 dayKey 不可按字符串排序；缺日期保留为未知，排在已知日期之后。
    static func sortDay(_ day: String?) -> Int {
        guard let parts = day?.split(separator: "-").compactMap({ Int($0) }),
              parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return 0 }
        return parts[0] * 10_000 + parts[1] * 100 + parts[2]
    }

    private static func legacyItem(_ item: RepoRecommendationItem) -> RepoRecommendationItem {
        RepoRecommendationItem(repoID: item.repoID, fullName: item.fullName, description: item.description,
                               language: item.language, stars: item.stars, forks: item.forks, archived: item.archived,
                               score: 0, source: "", reasons: [])
    }

    private static func item(from repo: Repo) -> RepoRecommendationItem {
        RepoRecommendationItem(repoID: repo.id, fullName: repo.fullName, description: repo.description,
                               language: repo.language, stars: repo.starsCount, forks: repo.forksCount,
                               archived: repo.isArchived, score: 0, source: "", reasons: [])
    }
}
