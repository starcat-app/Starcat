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
