//
//  SmartCollectionPerformanceTests.swift
//  StarcatTests
//
//  覆盖 Smart Collections 一致性计数快照与进程内 SWR 缓存隔离。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("Smart Collection performance")
struct SmartCollectionPerformanceTests {
    @Test("系统计数输入在同一快照中保留 starred、状态、知识库与未分类事实")
    func systemCountSnapshotKeepsConsistentFacts() async throws {
        let database = try InMemoryDatabaseManager()
        let starredFixture = makeRepo(id: 1, name: "starred", isStarred: true)
        let unstarredFixture = makeRepo(id: 2, name: "unstarred", isStarred: false)
        try await database.writer.write { db in
            var starred = starredFixture
            var unstarred = unstarredFixture
            try starred.save(db)
            try unstarred.save(db)
        }
        try await GRDBRepoNoteRepository(database: database).updateStatus(repoId: 1, status: .using)

        let snapshot = try await SmartCollectionSystemCountsLoader.load(database: database)

        #expect(snapshot.starredRepos.map(\.id) == [1])
        #expect(snapshot.statusByRepoID[1] == .using)
        #expect(snapshot.libraryStateByRepoID[1] == .inLibrary)
        #expect(snapshot.knowledgeCount == 1)
        #expect(snapshot.noTagsCount == 1)
    }

    @Test("SWR 计数缓存按账号和用户规则版本隔离")
    func countCacheSeparatesAccountAndRuleRevision() {
        let cache = SmartCollectionOverviewCountCache()
        let collection = makeCollection(updatedAt: "2026-09-05T10:00:00Z")
        cache.store(
            systemCounts: [.library: 3],
            userCounts: [collection.id: 2],
            accountID: 42,
            collections: [collection]
        )

        #expect(cache.snapshot(accountID: 42, collections: [collection])?.systemCounts[.library] == 3)
        #expect(cache.snapshot(accountID: 7, collections: [collection]) == nil)
        #expect(cache.snapshot(
            accountID: 42,
            collections: [makeCollection(updatedAt: "2026-09-05T11:00:00Z")]
        ) == nil)
    }

    private func makeCollection(updatedAt: String) -> UserSmartCollection {
        UserSmartCollection(
            id: "collection-1",
            name: "Swift",
            icon: "folder",
            color: nil,
            ruleJSON: "{}",
            sortOrder: 0,
            createdAt: "2026-09-05T10:00:00Z",
            updatedAt: updatedAt
        )
    }

    private func makeRepo(id: Int64, name: String, isStarred: Bool) -> Repo {
        Repo(
            id: id,
            owner: "owner",
            name: name,
            fullName: "owner/\(name)",
            description: "fixture",
            language: "Swift",
            starsCount: 10,
            forksCount: 1,
            watchersCount: 2,
            topics: "[]",
            license: nil,
            homepage: nil,
            htmlUrl: "https://github.com/owner/\(name)",
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
            cachedAt: nil
        )
    }
}
