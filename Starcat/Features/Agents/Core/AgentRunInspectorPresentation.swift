//
//  AgentRunInspectorPresentation.swift
//  Starcat
//
//  Agent 任务检查器的事实型展示投影。
//
//  本文件只从 Run、Context、Trace、Message 与 Artifact 的已记录数据计算指标，
//  不猜测 Runtime 未提供的上下文窗口、思维链或成本，确保三种 Runtime 共用同一套 UI
//  时仍能明确区分“没有发生”和“Provider 没有提供”。
//

import Foundation
import SwiftUI

/// Agent Inspector 的稳定信息架构；选项顺序即右栏的阅读顺序。
enum AgentInspectorTab: String, CaseIterable, Hashable, Sendable {
    case overview
    case context
    case artifacts

    var titleKey: LocalizedStringKey {
        switch self {
        case .overview: "agent.workspace.inspector.tab.overview"
        case .context: "agent.workspace.inspector.tab.context"
        case .artifacts: "agent.workspace.inspector.tab.artifacts"
        }
    }
}

/// 把分散在多种持久化实体里的 Run 事实收口为轻量值，避免 SwiftUI body 反复遍历消息树。
struct AgentRunInspectorPresentation: Equatable, Sendable {
    let stepCount: Int
    let completedStepCount: Int
    let activeStepCount: Int
    let failedStepCount: Int
    let toolCallCount: Int
    let retryCount: Int
    let compactionCount: Int
    let sourceCount: Int
    let artifactCount: Int
    let knowledgeAuditCount: Int
    let approvalRequestCount: Int
    let approvedApprovalCount: Int
    let rejectedApprovalCount: Int
    let fileChangeCount: Int
    let warningCount: Int
    let startedAt: Date?
    let finishedAt: Date?
    let lastActivityAt: Date?

    init(
        traceEvents: [AgentTraceEvent],
        messages: [AgentMessage],
        approvals: [AgentApprovalRequest],
        artifacts: [AgentArtifact],
        runRecord: AgentRunRecord?
    ) {
        stepCount = traceEvents.count
        completedStepCount = traceEvents.count { [.completed, .skipped].contains($0.status) }
        activeStepCount = traceEvents.count { [.pending, .running, .waiting].contains($0.status) }
        failedStepCount = traceEvents.count { $0.status == .failed }

        let traceToolCalls = traceEvents.count {
            [.tool, .command, .webSearch, .mcpTool].contains($0.kind)
        }
        toolCallCount = traceEvents.isEmpty
            ? messages.reduce(0) { count, message in
                count + message.parts.count { part in
                    if case .toolCall = part { return true }
                    return false
                }
            }
            : traceToolCalls
        retryCount = traceEvents.count { $0.kind == .retry }
        compactionCount = traceEvents.count { $0.kind == .compaction }
        sourceCount = messages.reduce(0) { count, message in
            count + message.parts.reduce(0) { partCount, part in
                guard case .toolResult(let result) = part else { return partCount }
                return partCount + result.sources.count
            }
        }
        artifactCount = artifacts.count
        knowledgeAuditCount = messages.reduce(0) { count, message in
            count + message.parts.count { part in
                guard case .toolResult(let result) = part else { return false }
                return result.toolAudit?.knowledgeRetrieval != nil
            }
        }
        approvalRequestCount = approvals.count
        approvedApprovalCount = approvals.count { $0.status == .approved }
        rejectedApprovalCount = approvals.count { $0.status == .rejected }
        fileChangeCount = traceEvents.count { $0.kind == .fileChange }
        warningCount = traceEvents.count { [.warning, .error].contains($0.kind) }

        let recordedStart = runRecord.flatMap { ISO8601DateFormatter.shared.date(from: $0.createdAt) }
        let recordedFinish = runRecord?.finishedAt.flatMap { ISO8601DateFormatter.shared.date(from: $0) }
        startedAt = traceEvents.map(\.startedAt).min() ?? recordedStart
        finishedAt = traceEvents.compactMap(\.completedAt).max() ?? recordedFinish
        lastActivityAt = traceEvents.compactMap { $0.completedAt ?? $0.startedAt }.max()
            ?? messages.map(\.createdAt).max()
            ?? recordedStart
    }

    func durationMilliseconds(now: Date = Date()) -> Int? {
        guard let startedAt else { return nil }
        let end = finishedAt ?? now
        return max(0, Int(end.timeIntervalSince(startedAt) * 1_000))
    }
}
