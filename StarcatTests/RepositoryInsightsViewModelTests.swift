//
//  RepositoryInsightsViewModelTests.swift
//  StarcatTests
//
//  验证仓库洞察本地各区块独立收敛，并阻止快速切换时旧 repo 结果覆盖新 repo。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("Repository insights view model")
struct RepositoryInsightsViewModelTests {

    @Test("默认数据源映射已有 Release、Health、OpenSSF 与 Community 缓存")
    func defaultProviderMapsExistingLocalData() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 7)

        let releaseRepository = GRDBReleaseRepository(database: database)
        try await releaseRepository.upsertMany(
            [
                ReleaseRecord(
                    id: 70,
                    repoId: 7,
                    tagName: "v2.1.0",
                    name: "Stable",
                    bodyMarkdown: nil,
                    htmlUrl: "https://github.com/octo/demo-7/releases/tag/v2.1.0",
                    isPrerelease: false,
                    isDraft: false,
                    publishedAt: "2026-07-20T00:00:00Z",
                    createdAtRemote: "2026-07-20T00:00:00Z",
                    assetsJson: nil,
                    isRead: false,
                    fetchedAt: "2026-07-27T00:00:00Z"
                )
            ],
            isReadDefault: false
        )

        let healthRepository = GRDBRepoHealthRepository(database: database)
        try await healthRepository.upsert(
            RepoHealthSnapshot(
                repoId: 7,
                overallScore: 88.4,
                grade: "A",
                maintenanceScore: 90.1,
                popularityScore: 87.2,
                qualityScore: 86.6,
                securityScore: 89.4,
                payloadJSON: "{}",
                computedAt: "2026-07-27T00:00:00Z",
                staleAfter: "2026-07-28T00:00:00Z",
                fetchStatus: .success,
                lastError: nil
            )
        )

        let openSSFRepository = GRDBOpenSSFScoreRepository(database: database)
        try await openSSFRepository.upsert(
            OpenSSFScoreRecord(
                repoId: 7,
                fetchStatus: .success,
                aggregateScore: 8.7,
                checksJSON: nil,
                scoreDate: "2026-07-27",
                fetchedAt: "2026-07-27T00:00:00Z",
                lastError: nil
            )
        )

        let cache = GRDBRepositoryInsightsCache(database: database)
        let community = RepositoryCommunityInsight(
            healthPercentage: 92,
            hasReadme: true,
            hasCodeOfConduct: false,
            hasContributing: true,
            hasLicense: true
        )
        try await cache.store(
            community,
            repoId: 7,
            dataset: .communityProfile,
            range: .all,
            fetchedAt: Date(timeIntervalSince1970: 1_000),
            responseETag: nil,
            defaultBranchSHA: nil
        )

        let provider = DefaultRepositoryLocalInsightsProvider(
            releaseRepository: releaseRepository,
            healthRepository: healthRepository,
            openSSFRepository: openSSFRepository,
            insightsCache: cache
        )

        let release = try #require(try await provider.latestRelease(repoId: 7))
        let health = try #require(try await provider.health(repoId: 7))
        let openSSF = try #require(try await provider.openSSF(repoId: 7))
        let cachedCommunity = try #require(try await provider.cachedCommunity(repoId: 7))

        #expect(release.tagName == "v2.1.0")
        #expect(release.name == "Stable")
        #expect(health.overallScore == 88)
        #expect(health.maintenanceScore == 90)
        #expect(openSSF == RepositoryOpenSSFInsight(score: 8.7, scoreDate: "2026-07-27"))
        #expect(cachedCommunity == community)
    }

    @Test("本地区块独立加载且单一区块失败不影响其他结果")
    func sectionsLoadIndependently() async {
        let provider = StubRepositoryLocalInsightsProvider(
            release: { _ in RepositoryReleaseInsight(tagName: "v1.0", name: nil, publishedAt: nil) },
            health: { _ in RepositoryHealthInsight(
                overallScore: 80,
                grade: "B",
                maintenanceScore: 81,
                popularityScore: 82,
                qualityScore: 83,
                securityScore: 84,
                isPartial: false
            ) },
            openSSF: { _ in throw StubError.failed },
            community: { _ in nil }
        )
        let viewModel = RepositoryInsightsViewModel(provider: provider)

        await viewModel.load(repoId: 1)

        #expect(viewModel.releaseState == .content(
            RepositoryReleaseInsight(tagName: "v1.0", name: nil, publishedAt: nil)
        ))
        #expect(viewModel.healthState != .failed)
        #expect(viewModel.openSSFState == .failed)
        #expect(viewModel.communityState == .empty)
    }

    @Test("较慢的旧 repo 结果不能覆盖新 repo")
    func staleGenerationIsDiscarded() async {
        let provider = StubRepositoryLocalInsightsProvider(
            release: { repoId in
                if repoId == 1 {
                    try await Task.sleep(for: .milliseconds(120))
                }
                return RepositoryReleaseInsight(
                    tagName: repoId == 1 ? "old" : "new",
                    name: nil,
                    publishedAt: nil
                )
            },
            health: { _ in nil },
            openSSF: { _ in nil },
            community: { _ in nil }
        )
        let viewModel = RepositoryInsightsViewModel(provider: provider)

        let oldLoad = Task { await viewModel.load(repoId: 1) }
        try? await Task.sleep(for: .milliseconds(20))
        await viewModel.load(repoId: 2)
        await oldLoad.value

        #expect(viewModel.activeRepoID == 2)
        #expect(viewModel.releaseState == .content(
            RepositoryReleaseInsight(tagName: "new", name: nil, publishedAt: nil)
        ))
    }
}

private enum StubError: Error {
    case failed
}

private struct StubRepositoryLocalInsightsProvider: RepositoryLocalInsightsProviding {
    let release: @Sendable (Int64) async throws -> RepositoryReleaseInsight?
    let health: @Sendable (Int64) async throws -> RepositoryHealthInsight?
    let openSSF: @Sendable (Int64) async throws -> RepositoryOpenSSFInsight?
    let community: @Sendable (Int64) async throws -> RepositoryCommunityInsight?

    func latestRelease(repoId: Int64) async throws -> RepositoryReleaseInsight? {
        try await release(repoId)
    }

    func health(repoId: Int64) async throws -> RepositoryHealthInsight? {
        try await health(repoId)
    }

    func openSSF(repoId: Int64) async throws -> RepositoryOpenSSFInsight? {
        try await openSSF(repoId)
    }

    func cachedCommunity(repoId: Int64) async throws -> RepositoryCommunityInsight? {
        try await community(repoId)
    }
}
