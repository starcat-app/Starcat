//
//  SkillBatchAssignmentService.swift
//  Starcat
//
//  批量层只组织独立的已批准分配，不建立跨条目的长事务。
//  部分成功、取消和需要恢复分别保留；重试生成新预览，成功项不会再次提交。
//

import Foundation

/// 请求身份独立于本轮 operationID，重新预检后仍能合并同一目标的结果。
struct SkillAssignmentRequest: Sendable, Identifiable {
    let entryID: UUID
    let action: SkillAssignmentAction
    var targetID: String?
    var assignmentID: UUID?
    var id: String {
        [entryID.uuidString, action.rawValue, targetID ?? "", assignmentID?.uuidString ?? ""].joined(separator: "\u{0}")
    }
}

struct SkillBatchAssignmentRow: Sendable, Identifiable {
    let request: SkillAssignmentRequest
    let name: String
    let target: SkillAssignmentTarget?
    var plan: SkillAssignmentPlan?
    var result: SkillOperationResult?
    var id: String { request.id }
    var isReady: Bool { plan != nil && result == nil }
}

enum SkillBatchAssignmentEvent: Sendable {
    case started(String)
    case finished(String, SkillOperationResult)
}

/// 复用单项协调器的所有权、渠道、完整队列与恢复边界。
actor SkillBatchAssignmentService {
    private let assignments: SkillAssignmentCoordinator

    init(
        assignments: SkillAssignmentCoordinator,
        distributionGate: DistributionGate = DistributionGate()
    ) throws {
        try distributionGate.requireDirect(.skillManagement)
        self.assignments = assignments
    }

    /// 每个已选条目都产生结果；没有分配或目标失效时不能悄悄遗漏该条目。
    func prepare(
        entryIDs: [UUID], action: SkillAssignmentAction, targetIDs: Set<String>
    ) async throws -> [SkillBatchAssignmentRow] {
        let snapshot = try await assignments.store.snapshot()
        let targets = try await assignments.targets()
        var requests: [SkillAssignmentRequest] = []
        for entryID in entryIDs {
            if action == .assign, !targetIDs.isEmpty {
                requests += targetIDs.sorted().map { SkillAssignmentRequest(entryID: entryID, action: action, targetID: $0) }
            } else if action != .assign {
                let existing = snapshot.assignments.filter { $0.entryID == entryID }.sorted { $0.targetPath < $1.targetPath }
                requests += existing.map {
                    SkillAssignmentRequest(entryID: entryID, action: action, assignmentID: $0.id)
                }
                if existing.isEmpty { requests.append(SkillAssignmentRequest(entryID: entryID, action: action)) }
            } else {
                requests.append(SkillAssignmentRequest(entryID: entryID, action: action))
            }
        }
        return await prepare(requests, snapshot: snapshot, targets: targets)
    }

    /// 重试仍需确认新预览；needsRecovery 必须先恢复，不能当成普通失败重复提交。
    func retryPreview(_ rows: [SkillBatchAssignmentRow]) async throws -> [SkillBatchAssignmentRow] {
        let snapshot = try await assignments.store.snapshot()
        let targets = try await assignments.targets()
        let retried = await prepare(
            rows.filter { $0.result?.canRetry == true }.map(\.request), snapshot: snapshot, targets: targets
        )
        let byID = Dictionary(uniqueKeysWithValues: retried.map { ($0.id, $0) })
        return rows.map { byID[$0.id] ?? $0 }
    }

    /// 取消只停止尚未进入提交区间的项；当前项由单项事务决定成功或恢复。
    func execute(
        _ rows: [SkillBatchAssignmentRow],
        progress: @escaping @MainActor @Sendable (SkillBatchAssignmentEvent) -> Void = { _ in }
    ) async -> [SkillBatchAssignmentRow] {
        var completed: [SkillBatchAssignmentRow] = []
        for var row in rows {
            guard row.isReady, let plan = row.plan else { completed.append(row); continue }
            let result: SkillOperationResult
            if Task.isCancelled {
                result = SkillOperationResult(id: plan.id, entryID: plan.entry.id, status: .cancelled, message: nil)
            } else {
                await progress(.started(row.id))
                result = await assignments.execute(plan)
            }
            row.result = result
            completed.append(row)
            await progress(.finished(row.id, result))
        }
        return completed
    }

    private func prepare(
        _ requests: [SkillAssignmentRequest], snapshot: SkillLibrarySnapshot, targets: [SkillAssignmentTarget]
    ) async -> [SkillBatchAssignmentRow] {
        var seen: Set<String> = []
        var rows: [SkillBatchAssignmentRow] = []
        for request in requests where seen.insert(request.id).inserted {
            let entry = snapshot.entries.first { $0.id == request.entryID }
            let assignment = snapshot.assignments.first { $0.id == request.assignmentID }
            var row = SkillBatchAssignmentRow(
                request: request, name: entry?.manifestName ?? request.entryID.uuidString,
                target: assignment?.target ?? targets.first { $0.id == request.targetID }
            )
            do {
                try Task.checkCancellation()
                row.plan = try await assignments.prepare(
                    entryID: request.entryID, action: request.action,
                    targetID: request.targetID, assignmentID: request.assignmentID
                )
            } catch {
                row.result = SkillOperationResult(
                    id: UUID(), entryID: request.entryID,
                    status: error is CancellationError ? .cancelled : .conflict,
                    message: error.localizedDescription
                )
            }
            rows.append(row)
        }
        return rows
    }
}
