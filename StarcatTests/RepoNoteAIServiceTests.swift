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

    private static let request = AIChatRequest(
        systemPrompt: "system",
        userPrompt: "user",
        model: "test",
        parameters: .summaryDefault
    )
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
