//
//  UserRepoActivityRepository.swift
//  Starcat
//
//  当前用户 Star / Unstar / Fork 账本。
//
//  关键约束：
//  - 只追加。最新一条已是同 kind 时，Star / Unstar 不再写（避免 Starcat star 完
//    同步又补一条 github_sync）。
//  - 通知时间线两表 UNION 的分页也放这里，避免 InboxService 自己拼 SQL。
//

import Foundation
import GRDB

struct GitHubInboxTimelineCursor: Equatable, Sendable {
    let occurredAt: String
    let id: String
}

enum GitHubInboxTimelineRow: Equatable, Identifiable, Sendable {
    /// `language` 来自本地 `repos`；没有缓存时为 nil，UI 退回通知分类色。
    case notification(GitHubNotificationThreadRecord, language: String?)
    case activity(UserRepoActivityListItem)

    var id: String {
        switch self {
        case .notification(let record, _):
            return record.id
        case .activity(let item):
            return item.record.id
        }
    }

    var occurredAt: String {
        switch self {
        case .notification(let record, _):
            return record.updatedAt
        case .activity(let item):
            return item.record.occurredAt
        }
    }

    var cursor: GitHubInboxTimelineCursor {
        GitHubInboxTimelineCursor(occurredAt: occurredAt, id: id)
    }

    var unread: Bool {
        switch self {
        case .notification(let record, _):
            return record.unread
        case .activity:
            return false
        }
    }

    /// 给时间线选中条 / 轴点用。空串当没有。
    var language: String? {
        switch self {
        case .notification(_, let language):
            return Self.normalizedLanguage(language)
        case .activity(let item):
            return Self.normalizedLanguage(item.language)
        }
    }

    fileprivate static func normalizedLanguage(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Stars 同步批量写入用：避免 SyncManager 为了账本去拼完整 `Repo`。
struct UserRepoActivityStarDraft: Sendable {
    let repoID: Int64
    let fullName: String
    let htmlURL: String
    let occurredAt: String
}

protocol UserRepoActivityRepositoryProtocol: Sendable {
    func recordStar(
        repo: Repo,
        source: UserRepoActivitySource,
        actor: UserRepoActivityActor,
        occurredAt: String
    ) async throws

    /// 全量 / 增量 Stars 同步发现的网页 Star。同一事务写入，只通知一次。
    func recordSyncedStars(_ items: [UserRepoActivityStarDraft], actor: UserRepoActivityActor) async throws

    func recordUnstar(
        repoID: Int64,
        fullName: String,
        htmlURL: String,
        source: UserRepoActivitySource,
        actor: UserRepoActivityActor,
        occurredAt: String
    ) async throws

    func recordFork(
        repo: Repo,
        source: UserRepoActivitySource,
        actor: UserRepoActivityActor,
        occurredAt: String
    ) async throws

    func recordUnstars(
        repoIDs: Set<Int64>,
        actor: UserRepoActivityActor,
        occurredAt: String
    ) async throws

    /// 把当前仍 star / 仍归自己的 fork 灌进账本，并给 v24 旧行补身份。可重复跑。
    func backfillFromLocalCaches(actor: UserRepoActivityActor) async throws

    func count() async throws -> Int

    func fetchPage(
        filter: GitHubNotificationFilter,
        cursor: GitHubInboxTimelineCursor?,
        limit: Int
    ) async throws -> (rows: [GitHubInboxTimelineRow], hasMore: Bool)

    func timelineCount(filter: GitHubNotificationFilter) async throws -> Int

    func adjacentNotificationID(
        after id: String,
        delta: Int,
        filter: GitHubNotificationFilter
    ) async throws -> String?
}

struct GRDBUserRepoActivityRepository: UserRepoActivityRepositoryProtocol, Sendable {
    private let database: any DatabaseManaging

    init(database: any DatabaseManaging) {
        self.database = database
    }

    func recordStar(
        repo: Repo,
        source: UserRepoActivitySource,
        actor: UserRepoActivityActor,
        occurredAt: String
    ) async throws {
        try await insert(
            kind: .star,
            source: source,
            actor: actor,
            repoID: repo.id,
            fullName: repo.fullName,
            htmlURL: repo.htmlUrl,
            occurredAt: occurredAt
        )
    }

    func recordSyncedStars(_ items: [UserRepoActivityStarDraft], actor: UserRepoActivityActor) async throws {
        guard actor.isIdentified, !items.isEmpty else { return }
        let createdAt = UserRepoActivityRecord.timestamp()
        let didInsert = try await database.writer.write { db in
            var inserted = false
            for item in items {
                if try Self.insertIfKindChanged(
                    db: db,
                    kind: .star,
                    source: .githubSync,
                    actor: actor,
                    repoID: item.repoID,
                    fullName: item.fullName,
                    htmlURL: item.htmlURL,
                    occurredAt: item.occurredAt,
                    createdAt: createdAt
                ) {
                    inserted = true
                }
            }
            return inserted
        }
        if didInsert {
            NotificationCenter.default.post(name: .userRepoActivityDidChange, object: nil)
        }
    }

    func recordUnstar(
        repoID: Int64,
        fullName: String,
        htmlURL: String,
        source: UserRepoActivitySource,
        actor: UserRepoActivityActor,
        occurredAt: String
    ) async throws {
        try await insert(
            kind: .unstar,
            source: source,
            actor: actor,
            repoID: repoID,
            fullName: fullName,
            htmlURL: htmlURL,
            occurredAt: occurredAt
        )
    }

    func recordFork(
        repo: Repo,
        source: UserRepoActivitySource,
        actor: UserRepoActivityActor,
        occurredAt: String
    ) async throws {
        try await insert(
            kind: .fork,
            source: source,
            actor: actor,
            repoID: repo.id,
            fullName: repo.fullName,
            htmlURL: repo.htmlUrl,
            occurredAt: occurredAt
        )
    }

    func recordUnstars(
        repoIDs: Set<Int64>,
        actor: UserRepoActivityActor,
        occurredAt: String
    ) async throws {
        guard actor.isIdentified, !repoIDs.isEmpty else { return }
        let createdAt = UserRepoActivityRecord.timestamp()
        try await database.writer.write { db in
            let ids = Array(repoIDs)
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, full_name, html_url FROM repos WHERE id IN (\(placeholders))",
                arguments: StatementArguments(ids)
            )
            for row in rows {
                let repoID: Int64 = row["id"]
                let fullName: String = row["full_name"]
                let htmlURL: String = row["html_url"]
                try Self.insertIfKindChanged(
                    db: db,
                    kind: .unstar,
                    source: .githubSync,
                    actor: actor,
                    repoID: repoID,
                    fullName: fullName,
                    htmlURL: htmlURL,
                    occurredAt: occurredAt,
                    createdAt: createdAt
                )
            }
        }
        NotificationCenter.default.post(name: .userRepoActivityDidChange, object: nil)
    }

    func backfillFromLocalCaches(actor: UserRepoActivityActor) async throws {
        guard actor.isIdentified else { return }
        let createdAt = UserRepoActivityRecord.timestamp()
        let login = actor.userName
        let userID = actor.userID
        try await database.writer.write { db in
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO user_repo_activity (
                        id, kind, source, repo_id, full_name, html_url, occurred_at, created_at, user_id, user_name
                    )
                    SELECT
                        'star:github_sync:' || r.id || ':' || sr.starred_at,
                        'star',
                        'github_sync',
                        r.id,
                        r.full_name,
                        r.html_url,
                        sr.starred_at,
                        ?,
                        ?,
                        ?
                    FROM starred_repos sr
                    JOIN repos r ON r.id = sr.repo_id
                    WHERE r.is_starred = 1
                      AND sr.starred_at IS NOT NULL
                      AND sr.starred_at != ''
                      AND NOT EXISTS (
                          SELECT 1 FROM (
                              SELECT kind FROM user_repo_activity a
                              WHERE a.repo_id = r.id
                              ORDER BY a.occurred_at DESC, a.id DESC
                              LIMIT 1
                          ) latest
                          WHERE latest.kind = 'star'
                      )
                    """,
                arguments: [createdAt, userID, login]
            )
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO user_repo_activity (
                        id, kind, source, repo_id, full_name, html_url, occurred_at, created_at, user_id, user_name
                    )
                    SELECT
                        'fork:github_sync:' || r.id || ':' || COALESCE(r.created_at, ?),
                        'fork',
                        'github_sync',
                        r.id,
                        r.full_name,
                        r.html_url,
                        COALESCE(r.created_at, ?),
                        ?,
                        ?,
                        ?
                    FROM repos r
                    WHERE r.is_fork = 1
                      AND (
                        (? != '' AND r.owner = ? COLLATE NOCASE)
                        OR EXISTS (
                            SELECT 1 FROM user_projects p
                            WHERE p.repo_id = r.id
                              AND p.user_id = ?
                              AND p.affiliation = 'owner'
                        )
                      )
                      AND NOT EXISTS (
                          SELECT 1 FROM user_repo_activity a
                          WHERE a.repo_id = r.id AND a.kind = 'fork'
                      )
                    """,
                arguments: [createdAt, createdAt, createdAt, userID, login, login, login, userID]
            )
            try db.execute(
                sql: """
                    UPDATE user_repo_activity
                    SET user_id = CASE WHEN user_id IS NULL THEN ? ELSE user_id END,
                        user_name = CASE WHEN user_name IS NULL OR user_name = '' THEN ? ELSE user_name END
                    WHERE user_id IS NULL OR user_name IS NULL OR user_name = ''
                    """,
                arguments: [userID, login]
            )
        }
        NotificationCenter.default.post(name: .userRepoActivityDidChange, object: nil)
    }

    func count() async throws -> Int {
        try await database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM user_repo_activity") ?? 0
        }
    }

    func fetchPage(
        filter: GitHubNotificationFilter,
        cursor: GitHubInboxTimelineCursor?,
        limit: Int
    ) async throws -> (rows: [GitHubInboxTimelineRow], hasMore: Bool) {
        let safeLimit = max(1, limit)
        let queryLimit = safeLimit + 1
        let keys = try await fetchKeys(filter: filter, cursor: cursor, limit: queryLimit)
        let hasMore = keys.count > safeLimit
        let pageKeys = Array(keys.prefix(safeLimit))
        let rows = try await hydrate(keys: pageKeys)
        return (rows, hasMore)
    }

    func timelineCount(filter: GitHubNotificationFilter) async throws -> Int {
        return try await database.writer.read { db in
            let query = Self.timelineQuery(filter: filter)
            return try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM (\(query.sql))",
                arguments: StatementArguments(query.arguments)
            ) ?? 0
        }
    }

    /// 详情导航同样使用完整 SQL 条件，不受首页 40 条或历史回填 300 条上限影响。
    func adjacentNotificationID(
        after id: String,
        delta: Int,
        filter: GitHubNotificationFilter
    ) async throws -> String? {
        guard delta == 1 || delta == -1 else { return nil }
        return try await database.writer.read { db in
            let query = Self.timelineQuery(filter: filter)
            guard let current = try GitHubNotificationThreadRecord.fetchOne(db, key: id) else { return nil }
            let comparison = delta == 1 ? "<" : ">"
            let order = delta == 1 ? "DESC" : "ASC"
            var arguments = query.arguments
            arguments.append(contentsOf: [current.updatedAt, current.updatedAt, current.id])
            return try String.fetchOne(
                db,
                sql: """
                    SELECT id FROM (\(query.sql))
                    WHERE source = 'notification'
                      AND (occurred_at \(comparison) ? OR (occurred_at = ? AND id \(comparison) ?))
                    ORDER BY occurred_at \(order), id \(order) LIMIT 1
                    """,
                arguments: StatementArguments(arguments)
            )
        }
    }

    // MARK: - Private

    private func insert(
        kind: UserRepoActivityKind,
        source: UserRepoActivitySource,
        actor: UserRepoActivityActor,
        repoID: Int64,
        fullName: String,
        htmlURL: String,
        occurredAt: String
    ) async throws {
        guard actor.isIdentified else { return }
        let createdAt = UserRepoActivityRecord.timestamp()
        let didInsert = try await database.writer.write { db in
            try Self.insertIfKindChanged(
                db: db,
                kind: kind,
                source: source,
                actor: actor,
                repoID: repoID,
                fullName: fullName,
                htmlURL: htmlURL,
                occurredAt: occurredAt,
                createdAt: createdAt
            )
        }
        if didInsert {
            NotificationCenter.default.post(name: .userRepoActivityDidChange, object: nil)
        }
    }

    @discardableResult
    private static func insertIfKindChanged(
        db: Database,
        kind: UserRepoActivityKind,
        source: UserRepoActivitySource,
        actor: UserRepoActivityActor,
        repoID: Int64,
        fullName: String,
        htmlURL: String,
        occurredAt: String,
        createdAt: String
    ) throws -> Bool {
        guard actor.isIdentified else { return false }
        let latestKind = try String.fetchOne(
            db,
            sql: """
                SELECT kind FROM user_repo_activity
                WHERE repo_id = ?
                ORDER BY occurred_at DESC, id DESC
                LIMIT 1
                """,
            arguments: [repoID]
        )
        if latestKind == kind.rawValue {
            return false
        }
        let id = UserRepoActivityRecord.makeID(
            kind: kind,
            source: source,
            repoID: repoID,
            occurredAt: occurredAt
        )
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO user_repo_activity (
                    id, kind, source, repo_id, full_name, html_url, occurred_at, created_at, user_id, user_name
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                id,
                kind.rawValue,
                source.rawValue,
                repoID,
                fullName,
                htmlURL,
                occurredAt,
                createdAt,
                actor.userID,
                actor.userName
            ]
        )
        return db.changesCount > 0
    }

    private struct TimelineKey: Equatable {
        let id: String
        let occurredAt: String
        let source: String
    }

    private func fetchKeys(
        filter: GitHubNotificationFilter,
        cursor: GitHubInboxTimelineCursor?,
        limit: Int
    ) async throws -> [TimelineKey] {
        try await database.writer.read { db in
            let query = Self.timelineQuery(filter: filter)
            var sql = "SELECT id, occurred_at, source FROM (\(query.sql)) "
            var arguments = query.arguments
            if let cursor {
                sql += """
                    WHERE occurred_at < ?
                       OR (occurred_at = ? AND id < ?)
                    """
                arguments.append(cursor.occurredAt)
                arguments.append(cursor.occurredAt)
                arguments.append(cursor.id)
            }
            sql += """
                ORDER BY occurred_at DESC, id DESC
                LIMIT ?
                """
            arguments.append(limit)

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
            return rows.map { row in
                TimelineKey(
                    id: row["id"],
                    occurredAt: row["occurred_at"],
                    source: row["source"]
                )
            }
        }
    }

    /// 分页、总数、详情导航与 CLI 共用这一查询；所有筛选都先于游标和 LIMIT。
    private static func timelineQuery(
        filter: GitHubNotificationFilter
    ) -> (sql: String, arguments: [any DatabaseValueConvertible]) {
        var queries: [String] = []
        var arguments: [any DatabaseValueConvertible] = []
        if filter.includesNotifications {
            var clauses: [String] = []
            let subjectTypes = filter.eventTypes.compactMap(\.subjectType).sorted()
            if !subjectTypes.isEmpty {
                clauses.append("n.subject_type IN (\(subjectTypes.map { _ in "?" }.joined(separator: ",")))")
                arguments.append(contentsOf: subjectTypes)
            }
            if filter.readState == .unread { clauses.append("n.unread = 1") }
            if let state = filter.issueState.issueStateFilter {
                clauses.append("n.subject_type IN ('Issue', 'PullRequest') AND n.issue_state = ?")
                arguments.append(state)
            }
            let reasons = filter.reasons.flatMap(\.reasonValues).sorted()
            if !reasons.isEmpty {
                clauses.append("n.reason IN (\(reasons.map { _ in "?" }.joined(separator: ",")))")
                arguments.append(contentsOf: reasons)
            }
            // ID 优先；通知没有对应缓存 ID 时按 full_name 找本地项目，不能只筛账本。
            let repoID = """
                COALESCE(
                    (SELECT id FROM repos WHERE id = n.repository_id),
                    (SELECT id FROM repos WHERE full_name = n.repository_full_name COLLATE NOCASE LIMIT 1),
                    n.repository_id
                )
                """
            if let library = libraryClause(filter.libraryState, repoID: repoID) { clauses.append(library) }
            queries.append("""
                SELECT n.id, n.updated_at AS occurred_at, 'notification' AS source
                FROM github_notification_threads n
                \(clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND "))
                """)
        }
        if filter.includesActivities {
            var clauses: [String] = []
            let kinds = filter.eventTypes.compactMap(\.ledgerKind).map(\.rawValue).sorted()
            if !kinds.isEmpty {
                clauses.append("a.kind IN (\(kinds.map { _ in "?" }.joined(separator: ",")))")
                arguments.append(contentsOf: kinds)
            }
            if let library = libraryClause(filter.libraryState, repoID: "a.repo_id") { clauses.append(library) }
            queries.append("""
                SELECT a.id, a.occurred_at, 'activity' AS source FROM user_repo_activity a
                \(clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND "))
                """)
        }
        // 例如 Star + 未读：两个来源都不匹配，仍返回可计数、可分页的空查询。
        return (
            queries.isEmpty
                ? "SELECT id, occurred_at, 'activity' AS source FROM user_repo_activity WHERE 0"
                : queries.joined(separator: " UNION ALL "),
            arguments
        )
    }

    private static func libraryClause(_ option: GitHubNotificationSegment, repoID: String) -> String? {
        guard let state = option.libraryStateFilter else { return nil }
        let membership = """
            EXISTS (SELECT 1 FROM repo_notes
                    WHERE repo_id = \(repoID) AND library_state = 'in_library')
            """
        return state == .inLibrary ? membership : "NOT \(membership)"
    }

    private func hydrate(keys: [TimelineKey]) async throws -> [GitHubInboxTimelineRow] {
        guard !keys.isEmpty else { return [] }
        let notificationIDs = keys.filter { $0.source == "notification" }.map(\.id)
        let activityIDs = keys.filter { $0.source == "activity" }.map(\.id)

        return try await database.writer.read { db in
            var notifications: [String: (GitHubNotificationThreadRecord, String?)] = [:]
            if !notificationIDs.isEmpty {
                let placeholders = Array(repeating: "?", count: notificationIDs.count).joined(separator: ",")
                let records = try GitHubNotificationThreadRecord.fetchAll(
                    db,
                    sql: "SELECT * FROM github_notification_threads WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(notificationIDs)
                )
                let languages = try Self.fetchLanguages(
                    db: db,
                    repoIDs: records.compactMap(\.repositoryId),
                    fullNames: records.map(\.repositoryFullName)
                )
                for record in records {
                    let language = record.repositoryId.flatMap { languages.byID[$0] }
                        ?? languages.byFullName[record.repositoryFullName]
                    notifications[record.id] = (record, language)
                }
            }

            var activities: [String: UserRepoActivityListItem] = [:]
            if !activityIDs.isEmpty {
                let placeholders = Array(repeating: "?", count: activityIDs.count).joined(separator: ",")
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT a.*, r.description AS repo_description, r.owner AS repo_owner,
                               r.language AS repo_language, n.library_state AS repo_library_state
                        FROM user_repo_activity a
                        LEFT JOIN repos r ON r.id = a.repo_id
                        LEFT JOIN repo_notes n ON n.repo_id = a.repo_id
                        WHERE a.id IN (\(placeholders))
                        """,
                    arguments: StatementArguments(activityIDs)
                )
                for row in rows {
                    let record = try UserRepoActivityRecord(row: row)
                    let description = (row["repo_description"] as String?)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let snippet = (description?.isEmpty == false) ? description : nil
                    activities[record.id] = UserRepoActivityListItem(
                        record: record,
                        snippet: snippet,
                        ownerLogin: row["repo_owner"],
                        language: GitHubInboxTimelineRow.normalizedLanguage(row["repo_language"]),
                        libraryState: LibraryState.parse(row["repo_library_state"])
                    )
                }
            }

            return keys.compactMap { key in
                if key.source == "notification", let pair = notifications[key.id] {
                    return .notification(pair.0, language: pair.1)
                }
                if key.source == "activity", let item = activities[key.id] {
                    return .activity(item)
                }
                return nil
            }
        }
    }

    /// 时间线点 / 选中条用的语言色。按 GitHub repo id 或 full_name 对本地缓存。
    private static func fetchLanguages(
        db: Database,
        repoIDs: [Int64],
        fullNames: [String]
    ) throws -> (byID: [Int64: String], byFullName: [String: String]) {
        var clauses: [String] = []
        var arguments: [any DatabaseValueConvertible] = []
        if !repoIDs.isEmpty {
            let placeholders = Array(repeating: "?", count: repoIDs.count).joined(separator: ",")
            clauses.append("id IN (\(placeholders))")
            arguments.append(contentsOf: repoIDs)
        }
        if !fullNames.isEmpty {
            let placeholders = Array(repeating: "?", count: fullNames.count).joined(separator: ",")
            clauses.append("full_name IN (\(placeholders))")
            arguments.append(contentsOf: fullNames)
        }
        guard !clauses.isEmpty else { return ([:], [:]) }

        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, full_name, language FROM repos
                WHERE \(clauses.joined(separator: " OR "))
                """,
            arguments: StatementArguments(arguments)
        )
        var byID: [Int64: String] = [:]
        var byFullName: [String: String] = [:]
        for row in rows {
            guard let language = GitHubInboxTimelineRow.normalizedLanguage(row["language"]) else {
                continue
            }
            let id: Int64 = row["id"]
            let fullName: String = row["full_name"]
            byID[id] = language
            if !fullName.isEmpty {
                byFullName[fullName] = language
            }
        }
        return (byID, byFullName)
    }
}
