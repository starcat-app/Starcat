//
//  SearchDiscoveryDeadline.swift
//  Starcat
//
//  搜索阶段共用同轮截止时间。超时结束上层等待，底层任务自行退出后释放资源。
//

import Foundation

/// TaskGroup 离开作用域时会等待全部子任务，不能约束不及时响应取消的模型。
/// 这里仅让首个结果恢复调用方；迟到结果丢弃，但不提前释放 Provider 持有的资源。
@MainActor
enum SearchDiscoveryDeadline {
    static func run<Value: Sendable>(
        until deadline: Date,
        operation: @escaping @MainActor @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        guard deadline > Date() else { throw URLError(.timedOut) }
        let race = SearchDiscoveryDeadlineRace<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
                let work = Task {
                    do {
                        try Task.checkCancellation()
                        let value = try await operation()
                        try Task.checkCancellation()
                        guard Date() < deadline else { throw URLError(.timedOut) }
                        race.resolve(.success(value))
                    } catch {
                        race.resolve(.failure(error))
                    }
                }
                let timer = Task {
                    do {
                        try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                        race.resolve(.failure(URLError(.timedOut)))
                    } catch {
                        // 正常完成或用户取消会取消计时任务，不能再伪造一次超时。
                    }
                }
                race.attach([work, timer])
            }
        } onCancel: {
            race.resolve(.failure(CancellationError()))
        }
    }
}

/// 取消处理器不运行在 MainActor；锁只保护一次性恢复状态，不跨 await 持有。
private final class SearchDiscoveryDeadlineRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var result: Result<Value, any Error>?
    private var tasks: [Task<Void, Never>] = []

    func install(_ continuation: CheckedContinuation<Value, any Error>) {
        let completed: Result<Value, any Error>? = lock.withLock {
            if let result { return result }
            self.continuation = continuation
            return nil
        }
        if let completed { continuation.resume(with: completed) }
    }

    func attach(_ tasks: [Task<Void, Never>]) {
        let isFinished = lock.withLock {
            guard result == nil else { return true }
            self.tasks = tasks
            return false
        }
        if isFinished { tasks.forEach { $0.cancel() } }
    }

    /// 在锁外恢复 continuation / 取消任务，避免取消回调重入同一把锁。
    func resolve(_ result: Result<Value, any Error>) {
        let pending = lock.withLock { () -> (CheckedContinuation<Value, any Error>?, [Task<Void, Never>])? in
            guard self.result == nil else { return nil }
            self.result = result
            let pending = (continuation, tasks)
            continuation = nil
            tasks = []
            return pending
        }
        guard let pending else { return }
        pending.0?.resume(with: result)
        pending.1.forEach { $0.cancel() }
    }
}
