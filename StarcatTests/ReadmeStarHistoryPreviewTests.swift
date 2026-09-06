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
            repositoryName: "octo/history",
            repositoryOwner: "octo",
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
            repositoryName: "octo/<history>",
            repositoryOwner: "octo",
            locale: Locale(identifier: "en")
        ))

        #expect(html.contains(#"class="starcat-star-history-card""#))
        #expect(html.contains("GitHub Star History"))
        #expect(html.contains("Powered by"))
        #expect(html.contains("<strong>Starcat</strong>"))
        #expect(html.contains("octo/&lt;history&gt;"))
        #expect(html.contains(#"class="starcat-star-history-avatar""#))
        #expect(html.contains(#"src="https://github.com/octo.png?size=80""#))
        #expect(html.contains(#"class="starcat-star-history-card-kicker""#))
        #expect(html.contains(#"class="starcat-star-history-current-star""#))
        #expect(html.contains(#"class="starcat-star-history-area""#))
        #expect(html.contains(#"class="starcat-star-history-endpoint""#))
        #expect(html.contains(">1,165</text>"))
        #expect(!html.contains(">1.2K</text>"))
        #expect(html.components(separatedBy: "starcat-star-history-axis-y").count - 1 == 6)
        #expect(html.components(separatedBy: "starcat-star-history-axis-x").count - 1 == 6)
    }

    private nonisolated static func repo() -> Repo {
        var repo = Repo.makeMinimal(owner: "octo", name: "history")
        repo.id = 42
        repo.starsCount = 200
        repo.createdAt = "2020-01-01T00:00:00Z"
        repo.cachedAt = "2026-09-06T00:00:00Z"
        return repo
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
