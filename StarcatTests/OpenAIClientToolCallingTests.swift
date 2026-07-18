//
//  OpenAIClientToolCallingTests.swift
//  StarcatTests
//
//  验证 Starcat Agent 消息与工具契约被准确编码为 OpenAI-compatible Chat 请求。
//

import Foundation
import Testing
@testable import Starcat

@Suite("OpenAIClient Tool Calling")
struct OpenAIClientToolCallingTests {
    @Test("编码工具 schema、assistant tool-call 和 tool-result")
    func encodesToolCallingConversation() throws {
        let schema = AgentJSONSchema(
            type: .object,
            properties: ["query": .init(type: .string)],
            required: ["query"]
        )
        let request = AIChatRequest(
            systemPrompt: "system",
            userPrompt: "",
            history: [
                .init(role: .user, content: "search"),
                .init(
                    role: .assistant,
                    toolCalls: [.init(id: "call-1", name: "external_search", arguments: "{\"query\":\"Swift\"}")]
                ),
                .init(role: .tool, content: "{\"items\":[]}", toolCallID: "call-1")
            ],
            model: "test-model",
            parameters: .summaryDefault,
            tools: [.init(name: "external_search", description: "Search the web", inputSchema: schema)],
            toolChoice: .auto,
            parallelToolCalls: false,
            includeUsage: true
        )

        let query = try OpenAIClient.makeChatQuery(request: request, resolvedModel: "test-model", stream: true)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(query)) as? [String: Any])
        let messages = try #require(object["messages"] as? [[String: Any]])
        let tools = try #require(object["tools"] as? [[String: Any]])
        let function = try #require(tools.first?["function"] as? [String: Any])
        let parameters = try #require(function["parameters"] as? [String: Any])
        let properties = try #require(parameters["properties"] as? [String: Any])
        let assistant = try #require(messages.first(where: { $0["role"] as? String == "assistant" }))
        let tool = try #require(messages.first(where: { $0["role"] as? String == "tool" }))

        #expect(function["name"] as? String == "external_search")
        #expect(properties["query"] != nil)
        #expect((assistant["tool_calls"] as? [[String: Any]])?.first?["id"] as? String == "call-1")
        #expect(tool["tool_call_id"] as? String == "call-1")
        #expect(object["parallel_tool_calls"] as? Bool == false)
        #expect((object["stream_options"] as? [String: Any])?["include_usage"] as? Bool == true)
    }

    @Test("拒绝缺少 call id 的 tool-result 历史")
    func rejectsToolResultWithoutCallID() throws {
        let request = AIChatRequest(
            systemPrompt: "system",
            userPrompt: "",
            history: [.init(role: .tool, content: "{}")],
            model: "test-model",
            parameters: .summaryDefault
        )

        #expect(throws: AIClientError.self) {
            _ = try OpenAIClient.makeChatQuery(request: request, resolvedModel: "test-model", stream: false)
        }
    }
}
