//
//  CuratedProjectResolverTests.swift
//  StarcatTests
//
//  覆盖直接地址核验、普通线索合并、去重与 Web Search 降级。
//

import Foundation
import Testing
@testable import Starcat

@Suite("精选发布台项目识别")
struct CuratedProjectResolverTests {
    @Test("直接 GitHub 地址只接受精确官方匹配")
    func directAddressUsesExactVerification() async throws {
        let recorder = SearchRequestRecorder()
        let github = CuratedResolverStubProvider(source: .github) { request in
            recorder.append(request)
            return Self.page([Self.candidate(id: 1, owner: "OpenAI", name: "Codex")])
        }
        let resolver = CuratedProjectResolver(githubProvider: github)

        let result = try await resolver.resolve(
            clue: "https://github.com/openai/codex/issues/1",
            externalSearchProvider: .anySearch
        )

        #expect(result.candidates.map(\.identity.normalizedFullName) == ["openai/codex"])
        #expect(recorder.snapshot.map(\.query) == ["repo:openai/codex"])
        #expect(!result.usedWebSearch)
    }

    @Test("普通线索合并 Web 核验和 GitHub 结果并按仓库去重")
    func arbitraryClueMergesAndDeduplicates() async throws {
        let github = CuratedResolverStubProvider(source: .github) { request in
            if request.query == "repo:openai/codex" {
                return Self.page([Self.candidate(id: 1, owner: "openai", name: "codex")])
            }
            return Self.page([
                Self.candidate(id: 1, owner: "openai", name: "codex"),
                Self.candidate(id: 2, owner: "anthropics", name: "claude-code")
            ])
        }
        let web = CuratedResolverStubProvider(source: .web) { request in
            #expect(request.externalSearchFilters.includeDomains == ["github.com"])
            return SearchProviderPage(
                repositories: [],
                references: [
                    Self.reference("https://github.com/openai/codex"),
                    Self.reference("https://example.com/not-a-repo")
                ],
                totalCount: 2,
                hasNextPage: false
            )
        }
        let resolver = CuratedProjectResolver(githubProvider: github, webProvider: web)

        let result = try await resolver.resolve(
            clue: "好用的 coding agent",
            externalSearchProvider: .exa
        )

        #expect(result.candidates.map(\.identity.normalizedFullName) == [
            "openai/codex", "anthropics/claude-code"
        ])
        #expect(result.usedWebSearch)
        #expect(!result.didFallbackFromWebSearch)
    }

    @Test("Web Search 失败时退化为 GitHub Search")
    func webFailureFallsBackToGitHub() async throws {
        let web = CuratedResolverStubProvider(source: .web) { _ in
            throw URLError(.userAuthenticationRequired)
        }
        let github = CuratedResolverStubProvider(source: .github) { _ in
            Self.page([Self.candidate(id: 7, owner: "apple", name: "swift")])
        }
        let resolver = CuratedProjectResolver(githubProvider: github, webProvider: web)

        let result = try await resolver.resolve(clue: "Swift", externalSearchProvider: .tavily)
        #expect(result.candidates.map(\.identity.normalizedFullName) == ["apple/swift"])
        #expect(result.didFallbackFromWebSearch)
    }

    @Test("最终地址核验拒绝非精确结果")
    func finalVerificationRejectsFuzzyResult() async {
        let github = CuratedResolverStubProvider(source: .github) { _ in
            Self.page([Self.candidate(id: 1, owner: "openai", name: "openai-python")])
        }
        let resolver = CuratedProjectResolver(githubProvider: github)

        do {
            _ = try await resolver.verify(
                address: GitHubRepositoryAddress(owner: "openai", repo: "codex")
            )
            Issue.record("Expected exact verification failure")
        } catch CuratedProjectResolverError.repositoryNotFound(let fullName) {
            #expect(fullName == "openai/codex")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private static func page(_ candidates: [RepositoryCandidate]) -> SearchProviderPage {
        SearchProviderPage(
            repositories: candidates,
            references: [],
            totalCount: candidates.count,
            hasNextPage: false
        )
    }

    private static func candidate(id: Int64, owner: String, name: String) -> RepositoryCandidate {
        RepositoryCandidate(
            identity: RepoIdentity(ghRepoID: id, owner: owner, name: name),
            card: RepoCardViewData(
                ghRepoId: id,
                fullName: "\(owner)/\(name)",
                owner: owner,
                repo: name,
                avatarURL: nil,
                description: "Description",
                language: "Swift",
                starsCount: 100,
                forksCount: 10,
                isArchived: false,
                isFork: false,
                isPrivate: false,
                isStarred: false,
                isInLibrary: false,
                badge: nil,
                weeklySources: [],
                weeklySourceLabel: nil,
                inlineMetadata: nil,
                footerMetadata: nil,
                readStatus: nil,
                openSSFScore: nil,
                healthBadge: nil
            ),
            sources: [.github],
            localRepo: nil,
            remoteRepo: nil,
            semanticScore: nil
        )
    }

    private static func reference(_ rawURL: String) -> ReferenceCandidate {
        let url = URL(string: rawURL)!
        return ReferenceCandidate(
            normalizedURL: url,
            originalURL: url,
            title: "Result",
            snippet: nil,
            domain: url.host ?? "",
            source: .web
        )
    }
}

private struct CuratedResolverStubProvider: SearchProvider {
    let source: SearchSource
    let handler: @Sendable (SearchRequest) async throws -> SearchProviderPage

    func search(_ request: SearchRequest) async throws -> SearchProviderPage {
        try await handler(request)
    }
}

private final class SearchRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [SearchRequest] = []

    func append(_ request: SearchRequest) {
        lock.withLock { requests.append(request) }
    }

    var snapshot: [SearchRequest] {
        lock.withLock { requests }
    }
}
