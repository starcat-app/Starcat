//
//  AgentApprovalCoordinator.swift
//  Starcat
//
//  Runtime 审批等待与命令唤醒协调器。
//
//  UI 命令可能在异步 continuation 真正挂起前到达，因此协调器会先 `prepare` 审批并
//  缓冲一次合法决策。只有 runID/approvalID/toolCallID 三者完全匹配才会恢复等待任务。
//

import Foundation

enum AgentApprovalResolution: Equatable, Sendable {
    case approved
    case rejected
    case cancelled
}

actor AgentApprovalCoordinator {
    private struct PendingApproval: Sendable {
        var request: AgentApprovalRequest
        var continuation: CheckedContinuation<AgentApprovalResolution, Never>?
        var bufferedResolution: AgentApprovalResolution?
    }

    private var pendingByID: [UUID: PendingApproval] = [:]

    func prepare(_ request: AgentApprovalRequest) {
        pendingByID[request.id] = PendingApproval(request: request)
    }

    func wait(for approvalID: UUID) async -> AgentApprovalResolution {
        guard var pending = pendingByID[approvalID] else { return .cancelled }
        if let buffered = pending.bufferedResolution {
            pendingByID.removeValue(forKey: approvalID)
            return buffered
        }
        return await withCheckedContinuation { continuation in
            pending.continuation = continuation
            pendingByID[approvalID] = pending
        }
    }

    @discardableResult
    func resolve(_ command: AgentRunCommand) -> Bool {
        switch command {
        case .cancel(let runID):
            let ids = pendingByID.values.filter { $0.request.runID == runID }.map { $0.request.id }
            for id in ids { complete(id: id, resolution: .cancelled) }
            return !ids.isEmpty
        case .decideApproval(let runID, let approvalID, let toolCallID, let decision):
            guard let pending = pendingByID[approvalID],
                  pending.request.runID == runID,
                  pending.request.toolCallID == toolCallID,
                  pending.request.status == .pending
            else { return false }
            complete(
                id: approvalID,
                resolution: decision == .approved ? .approved : .rejected
            )
            return true
        }
    }

    private func complete(id: UUID, resolution: AgentApprovalResolution) {
        guard var pending = pendingByID[id] else { return }
        if let continuation = pending.continuation {
            pendingByID.removeValue(forKey: id)
            continuation.resume(returning: resolution)
        } else {
            pending.bufferedResolution = resolution
            pendingByID[id] = pending
        }
    }
}
