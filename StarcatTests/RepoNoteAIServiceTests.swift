//
//  RepoNoteAIServiceTests.swift
//  StarcatTests
//
//  AI 个人笔记的 Prompt 边界与摘要同源流式收集语义测试。
//

import Foundation
import Testing
@testable import Starcat

@Suite("AI 个人笔记服务")
struct RepoNoteAIServiceTests {

    @Test("Prompt 同时传入 README 与原笔记并标记不可信边界")
    @MainActor
    func requestKeepsBothInputsAndTrustBoundary() {
        let request = RepoAIInsightService.makeRepoNoteRequest(
            readmeMarkdown: "# Demo\n\nRun `demo start`.",
            existingNote: "保留这条决策：不使用 beta API。",
            model: "test-model",
            parameters: .summaryDefault,
            outputLanguage: "Simplified Chinese"
        )

        #expect(request.systemPrompt.contains("Existing Personal Note is user-owned data"))
        #expect(request.systemPrompt.contains("untrusted data"))
        #expect(request.userPrompt.contains("保留这条决策：不使用 beta API。"))
        #expect(request.userPrompt.contains("Run `demo start`."))
        #expect(request.userPrompt.contains("<existing-personal-note>"))
        #expect(request.userPrompt.contains("<readme-markdown>"))
        #expect(request.usageContext?.feature == .repoNote)
        #expect(request.usageContext?.phase == "generation")
    }

    @Test("流式生成忽略思考片段并持续回传完整草稿")
    @MainActor
    func streamAccumulatesVisibleDraft() async throws {
        let client = RepoNoteAIClientStub(events: [
            .reasoningDelta("internal"),
            .delta("# Demo"),
            .delta("\n\n## Quick Start"),
            .completed(AIChatResponse(content: "# Demo\n\n## Quick Start", model: "test", finishReason: "stop"))
        ])
        var snapshots: [String] = []

        let result = try await RepoAIInsightService.generateText(
            client: client,
            request: Self.request,
            streamEnabled: true,
            onDelta: { snapshots.append($0) }
        )

        #expect(result == "# Demo\n\n## Quick Start")
        #expect(snapshots == ["# Demo", "# Demo\n\n## Quick Start"])
    }

    @Test("无 completed 事件时回退到已累积正文")
    func streamWithoutCompletedUsesAccumulatedText() async throws {
        let client = RepoNoteAIClientStub(events: [.delta("draft")])
        let result = try await RepoAIInsightService.generateText(
            client: client,
            request: Self.request,
            streamEnabled: true,
            onDelta: nil
        )
        #expect(result == "draft")
    }

    @Test("关闭流式时使用同一请求语义")
    func nonStreamingProviderReturnsFinalDraft() async throws {
        let client = RepoNoteAIClientStub(events: [
            .completed(AIChatResponse(content: "final draft", model: "test", finishReason: "stop"))
        ])
        let result = try await RepoAIInsightService.generateText(
            client: client,
            request: Self.request,
            streamEnabled: false,
            onDelta: nil
        )
        #expect(result == "final draft")
    }

    @Test("空响应不能被当成可应用草稿")
    func emptyResponseFails() async {
        let client = RepoNoteAIClientStub(events: [])
        await #expect(throws: AIClientError.emptyResponse) {
            try await RepoAIInsightService.generateText(
                client: client,
                request: Self.request,
                streamEnabled: true,
                onDelta: nil
            )
        }
    }

    @Test("取消后第三方流的迟到尾包不会进入草稿")
    @MainActor
    func cancellationRejectsLateStreamEvent() async throws {
        let client = RepoNoteControllableAIClient()
        var snapshots: [String] = []
        let task = Task {
            try await RepoAIInsightService.generateText(
                client: client,
                request: Self.request,
                streamEnabled: true,
                onDelta: { snapshots.append($0) }
            )
        }

        client.yield(.delta("first"))
        for _ in 0..<100 where snapshots.isEmpty {
            await Task.yield()
        }
        #expect(snapshots == ["first"])

        task.cancel()
        // 故意模拟不响应父 Task 取消、仍发送尾包的第三方 Provider。
        client.yield(.delta("-late"))
        client.finish()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(snapshots == ["first"])
    }

    private static let request = AIChatRequest(
        systemPrompt: "system",
        userPrompt: "user",
        model: "test",
        parameters: .summaryDefault
    )
}

/// 可由测试精确驱动事件的流客户端；Continuation 的 yield / finish 本身支持跨任务调用。
private final class RepoNoteControllableAIClient: AIClientProtocol, @unchecked Sendable {
    private let stream: AsyncThrowingStream<AIChatStreamEvent, Error>
    private let continuation: AsyncThrowingStream<AIChatStreamEvent, Error>.Continuation

    init() {
        var captured: AsyncThrowingStream<AIChatStreamEvent, Error>.Continuation?
        stream = AsyncThrowingStream { captured = $0 }
        continuation = captured!
    }

    func yield(_ event: AIChatStreamEvent) {
        continuation.yield(event)
    }

    func finish() {
        continuation.finish()
    }

    func chat(request: AIChatRequest) async throws -> AIChatResponse {
        throw AIClientError.emptyResponse
    }

    func chatStream(request: AIChatRequest) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        stream
    }

    func chat(systemPrompt: String, userPrompt: String, model: String?) async throws -> String {
        throw AIClientError.emptyResponse
    }

    func embedding(input: String, model: String?) async throws -> [Float] {
        throw AIClientError.emptyResponse
    }

    func embeddings(inputs: [String], model: String?) async throws -> [[Float]] {
        throw AIClientError.emptyResponse
    }

    func listModels() async throws -> [AIModelDescriptor] { [] }

    func testConnection() async throws {}
}

/// 只支持本 Suite 需要的 chat / stream，其余能力若被误调即明确失败。
private struct RepoNoteAIClientStub: AIClientProtocol {
    let events: [AIChatStreamEvent]

    func chat(request: AIChatRequest) async throws -> AIChatResponse {
        guard let completed = events.compactMap({ event -> AIChatResponse? in
            if case .completed(let response) = event { return response }
            return nil
        }).last else {
            throw AIClientError.emptyResponse
        }
        return completed
    }

    func chatStream(request: AIChatRequest) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            events.forEach { event in
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func chat(systemPrompt: String, userPrompt: String, model: String?) async throws -> String {
        throw AIClientError.emptyResponse
    }

    func embedding(input: String, model: String?) async throws -> [Float] {
        throw AIClientError.emptyResponse
    }

    func embeddings(inputs: [String], model: String?) async throws -> [[Float]] {
        throw AIClientError.emptyResponse
    }

    func listModels() async throws -> [AIModelDescriptor] { [] }

    func testConnection() async throws {}
}
