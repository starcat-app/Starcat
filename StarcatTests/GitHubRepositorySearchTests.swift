//
//  GitHubRepositorySearchTests.swift
//  StarcatTests
//
//  验证 GitHub Repository Search qualifier、排序和日期格式。
//

import Foundation
import Testing
@testable import Starcat

@Suite("GitHub Repository Search")
struct GitHubRepositorySearchTests {
    @Test("query builder 生成结构化 qualifiers")
    func structuredQuery() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let date = try #require(calendar.date(from: DateComponents(year: 2025, month: 6, day: 1)))
        let filters = GitHubSearchFilters(
            language: " Swift ",
            topic: "macos",
            minimumStars: 100,
            createdAfter: date,
            pushedAfter: nil,
            sort: .stars,
            order: .descending
        )
        let query = GitHubRepositorySearchQuery(text: "menu bar", filters: filters)

        #expect(query.encodedQuery == "menu bar language:Swift topic:macos stars:>=100 created:>=2025-06-01")
        #expect(query.queryItems.contains(URLQueryItem(name: "sort", value: "stars")))
        #expect(query.queryItems.contains(URLQueryItem(name: "order", value: "desc")))
    }

    @Test("best match 不发送 sort 和 order")
    func bestMatchOmitsSort() {
        let query = GitHubRepositorySearchQuery(text: "swift", filters: .empty)
        #expect(!query.queryItems.contains { $0.name == "sort" })
        #expect(!query.queryItems.contains { $0.name == "order" })
    }

    @Test("GitHub 搜索缓存命中时仍读取最新知识库状态")
    func cachedSearchPageAppliesFreshLibraryState() async throws {
        let db = try InMemoryDatabaseManager()
        let repoRepository = GRDBRepoRepository(database: db)
        let noteRepository = GRDBRepoNoteRepository(database: db)
        let client = MockGitHubAPIClient()
        let dto = Self.makeRepoDTO(id: 42, owner: "openai", name: "codex")
        var networkCallCount = 0
        client.searchRepositoriesHandler = { _, _, _ in
            networkCallCount += 1
            return APIResponse(
                value: GitHubRepositorySearchDTO(
                    totalCount: 1,
                    incompleteResults: false,
                    items: [dto]
                ),
                linkHeader: LinkHeader(nextPage: nil, lastPage: nil),
                rateLimit: .empty,
                statusCode: 200,
                etag: nil
            )
        }
        let provider = GitHubRepositorySearchProvider(
            client: client,
            noteRepository: noteRepository,
            cache: SearchSessionCache(ttl: 300)
        )
        let request = SearchRequest(query: "codex", scope: .github)

        let firstPage = try await provider.search(request)
        _ = try await repoRepository.upsertExternalRepoForLibrary(repoDTO: dto, syncedAt: Date())
        try await noteRepository.updateLibraryState(repoId: 42, state: .inLibrary)
        let cachedPage = try await provider.search(request)

        #expect(networkCallCount == 1)
        #expect(firstPage.repositories.first?.card.isInLibrary == false)
        #expect(cachedPage.repositories.first?.card.isInLibrary == true)
    }

    private static func makeRepoDTO(id: Int64, owner: String, name: String) -> GitHubRepoDTO {
        GitHubRepoDTO(
            id: id,
            name: name,
            fullName: "\(owner)/\(name)",
            owner: GitHubUserDTO(
                id: 1,
                login: owner,
                name: nil,
                avatarUrl: "https://github.com/\(owner).png"
            ),
            description: "Repository search fixture",
            language: "Swift",
            stargazersCount: 100,
            forksCount: 10,
            watchersCount: 100,
            topics: [],
            license: nil,
            homepage: nil,
            htmlUrl: "https://github.com/\(owner)/\(name)",
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: false,
            fork: false,
            archived: false,
            pushedAt: nil,
            createdAt: nil,
            updatedAt: nil,
            openIssuesCount: nil,
            defaultBranch: "main",
            disabled: nil,
            isTemplate: nil,
            score: nil
        )
    }
}
