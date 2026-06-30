//
//  ExploreDiscoveryViewModelTests.swift
//  StarcatTests
//
//  探索页 Discovery 列表状态机测试。
//
//  覆盖目标:
//  - ViewModel 把 mode / language / topic / platform / sort 转成 repository query;
//  - 服务端分页 meta 能驱动 ViewModel 追加下一页;
//  - 新筛选无缓存且远端失败时清空旧列表,避免展示不匹配的结果。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Explore Discovery ViewModel", .serialized)
@MainActor
struct ExploreDiscoveryViewModelTests {

    @Test("热门列表透传语言和排序参数")
    func popularReloadPassesLanguageAndSortQuery() async throws {
        let repository = FakeDiscoveryRepository()
        await repository.enqueueFetch(Self.makeCachedPage(repoID: 101, owner: "apple", name: "swift-collections"))
        let viewModel = ExploreDiscoveryViewModel()

        await viewModel.reload(
            repository: repository,
            mode: .popular,
            language: "Swift",
            topic: nil,
            platform: nil,
            sort: .stars
        )

        #expect(viewModel.repos.count == 1)
        #expect(viewModel.total == 1)
        #expect(viewModel.nextPage == nil)
        #expect(viewModel.loadError == nil)

        let request = try #require(await repository.recordedRequests().first)
        #expect(request.mode == .popular)
        #expect(request.query.language == "Swift")
        #expect(request.query.sort == "stars")
        #expect(request.query.page == 1)
        #expect(request.query.limit == 20)
    }

    @Test("分页 meta 驱动 loadMore 追加下一页")
    func loadMoreAppendsNextPageFromMeta() async throws {
        let repository = FakeDiscoveryRepository()
        await repository.enqueueFetch(Self.makeCachedPage(
            repoID: 201,
            owner: "swiftlang",
            name: "swift-syntax",
            total: 2,
            nextPage: 2
        ))
        await repository.enqueueFetch(Self.makeCachedPage(
            repoID: 202,
            owner: "swiftlang",
            name: "swift-format",
            total: 2,
            nextPage: nil,
            page: 2
        ))
        let viewModel = ExploreDiscoveryViewModel()

        await viewModel.reload(
            repository: repository,
            mode: .newReleases,
            language: "Swift",
            topic: nil,
            platform: nil,
            sort: .release
        )

        let firstRepo = try #require(viewModel.repos.first)
        #expect(viewModel.nextPage == 2)

        await viewModel.loadMoreIfNeeded(
            repository: repository,
            currentRepo: firstRepo,
            mode: .newReleases,
            language: "Swift",
            topic: nil,
            platform: nil,
            sort: .release
        )

        #expect(viewModel.repos.map(\.fullName) == ["swiftlang/swift-syntax", "swiftlang/swift-format"])
        #expect(viewModel.total == 2)
        #expect(viewModel.nextPage == nil)

        let requests = await repository.recordedRequests()
        #expect(requests.count == 2)
        #expect(requests.last?.mode == .newReleases)
        #expect(requests.last?.query.page == 2)
    }

    @Test("新筛选远端错误且无缓存时清空列表")
    func reloadServerErrorWithoutCacheClearsListAndStoresError() async throws {
        let repository = FakeDiscoveryRepository()
        await repository.enqueueFetch(Self.makeCachedPage(repoID: 301, owner: "initial", name: "repo"))
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

        let request = try #require(await repository.recordedRequests().last)
        #expect(request.mode == .discover)
        #expect(request.query.topic == "privacy")
        #expect(request.query.platform == "linux")
        #expect(request.query.sort == nil)
    }

    private nonisolated static func makeCachedPage(
        repoID: Int64,
        owner: String,
        name: String,
        total: Int = 1,
        nextPage: Int? = nil,
        page: Int = 1
    ) -> DiscoveryCachedPage {
        let fullName = "\(owner)/\(name)"
        let repo = DiscoveryRepoDTO(
            repoID: repoID,
            fullName: fullName,
            owner: owner,
            name: name,
            description: "A repository for discovery tests.",
            homepage: nil,
            language: "Swift",
            stars: 1000,
            forks: 100,
            watchers: 1000,
            subscribers: 20,
            openIssues: 5,
            ownerAvatar: nil,
            defaultBranch: "main",
            licenseSpdx: "MIT",
            topics: ["swift", "developer-tools"],
            platforms: ["macos"],
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
            score: 98.5,
            reasons: ["Active repository"],
            signals: [
                DiscoverySignalDTO(code: "release", label: "Recent release", value: "1.0.0")
            ]
        )
        let discoveryPage = DiscoveryPage(
            items: [repo],
            total: total,
            page: page,
            pageSize: 20,
            nextPage: nextPage
        )
        return DiscoveryCachedPage(page: discoveryPage, cachedAt: Date())
    }
}

private enum FakeDiscoveryError: Error {
    case unavailable
}

private actor FakeDiscoveryRepository: DiscoveryRepositoryProtocol {

    struct Request: Sendable {
        let mode: DiscoveryListMode
        let query: DiscoveryListQuery
    }

    private var cached: [String: DiscoveryCachedPage] = [:]
    private var fetchQueue: [DiscoveryCachedPage] = []
    private var requests: [Request] = []
    private var fetchError: Error?

    func cachedPage(mode: DiscoveryListMode, query: DiscoveryListQuery) async -> DiscoveryCachedPage? {
        cached[key(mode: mode, query: query)]
    }

    func fetchPage(mode: DiscoveryListMode, query: DiscoveryListQuery) async throws -> DiscoveryCachedPage {
        requests.append(Request(mode: mode, query: query))
        if let fetchError {
            throw fetchError
        }
        guard !fetchQueue.isEmpty else {
            throw FakeDiscoveryError.unavailable
        }
        let page = fetchQueue.removeFirst()
        cached[key(mode: mode, query: query)] = page
        return page
    }

    func cachedSummary() async -> DiscoverySummaryDTO? {
        nil
    }

    func fetchSummary() async throws -> DiscoverySummaryDTO {
        DiscoverySummaryDTO(modes: [], generatedAt: nil)
    }

    func clearCache() async {
        cached.removeAll()
    }

    func enqueueFetch(_ page: DiscoveryCachedPage) {
        fetchQueue.append(page)
    }

    func setFetchError(_ error: Error?) {
        fetchError = error
    }

    func recordedRequests() -> [Request] {
        requests
    }

    private func key(mode: DiscoveryListMode, query: DiscoveryListQuery) -> String {
        [
            mode.rawValue,
            query.language ?? "__all__",
            query.platform ?? "__all__",
            query.topic ?? "__all__",
            query.sort ?? "__default__",
            "\(query.page)",
            "\(query.limit)"
        ].joined(separator: "|")
    }
}
