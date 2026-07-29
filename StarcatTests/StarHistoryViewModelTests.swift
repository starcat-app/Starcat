//
//  StarHistoryViewModelTests.swift
//  StarcatTests
//
//  验证 Star 趋势状态机的范围、增长派生、有界轮询和旧请求隔离。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Star History ViewModel")
@MainActor
struct StarHistoryViewModelTests {

    @Test("building 最多自动轮询三次")
    func buildingPollingIsBounded() async {
        let repository = StubStarHistoryRepository(
            cachedHandler: { _, range in
                Self.snapshot(range: range, state: .cached)
            },
            refreshHandler: { _, range, _ in
                Self.snapshot(range: range, state: .building(retryAfter: 30))
            }
        )
        let viewModel = StarHistoryViewModel(
            repository: repository,
            sleep: { _ in }
        )

        await viewModel.load(repo: Self.fixtureRepo(id: 1))

        #expect(await repository.refreshCount() == 4)
        #expect(viewModel.phase == .building)
        #expect(viewModel.isRefreshing == false)
    }

    @Test("30 天与一年增长允许负数并按最近基准点派生")
    func growthUsesNearestBaselineAndAllowsDecrease() async {
        let latest = StarHistoryDateCodec.date(from: "2026-07-27")!
        let points = [
            Self.point(latest.addingTimeInterval(-365 * 86_400), 130),
            Self.point(latest.addingTimeInterval(-30 * 86_400), 115),
            Self.point(latest, 100, source: .localSnapshot, precision: .snapshot)
        ]
        let repository = StubStarHistoryRepository(
            cachedHandler: { _, range in
                Self.snapshot(range: range, state: .cached)
            },
            refreshHandler: { _, range, _ in
                Self.snapshot(range: range, points: points, state: .fresh)
            }
        )
        let viewModel = StarHistoryViewModel(repository: repository)

        await viewModel.load(repo: Self.fixtureRepo(id: 2))

        #expect(viewModel.currentStars == 100)
        #expect(viewModel.latestChange == -15)
        #expect(viewModel.growth30Days == -15)
        #expect(viewModel.growthOneYear == -30)
        #expect(viewModel.averageDailyGrowth30Days == -0.5)
        #expect(viewModel.averageMonthlyGrowthOneYear == -2.5)
        #expect(viewModel.phase == StarHistoryViewPhase.content)
    }

    @Test("较慢旧仓库响应不得覆盖新仓库")
    func staleRepositoryGenerationIsDiscarded() async {
        let repository = StubStarHistoryRepository(
            cachedHandler: { _, range in
                Self.snapshot(range: range, state: .cached)
            },
            refreshHandler: { repo, range, _ in
                if repo.id == 1 {
                    try await Task.sleep(for: .milliseconds(100))
                }
                return Self.snapshot(
                    range: range,
                    points: [Self.point("2026-07-27", Int(repo.id))],
                    state: .fresh
                )
            }
        )
        let viewModel = StarHistoryViewModel(repository: repository)

        let oldLoad = Task { await viewModel.load(repo: Self.fixtureRepo(id: 1)) }
        try? await Task.sleep(for: .milliseconds(15))
        await viewModel.load(repo: Self.fixtureRepo(id: 2))
        await oldLoad.value

        #expect(viewModel.activeRepoID == 2)
        #expect(viewModel.currentStars == 2)
    }

    @Test("Star 范围独立切换并传递给 Repository")
    func selectingRangeReloadsIndependentHistoryRange() async {
        let repository = StubStarHistoryRepository(
            cachedHandler: { _, range in
                Self.snapshot(range: range, state: .cached)
            },
            refreshHandler: { _, range, _ in
                Self.snapshot(range: range, state: .unavailable)
            }
        )
        let viewModel = StarHistoryViewModel(repository: repository)
        let repo = Self.fixtureRepo(id: 3)

        await viewModel.load(repo: repo)
        await viewModel.selectRange(.all, repo: repo)

        #expect(viewModel.range == .all)
        #expect(await repository.requestedRanges() == [.oneYear, .all])
    }

    @Test("切换 Star 范围期间保留现有曲线")
    func selectingRangeKeepsVisibleSnapshotUntilTargetRangeArrives() async {
        let loadGate = StarHistoryLoadGate()
        let currentPoint = Self.point("2026-07-27", 10)
        let targetPoint = Self.point("2026-07-27", 20)
        let repository = StubStarHistoryRepository(
            cachedHandler: { _, range in
                if range == .all {
                    await loadGate.block()
                    return Self.snapshot(range: range, points: [], state: .cached)
                }
                return Self.snapshot(range: range, points: [currentPoint], state: .cached)
            },
            refreshHandler: { _, range, _ in
                Self.snapshot(
                    range: range,
                    points: [range == .all ? targetPoint : currentPoint],
                    state: .fresh
                )
            }
        )
        let viewModel = StarHistoryViewModel(repository: repository)
        let repo = Self.fixtureRepo(id: 6)
        await viewModel.load(repo: repo)

        let rangeTask = Task {
            await viewModel.selectRange(.all, repo: repo)
        }
        await loadGate.waitUntilBlocked()

        #expect(viewModel.range == .all)
        #expect(viewModel.currentStars == 10)
        #expect(viewModel.isRefreshing)

        await loadGate.release()
        await rangeTask.value

        #expect(viewModel.currentStars == 20)
        #expect(viewModel.phase == .content)
        #expect(!viewModel.isRefreshing)
    }

    @Test("私有、陈旧、不可用与失败状态应稳定映射")
    func remoteStatesMapToStablePhases() async {
        let repo = Self.fixtureRepo(id: 4)
        let cases: [(StarHistoryRemoteState, StarHistoryViewPhase)] = [
            (.privateOnly, .privateOnly),
            (.stale(.providerUnavailable), .stale(.providerUnavailable)),
            (.unavailable, .unavailable),
            (.building(retryAfter: 0), .building)
        ]

        for (state, expectedPhase) in cases {
            let repository = StubStarHistoryRepository(
                cachedHandler: { _, range in
                    Self.snapshot(range: range, state: .cached)
                },
                refreshHandler: { _, range, _ in
                    Self.snapshot(range: range, state: state)
                }
            )
            let viewModel = StarHistoryViewModel(
                repository: repository,
                sleep: { _ in throw CancellationError() }
            )

            await viewModel.load(repo: repo)

            #expect(viewModel.phase == expectedPhase)
        }

        let failedRepository = StubStarHistoryRepository(
            cachedHandler: { _, _ in throw StarHistoryViewModelTestError.failed },
            refreshHandler: { _, range, _ in
                Self.snapshot(range: range, state: .fresh)
            }
        )
        let failedViewModel = StarHistoryViewModel(repository: failedRepository)
        await failedViewModel.load(repo: repo)
        #expect(failedViewModel.phase == .failed)
    }

    @Test("单快照可显示当前值但不伪造增长")
    func singleSnapshotDoesNotInventGrowth() async {
        let point = Self.point(
            "2026-07-27",
            88,
            source: .localSnapshot,
            precision: .snapshot
        )
        let repository = StubStarHistoryRepository(
            cachedHandler: { _, range in
                Self.snapshot(range: range, points: [point], state: .privateOnly)
            },
            refreshHandler: { _, range, _ in
                Self.snapshot(range: range, points: [point], state: .privateOnly)
            }
        )
        let viewModel = StarHistoryViewModel(repository: repository)

        await viewModel.load(repo: Self.fixtureRepo(id: 5))

        #expect(viewModel.currentStars == 88)
        #expect(viewModel.latestChange == nil)
        #expect(viewModel.growth30Days == nil)
        #expect(viewModel.growthOneYear == nil)
        #expect(viewModel.averageDailyGrowth30Days == nil)
        #expect(viewModel.averageMonthlyGrowthOneYear == nil)
        #expect(viewModel.phase == .privateOnly)
    }

    private nonisolated static func snapshot(
        range: StarHistoryRange,
        points: [StarHistoryPoint] = [],
        state: StarHistoryRemoteState
    ) -> StarHistorySnapshot {
        StarHistorySnapshot(
            range: range,
            points: points,
            remoteState: state,
            coverageStart: points.first?.date,
            updatedAt: points.last?.fetchedAt
        )
    }

    private nonisolated static func fixtureRepo(id: Int64) -> Repo {
        var repo = Repo.makeMinimal(owner: "octo", name: "history-\(id)")
        repo.id = id
        repo.starsCount = Int(id)
        repo.cachedAt = "2026-07-27T00:00:00Z"
        return repo
    }

    private nonisolated static func point(
        _ day: String,
        _ count: Int,
        source: StarHistorySource = .ghArchive,
        precision: StarHistoryPrecision = .estimated
    ) -> StarHistoryPoint {
        point(
            StarHistoryDateCodec.date(from: day)!,
            count,
            source: source,
            precision: precision
        )
    }

    private nonisolated static func point(
        _ date: Date,
        _ count: Int,
        source: StarHistorySource = .ghArchive,
        precision: StarHistoryPrecision = .estimated
    ) -> StarHistoryPoint {
        StarHistoryPoint(
            date: date,
            count: count,
            source: source,
            precision: precision,
            fetchedAt: date
        )
    }
}

@Suite("Star History Chart Series")
struct StarHistoryChartSeriesBuilderTests {

    @Test("重建历史切换到单个本机快照时应生成桥接段")
    func reconstructedHistoryConnectsToSnapshot() throws {
        let reconstructed = try point(
            "2023-10-22",
            15,
            source: .githubStargazers,
            precision: .reconstructed
        )
        let snapshot = try point(
            "2026-07-29",
            15,
            source: .localSnapshot,
            precision: .snapshot
        )

        let bridges = StarHistoryChartSeriesBuilder.bridges(in: [reconstructed, snapshot])

        #expect(bridges.count == 1)
        #expect(bridges.first?.start == reconstructed)
        #expect(bridges.first?.end == snapshot)
        #expect(bridges.first?.inheritedPrecision == .reconstructed)
    }

    @Test("同一精度的连续点不得重复生成桥接段")
    func samePrecisionDoesNotCreateBridge() throws {
        let first = try point(
            "2023-10-21",
            14,
            source: .githubStargazers,
            precision: .reconstructed
        )
        let second = try point(
            "2023-10-22",
            15,
            source: .githubStargazers,
            precision: .reconstructed
        )

        #expect(StarHistoryChartSeriesBuilder.bridges(in: [first, second]).isEmpty)
    }

    private func point(
        _ day: String,
        _ count: Int,
        source: StarHistorySource,
        precision: StarHistoryPrecision
    ) throws -> StarHistoryPoint {
        let date = try #require(StarHistoryDateCodec.date(from: day))
        return StarHistoryPoint(
            date: date,
            count: count,
            source: source,
            precision: precision,
            fetchedAt: date
        )
    }
}

private enum StarHistoryViewModelTestError: Error {
    case failed
}

private actor StarHistoryLoadGate {
    private var blockedWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var isBlocked = false
    private var isReleased = false

    func block() async {
        isBlocked = true
        blockedWaiter?.resume()
        blockedWaiter = nil
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilBlocked() async {
        guard !isBlocked else { return }
        await withCheckedContinuation { continuation in
            blockedWaiter = continuation
        }
    }

    func release() {
        isReleased = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor StubStarHistoryRepository: RepoStarHistoryRepositoryProtocol {
    typealias CachedHandler = @Sendable (Repo, StarHistoryRange) async throws -> StarHistorySnapshot
    typealias RefreshHandler = @Sendable (
        Repo,
        StarHistoryRange,
        Bool
    ) async throws -> StarHistorySnapshot

    private let cachedHandler: CachedHandler
    private let refreshHandler: RefreshHandler
    private var refreshCalls = 0
    private var ranges: [StarHistoryRange] = []

    init(
        cachedHandler: @escaping CachedHandler,
        refreshHandler: @escaping RefreshHandler
    ) {
        self.cachedHandler = cachedHandler
        self.refreshHandler = refreshHandler
    }

    func points(repoId: Int64) async throws -> [StarHistoryPoint] {
        []
    }

    func cached(repo: Repo, range: StarHistoryRange) async throws -> StarHistorySnapshot {
        try await cachedHandler(repo, range)
    }

    func recordLocalSnapshot(
        repoId: Int64,
        starsCount: Int,
        observedAt: Date,
        fetchedAt: Date
    ) async throws {}

    func replaceRemotePoints(repoId: Int64, points: [StarHistoryPoint]) async throws {}

    func refresh(
        repo: Repo,
        range: StarHistoryRange,
        forceRefresh: Bool
    ) async throws -> StarHistorySnapshot {
        refreshCalls += 1
        ranges.append(range)
        return try await refreshHandler(repo, range, forceRefresh)
    }

    func refreshCount() -> Int {
        refreshCalls
    }

    func requestedRanges() -> [StarHistoryRange] {
        ranges
    }
}
