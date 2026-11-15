//
//  DailyRecommendationPreparation.swift
//  Starcat
//
//  每日推荐准备任务的单一所有者。宿主任务和卡片操作各有生命周期，
//  必须显式传递用户取消，不能依赖非结构化 Task 自动继承取消。
//

import Foundation
import Observation

/// 启动预取可以在关闭入口后继续；用户打开或换批创建的任务则随用户取消。
@MainActor
@Observable
final class DailyRecommendationPreparation {
    enum Origin {
        case background
        case user
    }

    private(set) var isRunning = false
    private var isSuspended = false
    private var task: Task<Bool, Never>?
    private var taskID: UUID?
    private var key: String?
    private var origin: Origin?

    /// 相同身份共享结果；身份变化先等旧任务取消完成，避免 Store 的 isLoading 吞掉新请求。
    func run(
        key: String, origin: Origin,
        operation: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        guard !Task.isCancelled, !isSuspended else { return false }
        if let task {
            if self.key == key {
                let value = await result(of: task, cancelsWithCaller: origin == .user && self.origin == .user)
                return value && !Task.isCancelled
            }
            let previousID = taskID
            task.cancel()
            _ = await task.value
            if taskID == previousID { finish() }
            guard !Task.isCancelled else { return false }
            return await run(key: key, origin: origin, operation: operation)
        }
        let id = UUID()
        let task = Task { @MainActor in await operation() }
        self.task = task
        taskID = id
        self.key = key
        self.origin = origin
        isRunning = true
        let value = await result(of: task, cancelsWithCaller: origin == .user)
        if taskID == id { finish() }
        return value && !Task.isCancelled
    }

    /// 关闭覆盖层不取消独立启动预取，但必须取消尚未替换批次的用户换批。
    func cancelUserPreparation() {
        if origin == .user { task?.cancel() }
    }

    /// 账号切换或宿主销毁不保留旧身份任务。
    func cancel() {
        task?.cancel()
    }

    /// 恢复出厂期间拒绝新准备；等待已有任务退出后才能删除账号文件。
    func suspendAndWait() async {
        isSuspended = true
        let previousID = taskID
        task?.cancel()
        _ = await task?.value
        if taskID == previousID { finish() }
    }

    /// 重置编排结束（包括失败）后解除屏障，后续登录可以正常准备。
    func resume() {
        isSuspended = false
    }

    private func finish() {
        task = nil
        taskID = nil
        key = nil
        origin = nil
        isRunning = false
    }

    private func result(of task: Task<Bool, Never>, cancelsWithCaller: Bool) async -> Bool {
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            if cancelsWithCaller { task.cancel() }
        }
    }
}
