//
//  RepositoryLanguageDistributionViewModelTests.swift
//  StarcatTests
//
//  验证详情语言横条的 Top 5 + Other 归一化与 cache-first 刷新边界。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("Repository language distribution")
struct RepositoryLanguageDistributionViewModelTests {
    @Test("按字节稳定排序并把第六名起聚合为 Other")
    func makesTopFiveAndOtherSegments() throws {
        let segments = RepositoryLanguageDistributionViewModel.makeSegments(
            from: [
                "Swift": 50,
                "C": 20,
                "Shell": 10,
                "Ruby": 8,
                "Python": 6,
                "JavaScript": 4,
                "HTML": 2,
                "Ignored": 0,
                " ": 100
            ]
        )

        #expect(segments.compactMap(\.language) == ["Swift", "C", "Shell", "Ruby", "Python"])
        #expect(segments.last?.language == nil)
        #expect(try #require(segments.last).fraction == 0.06)
        #expect(abs(segments.reduce(0) { $0 + $1.fraction } - 1) < 0.000_001)
    }

    @Test("新鲜缓存直接上屏且不刷新网络")
    func freshCacheSkipsRefresh() async throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let service = RepositoryLanguageServiceStub(
            cached: cached(["Swift": 3, "C": 1], fetchedAt: now),
            refreshed: ["Rust": 1]
        )
        let viewModel = RepositoryLanguageDistributionViewModel(service: service)

        await viewModel.load(repoID: 1, owner: "starcat", name: "app", now: now)

        #expect(viewModel.segments.map(\.language) == ["Swift", "C"])
        let refreshCount = await service.refreshCount
        #expect(refreshCount == 0)
    }

    @Test("过期缓存先进入 SWR 路径并由网络结果替换")
    func staleCacheRefreshes() async throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let service = RepositoryLanguageServiceStub(
            cached: cached(
                ["Swift": 3],
                fetchedAt: now.addingTimeInterval(-25 * 60 * 60)
            ),
            refreshed: ["Rust": 3, "C": 1]
        )
        let viewModel = RepositoryLanguageDistributionViewModel(service: service)

        await viewModel.load(repoID: 1, owner: "starcat", name: "app", now: now)

        #expect(viewModel.segments.map(\.language) == ["Rust", "C"])
        let refreshCount = await service.refreshCount
        #expect(refreshCount == 1)
    }

    private func cached(
        _ value: [String: Int],
        fetchedAt: Date
    ) -> RepositoryInsightsCachedValue<[String: Int]> {
        RepositoryInsightsCachedValue(
            value: value,
            fetchedAt: fetchedAt,
            staleAfter: fetchedAt.addingTimeInterval(24 * 60 * 60),
            responseETag: nil,
            defaultBranchSHA: nil
        )
    }
}

/// actor 隔离计数，确保测试不会用非 Sendable 可变状态伪造并发服务。
private actor RepositoryLanguageServiceStub: RepositoryLanguageServing {
    let cached: RepositoryInsightsCachedValue<[String: Int]>?
    let refreshed: [String: Int]
    private(set) var refreshCount = 0

    init(
        cached: RepositoryInsightsCachedValue<[String: Int]>?,
        refreshed: [String: Int]
    ) {
        self.cached = cached
        self.refreshed = refreshed
    }

    func cachedLanguages(
        repoID: Int64
    ) async throws -> RepositoryInsightsCachedValue<[String: Int]>? {
        cached
    }

    func refreshLanguages(
        repoID: Int64,
        owner: String,
        name: String
    ) async throws -> [String: Int] {
        refreshCount += 1
        return refreshed
    }
}
