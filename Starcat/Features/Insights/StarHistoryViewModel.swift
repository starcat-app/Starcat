//
//  StarHistoryViewModel.swift
//  Starcat
//
//  仓库 Star 趋势区块的独立状态机。
//
//  关键约束：
//  - Star 范围不复用 PR / Issue / Commit 的 activityRange。
//  - 首屏先显示 SQLite cache，再刷新远端；远端失败只追加 stale 提示，不清空曲线。
//  - generation 与 Task cancellation 双重防护，快速切仓库 / 切范围时旧响应不能覆盖新状态。
//  - 202 最多自动轮询三次，随后停在 building，必须由用户手动刷新。
//

import Foundation

enum StarHistoryViewPhase: Equatable, Sendable {
    case idle
    case loading
    case content
    case building
    case stale(StarHistoryAPIError)
    case privateOnly
    case unavailable
    case failed
}

@MainActor
@Observable
final class StarHistoryViewModel {
    typealias Sleep = @Sendable (TimeInterval) async throws -> Void

    private static let maximumAutomaticPolls = 3
    private static let maximumPollDelay: TimeInterval = 10

    private let repository: any RepoStarHistoryRepositoryProtocol
    private let sleep: Sleep
    private var generation: UInt64 = 0

    private(set) var activeRepoID: Int64?
    private(set) var range: StarHistoryRange = .oneYear
    private(set) var phase: StarHistoryViewPhase = .idle
    private(set) var snapshot: StarHistorySnapshot?
    private(set) var chartRenderModel: StarHistoryChartRenderModel = .empty
    private(set) var isRefreshing = false

    init(
        repository: any RepoStarHistoryRepositoryProtocol,
        sleep: @escaping Sleep = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.repository = repository
        self.sleep = sleep
    }

    var points: [StarHistoryPoint] {
        snapshot?.points ?? []
    }

    var currentStars: Int? {
        snapshot?.points.last?.count
    }

    var latestChange: Int? {
        guard let points = snapshot?.points, points.count >= 2 else {
            return nil
        }
        return points[points.count - 1].count - points[points.count - 2].count
    }

    var growth30Days: Int? {
        snapshot?.statistics.growth30Days
    }

    var growthOneYear: Int? {
        snapshot?.statistics.growthOneYear
    }

    /// Repository 已按完整历史和实际有效窗口统一计算，范围切换不会改变指标。
    var averageDailyGrowth30Days: Double? {
        snapshot?.statistics.averageDailyGrowth30Days
    }

    /// 把一年窗口折算为平均月增量，用于比较不同量级仓库的增长速度。
    var averageMonthlyGrowthOneYear: Double? {
        snapshot?.statistics.averageMonthlyGrowthOneYear
    }

    var coverageStart: Date? {
        snapshot?.coverageStart
    }

    var updatedAt: Date? {
        snapshot?.updatedAt
    }

    func load(repo: Repo) async {
        await load(repo: repo, preserveVisibleSnapshot: false)
    }

    /// 范围切换与仓库切换的保留策略不同：
    /// - 同仓库切范围时保留当前曲线，目标范围返回后再整体替换；
    /// - 切仓库时立即清空，禁止短暂显示上一个仓库的 Star 数据。
    private func load(repo: Repo, preserveVisibleSnapshot: Bool) async {
        generation &+= 1
        let requestedGeneration = generation
        activeRepoID = repo.id
        if !preserveVisibleSnapshot {
            snapshot = nil
            chartRenderModel = .empty
        }
        phase = .loading
        // 切范围也驱动 Sync 转圈，与手动刷新、其它 SyncIconButton 统一。
        isRefreshing = preserveVisibleSnapshot
        defer {
            if owns(requestedGeneration, repoID: repo.id) {
                isRefreshing = false
            }
        }

        do {
            let cached = try await repository.cached(repo: repo, range: range)
            guard owns(requestedGeneration, repoID: repo.id) else { return }
            // 目标范围没有缓存时继续展示原曲线；空缓存不是一份值得覆盖 UI 的新数据。
            if !preserveVisibleSnapshot || !cached.points.isEmpty || snapshot == nil {
                applySnapshot(cached, repo: repo)
                apply(cached.remoteState)
            }
        } catch is CancellationError {
            return
        } catch {
            guard owns(requestedGeneration, repoID: repo.id) else { return }
            phase = snapshot == nil ? .failed : .stale(.transport(error.localizedDescription))
            return
        }

        await refreshLoop(
            repo: repo,
            forceRefresh: false,
            requestedGeneration: requestedGeneration
        )
    }

    func selectRange(_ newRange: StarHistoryRange, repo: Repo) async {
        guard range != newRange else { return }
        range = newRange
        await load(repo: repo, preserveVisibleSnapshot: true)
    }

    func refresh(repo: Repo) async {
        guard !isRefreshing else { return }
        generation &+= 1
        let requestedGeneration = generation
        activeRepoID = repo.id
        isRefreshing = true
        await refreshLoop(
            repo: repo,
            forceRefresh: true,
            requestedGeneration: requestedGeneration
        )
        if owns(requestedGeneration, repoID: repo.id) {
            isRefreshing = false
        }
    }

    /// README 模式和仓库切换都调用这里；即使底层网络来不及真正取消，也不能再写回 UI。
    func cancel() {
        generation &+= 1
        isRefreshing = false
    }

    private func refreshLoop(
        repo: Repo,
        forceRefresh: Bool,
        requestedGeneration: UInt64
    ) async {
        var automaticPolls = 0
        var shouldForceRefresh = forceRefresh

        while owns(requestedGeneration, repoID: repo.id), !Task.isCancelled {
            let refreshed: StarHistorySnapshot
            do {
                refreshed = try await repository.refresh(
                    repo: repo,
                    range: range,
                    forceRefresh: shouldForceRefresh
                )
            } catch is CancellationError {
                return
            } catch {
                guard owns(requestedGeneration, repoID: repo.id) else { return }
                phase = snapshot == nil ? .failed : .stale(.transport(error.localizedDescription))
                return
            }
            guard owns(requestedGeneration, repoID: repo.id) else { return }

            applySnapshot(refreshed, repo: repo)
            apply(refreshed.remoteState)
            guard case .building(let retryAfter) = refreshed.remoteState,
                  automaticPolls < Self.maximumAutomaticPolls
            else {
                return
            }

            automaticPolls += 1
            shouldForceRefresh = true
            do {
                let delay = min(max(retryAfter, 0), Self.maximumPollDelay)
                try await sleep(delay)
            } catch {
                return
            }
        }
    }

    private func apply(_ state: StarHistoryRemoteState) {
        switch state {
        case .cached, .fresh, .notModified:
            phase = snapshot?.points.isEmpty == false ? .content : .unavailable
        case .building:
            phase = .building
        case .privateOnly:
            phase = .privateOnly
        case .stale(let error):
            phase = .stale(error)
        case .unavailable:
            phase = .unavailable
        }
    }

    /// 图表抽稀和分组只跟 Snapshot 生命周期一起更新；洞察页滚动不再重复处理完整日级序列。
    private func applySnapshot(_ newSnapshot: StarHistorySnapshot, repo: Repo) {
        snapshot = newSnapshot
        chartRenderModel = StarHistoryChartRenderModel(
            points: newSnapshot.points,
            range: newSnapshot.range,
            repositoryCreatedAt: repo.createdAt.flatMap(ISO8601DateFormatter.githubDate(from:))
        )
    }

    private func owns(_ requestedGeneration: UInt64, repoID: Int64) -> Bool {
        generation == requestedGeneration && activeRepoID == repoID
    }
}
