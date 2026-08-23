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
        try cache.save(snapshot: Self.makeSnapshot(repoID: 1, items: [cachedItem], isFresh: true))
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
        try cache.save(snapshot: Self.makeSnapshot(repoID: 1, items: [], isFresh: true))
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
        try cache.save(snapshot: Self.makeSnapshot(
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

    private func makeCache() -> (DiskRecommendationCache, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("starcat-recommendation-test-\(UUID().uuidString)", isDirectory: true)
        return (DiskRecommendationCache(rootOverride: root), root)
    }

    private static func makeSnapshot(
        repoID: Int64,
        items: [RepoRecommendationItem],
        isFresh: Bool
    ) -> RecommendationCacheSnapshot {
        let now = Date()
        return RecommendationCacheSnapshot(
            repoID: repoID,
            probedAt: now,
            nextProbeAt: now.addingTimeInterval(isFresh ? 3_600 : -1),
            items: items,
            hasMore: false,
            nextOffset: nil
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
    private let page: RepoRecommendationPage
    private var calls = 0

    init(page: RepoRecommendationPage) {
        self.page = page
    }

    func fetchRecommendations(repoID: Int64, limit: Int, offset: Int) async throws -> RepoRecommendationPage {
        calls += 1
        return page
    }

    func callCount() -> Int {
        calls
    }
}
