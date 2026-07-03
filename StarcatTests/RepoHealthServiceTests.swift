//
//  RepoHealthServiceTests.swift
//  StarcatTests
//
//  验证 Repo Health 手动刷新与 repo 访问状态的衔接。
//

import Testing
import Foundation
@testable import Starcat

@Suite("RepoHealthService")
struct RepoHealthServiceTests {

    @Test("repo metadata 404 时标记不可访问且不改变知识库归属")
    func metadataNotFoundMarksRepoUnavailable() async throws {
        let db = try InMemoryDatabaseManager()
        let repoRepository = GRDBRepoRepository(database: db)
        let noteRepository = GRDBRepoNoteRepository(database: db)
        let releaseRepository = GRDBReleaseRepository(database: db)
        let openSSFRepository = GRDBOpenSSFScoreRepository(database: db)
        let healthRepository = GRDBRepoHealthRepository(database: db)
        let api = MockGitHubAPIClient()

        try await db.insertRepoFixture(id: 42, owner: "octo", name: "gone")
        try await noteRepository.updateLibraryState(repoId: 42, state: .inLibrary)
        api.releasesHandler = { _, _, _ in
            APIResponse(value: [], linkHeader: LinkHeader(nextPage: nil, lastPage: nil), rateLimit: .empty, statusCode: 200, etag: nil)
        }
        api.repoHandler = { _, _ in
            throw NetworkError.notFound
        }

        let service = RepoHealthService(
            repository: healthRepository,
            releaseRepository: releaseRepository,
            openSSFRepository: openSSFRepository,
            repoRepository: repoRepository,
            apiClient: api
        )

        let repo = try #require(try await repoRepository.findById(42))
        _ = try await service.refreshWithLatestSignals(repo: repo)

        let saved = try #require(try await repoRepository.findById(42))
        #expect(saved.accessState == .unavailable)
        #expect(saved.accessReason != nil)
        #expect(try await noteRepository.fetchLibraryState(repoId: 42) == .inLibrary)
        #expect((try await repoRepository.fetchKnowledgeRepos()).map(\.id).contains(42))
    }
}
