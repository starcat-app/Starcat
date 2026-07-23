//
//  AIUsageCaptureTests.swift
//  StarcatTests
//
//  验证底层 usage 到持久化事件的统计口径。
//

import Foundation
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

    @Test("无 Provider usage 的文本 Chat 使用本地估算并标记来源")
    func missingProviderUsageUsesLocalEstimate() {
        let request = AIChatRequest(
            systemPrompt: "Translate the README segments.",
            userPrompt: #"{"segments":[{"id":"p1","text":"Hello Starcat"}]}"#,
            history: [
                AIChatMessage(role: .assistant, content: "Previous context")
            ],
            model: "chat-model",
            parameters: .summaryDefault
        )

        let estimate = OpenAIClient.estimatedChatUsage(
            request: request,
            responseContent: #"{"translations":[{"id":"p1","translation":"你好，Starcat"}]}"#
        )
        #expect(estimate != nil)
        #expect(estimate?.inputTokens ?? 0 > 0)
        #expect(estimate?.outputTokens ?? 0 > 0)
        #expect(estimate?.totalTokens == (estimate?.inputTokens ?? 0) + (estimate?.outputTokens ?? 0))

        let event = AIUsageEventFactory.make(
            startedAt: 10,
            completedAt: 11,
            configuration: configuration,
            usageContext: AIUsageContext(feature: .readmeTranslation, phase: "translation"),
            model: request.model,
            operation: .chat,
            inputTokens: estimate?.inputTokens,
            outputTokens: estimate?.outputTokens,
            totalTokens: estimate?.totalTokens,
            cachedInputTokens: nil,
            reasoningOutputTokens: nil,
            itemCount: 1,
            usageSource: .estimated,
            status: .succeeded
        )

        #expect(event.feature == AIUsageFeature.readmeTranslation.rawValue)
        #expect(event.usageSource == AIUsageSource.estimated.rawValue)
        #expect(event.totalTokens == estimate?.totalTokens)
    }

    @Test("含图片请求不伪造文本 Token 估算")
    func visionRequestKeepsUnavailableUsage() {
        let request = AIChatRequest(
            systemPrompt: "Describe the image.",
            userPrompt: "What is shown?",
            images: [AIChatImageInput(data: Data([0x01]), contentType: "image/png")],
            model: "vision-model",
            parameters: .summaryDefault
        )

        #expect(OpenAIClient.estimatedChatUsage(
            request: request,
            responseContent: "A cat."
        ) == nil)
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

    @Test("失败事件仍保留 Provider 已返回的 usage")
    func failedResponsePreservesProviderUsage() {
        let event = AIUsageEventFactory.make(
            startedAt: 10,
            completedAt: 11,
            configuration: configuration,
            model: "embedding-model",
            operation: .embedding,
            inputTokens: 48,
            outputTokens: 0,
            totalTokens: 48,
            cachedInputTokens: nil,
            reasoningOutputTokens: nil,
            itemCount: 3,
            status: .failed,
            error: AIEmbeddingError.invalidResponse
        )

        #expect(event.status == AIUsageStatus.failed.rawValue)
        #expect(event.totalTokens == 48)
        #expect(event.usageSource == AIUsageSource.provider.rawValue)
    }

    @Test("取消终态不产生错误分类")
    func cancellationHasNoErrorCategory() {
        let event = AIUsageEventFactory.make(
            startedAt: 10,
            completedAt: 10.2,
            configuration: configuration,
            model: "chat-model",
            operation: .chat,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: nil,
            cachedInputTokens: nil,
            reasoningOutputTokens: nil,
            itemCount: 1,
            status: .cancelled,
            error: CancellationError()
        )

        #expect(event.status == AIUsageStatus.cancelled.rawValue)
        #expect(event.errorCategory == nil)
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
