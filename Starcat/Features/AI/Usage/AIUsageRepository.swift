//
//  AIUsageRepository.swift
//  Starcat
//
//  AI 用量事件的 GRDB 写入与基础读取入口。
//

import Foundation
import GRDB

protocol AIUsageRepositoryProtocol: Sendable {
    func insert(_ event: AIUsageEvent) async throws
    func fetchRecent(limit: Int) async throws -> [AIUsageEvent]
    func summary(
        filter: AIUsageFilter,
        now: Date,
        calendar: Calendar
    ) async throws -> AIUsageSummary
    func statistics(
        filter: AIUsageFilter,
        now: Date,
        calendar: Calendar,
        recentLimit: Int
    ) async throws -> AIUsageStatisticsSnapshot
}

/// 仓储每次通过 `database.writer` getter 访问当前账号数据库，账号切换后不会写回旧用户库。
struct GRDBAIUsageRepository: AIUsageRepositoryProtocol {
    private let database: any DatabaseManaging

    init(database: any DatabaseManaging) {
        self.database = database
    }

    func insert(_ event: AIUsageEvent) async throws {
        try await database.writer.write { db in
            try event.insert(db)
        }
    }

    func fetchRecent(limit: Int) async throws -> [AIUsageEvent] {
        guard limit > 0 else { return [] }
        return try await database.writer.read { db in
            try AIUsageEvent
                .order(Column("completed_at").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func summary(
        filter: AIUsageFilter,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async throws -> AIUsageSummary {
        let predicate = Self.predicate(filter: filter, now: now, calendar: calendar)
        return try await database.writer.read { db in
            try Self.summary(in: db, predicate: predicate)
        }
    }

    func statistics(
        filter: AIUsageFilter,
        now: Date = Date(),
        calendar: Calendar = .current,
        recentLimit: Int = 80
    ) async throws -> AIUsageStatisticsSnapshot {
        let predicate = Self.predicate(filter: filter, now: now, calendar: calendar)
        return try await database.writer.read { db in
            let summary = try Self.summary(in: db, predicate: predicate)

            let dailyRows = try Row.fetchAll(db, sql: """
                SELECT
                    strftime('%Y-%m-%d', completed_at, 'unixepoch', 'localtime') AS day,
                    COALESCE(SUM(input_tokens), 0) AS input_tokens,
                    COALESCE(SUM(output_tokens), 0) AS output_tokens,
                    COALESCE(SUM(total_tokens), 0) AS total_tokens,
                    COALESCE(SUM(estimated_cost_usd), 0) AS estimated_cost_usd,
                    COUNT(*) AS call_count
                FROM ai_usage_events
                \(predicate.whereClause)
                GROUP BY day
                ORDER BY day ASC
                """, arguments: predicate.arguments)
            let daily = dailyRows.map { row in
                AIUsageDailyPoint(
                    day: row["day"],
                    inputTokens: row["input_tokens"],
                    outputTokens: row["output_tokens"],
                    totalTokens: row["total_tokens"],
                    callCount: row["call_count"],
                    estimatedCostUSD: row["estimated_cost_usd"]
                )
            }

            func dimensions(column: String) throws -> [AIUsageDimensionPoint] {
                // `column` 只由本文件内固定字面量调用，不能接收用户输入，避免 SQL identifier 注入。
                let rows = try Row.fetchAll(db, sql: """
                    SELECT
                        \(column) AS dimension_key,
                        COALESCE(SUM(input_tokens), 0) AS input_tokens,
                        COALESCE(SUM(output_tokens), 0) AS output_tokens,
                        COALESCE(SUM(total_tokens), 0) AS total_tokens,
                        COALESCE(SUM(estimated_cost_usd), 0) AS estimated_cost_usd,
                        SUM(CASE WHEN estimated_cost_usd IS NOT NULL THEN 1 ELSE 0 END) AS priced_count,
                        COUNT(*) AS call_count
                    FROM ai_usage_events
                    \(predicate.whereClause)
                    GROUP BY \(column)
                    ORDER BY total_tokens DESC, call_count DESC, dimension_key ASC
                    """, arguments: predicate.arguments)
                return rows.map { row in
                    AIUsageDimensionPoint(
                        key: row["dimension_key"],
                        inputTokens: row["input_tokens"],
                        outputTokens: row["output_tokens"],
                        totalTokens: row["total_tokens"],
                        callCount: row["call_count"],
                        estimatedCostUSD: row["estimated_cost_usd"],
                        pricedCallCount: row["priced_count"]
                    )
                }
            }

            let recent = try AIUsageEvent.fetchAll(db, sql: """
                SELECT * FROM ai_usage_events
                \(predicate.whereClause)
                ORDER BY completed_at DESC
                LIMIT \(max(1, recentLimit))
                """, arguments: predicate.arguments)

            // 筛选选项故意读取全历史，不受当前筛选约束；否则选择某模型后其余选项会消失，
            // 用户无法直接切换，只能先清空筛选。
            let providers = try String.fetchAll(db, sql: "SELECT DISTINCT provider_id FROM ai_usage_events ORDER BY provider_id")
            let models = try String.fetchAll(db, sql: "SELECT DISTINCT model FROM ai_usage_events ORDER BY model")

            return AIUsageStatisticsSnapshot(
                summary: summary,
                daily: daily,
                byFeature: try dimensions(column: "feature"),
                byProvider: try dimensions(column: "provider_id"),
                byModel: try dimensions(column: "model"),
                recentEvents: recent,
                filterOptions: AIUsageFilterOptions(providerIDs: providers, models: models)
            )
        }
    }

    /// 状态 popover 与完整面板共用同一统计口径，但前者只执行这一条汇总 SQL。
    private static func summary(
        in db: Database,
        predicate: (whereClause: String, arguments: StatementArguments)
    ) throws -> AIUsageSummary {
        let row = try Row.fetchOne(db, sql: """
            SELECT
                COALESCE(SUM(total_tokens), 0) AS total_tokens,
                COALESCE(SUM(input_tokens), 0) AS input_tokens,
                COALESCE(SUM(output_tokens), 0) AS output_tokens,
                COUNT(*) AS call_count,
                SUM(CASE WHEN status = 'succeeded' THEN 1 ELSE 0 END) AS successful_count,
                SUM(CASE WHEN total_tokens IS NOT NULL THEN 1 ELSE 0 END) AS usage_count,
                COALESCE(SUM(estimated_cost_usd), 0) AS estimated_cost_usd,
                SUM(CASE WHEN estimated_cost_usd IS NOT NULL THEN 1 ELSE 0 END) AS priced_count,
                COALESCE(SUM(CASE WHEN operation = 'embedding' THEN item_count ELSE 0 END), 0) AS embedding_items
            FROM ai_usage_events
            \(predicate.whereClause)
            """, arguments: predicate.arguments)

        return AIUsageSummary(
            totalTokens: row?["total_tokens"] ?? 0,
            inputTokens: row?["input_tokens"] ?? 0,
            outputTokens: row?["output_tokens"] ?? 0,
            callCount: row?["call_count"] ?? 0,
            successfulCallCount: row?["successful_count"] ?? 0,
            callsWithUsage: row?["usage_count"] ?? 0,
            estimatedCostUSD: row?["estimated_cost_usd"] ?? 0,
            callsWithEstimatedCost: row?["priced_count"] ?? 0,
            embeddingItemCount: row?["embedding_items"] ?? 0
        )
    }

    private static func predicate(
        filter: AIUsageFilter,
        now: Date,
        calendar: Calendar
    ) -> (whereClause: String, arguments: StatementArguments) {
        var conditions: [String] = []
        var values: [any DatabaseValueConvertible] = []
        if let lowerBound = filter.timeRange.lowerBound(now: now, calendar: calendar) {
            conditions.append("completed_at >= ?")
            values.append(lowerBound.timeIntervalSince1970)
        }
        if let feature = filter.feature {
            conditions.append("feature = ?")
            values.append(feature.rawValue)
        }
        if let providerID = filter.providerID {
            conditions.append("provider_id = ?")
            values.append(providerID)
        }
        if let model = filter.model {
            conditions.append("model = ?")
            values.append(model)
        }
        return (
            conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND "),
            StatementArguments(values)
        )
    }
}
