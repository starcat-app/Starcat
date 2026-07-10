//
//  LoopAgentRuntimeTests.swift
//  StarcatTests
//
//  验证模型主动选工具、tool-result 回灌、非法输入和 artifact 完成约束。
//

import Foundation
import Testing
@testable import Starcat

@Suite("LoopAgentRuntime")
struct LoopAgentRuntimeTests {
    @Test("模型主动选择 allowlist 中非首个工具并在下一轮读取结果")
    func modelSelectsToolAndReceivesResult() async throws {
        let recorder = ModelRequestRecorder(responses: [
            .init(
                text: "",
                reasoning: "需要读取第二个工具",
                toolCalls: [.init(id: "call-1", name: "tool_b", arguments: "{}")],
                model: "test",
                finishReason: "tool_calls"
            ),
            .init(
                text: "最终回答",
                reasoning: nil,
                toolCalls: [],
                model: "test",
                finishReason: "stop"
            )
        ])
        let toolA = RuntimeStubTool(name: "tool_a", result: "A")
        let toolB = RuntimeStubTool(name: "tool_b", result: "B")
        let runtime = LoopAgentRuntime(
            modelClient: RecordedAgentModelClient(recorder: recorder),
            toolRegistry: try AgentToolRegistry(tools: [toolA, toolB])
        )
        let definition = makeDefinition(toolIDs: ["tool_a", "tool_b"])

        let events = await collect(runtime.run(definition: definition, prompt: "执行", context: .empty))
        let messages = events.compactMap { event -> AgentMessage? in
            guard case .messageAppended(let message) = event else { return nil }
            return message
        }
        let requests = await recorder.recordedRequests()

        #expect(await toolA.executionCount() == 0)
        #expect(await toolB.executionCount() == 1)
        #expect(requests.count == 2)
        #expect(requests[1].prompt.messages.contains(where: { message in
            message.parts.contains(where: {
                guard case .toolResult(let result) = $0 else { return false }
                return result.toolCallID == "call-1" && result.output.jsonDescription.contains("B")
            })
        }))
        #expect(messages.map(\.role) == [.user, .assistant, .tool, .assistant])
        #expect(events.contains(where: { if case .runCompleted = $0 { return true }; return false }))
    }

    @Test("非法参数不会执行工具并作为失败结果回灌")
    func invalidArgumentsBecomeToolResult() async throws {
        let recorder = ModelRequestRecorder(responses: [
            .init(
                text: "",
                reasoning: nil,
                toolCalls: [.init(id: "call-invalid", name: "tool_a", arguments: "{not-json")],
                model: "test",
                finishReason: "tool_calls"
            ),
            .init(text: "已识别工具参数错误", reasoning: nil, toolCalls: [], model: "test", finishReason: "stop")
        ])
        let tool = RuntimeStubTool(name: "tool_a", result: "unused")
        let runtime = LoopAgentRuntime(
            modelClient: RecordedAgentModelClient(recorder: recorder),
            toolRegistry: try AgentToolRegistry(tools: [tool])
        )

        let events = await collect(runtime.run(
            definition: makeDefinition(toolIDs: ["tool_a"]),
            prompt: "执行",
            context: .empty
        ))
        let toolResult = events.compactMap { event -> AgentToolResultMessage? in
            guard case .messageAppended(let message) = event else { return nil }
            return message.parts.compactMap {
                guard case .toolResult(let result) = $0 else { return nil }
                return result
            }.first
        }.first

        #expect(await tool.executionCount() == 0)
        #expect(toolResult?.status == .failed)
        #expect(toolResult?.isError == true)
        #expect(toolResult?.output.jsonDescription.contains("{not-json") == true)
    }

    @Test("需要 Markdown 产出物的 Agent 不允许纯文本提前结束")
    func requiresArtifactBeforeCompletion() async throws {
        let recorder = ModelRequestRecorder(responses: [
            .init(text: "跳过产出物", reasoning: nil, toolCalls: [], model: "test", finishReason: "stop")
        ])
        let runtime = LoopAgentRuntime(
            modelClient: RecordedAgentModelClient(recorder: recorder),
            toolRegistry: try AgentToolRegistry(tools: [])
        )
        let definition = makeDefinition(toolIDs: [], artifactTypes: [.markdown])

        let events = await collect(runtime.run(definition: definition, prompt: "生成报告", context: .empty))

        #expect(events.contains(where: { event in
            guard case .runFailed(let message) = event else { return false }
            return message == LoopAgentRuntimeError.requiredArtifactMissing.localizedDescription
        }))
        #expect(!events.contains(where: { if case .runCompleted = $0 { return true }; return false }))
    }

    private func collect(_ stream: AsyncStream<AgentRunEvent>) async -> [AgentRunEvent] {
        var events: [AgentRunEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    private func makeDefinition(
        toolIDs: [String],
        artifactTypes: [AgentArtifactType] = []
    ) -> AgentDefinition {
        AgentDefinition(
            id: "loop-test",
            title: "Loop Test",
            subtitle: "",
            systemImage: "gear",
            capabilityLabels: [],
            defaultPrompt: "",
            isEnabled: true,
            toolIDs: toolIDs,
            artifactTypes: artifactTypes
        )
    }
}

private actor ModelRequestRecorder {
    private var responses: [AgentModelResponse]
    private var requests: [AgentModelRequest] = []

    init(responses: [AgentModelResponse]) {
        self.responses = responses
    }

    func next(for request: AgentModelRequest) throws -> AgentModelResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw LoopAgentRuntimeError.emptyModelResponse }
        return responses.removeFirst()
    }

    func recordedRequests() -> [AgentModelRequest] { requests }
}

private struct RecordedAgentModelClient: AgentLoopModelClient {
    let recorder: ModelRequestRecorder

    func stream(request: AgentModelRequest) -> AsyncThrowingStream<AgentModelStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    continuation.yield(.completed(try await recorder.next(for: request)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

private struct RuntimeStubTool: AgentTool {
    let definition: AgentToolDefinition
    private let result: String
    private let counter = RuntimeToolCounter()

    init(name: String, result: String) {
        self.definition = AgentToolDefinition(
            name: name,
            description: "Runtime stub",
            inputSchema: .init(type: .object)
        )
        self.result = result
    }

    func execute(_ input: AgentToolInput) async -> AgentToolResult {
        await counter.increment()
        let output = AgentToolOutput(
            toolName: definition.name,
            summary: result,
            detail: result,
            input: (try? input.arguments.jsonString()) ?? "",
            output: result,
            log: "executed"
        )
        return AgentToolResult(
            output: output,
            trace: AgentTraceSpan(
                kind: "Tool",
                title: definition.name,
                summary: result,
                input: output.input,
                output: result,
                log: "executed"
            )
        )
    }

    func executionCount() async -> Int { await counter.value() }
}

private actor RuntimeToolCounter {
    private var count = 0
    func increment() { count += 1 }
    func value() -> Int { count }
}

private extension AgentJSONValue {
    var jsonDescription: String { (try? jsonString()) ?? "" }
}
