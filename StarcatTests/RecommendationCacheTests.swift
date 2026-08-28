//
//  RecommendationCacheTests.swift
//  StarcatTests
//
//  验证推荐详情页真正尊重磁盘快照的 freshness：fresh 快照不访问网络，
//  stale 快照才刷新。测试使用临时目录，避免污染正式 recommendation-cache。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("Recommendation cache freshness", .serialized)
struct RecommendationCacheTests {

    @Test("fresh 有结果快照直接上屏且不请求网络")
    func freshSnapshotSkipsNetwork() async throws {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let cachedItem = Self.makeItem(repoID: 2, fullName: "cached/repo")
        try await cache.save(snapshot: Self.makeSnapshot(repoID: 1, items: [cachedItem], isFresh: true))
        let fetcher = RecommendationFetcherStub(page: Self.makePage(repoID: 1, items: []))
        let service = RecommendationContextService(cache: cache, fetcher: fetcher)
        let viewModel = RepoRecommendationViewModel()

        await viewModel.loadInitial(repoID: 1, service: service)

        #expect(viewModel.items == [cachedItem])
        #expect(await fetcher.callCount() == 0)
    }

    @Test("fresh 空结果负缓存不请求网络")
    func freshEmptySnapshotSkipsNetwork() async throws {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        try await cache.save(snapshot: Self.makeSnapshot(repoID: 1, items: [], isFresh: true))
        let fetcher = RecommendationFetcherStub(page: Self.makePage(repoID: 1, items: []))
        let service = RecommendationContextService(cache: cache, fetcher: fetcher)
        let viewModel = RepoRecommendationViewModel()

        await viewModel.loadInitial(repoID: 1, service: service)

        #expect(viewModel.items.isEmpty)
        #expect(await fetcher.callCount() == 0)
    }

    @Test("stale 快照刷新并替换为远端结果")
    func staleSnapshotRefreshesNetwork() async throws {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        try await cache.save(snapshot: Self.makeSnapshot(
            repoID: 1,
            items: [Self.makeItem(repoID: 2, fullName: "stale/repo")],
            isFresh: false
        ))
        let remoteItem = Self.makeItem(repoID: 3, fullName: "remote/repo")
        let fetcher = RecommendationFetcherStub(page: Self.makePage(repoID: 1, items: [remoteItem]))
        let service = RecommendationContextService(cache: cache, fetcher: fetcher)
        let viewModel = RepoRecommendationViewModel()

        await viewModel.loadInitial(repoID: 1, service: service)

        #expect(viewModel.items == [remoteItem])
        #expect(await fetcher.callCount() == 1)
    }

    @Test("完整缓存只展示首批，更多按钮每次解锁十条")
    func cachedPagesRemainVisiblyPaginated() async throws {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let cachedItems = (1...25).map {
            Self.makeItem(repoID: Int64($0 + 1), fullName: "cached/repo-\($0)")
        }
        try await cache.save(snapshot: Self.makeSnapshot(
            repoID: 1,
            items: cachedItems,
            isFresh: true
        ))
        let fetcher = RecommendationFetcherStub(page: Self.makePage(repoID: 1, items: []))
        let service = RecommendationContextService(cache: cache, fetcher: fetcher)
        let viewModel = RepoRecommendationViewModel()

        await viewModel.loadInitial(repoID: 1, service: service)
        #expect(viewModel.items.count == 10)
        #expect(viewModel.hasMore)
        #expect(await fetcher.callCount() == 0)

        await viewModel.loadMore(service: service)
        #expect(viewModel.items.count == 20)
        #expect(viewModel.hasMore)
        #expect(await fetcher.callCount() == 0)

        await viewModel.loadMore(service: service)
        #expect(viewModel.items.count == 25)
        #expect(!viewModel.hasMore)
        #expect(await fetcher.callCount() == 0)
    }

    @Test("缓存耗尽后点击更多才请求下一页")
    func loadMoreFetchesOnlyAfterCachedItemsAreVisible() async throws {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstPage = (1...10).map {
            Self.makeItem(repoID: Int64($0 + 1), fullName: "first/repo-\($0)")
        }
        let secondPage = (11...20).map {
            Self.makeItem(repoID: Int64($0 + 1), fullName: "second/repo-\($0)")
        }
        try await cache.save(snapshot: Self.makeSnapshot(
            repoID: 1,
            items: firstPage,
            isFresh: true,
            hasMore: true,
            nextOffset: 10
        ))
        let fetcher = RecommendationFetcherStub(
            pages: [10: Self.makePage(repoID: 1, items: secondPage)]
        )
        let service = RecommendationContextService(cache: cache, fetcher: fetcher)
        let viewModel = RepoRecommendationViewModel()

        await viewModel.loadInitial(repoID: 1, service: service)
        #expect(viewModel.items.count == 10)
        #expect(await fetcher.callCount() == 0)

        await viewModel.loadMore(service: service)
        #expect(viewModel.items.count == 20)
        #expect(!viewModel.hasMore)
        #expect(await fetcher.requestedOffsets() == [10])

        let reopenedViewModel = RepoRecommendationViewModel()
        await reopenedViewModel.loadInitial(repoID: 1, service: service)
        #expect(reopenedViewModel.items.count == 10)
        #expect(reopenedViewModel.hasMore)
        #expect(await fetcher.callCount() == 1)
    }

    @Test("切换推荐服务后旧作用域缓存不会命中")
    func serviceScopeMismatchRefreshesInsteadOfReusingCache() async throws {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldItem = Self.makeItem(repoID: 2, fullName: "local/old")
        try await cache.save(snapshot: Self.makeSnapshot(
            repoID: 1,
            items: [oldItem],
            isFresh: true,
            serviceScope: "local-v2"
        ))
        let remoteItem = Self.makeItem(repoID: 3, fullName: "online/new")
        let fetcher = RecommendationFetcherStub(
            page: Self.makePage(repoID: 1, items: [remoteItem]),
            serviceScope: "online-v1"
        )
        let service = RecommendationContextService(cache: cache, fetcher: fetcher)
        let viewModel = RepoRecommendationViewModel()

        await viewModel.loadInitial(repoID: 1, service: service)

        #expect(viewModel.items == [remoteItem])
        #expect(await fetcher.callCount() == 1)
        let stored = await cache.load(repoID: 1)
        #expect(stored?.serviceScope == "online-v1")
    }

    private func makeCache() -> (DiskRecommendationCache, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("starcat-recommendation-test-\(UUID().uuidString)", isDirectory: true)
        return (DiskRecommendationCache(rootOverride: root), root)
    }

    private static func makeSnapshot(
        repoID: Int64,
        items: [RepoRecommendationItem],
        isFresh: Bool,
        hasMore: Bool = false,
        nextOffset: Int? = nil,
        serviceScope: String = "recommendation-default"
    ) -> RecommendationCacheSnapshot {
        let now = Date()
        return RecommendationCacheSnapshot(
            repoID: repoID,
            serviceScope: serviceScope,
            modelVersion: "test-v1",
            probedAt: now,
            nextProbeAt: now.addingTimeInterval(isFresh ? 3_600 : -1),
            items: items,
            hasMore: hasMore,
            nextOffset: nextOffset
        )
    }

    private static func makeItem(repoID: Int64, fullName: String) -> RepoRecommendationItem {
        RepoRecommendationItem(
            repoID: repoID,
            fullName: fullName,
            description: nil,
            language: "Swift",
            stars: 100,
            forks: 10,
            archived: false,
            score: 0.9,
            source: "embedding",
            reasons: []
        )
    }

    private static func makePage(
        repoID: Int64,
        items: [RepoRecommendationItem]
    ) -> RepoRecommendationPage {
        RepoRecommendationPage(
            source: "embedding",
            fallback: false,
            repoID: repoID,
            modelVersion: nil,
            items: items,
            hasMore: false,
            nextOffset: nil
        )
    }
}

/// 记录网络调用次数的 actor stub，确保并发测试读取计数时没有数据竞争。
private actor RecommendationFetcherStub: RecommendationStatusFetching {
    private let pages: [Int: RepoRecommendationPage]
    private let serviceScope: String
    private var offsets: [Int] = []

    init(page: RepoRecommendationPage, serviceScope: String = "recommendation-default") {
        self.pages = [0: page]
        self.serviceScope = serviceScope
    }

    init(pages: [Int: RepoRecommendationPage], serviceScope: String = "recommendation-default") {
        self.pages = pages
        self.serviceScope = serviceScope
    }

    func fetchRecommendations(repoID: Int64, limit: Int, offset: Int) async throws -> RepoRecommendationPage {
        offsets.append(offset)
        return pages[offset] ?? RepoRecommendationPage(
            source: "embedding",
            fallback: false,
            repoID: repoID,
            modelVersion: nil,
            items: [],
            hasMore: false,
            nextOffset: nil
        )
    }

    func recommendationCacheScope() async -> String {
        serviceScope
    }

    func callCount() -> Int {
        offsets.count
    }

    func requestedOffsets() -> [Int] {
        offsets
    }
}
