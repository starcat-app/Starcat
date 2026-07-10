//
//  AgentApproval.swift
//  Starcat
//
//  写入型与高成本 Agent tool-call 的审批事实模型。
//
//  审批不是瞬时 UI 状态：App 退出后仍必须知道等待的是哪个 run、哪个 tool-call、原始
//  输入和用户决策。Runtime 只能在同一 approval id 明确 approved 后执行一次工具。
//

import Foundation

enum AgentApprovalStatus: String, Codable, Hashable, Sendable {
    case pending
    case approved
    case rejected
    case executing
    case executed
    case failed
    case cancelled

    var localizedTitle: String {
        switch self {
        case .pending: return String.l10n("agent.approval.status.pending")
        case .approved: return String.l10n("agent.approval.status.approved")
        case .rejected: return String.l10n("agent.approval.status.rejected")
        case .executing: return String.l10n("agent.approval.status.executing")
        case .executed: return String.l10n("agent.approval.status.executed")
        case .failed: return String.l10n("agent.approval.status.failed")
        case .cancelled: return String.l10n("agent.approval.status.cancelled")
        }
    }
}

struct AgentApprovalRequest: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var runID: UUID
    var toolCallID: String
    var toolName: String
    var input: AgentJSONValue
    var permission: AgentToolPermission
    var sequence: Int
    var status: AgentApprovalStatus
    var createdAt: Date
    var decidedAt: Date?

    init(
        id: UUID = UUID(),
        runID: UUID,
        toolCallID: String,
        toolName: String,
        input: AgentJSONValue,
        permission: AgentToolPermission,
        sequence: Int,
        status: AgentApprovalStatus = .pending,
        createdAt: Date = Date(),
        decidedAt: Date? = nil
    ) {
        self.id = id
        self.runID = runID
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.input = input
        self.permission = permission
        self.sequence = sequence
        self.status = status
        self.createdAt = createdAt
        self.decidedAt = decidedAt
    }
}
