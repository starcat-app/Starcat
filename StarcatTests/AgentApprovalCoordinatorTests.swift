//
//  AgentApprovalCoordinatorTests.swift
//  StarcatTests
//
//  验证审批命令关联校验、提前到达缓冲和取消唤醒。
//

import Foundation
import Testing
@testable import Starcat

@Suite("AgentApprovalCoordinator")
struct AgentApprovalCoordinatorTests {
    @Test("合法决策可以在 wait 前到达并被消费一次")
    func buffersDecisionBeforeWait() async {
        let coordinator = AgentApprovalCoordinator()
        let request = approval()
        await coordinator.prepare(request)

        let accepted = await coordinator.resolve(.decideApproval(
            runID: request.runID,
            approvalID: request.id,
            toolCallID: request.toolCallID,
            decision: .approved
        ))
        let resolution = await coordinator.wait(for: request.id)
        let duplicate = await coordinator.resolve(.decideApproval(
            runID: request.runID,
            approvalID: request.id,
            toolCallID: request.toolCallID,
            decision: .approved
        ))

        #expect(accepted)
        #expect(resolution == .approved)
        #expect(!duplicate)
    }

    @Test("错误 run 或 toolCallID 不会恢复审批")
    func rejectsMismatchedCommand() async {
        let coordinator = AgentApprovalCoordinator()
        let request = approval()
        await coordinator.prepare(request)

        let wrongRun = await coordinator.resolve(.decideApproval(
            runID: UUID(),
            approvalID: request.id,
            toolCallID: request.toolCallID,
            decision: .approved
        ))
        let wrongCall = await coordinator.resolve(.decideApproval(
            runID: request.runID,
            approvalID: request.id,
            toolCallID: "wrong-call",
            decision: .approved
        ))
        #expect(!wrongRun)
        #expect(!wrongCall)
    }

    @Test("取消会唤醒同一 run 的等待")
    func cancellationResumesWaiter() async {
        let coordinator = AgentApprovalCoordinator()
        let request = approval()
        await coordinator.prepare(request)

        async let resolution = coordinator.wait(for: request.id)
        let accepted = await coordinator.resolve(.cancel(runID: request.runID))
        let resolved = await resolution

        #expect(accepted)
        #expect(resolved == .cancelled)
    }

    private func approval() -> AgentApprovalRequest {
        AgentApprovalRequest(
            runID: UUID(),
            toolCallID: "call-1",
            toolName: "write_tag",
            input: .object(["tag": .string("swift")]),
            permission: .requiresConfirmation,
            sequence: 2
        )
    }
}
