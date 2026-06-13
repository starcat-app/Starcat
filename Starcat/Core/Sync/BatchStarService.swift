//
//  BatchStarService.swift
//  Starcat
//
//  多选批量 star / unstar 的后台任务调度服务（W12 toolbar 专项 PR-3）。
//
//  设计目标：
//  - 单串行 Task：避免并发对 GitHub API 打高峰；
//  - 复用 `StarActionService` 现有 star / unstar 入口 → DB + registry 写入路径保持唯一
//    （绝对不在本类型里直接调 apiClient / repoRepository，破坏"写入路径唯一"契约）；
//  - 每条执行前用 `StarredRegistry.contains(ghRepoId:)` 复核当前 star 状态，已是
//    目标态的直接 `skipped += 1`（dong4j 明确要求：trending / weekly / activity
//    多选时混合状态要静默跳过冲突项）；
//  - 节流：每条之间 sleep 200ms（5 req/s，远低于 GitHub 已认证用户 5000 req/h）；
//  - 连续 5 次失败自动停（保护用户 API 配额 + 网络故障护栏）；
//  - UI 通过 `progress` / `isRunning` 订阅状态变化；`completionSummary` 在
//    任务结束后写一次，给调用方弹 toast / 摘要 sheet。
//
//  关键约束：
//  - `@MainActor`：所有状态读写均在主线程，与 SwiftUI Observation 一致；
//    实际 await 调 API / DB 时由 `StarActionService` 内部 actor 隔离负责跨线程；
//  - 同一时刻只允许跑一个批次：`enqueue` 时如果 `isRunning == true` 直接 no-op
//    并日志告警（业务上 UI 已经禁用入口按钮，进到这里属编程错误）；
//  - `cancel()` 标记取消但**不回滚已写入**的 DB / registry —— 与单条 star 失败语义对齐
//    （成功的成功、失败的失败，不做 transactional rollback）；
//

import Foundation
import Observation

/// 批量 star / unstar 的最小目标描述。
///
/// 为什么用 struct 而非 `Repo`：trending / weekly 列表项是 ephemeral，没有完整
/// `Repo` 实例；而 batch star/unstar 真正只需要 `ghRepoId` + `owner` + `name`。
/// 抽出 `BatchStarTarget` 后 Manage / Trending / Weekly / Activity 四个场景的
/// 入参形态完全统一，BatchStarService 不再依赖 Repo 模型。
struct BatchStarTarget: Equatable, Identifiable {
    /// GitHub repo ID。registry 的 contains 查询 + DB markUnstarred 都用它。
    let ghRepoId: Int64
    let owner: String
    let name: String

    var id: Int64 { ghRepoId }
    var fullName: String { "\(owner)/\(name)" }

    /// 从已 star 的本地 `Repo` 构造（Manage 路径）。
    static func from(repo: Repo) -> BatchStarTarget {
        BatchStarTarget(ghRepoId: repo.id, owner: repo.owner, name: repo.name)
    }
}

/// 批量 star / unstar 调度服务。
@MainActor
@Observable
final class BatchStarService {

    /// 批量操作类型。
    enum Action: Equatable {
        case star
        case unstar

        /// 目标态：执行前 `registry.contains(ghRepoId:) == expectedRegistryState` 即跳过。
        ///
        /// - `.star`：目标态是「已 star」，已 star 的跳过；
        /// - `.unstar`：目标态是「未 star」，未 star 的跳过。
        fileprivate var expectedRegistryStateAfter: Bool {
            switch self {
            case .star:   return true
            case .unstar: return false
            }
        }

        /// 友好日志名。
        var logTag: String {
            switch self {
            case .star:   return "batch-star"
            case .unstar: return "batch-unstar"
            }
        }
    }

    /// 单次批量任务的进度快照。
    ///
    /// 全部字段都是值类型字段；`progress = Progress(...)` 整体替换以触发一次 Observation 变更，
    /// 避免一帧内多个字段分别变化导致 UI 闪屏。
    struct Progress: Equatable {
        var total: Int = 0
        var completed: Int = 0
        var succeeded: Int = 0
        var skipped: Int = 0
        var failed: Int = 0
        /// 当前正在处理的 repo fullName（owner/name），UI 显示「处理中：apple/swift」。
        var currentFullName: String?
    }

    /// 单次任务结束后的摘要，用于驱动结束 toast。
    /// `nil` 表示「上一次任务尚未结束 / 已被消费」。
    struct Summary: Equatable {
        let action: Action
        let total: Int
        let succeeded: Int
        let skipped: Int
        let failed: Int
        let wasCancelled: Bool
    }

    /// 当前进度。任务未启动时为 nil。
    private(set) var progress: Progress?

    /// 是否有任务在跑。UI 用这个值禁用「再开一个批次」按钮。
    private(set) var isRunning: Bool = false

    /// 任务结束摘要。UI 在收到后展示 toast 后应主动调 `consumeSummary()`。
    private(set) var completionSummary: Summary?

    // MARK: - 内部状态

    private let starActionService: StarActionService
    private let registry: StarredRegistry

    /// 当前批次的 Task 引用。`cancel()` 调用它的 `cancel()`，循环里靠 `Task.isCancelled` 退出。
    private var currentTask: Task<Void, Never>?

    /// 每条请求之间的节流（默认 200ms）。
    /// 暴露为 var 仅供单元测试调成 0 加速；产线只能走默认值。
    var throttleDelay: Duration = .milliseconds(200)

    /// 连续失败的容忍度。超过即整体停。
    /// 同样暴露为 var 供测试调整。
    var maxConsecutiveFailures: Int = 5

    init(starActionService: StarActionService, registry: StarredRegistry) {
        self.starActionService = starActionService
        self.registry = registry
    }

    // MARK: - 外部 API

    /// 提交一批目标进行 star / unstar。
    ///
    /// - parameter targets: 目标列表（PR-4 改用 `BatchStarTarget`，统一兼容
    ///   Manage / Trending / Weekly / Activity 四个场景）；空列表直接 no-op。
    /// - parameter action: 操作类型。
    ///
    /// **同一时刻只允许跑一个批次**：若 `isRunning == true` 则直接 no-op + 日志告警。
    /// UI 入口按钮应据 `isRunning` 禁用，避免触发本守卫。
    func enqueue(targets: [BatchStarTarget], action: Action) {
        guard !targets.isEmpty else {
            AppLog.sync.notice("[\(action.logTag, privacy: .public)] enqueue empty; ignored")
            return
        }
        guard !isRunning else {
            AppLog.sync.error("[\(action.logTag, privacy: .public)] enqueue while running; ignored (UI bug)")
            return
        }

        isRunning = true
        progress = Progress(total: targets.count)
        completionSummary = nil

        currentTask = Task { [weak self] in
            await self?.runBatch(targets: targets, action: action)
        }
    }

    /// 取消当前批次。已写入 DB / registry 的不回滚。
    func cancel() {
        currentTask?.cancel()
    }

    /// UI 消费完成 toast 后调用，清空 `completionSummary`。
    /// 不在 `enqueue` 开头清空：避免 toast 还没消失就被同一帧的 enqueue 清掉。
    func consumeSummary() {
        completionSummary = nil
    }

    // MARK: - 串行循环

    /// 真正的批量执行体。
    ///
    /// 单 for 循环串行处理；每条 await `try?` 调 StarActionService 复用现有写入路径。
    /// 失败次数 / 连续失败次数都在循环内累加，结束时统一写入 `completionSummary`。
    private func runBatch(targets: [BatchStarTarget], action: Action) async {
        var snapshot = progress ?? Progress(total: targets.count)
        var consecutiveFailures = 0
        var wasCancelled = false

        for target in targets {
            if Task.isCancelled {
                wasCancelled = true
                break
            }

            snapshot.currentFullName = target.fullName
            progress = snapshot

            // 1) 复核当前 registry 状态：已是目标态则跳过
            //    star 已 star → skip；unstar 已未 star → skip。
            let nowStarred = registry.contains(ghRepoId: target.ghRepoId)
            if nowStarred == action.expectedRegistryStateAfter {
                snapshot.skipped += 1
                snapshot.completed += 1
                progress = snapshot
                AppLog.sync.info("[\(action.logTag, privacy: .public)] skip \(target.fullName, privacy: .public) (already in target state)")
                // 不节流：skip 不发请求
                continue
            }

            // 2) 调 StarActionService 复用单条入口（DB + registry 写入路径唯一）
            do {
                switch action {
                case .star:
                    _ = try await starActionService.star(owner: target.owner, repo: target.name)
                case .unstar:
                    try await starActionService.unstar(
                        ghRepoId: target.ghRepoId,
                        owner: target.owner,
                        name: target.name
                    )
                }
                snapshot.succeeded += 1
                consecutiveFailures = 0
                AppLog.sync.info("[\(action.logTag, privacy: .public)] ok \(target.fullName, privacy: .public)")
            } catch is CancellationError {
                wasCancelled = true
                break
            } catch {
                snapshot.failed += 1
                consecutiveFailures += 1
                AppLog.sync.error("[\(action.logTag, privacy: .public)] fail \(target.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                if consecutiveFailures >= maxConsecutiveFailures {
                    AppLog.sync.error("[\(action.logTag, privacy: .public)] aborting after \(self.maxConsecutiveFailures, privacy: .public) consecutive failures")
                    break
                }
            }

            snapshot.completed += 1
            progress = snapshot

            // 3) 节流（200ms / 条）
            //    skip 路径不进这里。
            if !Task.isCancelled {
                try? await Task.sleep(for: throttleDelay)
            }
        }

        // 收尾：把 currentFullName 清掉，写完成摘要 + 标记 isRunning=false
        snapshot.currentFullName = nil
        progress = snapshot
        completionSummary = Summary(
            action: action,
            total: snapshot.total,
            succeeded: snapshot.succeeded,
            skipped: snapshot.skipped,
            failed: snapshot.failed,
            wasCancelled: wasCancelled || Task.isCancelled
        )
        isRunning = false
        currentTask = nil

        AppLog.sync.notice("[\(action.logTag, privacy: .public)] done: total=\(snapshot.total) succeeded=\(snapshot.succeeded) skipped=\(snapshot.skipped) failed=\(snapshot.failed) cancelled=\(wasCancelled, privacy: .public)")
    }
}
