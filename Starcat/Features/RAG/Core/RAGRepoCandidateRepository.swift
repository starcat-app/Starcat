//
//  RAGRepoCandidateRepository.swift
//  Starcat
//
//  Query Planner 结构化条件的本地 SQL 执行器。
//
//  所有查询固定从知识库关系表出发。动态 SQL 只拼接预定义列和操作符，用户值全部走
//  StatementArguments，避免模型输出进入 SQL 结构位置。
//

import Foundation
import GRDB

protocol RAGRepoCandidateRepositoryProtocol: Sendable {
    func fetchCandidates(
        plan: RAGQueryPlan,
        explicitRepoIDs: [Int64],
        explicitMode: RAGExplicitRepoMode
    ) async throws -> [RAGRepoCandidate]

    /// 知识库浏览器左侧列表专用分页；与 Planner 候选查询解耦，避免 semantic_only 全库哨兵 LIMIT。
    func fetchKnowledgeBrowserPage(limit: Int, offset: Int) async throws -> RAGRepoCandidatePage
    /// Composer 上下文选择器专用轻量投影；大库按关键词 + 面板排序/筛选分页。
    func fetchMentionCandidates(
        query: String,
        limit: Int,
        offset: Int,
        sort: RepoSortOption,
        filters: RAGComposerMentionFilters
    ) async throws -> RAGMentionCandidatePage
    /// 用户确认选择后才批量回填完整 Repo，避免 picker 初次打开就解码全库完整行。
    func fetchMentionRepos(ids: [Int64]) async throws -> [Repo]
}

/// 知识库浏览器仓库列表一页；`hasMore` 由 `limit + 1` 哨兵判定。
struct RAGRepoCandidatePage: Equatable, Sendable {
    var candidates: [RAGRepoCandidate]
    var hasMore: Bool
}

struct RAGMentionCandidatePage: Equatable, Sendable {
    var candidates: [RAGMentionCandidate]
    var knowledgeCount: Int
    var matchCount: Int
    var hasMore: Bool
}

struct GRDBRAGRepoCandidateRepository: RAGRepoCandidateRepositoryProtocol {
    private let database: any DatabaseManaging

    init(database: any DatabaseManaging) {
        self.database = database
    }

    func fetchMentionCandidates(
        query: String,
        limit: Int,
        offset: Int,
        sort: RepoSortOption = RAGComposerMentionSort.default,
        filters: RAGComposerMentionFilters = .empty
    ) async throws -> RAGMentionCandidatePage {
        precondition(limit > 0 && offset >= 0)
        // Wiki 可用性在 DiskWikiCache（MainActor），本仓库只下推 SQLite 可表达的条件。
        var sqlFilters = filters
        sqlFilters.wikiAvailability = .unknown
        return try await fetchMentionCandidatesSQL(
            query: query,
            limit: limit,
            offset: offset,
            sort: sort,
            filters: sqlFilters
        )
    }

    private func fetchMentionCandidatesSQL(
        query: String,
        limit: Int,
        offset: Int,
        sort: RepoSortOption,
        filters: RAGComposerMentionFilters
    ) async throws -> RAGMentionCandidatePage {
        return try await database.writer.read { db in
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let pattern = "%\(Self.escapeLike(trimmed))%"
            let searchPredicate = """
                (r.full_name LIKE ? ESCAPE '\\' COLLATE NOCASE
                 OR COALESCE(r.description, '') LIKE ? ESCAPE '\\' COLLATE NOCASE
                 OR COALESCE(r.language, '') LIKE ? ESCAPE '\\' COLLATE NOCASE
                 OR COALESCE(r.topics, '') LIKE ? ESCAPE '\\' COLLATE NOCASE
                 OR n.status LIKE ? ESCAPE '\\' COLLATE NOCASE
                 OR COALESCE(n.content, '') LIKE ? ESCAPE '\\' COLLATE NOCASE
                 OR EXISTS (
                     SELECT 1 FROM repo_tags rt JOIN tags t ON t.id = rt.tag_id
                     WHERE rt.repo_id = r.id AND t.name LIKE ? ESCAPE '\\' COLLATE NOCASE
                 )
                 OR EXISTS (
                     SELECT 1 FROM ai_summaries summary
                     WHERE summary.repo_id = r.id
                       AND summary.summary_json LIKE ? ESCAPE '\\' COLLATE NOCASE
                 ))
                """

            var predicates = ["n.library_state = 'in_library'"]
            var arguments: [any DatabaseValueConvertible] = []
            if !trimmed.isEmpty {
                predicates.append(searchPredicate)
                arguments.append(contentsOf: Array(repeating: pattern as any DatabaseValueConvertible, count: 8))
            }
            Self.appendMentionFilters(filters, predicates: &predicates, arguments: &arguments)

            let whereClause = predicates.joined(separator: " AND ")
            let knowledgeCount = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM repos r
                JOIN repo_notes n ON n.repo_id = r.id
                WHERE n.library_state = 'in_library'
                """) ?? 0
            let matchCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM repos r JOIN repo_notes n ON n.repo_id = r.id WHERE \(whereClause)",
                arguments: StatementArguments(arguments)
            ) ?? 0

            var joins: [String] = []
            if sort == .healthScoreDesc {
                joins.append("LEFT JOIN repo_health_snapshots h_sort ON h_sort.repo_id = r.id")
            } else if sort == .openSSFScoreDesc {
                joins.append(
                    "LEFT JOIN open_ssf_scores ossf_sort ON ossf_sort.repo_id = r.id AND ossf_sort.fetch_status = 'success'"
                )
            }
            let joinSQL = joins.isEmpty ? "" : " " + joins.joined(separator: " ")
            let orderBy = Self.mentionOrderClause(sort)

            var pageArguments = arguments
            pageArguments.append(limit + 1)
            pageArguments.append(offset)
            let rows = try Row.fetchAll(db, sql: """
                SELECT r.id, r.owner, r.name, r.full_name, r.description, r.language,
                       r.stars_count, r.owner_avatar, r.topics, n.status,
                       COALESCE((
                           SELECT GROUP_CONCAT(t.name, '\u{1F}')
                           FROM repo_tags rt JOIN tags t ON t.id = rt.tag_id
                           WHERE rt.repo_id = r.id
                       ), '') AS tag_names
                FROM repos r
                JOIN repo_notes n ON n.repo_id = r.id
                \(joinSQL)
                WHERE \(whereClause)
                ORDER BY \(orderBy)
                LIMIT ? OFFSET ?
                """, arguments: StatementArguments(pageArguments))
            let candidates = rows.prefix(limit).map(RAGMentionCandidate.init(row:))
            return RAGMentionCandidatePage(
                candidates: candidates,
                knowledgeCount: knowledgeCount,
                matchCount: matchCount,
                hasMore: rows.count > limit
            )
        }
    }

    private static func appendMentionFilters(
        _ filters: RAGComposerMentionFilters,
        predicates: inout [String],
        arguments: inout [any DatabaseValueConvertible]
    ) {
        if filters.hideArchived {
            predicates.append("r.is_archived = 0")
        }
        if filters.hideForks {
            predicates.append("r.is_fork = 0")
        }
        switch filters.star {
        case .all:
            break
        case .starred:
            predicates.append("r.is_starred = 1")
        case .unstarred:
            predicates.append("r.is_starred = 0")
        }
        if let status = filters.status {
            if status == .unread {
                predicates.append("COALESCE(n.status, 'unread') = ?")
            } else {
                predicates.append("n.status = ?")
            }
            arguments.append(status.rawValue)
        }
        let languages = filters.selectedLanguages
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !languages.isEmpty {
            let placeholders = Array(repeating: "?", count: languages.count).joined(separator: ", ")
            predicates.append("r.language IN (\(placeholders))")
            arguments.append(contentsOf: languages.sorted())
        }
        switch filters.healthAvailability {
        case .unknown:
            break
        case .available:
            predicates.append("""
                EXISTS (
                    SELECT 1 FROM repo_health_snapshots h_filter
                    WHERE h_filter.repo_id = r.id
                      AND h_filter.fetch_status != 'failed'
                )
                """)
        case .missing:
            predicates.append("""
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
            predicates.append("""
                EXISTS (
                    SELECT 1 FROM open_ssf_scores ossf_filter
                    WHERE ossf_filter.repo_id = r.id
                      AND ossf_filter.fetch_status = 'success'
                      AND ossf_filter.aggregate_score IS NOT NULL
                )
                """)
        case .missing:
            predicates.append("""
                NOT EXISTS (
                    SELECT 1 FROM open_ssf_scores ossf_filter
                    WHERE ossf_filter.repo_id = r.id
                      AND ossf_filter.fetch_status = 'success'
                      AND ossf_filter.aggregate_score IS NOT NULL
                )
                """)
        }
    }

    private static func mentionOrderClause(_ sort: RepoSortOption) -> String {
        switch sort {
        case .starredAtDesc:
            return "COALESCE(r.starred_at, n.library_updated_at, r.cached_at) DESC, r.id DESC"
        case .starredAtAsc:
            return "r.starred_at IS NULL ASC, r.starred_at ASC, r.id ASC"
        case .nameAsc:
            return "LOWER(r.full_name) ASC, r.id ASC"
        case .nameDesc:
            return "LOWER(r.full_name) DESC, r.id DESC"
        case .starsDesc:
            return "r.stars_count DESC, r.full_name COLLATE NOCASE ASC"
        case .starsAsc:
            return "r.stars_count ASC, r.full_name COLLATE NOCASE ASC"
        case .updatedDesc:
            return "r.pushed_at DESC, r.id DESC"
        case .updatedAsc:
            return "r.pushed_at IS NULL ASC, r.pushed_at ASC, r.id ASC"
        case .createdDesc:
            return "r.created_at DESC, r.id DESC"
        case .createdAsc:
            return "r.created_at IS NULL ASC, r.created_at ASC, r.id ASC"
        case .healthScoreDesc:
            return "h_sort.repo_id IS NULL ASC, h_sort.overall_score DESC, r.stars_count DESC, r.id DESC"
        case .openSSFScoreDesc:
            return "ossf_sort.aggregate_score IS NULL ASC, ossf_sort.aggregate_score DESC, r.stars_count DESC, r.id DESC"
        }
    }

    func fetchMentionRepos(ids: [Int64]) async throws -> [Repo] {
        guard !ids.isEmpty else { return [] }
        return try await database.writer.read { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let repos = try Repo.fetchAll(
                db,
                sql: """
                    SELECT r.* FROM repos r
                    JOIN repo_notes n ON n.repo_id = r.id AND n.library_state = 'in_library'
                    WHERE r.id IN (\(placeholders))
                    """,
                arguments: StatementArguments(ids)
            )
            let byID = Dictionary(uniqueKeysWithValues: repos.map { ($0.id, $0) })
            return ids.compactMap { byID[$0] }
        }
    }

    private static func escapeLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    func fetchCandidates(
        plan: RAGQueryPlan,
        explicitRepoIDs: [Int64],
        explicitMode: RAGExplicitRepoMode
    ) async throws -> [RAGRepoCandidate] {
        try await database.writer.read { db in
            var predicates = ["n.library_state = 'in_library'"]
            var arguments: [any DatabaseValueConvertible] = []
            let filters = plan.filters

            if let status = filters.status {
                predicates.append("n.status = ?")
                arguments.append(status.rawValue)
            }
            appendStringSet(filters.languages, column: "r.language", predicates: &predicates, arguments: &arguments)
            appendStringSet(filters.licenses, column: "r.license", predicates: &predicates, arguments: &arguments)
            appendBound(filters.minStars, column: "r.stars_count", operation: ">=", predicates: &predicates, arguments: &arguments)
            appendBound(filters.maxStars, column: "r.stars_count", operation: "<=", predicates: &predicates, arguments: &arguments)
            appendBound(filters.minForks, column: "r.forks_count", operation: ">=", predicates: &predicates, arguments: &arguments)
            appendBound(filters.maxForks, column: "r.forks_count", operation: "<=", predicates: &predicates, arguments: &arguments)
            if filters.includeArchived == false { predicates.append("r.is_archived = 0") }
            if filters.includeForks == false { predicates.append("r.is_fork = 0") }

            appendDate(filters.starredAfter, column: "r.starred_at", operation: ">=", predicates: &predicates, arguments: &arguments)
            appendDate(filters.starredBefore, column: "r.starred_at", operation: "<=", predicates: &predicates, arguments: &arguments)
            appendDate(filters.libraryUpdatedAfter, column: "n.library_updated_at", operation: ">=", predicates: &predicates, arguments: &arguments)
            appendDate(filters.libraryUpdatedBefore, column: "n.library_updated_at", operation: "<=", predicates: &predicates, arguments: &arguments)
            appendDate(filters.repoCreatedAfter, column: "r.created_at", operation: ">=", predicates: &predicates, arguments: &arguments)
            appendDate(filters.repoCreatedBefore, column: "r.created_at", operation: "<=", predicates: &predicates, arguments: &arguments)
            appendDate(filters.pushedAfter, column: "r.pushed_at", operation: ">=", predicates: &predicates, arguments: &arguments)
            appendDate(filters.pushedBefore, column: "r.pushed_at", operation: "<=", predicates: &predicates, arguments: &arguments)

            for tagName in filters.tags where !tagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                predicates.append("EXISTS (SELECT 1 FROM repo_tags rt JOIN tags t ON t.id = rt.tag_id WHERE rt.repo_id = r.id AND t.name = ? COLLATE NOCASE)")
                arguments.append(tagName)
            }

            if !explicitRepoIDs.isEmpty, explicitMode != .prefer {
                let placeholders = Array(repeating: "?", count: explicitRepoIDs.count).joined(separator: ",")
                predicates.append("r.id \(explicitMode == .only ? "IN" : "NOT IN") (\(placeholders))")
                arguments.append(contentsOf: explicitRepoIDs)
            }

            // semantic_only 且 Planner 未指定 limit 时必须覆盖整个知识库；显式 limit 仍钳制
            // 到 1000，避免模型输出异常大值。100_000 仅作为 SQLite LIMIT 的实际无上限哨兵。
            let limit: Int
            if plan.mode == .semanticOnly, plan.candidateLimit == nil {
                limit = 100_000
            } else {
                limit = min(max(plan.candidateLimit ?? defaultLimit(for: plan.mode), 1), 1_000)
            }
            arguments.append(limit)
            let rows = try Row.fetchAll(db, sql: """
                SELECT r.*, n.status AS rag_status, n.library_updated_at AS rag_library_updated_at,
                       COALESCE((
                           SELECT GROUP_CONCAT(t.name, '\u{1F}')
                           FROM repo_tags rt JOIN tags t ON t.id = rt.tag_id
                           WHERE rt.repo_id = r.id
                       ), '') AS rag_tag_names
                FROM repos r
                JOIN repo_notes n ON n.repo_id = r.id
                WHERE \(predicates.joined(separator: " AND "))
                ORDER BY \(orderClause(plan.sort))
                LIMIT ?
                """, arguments: StatementArguments(arguments))

            return try rows.map(Self.mapCandidate(row:))
        }
    }

    func fetchKnowledgeBrowserPage(limit: Int, offset: Int) async throws -> RAGRepoCandidatePage {
        precondition(limit > 0 && offset >= 0)
        return try await database.writer.read { db in
            // 与主列表一致：star 数降序，同星再按 full_name；LIMIT+1 判定是否还有下一页。
            let rows = try Row.fetchAll(db, sql: """
                SELECT r.*, n.status AS rag_status, n.library_updated_at AS rag_library_updated_at,
                       COALESCE((
                           SELECT GROUP_CONCAT(t.name, '\u{1F}')
                           FROM repo_tags rt JOIN tags t ON t.id = rt.tag_id
                           WHERE rt.repo_id = r.id
                       ), '') AS rag_tag_names
                FROM repos r
                JOIN repo_notes n ON n.repo_id = r.id
                WHERE n.library_state = 'in_library'
                ORDER BY r.stars_count DESC, r.full_name COLLATE NOCASE ASC
                LIMIT ? OFFSET ?
                """, arguments: [limit + 1, offset])
            let mapped = try rows.map(Self.mapCandidate(row:))
            return RAGRepoCandidatePage(
                candidates: Array(mapped.prefix(limit)),
                hasMore: mapped.count > limit
            )
        }
    }

    private static func mapCandidate(row: Row) throws -> RAGRepoCandidate {
        let rawStatus: String = row["rag_status"]
        let tagString: String = row["rag_tag_names"]
        return RAGRepoCandidate(
            repo: try Repo(row: row),
            status: RepoStatus.parse(rawStatus),
            libraryUpdatedAt: row["rag_library_updated_at"],
            tagNames: tagString.isEmpty ? [] : tagString.components(separatedBy: "\u{1F}")
        )
    }

    private func defaultLimit(for mode: RAGQueryMode) -> Int {
        switch mode {
        // structured_only 可能是计数/统计问题，默认 50 会把“共多少个”错误截断为 50。
        // Prompt 层只展开预算内的前 50 行，但保留这里的完整候选计数。
        case .structuredOnly: return 1_000
        case .filteredSemantic: return 200
        case .semanticOnly, .guidedDiscovery, .needsClarification: return 1_000
        }
    }

    private func appendStringSet(
        _ values: [String],
        column: String,
        predicates: inout [String],
        arguments: inout [any DatabaseValueConvertible]
    ) {
        let values = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !values.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: values.count).joined(separator: ",")
        predicates.append("\(column) COLLATE NOCASE IN (\(placeholders))")
        arguments.append(contentsOf: values)
    }

    private func appendBound(
        _ value: Int?,
        column: String,
        operation: String,
        predicates: inout [String],
        arguments: inout [any DatabaseValueConvertible]
    ) {
        guard let value else { return }
        predicates.append("\(column) \(operation) ?")
        arguments.append(max(value, 0))
    }

    private func appendDate(
        _ value: Date?,
        column: String,
        operation: String,
        predicates: inout [String],
        arguments: inout [any DatabaseValueConvertible]
    ) {
        guard let value else { return }
        predicates.append("\(column) \(operation) ?")
        arguments.append(ISO8601DateFormatter.shared.string(from: value))
    }

    private func orderClause(_ sort: RAGRepoSort?) -> String {
        guard let sort else { return "r.stars_count DESC, r.full_name COLLATE NOCASE ASC" }
        let column: String
        switch sort.field {
        case .stars: column = "r.stars_count"
        case .forks: column = "r.forks_count"
        case .pushedAt: column = "r.pushed_at"
        case .repoCreatedAt: column = "r.created_at"
        case .libraryUpdatedAt: column = "n.library_updated_at"
        case .starredAt: column = "r.starred_at"
        }
        return "\(column) \(sort.direction == .ascending ? "ASC" : "DESC"), r.full_name COLLATE NOCASE ASC"
    }
}
