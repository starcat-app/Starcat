//
//  DiagnosticDeadline.swift
//  Starcat
//
//  单项采集有明确预算；超时不等待不合作的采集器，迟到结果只能被丢弃。
//

import Foundation

/// 一次完成盒只保护 continuation，不持有业务对象或主线程锁。
private final class DiagnosticCompletion<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Never>?

    init(_ continuation: CheckedContinuation<Value?, Never>) { self.continuation = continuation }

    func finish(_ value: Value?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

/// collector 的返回值都为安全值快照；超时只影响包完整性，不取消用户业务。
enum DiagnosticDeadline {
    static func capture<Value: Sendable>(seconds: TimeInterval = 2,
                                        _ body: @escaping @Sendable () async -> Value) async -> Value? {
        await withCheckedContinuation { continuation in
            let completion = DiagnosticCompletion(continuation)
            let task = Task { completion.finish(await body()) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
                completion.finish(nil)
                task.cancel()
            }
        }
    }
}
