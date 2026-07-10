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
}
