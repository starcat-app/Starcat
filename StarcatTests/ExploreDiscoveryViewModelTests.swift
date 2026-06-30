//
//  ExploreDiscoveryViewModelTests.swift
//  StarcatTests
//
//  探索页 Discovery 列表状态机测试。
//
//  覆盖目标：
//  - ViewModel 使用 bulk 快照在本地完成筛选和排序；
//  - 分页追加只增长本地切片，不再走远端分页接口；
//  - 无 bulk 缓存且远端失败时清空列表，避免展示不匹配结果。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Explore Discovery ViewModel", .serialized)
@MainActor
struct ExploreDiscoveryViewModelTests {

    @Test("热门列表基于 bulk 本地过滤语言和排序")
    func popularReloadFiltersAndSortsLocalBulk() async throws {
        let repository = FakeDiscoveryRepository()
        await repository.enqueueBulk(Self.makeBulkResult(repos: [
            Self.makeRepo(repoID: 101, owner: "apple", name: "swift-a", language: "Swift", stars: 100, popularityScore: 0.1),
            Self.makeRepo(repoID: 102, owner: "apple", name: "swift-b", language: "Swift", stars: 200, popularityScore: 0.9),
            Self.makeRepo(repoID: 103, owner: "golang", name: "go", language: "Go", stars: 1000, popularityScore: 1.0)
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
                popularityScore: Double(100 - index)
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

    private nonisolated static func makeBulkResult(repos: [DiscoveryRepoDTO]) -> DiscoveryBulkResult {
        DiscoveryBulkResult(
            repos: repos,
            summary: DiscoverySummaryDTO(modes: [], generatedAt: "2026-06-30T10:00:00Z"),
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
        releaseScore: Double = 1
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
            ]
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

    func fetchBulk() async throws -> DiscoveryBulkResult {
        bulkFetches += 1
        if let fetchError {
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
        return result
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

    func setFetchError(_ error: Error?) {
        fetchError = error
    }

    func fetchBulkCount() -> Int {
        bulkFetches
    }

    func fetchPageCount() -> Int {
        pageFetches
    }
}
