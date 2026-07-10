//
//  AgentRunSessionTests.swift
//  StarcatTests
//
//  验证 Agent run 状态机的有序消息、预算与终态竞争约束。
//

import Foundation
import Testing
@testable import Starcat

@Suite("AgentRunSession")
struct AgentRunSessionTests {
    @Test("为并发边界内的消息分配严格递增 sequence")
    func assignsIncreasingMessageSequence() async throws {
        let session = AgentRunSession()

        _ = try await session.append(role: .user, turn: 0, parts: [.text("goal")])
        _ = try await session.append(role: .assistant, turn: 0, parts: [.text("answer")])

        let snapshot = await session.snapshot()
        #expect(snapshot.messages.map(\.sequence) == [0, 1])
        #expect(snapshot.nextSequence == 2)
        try AgentMessageContract.validate(snapshot.messages)
    }

    @Test("迭代、工具和 token 预算在越界前保持原计数")
    func enforcesBudgetsWithoutPartialMutation() async throws {
        let limits = AgentRunLimits(
            maxIterations: 1,
            maxToolCalls: 2,
            maxTokens: 10,
            maxDuration: 60,
            defaultToolTimeoutMilliseconds: 1_000
        )
        let session = AgentRunSession(limits: limits)

        #expect(try await session.beginIteration() == 0)
        await #expect(throws: AgentRunSessionError.iterationLimit(1)) {
            _ = try await session.beginIteration()
        }
        try await session.registerToolCalls(2)
        await #expect(throws: AgentRunSessionError.toolCallLimit(2)) {
            try await session.registerToolCalls(1)
        }
        try await session.mergeUsage(.init(inputTokens: 4, outputTokens: 4))
        await #expect(throws: AgentRunSessionError.tokenLimit(10)) {
            try await session.mergeUsage(.init(inputTokens: 2, outputTokens: 2))
        }

        let snapshot = await session.snapshot()
        #expect(snapshot.iteration == 1)
        #expect(snapshot.toolCallCount == 2)
        #expect(snapshot.usage.totalTokens == 8)
    }

    @Test("超过运行时长后拒绝进入下一轮")
    func enforcesDurationLimit() async {
        let startedAt = Date(timeIntervalSince1970: 100)
        let session = AgentRunSession(
            limits: .init(maxDuration: 5),
            startedAt: startedAt,
            now: { Date(timeIntervalSince1970: 106) }
        )

        await #expect(throws: AgentRunSessionError.durationLimit(5)) {
            _ = try await session.beginIteration()
        }
    }

    @Test("取消和完成竞争时只接受一个终态")
    func acceptsOnlyOneTerminalState() async {
        let runID = UUID()
        let session = AgentRunSession(runID: runID)

        let cancelled = await session.apply(.cancel(runID: runID))
        let completed = await session.finish(.completed)
        let snapshot = await session.snapshot()

        #expect(cancelled)
        #expect(!completed)
        #expect(snapshot.state == .cancelled)
    }

    @Test("审批等待期间阻止追加消息并可由同 run 命令恢复")
    func gatesMessagesWhileWaitingForApproval() async throws {
        let runID = UUID()
        let session = AgentRunSession(runID: runID)
        let approvalID = UUID()
        try await session.requestApproval(AgentApprovalRequest(
            id: approvalID,
            runID: runID,
            toolCallID: "call-1",
            toolName: "write_tag",
            input: .object(["tag": .string("swift")]),
            permission: .requiresConfirmation,
            sequence: 2
        ))

        await #expect(throws: AgentRunSessionError.waitingForConfirmation) {
            _ = try await session.append(role: .assistant, turn: 0, parts: [.text("blocked")])
        }
        let ignoredCommand = await session.apply(.cancel(runID: UUID()))
        let resumed = await session.apply(.decideApproval(
            runID: runID,
            approvalID: approvalID,
            decision: .approved
        ))
        #expect(!ignoredCommand)
        #expect(resumed)
        let snapshot = await session.snapshot()
        #expect(snapshot.pendingApproval?.status == .approved)
        _ = try await session.append(role: .assistant, turn: 0, parts: [.text("resumed")])
    }
}
