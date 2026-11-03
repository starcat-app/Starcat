//
//  UndoStarCleanupScheduler.swift
//  Starcat
//
//  Undo Star 历史记录后台清理调度器。
//
//  设计：
//  - App 启动后延迟 15 分钟执行首次清理
//  - 之后每 6 小时通过 Task.sleep 循环执行
//  - 保留时间从 AppSettings.undoStarRetentionDays 读取（-1 = 永久不清）
//  - 仅删除 undo_star_history 表中的过期行，不动 repos 表
//  - 实际删除了数据后广播 .undoStarHistoryDidChange，驱动各界面同步刷新
//

import Foundation

@MainActor
@Observable
final class UndoStarCleanupScheduler {

    private let repository: any UndoStarHistoryRepositoryProtocol
    private let settings: AppSettings

    /// 状态面板用：最近一次清理时间。
    private(set) var lastCleanupAt: Date?
    /// 状态面板用：最近一次清理删除了多少条。
    private(set) var lastCleanupCount: Int = 0
    /// 当前是否正在清理中。
    private(set) var isCleaning: Bool = false

    private var cleanupTask: Task<Void, Never>?

    init(repository: any UndoStarHistoryRepositoryProtocol, settings: AppSettings) {
        self.repository = repository
        self.settings = settings
    }

    /// 启动后台清理循环（App 启动时调用一次即可）。
    func start() {
        guard cleanupTask == nil else { return }
        cleanupTask = Task {
            // 首次延迟 15 分钟执行
            try? await Task.sleep(for: .seconds(15 * 60))
            guard !Task.isCancelled else { return }
            await cleanupNow()

            // 之后每 6 小时执行一次
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(6 * 60 * 60))
                guard !Task.isCancelled else { break }
                await cleanupNow()
            }
        }
    }

    func stop() {
        cleanupTask?.cancel()
        cleanupTask = nil
    }

    /// 按当前设置的保留天数执行一次清理。`retentionDays = -1` 时跳过（永久保留）。
    /// 返回删除条数。
    @discardableResult
    func cleanupNow() async -> Int {
        let retentionDays = settings.undoStarRetentionDays
        guard retentionDays > 0 else { return 0 }  // -1 = 永久，不清

        isCleaning = true
        defer { isCleaning = false }

        let cutoff = ISO8601DateFormatter.shared.string(
            from: Date().addingTimeInterval(-TimeInterval(retentionDays * 24 * 60 * 60))
        )
        do {
            let count = try await repository.cleanupExpired(before: cutoff)
            lastCleanupAt = Date()
            lastCleanupCount = count
            if count > 0 {
                AppLog.sync.info("UndoStar cleanup: removed \(count, privacy: .public) expired records (>\(retentionDays, privacy: .public)d)")
                postHistoryDidChange()
            }
            return count
        } catch {
            AppLog.sync.error("UndoStar cleanup failed: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }

    /// 设置页「立即删除」入口：无视保留天数，清空全部 Undo Star 历史。
    ///
    /// 为什么不复用 cleanupNow：保留期内的记录（用户刚取消 Star 的）不属于「过期」，
    /// cleanupNow 一条都不会删；而按钮旁边的计数展示的是全部保留数，
    /// 用户预期点击后该分类清空。永久保留（-1）只豁免自动清理，不拦手动全删。
    @discardableResult
    func deleteAllNow() async -> Int {
        isCleaning = true
        defer { isCleaning = false }

        do {
            let countBefore = try await repository.count()
            guard countBefore > 0 else {
                lastCleanupAt = Date()
                lastCleanupCount = 0
                return 0
            }
            try await repository.clearAll()
            lastCleanupAt = Date()
            lastCleanupCount = countBefore
            AppLog.sync.info("UndoStar delete-now: removed all \(countBefore, privacy: .public) retained records")
            postHistoryDidChange()
            return countBefore
        } catch {
            AppLog.sync.error("UndoStar delete-now failed: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }

    /// 删除成功后广播：Activity 列表、侧栏计数、设置页保留计数都监听此通知刷新。
    private func postHistoryDidChange() {
        NotificationCenter.default.post(name: .undoStarHistoryDidChange, object: nil)
    }
}
