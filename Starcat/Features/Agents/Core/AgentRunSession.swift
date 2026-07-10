//
//  AgentRunSession.swift
//  Starcat
//
//  单次 Agent run 的并发安全状态机与预算守卫。
//
//  Runtime 的模型流、工具执行、取消和审批命令来自不同异步任务。如果这些状态散落在
//  局部变量中，取消与完成会竞争写终态，message sequence 也可能重复。Session actor
//  作为唯一写入口，保证运行事实严格有序且终态只产生一次。
//

import Foundation

struct AgentRunLimits: Equatable, Sendable {
    var maxIterations: Int = 12
    var maxToolCalls: Int = 32
    var maxTokens: Int = 128_000
    var maxDuration: TimeInterval = 10 * 60
    var defaultToolTimeoutMilliseconds: Int = 30_000
}

enum AgentRunSessionState: Equatable, Sendable {
    case running
    case waitingForConfirmation
    case completed
    case failed(String)
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        case .running, .waitingForConfirmation:
            return false
        }
    }
}

enum AgentApprovalDecision: Equatable, Sendable {
    case approved
    case rejected
}

enum AgentRunCommand: Equatable, Sendable {
    case cancel(runID: UUID)
    case decideApproval(
        runID: UUID,
        approvalID: UUID,
        toolCallID: String,
        decision: AgentApprovalDecision
    )

    var runID: UUID {
        switch self {
        case .cancel(let runID), .decideApproval(let runID, _, _, _):
            return runID
        }
    }
}

struct AgentRunSessionSnapshot: Equatable, Sendable {
    var runID: UUID
    var messages: [AgentMessage]
    var iteration: Int
    var toolCallCount: Int
    var usage: AgentUsage
    var pendingApproval: AgentApprovalRequest?
    var state: AgentRunSessionState
    var nextSequence: Int
    var startedAt: Date
}

enum AgentRunSessionError: Error, LocalizedError, Equatable, Sendable {
    case terminal(AgentRunSessionState)
    case waitingForConfirmation
    case iterationLimit(Int)
    case toolCallLimit(Int)
    case tokenLimit(Int)
    case durationLimit(TimeInterval)
    case invalidRunID(UUID)

    var errorDescription: String? {
        switch self {
        case .terminal:
            return String.l10n("agent.session.error.terminal")
        case .waitingForConfirmation:
            return String.l10n("agent.session.error.waitingForConfirmation")
        case .iterationLimit(let limit):
            return String(format: String.l10n("agent.session.error.iterationLimitFormat"), limit)
        case .toolCallLimit(let limit):
            return String(format: String.l10n("agent.session.error.toolCallLimitFormat"), limit)
        case .tokenLimit(let limit):
            return String(format: String.l10n("agent.session.error.tokenLimitFormat"), limit)
        case .durationLimit(let seconds):
            return String(format: String.l10n("agent.session.error.durationLimitFormat"), seconds)
        case .invalidRunID:
            return String.l10n("agent.session.error.invalidRunID")
        }
    }
}

actor AgentRunSession {
    let runID: UUID
    let limits: AgentRunLimits
    let startedAt: Date

    private let now: @Sendable () -> Date
    private var messages: [AgentMessage] = []
    private var iteration = 0
    private var toolCallCount = 0
    private var usage = AgentUsage.zero
    private var pendingApproval: AgentApprovalRequest?
    private var state: AgentRunSessionState = .running
    private var nextSequence = 0

    init(
        runID: UUID = UUID(),
        limits: AgentRunLimits = AgentRunLimits(),
        startedAt: Date = Date(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.runID = runID
        self.limits = limits
        self.startedAt = startedAt
        self.now = now
    }

    /// 从事实存储恢复等待审批的 run。只重建状态，不执行任何工具；恢复后 Session 仍处于
    /// `waitingForConfirmation`，必须收到匹配 run/approval/toolCall 的命令才会继续。
    init(
        restoring snapshot: AgentRunSnapshotRecord,
        pendingApproval: AgentApprovalRequest,
        limits: AgentRunLimits = AgentRunLimits(),
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard let runID = UUID(uuidString: snapshot.run.id), pendingApproval.runID == runID else {
            throw AgentRunSessionError.invalidRunID(pendingApproval.runID)
        }
        self.runID = runID
        self.limits = limits
        self.startedAt = ISO8601DateFormatter.shared.date(from: snapshot.run.createdAt) ?? now()
        self.now = now
        self.messages = snapshot.messages
        self.iteration = (snapshot.messages.filter { $0.role == .assistant }.map(\.turn).max() ?? -1) + 1
        self.toolCallCount = snapshot.messages.reduce(0) { count, message in
            count + message.parts.filter { if case .toolCall = $0 { return true }; return false }.count
        }
        self.usage = snapshot.messages.compactMap(\.usage).reduce(.zero) { partial, next in
            var merged = partial
            merged.merge(next)
            return merged
        }
        self.pendingApproval = pendingApproval
        self.state = .waitingForConfirmation
        let maxMessageSequence = snapshot.messages.map(\.sequence).max() ?? -1
        let maxArtifactSequence = snapshot.artifacts.map(\.sequence).max() ?? -1
        self.nextSequence = max(maxMessageSequence, maxArtifactSequence) + 1
    }

    func append(
        role: AgentMessageRole,
        turn: Int,
        parts: [AgentMessagePart],
        usage messageUsage: AgentUsage? = nil,
        createdAt: Date? = nil
    ) throws -> AgentMessage {
        try ensureRunnable()
        if let messageUsage {
            try mergeUsage(messageUsage)
        }
        let message = AgentMessage(
            runID: runID,
            role: role,
            turn: turn,
            sequence: nextSequence,
            parts: parts,
            usage: messageUsage,
            createdAt: createdAt ?? now()
        )
        nextSequence += 1
        messages.append(message)
        return message
    }

    /// 返回本轮从 0 开始的 index；超过预算时不增加计数。
    func beginIteration() throws -> Int {
        try ensureRunnable()
        try ensureDuration()
        guard iteration < limits.maxIterations else {
            throw AgentRunSessionError.iterationLimit(limits.maxIterations)
        }
        defer { iteration += 1 }
        return iteration
    }

    func registerToolCalls(_ count: Int) throws {
        try ensureRunnable()
        try ensureDuration()
        let nextCount = toolCallCount + max(0, count)
        guard nextCount <= limits.maxToolCalls else {
            throw AgentRunSessionError.toolCallLimit(limits.maxToolCalls)
        }
        toolCallCount = nextCount
    }

    /// 为 message 之外的持久化事实保留一个全局 sequence。
    ///
    /// Artifact 必须排在产生它的 tool-result 之后，不能复用 tool message 的 sequence；
    /// 否则历史恢复后只能依赖 UI 的类型排序猜测真实执行顺序。
    func reserveSequence() throws -> Int {
        try ensureRunnable()
        defer { nextSequence += 1 }
        return nextSequence
    }

    func mergeUsage(_ delta: AgentUsage) throws {
        try ensureRunnable()
        var next = usage
        next.merge(delta)
        guard next.totalTokens <= limits.maxTokens else {
            throw AgentRunSessionError.tokenLimit(limits.maxTokens)
        }
        usage = next
    }

    func requestApproval(_ approval: AgentApprovalRequest) throws {
        try ensureRunnable()
        guard approval.runID == runID else {
            throw AgentRunSessionError.invalidRunID(approval.runID)
        }
        pendingApproval = approval
        state = .waitingForConfirmation
    }

    func clearResolvedApproval() {
        guard pendingApproval?.status != .pending else { return }
        pendingApproval = nil
    }

    @discardableResult
    func finish(_ terminalState: AgentRunSessionState) -> Bool {
        guard terminalState.isTerminal, !state.isTerminal else { return false }
        state = terminalState
        return true
    }

    @discardableResult
    func apply(_ command: AgentRunCommand) -> Bool {
        guard command.runID == runID, !state.isTerminal else { return false }
        switch command {
        case .cancel:
            state = .cancelled
            return true
        case .decideApproval(_, let approvalID, let toolCallID, let decision):
            guard state == .waitingForConfirmation,
                  var approval = pendingApproval,
                  approval.id == approvalID,
                  approval.toolCallID == toolCallID,
                  approval.status == .pending
            else { return false }
            approval.status = decision == .approved ? .approved : .rejected
            approval.decidedAt = now()
            pendingApproval = approval
            state = .running
            return true
        }
    }

    func snapshot() -> AgentRunSessionSnapshot {
        AgentRunSessionSnapshot(
            runID: runID,
            messages: messages,
            iteration: iteration,
            toolCallCount: toolCallCount,
            usage: usage,
            pendingApproval: pendingApproval,
            state: state,
            nextSequence: nextSequence,
            startedAt: startedAt
        )
    }

    func updateApprovalStatus(_ status: AgentApprovalStatus, approvalID: UUID) throws {
        guard var approval = pendingApproval, approval.id == approvalID else {
            throw AgentRunSessionError.waitingForConfirmation
        }
        approval.status = status
        pendingApproval = approval
    }

    private func ensureRunnable() throws {
        if state.isTerminal {
            throw AgentRunSessionError.terminal(state)
        }
        if state == .waitingForConfirmation {
            throw AgentRunSessionError.waitingForConfirmation
        }
    }

    private func ensureDuration() throws {
        let elapsed = now().timeIntervalSince(startedAt)
        guard elapsed <= limits.maxDuration else {
            throw AgentRunSessionError.durationLimit(limits.maxDuration)
        }
    }
}
