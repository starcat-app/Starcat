//
//  DiagnosticContext.swift
//  Starcat
//
//  操作关联与安全阶段记录。跨回调显式持有 span；TaskLocal 只传播结构化任务上下文。
//

import Foundation

/// 会话身份独立于账号和业务数据库，启动失败时仍能建立关联。
enum DiagnosticContext {
    static let sessionID = UUID().uuidString
    @TaskLocal static var current: DiagnosticOperation?
}

/// 一次操作的不可变身份。终态幂等由调用方现有任务生命周期控制，不创建业务重试。
struct DiagnosticOperation: Sendable {
    let id: String
    let parentID: String?
    let category: String
    let name: String
    private let started: ContinuousClock.Instant

    /// 在真实操作开始处创建；不得为诊断目的启动额外业务请求。
    init(category: String, name: String, fields: [String: DiagnosticValue] = [:]) {
        self.id = UUID().uuidString
        self.parentID = DiagnosticContext.current?.id
        self.category = category
        self.name = name
        self.started = .now
        event(phase: "started", fields: fields)
    }

    /// 固定阶段名和标量字段支持卡住任务的最后进度定位。
    func event(phase: String, fields: [String: DiagnosticValue] = [:]) {
        DiagnosticLogStore.shared.enqueue(DiagnosticEvent(
            level: .info, category: category, operation: name, message: "Operation stage",
            operationID: id, parentOperationID: parentID, phase: phase, fields: fields
        ))
    }

    /// 取消单独记录，错误摘要只保留类型和系统结果码，避免错误对象夹带正文。
    func finish(_ outcome: DiagnosticEvent.Outcome = .succeeded, error: Error? = nil,
                fields: [String: DiagnosticValue] = [:]) {
        let elapsed = started.duration(to: .now).components
        let cancelled = error.map(DiagnosticFailure.isCancellation) ?? false
        let result: DiagnosticEvent.Outcome = cancelled ? .cancelled : outcome
        DiagnosticLogStore.shared.enqueue(DiagnosticEvent(
            level: result == .failed ? .error : .info,
            category: category, operation: name, message: "Operation finished",
            errorCode: error.map { DiagnosticFailure.code($0) },
            underlying: error.map(DiagnosticEvent.summarize),
            operationID: id, parentOperationID: parentID, phase: "finished", outcome: result,
            durationMs: Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15,
            impact: result == .failed ? .blocked : .none, fields: fields
        ))
    }
}

/// 稳定错误身份不依赖系统语言；取消判定同时覆盖 URLSession 的取消。
enum DiagnosticFailure {
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        if let network = error as? NetworkError, case .cancelled = network { return true }
        return false
    }

    static func code(_ error: Error) -> String {
        if isCancellation(error) { return "operation.cancelled" }
        let ns = error as NSError
        return String(reflecting: type(of: error)) + "." + String(ns.code)
    }
}
