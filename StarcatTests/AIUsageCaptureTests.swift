//
//  AIUsageCaptureTests.swift
//  StarcatTests
//
//  验证底层 usage 到持久化事件的统计口径。
//

import Testing
@testable import Starcat

@Suite("AI 用量采集口径")
struct AIUsageCaptureTests {

    @Test("Provider usage 保留输入输出及子集但不重复改写总量")
    func providerUsageKeepsTokenBreakdown() {
        let event = AIUsageEventFactory.make(
            startedAt: 10,
            completedAt: 11.25,
            configuration: configuration,
            model: "chat-model",
            operation: .chat,
            inputTokens: 100,
            outputTokens: 40,
            totalTokens: 140,
            cachedInputTokens: 25,
            reasoningOutputTokens: 10,
            itemCount: 1,
            status: .succeeded
        )

        #expect(event.inputTokens == 100)
        #expect(event.outputTokens == 40)
        #expect(event.totalTokens == 140)
        #expect(event.cachedInputTokens == 25)
        #expect(event.reasoningOutputTokens == 10)
        #expect(event.usageSource == AIUsageSource.provider.rawValue)
        #expect(event.durationMs == 1_250)
    }

    @Test("无 usage 的失败请求保持未知 token 并保存枚举错误")
    func unavailableUsageDoesNotBecomeZero() {
        let event = AIUsageEventFactory.make(
            startedAt: 10,
            completedAt: 10.5,
            configuration: configuration,
            model: "embedding-model",
            operation: .embedding,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: nil,
            cachedInputTokens: nil,
            reasoningOutputTokens: nil,
            itemCount: 8,
            status: .failed,
            error: AIEmbeddingError.rateLimited
        )

        #expect(event.inputTokens == nil)
        #expect(event.totalTokens == nil)
        #expect(event.usageSource == AIUsageSource.unavailable.rawValue)
        #expect(event.errorCategory == AIUsageErrorCategory.rateLimit.rawValue)
        #expect(event.itemCount == 8)
    }

    @Test("流式 usage fallback 只接受明确的参数不兼容错误")
    func streamUsageFallbackIsConservative() {
        #expect(OpenAIClient.shouldRetryWithoutStreamUsage(
            AIClientError.requestRejected(
                statusCode: 400,
                detail: "Unknown parameter: stream_options.include_usage"
            )
        ))
        #expect(!OpenAIClient.shouldRetryWithoutStreamUsage(
            AIClientError.requestRejected(statusCode: 400, detail: "Invalid model")
        ))
        #expect(!OpenAIClient.shouldRetryWithoutStreamUsage(
            AIClientError.networkUnavailable(detail: "connection reset")
        ))
    }

    private var configuration: AIClientConfiguration {
        AIClientConfiguration(
            providerID: "profile-1",
            provider: .deepSeek,
            apiKey: "not-persisted",
            baseURL: "https://example.invalid/v1",
            chatModel: "chat-model",
            embeddingModel: "embedding-model",
            usageContext: AIUsageContext(feature: .rag, phase: "answer", correlationID: "conversation-1")
        )
    }
}
