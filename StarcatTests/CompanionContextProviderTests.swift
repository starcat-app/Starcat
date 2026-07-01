//
//  CompanionContextProviderTests.swift
//  StarcatTests
//
//  验证 Chrome Companion repo-context 聚合入口的 repo 基础映射。
//

import Foundation
import Testing
@testable import Starcat

@Suite("CompanionContextProvider")
struct CompanionContextProviderTests {
    private enum FixtureError: Error {
        case expectedFailure
    }

    @Test("unknown repo returns stable empty context")
    func unknownRepoContext() async throws {
        let provider = CompanionContextProvider { _, _ in nil }

        let context = try await provider.context(owner: "apple", repo: "swift")

        #expect(context.schemaVersion == 1)
        #expect(context.repo.fullName == "apple/swift")
        #expect(context.repo.repoID == nil)
        #expect(context.repo.htmlURL == "https://github.com/apple/swift")
        #expect(context.repo.knownToStarcat == false)
        #expect(context.repo.isStarred == false)
        #expect(context.recommendations.isEmpty)
        #expect(context.wikiLinks.isEmpty)
        #expect(context.note == nil)
        #expect(context.health == nil)
        #expect(context.openssf == nil)
        #expect(context.actions.openInStarcat == false)
    }

    @Test("known local repo maps Starcat fields")
    func knownRepoContext() async throws {
        let repo = makeRepo(isStarred: true)
        let provider = CompanionContextProvider { owner, name in
            #expect(owner == "apple")
            #expect(name == "swift")
            return repo
        }

        let context = try await provider.context(owner: " apple ", repo: " swift ")

        #expect(context.repo.repoID == 44_838_949)
        #expect(context.repo.fullName == "apple/swift")
        #expect(context.repo.knownToStarcat == true)
        #expect(context.repo.isStarred == true)
        #expect(context.actions.openInStarcat == true)
        #expect(context.actions.codeflow == true)
        #expect(context.actions.codebase == true)
    }

    @Test("starred repo returns editable private note")
    func starredRepoReturnsEditableNote() async throws {
        let repo = makeRepo(isStarred: true)
        let provider = CompanionContextProvider(
            lookupRepo: { _, _ in repo },
            lookupNote: { repoID in
                #expect(repoID == 44_838_949)
                return RepoNote(
                    repoId: repoID,
                    content: "private note",
                    status: RepoStatus.using.rawValue,
                    isAIGenerated: false,
                    editedAt: "2026-07-01T10:00:00Z"
                )
            }
        )

        let context = try await provider.context(owner: "apple", repo: "swift")

        #expect(context.note?.editable == true)
        #expect(context.note?.content == "private note")
        #expect(context.note?.editedAt == "2026-07-01T10:00:00Z")
    }

    @Test("unstarred local repo does not expose private note")
    func unstarredRepoHidesPrivateNote() async throws {
        let repo = makeRepo(isStarred: false)
        let provider = CompanionContextProvider(
            lookupRepo: { _, _ in repo },
            lookupNote: { _ in
                Issue.record("unstarred repo must not read note content")
                return nil
            }
        )

        let context = try await provider.context(owner: "apple", repo: "swift")

        #expect(context.repo.knownToStarcat == true)
        #expect(context.repo.isStarred == false)
        #expect(context.note == nil)
    }

    @Test("cached health and OpenSSF are exposed without refresh")
    func cachedSignalsAreExposed() async throws {
        let repo = makeRepo(isStarred: true)
        let provider = CompanionContextProvider(
            lookupRepo: { _, _ in repo },
            lookupHealth: { repoID in
                #expect(repoID == 44_838_949)
                return RepoHealthSnapshot(
                    repoId: repoID,
                    overallScore: 82,
                    grade: "B",
                    maintenanceScore: 80,
                    popularityScore: 90,
                    qualityScore: 76,
                    securityScore: 84,
                    payloadJSON: "{}",
                    computedAt: "2026-07-01T10:00:00Z",
                    staleAfter: "2026-07-02T10:00:00Z",
                    fetchStatus: .success,
                    lastError: nil
                )
            },
            lookupOpenSSF: { repoID in
                #expect(repoID == 44_838_949)
                return OpenSSFScoreRecord(
                    repoId: repoID,
                    fetchStatus: .success,
                    aggregateScore: 7.4,
                    checksJSON: nil,
                    scoreDate: "2026-06-30",
                    fetchedAt: "2026-07-01T10:00:00Z",
                    lastError: nil
                )
            }
        )

        let context = try await provider.context(owner: "apple", repo: "swift")

        #expect(context.health?.score == 82)
        #expect(context.health?.grade == "B")
        #expect(context.health?.computedAt == "2026-07-01T10:00:00Z")
        #expect(context.openssf?.score == 7.4)
        #expect(context.openssf?.scoreDate == "2026-06-30")
    }

    @Test("cached wiki links are exposed with English titles")
    func cachedWikiLinksAreExposed() async throws {
        let deepWikiURL = try #require(URL(string: "https://deepwiki.com/apple/swift"))
        let zreadURL = try #require(URL(string: "https://zread.ai/apple/swift"))
        let provider = CompanionContextProvider(
            lookupRepo: { _, _ in nil },
            lookupWikiLinks: { owner, repo in
                #expect(owner == "apple")
                #expect(repo == "swift")
                return [
                    WikiLink(source: .deepWiki, url: deepWikiURL),
                    WikiLink(source: .zread, url: zreadURL)
                ]
            }
        )

        let context = try await provider.context(owner: "apple", repo: "swift")

        #expect(context.wikiLinks.map { $0.source } == ["deepwiki", "zread"])
        #expect(context.wikiLinks.map { $0.title } == ["DeepWiki", "ZRead"])
        #expect(context.wikiLinks.map { $0.url } == [
            "https://deepwiki.com/apple/swift",
            "https://zread.ai/apple/swift"
        ])
    }

    @Test("recommendations are mapped and limited")
    func recommendationsAreMappedAndLimited() async throws {
        let repo = makeRepo(isStarred: true)
        let provider = CompanionContextProvider(
            lookupRepo: { _, _ in repo },
            lookupRecommendations: { repoID in
                #expect(repoID == 44_838_949)
                return (0..<6).map { index in
                    RepoRecommendationItem(
                        repoID: Int64(index + 1),
                        fullName: "owner\(index)/repo\(index)",
                        description: "description \(index)",
                        language: "Swift",
                        stars: 100 + index,
                        forks: 10,
                        archived: false,
                        score: 0.9 - Double(index) * 0.01,
                        source: "simrepo",
                        reasons: ["similar users", "shared topics"]
                    )
                }
            }
        )

        let context = try await provider.context(owner: "apple", repo: "swift")

        #expect(context.recommendations.count == 5)
        #expect(context.recommendations.first?.repoID == 1)
        #expect(context.recommendations.first?.fullName == "owner0/repo0")
        #expect(context.recommendations.first?.reason == "similar users")
    }

    @Test("recommendation failure degrades to empty group")
    func recommendationFailureIsIsolated() async throws {
        let repo = makeRepo(isStarred: true)
        let provider = CompanionContextProvider(
            lookupRepo: { _, _ in repo },
            lookupRecommendations: { _ in throw FixtureError.expectedFailure }
        )

        let context = try await provider.context(owner: "apple", repo: "swift")

        #expect(context.repo.knownToStarcat == true)
        #expect(context.recommendations.isEmpty)
    }

    @Test("missing or failed signal cache is omitted")
    func failedSignalsAreOmitted() async throws {
        let repo = makeRepo(isStarred: true)
        let provider = CompanionContextProvider(
            lookupRepo: { _, _ in repo },
            lookupHealth: { repoID in
                RepoHealthSnapshot(
                    repoId: repoID,
                    overallScore: 0,
                    grade: "F",
                    maintenanceScore: 0,
                    popularityScore: 0,
                    qualityScore: 0,
                    securityScore: 0,
                    payloadJSON: "{}",
                    computedAt: "2026-07-01T10:00:00Z",
                    staleAfter: "2026-07-02T10:00:00Z",
                    fetchStatus: .failed,
                    lastError: "network"
                )
            },
            lookupOpenSSF: { repoID in
                OpenSSFScoreRecord.failure(
                    repoId: repoID,
                    status: .networkError,
                    message: "network",
                    fetchedAt: Date(timeIntervalSince1970: 0)
                )
            }
        )

        let context = try await provider.context(owner: "apple", repo: "swift")

        #expect(context.health == nil)
        #expect(context.openssf == nil)
    }

    @Test("invalid owner or repo is rejected")
    func invalidRepoPath() async throws {
        let provider = CompanionContextProvider { _, _ in nil }

        await #expect(throws: CompanionContextError.invalidRepoPath) {
            _ = try await provider.context(owner: "apple/swift", repo: "swift")
        }
        await #expect(throws: CompanionContextError.invalidRepoPath) {
            _ = try await provider.context(owner: "apple", repo: "")
        }
        await #expect(throws: CompanionContextError.invalidRepoPath) {
            _ = try await provider.context(owner: "苹果", repo: "swift")
        }
    }

    private func makeRepo(isStarred: Bool) -> Repo {
        Repo(
            id: 44_838_949,
            owner: "apple",
            name: "swift",
            fullName: "apple/swift",
            description: "The Swift Programming Language",
            language: "C++",
            starsCount: 70_000,
            forksCount: 11_000,
            watchersCount: 70_000,
            topics: nil,
            license: "Apache-2.0",
            homepage: nil,
            htmlUrl: "https://github.com/apple/swift",
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: false,
            isFork: false,
            isArchived: false,
            isStarred: isStarred,
            pushedAt: nil,
            createdAt: nil,
            updatedAt: nil,
            starredAt: nil,
            cachedAt: "2026-07-01T10:00:00Z"
        )
    }
}
