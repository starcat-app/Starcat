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
    static var active: DiagnosticOperation? {
        current.flatMap { $0.isActive ? $0 : nil }
    }
}

/// 一次操作的不可变身份和有界上下文；只有业务明确确认的最终严重故障才落盘。
struct DiagnosticOperation: Sendable {
    let id: String
    let parentID: String?
    let category: String
    let name: String
    private let started: ContinuousClock.Instant
    private let store: DiagnosticLogStore
    private let state: CompletionState
    var isActive: Bool { state.isActive }

    /// 跨 WebKit 回调与结构化子任务共享阶段，因此用锁保护短值操作，不在锁内 await。
    /// 子操作只向父操作交付结果；父操作成功回退时整体释放，避免中间失败留下误报。
    private final class CompletionState: @unchecked Sendable {
        private let lock = NSLock()
        let parent: CompletionState?
        let started: ContinuousClock.Instant
        let initialFields: [String: DiagnosticValue]
        private var finished = false
        private var breadcrumbs: [DiagnosticBreadcrumb] = []
        private var truncated = false
        private var failure: DiagnosticEvent?
        var isActive: Bool { lock.withLock { !finished } }

        init(parent: CompletionState?, started: ContinuousClock.Instant,
             fields: [String: DiagnosticValue]) {
            self.parent = parent
            self.started = started
            initialFields = DiagnosticEvent.safeFields(fields)
        }

        @discardableResult
        func observe(_ event: DiagnosticEvent) -> Bool {
            let elapsed = started.duration(to: .now).components
            let stage = DiagnosticBreadcrumb(event: event,
                elapsedMs: Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
            let accepted = lock.withLock {
                guard !finished else { return false }
                if breadcrumbs.count == DiagnosticBreadcrumb.limit {
                    breadcrumbs.removeFirst()
                    truncated = true
                }
                breadcrumbs.append(stage)
                if event.isSevereFailure && event.hasValidSummaryKey { failure = event }
                return true
            }
            if accepted { parent?.observeStage(event) }
            return accepted
        }

        /// 父操作保留子阶段，但子故障是否成立必须等子操作最终结束后再判断。
        private func observeStage(_ event: DiagnosticEvent) {
            var stage = event
            stage.visibility = .context
            observe(stage)
        }

        func complete(_ terminal: DiagnosticEvent) -> DiagnosticEvent? {
            let completed: (Bool, DiagnosticEvent?) = lock.withLock {
                guard !finished else { return (false, nil) }
                finished = true
                defer { failure = nil; breadcrumbs.removeAll() }
                if breadcrumbs.count == DiagnosticBreadcrumb.limit {
                    breadcrumbs.removeFirst()
                    truncated = true
                }
                breadcrumbs.append(DiagnosticBreadcrumb(event: terminal, elapsedMs: terminal.durationMs ?? 0))
                guard terminal.outcome == .failed || terminal.outcome == .partial,
                      var result = terminal.isSevereFailure ? terminal : failure else { return (true, nil) }
                if let failure {
                    // 上层终态经常只有影响判断；保留下层真实错误和请求身份供定位。
                    result.errorCode = result.errorCode ?? failure.errorCode
                    result.underlying = result.underlying ?? failure.underlying
                    if result.errorChain.isEmpty { result.errorChain = failure.errorChain }
                    result.requestID = result.requestID ?? failure.requestID
                    result.serverTraceID = result.serverTraceID ?? failure.serverTraceID
                    result.service = result.service ?? failure.service
                    result.statusCode = result.statusCode ?? failure.statusCode
                    if result.context.isEmpty { result.context = failure.context }
                    result.fields = failure.fields.merging(result.fields) { _, latest in latest }
                }
                result.errorCode = result.errorCode ?? terminal.errorCode
                result.underlying = result.underlying ?? terminal.underlying
                if result.errorChain.isEmpty { result.errorChain = terminal.errorChain }
                result.fields.merge(terminal.fields) { _, latest in latest }
                result.outcome = terminal.outcome
                result.fields = DiagnosticEvent.safeFields(initialFields.merging(result.fields) { _, latest in latest })
                result.breadcrumbs = breadcrumbs
                result.breadcrumbsTruncated = truncated
                return (true, result)
            }
            if completed.0 { parent?.observeStage(terminal) }
            return completed.1
        }

        /// 子阶段此前已传播；这里只交付候选故障，避免重复追加同一终态。
        func receiveFailure(_ event: DiagnosticEvent) {
            lock.withLock {
                guard !finished else { return }
                failure = event
            }
        }
    }

    /// 在真实操作开始处创建；不得为诊断目的启动额外业务请求。
    init(category: String, name: String, fields: [String: DiagnosticValue] = [:], store: DiagnosticLogStore = .shared) {
        // 启动期派生的后台 Task 会继承 TaskLocal；已结束的启动操作不能吞掉后续独立请求。
        let parent = DiagnosticContext.active
        self.id = UUID().uuidString
        self.parentID = parent?.id
        self.category = category
        self.name = name
        self.started = .now
        self.store = store
        self.state = CompletionState(parent: parent?.state, started: started, fields: fields)
        event(phase: "started", fields: fields)
    }

    /// 普通阶段只进入内存；成功、取消或有效回退后不会留下独立诊断事件。
    func event(phase: String, outcome: DiagnosticEvent.Outcome? = nil,
               fields: [String: DiagnosticValue] = [:]) {
        capture(DiagnosticEvent(
            level: .info, category: category, operation: name, message: "Operation stage",
            operationID: id, parentOperationID: parentID, phase: phase, outcome: outcome, fields: fields
        ))
    }

    /// 传输和业务层复用同一安全事件模型；是否持久化仍由根操作的最终结果决定。
    @discardableResult
    func capture(_ event: DiagnosticEvent) -> Bool {
        state.observe(event)
    }

    /// failed 本身不再推断 blocked；调用方必须提供实际影响和固定摘要。
    /// 重复收尾无效，同一根操作多层捕获的失败最终只生成一条故障。
    func finish(_ outcome: DiagnosticEvent.Outcome = .succeeded, error: Error? = nil,
                impact: DiagnosticEvent.Impact = .none, summary: DiagnosticIssue? = nil,
                fields: [String: DiagnosticValue] = [:],
                sourceFile: String = #fileID, sourceFunction: String = #function, sourceLine: Int = #line) {
        let elapsed = started.duration(to: .now).components
        let cancelled = error.map(DiagnosticFailure.isCancellation) ?? false
        let result: DiagnosticEvent.Outcome = cancelled ? .cancelled : outcome
        let terminal = DiagnosticEvent(
            level: result == .failed || result == .partial ? .error : .info,
            visibility: summary == nil ? .context : .issue,
            category: category, operation: name, message: "Operation finished",
            summaryKey: summary?.rawValue,
            errorCode: error.map { DiagnosticFailure.code($0) },
            underlying: error.map(DiagnosticEvent.summarize),
            operationID: id, parentOperationID: parentID, phase: "finished", outcome: result,
            durationMs: Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15,
            impact: impact, fields: fields, errorChain: error.map(DiagnosticFailure.causes) ?? [],
            sourceFile: sourceFile, sourceFunction: sourceFunction, sourceLine: sourceLine)
        guard var failure = state.complete(terminal) else { return }
        if let parent = state.parent {
            parent.receiveFailure(failure)
        } else {
            // 根身份用于去重；具体错误和请求身份仍保留在故障字段与阶段中。
            failure.operationID = id
            failure.parentOperationID = parentID
            failure.durationMs = terminal.durationMs
            store.enqueue(failure)
        }
    }
}

/// 稳定错误身份不依赖系统语言；取消判定同时覆盖 URLSession 的取消。
enum DiagnosticFailure {
    /// 有界遍历系统底层错误；即使 userInfo 意外构成循环，也最多保留四层。
    static func causes(_ error: Error) -> [DiagnosticErrorCause] {
        var current: Error? = error
        var result: [DiagnosticErrorCause] = []
        for _ in 0..<4 {
            guard let value = current else { break }
            let ns = value as NSError
            result.append(.init(type: String(reflecting: type(of: value)), code: ns.code))
            current = ns.userInfo[NSUnderlyingErrorKey] as? Error
        }
        return result
    }

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
