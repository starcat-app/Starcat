//
//  KnowledgeProfileFacts.swift
//  Starcat
//
//  洞察和年报使用同一份可编码的本地事实。分类属于生成时刻，动作才有历史日期。
//

import Foundation
import GRDB

/// 数量从完整证据推导。快照编码后可以独立于标签、仓库缓存和账号数据库读取。
struct KnowledgeProfileFacts: Codable, Sendable {
    enum Coverage: String, Codable { case unknown, partial, complete }
    enum Note: String, Codable { case none, manual, ai }

    struct Repository: Codable, Sendable {
        let id: Int64
        let fullName: String?
        let language: String?
        let topics: [String]
        let tags: [String]
        let starred: Bool
        let inLibrary: Bool
        let using: Bool
        let note: Note
        let hasSummary: Bool
    }

    struct Event: Codable, Sendable {
        let repoID: Int64
        let fullName: String?
        let action: KnowledgeAction
        let source: KnowledgeActionSource
        let date: Date

        /// 网页取消收藏只能在同步发现时定位。
        var isDiscoveryTime: Bool { action == .unstar && source == .githubSync }
    }

    let rulesVersion: Int
    let accountID: Int64
    let scope: String
    let window: DateInterval
    let timeZoneID: String
    let cutoff: Date
    let classifiedAt: Date
    let localCollectionStartedAt: Date
    let localCoverage: Coverage
    let starCoverage: Coverage
    let events: [Event]
    let repositories: [Repository]

    /// 当前范围的仓库与已离开范围的历史证据分别取用，已删除缓存的事件仍保留 repoID。
    var currentMembers: [Repository] {
        repositories.filter { scope == InsightsScope.starred.rawValue ? $0.starred : $0.inLibrary }
    }

    var starEvents: [Event] { events.filter { $0.action == .star } }
    var starredRepoIDs: Set<Int64> { Set(starEvents.map(\.repoID)) }
    var writtenRepoIDs: Set<Int64> {
        Set(events.filter { $0.action == .wroteNote || $0.action == .editedNote }.map(\.repoID))
    }

    enum Dimension: CaseIterable, Hashable, Sendable { case topic, userTag, language }
    enum Members { case current, starredInPeriod }

    /// 分组值保留完整仓库证据，同一项目可出现在多个主题下。nil 是缺少分类的独立组。
    func groups(by dimension: Dimension, members: Members) -> [String?: [Int64]] {
        let candidates: [Int64]
        switch members {
        case .current: candidates = currentMembers.map(\.id)
        case .starredInPeriod: candidates = starredRepoIDs.sorted()
        }
        let metadata = Dictionary(uniqueKeysWithValues: repositories.map { ($0.id, $0) })
        var groups: [String?: [Int64]] = [:]
        for id in candidates {
            let repo = metadata[id]
            let names: [String]
            switch dimension {
            case .topic: names = repo?.topics ?? []
            case .userTag: names = repo?.tags ?? []
            case .language: names = [repo?.language].compactMap { $0 }.filter { !$0.isEmpty }
            }
            if names.isEmpty { groups[nil, default: []].append(id) }
            for name in names { groups[name, default: []].append(id) }
        }
        return groups
    }

    /// 分享样例采用计数白名单，避免将私仓 ID、私人标签和仓库轨迹带入公开输出。
    struct ShareCounts: Codable {
        let starActions: Int?
        let distinctStarredRepos: Int?
        let reposWithWriting: Int?
        let starCoverage: Coverage
        let localCoverage: Coverage
    }

    var shareCounts: ShareCounts {
        ShareCounts(starActions: starEvents.isEmpty ? nil : starEvents.count,
                    distinctStarredRepos: starredRepoIDs.isEmpty ? nil : starredRepoIDs.count,
                    reposWithWriting: writtenRepoIDs.isEmpty && localCoverage != .complete ? nil : writtenRepoIDs.count,
                    starCoverage: starCoverage, localCoverage: localCoverage)
    }
}

/// 通过账号专属数据库读取。自然年、月份等窗口都走相同的半开区间查询。
struct KnowledgeProfileFactsProvider {
    let database: any DatabaseManaging

    enum QueryError: Error { case invalidPeriod, accountChanged, missingCoverage }

    /// 两个现有洞察范围也使用此 SQL。先统计全部成员，显示数量仍由各页面决定。
    static func topicCountsSQL(scope: InsightsScope) -> String {
        """
        SELECT \(topicNameSQL) AS name, COUNT(DISTINCT r.id) AS count
        FROM repos r LEFT JOIN repo_notes n ON n.repo_id = r.id
        JOIN \(topicRowsSQL) topic
        WHERE \(memberPredicate(scope)) AND \(topicFilterSQL)
        GROUP BY \(topicNameSQL) ORDER BY count DESC, name COLLATE NOCASE ASC
        """
    }

    private static let topicNameSQL = "LOWER(TRIM(topic.value))"
    private static let topicRowsSQL = "json_each(CASE WHEN json_valid(r.topics) THEN r.topics ELSE '[]' END)"
    private static let topicFilterSQL = "topic.type = 'text' AND TRIM(topic.value) != ''"

    private static func memberPredicate(_ scope: InsightsScope) -> String {
        scope == .starred ? "r.is_starred = 1" : "n.library_state = 'in_library'"
    }

    func annual(year: Int, timeZone: TimeZone, accountID: Int64, scope: InsightsScope,
                cutoff: Date = Date()) async throws -> KnowledgeProfileFacts {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard (1...9999).contains(year),
              let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let window = calendar.dateInterval(of: .year, for: start) else { throw QueryError.invalidPeriod }
        return try await fetch(window: window, timeZone: timeZone, accountID: accountID, scope: scope, cutoff: cutoff)
    }

    /// 与切号在 MainActor 上取得同一对账号和 writer，所有事实来自一次只读事务。
    @MainActor
    func fetch(window: DateInterval, timeZone: TimeZone, accountID: Int64, scope: InsightsScope,
               cutoff: Date) async throws -> KnowledgeProfileFacts {
        guard window.duration > 0 else { throw QueryError.invalidPeriod }
        guard database.currentUserId == accountID else { throw QueryError.accountChanged }
        let facts = try await database.writer.read { db in
            let classifiedAt = Date()
            let asOf = min(cutoff, classifiedAt)
            guard let started = try Double.fetchOne(db, sql: "SELECT started_at FROM knowledge_activity_coverage WHERE id = 1")
            else { throw QueryError.missingCoverage }
            let localStart = Date(timeIntervalSince1970: started)
            let localCoverage: KnowledgeProfileFacts.Coverage
            if window.start > asOf || localStart >= window.end || localStart > asOf {
                localCoverage = .unknown
            } else {
                localCoverage = localStart <= window.start ? .complete : .partial
            }
            let events = try Self.events(db, window: window, cutoff: asOf, accountID: accountID)
            let repositories = try Self.repositories(db, scope: scope, eventIDs: Set(events.map(\.repoID)))
            return KnowledgeProfileFacts(
                rulesVersion: 1, accountID: accountID, scope: scope.rawValue, window: window,
                timeZoneID: timeZone.identifier, cutoff: asOf, classifiedAt: classifiedAt,
                localCollectionStartedAt: localStart, localCoverage: localCoverage,
                starCoverage: events.contains { $0.action == .star || $0.action == .unstar } ? .partial : .unknown,
                events: events, repositories: repositories)
        }
        guard database.currentUserId == accountID else { throw QueryError.accountChanged }
        return facts
    }

    /// 当前关系仅补足账本缺少的收藏，本地动作始终使用动作发生时间。
    private static func events(_ db: Database, window: DateInterval, cutoff: Date,
                               accountID: Int64) throws -> [KnowledgeProfileFacts.Event] {
        let rows = try Row.fetchAll(db, sql: """
            WITH dated_stars AS (
                SELECT repo_id, kind, source, occurred_at, id, full_name FROM user_repo_activity
                WHERE kind IN ('star', 'unstar') AND (user_id = :user OR user_id IS NULL)
                UNION ALL
                SELECT sr.repo_id, 'star', 'currentStar', sr.starred_at, '', r.full_name FROM starred_repos sr
                JOIN repos r ON r.id = sr.repo_id AND r.is_starred = 1 WHERE sr.user_id = :user
                  AND \(GRDBUserRepoActivityRepository.unrecordedCurrentStarSQL)
            ), actions AS (
                SELECT repo_id, kind, source, unixepoch(occurred_at, 'subsec') AS seconds, id AS tie, full_name
                FROM dated_stars
                UNION ALL
                SELECT repo_id, kind, source, occurred_at, id, NULL FROM knowledge_activity
                WHERE occurred_at >= :start AND occurred_at < :end AND occurred_at <= :cutoff
            )
            SELECT * FROM actions WHERE seconds >= :start AND seconds < :end AND seconds <= :cutoff
            ORDER BY seconds DESC, repo_id ASC, tie DESC
            """, arguments: ["user": accountID, "start": window.start.timeIntervalSince1970,
                             "end": window.end.timeIntervalSince1970, "cutoff": cutoff.timeIntervalSince1970])
        return rows.compactMap { row in
            guard let action = KnowledgeAction(rawValue: row["kind"]),
                  let source = KnowledgeActionSource(rawValue: row["source"]) else { return nil }
            return .init(repoID: row["repo_id"], fullName: row["full_name"], action: action, source: source,
                         date: Date(timeIntervalSince1970: row["seconds"]))
        }
    }

    /// 按仓库取生成时分类。历史集合保留当前已取消收藏的仓库；主题数组不受 UI 的 Top N 限制。
    private static func repositories(_ db: Database, scope: InsightsScope,
                                     eventIDs: Set<Int64>) throws -> [KnowledgeProfileFacts.Repository] {
        let ids = String(decoding: try JSONEncoder().encode(eventIDs), as: UTF8.self)
        let rows = try Row.fetchAll(db, sql: """
            SELECT r.id, r.full_name, TRIM(r.language) AS language, r.is_starred, n.library_state, n.status, n.is_ai_generated,
                   \(KnowledgeActivity.nonemptyNoteSQL) AS has_note,
                   EXISTS(SELECT 1 FROM ai_summaries s WHERE s.repo_id = r.id) AS has_summary,
                   (SELECT json_group_array(name) FROM (
                       SELECT DISTINCT \(topicNameSQL) AS name FROM \(topicRowsSQL) topic
                       WHERE \(topicFilterSQL) ORDER BY name)) AS topics,
                   (SELECT json_group_array(name) FROM (
                       SELECT t.name FROM repo_tags rt JOIN tags t ON t.id = rt.tag_id
                       WHERE rt.repo_id = r.id ORDER BY t.name)) AS tags
            FROM repos r LEFT JOIN repo_notes n ON n.repo_id = r.id
            WHERE \(memberPredicate(scope)) OR r.id IN (SELECT value FROM json_each(?))
            ORDER BY r.id
            """, arguments: [ids])
        let decoder = JSONDecoder()
        return try rows.map { row in
            let hasNote: Bool = row["has_note"]
            let ai: Bool? = row["is_ai_generated"]
            let topics: String = row["topics"]
            let tags: String = row["tags"]
            return try .init(id: row["id"], fullName: row["full_name"], language: row["language"],
                             topics: decoder.decode([String].self, from: Data(topics.utf8)),
                             tags: decoder.decode([String].self, from: Data(tags.utf8)),
                             starred: row["is_starred"], inLibrary: row["library_state"] as String? == "in_library",
                             using: row["status"] as String? == "using", note: hasNote ? (ai == true ? .ai : .manual) : .none,
                             hasSummary: row["has_summary"])
        }
    }
}
