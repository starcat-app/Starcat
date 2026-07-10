//
//  AgentLoopModelClientTests.swift
//  StarcatTests
//
//  验证 Agent 消息、工具与 provider 能力错误的模型适配契约。
//

import Foundation
import Testing
@testable import Starcat

@Suite("AgentLoopModelClient")
struct AgentLoopModelClientTests {
    @Test("流式 Provider 事件完整映射 reasoning、text、tool-call、usage 和 completed")
    func mapsStreamingProviderEvents() async throws {
        let usage = AIChatUsage(
            inputTokens: 11,
            outputTokens: 7,
            cachedTokens: 3,
            reasoningTokens: 2,
            totalTokens: 18
        )
        let completed = AIChatResponse(
            content: "完成",
            reasoningContent: "已核验",
            toolCalls: [
                .init(id: "call-1", name: "context_resolve_repos", arguments: "{}"),
                .init(id: "call-2", name: "external_search", arguments: "{\"query\":\"Swift\"}")
            ],
            usage: usage,
            model: "test-model",
            finishReason: "tool_calls"
        )
        let client = AdapterStubAIClient(events: [
            .reasoningDelta("已"),
            .delta("完"),
            .toolCallDelta(.init(index: 0, id: "call-1", name: "context_resolve_repos", argumentsFragment: "{}")),
            .usage(usage),
            .completed(completed)
        ])
        let adapter = OpenAIAgentLoopModelClient(
            client: client,
            model: "test-model",
            parameters: .summaryDefault
        )

        var events: [AgentModelStreamEvent] = []
        for try await event in adapter.stream(request: emptyRequest()) {
            events.append(event)
        }

        #expect(events[0] == .reasoningDelta("已"))
        #expect(events[1] == .textDelta("完"))
        #expect(events[2] == .toolCallDelta(.init(
            index: 0,
            id: "call-1",
            name: "context_resolve_repos",
            argumentsFragment: "{}"
        )))
        #expect(events[3] == .usage(AgentUsage(
            inputTokens: 11,
            outputTokens: 7,
            cachedTokens: 3,
            reasoningTokens: 2,
            totalTokens: 18
        )))
        guard case .completed(let response) = events[4] else {
            Issue.record("Expected completed response")
            return
        }
        #expect(response.text == "完成")
        #expect(response.reasoning == "已核验")
        #expect(response.toolCalls.map(\.id) == ["call-1", "call-2"])
        #expect(response.usage?.totalTokens == 18)
        #expect(response.finishReason == "tool_calls")
    }

    @Test("非流式 Provider 的纯文本响应映射为单个 completed 事件")
    func mapsNonStreamingTextResponse() async throws {
        var parameters = AIModelParameters.summaryDefault
        parameters.streamEnabled = false
        let response = AIChatResponse(
            content: "纯文本结果",
            model: "text-model",
            finishReason: "stop"
        )
        let adapter = OpenAIAgentLoopModelClient(
            client: AdapterStubAIClient(response: response),
            model: "text-model",
            parameters: parameters
        )

        var events: [AgentModelStreamEvent] = []
        for try await event in adapter.stream(request: emptyRequest()) {
            events.append(event)
        }

        #expect(events == [.completed(AgentModelResponse(
            text: "纯文本结果",
            reasoning: nil,
            toolCalls: [],
            model: "text-model",
            finishReason: "stop"
        ))])
    }

    @Test("Provider 普通错误会转换为可读 Agent provider 错误")
    func classifiesGenericProviderFailureFromStream() async {
        let adapter = OpenAIAgentLoopModelClient(
            client: AdapterStubAIClient(failureMessage: "upstream unavailable"),
            model: "test-model",
            parameters: .summaryDefault
        )

        do {
            for try await _ in adapter.stream(request: emptyRequest()) {}
            Issue.record("Expected provider failure")
        } catch {
            #expect(error as? AgentLoopModelError == .provider("upstream unavailable"))
        }
    }

    @MainActor
    @Test("模型工厂在任务 Provider 缺失时明确失败")
    func factoryRejectsMissingProvider() {
        let settings = isolatedSettings()
        settings.aiProviderProfiles = []

        #expect(throws: AgentLoopModelError.missingProvider) {
            _ = try AgentLoopModelClientFactory.make(
                settings: settings,
                keychain: InMemoryKeychain()
            )
        }
    }

    @MainActor
    @Test("模型工厂在远程 Provider 缺少 API key 时明确失败")
    func factoryRejectsMissingAPIKey() {
        let settings = isolatedSettings()
        let profile = AIProviderProfile(
            id: "agent-test-provider",
            provider: .openAICompatible,
            baseURL: "https://api.example.com/v1",
            models: [AIModelDescriptor(
                providerID: "agent-test-provider",
                name: "test-chat-model",
                capability: .chat
            )]
        )
        settings.aiProviderProfiles = [profile]
        settings.aiChatTask = AIModelTaskConfiguration(
            providerID: profile.id,
            modelID: "test-chat-model",
            customModelName: "",
            useCustomModel: false,
            parameters: .summaryDefault,
            prompt: AIDefaultPrompts.chat
        )

        #expect(throws: AgentLoopModelError.missingAPIKey) {
            _ = try AgentLoopModelClientFactory.make(
                settings: settings,
                keychain: InMemoryKeychain()
            )
        }
    }

    @Test("将可审计消息链映射为 provider tool-calling 历史")
    func mapsAgentMessagesToProviderHistory() throws {
        let runID = UUID()
        let call = AgentToolCall(
            id: "call-1",
            name: "external_search",
            input: .object(["query": .string("Swift")]),
            sequence: 2
        )
        let result = AgentToolResultMessage(
            toolCallID: call.id,
            toolName: call.name,
            output: .object(["items": .array([])]),
            isError: false,
            status: .completed,
            elapsedMilliseconds: 24,
            sequence: 3
        )
        let messages = [
            AgentMessage(runID: runID, role: .user, turn: 0, sequence: 1, parts: [.text("搜索 Swift")]),
            AgentMessage(
                runID: runID,
                role: .assistant,
                turn: 0,
                sequence: 2,
                parts: [.reasoning("需要联网证据"), .toolCall(call)]
            ),
            AgentMessage(runID: runID, role: .tool, turn: 0, sequence: 3, parts: [.toolResult(result)])
        ]
        let definition = AgentToolDefinition(
            name: "external_search",
            description: "Search external sources",
            inputSchema: .init(
                type: .object,
                properties: ["query": .init(type: .string)],
                required: ["query"]
            )
        )

        let request = try OpenAIAgentLoopModelClient.makeChatRequest(
            request: AgentModelRequest(
                prompt: .init(systemPrompt: "system", userPrompt: "turn", messages: messages),
                tools: [definition],
                metadata: ["run_id": runID.uuidString]
            ),
            model: "test-model",
            parameters: .summaryDefault
        )

        #expect(request.history.count == 3)
        #expect(request.history[1].toolCalls.first?.id == "call-1")
        #expect(request.history[1].reasoningContent == "需要联网证据")
        #expect(request.history[2].toolCallID == "call-1")
        #expect(request.history[2].content.contains("\"status\":\"completed\""))
        #expect(request.tools.map(\.name) == ["external_search"])
        #expect(request.metadata["run_id"] == runID.uuidString)
        #expect(request.includeUsage)
    }

    @Test("拒绝 provider 不接受的工具名称")
    func rejectsInvalidProviderToolName() {
        let definition = AgentToolDefinition(
            name: "external.search",
            description: "Invalid name",
            inputSchema: .init(type: .object)
        )
        let request = AgentModelRequest(
            prompt: .init(systemPrompt: "system", userPrompt: "turn", messages: []),
            tools: [definition],
            metadata: [:]
        )

        #expect(throws: AgentLoopModelError.self) {
            _ = try OpenAIAgentLoopModelClient.makeChatRequest(
                request: request,
                model: "test-model",
                parameters: .summaryDefault
            )
        }
    }

    @Test("识别 provider 明确返回的 tool-calling 能力错误")
    func classifiesUnsupportedToolCallingError() {
        let source = NSError(
            domain: "provider",
            code: 400,
            userInfo: [NSLocalizedDescriptionKey: "This model does not support tool calls"]
        )

        let error = OpenAIAgentLoopModelClient.classify(source, model: "text-only-model")

        #expect(error as? AgentLoopModelError == .toolCallingUnsupported(model: "text-only-model"))
    }

    private func emptyRequest() -> AgentModelRequest {
        AgentModelRequest(
            prompt: .init(systemPrompt: "system", userPrompt: "turn", messages: []),
            tools: [],
            metadata: [:]
        )
    }

    @MainActor
    private func isolatedSettings() -> AppSettings {
        let defaults = UserDefaults(suiteName: "test.starcat.agent-model.\(UUID().uuidString)")!
        return AppSettings(defaults: defaults, keychain: InMemoryKeychain())
    }
}

private struct AdapterStubAIClient: AIClientProtocol {
    var response = AIChatResponse(content: "", model: "test-model", finishReason: nil)
    var events: [AIChatStreamEvent] = []
    var failureMessage: String?

    func chat(request: AIChatRequest) async throws -> AIChatResponse {
        if let failureMessage { throw AdapterStubError.provider(failureMessage) }
        return response
    }

    func chatStream(request: AIChatRequest) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            if let failureMessage {
                continuation.finish(throwing: AdapterStubError.provider(failureMessage))
            } else {
                continuation.finish()
            }
        }
    }

    func chat(systemPrompt: String, userPrompt: String, model: String?) async throws -> String {
        try await chat(request: AIChatRequest(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            model: model ?? "test-model",
            parameters: .summaryDefault
        )).content
    }

    func embedding(input: String, model: String?) async throws -> [Float] { [] }
    func embeddings(inputs: [String], model: String?) async throws -> [[Float]] { [] }
    func listModels() async throws -> [AIModelDescriptor] { [] }
    func testConnection() async throws {}
}

private enum AdapterStubError: LocalizedError {
    case provider(String)

    var errorDescription: String? {
        guard case .provider(let message) = self else { return nil }
        return message
    }
}
