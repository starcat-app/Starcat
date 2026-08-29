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

    /// 发布门禁只读取当前身份，不接触数据库路径或业务数据。
    var currentUserID: Int64? { database.currentUserId }

    init(database: any DatabaseManaging) {
        self.database = database
    }

    func build(
        generatedAt: Date = Date(),
        calendar: Calendar = .current,
        contributionCalendar: ContributionCalendarPayload? = nil
    ) async throws -> WidgetSnapshot {
        guard let userID = database.currentUserId else {
            throw WidgetSnapshotBuilderError.noAuthenticatedUser
        }

        let contributionActivity = Self.makeContributionActivity(
            from: contributionCalendar,
            generatedAt: generatedAt,
            calendar: calendar
        )

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
                    SELECT r.*,
                           rn.status AS widget_status,
                           NULL AS widget_pinned_at
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
            let collectionTrend = try Self.makeCollectionTrend(
                db: db,
                generatedAt: generatedAt
            )

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
                unreadReleases: releases,
                collectionTrend: collectionTrend,
                contributionActivity: contributionActivity
            )
        }
    }

    /// 把主应用贡献缓存压缩成 Widget 可读取的匿名聚合投影。
    ///
    /// 保留 GitHub 周边界与官方贡献等级，避免 Extension 重新推导日期或强度；
    /// “今日”按主应用当前日历生成 `YYYY-MM-DD`，与 GraphQL 日期字段直接比较。
    private static func makeContributionActivity(
        from payload: ContributionCalendarPayload?,
        generatedAt: Date,
        calendar: Calendar
    ) -> WidgetContributionActivity? {
        guard let payload else { return nil }

        let weeks = payload.weeks.map { week in
            WidgetContributionWeek(
                days: week.contributionDays.map { day in
                    WidgetContributionDay(
                        date: day.date,
                        count: max(0, day.contributionCount),
                        level: WidgetContributionLevel(rawValue: day.contributionLevel.rawValue)
                            ?? .none,
                        weekday: min(6, max(0, day.weekday))
                    )
                }
            )
        }
        let days = weeks.flatMap(\.days)
        let today = contributionDateString(for: generatedAt, calendar: calendar)
        let stats = payload.activityStats

        return WidgetContributionActivity(
            totalContributions: max(0, payload.totalContributions),
            todayContributions: days.first(where: { $0.date == today })?.count ?? 0,
            bestDayContributions: days.map(\.count).max() ?? 0,
            weeks: Array(weeks.suffix(53)),
            stats: WidgetContributionStats(
                commits: stats.commits,
                issues: stats.issues,
                pullRequests: stats.pullRequests,
                reviews: stats.reviews,
                repositories: stats.repositories
            )
        )
    }

    private static func contributionDateString(
        for date: Date,
        calendar: Calendar
    ) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    /// 构建 12 周汇总、26 周单日热力点与公开收藏整理状态。
    ///
    /// 周边界与“我的洞察”保持 ISO 周一口径，但这里有意排除 Private 和 inaccessible
    /// repository；Widget 快照是跨进程桌面数据，不能因为只展示聚合值就绕过既有隐私门禁。
    private static func makeCollectionTrend(
        db: Database,
        generatedAt: Date
    ) throws -> WidgetCollectionTrend {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let currentWeek = calendar.dateInterval(
            of: .weekOfYear,
            for: generatedAt
        )?.start,
        let firstWeek = calendar.date(
            byAdding: .weekOfYear,
            value: -11,
            to: currentWeek
        ),
        let firstHeatmapWeek = calendar.date(
            byAdding: .weekOfYear,
            value: -25,
            to: currentWeek
        ) else {
            return WidgetCollectionTrend(
                totalCount: 0,
                addedInLast30DaysCount: 0,
                weeklyPoints: [],
                dailyPoints: [],
                statusBreakdown: WidgetCollectionStatusBreakdown(
                    unreadCount: 0,
                    readCount: 0,
                    usingCount: 0
                )
            )
        }

        let generatedAtISO = ISO8601DateFormatter.shared.string(from: generatedAt)
        let recentCutoffISO = ISO8601DateFormatter.shared.string(
            from: generatedAt.addingTimeInterval(-30 * 24 * 60 * 60)
        )
        let overview = try Row.fetchOne(
            db,
            sql: """
            SELECT
                COUNT(*) AS total_count,
                COALESCE(SUM(CASE
                    WHEN r.starred_at IS NOT NULL
                     AND datetime(r.starred_at) >= datetime(?)
                     AND datetime(r.starred_at) <= datetime(?)
                    THEN 1 ELSE 0
                END), 0) AS recent_count,
                COALESCE(SUM(CASE
                    WHEN rn.repo_id IS NULL OR rn.status = 'unread'
                    THEN 1 ELSE 0
                END), 0) AS unread_count,
                COALESCE(SUM(CASE WHEN rn.status = 'using' THEN 1 ELSE 0 END), 0)
                    AS using_count,
                COALESCE(SUM(CASE
                    WHEN rn.repo_id IS NOT NULL
                     AND rn.status NOT IN ('unread', 'using')
                    THEN 1 ELSE 0
                END), 0) AS read_count
            FROM repos r
            LEFT JOIN repo_notes rn ON rn.repo_id = r.id
            WHERE r.is_starred = 1
              AND r.is_private = 0
              AND r.access_state = 'accessible'
            """,
            arguments: [recentCutoffISO, generatedAtISO]
        )!

        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT
                date(
                    r.starred_at,
                    printf(
                        '-%d days',
                        (CAST(strftime('%w', r.starred_at) AS INTEGER) + 6) % 7
                    )
                ) AS week_start,
                COUNT(*) AS count
            FROM repos r
            WHERE r.is_starred = 1
              AND r.is_private = 0
              AND r.access_state = 'accessible'
              AND r.starred_at IS NOT NULL
              AND datetime(r.starred_at) >= datetime(?)
              AND datetime(r.starred_at) <= datetime(?)
            GROUP BY week_start
            ORDER BY week_start ASC
            """,
            arguments: [
                ISO8601DateFormatter.shared.string(from: firstWeek),
                generatedAtISO
            ]
        )
        let counts = Dictionary(uniqueKeysWithValues: rows.map {
            ($0["week_start"] as String, $0["count"] as Int)
        })
        let weeklyPoints = (0..<12).compactMap { offset -> WidgetCollectionTrendPoint? in
            guard let week = calendar.date(
                byAdding: .weekOfYear,
                value: offset,
                to: firstWeek
            ) else {
                return nil
            }
            let key = String(ISO8601DateFormatter.shared.string(from: week).prefix(10))
            return WidgetCollectionTrendPoint(
                weekStart: week,
                count: max(0, counts[key] ?? 0)
            )
        }

        let dailyRows = try Row.fetchAll(
            db,
            sql: """
            SELECT date(r.starred_at) AS day, COUNT(*) AS count
            FROM repos r
            WHERE r.is_starred = 1
              AND r.is_private = 0
              AND r.access_state = 'accessible'
              AND r.starred_at IS NOT NULL
              AND datetime(r.starred_at) >= datetime(?)
              AND datetime(r.starred_at) <= datetime(?)
            GROUP BY day
            ORDER BY day ASC
            """,
            arguments: [
                ISO8601DateFormatter.shared.string(from: firstHeatmapWeek),
                generatedAtISO
            ]
        )
        let dailyCounts = Dictionary(uniqueKeysWithValues: dailyRows.map {
            ($0["day"] as String, $0["count"] as Int)
        })
        // 26 个完整 ISO 周固定为 182 个点。当前周尚未到来的日期以 0 占位，
        // Widget 才能稳定按“周为列、星期为行”布局，而不会每天横向跳动。
        let dailyPoints = (0..<(26 * 7)).compactMap { offset -> WidgetCollectionTrendDay? in
            guard let day = calendar.date(
                byAdding: .day,
                value: offset,
                to: firstHeatmapWeek
            ) else {
                return nil
            }
            let key = String(ISO8601DateFormatter.shared.string(from: day).prefix(10))
            return WidgetCollectionTrendDay(
                date: day,
                count: max(0, dailyCounts[key] ?? 0)
            )
        }

        return WidgetCollectionTrend(
            totalCount: max(0, overview["total_count"] as Int),
            addedInLast30DaysCount: max(0, overview["recent_count"] as Int),
            weeklyPoints: weeklyPoints,
            dailyPoints: dailyPoints,
            statusBreakdown: WidgetCollectionStatusBreakdown(
                unreadCount: max(0, overview["unread_count"] as Int),
                readCount: max(0, overview["read_count"] as Int),
                usingCount: max(0, overview["using_count"] as Int)
            )
        )
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
        let pinnedAt: Double? = row["widget_pinned_at"]
        let focusSource: WidgetFocusSource? = if pinnedAt != nil {
            .pinned
        } else if rawStatus.map(RepoStatus.parse) == .using {
            .using
        } else {
            nil
        }
        return WidgetRepository(
            id: repo.id,
            owner: repo.owner,
            name: repo.name,
            description: repo.description.map { String($0.prefix(180)) },
            language: repo.language.map { String($0.prefix(32)) },
            starsCount: max(0, repo.starsCount),
            tags: Array(tags.prefix(3)),
            status: rawStatus.map { RepoStatus.parse($0).rawValue },
            focusSource: focusSource,
            avatarFileName: nil,
            openURL: deepLink.appURL
        )
    }

    private static func makeRelease(row: Row) -> WidgetRelease? {
        let releaseID: Int64 = row["release_id"]
        let repositoryID: Int64 = row["release_repo_id"]
        let owner: String = row["release_owner"]
        let repositoryName: String = row["release_repo_name"]
        guard let deepLink = RepositoryReleaseDeepLink(
                owner: owner,
                name: repositoryName,
                repositoryID: repositoryID,
                releaseID: releaseID
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
            // GitHub 可能返回带或不带毫秒的 ISO8601；统一复用双格式解析器，
            // 否则常见的 `...00Z` 会被误判为 nil，Widget 无法显示相对时间。
            publishedAt: ISO8601DateFormatter.githubDate(from: publishedRaw),
            isPrerelease: row["release_is_prerelease"] as Bool,
            avatarFileName: nil,
            openURL: deepLink.appURL
        )
    }
}
