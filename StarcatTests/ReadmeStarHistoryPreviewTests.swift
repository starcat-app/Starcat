//
//  ReadmeStarHistoryPreviewTests.swift
//  StarcatTests
//
//  验证 README 末尾 Star History 的 cache-first、隐私门禁、全历史范围和安全渲染。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("README Star History")
struct ReadmeStarHistoryPreviewTests {
    @Test("接近底部后先显示 SQLite 缓存，再等待后台刷新")
    func cachedHistoryAppearsBeforeRefreshCompletes() async {
        let gate = ReadmeStarHistoryLoadGate()
        let cached = Self.snapshot(state: .cached)
        let repository = ReadmeStarHistoryRepositoryStub(
            cachedSnapshot: cached,
            refreshSnapshot: cached,
            refreshGate: gate
        )
        let viewModel = ReadmeStarHistoryViewModel(
            repository: repository,
            projectVisibilityProvider: { _ in .public }
        )

        let load = Task {
            await viewModel.loadIfNeeded(
                repo: Self.repo(),
                databaseScopeRevision: 1,
                locale: Locale(identifier: "en")
            )
        }
        await gate.waitUntilBlocked()

        #expect(viewModel.renderState.html?.contains("starcat-star-history-line") == true)
        #expect(await repository.cachedRanges() == [.all])
        #expect(await repository.refreshRanges() == [.all])

        await gate.release()
        await load.value
    }

    @Test("Internal 仓库不读取历史缓存也不请求远端")
    func internalRepositorySkipsHistory() async {
        let repository = ReadmeStarHistoryRepositoryStub(
            cachedSnapshot: Self.snapshot(state: .cached),
            refreshSnapshot: Self.snapshot(state: .fresh)
        )
        let viewModel = ReadmeStarHistoryViewModel(
            repository: repository,
            projectVisibilityProvider: { _ in .internal }
        )

        await viewModel.loadIfNeeded(
            repo: Self.repo(),
            databaseScopeRevision: 1,
            locale: Locale(identifier: "en")
        )

        #expect(viewModel.renderState.html == nil)
        #expect(await repository.cachedRanges().isEmpty)
        #expect(await repository.refreshRanges().isEmpty)
    }

    @Test("取消后迟到的刷新结果不能重新写入 README")
    func cancelledLoadCannotRestoreOldRepositoryHTML() async {
        let gate = ReadmeStarHistoryLoadGate()
        let repository = ReadmeStarHistoryRepositoryStub(
            cachedSnapshot: Self.snapshot(points: [], state: .cached),
            refreshSnapshot: Self.snapshot(state: .fresh),
            refreshGate: gate
        )
        let viewModel = ReadmeStarHistoryViewModel(
            repository: repository,
            projectVisibilityProvider: { _ in .public }
        )

        let load = Task {
            await viewModel.loadIfNeeded(
                repo: Self.repo(),
                databaseScopeRevision: 1,
                locale: Locale(identifier: "en")
            )
        }
        await gate.waitUntilBlocked()
        viewModel.cancel()
        await gate.release()
        await load.value

        #expect(viewModel.renderState == .empty)
    }

    @Test("取消异步任务后迟到的刷新结果不能写入 README")
    func cancelledTaskCannotApplyDelayedRefresh() async {
        let gate = ReadmeStarHistoryLoadGate()
        let repository = ReadmeStarHistoryRepositoryStub(
            cachedSnapshot: Self.snapshot(points: [], state: .cached),
            refreshSnapshot: Self.snapshot(state: .fresh),
            refreshGate: gate
        )
        let viewModel = ReadmeStarHistoryViewModel(
            repository: repository,
            projectVisibilityProvider: { _ in .public }
        )

        let load = Task {
            await viewModel.loadIfNeeded(
                repo: Self.repo(),
                databaseScopeRevision: 1,
                locale: Locale(identifier: "en")
            )
        }
        await gate.waitUntilBlocked()
        load.cancel()
        await gate.release()
        await load.value

        #expect(viewModel.renderState.html == nil)
    }

    @Test("README 只展示至少两个 GH Archive 全历史点")
    func visibilityRequiresPublicAllRangeGHArchivePoints() {
        let repo = Self.repo()

        #expect(ReadmeStarHistoryVisibilityPolicy.shouldDisplay(
            repo: repo,
            projectVisibility: nil,
            snapshot: Self.snapshot(state: .cached)
        ))
        #expect(!ReadmeStarHistoryVisibilityPolicy.shouldDisplay(
            repo: repo,
            projectVisibility: nil,
            snapshot: Self.snapshot(
                points: Self.points(source: .localSnapshot, precision: .snapshot),
                state: .cached
            )
        ))
        #expect(!ReadmeStarHistoryVisibilityPolicy.shouldDisplay(
            repo: repo,
            projectVisibility: .private,
            snapshot: Self.snapshot(state: .cached)
        ))
    }

    @Test("HTML 转义不能让动态文本注入标签或属性")
    func htmlEscapingCoversTextAndAttributes() {
        let escaped = ReadmeStarHistoryHTMLRenderer.escape("<img src=x onerror='bad'>&\"")

        #expect(escaped == "&lt;img src=x onerror=&#39;bad&#39;&gt;&amp;&quot;")
        #expect(!escaped.contains("<img"))
    }

    @Test("SVG 刻度必须输出 HTML，不能泄漏 GRDB SQL 插值调试描述")
    func renderedHTMLUsesStringFragmentsForAxisTicks() throws {
        let snapshot = Self.snapshot(state: .cached)
        let model = StarHistoryChartRenderModel(
            points: snapshot.points,
            range: .all,
            repositoryCreatedAt: StarHistoryDateCodec.date(from: "2020-01-01")
        )
        let html = try #require(ReadmeStarHistoryHTMLRenderer.render(
            snapshot: snapshot,
            model: model,
            repo: Self.repo(),
            locale: Locale(identifier: "zh-Hans")
        ))

        #expect(!html.contains("GRDB.SQL"))
        #expect(html.contains("starcat-star-history-grid-horizontal"))
        #expect(html.contains("starcat-star-history-axis-y"))
    }

    @Test("图表包含参考样式所需的标题、坐标、面积和末端点")
    func renderedHTMLContainsCompleteChartStructure() throws {
        let points = [
            StarHistoryPoint(
                date: StarHistoryDateCodec.date(from: "2026-07-23")!,
                count: 0,
                source: .ghArchive,
                precision: .estimated,
                fetchedAt: StarHistoryDateCodec.date(from: "2026-09-06")
            ),
            StarHistoryPoint(
                date: StarHistoryDateCodec.date(from: "2026-09-06")!,
                count: 1_165,
                source: .ghArchive,
                precision: .estimated,
                fetchedAt: StarHistoryDateCodec.date(from: "2026-09-06")
            )
        ]
        let snapshot = Self.snapshot(points: points, state: .cached)
        let model = StarHistoryChartRenderModel(
            points: snapshot.points,
            range: .all,
            repositoryCreatedAt: StarHistoryDateCodec.date(from: "2026-07-23"),
            now: StarHistoryDateCodec.date(from: "2026-09-06")!
        )
        let html = try #require(ReadmeStarHistoryHTMLRenderer.render(
            snapshot: snapshot,
            model: model,
            repo: Self.repo(),
            locale: Locale(identifier: "en")
        ))

        #expect(html.contains(#"class="starcat-star-history-card""#))
        #expect(html.contains("GitHub Star History"))
        #expect(html.contains("Powered by"))
        #expect(html.contains("<strong>Starcat</strong>"))
        #expect(html.contains("octo/history"))
        #expect(html.contains(#"class="starcat-star-history-avatar""#))
        #expect(html.contains(#"src="https://github.com/octo.png?size=80""#))
        #expect(html.contains(#"class="starcat-star-history-card-kicker""#))
        #expect(html.contains(#"class="starcat-star-history-current-star""#))
        #expect(html.contains(#"class="starcat-star-history-area""#))
        #expect(html.contains("starcat-star-history-metrics"))
        #expect(html.contains("starcat-star-history-callouts"))
        #expect(html.contains("starcat-star-history-gradient-top"))
        #expect(html.contains(">1.2K</text>"))
        #expect(!html.contains(">1,165</text>"))
        #expect(html.components(separatedBy: "starcat-star-history-axis-y").count - 1 == 5)
    }

    private nonisolated static func repo() -> Repo {
        var repo = Repo.makeMinimal(owner: "octo", name: "history")
        repo.id = 42
        repo.starsCount = 200
        repo.createdAt = "2020-01-01T00:00:00Z"
        repo.cachedAt = "2026-09-06T00:00:00Z"
        return repo
    }

    @Test("整刻度上限覆盖峰值，避免按峰值五等分产生零碎数值", arguments: [0, 1, 9, 99, 1_165, 50_511, 100_001, 999_999, 4_000_000])
    func niceAxisCoversPeak(peak: Int) {
        let axis = ReadmeStarHistoryAxis(peak: peak)
        #expect(axis.maximum >= Double(peak))
        #expect(axis.step >= 1)
        #expect(axis.ticks.count == 5)
        #expect(axis.ticks.first == 0)
        #expect(axis.ticks.last == axis.maximum)
        #expect(Set(axis.ticks).count == 5)
        if peak == 50_511 {
            #expect(axis.ticks == [0, 15_000, 30_000, 45_000, 60_000])
        }
    }

    @Test("90 天统计使用完整日序列，按期初数计算增长率")
    func ninetyDayGrowthUsesBaseline() throws {
        let end = try #require(StarHistoryDateCodec.date(from: "2026-09-06"))
        let points = [
            StarHistoryPoint(date: end.addingTimeInterval(-100 * 86_400), count: 20_000),
            StarHistoryPoint(date: end.addingTimeInterval(-90 * 86_400), count: 38_155),
            StarHistoryPoint(date: end.addingTimeInterval(-89 * 86_400), count: 40_000),
            StarHistoryPoint(date: end, count: 50_495)
        ]
        let metrics = ReadmeStarHistoryMetrics(snapshot: Self.snapshot(points: points, state: .fresh), createdAt: nil)
        #expect(metrics.growth == 12_340)
        #expect(metrics.periodDays == 90)
        #expect(abs(try #require(metrics.dailyAverage) - 12_340.0 / 90) < 0.000001)
        #expect(abs(try #require(metrics.growthRate) - 12_340.0 / 38_155) < 0.000001)
        #expect(metrics.isEstimated)
        #expect(!metrics.sinceCreated)
    }

    @Test("历史不足不能补造零基线，新仓零基线不能显示无穷增长率")
    func incompleteCoverageAndNewRepositoryAreDistinct() throws {
        let end = try #require(StarHistoryDateCodec.date(from: "2026-09-06"))
        let points = [StarHistoryPoint(date: end.addingTimeInterval(-20 * 86_400), count: 10), StarHistoryPoint(date: end, count: 200)]
        let snapshot = Self.snapshot(points: points, state: .cached)
        let old = ReadmeStarHistoryMetrics(snapshot: snapshot, createdAt: end.addingTimeInterval(-200 * 86_400))
        #expect(old.growth == nil)
        #expect(old.growthRate == nil)
        #expect(old.dailyAverage == nil)
        let young = ReadmeStarHistoryMetrics(snapshot: snapshot, createdAt: end.addingTimeInterval(-25 * 86_400), now: end)
        #expect(young.growth == 200)
        #expect(young.growthRate == nil)
        #expect(young.sinceCreated)
        #expect(young.ageDays == 25)
        #expect(young.dailyAverage == 8)
    }

    @Test("日均新增保留负值，不足一天不能强行补成一天")
    func dailyAverageHandlesDeclineAndSameDayCreation() throws {
        let end = try #require(StarHistoryDateCodec.date(from: "2026-09-06"))
        let points = [StarHistoryPoint(date: end.addingTimeInterval(-90 * 86_400), count: 300),
                      StarHistoryPoint(date: end, count: 210)]
        let decline = ReadmeStarHistoryMetrics(snapshot: Self.snapshot(points: points, state: .fresh), createdAt: nil)
        #expect(decline.dailyAverage == -1)
        let sameDay = ReadmeStarHistoryMetrics(snapshot: Self.snapshot(points: points, state: .fresh),
                                              createdAt: end, now: end)
        #expect(sameDay.dailyAverage == nil)
    }

    @Test("相同仓库更新元数据后总数和描述必须原地更新")
    func sameRepositoryMetadataUpdateRebuildsCard() async {
        let snapshot = Self.snapshot(state: .fresh)
        let repository = ReadmeStarHistoryRepositoryStub(cachedSnapshot: snapshot, refreshSnapshot: snapshot)
        let viewModel = ReadmeStarHistoryViewModel(repository: repository, projectVisibilityProvider: { _ in .public })
        var repo = Self.repo()
        await viewModel.loadIfNeeded(repo: repo, databaseScopeRevision: 1, locale: Locale(identifier: "en"))
        let revision = viewModel.renderState.revision
        repo.starsCount = 50_511
        repo.description = "Description from updated metadata"
        await viewModel.loadIfNeeded(repo: repo, databaseScopeRevision: 1, locale: Locale(identifier: "en"))
        #expect(viewModel.renderState.revision != revision)
        #expect(viewModel.renderState.html?.contains("<strong>50.5K</strong>") == true)
        #expect(viewModel.renderState.html?.contains("Description from updated metadata") == true)
    }

    @Test("README 从创建日起画，补点不能给缺历史的老仓制造增长数据", arguments: ["2020-01-01", "2026-07-22"])
    func creationAnchorIsOnlyUsedForDrawing(createdDay: String) async throws {
        let created = try #require(StarHistoryDateCodec.date(from: createdDay))
        let first = try #require(StarHistoryDateCodec.date(from: "2026-08-18"))
        let last = try #require(StarHistoryDateCodec.date(from: "2026-09-07"))
        let points = [StarHistoryPoint(date: first, count: 752, source: .ghArchive, precision: .estimated),
                      StarHistoryPoint(date: last, count: 1_165, source: .ghArchive, precision: .estimated)]
        let snapshot = Self.snapshot(points: points, state: .fresh)
        let repository = ReadmeStarHistoryRepositoryStub(cachedSnapshot: snapshot, refreshSnapshot: snapshot)
        let viewModel = ReadmeStarHistoryViewModel(repository: repository, projectVisibilityProvider: { _ in .public })
        var repo = Self.repo()
        repo.createdAt = createdDay + "T00:00:00Z"
        await viewModel.loadIfNeeded(repo: repo, databaseScopeRevision: 1, locale: Locale(identifier: "en"))
        let html = try #require(viewModel.renderState.html)
        for attribute in ["data-points", "data-rendered"] {
            let prefix = try #require(html.range(of: attribute + "=\""))
            let value = try #require(html[prefix.upperBound...].split(separator: "\"", maxSplits: 1).first)
            let series = try #require(try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [[Double]])
            #expect(series.first == [created.timeIntervalSince1970 * 1_000, 0, 1])
            #expect(series.last?[1] == 1_165)
        }
        #expect(html.contains(#"class="starcat-star-history-line" points="44.00,280.00 "#))
        if createdDay == "2020-01-01" {
            #expect(html.components(separatedBy: "<strong>—</strong>").count - 1 == 3)
        }
        #expect(snapshot.points == points)
    }

    @Test("描述与 Topics 不可注入脚本，总数不能误用历史最后读数")
    func repositoryFieldsAreEscapedAndTotalUsesMetadata() throws {
        var repo = Self.repo()
        repo.starsCount = 50_511
        repo.description = "<script>alert('description')</script>"
        repo.topics = #"["ai", "<img src=x onerror=bad>", "research", "extra"]"#
        let snapshot = Self.snapshot(state: .cached)
        let model = StarHistoryChartRenderModel(points: snapshot.points, range: .all, repositoryCreatedAt: nil)
        let html = try #require(ReadmeStarHistoryHTMLRenderer.render(snapshot: snapshot, model: model, repo: repo, locale: Locale(identifier: "en")))
        #expect(html.contains("<strong>50.5K</strong>"))
        #expect(!html.contains("<script>"))
        #expect(!html.contains("<img src=x"))
        #expect(html.contains("&lt;script&gt;"))
        #expect(html.contains("&lt;img src=x onerror=bad&gt;"))
        #expect(html.contains(">+1</span>"))
    }

    private nonisolated static func points(
        source: StarHistorySource = .ghArchive,
        precision: StarHistoryPrecision = .estimated
    ) -> [StarHistoryPoint] {
        [
            StarHistoryPoint(
                date: StarHistoryDateCodec.date(from: "2020-02-01")!,
                count: 10,
                source: source,
                precision: precision,
                fetchedAt: StarHistoryDateCodec.date(from: "2026-09-05")
            ),
            StarHistoryPoint(
                date: StarHistoryDateCodec.date(from: "2026-09-05")!,
                count: 200,
                source: source,
                precision: precision,
                fetchedAt: StarHistoryDateCodec.date(from: "2026-09-05")
            )
        ]
    }

    private nonisolated static func snapshot(
        points: [StarHistoryPoint] = points(),
        state: StarHistoryRemoteState
    ) -> StarHistorySnapshot {
        StarHistorySnapshot(
            range: .all,
            points: points,
            remoteState: state,
            coverageStart: points.first?.date,
            updatedAt: points.last?.fetchedAt
        )
    }
}

private actor ReadmeStarHistoryRepositoryStub: RepoStarHistoryRepositoryProtocol {
    private let cachedSnapshot: StarHistorySnapshot
    private let refreshSnapshot: StarHistorySnapshot
    private let refreshGate: ReadmeStarHistoryLoadGate?
    private var cachedRangeValues: [StarHistoryRange] = []
    private var refreshRangeValues: [StarHistoryRange] = []

    init(
        cachedSnapshot: StarHistorySnapshot,
        refreshSnapshot: StarHistorySnapshot,
        refreshGate: ReadmeStarHistoryLoadGate? = nil
    ) {
        self.cachedSnapshot = cachedSnapshot
        self.refreshSnapshot = refreshSnapshot
        self.refreshGate = refreshGate
    }

    func points(repoId: Int64) async throws -> [StarHistoryPoint] { [] }

    func cached(repo: Repo, range: StarHistoryRange) async throws -> StarHistorySnapshot {
        cachedRangeValues.append(range)
        return cachedSnapshot
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
        refreshRangeValues.append(range)
        await refreshGate?.block()
        return refreshSnapshot
    }

    func cachedRanges() -> [StarHistoryRange] { cachedRangeValues }
    func refreshRanges() -> [StarHistoryRange] { refreshRangeValues }
}

private actor ReadmeStarHistoryLoadGate {
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var isBlocked = false
    private var isReleased = false

    func block() async {
        isBlocked = true
        blockedContinuation?.resume()
        blockedContinuation = nil
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilBlocked() async {
        guard !isBlocked else { return }
        await withCheckedContinuation { continuation in
            blockedContinuation = continuation
        }
    }

    func release() {
        isReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
