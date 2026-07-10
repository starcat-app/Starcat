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
            return message.parts.compactMap { part -> AgentToolResultMessage? in
                guard case .toolResult(let result) = part else { return nil }
                return result
            }.first
        }.first

        #expect(await tool.executionCount() == 0)
        #expect(toolResult?.status == .failed)
        #expect(toolResult?.isError == true)
        #expect(toolResult?.output.jsonDescription.contains("{not-json") == true)
    }

    @Test("只读工具重试会持久化每次 attempt")
    func readOnlyRetryPersistsEveryAttempt() async throws {
        let recorder = ModelRequestRecorder(responses: [
            .init(
                text: "",
                reasoning: "先调用可重试工具",
                toolCalls: [.init(id: "call-retry", name: "retry_tool", arguments: "{}")],
                model: "test",
                finishReason: "tool_calls"
            ),
            .init(text: "重试后完成", reasoning: nil, toolCalls: [], model: "test", finishReason: "stop")
        ])
        let tool = RetryingRuntimeTool()
        let runtime = LoopAgentRuntime(
            modelClient: RecordedAgentModelClient(recorder: recorder),
            toolRegistry: try AgentToolRegistry(tools: [tool])
        )

        let events = await collect(runtime.run(
            definition: makeDefinition(toolIDs: ["retry_tool"]),
            prompt: "执行",
            context: .empty
        ))
        let result = events.compactMap { event -> AgentToolResultMessage? in
            guard case .messageAppended(let message) = event else { return nil }
            return message.parts.compactMap { part -> AgentToolResultMessage? in
                guard case .toolResult(let result) = part else { return nil }
                return result
            }.first
        }.first

        #expect(await tool.executionCount() == 2)
        #expect(result?.status == .completed)
        #expect(result?.attempts.map(\.number) == [1, 2])
        #expect(result?.attempts.map(\.status) == [.failed, .completed])
        #expect(result?.attempts.first?.errorSummary == "transient failure")
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

    @Test("Weekly system prompt 注入真实数据与 artifact 专用约束")
    func weeklyPromptIncludesDefinitionGuardrails() async throws {
        let recorder = ModelRequestRecorder(responses: [
            .init(text: "无法提交", reasoning: nil, toolCalls: [], model: "test", finishReason: "stop")
        ])
        let runtime = LoopAgentRuntime(
            modelClient: RecordedAgentModelClient(recorder: recorder),
            toolRegistry: try AgentToolRegistry(tools: GitHubWeeklyReportAgentTools.all)
        )

        _ = await collect(runtime.run(
            definition: BuiltInAgents.githubWeeklyReport,
            prompt: "生成周刊",
            context: .empty
        ))
        let request = try #require((await recorder.recordedRequests()).first)

        #expect(request.prompt.systemPrompt.contains("weekly-local-facts"))
        #expect(request.prompt.systemPrompt.contains("Do not claim live GitHub trends"))
        #expect(request.prompt.systemPrompt.contains("submit exactly one structured artifact_build_weekly_report"))
    }

    @Test("completesRun 工具提交 artifact 后直接完成且 artifact sequence 位于底部")
    func completionToolSubmitsBottomArtifactAndFinishes() async throws {
        let recorder = ModelRequestRecorder(responses: [
            .init(
                text: "",
                reasoning: "提交最终产物",
                toolCalls: [.init(id: "call-submit", name: "submit_report", arguments: "{}")],
                model: "test",
                finishReason: "tool_calls"
            )
        ])
        let tool = RuntimeStubTool(
            name: "submit_report",
            result: "submitted",
            completesRun: true,
            payload: .markdown("# Final Report")
        )
        let runtime = LoopAgentRuntime(
            modelClient: RecordedAgentModelClient(recorder: recorder),
            toolRegistry: try AgentToolRegistry(tools: [tool])
        )

        let events = await collect(runtime.run(
            definition: makeDefinition(toolIDs: ["submit_report"], artifactTypes: [.markdown]),
            prompt: "生成报告",
            context: .empty
        ))
        let messages = events.compactMap { event -> AgentMessage? in
            guard case .messageAppended(let message) = event else { return nil }
            return message
        }
        let artifact = try #require(events.compactMap { event -> AgentArtifact? in
            guard case .artifactCreated(let artifact) = event else { return nil }
            return artifact
        }.first)
        let artifactIndex = try #require(events.firstIndex(where: {
            if case .artifactCreated = $0 { return true }
            return false
        }))
        let completedIndex = try #require(events.firstIndex(where: {
            if case .runCompleted = $0 { return true }
            return false
        }))

        #expect((await recorder.recordedRequests()).count == 1)
        #expect(artifact.content == "# Final Report")
        #expect(artifact.sequence > (messages.map(\.sequence).max() ?? -1))
        #expect(artifactIndex < completedIndex)
        #expect(events.suffix(from: artifactIndex).contains(where: { if case .messageAppended = $0 { return true }; return false }) == false)
    }

    @Test("批准后只执行原 tool-call 一次并继续同一 run")
    func approvalExecutesOriginalToolCallOnce() async throws {
        let recorder = ModelRequestRecorder(responses: approvalResponses())
        let tool = RuntimeStubTool(name: "write_tag", result: "written", permission: .requiresConfirmation)
        let runtime = LoopAgentRuntime(
            modelClient: RecordedAgentModelClient(recorder: recorder),
            toolRegistry: try AgentToolRegistry(tools: [tool])
        )
        var events: [AgentRunEvent] = []

        for await event in runtime.run(
            definition: makeDefinition(toolIDs: ["write_tag"]),
            prompt: "写入标签",
            context: .empty
        ) {
            events.append(event)
            if case .approvalUpdated(let approval) = event, approval.status == .pending {
                await runtime.send(.decideApproval(
                    runID: approval.runID,
                    approvalID: approval.id,
                    toolCallID: approval.toolCallID,
                    decision: .approved
                ))
            }
        }

        let approvals = events.compactMap { event -> AgentApprovalRequest? in
            guard case .approvalUpdated(let approval) = event else { return nil }
            return approval
        }
        #expect(await tool.executionCount() == 1)
        #expect(approvals.map(\.status) == [.pending, .approved, .executing, .executed])
        #expect(events.contains(where: { if case .runCompleted = $0 { return true }; return false }))
    }

    @Test("拒绝审批不会执行工具并把 rejected 结果回灌模型")
    func rejectionFeedsToolResultBackWithoutExecution() async throws {
        let recorder = ModelRequestRecorder(responses: approvalResponses())
        let tool = RuntimeStubTool(name: "write_tag", result: "unused", permission: .requiresConfirmation)
        let runtime = LoopAgentRuntime(
            modelClient: RecordedAgentModelClient(recorder: recorder),
            toolRegistry: try AgentToolRegistry(tools: [tool])
        )

        for await event in runtime.run(
            definition: makeDefinition(toolIDs: ["write_tag"]),
            prompt: "写入标签",
            context: .empty
        ) {
            if case .approvalUpdated(let approval) = event, approval.status == .pending {
                await runtime.send(.decideApproval(
                    runID: approval.runID,
                    approvalID: approval.id,
                    toolCallID: approval.toolCallID,
                    decision: .rejected
                ))
            }
        }
        let requests = await recorder.recordedRequests()
        let rejectedResult = requests[1].prompt.messages.flatMap(\.parts).contains { part in
            guard case .toolResult(let result) = part else { return false }
            return result.status == .rejected && result.isError
        }

        #expect(await tool.executionCount() == 0)
        #expect(rejectedResult)
    }

    @Test("等待审批时取消会终止 run 且不执行工具")
    func cancellationStopsPendingApproval() async throws {
        let recorder = ModelRequestRecorder(responses: [approvalResponses()[0]])
        let tool = RuntimeStubTool(name: "write_tag", result: "unused", permission: .requiresConfirmation)
        let runtime = LoopAgentRuntime(
            modelClient: RecordedAgentModelClient(recorder: recorder),
            toolRegistry: try AgentToolRegistry(tools: [tool])
        )
        var cancelled = false

        for await event in runtime.run(
            definition: makeDefinition(toolIDs: ["write_tag"]),
            prompt: "写入标签",
            context: .empty
        ) {
            if case .approvalUpdated(let approval) = event, approval.status == .pending {
                await runtime.send(.cancel(runID: approval.runID))
            }
            if case .runCancelled = event { cancelled = true }
        }

        #expect(cancelled)
        #expect(await tool.executionCount() == 0)
    }

    @Test("重启恢复 pending approval 后只在批准时执行原调用并继续同一 run")
    func restoredApprovalExecutesOnceAndContinuesSameRun() async throws {
        let database = try InMemoryDatabaseManager()
        let repository = GRDBAgentRunRepository(database: database)
        let definition = makeDefinition(toolIDs: ["write_tag"])
        let runID = UUID()
        _ = try await repository.createRun(
            id: runID,
            definition: definition,
            prompt: "写入标签",
            context: .empty,
            createdAt: Date(timeIntervalSince1970: 1_788_000_000)
        )
        try await repository.appendMessage(
            AgentMessage(runID: runID, role: .user, turn: 0, sequence: 0, parts: [.text("写入标签")]),
            runStatus: .running
        )
        let call = AgentToolCall(
            id: "restored-call",
            name: "write_tag",
            input: .object(["tag": .string("swift")]),
            rawInput: "{\"tag\":\"swift\"}",
            sequence: 1
        )
        try await repository.appendMessage(
            AgentMessage(runID: runID, role: .assistant, turn: 0, sequence: 1, parts: [.toolCall(call)]),
            runStatus: .running
        )
        let approval = AgentApprovalRequest(
            runID: runID,
            toolCallID: call.id,
            toolName: call.name,
            input: call.input,
            permission: .requiresConfirmation,
            sequence: call.sequence
        )
        try await repository.saveApproval(approval, runStatus: .waitingForConfirmation)
        let persisted = try #require(try await repository.snapshot(runID: runID))

        let recorder = ModelRequestRecorder(responses: [
            .init(text: "写入完成", reasoning: nil, toolCalls: [], model: "test", finishReason: "stop")
        ])
        let tool = RuntimeStubTool(name: "write_tag", result: "written", permission: .requiresConfirmation)
        let runtime = LoopAgentRuntime(
            modelClient: RecordedAgentModelClient(recorder: recorder),
            toolRegistry: try AgentToolRegistry(tools: [tool]),
            runRepository: repository
        )

        var events: [AgentRunEvent] = []
        for await event in runtime.resumePendingRun(snapshot: persisted, definition: definition) {
            events.append(event)
            if case .approvalUpdated(let pending) = event, pending.status == .pending {
                await runtime.send(.decideApproval(
                    runID: pending.runID,
                    approvalID: pending.id,
                    toolCallID: pending.toolCallID,
                    decision: .approved
                ))
            }
        }
        let restored = try #require(try await repository.snapshot(runID: runID))

        #expect(await tool.executionCount() == 1)
        #expect((await recorder.recordedRequests()).count == 1)
        #expect(restored.run.status == AgentRunStatus.completed.rawValue)
        #expect(restored.messages.map(\.sequence) == [0, 1, 2, 3])
        #expect(restored.messages.map(\.role) == [.user, .assistant, .tool, .assistant])
        #expect(restored.approvals.map(\.status) == [.executed])
        #expect(events.contains(where: { if case .runCompleted = $0 { return true }; return false }))
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

    private func approvalResponses() -> [AgentModelResponse] {
        [
            .init(
                text: "",
                reasoning: "需要用户确认",
                toolCalls: [.init(id: "call-write", name: "write_tag", arguments: "{\"tag\":\"swift\"}")],
                model: "test",
                finishReason: "tool_calls"
            ),
            .init(text: "处理完成", reasoning: nil, toolCalls: [], model: "test", finishReason: "stop")
        ]
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
    private let payload: AgentToolPayload
    private let counter = RuntimeToolCounter()

    init(
        name: String,
        result: String,
        permission: AgentToolPermission = .readOnly,
        completesRun: Bool = false,
        payload: AgentToolPayload = .none
    ) {
        self.definition = AgentToolDefinition(
            name: name,
            description: "Runtime stub",
            inputSchema: .init(type: .object, additionalProperties: true),
            permission: permission,
            completesRun: completesRun
        )
        self.result = result
        self.payload = payload
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
            ),
            payload: payload
        )
    }

    func executionCount() async -> Int { await counter.value() }
}

private actor RuntimeToolCounter {
    private var count = 0
    func increment() { count += 1 }
    func value() -> Int { count }
}

private struct RetryingRuntimeTool: AgentTool {
    let definition = AgentToolDefinition(
        name: "retry_tool",
        description: "Fails once before succeeding",
        inputSchema: .init(type: .object, additionalProperties: false),
        retryPolicy: AgentToolRetryPolicy(maxRetries: 1, initialBackoffMilliseconds: 0)
    )
    private let counter = RuntimeToolCounter()

    func execute(_ input: AgentToolInput) async -> AgentToolResult {
        await counter.increment()
        let attempt = await counter.value()
        let failed = attempt == 1
        let summary = failed ? "transient failure" : "completed"
        let output = AgentToolOutput(
            toolName: definition.name,
            summary: summary,
            detail: summary,
            input: "{}",
            output: summary,
            log: "attempt=\(attempt)"
        )
        return AgentToolResult(
            status: failed ? .failed : .completed,
            output: output,
            trace: AgentTraceSpan(
                kind: "Tool",
                title: definition.name,
                summary: summary,
                input: "{}",
                output: summary,
                log: "attempt=\(attempt)",
                status: failed ? .failed : .completed
            )
        )
    }

    func executionCount() async -> Int { await counter.value() }
}

private extension AgentJSONValue {
    var jsonDescription: String { (try? jsonString()) ?? "" }
}
