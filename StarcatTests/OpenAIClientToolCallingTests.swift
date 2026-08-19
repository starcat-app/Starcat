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

    @Test("disableThinking 编码 reasoning_effort=none，默认请求不带该字段")
    func encodesReasoningEffortNoneOnlyWhenDisabled() throws {
        let enabled = try encodedChatQuery(disableThinking: false)
        let disabled = try encodedChatQuery(disableThinking: true)

        #expect(enabled["reasoning_effort"] == nil || enabled["reasoning_effort"] is NSNull)
        #expect(disabled["reasoning_effort"] as? String == "none")
    }

    @Test("中间件只在 reasoning_effort=none 时补 Qwen/vLLM 关思考字段")
    func middlewareInjectsEnableThinkingFalse() throws {
        let middleware = OpenAIDisableThinkingMiddleware()

        let disabled = middleware.intercept(request: try chatRequest(body: [
            "model": "qwen3",
            "reasoning_effort": "none"
        ]))
        let disabledObject = try jsonObject(from: disabled)
        #expect(disabledObject["enable_thinking"] as? Bool == false)
        #expect((disabledObject["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool == false)

        let untouched = middleware.intercept(request: try chatRequest(body: [
            "model": "qwen3",
            "reasoning_effort": "medium"
        ]))
        let untouchedObject = try jsonObject(from: untouched)
        #expect(untouchedObject["enable_thinking"] == nil)
        #expect(untouchedObject["chat_template_kwargs"] == nil)
    }

    private func encodedChatQuery(disableThinking: Bool) throws -> [String: Any] {
        let request = AIChatRequest(
            systemPrompt: "system",
            userPrompt: "hello",
            model: "test-model",
            parameters: .summaryDefault,
            disableThinking: disableThinking
        )
        let query = try OpenAIClient.makeChatQuery(request: request, resolvedModel: "test-model", stream: false)
        return try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(query)) as? [String: Any])
    }

    private func chatRequest(body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://example.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func jsonObject(from request: URLRequest) throws -> [String: Any] {
        let body = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }
}
