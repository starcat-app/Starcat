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

/// 批量标签审核列表的展示筛选。
///
/// `actionable` 沿用既有枚举名，但业务语义只表示仍在排队或处理中的仓库。
enum BatchAIResultFilter: String, CaseIterable, Sendable {
    case actionable
    case pendingReview
    case completed
    case failed
    case ignored
    case all
}

/// 标签整理列表中一个仓库唯一所属的业务状态；`all` 仅是汇总筛选。
enum BatchAIPrimaryState: Int, CaseIterable, Hashable, Sendable {
    case pending
    case pendingReview
    case completed
    case failed
    case ignored
}

@MainActor
@Observable
final class BatchAIQueuePresentationStore {
    var filter: BatchAIResultFilter = .actionable {
        didSet {
            guard filter != oldValue else { return }
            resetPaginationAndRebuild()
        }
    }
    var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            scheduleSearchRebuild()
        }
    }

    private(set) var visibleJobs: [BatchAIJob] = []
    private(set) var totalJobCount = 0
    private(set) var matchingJobCount = 0
    private(set) var canLoadMore = false
    private(set) var primaryStateCounts: [BatchAIPrimaryState: Int] = [:]

    @ObservationIgnored private var visibleLimit = BatchAIQueuePresentationStore.pageSize
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var batchStartedAt: Date?
    @ObservationIgnored private var allJobs: [BatchAIJob] = []
    @ObservationIgnored private var normalizedSearchText = ""

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

    private func scheduleSearchRebuild() {
        searchTask?.cancel()
        let nextSearchText = searchText
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return
            }
            guard let self, !Task.isCancelled, nextSearchText == searchText else { return }
            normalizedSearchText = nextSearchText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedLowercase
            resetPaginationAndRebuild()
        }
    }

    private func synchronize(from service: BatchAIQueueService) {
        if batchStartedAt != service.startedAt {
            batchStartedAt = service.startedAt
            visibleLimit = Self.pageSize
        }
        allJobs = service.jobs
        totalJobCount = allJobs.count
        primaryStateCounts = allJobs.reduce(into: [:]) { counts, job in
            counts[Self.primaryState(for: job), default: 0] += 1
        }
        rebuildVisibleJobs()
    }

    private func rebuildVisibleJobs() {
        let matchingJobs = allJobs.filter { job in
            matchesFilter(job) && matchesSearch(job)
        }
        // 全部视图按主状态分区，同一状态内保留 Service 队列顺序。
        let displayOrder: [BatchAIPrimaryState] = [.pending, .pendingReview, .completed, .failed, .ignored]
        let ordered = displayOrder.flatMap { state in
            matchingJobs.filter { Self.primaryState(for: $0) == state }
        }
        matchingJobCount = ordered.count
        visibleJobs = Array(ordered.prefix(visibleLimit))
        canLoadMore = visibleJobs.count < ordered.count
    }

    private func resetPaginationAndRebuild() {
        visibleLimit = Self.pageSize
        rebuildVisibleJobs()
    }

    private func matchesFilter(_ job: BatchAIJob) -> Bool {
        switch filter {
        case .actionable:
            Self.primaryState(for: job) == .pending
        case .pendingReview:
            Self.primaryState(for: job) == .pendingReview
        case .failed:
            Self.primaryState(for: job) == .failed
        case .completed:
            Self.primaryState(for: job) == .completed
        case .ignored:
            Self.primaryState(for: job) == .ignored
        case .all:
            true
        }
    }

    private func matchesSearch(_ job: BatchAIJob) -> Bool {
        guard !normalizedSearchText.isEmpty else { return true }
        let candidates = [
            job.repoFullName,
            job.repoDescription ?? "",
            job.appliedTagNames.joined(separator: " "),
            job.suggestedTags.map(\.name).joined(separator: " ")
        ]
        return candidates.contains { $0.localizedLowercase.contains(normalizedSearchText) }
    }

    /// 生成状态和人工审核状态在这里合并成唯一分类，避免两个 Tab 各自解释同一组字段。
    static func primaryState(for job: BatchAIJob) -> BatchAIPrimaryState {
        if job.status == .failed { return .failed }
        if case .failed = job.tagReviewState { return .failed }
        if job.status == .ignored || job.tagReviewState == .ignored { return .ignored }
        if job.status == .queued || job.status == .processing { return .pending }
        switch job.tagReviewState {
        case .pending, .applying:
            return .pendingReview
        case .notRequired, .applied:
            return .completed
        case .failed:
            return .failed
        case .ignored:
            return .ignored
        }
    }

    func count(for filter: BatchAIResultFilter) -> Int {
        switch filter {
        case .actionable: primaryStateCounts[.pending, default: 0]
        case .pendingReview: primaryStateCounts[.pendingReview, default: 0]
        case .failed: primaryStateCounts[.failed, default: 0]
        case .completed: primaryStateCounts[.completed, default: 0]
        case .ignored: primaryStateCounts[.ignored, default: 0]
        case .all: totalJobCount
        }
    }
}
