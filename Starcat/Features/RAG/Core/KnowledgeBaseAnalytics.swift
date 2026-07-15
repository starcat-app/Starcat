//
//  KnowledgeBaseAnalytics.swift
//  Starcat
//
//  知识库 RAG 的受限结构化分析 DSL 与本地执行器。
//
//  模型只能选择本文件定义的业务字段、指标和排序方式，绝不能传入表名、列名、SQL
//  片段或 Join。执行器将每个枚举值映射为固定 SQL，所有实际筛选值仍走 GRDB 参数绑定。
//

import Foundation
import GRDB

/// Planner 可请求的聚合维度。`repository` 用于“Star 最高的项目”这类逐项目排行。
enum KnowledgeBaseAnalyticsDimension: String, Codable, Equatable, Sendable {
    case repository
    case language
    case status
    case tag
}

/// 固定指标集合；不开放自由表达式，避免模型把计算逻辑注入到 SQL 结构中。
enum KnowledgeBaseAnalyticsMeasure: String, Codable, Equatable, Sendable {
    case count
    case maxStars = "max_stars"
    case averageStars = "average_stars"
    case maxForks = "max_forks"
    case averageForks = "average_forks"
    /// 库存与索引诊断指标只支持全库单值统计；其 SQL 仍由本地固定映射执行。
    case repositoriesWithAISummary = "repositories_with_ai_summary"
    case repositoriesWithPrivateNotes = "repositories_with_private_notes"
    case repositoriesWithAIGeneratedNotes = "repositories_with_ai_generated_notes"
    case repositoriesWithRecentlyEditedPrivateNotes = "repositories_with_recently_edited_private_notes"
    case repositoriesWithRecentlyGeneratedAISummaries = "repositories_with_recently_generated_ai_summaries"
    case excludedRAGChunks = "excluded_rag_chunks"
    case repositoriesWithoutREADME = "repositories_without_readme"
    case repositoriesWithoutIndexableSource = "repositories_without_indexable_source"

    var requiresSingleAggregateResult: Bool {
        switch self {
        case .repositoriesWithAISummary,
             .repositoriesWithPrivateNotes,
             .repositoriesWithAIGeneratedNotes,
             .repositoriesWithRecentlyEditedPrivateNotes,
             .repositoriesWithRecentlyGeneratedAISummaries,
             .excludedRAGChunks,
             .repositoriesWithoutREADME,
             .repositoriesWithoutIndexableSource:
            true
        case .count, .maxStars, .averageStars, .maxForks, .averageForks:
            false
        }
    }
}

enum KnowledgeBaseAnalyticsSortDirection: String, Codable, Equatable, Sendable {
    case ascending = "asc"
    case descending = "desc"
}

/// 一个稳定的业务分析计划。没有维度时返回全库单值统计；有维度时返回分组或排行。
struct KnowledgeBaseAnalyticsPlan: Codable, Equatable, Sendable {
    var dimension: KnowledgeBaseAnalyticsDimension?
    var measure: KnowledgeBaseAnalyticsMeasure
    var direction: KnowledgeBaseAnalyticsSortDirection
    var limit: Int

    init(
        dimension: KnowledgeBaseAnalyticsDimension? = nil,
        measure: KnowledgeBaseAnalyticsMeasure,
        direction: KnowledgeBaseAnalyticsSortDirection = .descending,
        limit: Int = 10
    ) {
        self.dimension = dimension
        self.measure = measure
        self.direction = direction
        self.limit = limit
    }

    func validated() throws -> Self {
        // 单值聚合不需要多行，固定为 1；分组结果也绝不允许模型枚举整个知识库。
        var result = self
        if measure.requiresSingleAggregateResult, dimension != nil {
            throw RAGQueryPlannerError.invalidPlan("库存统计不支持分组维度")
        }
        result.limit = dimension == nil ? 1 : min(max(limit, 1), 100)
        return result
    }
}

/// 已执行分析的结果。它是数据库事实，不是分片证据，因此 Generator 不得伪造 S 引用。
struct KnowledgeBaseAnalyticsResult: Equatable, Sendable {
    struct Row: Equatable, Sendable {
        var dimensionValue: String?
        var value: Double
    }

    var plan: KnowledgeBaseAnalyticsPlan
    var rows: [Row]

    func promptContext() -> String {
        let dimension = plan.dimension?.rawValue ?? "all_in_library_repositories"
        let renderedRows: [String] = rows.map { row -> String in
            let label = row.dimensionValue ?? "all"
            return "\(label): \(Self.renderedNumber(row.value))"
        }
        let rows = renderedRows.joined(separator: "; ")
        return """
        Authoritative local structured analytics result (not vector-search evidence):
        - Scope: in-library repositories only.
        - Dimension: \(dimension); measure: \(plan.measure.rawValue); order: \(plan.direction.rawValue); limit: \(plan.limit).
        - Result rows: [\(rows)].
        Use these exact database results for this analysis question. Do not fabricate chunk citations for them.
        """
    }

    private static func renderedNumber(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
    }
}

protocol KnowledgeBaseAnalyticsExecuting: Sendable {
    func execute(plan: KnowledgeBaseAnalyticsPlan, filters: RAGRepoFilter) async throws -> KnowledgeBaseAnalyticsResult
}

/// 将 DSL 编译为固定 SQL。动态部分仅来自本文件枚举的 switch；用户/模型值永不拼入 SQL。
struct KnowledgeBaseAnalyticsExecutor: KnowledgeBaseAnalyticsExecuting {
    private let database: any DatabaseManaging

    init(database: any DatabaseManaging) {
        self.database = database
    }

    func execute(plan: KnowledgeBaseAnalyticsPlan, filters: RAGRepoFilter) async throws -> KnowledgeBaseAnalyticsResult {
        let plan = try plan.validated()
        return try await database.writer.read { db in
            var predicates = ["n.library_state = 'in_library'"]
            var arguments: [any DatabaseValueConvertible] = []
            appendFilters(filters, predicates: &predicates, arguments: &arguments)

            let dimension = dimensionSQL(plan.dimension)
            let measure = measureSQL(plan.measure)
            let groupBy = dimension.groupBy.map { " GROUP BY \($0)" } ?? ""
            let direction = plan.direction == .ascending ? "ASC" : "DESC"
            arguments.append(plan.limit)
            let rows = try Row.fetchAll(db, sql: """
                SELECT \(dimension.select), \(measure) AS metric
                FROM repos r
                JOIN repo_notes n ON n.repo_id = r.id
                \(dimension.join)
                WHERE \(predicates.joined(separator: " AND "))
                \(groupBy)
                ORDER BY metric \(direction), dimension_value COLLATE NOCASE ASC
                LIMIT ?
                """, arguments: StatementArguments(arguments))
            return KnowledgeBaseAnalyticsResult(
                plan: plan,
                rows: rows.map { row in
                    .init(dimensionValue: row["dimension_value"], value: row["metric"])
                }
            )
        }
    }

    private func dimensionSQL(_ dimension: KnowledgeBaseAnalyticsDimension?) -> (select: String, join: String, groupBy: String?) {
        switch dimension {
        case .repository:
            return ("r.full_name AS dimension_value", "", "r.id, r.full_name")
        case .language:
            return ("COALESCE(NULLIF(TRIM(r.language), ''), 'Unknown') AS dimension_value", "", "COALESCE(NULLIF(TRIM(r.language), ''), 'Unknown')")
        case .status:
            return ("COALESCE(NULLIF(TRIM(n.status), ''), 'unclassified') AS dimension_value", "", "COALESCE(NULLIF(TRIM(n.status), ''), 'unclassified')")
        case .tag:
            return ("t.name AS dimension_value", "JOIN repo_tags rt ON rt.repo_id = r.id JOIN tags t ON t.id = rt.tag_id", "t.id, t.name")
        case nil:
            return ("NULL AS dimension_value", "", nil)
        }
    }

    private func measureSQL(_ measure: KnowledgeBaseAnalyticsMeasure) -> String {
        switch measure {
        case .count: return "COUNT(DISTINCT r.id)"
        case .maxStars: return "MAX(r.stars_count)"
        case .averageStars: return "AVG(r.stars_count)"
        case .maxForks: return "MAX(r.forks_count)"
        case .averageForks: return "AVG(r.forks_count)"
        case .repositoriesWithAISummary:
            return "COUNT(DISTINCT CASE WHEN EXISTS (SELECT 1 FROM ai_summaries s WHERE s.repo_id = r.id) THEN r.id END)"
        case .repositoriesWithPrivateNotes:
            return "COUNT(DISTINCT CASE WHEN NULLIF(TRIM(n.content), '') IS NOT NULL THEN r.id END)"
        case .repositoriesWithAIGeneratedNotes:
            return "COUNT(DISTINCT CASE WHEN NULLIF(TRIM(n.content), '') IS NOT NULL AND n.is_ai_generated = 1 THEN r.id END)"
        case .repositoriesWithRecentlyEditedPrivateNotes:
            return "COUNT(DISTINCT CASE WHEN NULLIF(TRIM(n.content), '') IS NOT NULL AND datetime(n.edited_at) >= datetime('now', '-30 days') THEN r.id END)"
        case .repositoriesWithRecentlyGeneratedAISummaries:
            return "COUNT(DISTINCT CASE WHEN EXISTS (SELECT 1 FROM ai_summaries s WHERE s.repo_id = r.id AND datetime(s.generated_at) >= datetime('now', '-30 days')) THEN r.id END)"
        case .excludedRAGChunks:
            return "SUM((SELECT COUNT(*) FROM rag_chunks c JOIN rag_chunk_overrides o ON o.chunk_id = c.id AND o.is_excluded = 1 WHERE c.repo_id = r.id))"
        case .repositoriesWithoutREADME:
            return "COUNT(DISTINCT CASE WHEN NOT EXISTS (SELECT 1 FROM rag_chunks c WHERE c.repo_id = r.id AND c.source = 'readme') THEN r.id END)"
        case .repositoriesWithoutIndexableSource:
            return "COUNT(DISTINCT CASE WHEN NOT EXISTS (SELECT 1 FROM rag_chunks c WHERE c.repo_id = r.id AND NOT EXISTS (SELECT 1 FROM rag_chunk_overrides o WHERE o.chunk_id = c.id AND o.is_excluded = 1)) THEN r.id END)"
        }
    }

    private func appendFilters(
        _ filters: RAGRepoFilter,
        predicates: inout [String],
        arguments: inout [any DatabaseValueConvertible]
    ) {
        if let status = filters.status { predicates.append("n.status = ?"); arguments.append(status.rawValue) }
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
        for tag in filters.tags.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).filter({ !$0.isEmpty }) {
            predicates.append("EXISTS (SELECT 1 FROM repo_tags filter_rt JOIN tags filter_t ON filter_t.id = filter_rt.tag_id WHERE filter_rt.repo_id = r.id AND filter_t.name = ? COLLATE NOCASE)")
            arguments.append(tag)
        }
    }

    private func appendStringSet(_ values: [String], column: String, predicates: inout [String], arguments: inout [any DatabaseValueConvertible]) {
        let values = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !values.isEmpty else { return }
        predicates.append("\(column) COLLATE NOCASE IN (\(Array(repeating: "?", count: values.count).joined(separator: ",")))")
        arguments.append(contentsOf: values)
    }

    private func appendBound(_ value: Int?, column: String, operation: String, predicates: inout [String], arguments: inout [any DatabaseValueConvertible]) {
        guard let value else { return }
        predicates.append("\(column) \(operation) ?")
        arguments.append(max(value, 0))
    }

    private func appendDate(_ value: Date?, column: String, operation: String, predicates: inout [String], arguments: inout [any DatabaseValueConvertible]) {
        guard let value else { return }
        predicates.append("\(column) \(operation) ?")
        arguments.append(ISO8601DateFormatter.shared.string(from: value))
    }
}
