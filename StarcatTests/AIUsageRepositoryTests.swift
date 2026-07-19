//
//  AIUsageRepositoryTests.swift
//  StarcatTests
//
//  验证 v14 schema 与原始 AI 用量事件读写。
//

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

    private func makeEvent(id: String, completedAt: Double, inputTokens: Int?, totalTokens: Int?) -> AIUsageEvent {
        AIUsageEvent(
            id: id,
            startedAt: completedAt - 1,
            completedAt: completedAt,
            durationMs: 1_000,
            providerId: "provider",
            providerKind: "openAICompatible",
            model: "model",
            feature: AIUsageFeature.rag.rawValue,
            phase: "answer",
            operation: AIUsageOperation.chat.rawValue,
            inputTokens: inputTokens,
            outputTokens: inputTokens == nil ? nil : 6,
            totalTokens: totalTokens,
            cachedInputTokens: nil,
            reasoningOutputTokens: nil,
            itemCount: 1,
            usageSource: inputTokens == nil ? AIUsageSource.unavailable.rawValue : AIUsageSource.provider.rawValue,
            status: AIUsageStatus.succeeded.rawValue,
            errorCategory: nil,
            correlationId: nil
        )
    }
}
