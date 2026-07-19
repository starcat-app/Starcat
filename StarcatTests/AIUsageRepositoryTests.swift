//
//  AIUsageRepositoryTests.swift
//  StarcatTests
//
//  验证 v14 schema 与原始 AI 用量事件读写。
//

import Foundation
import GRDB
import Testing
@testable import Starcat

@Suite("AI 用量事件仓储")
struct AIUsageRepositoryTests {

    @Test("v14 创建用量表与查询索引")
    func migrationCreatesUsageSchema() async throws {
        let database = try InMemoryDatabaseManager()

        try await database.writer.read { db in
            #expect(try db.tableExists("ai_usage_events"))
            let columns = try db.columns(in: "ai_usage_events").map(\.name)
            #expect(columns.contains("input_tokens"))
            #expect(columns.contains("usage_source"))
            #expect(columns.contains("correlation_id"))

            let indexes = try db.indexes(on: "ai_usage_events").map(\.name)
            #expect(indexes.contains("idx_ai_usage_events_completed"))
            #expect(indexes.contains("idx_ai_usage_events_feature_completed"))
            #expect(indexes.contains("idx_ai_usage_events_model_completed"))
        }
    }

    @Test("事件按完成时间倒序读取且不可用 token 保持 nil")
    func recentEventsPreserveUnavailableUsage() async throws {
        let database = try InMemoryDatabaseManager()
        let repository = GRDBAIUsageRepository(database: database)
        try await repository.insert(makeEvent(id: "older", completedAt: 10, inputTokens: 12, totalTokens: 18))
        try await repository.insert(makeEvent(id: "newer", completedAt: 20, inputTokens: nil, totalTokens: nil))

        let events = try await repository.fetchRecent(limit: 10)

        #expect(events.map(\.id) == ["newer", "older"])
        #expect(events[0].inputTokens == nil)
        #expect(events[0].totalTokens == nil)
        #expect(events[1].totalTokens == 18)
    }

    @Test("聚合支持时间与功能筛选并统计可用率")
    func statisticsAggregateRawEvents() async throws {
        let database = try InMemoryDatabaseManager()
        let repository = GRDBAIUsageRepository(database: database)
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_752_921_600) // 2025-07-19T00:00:00Z
        try await repository.insert(makeEvent(
            id: "rag-chat",
            completedAt: now.timeIntervalSince1970 - 60,
            inputTokens: 100,
            totalTokens: 140,
            feature: .rag,
            model: "chat-a"
        ))
        try await repository.insert(makeEvent(
            id: "rag-unknown",
            completedAt: now.timeIntervalSince1970 - 120,
            inputTokens: nil,
            totalTokens: nil,
            feature: .rag,
            model: "chat-b",
            status: .failed
        ))
        try await repository.insert(makeEvent(
            id: "semantic-embedding",
            completedAt: now.timeIntervalSince1970 - 180,
            inputTokens: 20,
            totalTokens: 20,
            feature: .semanticSearch,
            model: "embed-a",
            operation: .embedding,
            itemCount: 6
        ))
        try await repository.insert(makeEvent(
            id: "old",
            completedAt: now.timeIntervalSince1970 - 40 * 86_400,
            inputTokens: 500,
            totalTokens: 550,
            feature: .rag,
            model: "chat-a"
        ))

        var filter = AIUsageFilter(timeRange: .thirtyDays)
        var snapshot = try await repository.statistics(
            filter: filter,
            now: now,
            calendar: calendar,
            recentLimit: 20
        )
        #expect(snapshot.summary.callCount == 3)
        #expect(snapshot.summary.totalTokens == 160)
        #expect(snapshot.summary.callsWithUsage == 2)
        #expect(snapshot.summary.successfulCallCount == 2)
        #expect(snapshot.summary.embeddingItemCount == 6)
        #expect(snapshot.byFeature.map(\.key) == [AIUsageFeature.rag.rawValue, AIUsageFeature.semanticSearch.rawValue])
        #expect(snapshot.filterOptions.models == ["chat-a", "chat-b", "embed-a"])

        let summary = try await repository.summary(
            filter: filter,
            now: now,
            calendar: calendar
        )
        #expect(summary == snapshot.summary)

        filter.feature = .rag
        snapshot = try await repository.statistics(
            filter: filter,
            now: now,
            calendar: calendar,
            recentLimit: 20
        )
        #expect(snapshot.summary.callCount == 2)
        #expect(snapshot.summary.totalTokens == 140)
        #expect(snapshot.recentEvents.map(\.id) == ["rag-chat", "rag-unknown"])
    }

    private func makeEvent(
        id: String,
        completedAt: Double,
        inputTokens: Int?,
        totalTokens: Int?,
        feature: AIUsageFeature = .rag,
        model: String = "model",
        status: AIUsageStatus = .succeeded,
        operation: AIUsageOperation = .chat,
        itemCount: Int = 1
    ) -> AIUsageEvent {
        AIUsageEvent(
            id: id,
            startedAt: completedAt - 1,
            completedAt: completedAt,
            durationMs: 1_000,
            providerId: "provider",
            providerKind: "openAICompatible",
            model: model,
            feature: feature.rawValue,
            phase: "answer",
            operation: operation.rawValue,
            inputTokens: inputTokens,
            outputTokens: inputTokens == nil ? nil : 6,
            totalTokens: totalTokens,
            cachedInputTokens: nil,
            reasoningOutputTokens: nil,
            itemCount: itemCount,
            usageSource: inputTokens == nil ? AIUsageSource.unavailable.rawValue : AIUsageSource.provider.rawValue,
            status: status.rawValue,
            errorCategory: nil,
            correlationId: nil
        )
    }
}
