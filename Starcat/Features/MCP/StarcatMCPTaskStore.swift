//
//  StarcatMCPTaskStore.swift
//  Starcat
//
//  公共能力的进程内长任务句柄。不持久化调度、不重放请求；取消只标记请求，
//  必须等真实执行器退出才宣告 cancelled。切账号先等待全部执行器，再允许切库。
//

import Foundation
import MCP

struct StarcatPublicCapabilityError: LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

/// 任务由 App 持有，客户端断开不会取消；已完成结果保留一小时，App 退出后失效。
@MainActor
final class StarcatMCPTaskStore {
    private struct Job {
        let id: String
        let kind: String
        let createdAt: Date
        let supportsCancellation: Bool
        let containsPrivateNotes: Bool
        var state = "queued"
        var finishedAt: Date?
        var result: Value?
        var errorCode: String?
        var task: Task<Void, Never>?
    }

    private var jobs: [String: Job] = [:]
    private var changingAccount = false
    private var activeRequests = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// 切库既要等待后台任务，也要等待已接受的普通请求；否则异步回读可能跨账号。
    func beginRequest() throws {
        guard !changingAccount else {
            throw StarcatPublicCapabilityError(code: "SESSION_CHANGING", message: "The account is changing.")
        }
        activeRequests += 1
    }

    func endRequest() {
        activeRequests -= 1
        if activeRequests == 0 {
            let waiters = idleWaiters
            idleWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func hasActive(kind: String) -> Bool {
        jobs.values.contains { $0.kind == kind && !["succeeded", "failed", "cancelled"].contains($0.state) }
    }

    /// 执行闭包必须复用领域服务，禁止把业务规则放进任务轮询或状态投影。
    func start(
        kind: String,
        supportsCancellation: Bool = true,
        containsPrivateNotes: Bool = false,
        operation: @escaping @MainActor () async throws -> Value
    ) throws -> Value {
        prune()
        guard !changingAccount else {
            throw StarcatPublicCapabilityError(code: "SESSION_CHANGING", message: "The account is changing.")
        }
        guard jobs.count < 100 else {
            throw StarcatPublicCapabilityError(code: "TASK_LIMIT_REACHED", message: "The retained task limit was reached.")
        }
        let id = UUID().uuidString.lowercased()
        jobs[id] = Job(
            id: id, kind: kind, createdAt: now(),
            supportsCancellation: supportsCancellation, containsPrivateNotes: containsPrivateNotes
        )
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            self.jobs[id]?.state = "running"
            do {
                try Task.checkCancellation()
                let result = try await operation()
                try Task.checkCancellation()
                self.jobs[id]?.result = result
                self.jobs[id]?.state = "succeeded"
            } catch {
                if Task.isCancelled || error is CancellationError {
                    self.jobs[id]?.state = "cancelled"
                } else {
                    self.jobs[id]?.state = "failed"
                    self.jobs[id]?.errorCode = (error as? StarcatPublicCapabilityError)?.code ?? "OPERATION_FAILED"
                }
            }
            self.jobs[id]?.finishedAt = self.now()
            self.jobs[id]?.task = nil
        }
        jobs[id]?.task = task
        return try status(id: id)
    }

    func status(id: String) throws -> Value {
        let job = try lookup(id)
        return .object([
            "task_id": .string(job.id),
            "kind": .string(job.kind),
            "state": .string(job.state),
            "created_at": .string(ISO8601DateFormatter.shared.string(from: job.createdAt)),
            "finished_at": job.finishedAt.map { .string(ISO8601DateFormatter.shared.string(from: $0)) } ?? .null,
            "supports_cancellation": .bool(job.supportsCancellation),
            "restart_resumable": .bool(false),
            "result_retention_seconds": .int(3600),
            "error_code": job.errorCode.map(Value.string) ?? .null
        ])
    }

    func result(id: String, privateNotesAllowed: Bool) throws -> Value {
        let job = try lookup(id)
        guard !job.containsPrivateNotes || privateNotesAllowed else { throw StarcatMCPError.privateNotesDisabled }
        guard ["succeeded", "failed", "cancelled"].contains(job.state) else {
            throw StarcatPublicCapabilityError(code: "TASK_RESULT_NOT_READY", message: "The task is still running.")
        }
        return .object([
            "task": try status(id: id),
            "result": job.result ?? .null
        ])
    }

    func cancel(id: String) throws -> Value {
        let job = try lookup(id)
        if ["succeeded", "failed", "cancelled"].contains(job.state) { return try status(id: id) }
        guard job.supportsCancellation else {
            throw StarcatPublicCapabilityError(code: "TASK_CANCEL_UNSUPPORTED", message: "This executor does not support cancellation.")
        }
        jobs[id]?.state = "cancelling"
        job.task?.cancel()
        return try status(id: id)
    }

    /// 数据库切换屏障：不能只清字典，否则旧任务仍可能向新账号数据库写入。
    func cancelAllAndWait() async {
        changingAccount = true
        let previous = jobs.values.compactMap(\.task)
        previous.forEach { $0.cancel() }
        for task in previous { await task.value }
        if activeRequests > 0 {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
        jobs.removeAll()
        changingAccount = false
    }

    private func lookup(_ id: String) throws -> Job {
        prune()
        guard let job = jobs[id] else {
            throw StarcatPublicCapabilityError(code: "TASK_NOT_FOUND", message: "The task does not exist, expired, or belongs to an earlier app session.")
        }
        return job
    }

    private func prune() {
        jobs = jobs.filter { $0.value.finishedAt.map { now().timeIntervalSince($0) < 3600 } ?? true }
    }
}

/// 公共 DTO 只编码被明确选择的字段；调用方不得直接编码包含 Key、embedding 或原始诊断的对象。
enum StarcatMCPJSON {
    static func value<T: Encodable>(_ value: T) throws -> Value {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(Value.self, from: encoder.encode(value))
    }
}
