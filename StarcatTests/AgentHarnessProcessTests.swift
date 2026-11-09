//
//  AgentHarnessProcessTests.swift
//  StarcatTests
//
//  Harness 过程投影、流式结算与中断恢复的回归测试，不访问网络或用户凭据。
//

import Foundation
import Testing
@testable import Starcat

/// 同时验证实时行身份与历史事实，防止只修复首屏样式却引入重复回答或中断丢字。
@Suite("Agent Harness Process")
struct AgentHarnessProcessTests {
    @Test("过程隐藏内部事件，完整审计保留所有事实且失败阻塞始终可见")
    func projectsReadableActivitiesWithoutDroppingAudit() {
        let runID = UUID()
        let kinds: [AgentTraceKind] = [.lifecycle, .message, .request, .unknown, .tool, .warning, .retry, .compaction]
        var traces = kinds.enumerated().map { index, kind in
            AgentTraceEvent(
                id: "\(index)", runID: runID, backend: .deepSeekHarness,
                sequence: index, kind: kind, status: .completed, title: "fixture"
            )
        }
        traces.append(.init(
            id: "unknown-failure", runID: runID, backend: .deepSeekHarness,
            sequence: 8, kind: .unknown, status: .failed, title: "failure"
        ))
        traces.append(.init(
            id: "blocked", runID: runID, backend: .deepSeekHarness,
            sequence: 9, kind: .lifecycle, status: .waiting, title: "blocked"
        ))
        let presentation = AgentTimelineProjection.makePresentation(
            messages: [], approvals: [], artifacts: [], userPrompt: "", status: .completed
        )
        let rows = AgentHarnessProcessPresentation.rows(presentation: presentation, traces: traces)
        #expect(rows.map(\.sequence) == [4, 5, 6, 7, 8, 9])
        #expect(AgentTraceTimelinePresentation.makeSnapshot(traces).orderedEvents == traces)
    }

    @Test("密集增量节流，内容块保序，block-end 权威替换且展示预算有界")
    func assemblesAndThrottlesOrderedBlocks() throws {
        var buffer = AgentAssistantStreamBuffer(sequence: 3, turn: 0, step: 1)
        let firstUpdate = buffer.append(index: 0, part: .reasoning("先核对"), replacing: false, now: 0)
        let first = try #require(firstUpdate)
        for _ in 0..<400 {
            #expect(buffer.append(index: 0, part: .reasoning("字"), replacing: false, now: 0.01) == nil)
        }
        let textUpdate = buffer.append(index: 1, part: .text("准备检索"), replacing: false, now: 0.02)
        let text = try #require(textUpdate)
        #expect(text.id == first.id)
        #expect(text.blocks.map(\.id) == [0, 1])
        _ = buffer.append(index: 1, part: .text("检索完成"), replacing: true, now: 0.03)
        #expect(buffer.parts.last == .text("检索完成"))
        _ = buffer.append(index: 2, part: .reasoning(String(repeating: "长", count: 30_000)), replacing: true, now: 1)
        let size = buffer.snapshot.blocks.reduce(0) { count, block in
            switch block.part {
            case .text(let text), .reasoning(let text): return count + text.count
            default: return count
            }
        }
        #expect(size <= 12_000)
        #expect(buffer.parts.count == 3)
        buffer.reset()
        #expect(buffer.parts.isEmpty)
        #expect(buffer.snapshot.id == first.id)
    }

    @Test("最终正文在过程区外，最后一步思考仍可查阅，工具只出现一次")
    func keepsFinalReasoningAndToolIdentity() {
        let runID = UUID()
        let call = AgentToolCall(id: "call", name: "starcat.get_readme", input: .object([:]), sequence: 1)
        let messages = [
            AgentMessage(runID: runID, role: .assistant, turn: 0, sequence: 1,
                         parts: [.reasoning("检查项目"), .text("读取 README"), .toolCall(call)]),
            AgentMessage(runID: runID, role: .assistant, turn: 0, sequence: 4,
                         parts: [.reasoning("对照证据"), .text("最终结论")]),
        ]
        let tool = AgentTraceEvent(
            id: "tool:call", runID: runID, backend: .deepSeekHarness,
            sequence: 2, kind: .tool, status: .completed, title: call.name
        )
        let presentation = AgentTimelineProjection.makePresentation(
            messages: messages, approvals: [], artifacts: [], userPrompt: "", status: .completed
        )
        let rows = AgentHarnessProcessPresentation.rows(presentation: presentation, traces: [tool])
        #expect(rows.count == 4)
        #expect(rows.map(\.sequence) == [1, 1, 2, 4])
        #expect(rows.contains { row in
            if case .block(.text("最终结论")) = row.content { return true }
            return false
        } == false)
        #expect(rows.last?.id == "message-assistant-\(messages[1].id.uuidString)-block-0")
    }

    @Test("流式内容结算沿用 UUID 与排序，完整消息不与 delta 重复拼接")
    func settlesStreamWithoutDuplicateAnswer() async throws {
        let events = await runFixture([
            .assistantStepDelta(turn: 0, step: 0, index: 0, part: .reasoning("核对"), replacing: false),
            .assistantStepDelta(turn: 0, step: 0, index: 3, part: .text("答"), replacing: false),
            .assistantStepMessage(.init(
                providerMessageID: "settled", turn: 0, step: 0, parentTraceID: "turn:0:step:0",
                parts: [.reasoning("核对完毕"), .text("答案")]
            ), usage: nil),
            .completed,
        ])
        let stream = try #require(events.compactMap { event -> AgentAssistantStreamSnapshot? in
            if case .assistantStreamUpdated(let snapshot) = event { return snapshot }
            return nil
        }.last)
        let assistants = events.compactMap { event -> AgentMessage? in
            if case .messageAppended(let message) = event, message.role == .assistant { return message }
            return nil
        }
        #expect(assistants.count == 1)
        let message = try #require(assistants.first)
        #expect(message.id == stream.id)
        #expect(message.sequence == stream.sequence)
        #expect(message.parts == [.reasoning("核对完毕"), .text("答案")])
        let presentation = AgentTimelineProjection.makePresentation(
            messages: assistants, approvals: [], artifacts: [], userPrompt: "", status: .running
        )
        let settledRows = AgentHarnessProcessPresentation.rows(presentation: presentation, traces: [])
        #expect(settledRows.map(\.id) == AgentHarnessProcessPresentation.streamingRows(stream).map(\.id))
    }

    @Test("多步骤工具调用与结果合并，下一步正文不会拼接上一轮")
    func streamsAcrossToolBoundaries() async throws {
        let events = await runFixture([
            .assistantStepDelta(turn: 0, step: 0, index: 0, part: .text("先检索"), replacing: false),
            .assistantStepMessage(.init(
                providerMessageID: "first", turn: 0, step: 0, parentTraceID: "turn:0:step:0",
                parts: [.text("先检索")]
            ), usage: nil),
            .toolCall(id: "lookup", name: "fixture_lookup", input: .object(["query": .string("Starcat")]), rawInput: nil),
            .toolResult(id: "lookup", name: "fixture_lookup", output: .object(["summary": .string("found")]), isError: false),
            .assistantStepDelta(turn: 0, step: 1, index: 0, part: .text("有证据的回答"), replacing: false),
            .assistantStepMessage(.init(
                providerMessageID: "second", turn: 0, step: 1, parentTraceID: "turn:0:step:1",
                parts: [.text("有证据的回答")]
            ), usage: nil),
            .completed,
        ])
        let messages = events.compactMap { event -> AgentMessage? in
            if case .messageAppended(let message) = event { return message }
            return nil
        }
        let traces = events.compactMap { event -> AgentTraceEvent? in
            if case .traceUpdated(let trace) = event { return trace }
            return nil
        }
        let presentation = AgentTimelineProjection.makePresentation(
            messages: messages, approvals: [], artifacts: [], userPrompt: "", status: .completed
        )
        #expect(messages.filter { $0.role == .assistant }.count == 2)
        #expect(presentation.finalAnswer?.text == "有证据的回答")
        let snapshot = AgentTraceTimelinePresentation.makeSnapshot(
            Array(Dictionary(traces.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest }).values)
        )
        let rows = AgentHarnessProcessPresentation.rows(presentation: presentation, traces: snapshot.orderedEvents)
        #expect(rows.count == 2)
        #expect(rows.map(\.id).count == Set(rows.map(\.id)).count)
    }

    @Test("重试丢弃旧尝试，中断仍保留新尝试的部分内容", arguments: [
        ExternalAgentProtocolEvent.cancelled, .failed("fixture failure"),
    ])
    func retryAndInterruptionPreserveOnlyCurrentAttempt(_ terminal: ExternalAgentProtocolEvent) async throws {
        let events = await runFixture([
            .assistantStepDelta(turn: 0, step: 0, index: 0, part: .text("旧尝试"), replacing: false),
            .assistantStepReset(turn: 0, step: 0),
            .assistantStepDelta(turn: 0, step: 0, index: 0, part: .text("新尝试的部分内容"), replacing: false),
            terminal,
        ])
        let messages = events.compactMap { event -> AgentMessage? in
            if case .messageAppended(let message) = event, message.role == .assistant { return message }
            return nil
        }
        #expect(messages.count == 1)
        #expect(messages.first?.parts == [.text("新尝试的部分内容")])
        #expect(events.contains { if case .assistantStreamUpdated(nil) = $0 { return true }; return false })
        #expect(!events.contains { if case .runCompleted = $0 { return true }; return false })
    }

    /// 通过真实 Runtime/Host 驱动归一化事件，覆盖 actor 消费、消息结算与终态路径。
    private func runFixture(_ protocolEvents: [ExternalAgentProtocolEvent]) async -> [AgentRunEvent] {
        let definition = AgentDefinition(
            id: "harness-process-fixture", title: "Harness Fixture", subtitle: "",
            iconSource: .business(.terminal), capabilityLabels: [], defaultPrompt: "",
            isEnabled: true, runtimePolicy: .externalReadOnly
        )
        let runtime = ExternalAgentRuntime(
            adapter: HarnessProcessFixtureAdapter(events: protocolEvents),
            distributionGate: DistributionGate(channel: .direct)
        )
        var events: [AgentRunEvent] = []
        for await event in runtime.run(definition: definition, prompt: "fixture", context: .empty) {
            events.append(event)
        }
        return events
    }
}

/// 单次本机管道回包替代真实 Provider；不需要 Harness 二进制、API Key 或联网。
private struct HarnessProcessFixtureAdapter: ExternalAgentProtocolAdapter {
    let backend = AgentRuntimeBackend.deepSeekHarness
    let capabilities = AgentRuntimeCapabilities.deepSeekHarness
    let events: [ExternalAgentProtocolEvent]

    func makeDriver(request: ExternalAgentRunRequest) throws -> any ExternalAgentProtocolDriver {
        HarnessProcessFixtureDriver(events: events)
    }
}

/// Driver 的事件列表不可变；Host 串行调用 receive，和生产 Driver 使用相同接口。
private final class HarnessProcessFixtureDriver: ExternalAgentProtocolDriver, Sendable {
    let backend = AgentRuntimeBackend.deepSeekHarness
    let capabilities = AgentRuntimeCapabilities.deepSeekHarness
    let events: [ExternalAgentProtocolEvent]
    let processConfiguration = ExternalAgentProcessConfiguration(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "read first; printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"method\":\"fixture/completed\"}'"],
        environment: ExternalAgentProcessEnvironment.filtered(),
        currentDirectoryURL: FileManager.default.temporaryDirectory
    )

    init(events: [ExternalAgentProtocolEvent]) { self.events = events }
    func initialFrames() throws -> [AgentJSONValue] { [.jsonRPCRequest(id: 1, method: "fixture/start")] }
    func receive(_ frame: AgentJSONValue) throws -> ExternalAgentProtocolOutput {
        ExternalAgentProtocolOutput(events: events, isTerminal: true)
    }
    func cancellationFrame() -> AgentJSONValue? { nil }
    func shutdownFrame() -> AgentJSONValue? { nil }
}
