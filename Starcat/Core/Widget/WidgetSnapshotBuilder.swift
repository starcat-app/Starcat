//
//  WidgetSnapshotBuilder.swift
//  Starcat
//
//  从当前用户 GRDB 构建 Widget 专用最小只读投影。
//
//  关键约束：
//  - 所有查询在同一个 read transaction 内完成，避免仓库、标签和 Release 来自不同修订；
//  - 默认排除 Private repository，且不读取笔记正文；
//  - 今日重逢使用确定性 hash，不能使用跨进程随机化的 Swift Hasher。
//

import Foundation
import GRDB

enum WidgetSnapshotBuilderError: Error, Equatable, LocalizedError {
    case noAuthenticatedUser

    var errorDescription: String? {
        switch self {
        case .noAuthenticatedUser:
            return "Cannot build a ready Widget snapshot without an authenticated user"
        }
    }
}

/// 从当前用户数据库构建一次完整、内部一致的 Widget 快照。
struct WidgetSnapshotBuilder: Sendable {
    private let database: any DatabaseManaging

    init(database: any DatabaseManaging) {
        self.database = database
    }

    func build(
        generatedAt: Date = Date(),
        calendar: Calendar = .current
    ) async throws -> WidgetSnapshot {
        guard let userID = database.currentUserId else {
            throw WidgetSnapshotBuilderError.noAuthenticatedUser
        }

        return try await database.writer.read { db in
            let focusRows = try Row.fetchAll(
                db,
                sql: """
                SELECT r.*,
                       rn.status AS widget_status,
                       rp.pinned_at AS widget_pinned_at
                FROM repos r
                LEFT JOIN repo_notes rn ON rn.repo_id = r.id
                LEFT JOIN repo_pins rp ON rp.repo_id = r.id
                WHERE r.is_private = 0
                  AND r.is_archived = 0
                  AND r.access_state = 'accessible'
                  AND (rp.repo_id IS NOT NULL OR rn.status = 'using')
                ORDER BY
                    CASE WHEN rp.repo_id IS NOT NULL THEN 0 ELSE 1 END,
                    rp.pinned_at DESC,
                    r.starred_at DESC,
                    r.id ASC
                LIMIT 6
                """
            )

            let rediscoveryIDs = try Self.fetchRediscoveryCandidateIDs(
                db: db,
                generatedAt: generatedAt,
                calendar: calendar
            )
            let rediscoveryID = Self.selectRediscoveryRepositoryID(
                candidateIDs: rediscoveryIDs,
                userID: userID,
                date: generatedAt,
                calendar: calendar
            )
            let rediscoveryRow = try rediscoveryID.flatMap { repositoryID in
                try Row.fetchOne(
                    db,
                    sql: """
                    SELECT r.*, rn.status AS widget_status
                    FROM repos r
                    LEFT JOIN repo_notes rn ON rn.repo_id = r.id
                    WHERE r.id = ?
                    """,
                    arguments: [repositoryID]
                )
            }

            let releaseRows = try Row.fetchAll(
                db,
                sql: """
                SELECT rel.id AS release_id,
                       rel.repo_id AS release_repo_id,
                       rel.tag_name AS release_tag_name,
                       rel.name AS release_name,
                       rel.is_prerelease AS release_is_prerelease,
                       rel.published_at AS release_published_at,
                       rel.created_at_remote AS release_created_at_remote,
                       rel.fetched_at AS release_fetched_at,
                       r.owner AS release_owner,
                       r.name AS release_repo_name
                FROM releases rel
                INNER JOIN release_subscriptions sub ON sub.repo_id = rel.repo_id
                INNER JOIN repos r ON r.id = rel.repo_id
                WHERE sub.is_subscribed = 1
                  AND rel.is_read = 0
                  AND rel.is_draft = 0
                  AND r.is_private = 0
                  AND r.access_state = 'accessible'
                ORDER BY COALESCE(
                    rel.published_at,
                    rel.created_at_remote,
                    rel.fetched_at
                ) DESC
                LIMIT 6
                """
            )
            let unreadReleaseCount = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM releases rel
                INNER JOIN release_subscriptions sub ON sub.repo_id = rel.repo_id
                INNER JOIN repos r ON r.id = rel.repo_id
                WHERE sub.is_subscribed = 1
                  AND rel.is_read = 0
                  AND rel.is_draft = 0
                  AND r.is_private = 0
                  AND r.access_state = 'accessible'
                """
            ) ?? 0

            let projectedRepositoryIDs = Set(
                focusRows.compactMap { $0["id"] as Int64? }
                    + [rediscoveryID].compactMap { $0 }
            )
            let tagsByRepositoryID = try Self.fetchTags(
                db: db,
                repositoryIDs: projectedRepositoryIDs
            )

            let focus = focusRows.compactMap { row in
                Self.makeRepository(
                    row: row,
                    tags: tagsByRepositoryID[row["id"] as Int64] ?? []
                )
            }
            let rediscovery = rediscoveryRow.flatMap { row in
                Self.makeRepository(
                    row: row,
                    tags: tagsByRepositoryID[row["id"] as Int64] ?? []
                )
            }
            let releases = releaseRows.compactMap(Self.makeRelease(row:))

            return WidgetSnapshot(
                generatedAt: generatedAt,
                accountState: .ready,
                focusRepositories: focus,
                rediscoveryRepository: rediscovery,
                unreadReleaseCount: unreadReleaseCount,
                unreadReleases: releases
            )
        }
    }

    /// 返回稳定排序的候选 ID；完整 Repo 只为最终被选中的一条解码。
    private static func fetchRediscoveryCandidateIDs(
        db: Database,
        generatedAt: Date,
        calendar: Calendar
    ) throws -> [Int64] {
        guard let cutoff = calendar.date(byAdding: .day, value: -30, to: generatedAt) else {
            return []
        }
        let cutoffISO = ISO8601DateFormatter.shared.string(from: cutoff)

        return try Int64.fetchAll(
            db,
            sql: """
            SELECT r.id
            FROM repos r
            LEFT JOIN repo_notes rn ON rn.repo_id = r.id
            LEFT JOIN repo_pins rp ON rp.repo_id = r.id
            WHERE (r.is_starred = 1 OR rn.library_state = 'in_library')
              AND r.is_private = 0
              AND r.is_archived = 0
              AND r.access_state = 'accessible'
              AND (r.starred_at IS NULL OR r.starred_at < ?)
              AND rp.repo_id IS NULL
              AND COALESCE(rn.status, 'unread') != 'using'
            ORDER BY r.id ASC
            """,
            arguments: [cutoffISO]
        )
    }

    /// 同一用户、同一本地日期、同一候选集合始终得到相同 repo。
    static func selectRediscoveryRepositoryID(
        candidateIDs: [Int64],
        userID: Int64,
        date: Date,
        calendar: Calendar
    ) -> Int64? {
        guard !candidateIDs.isEmpty else { return nil }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let seed = "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0):\(userID)"

        // FNV-1a 64-bit 参数固定且跨进程稳定；Swift Hasher 带随机种子，不能用于日选。
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return candidateIDs[Int(hash % UInt64(candidateIDs.count))]
    }

    private static func fetchTags(
        db: Database,
        repositoryIDs: Set<Int64>
    ) throws -> [Int64: [String]] {
        guard !repositoryIDs.isEmpty else { return [:] }
        let sortedIDs = repositoryIDs.sorted()
        let placeholders = Array(repeating: "?", count: sortedIDs.count).joined(separator: ", ")
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT rt.repo_id AS widget_repo_id, t.name AS widget_tag_name
            FROM repo_tags rt
            INNER JOIN tags t ON t.id = rt.tag_id
            WHERE rt.repo_id IN (\(placeholders))
            ORDER BY rt.repo_id, t.sort_order ASC, t.name ASC
            """,
            arguments: StatementArguments(sortedIDs)
        )

        var result: [Int64: [String]] = [:]
        for row in rows {
            let repositoryID: Int64 = row["widget_repo_id"]
            guard result[repositoryID, default: []].count < 3 else { continue }
            let name: String = row["widget_tag_name"]
            result[repositoryID, default: []].append(
                String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
            )
        }
        return result
    }

    private static func makeRepository(row: Row, tags: [String]) -> WidgetRepository? {
        guard let repo = try? Repo(row: row),
              !repo.isPrivate,
              let deepLink = RepositoryDeepLink(
                owner: repo.owner,
                name: repo.name,
                repositoryID: repo.id
              ) else {
            return nil
        }
        let rawStatus: String? = row["widget_status"]
        return WidgetRepository(
            id: repo.id,
            owner: repo.owner,
            name: repo.name,
            description: repo.description.map { String($0.prefix(180)) },
            language: repo.language.map { String($0.prefix(32)) },
            starsCount: max(0, repo.starsCount),
            tags: Array(tags.prefix(3)),
            status: rawStatus.map { RepoStatus.parse($0).rawValue },
            avatarFileName: nil,
            openURL: deepLink.appURL
        )
    }

    private static func makeRelease(row: Row) -> WidgetRelease? {
        let releaseID: Int64 = row["release_id"]
        let repositoryID: Int64 = row["release_repo_id"]
        let owner: String = row["release_owner"]
        let repositoryName: String = row["release_repo_name"]
        guard releaseID > 0,
              let deepLink = RepositoryDeepLink(
                owner: owner,
                name: repositoryName,
                repositoryID: repositoryID
              ) else {
            return nil
        }
        let publishedRaw: String? = row["release_published_at"]
            ?? row["release_created_at_remote"]
            ?? row["release_fetched_at"]

        return WidgetRelease(
            id: releaseID,
            repositoryID: repositoryID,
            owner: owner,
            repositoryName: repositoryName,
            tagName: String((row["release_tag_name"] as String).prefix(80)),
            displayName: (row["release_name"] as String?).map { String($0.prefix(120)) },
            publishedAt: publishedRaw.flatMap { ISO8601DateFormatter.shared.date(from: $0) },
            isPrerelease: row["release_is_prerelease"] as Bool,
            avatarFileName: nil,
            openURL: deepLink.appURL
        )
    }
}
