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
