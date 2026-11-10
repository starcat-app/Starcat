//
//  AppBackgroundTaskSnapshot.swift
//  Starcat
//
//  工具栏和状态面板共用的即时任务投影；只读现有服务，不执行数据库查询或启动任何工作。
//

import Foundation

/// 单一计数口径：任务数来自可展示的行，而不是把不同服务的剩余仓库数相加。
struct AppBackgroundTaskSnapshot: Equatable {
    let tasks: [AppBackgroundTask]

    /// 只在父任务确实拥有 README 阶段时合并；独立预取与其它预热阶段仍是不同工作。
    init(tasks: [AppBackgroundTask], warmupOwnsReadme: Bool = false) {
        let hasWarmup = tasks.contains { $0.kind == .warmup }
        self.tasks = tasks.filter { !(warmupOwnsReadme && hasWarmup && $0.kind == .readme) }
    }

    var count: Int { tasks.count }
    var isRunning: Bool { tasks.contains { $0.phase.isRunning } }
    var needsAttention: Bool { tasks.contains { $0.phase.needsAttention } }
    var captionKey: String {
        if tasks.isEmpty { return "toolbar.status.tasks.idleCaption" }
        if isRunning { return "toolbar.backgroundTasks.running" }
        // 待确认与失败都需要关注，但摘要不能把正常等待用户确认的结果说成失败。
        if tasks.contains(where: { $0.phase == .failed }) { return "toolbar.backgroundTasks.failed" }
        if tasks.contains(where: { $0.phase == .review }) { return "toolbar.backgroundTasks.review" }
        if tasks.contains(where: { $0.phase == .paused }) { return "toolbar.backgroundTasks.paused" }
        return "toolbar.backgroundTasks.waiting"
    }

    /// 在真正执行打开或取消前再检查实时投影，避免旧行回调误开空的整理开始页。
    func task(_ id: AppBackgroundTask.ID) -> AppBackgroundTask? { tasks.first { $0.id == id } }

    /// 单例任务沿用按类型查询；多实例操作必须传入完整 ID，避免误选另一个下载。
    func task(_ kind: AppBackgroundTask.Kind) -> AppBackgroundTask? {
        task(.init(kind: kind))
    }

    @MainActor
    static func current(_ dependencies: AppDependencies) -> Self {
        let grouping = dependencies.githubStarListAIGroupingSession
        let batch = dependencies.batchAIQueueService
        let warmup = dependencies.initialWarmupCoordinator
        let readme = dependencies.readmePrefetchService
        var tasks: [AppBackgroundTask] = []

        if grouping.mode == .manual {
            if let task = AppBackgroundTask.organization(.grouping(grouping), kind: .grouping,
                                                         canCancel: grouping.isRunning && !grouping.isApplying, opensWindow: true) {
                tasks.append(task)
            }
        } else if grouping.isRunning || grouping.isApplying {
            // 人工分组窗口会 prepareManualContext 并停止自动分析；查看自动任务不能改变执行模式。
            let state: AIOrganizationBannerState = grouping.isApplying
                ? .applying(processed: grouping.applicationProgress?.processedRepositoryCount ?? 0,
                            total: grouping.applicationProgress?.totalRepositoryCount ?? 0)
                : .analyzing(processed: grouping.analyzedCount, total: grouping.analysisTotalCount)
            if let task = AppBackgroundTask.organization(state, kind: .grouping,
                                                         canCancel: grouping.isRunning, opensWindow: false) {
                tasks.append(task)
            }
        }
        if let task = AppBackgroundTask.organization(.tags(batch), kind: .tags,
                                                     canCancel: batch.isRunning && !batch.isApplyingSuggestedTags, opensWindow: true) {
            tasks.append(task)
        }
        if warmup.isActive {
            let phase: AppBackgroundTask.Phase = warmup.isRunning ? .running : (warmup.job?.phase == .paused ? .paused : .waiting)
            let detail: AppBackgroundTask.Detail
            switch warmup.job?.phase {
            case .readme: detail = .progress(processed: warmup.job?.readmeCovered ?? 0, total: warmup.job?.readmeTotal ?? 0)
            case .openSSF: detail = .progress(processed: warmup.openSSFCovered, total: warmup.openSSFTotal)
            case .health: detail = .progress(processed: warmup.job?.healthCovered ?? 0, total: warmup.job?.healthTotal ?? 0)
            default: detail = .none
            }
            tasks.append(.init(id: .warmup, phase: phase, detail: detail, canCancel: warmup.canCancelCurrentRun))
        }
        // 首次预热复用相同 README 服务；其 README 阶段只展示父任务，不能再计一次子任务。
        let warmupOwnsReadme = warmup.isRunning && (warmup.job?.phase == .readme
            || (readme.isRunning && !dependencies.readmePrefetchPoller.isDraining))
        if readme.isRunning || dependencies.readmePrefetchPoller.isDraining {
            tasks.append(.init(id: .readme, phase: .running,
                               detail: .progress(processed: readme.processed, total: readme.total),
                               canCancel: dependencies.readmePrefetchPoller.isDraining))
        } else if case .waitingForRetry = readme.status {
            tasks.append(.init(id: .readme, phase: .failed))
        } else if case .coolingDown = readme.status {
            tasks.append(.init(id: .readme, phase: .waiting))
        }
        let openSSF = dependencies.openSSFScorePoller
        if openSSF.isRefreshing {
            tasks.append(.init(id: .openSSF, phase: .running,
                               detail: .progress(processed: openSSF.refreshProcessed, total: openSSF.refreshTotal), canCancel: true))
        }
        let health = dependencies.repoHealthPoller
        if health.isRefreshing {
            tasks.append(.init(id: .health, phase: .running,
                               detail: .progress(processed: health.refreshProcessed, total: health.refreshTotal), canCancel: true))
        }
        // 读取设置页使用的同一个索引器，不维护第二份进度或启动额外任务。
        let repositoryIndex = dependencies.semanticIndexBuilder
        if let task = AppBackgroundTask.repositoryIndex(
            status: repositoryIndex.status, processed: repositoryIndex.processed,
            total: repositoryIndex.total, failures: repositoryIndex.failures
        ) {
            tasks.append(task)
        }
        switch dependencies.knowledgeRAGIndexBuilder.status {
        case let .fetchingReadmes(processed, total), let .building(processed, total), let .embedding(processed, total):
            tasks.append(.init(id: .indexing, phase: .running,
                               detail: .progress(processed: processed, total: total), canCancel: true, opensWindow: true))
        case .failed:
            // 不把内部错误字符串放进状态浮层；详情与重试继续由知识库窗口负责。
            tasks.append(.init(id: .indexing, phase: .failed, opensWindow: true))
        case .idle, .completed: break
        }
        for entry in LocalAIModelCatalog.entries {
            if let task = AppBackgroundTask.modelInstall(
                state: LocalAIModelManager.shared.installState(for: entry.id),
                id: entry.id, name: entry.displayName
            ) {
                tasks.append(task)
            }
        }
        let laya = LayaDecisionModelCatalog.multilingual
        if let task = AppBackgroundTask.modelInstall(
            state: LayaDecisionModelManager.shared.installState,
            id: laya.id, name: laya.displayName, isLaya: true
        ) {
            tasks.append(task)
        }
        if let task = AppBackgroundTask.screensaverAvatars(
            progress: dependencies.screensaverRefreshCoordinator.avatarProgress, channel: .current
        ) {
            tasks.append(task)
        }
        if let task = AppBackgroundTask.chatHistoryMigration(isMigrating: dependencies.diskChatHistoryStore.isMigrating) {
            tasks.append(task)
        }
        if DistributionChannel.current.isDirect {
            for runtime in DownloadableRuntime.allCases {
                if let task = AppBackgroundTask.runtimeInstall(runtime, state: RuntimeDownloadManager.shared.state(for: runtime)) {
                    tasks.append(task)
                }
            }
        }
        return Self(tasks: tasks, warmupOwnsReadme: warmupOwnsReadme)
    }
}
