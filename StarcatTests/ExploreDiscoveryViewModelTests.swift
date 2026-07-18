//
//  ExploreDiscoveryViewModelTests.swift
//  StarcatTests
//
//  探索页 Discovery 列表状态机测试。
//
//  覆盖目标：
//  - ViewModel 使用 bulk 快照在本地完成筛选和排序；
//  - 分类切换时旧 query 不再冒充新 query，上屏前只发布选定的数据源；
//  - 分页追加只增长本地切片，不再走远端分页接口；
//  - 无 bulk 缓存且远端失败时清空列表，避免展示不匹配结果。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Explore Discovery ViewModel", .serialized)
@MainActor
struct ExploreDiscoveryViewModelTests {

    @Test("ExploreMode: Weekly identity / title / discovery normalization")
    func exploreModeWeeklyIdentity() {
        #expect(ExploreMode(rawValue: "weekly") == .weekly)
        #expect(ExploreMode.weekly.id == "weekly")
        #expect(ExploreMode.weekly.localizedTitle == String.l10n("explore.mode.weekly"))
        #expect(ExploreMode.weekly.systemImage == "newspaper")
        #expect(ExploreMode.weekly.usesDiscoveryAPI == false)
        #expect(ExploreMode.weekly.discoveryListMode == nil)
        #expect(ExploreMode.allCases.contains(.weekly))
    }

    @Test("热门列表基于 bulk 本地过滤语言和排序")
    func popularReloadFiltersAndSortsLocalBulk() async throws {
        let repository = FakeDiscoveryRepository()
        await repository.enqueueBulk(Self.makeBulkResult(repos: [
            Self.makeRepo(repoID: 101, owner: "apple", name: "swift-a", language: "Swift", stars: 100, popularityScore: 0.1, categoryRanks: ["popular": 2]),
            Self.makeRepo(repoID: 102, owner: "apple", name: "swift-b", language: "Swift", stars: 200, popularityScore: 0.9, categoryRanks: ["popular": 1]),
            Self.makeRepo(repoID: 103, owner: "golang", name: "go", language: "Go", stars: 1000, popularityScore: 1.0, categoryRanks: ["popular": 3]),
            Self.makeRepo(repoID: 104, owner: "apple", name: "swift-c", language: "Swift", stars: 300, popularityScore: 1.0, categories: [])
        ]))
        let viewModel = ExploreDiscoveryViewModel()

        await viewModel.reload(
            repository: repository,
            mode: .popular,
            language: "Swift",
            topic: nil,
            platform: nil,
            sort: .popular
        )

        #expect(viewModel.repos.map(\.fullName) == ["apple/swift-b", "apple/swift-a"])
        #expect(viewModel.total == 2)
        #expect(viewModel.nextPage == nil)
        #expect(viewModel.loadError == nil)
        #expect(await repository.fetchBulkCount() == 1)
        #expect(await repository.fetchPageCount() == 0)
    }

    @Test("新鲜缓存直接发布且不重复请求远端")
    func freshCachePublishesWithoutRemoteFetch() async throws {
        let repository = FakeDiscoveryRepository()
        await repository.seedCached(
            Self.makeBulkResult(repos: [
                Self.makeRepo(repoID: 120, owner: "cached", name: "popular", categoryRanks: ["popular": 1])
            ]),
            lastFetchedAt: Date().addingTimeInterval(-2 * 60 * 60)
        )
        let viewModel = ExploreDiscoveryViewModel()

        await viewModel.reload(
            repository: repository,
            mode: .popular,
            language: nil,
            topic: nil,
            platform: nil,
            sort: .popular
        )

        let popularIdentity = ExploreDiscoveryViewModel.queryIdentity(
            mode: .popular,
            language: nil,
            topic: nil,
            platform: nil,
            sort: .popular
        )
        let newReleasesIdentity = ExploreDiscoveryViewModel.queryIdentity(
            mode: .newReleases,
            language: nil,
            topic: nil,
            platform: nil,
            sort: .release
        )

        #expect(viewModel.repos.map(\.fullName) == ["cached/popular"])
        #expect(viewModel.publishedQueryIdentity == popularIdentity)
        // View 切到新发布后会立刻发现 identity 不匹配，因此不会继续渲染热门列表。
        #expect(viewModel.publishedQueryIdentity != newReleasesIdentity)
        #expect(viewModel.reposRevision == 1)
        #expect(await repository.fetchBulkCount() == 0)
    }

    @Test("过期缓存等待远端完成后只发布远端快照")
    func staleCacheWaitsForRemoteBeforePublishing() async throws {
        let repository = FakeDiscoveryRepository()
        await repository.seedCached(
            Self.makeBulkResult(repos: [
                Self.makeRepo(repoID: 130, owner: "stale", name: "repo", categoryRanks: ["popular": 1])
            ]),
            lastFetchedAt: Date().addingTimeInterval(-(3 * 60 * 60 + 60))
        )
        await repository.enqueueBulk(Self.makeBulkResult(repos: [
            Self.makeRepo(repoID: 131, owner: "remote", name: "repo", categoryRanks: ["popular": 1])
        ]))
        await repository.pauseNextBulkFetch()
        let viewModel = ExploreDiscoveryViewModel()

        let reloadTask = Task {
            await viewModel.reload(
                repository: repository,
                mode: .popular,
                language: nil,
                topic: nil,
                platform: nil,
                sort: .popular
            )
        }
        await repository.waitForBulkFetchToStart()

        // 远端尚未返回时，过期缓存只作为失败兜底，不能先发布造成二次换榜。
        #expect(viewModel.repos.isEmpty)
        #expect(viewModel.publishedQueryIdentity == nil)
        #expect(viewModel.reposRevision == 0)

        await repository.resumeBulkFetch()
        await reloadTask.value

        #expect(viewModel.repos.map(\.fullName) == ["remote/repo"])
        #expect(viewModel.publishedQueryIdentity != nil)
        #expect(viewModel.reposRevision == 1)
        #expect(await repository.fetchBulkCount() == 1)
    }

    @Test("过期缓存仅在远端失败后作为单次兜底发布")
    func staleCachePublishesOnceAfterRemoteFailure() async throws {
        let repository = FakeDiscoveryRepository()
        await repository.seedCached(
            Self.makeBulkResult(repos: [
                Self.makeRepo(repoID: 135, owner: "fallback", name: "repo", categoryRanks: ["popular": 1])
            ]),
            lastFetchedAt: Date().addingTimeInterval(-(3 * 60 * 60 + 60))
        )
        await repository.setFetchError(FakeDiscoveryError.unavailable)
        let viewModel = ExploreDiscoveryViewModel()

        await viewModel.reload(
            repository: repository,
            mode: .popular,
            language: nil,
            topic: nil,
            platform: nil,
            sort: .popular
        )

        #expect(viewModel.repos.map(\.fullName) == ["fallback/repo"])
        #expect(viewModel.publishedQueryIdentity != nil)
        #expect(viewModel.reposRevision == 1)
        #expect(viewModel.loadError == nil)
        #expect(viewModel.cacheWarning?.isEmpty == false)
        #expect(await repository.fetchBulkCount() == 1)
    }

    @Test("取消的分类请求不会发布结果或遗留 loading")
    func cancelledReloadDoesNotPublish() async throws {
        let repository = FakeDiscoveryRepository()
        await repository.seedCached(
            Self.makeBulkResult(repos: [
                Self.makeRepo(repoID: 140, owner: "stale", name: "repo", categoryRanks: ["popular": 1])
            ]),
            lastFetchedAt: Date().addingTimeInterval(-(3 * 60 * 60 + 60))
        )
        await repository.enqueueBulk(Self.makeBulkResult(repos: [
            Self.makeRepo(repoID: 141, owner: "cancelled", name: "repo", categoryRanks: ["popular": 1])
        ]))
        await repository.pauseNextBulkFetch()
        let viewModel = ExploreDiscoveryViewModel()

        let reloadTask = Task {
            await viewModel.reload(
                repository: repository,
                mode: .popular,
                language: nil,
                topic: nil,
                platform: nil,
                sort: .popular
            )
        }
        await repository.waitForBulkFetchToStart()
        reloadTask.cancel()
        await repository.resumeBulkFetch()
        await reloadTask.value

        #expect(viewModel.repos.isEmpty)
        #expect(viewModel.publishedQueryIdentity == nil)
        #expect(viewModel.reposRevision == 0)
        #expect(!viewModel.isLoading)
        #expect(!viewModel.isRefreshing)
    }

    @Test("bulk 刷新发布同快照 summary 供 Sidebar 更新计数")
    func bulkReloadPublishesSummaryForSidebar() async throws {
        let repository = FakeDiscoveryRepository()
        let summary = DiscoverySummaryDTO(
            modes: [
                DiscoveryModeSummaryDTO(mode: "discover", total: 386, topics: nil, platforms: nil, languages: nil),
                DiscoveryModeSummaryDTO(mode: "popular", total: 351, topics: nil, platforms: nil, languages: nil),
                DiscoveryModeSummaryDTO(mode: "new_releases", total: 110, topics: nil, platforms: nil, languages: nil),
            ],
            generatedAt: "2026-07-18T08:00:00Z"
        )
        await repository.enqueueBulk(Self.makeBulkResult(
            repos: [Self.makeRepo(repoID: 150, owner: "fresh", name: "repo")],
            summary: summary
        ))
        let viewModel = ExploreDiscoveryViewModel()
        let catalogStore = ExploreCatalogStore(repository: repository)

        await viewModel.reload(
            repository: repository,
            mode: .discover,
            language: nil,
            topic: nil,
            platform: nil,
            sort: .recommended
        )
        catalogStore.apply(try #require(viewModel.latestSummary))

        #expect(catalogStore.total(for: .discover) == 386)
        #expect(catalogStore.total(for: .popular) == 351)
        #expect(catalogStore.total(for: .newReleases) == 110)
    }

    @Test("本地分页 meta 驱动 loadMore 追加下一页")
    func loadMoreAppendsNextLocalPage() async throws {
        let repository = FakeDiscoveryRepository()
        let repos = (1...25).map { index in
            Self.makeRepo(
                repoID: Int64(200 + index),
                owner: "page",
                name: "repo-\(String(format: "%02d", index))",
                language: "Swift",
                stars: 100 - index,
                popularityScore: Double(100 - index),
                categoryRanks: ["popular": index]
            )
        }
        await repository.enqueueBulk(Self.makeBulkResult(repos: repos))
        let viewModel = ExploreDiscoveryViewModel()

        await viewModel.reload(
            repository: repository,
            mode: .popular,
            language: "Swift",
            topic: nil,
            platform: nil,
            sort: .popular
        )

        #expect(viewModel.repos.count == 20)
        #expect(viewModel.nextPage == 2)
        let triggerRepo = try #require(viewModel.repos.last)

        await viewModel.loadMoreIfNeeded(
            repository: repository,
            currentRepo: triggerRepo,
            mode: .popular,
            language: "Swift",
            topic: nil,
            platform: nil,
            sort: .popular
        )

        #expect(viewModel.repos.count == 25)
        #expect(viewModel.total == 25)
        #expect(viewModel.nextPage == nil)
        #expect(await repository.fetchPageCount() == 0)
    }

    @Test("新发布列表只展示 new_releases 归属仓库")
    func newReleasesFiltersByCategoryMembership() async throws {
        let repository = FakeDiscoveryRepository()
        await repository.enqueueBulk(Self.makeBulkResult(repos: [
            Self.makeRepo(repoID: 401, owner: "release", name: "new-a", language: "Swift", releaseScore: 0.1, categories: ["new_releases"], categoryRanks: ["new_releases": 2]),
            Self.makeRepo(repoID: 402, owner: "release", name: "new-b", language: "Swift", releaseScore: 0.9, categories: ["new_releases"], categoryRanks: ["new_releases": 1]),
            Self.makeRepo(repoID: 403, owner: "release", name: "old", language: "Swift", releaseScore: 1.0, categories: ["popular"], categoryRanks: ["popular": 1])
        ]))
        let viewModel = ExploreDiscoveryViewModel()

        await viewModel.reload(
            repository: repository,
            mode: .newReleases,
            language: "Swift",
            topic: nil,
            platform: nil,
            sort: .release
        )

        #expect(viewModel.repos.map(\.fullName) == ["release/new-b", "release/new-a"])
        #expect(viewModel.total == 2)
    }

    @Test("新筛选远端错误且无 bulk 缓存时清空列表")
    func reloadServerErrorWithoutCacheClearsListAndStoresError() async throws {
        let repository = FakeDiscoveryRepository()
        await repository.enqueueBulk(Self.makeBulkResult(repos: [
            Self.makeRepo(repoID: 301, owner: "initial", name: "repo", topics: ["ai"], platforms: ["macos"])
        ]))
        let viewModel = ExploreDiscoveryViewModel()

        await viewModel.reload(
            repository: repository,
            mode: .discover,
            language: nil,
            topic: "ai",
            platform: "macos",
            sort: .recommended
        )

        #expect(viewModel.repos.count == 1)

        await repository.clearCache()
        await repository.setFetchError(FakeDiscoveryError.unavailable)

        await viewModel.reload(
            repository: repository,
            mode: .discover,
            language: nil,
            topic: "privacy",
            platform: "linux",
            sort: .recommended
        )

        #expect(viewModel.repos.isEmpty)
        #expect(viewModel.total == 0)
        #expect(viewModel.nextPage == nil)
        #expect(viewModel.loadError?.isEmpty == false)
        #expect(!viewModel.isLoading)
        #expect(!viewModel.isRefreshing)
    }

    @Test("手动刷新失败且有 bulk 缓存时保留列表并展示缓存提示")
    func manualRefreshFailureFallsBackToCachedBulkWithWarning() async throws {
        let repository = FakeDiscoveryRepository()
        await repository.enqueueBulk(Self.makeBulkResult(repos: [
            Self.makeRepo(repoID: 501, owner: "cached", name: "repo", topics: ["ai"], platforms: ["macos"])
        ]))
        let viewModel = ExploreDiscoveryViewModel()

        await viewModel.reload(
            repository: repository,
            mode: .discover,
            language: nil,
            topic: "ai",
            platform: "macos",
            sort: .recommended
        )

        await repository.setFetchError(FakeDiscoveryError.unavailable)

        await viewModel.reload(
            repository: repository,
            mode: .discover,
            language: nil,
            topic: "ai",
            platform: "macos",
            sort: .recommended,
            showsRefreshIndicator: true
        )

        #expect(viewModel.repos.map(\.fullName) == ["cached/repo"])
        #expect(viewModel.loadError == nil)
        #expect(viewModel.cacheWarning?.isEmpty == false)
        #expect(await repository.lastIgnoresCacheValue() == true)
    }

    private nonisolated static func makeBulkResult(
        repos: [DiscoveryRepoDTO],
        summary: DiscoverySummaryDTO = DiscoverySummaryDTO(
            modes: [],
            generatedAt: "2026-06-30T10:00:00Z"
        )
    ) -> DiscoveryBulkResult {
        DiscoveryBulkResult(
            repos: repos,
            summary: summary,
            etag: "W/test",
            generatedAt: "2026-06-30T10:00:00Z",
            total: repos.count
        )
    }

    private nonisolated static func makeRepo(
        repoID: Int64,
        owner: String,
        name: String,
        language: String = "Swift",
        stars: Int = 1000,
        topics: [String] = ["tools"],
        platforms: [String] = ["macos"],
        popularityScore: Double = 1,
        discoveryScore: Double = 1,
        releaseScore: Double = 1,
        categories: [String] = ["popular"],
        categoryRanks: [String: Int] = ["popular": 1]
    ) -> DiscoveryRepoDTO {
        let fullName = "\(owner)/\(name)"
        var repo = DiscoveryRepoDTO(
            repoID: repoID,
            fullName: fullName,
            owner: owner,
            name: name,
            description: "A repository for discovery tests.",
            homepage: nil,
            language: language,
            stars: stars,
            forks: 100,
            watchers: 1000,
            subscribers: 20,
            openIssues: 5,
            ownerAvatar: nil,
            defaultBranch: "main",
            licenseSpdx: "MIT",
            topics: topics,
            platforms: platforms,
            pushedAt: "2026-06-29T00:00:00Z",
            updatedAt: "2026-06-29T00:00:00Z",
            createdAt: "2025-01-01T00:00:00Z",
            isArchived: false,
            isFork: false,
            latestReleaseTag: "1.0.0",
            latestReleaseAt: "2026-06-28T00:00:00Z",
            latestReleaseURL: "https://github.com/\(fullName)/releases/tag/1.0.0",
            releaseDownloadCount: 42,
            rank: 1,
            score: discoveryScore,
            reasons: ["Active repository"],
            signals: [
                DiscoverySignalDTO(code: "release", label: "Recent release", value: "1.0.0")
            ],
            categories: categories,
            categoryRanks: categoryRanks
        )
        repo.popularityScore = popularityScore
        repo.discoveryScore = discoveryScore
        repo.releaseScore = releaseScore
        repo.trendingScore = popularityScore
        repo.searchScore = Double(stars)
        return repo
    }
}

private enum FakeDiscoveryError: Error {
    case unavailable
}

private actor FakeDiscoveryRepository: DiscoveryRepositoryProtocol {

    private var cached: DiscoveryBulkCachedSnapshot?
    private var fetchQueue: [DiscoveryBulkResult] = []
    private var fetchError: Error?
    private var bulkFetches = 0
    private var pageFetches = 0
    private var shouldPauseNextBulkFetch = false
    private var bulkFetchHasStarted = false
    private var bulkFetchStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var bulkFetchResumeContinuation: CheckedContinuation<Void, Never>?

    func cachedPage(mode: DiscoveryListMode, query: DiscoveryListQuery) async -> DiscoveryCachedPage? {
        nil
    }

    func fetchPage(mode: DiscoveryListMode, query: DiscoveryListQuery) async throws -> DiscoveryCachedPage {
        pageFetches += 1
        throw FakeDiscoveryError.unavailable
    }

    func cachedBulk() async -> DiscoveryBulkCachedSnapshot? {
        cached
    }

    func fetchBulk(ignoresCache: Bool) async throws -> DiscoveryBulkFetchResult {
        bulkFetches += 1
        lastIgnoresCache = ignoresCache
        if shouldPauseNextBulkFetch {
            shouldPauseNextBulkFetch = false
            bulkFetchHasStarted = true
            let waiters = bulkFetchStartWaiters
            bulkFetchStartWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                bulkFetchResumeContinuation = continuation
            }
        }
        if let fetchError {
            if let cached {
                let result = DiscoveryBulkResult(
                    repos: cached.repos,
                    summary: cached.summary,
                    etag: cached.etag,
                    generatedAt: cached.generatedAt,
                    total: cached.total
                )
                return DiscoveryBulkFetchResult(
                    result: result,
                    source: .cachedFallback,
                    fallbackErrorDescription: fetchError.localizedDescription
                )
            }
            throw fetchError
        }
        guard !fetchQueue.isEmpty else {
            throw FakeDiscoveryError.unavailable
        }
        let result = fetchQueue.removeFirst()
        cached = DiscoveryBulkCachedSnapshot(
            repos: result.repos,
            summary: result.summary,
            etag: result.etag,
            lastFetchedAt: Date(),
            generatedAt: result.generatedAt,
            total: result.total
        )
        return DiscoveryBulkFetchResult(
            result: result,
            source: .remote,
            fallbackErrorDescription: nil
        )
    }

    func cachedSummary() async -> DiscoverySummaryDTO? {
        cached?.summary
    }

    func fetchSummary() async throws -> DiscoverySummaryDTO {
        cached?.summary ?? DiscoverySummaryDTO(modes: [], generatedAt: nil)
    }

    func clearCache() async {
        cached = nil
    }

    func enqueueBulk(_ result: DiscoveryBulkResult) {
        fetchQueue.append(result)
    }

    func seedCached(_ result: DiscoveryBulkResult, lastFetchedAt: Date) {
        cached = DiscoveryBulkCachedSnapshot(
            repos: result.repos,
            summary: result.summary,
            etag: result.etag,
            lastFetchedAt: lastFetchedAt,
            generatedAt: result.generatedAt,
            total: result.total
        )
    }

    /// 测试门闩：让断言有机会观察“缓存已判定过期、远端尚未返回”的中间状态。
    func pauseNextBulkFetch() {
        shouldPauseNextBulkFetch = true
        bulkFetchHasStarted = false
    }

    func waitForBulkFetchToStart() async {
        if bulkFetchHasStarted { return }
        await withCheckedContinuation { continuation in
            bulkFetchStartWaiters.append(continuation)
        }
    }

    func resumeBulkFetch() {
        bulkFetchResumeContinuation?.resume()
        bulkFetchResumeContinuation = nil
    }

    func setFetchError(_ error: Error?) {
        fetchError = error
    }

    func fetchBulkCount() -> Int {
        bulkFetches
    }

    private var lastIgnoresCache: Bool?

    func lastIgnoresCacheValue() -> Bool? {
        lastIgnoresCache
    }

    func fetchPageCount() -> Int {
        pageFetches
    }
}
