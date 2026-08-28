//
//  BatchAIQueuePresentationStore.swift
//  Starcat
//
//  批量 AI 队列面板的分页展示缓存。
//
//  关键约束：BatchAIQueueService 仍持有完整任务状态；本类型只缓存按 100 条渐进加载的
//  展示快照，并合并短时间内连续完成的任务更新，避免 SwiftUI body 对近 2,000 个 job
//  反复过滤、排序和创建枚举数组。
//

import Foundation
import Observation

@MainActor
@Observable
final class BatchAIQueuePresentationStore {
    private(set) var visibleJobs: [BatchAIJob] = []
    private(set) var totalJobCount = 0
    private(set) var canLoadMore = false

    @ObservationIgnored private var visibleLimit = BatchAIQueuePresentationStore.pageSize
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var batchStartedAt: Date?
    @ObservationIgnored private var allJobs: [BatchAIJob] = []

    private static let pageSize = 100

    /// 连续完成的仓库会快速递增 revision；延迟 20ms 后只生成一次分页快照。
    func scheduleSynchronize(from service: BatchAIQueueService) {
        refreshTask?.cancel()
        let revision = service.presentationRevision
        refreshTask = Task { [weak self, weak service] in
            guard let self, let service else { return }
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return
            }
            guard !Task.isCancelled, revision == service.presentationRevision else { return }
            synchronize(from: service)
        }
    }

    func synchronizeImmediately(from service: BatchAIQueueService) {
        refreshTask?.cancel()
        synchronize(from: service)
    }

    func loadMore() {
        guard canLoadMore else { return }
        visibleLimit += Self.pageSize
        rebuildVisibleJobs()
    }

    private func synchronize(from service: BatchAIQueueService) {
        if batchStartedAt != service.startedAt {
            batchStartedAt = service.startedAt
            visibleLimit = Self.pageSize
        }
        allJobs = service.jobs
        totalJobCount = allJobs.count
        rebuildVisibleJobs()
    }

    private func rebuildVisibleJobs() {
        let failed = allJobs.filter { $0.status == .failed }
        let pendingReview = allJobs.filter {
            $0.status != .failed && Self.needsTagReview($0)
        }
        let others = allJobs.filter {
            $0.status != .failed && !Self.needsTagReview($0)
        }
        let ordered = failed + pendingReview + others
        visibleJobs = Array(ordered.prefix(visibleLimit))
        canLoadMore = visibleJobs.count < ordered.count
    }

    private static func needsTagReview(_ job: BatchAIJob) -> Bool {
        switch job.tagReviewState {
        case .pending, .applying, .failed:
            true
        case .notRequired, .applied, .ignored:
            false
        }
    }
}
