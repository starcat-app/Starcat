//
//  GitHubNotificationIssueSummaryStreamTests.swift
//  StarcatTests
//
//  验证 Issue 的真增量回调和既有全文回调互不混淆，模型思考片段不会进入摘要正文。
//  直接驱动客户端事件，不调用远程 API 或修改用户的模型设置。
//

import Foundation
import Testing
@testable import Starcat

/// 共享收流器的回调契约；覆盖 Issue 新增用法，同时保护个人笔记既有的全文语义。
@Suite("Issue 总结流式边界")
@MainActor
struct GitHubNotificationIssueSummaryStreamTests {
    @Test("真增量与全文快照分别返回，思考事件不混入正文")
    func deltaCallbackDoesNotRepeatSnapshots() async throws {
        let client = SummaryStreamClient(events: [
            .reasoningDelta("internal reasoning"), .reasoningCompleted,
            .delta("核心"), .delta("事实🙂"),
            .completed(AIChatResponse(content: "核心事实🙂", model: "test", finishReason: "stop"))
        ])
        var pieces: [String] = []
        var snapshots: [String] = []
        let result = try await RepoAIInsightService.generateText(
            client: client, request: request, streamEnabled: true,
            onDelta: { snapshots.append($0) }, onToken: { pieces.append($0) }
        )
        #expect(pieces == ["核心", "事实🙂"])
        #expect(snapshots == ["核心", "核心事实🙂"])
        #expect(pieces.joined() == result)
    }

    @Test("无 completed 时仍返回全部增量；completed 的修订由会话最终对齐")
    func missingCompletionDoesNotLoseLastChunk() async throws {
        var pieces: [String] = []
        let result = try await RepoAIInsightService.generateText(
            client: SummaryStreamClient(events: [.delta("前段"), .delta("尾段")]),
            request: request, streamEnabled: true, onDelta: nil, onToken: { pieces.append($0) }
        )
        #expect(result == "前段尾段")
        #expect(pieces == ["前段", "尾段"])
    }

    @Test("Issue 请求不会继承非流式偏好，也不改变其它模型参数")
    func issueRequestForcesStreamingOnly() {
        var settings = AIModelParameters.summaryDefault
        settings.streamEnabled = false
        settings.temperature = 0.25
        let result = GitHubNotificationIssueSummary.makeRequest(
            context: "{}", model: "test", parameters: settings, outputLanguage: "Chinese"
        )
        #expect(result.parameters.streamEnabled)
        #expect(result.parameters.temperature == 0.25)
        #expect(!settings.streamEnabled)
    }

    private var request: AIChatRequest {
        GitHubNotificationIssueSummary.makeRequest(
            context: "{}", model: "test", parameters: .summaryDefault, outputLanguage: "Chinese"
        )
    }
}

/// 除流式读取以外均返回失败，误走非流式分支会立刻使测试失败。
private struct SummaryStreamClient: AIClientProtocol {
    let events: [AIChatStreamEvent]

    func chat(request: AIChatRequest) async throws -> AIChatResponse { throw AIClientError.emptyResponse }

    func chatStream(request: AIChatRequest) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            events.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }

    func chat(systemPrompt: String, userPrompt: String, model: String?) async throws -> String {
        throw AIClientError.emptyResponse
    }

    func embedding(input: String, model: String?) async throws -> [Float] { throw AIClientError.emptyResponse }
    func embeddings(inputs: [String], model: String?) async throws -> [[Float]] { throw AIClientError.emptyResponse }
    func listModels() async throws -> [AIModelDescriptor] { [] }
    func testConnection() async throws {}
}
