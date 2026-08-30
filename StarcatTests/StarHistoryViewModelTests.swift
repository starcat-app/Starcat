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

    @Test("30 天与一年增长直接读取完整历史统计且允许负数")
    func growthUsesSnapshotStatisticsAndAllowsDecrease() async {
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
                Self.snapshot(
                    range: range,
                    points: points,
                    state: .fresh,
                    statistics: StarHistoryStatisticsBuilder.build(
                        points: points,
                        repositoryCreatedAt: nil
                    )
                )
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
        #expect(viewModel.chartRenderModel.renderedPoints == points)
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
        #expect(viewModel.chartRenderModel.range == .all)
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
        state: StarHistoryRemoteState,
        statistics: StarHistoryStatistics = .empty
    ) -> StarHistorySnapshot {
        StarHistorySnapshot(
            range: range,
            points: points,
            remoteState: state,
            coverageStart: points.first?.date,
            updatedAt: points.last?.fetchedAt,
            statistics: statistics
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

@Suite("Star History Statistics")
struct StarHistoryStatisticsBuilderTests {

    @Test("稀疏历史应向前填充目标日累计值")
    func sparseHistoryCarriesBaselineForward() throws {
        let latest = try #require(StarHistoryDateCodec.date(from: "2026-08-30"))
        let points = [
            point(latest.addingTimeInterval(-45 * 86_400), 100),
            point(latest.addingTimeInterval(-10 * 86_400), 120),
            point(latest, 130, source: .localSnapshot, precision: .snapshot)
        ]

        let statistics = StarHistoryStatisticsBuilder.build(
            points: points,
            repositoryCreatedAt: nil
        )

        #expect(statistics.growth30Days == 30)
        #expect(statistics.averageDailyGrowth30Days == 1)
    }

    @Test("年轻仓库应以创建日零值计算实际窗口")
    func youngRepositoryUsesCreationZeroBaseline() throws {
        let createdAt = try #require(StarHistoryDateCodec.date(from: "2026-08-18"))
        let latest = try #require(StarHistoryDateCodec.date(from: "2026-08-30"))
        let points = [point(latest, 24)]

        let statistics = StarHistoryStatisticsBuilder.build(
            points: points,
            repositoryCreatedAt: createdAt
        )

        #expect(statistics.growth30Days == 24)
        #expect(statistics.averageDailyGrowth30Days == 2)
    }

    @Test("只有本机快照时不得伪造增长")
    func localSnapshotOnlyProducesNoStatistics() throws {
        let createdAt = try #require(StarHistoryDateCodec.date(from: "2026-08-18"))
        let latest = try #require(StarHistoryDateCodec.date(from: "2026-08-30"))

        let statistics = StarHistoryStatisticsBuilder.build(
            points: [point(latest, 24, source: .localSnapshot, precision: .snapshot)],
            repositoryCreatedAt: createdAt
        )

        #expect(statistics == .empty)
    }

    private func point(
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

    @Test("全部范围横轴应从仓库创建时间开始")
    func allRangeStartsAtRepositoryCreation() throws {
        let createdAt = try #require(StarHistoryDateCodec.date(from: "2016-01-10"))
        let firstEvent = try point(
            "2017-03-01",
            10,
            source: .ghArchive,
            precision: .estimated
        )
        let now = try #require(StarHistoryDateCodec.date(from: "2026-08-30"))

        let domain = StarHistoryChartLayoutPolicy.xDomain(
            range: .all,
            repositoryCreatedAt: createdAt,
            points: [firstEvent],
            now: now
        )

        #expect(domain.lowerBound == createdAt)
        #expect(domain.upperBound == now)
    }

    @Test("全部范围应在仓库创建日补零值基线")
    func allRangeAddsZeroCreationBaseline() throws {
        let createdAt = try #require(StarHistoryDateCodec.date(from: "2026-08-03"))
        let firstSnapshot = try point(
            "2026-08-19",
            5,
            source: .localSnapshot,
            precision: .snapshot
        )

        let rendered = StarHistoryChartSeriesBuilder.renderedPoints(
            [firstSnapshot],
            range: .all,
            repositoryCreatedAt: createdAt
        )

        #expect(rendered.count == 2)
        #expect(rendered.first?.date == createdAt)
        #expect(rendered.first?.count == 0)
        #expect(rendered.last == firstSnapshot)
    }

    @Test("全部范围抽稀不得超过上限且必须保留精度交接")
    func allRangeDownsamplesAndKeepsPrecisionBoundary() throws {
        let start = try #require(StarHistoryDateCodec.date(from: "2024-01-01"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let points = try (0..<500).map { index in
            let date = try #require(calendar.date(byAdding: .day, value: index, to: start))
            let isSnapshot = index >= 400
            return StarHistoryPoint(
                date: date,
                count: index * index,
                source: isSnapshot ? .localSnapshot : .ghArchive,
                precision: isSnapshot ? .snapshot : .estimated,
                fetchedAt: date
            )
        }

        let rendered = StarHistoryChartSeriesBuilder.renderedPoints(
            points,
            range: .all,
            repositoryCreatedAt: nil,
            maximumPointCount: 40
        )

        #expect(rendered.count <= 40)
        #expect(rendered.first == points.first)
        #expect(rendered.last == points.last)
        #expect(rendered.contains(points[399]))
        #expect(rendered.contains(points[400]))
    }

    @Test("近期范围也必须限制图表渲染点数量")
    func recentRangesAlsoDownsample() throws {
        let start = try #require(StarHistoryDateCodec.date(from: "2026-01-01"))
        let points = (0..<365).map { index in
            StarHistoryPoint(
                date: start.addingTimeInterval(Double(index) * 86_400),
                count: index,
                source: .ghArchive,
                precision: .estimated
            )
        }

        let rendered = StarHistoryChartSeriesBuilder.renderedPoints(
            points,
            range: .oneYear,
            repositoryCreatedAt: nil
        )

        #expect(rendered.count <= StarHistoryChartSeriesBuilder.oneYearPointLimit)
        #expect(rendered.first == points.first)
        #expect(rendered.last == points.last)
    }

    @Test("图表只标记首尾与精度交接点")
    func landmarksStaySparse() throws {
        let estimatedStart = try point(
            "2026-08-01",
            0,
            source: .ghArchive,
            precision: .estimated
        )
        let estimatedEnd = try point(
            "2026-08-10",
            10,
            source: .ghArchive,
            precision: .estimated
        )
        let snapshotStart = try point(
            "2026-08-11",
            11,
            source: .localSnapshot,
            precision: .snapshot
        )
        let snapshotEnd = try point(
            "2026-08-30",
            30,
            source: .localSnapshot,
            precision: .snapshot
        )

        let landmarks = StarHistoryChartSeriesBuilder.landmarkPoints(
            in: [estimatedStart, estimatedEnd, snapshotStart, snapshotEnd]
        )

        #expect(landmarks == [estimatedStart, snapshotStart, snapshotEnd])
    }

    @Test("近期范围不得早于仓库创建时间")
    func recentRangeDoesNotPredateRepository() throws {
        let createdAt = try #require(StarHistoryDateCodec.date(from: "2026-08-01"))
        let now = try #require(StarHistoryDateCodec.date(from: "2026-08-30"))

        let domain = StarHistoryChartLayoutPolicy.xDomain(
            range: .threeMonths,
            repositoryCreatedAt: createdAt,
            points: [],
            now: now
        )

        #expect(domain.lowerBound == createdAt)
    }

    @Test("全部范围保留零基线而近期范围聚焦实际变化")
    func yDomainDependsOnSelectedRange() throws {
        let first = try point(
            "2026-08-01",
            9_000,
            source: .ghArchive,
            precision: .estimated
        )
        let latest = try point(
            "2026-08-30",
            10_000,
            source: .localSnapshot,
            precision: .snapshot
        )

        let all = StarHistoryChartLayoutPolicy.yDomain(range: .all, points: [first, latest])
        let recent = StarHistoryChartLayoutPolicy.yDomain(
            range: .threeMonths,
            points: [first, latest]
        )

        #expect(all.lowerBound == 0)
        #expect(recent.lowerBound > 0)
        #expect(recent.upperBound > 10_000)
    }

    @Test("横轴刻度应包含完整时间域两端")
    func xAxisDatesIncludeBothDomainEdges() throws {
        let start = try #require(StarHistoryDateCodec.date(from: "2016-01-01"))
        let end = try #require(StarHistoryDateCodec.date(from: "2026-01-01"))

        let values = StarHistoryChartLayoutPolicy.xAxisDates(
            domain: start...end,
            range: .all
        )

        #expect(values.count == 6)
        #expect(values.first == start)
        #expect(values.last == end)
    }

    @Test("年份刻度只应用于相邻刻度至少跨一年的时间域")
    func yearOnlyLabelsRequireYearSizedIntervals() throws {
        let start = try #require(StarHistoryDateCodec.date(from: "2020-01-01"))
        let threeYearsLater = try #require(StarHistoryDateCodec.date(from: "2023-01-01"))
        let tenYearsLater = try #require(StarHistoryDateCodec.date(from: "2030-01-01"))

        #expect(!StarHistoryChartLayoutPolicy.usesYearOnlyAxisLabels(
            domain: start...threeYearsLater
        ))
        #expect(StarHistoryChartLayoutPolicy.usesYearOnlyAxisLabels(
            domain: start...tenYearsLater
        ))
    }

    @Test("半年内的全部范围应显示日级横轴标签")
    func shortAllRangeUsesDayAxisLabels() throws {
        let start = try #require(StarHistoryDateCodec.date(from: "2026-08-03"))
        let shortEnd = try #require(StarHistoryDateCodec.date(from: "2026-08-30"))
        let longEnd = try #require(StarHistoryDateCodec.date(from: "2027-08-30"))

        #expect(StarHistoryChartLayoutPolicy.usesDayAxisLabels(domain: start...shortEnd))
        #expect(!StarHistoryChartLayoutPolicy.usesDayAxisLabels(domain: start...longEnd))
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

@Suite("Star History Restriction Notice Policy")
struct StarHistoryRestrictionNoticePolicyTests {

    @Test("GitHub Stargazers 精确来源不显示访问限制说明")
    func githubStargazersHidesNotice() {
        let points = [point(source: .githubStargazers, precision: .reconstructed)]

        #expect(!StarHistoryRestrictionNoticePolicy.shouldShow(points: points, phase: .content))
    }

    @Test("公共估算数据应显示访问限制说明")
    func estimatedHistoryShowsNotice() {
        let points = [point(source: .discoverySnapshot, precision: .estimated)]

        #expect(
            StarHistoryRestrictionNoticePolicy.shouldShow(
                points: points,
                phase: .content,
                isPrivateRepository: false
            )
        )
    }

    @Test("公开仓仅有本机快照时可显示访问限制说明")
    func localSnapshotOnPublicShowsNotice() {
        let points = [point(source: .localSnapshot, precision: .snapshot)]

        #expect(
            StarHistoryRestrictionNoticePolicy.shouldShow(
                points: points,
                phase: .content,
                isPrivateRepository: false
            )
        )
    }

    @Test("私仓与 privateOnly 不显示公开访问限制说明")
    func privateContextsHidePublicRestrictionNotice() {
        let points = [point(source: .localSnapshot, precision: .snapshot)]

        #expect(
            !StarHistoryRestrictionNoticePolicy.shouldShow(
                points: points,
                phase: .privateOnly,
                isPrivateRepository: true
            )
        )
        #expect(
            !StarHistoryRestrictionNoticePolicy.shouldShow(
                points: points,
                phase: .content,
                isPrivateRepository: true
            )
        )
    }

    @Test("加载或失败状态不应抢占主反馈")
    func transientStatesHideNotice() {
        #expect(!StarHistoryRestrictionNoticePolicy.shouldShow(points: [], phase: .loading))
        #expect(!StarHistoryRestrictionNoticePolicy.shouldShow(points: [], phase: .failed))
    }

    private func point(
        source: StarHistorySource,
        precision: StarHistoryPrecision
    ) -> StarHistoryPoint {
        let date = Date(timeIntervalSince1970: 0)
        return StarHistoryPoint(
            date: date,
            count: 1,
            source: source,
            precision: precision,
            fetchedAt: date
        )
    }
}

@Suite("Star History Display Policy")
struct StarHistoryDisplayPolicyTests {

    @Test("空数据仍显示 Starcat 精确快照图例")
    func emptyPointsKeepSnapshotLegend() {
        #expect(
            StarHistoryDisplayPolicy.legendPrecisions(points: []).map(\.rawValue)
                == [StarHistoryPrecision.snapshot.rawValue]
        )
    }

    @Test("普通仓库只显示 Starcat 精确快照图例")
    func localSnapshotUsesSnapshotLegend() {
        let points = [
            point("2026-07-28", source: .localSnapshot, precision: .snapshot),
            point("2026-07-29", source: .localSnapshot, precision: .snapshot)
        ]

        #expect(
            StarHistoryDisplayPolicy.legendPrecisions(points: points).map(\.rawValue)
                == [StarHistoryPrecision.snapshot.rawValue]
        )
    }

    @Test("我的项目先显示 Starcat 精确快照再显示 GitHub 图例")
    func projectLegendKeepsSnapshotFirst() {
        let points = [
            point("2023-10-22", source: .githubStargazers, precision: .reconstructed),
            point("2026-07-29", source: .localSnapshot, precision: .snapshot)
        ]

        #expect(
            StarHistoryDisplayPolicy.legendPrecisions(points: points).map(\.rawValue)
                == [
                    StarHistoryPrecision.snapshot.rawValue,
                    StarHistoryPrecision.reconstructed.rawValue
                ]
        )
    }

    @Test("未选中图表日期时不产生选中点")
    func noSelectionReturnsNoPoint() {
        let points = [point("2026-07-29", source: .localSnapshot, precision: .snapshot)]

        #expect(StarHistoryDisplayPolicy.selectedPoint(in: points, selectedDate: nil) == nil)
    }

    @Test("选中图表日期时返回最近图表点")
    func selectionReturnsNearestPoint() throws {
        let first = point("2026-07-27", source: .localSnapshot, precision: .snapshot)
        let latest = point("2026-07-29", source: .localSnapshot, precision: .snapshot)
        let selectedDay = try #require(StarHistoryDateCodec.date(from: "2026-07-28"))
        let selectedDate = selectedDay.addingTimeInterval(18 * 60 * 60)

        #expect(
            StarHistoryDisplayPolicy.selectedPoint(
                in: [first, latest],
                selectedDate: selectedDate
            ) == latest
        )
    }

    private func point(
        _ day: String,
        source: StarHistorySource,
        precision: StarHistoryPrecision
    ) -> StarHistoryPoint {
        let date = StarHistoryDateCodec.date(from: day)!
        return StarHistoryPoint(
            date: date,
            count: 1,
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
