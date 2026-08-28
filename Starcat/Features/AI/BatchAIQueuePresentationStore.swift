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
/// `actionable` 同时包含生成失败和待人工确认项，作为默认入口避免用户漏掉仍需处理的仓库。
enum BatchAIResultFilter: String, CaseIterable, Sendable {
    case actionable
    case pendingReview
    case failed
    case completed
    case ignored
    case all
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
        rebuildVisibleJobs()
    }

    private func rebuildVisibleJobs() {
        let matchingJobs = allJobs.filter { job in
            matchesFilter(job) && matchesSearch(job)
        }
        let failed = matchingJobs.filter { $0.status == .failed }
        let pendingReview = matchingJobs.filter {
            $0.status != .failed && Self.needsTagReview($0)
        }
        let others = matchingJobs.filter {
            $0.status != .failed && !Self.needsTagReview($0)
        }
        let ordered = failed + pendingReview + others
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
            job.status == .queued
                || job.status == .processing
                || job.status == .failed
                || Self.needsTagReview(job)
        case .pendingReview:
            Self.needsTagReview(job)
        case .failed:
            job.status == .failed
        case .completed:
            job.status == .completed && !Self.needsTagReview(job)
        case .ignored:
            job.status == .ignored || job.tagReviewState == .ignored
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

    private static func needsTagReview(_ job: BatchAIJob) -> Bool {
        switch job.tagReviewState {
        case .pending, .applying, .failed:
            true
        case .notRequired, .applied, .ignored:
            false
        }
    }
}
