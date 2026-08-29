//
//  GitHubStarListRepositoryTests.swift
//  StarcatTests
//
//  GRDBGitHubStarListRepository 单测。
//
//  覆盖 GitHub Stars List 本地镜像的核心约束：
//  - 远端快照覆盖 list 和 membership
//  - 远端同步不覆盖本地颜色
//  - repo 与 list 是多对多
//  - 虚拟「未分组」由 NOT EXISTS 查询派生，不落实体行
//

import Testing
import Foundation
@testable import Starcat

@Suite("GRDBGitHubStarListRepository")
struct GitHubStarListRepositoryTests {

    private func makeRepo() throws -> (GRDBGitHubStarListRepository, any DatabaseManaging) {
        let db = try InMemoryDatabaseManager()
        return (GRDBGitHubStarListRepository(database: db), db)
    }

    private func remoteList(
        id: String,
        name: String,
        position: Int = 0,
        isPrivate: Bool = false
    ) -> GitHubStarListRemoteRecord {
        GitHubStarListRemoteRecord(
            id: id,
            name: name,
            description: "desc-\(name)",
            isPrivate: isPrivate,
            position: position,
            createdAt: "2026-06-26T00:00:00Z",
            updatedAt: "2026-06-26T00:00:00Z"
        )
    }

    @Test("replaceRemoteSnapshot: 写入 lists 并按远端顺序排序")
    func replaceSnapshotWritesLists() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixtures(count: 2, idStart: 1)

        try await repo.replaceRemoteSnapshot(
            lists: [
                remoteList(id: "list-b", name: "Beta", position: 1),
                remoteList(id: "list-a", name: "Alpha", position: 0)
            ],
            memberships: [],
            syncedAt: Date(timeIntervalSince1970: 0)
        )

        let lists = try await repo.fetchAllLists()
        #expect(lists.map(\.id) == ["list-a", "list-b"])
        #expect(lists.allSatisfy { !$0.colorHex.isEmpty })
    }

    @Test("replaceRemoteSnapshot: 保留已有本地颜色")
    func replaceSnapshotPreservesLocalColor() async throws {
        let (repo, _) = try makeRepo()

        try await repo.replaceRemoteSnapshot(
            lists: [remoteList(id: "list-1", name: "Original")],
            memberships: [],
            syncedAt: Date(timeIntervalSince1970: 0)
        )
        try await repo.upsertList(
            remoteList(id: "list-1", name: "Original"),
            colorHex: "#123456",
            syncedAt: Date(timeIntervalSince1970: 1)
        )

        try await repo.replaceRemoteSnapshot(
            lists: [remoteList(id: "list-1", name: "Renamed")],
            memberships: [],
            syncedAt: Date(timeIntervalSince1970: 2)
        )

        let list = try #require(await repo.findList(id: "list-1"))
        #expect(list.name == "Renamed")
        #expect(list.colorHex == "#123456")
    }

    @Test("replaceRemoteSnapshot: 只映射本地已缓存且 starred 的 repo")
    func replaceSnapshotMapsLocalStarredReposOnly() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixture(id: 1, owner: "octo", name: "one")
        try await db.insertRepoFixture(id: 2, owner: "octo", name: "two")
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE repos SET is_starred = 0 WHERE id = 2")
        }

        try await repo.replaceRemoteSnapshot(
            lists: [remoteList(id: "list-1", name: "Tools")],
            memberships: [
                GitHubStarListRemoteMembership(listId: "list-1", repoFullName: "octo/one"),
                GitHubStarListRemoteMembership(listId: "list-1", repoFullName: "octo/two"),
                GitHubStarListRemoteMembership(listId: "list-1", repoFullName: "octo/missing")
            ],
            syncedAt: Date(timeIntervalSince1970: 0)
        )

        #expect(try await repo.listIds(forRepo: 1) == ["list-1"])
        #expect(try await repo.listIds(forRepo: 2).isEmpty)
        #expect(try await repo.repoCountsByList()["list-1"] == 1)
    }

    @Test("setListIds: 替换单 repo 的完整 list 集合")
    func setListIdsReplacesMemberships() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixture(id: 1, owner: "octo", name: "one")
        try await repo.replaceRemoteSnapshot(
            lists: [
                remoteList(id: "list-a", name: "A", position: 0),
                remoteList(id: "list-b", name: "B", position: 1)
            ],
            memberships: [
                GitHubStarListRemoteMembership(listId: "list-a", repoFullName: "octo/one")
            ],
            syncedAt: Date(timeIntervalSince1970: 0)
        )

        try await repo.setListIds(forRepo: 1, listIds: ["list-b", "list-b"])

        #expect(try await repo.listIds(forRepo: 1) == ["list-b"])
        #expect(try await repo.repoCountsByList()["list-a"] == nil)
        #expect(try await repo.repoCountsByList()["list-b"] == 1)
    }

    @Test("fetchAllListAssignments: 一个仓库可同时属于多个 Lists")
    func fetchAllAssignmentsKeepsManyToManyMemberships() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixture(id: 1, owner: "octo", name: "one")
        try await repo.replaceRemoteSnapshot(
            lists: [
                remoteList(id: "list-a", name: "A", position: 0),
                remoteList(id: "list-b", name: "B", position: 1)
            ],
            memberships: [
                GitHubStarListRemoteMembership(listId: "list-a", repoFullName: "octo/one"),
                GitHubStarListRemoteMembership(listId: "list-b", repoFullName: "octo/one")
            ],
            syncedAt: Date(timeIntervalSince1970: 0)
        )

        let assignments = try await repo.fetchAllListAssignments()
        #expect(assignments[1]?.map(\.id) == ["list-a", "list-b"])
    }

    @Test("AI 规则: 远端快照不覆盖本地规则，删除 List 后级联清理")
    func aiRuleSurvivesSnapshotAndCascadesOnDelete() async throws {
        let (repo, _) = try makeRepo()
        try await repo.replaceRemoteSnapshot(
            lists: [remoteList(id: "list-1", name: "Original")],
            memberships: [],
            syncedAt: Date(timeIntervalSince1970: 0)
        )
        let rule = GitHubStarListAIRule(
            listId: "list-1",
            instruction: "Only native Swift tools",
            autoApplyEnabled: true,
            updatedAt: "2026-08-26T00:00:00Z"
        )
        try await repo.upsertAIRule(rule)

        try await repo.replaceRemoteSnapshot(
            lists: [remoteList(id: "list-1", name: "Renamed")],
            memberships: [],
            syncedAt: Date(timeIntervalSince1970: 1)
        )
        #expect(try await repo.findAIRule(listId: "list-1") == rule)

        try await repo.deleteList(id: "list-1")
        #expect(try await repo.findAIRule(listId: "list-1") == nil)
    }

    @Test("ungroupedRepoCount: 统计没有任何 GitHub List 的 starred repo")
    func ungroupedRepoCount() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixture(id: 1, owner: "octo", name: "one")
        try await db.insertRepoFixture(id: 2, owner: "octo", name: "two")
        try await db.insertRepoFixture(id: 3, owner: "octo", name: "three")
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE repos SET is_starred = 0 WHERE id = 3")
        }

        try await repo.replaceRemoteSnapshot(
            lists: [remoteList(id: "list-1", name: "Tools")],
            memberships: [
                GitHubStarListRemoteMembership(listId: "list-1", repoFullName: "octo/one")
            ],
            syncedAt: Date(timeIntervalSince1970: 0)
        )

        #expect(try await repo.ungroupedRepoCount() == 1)
    }

    @Test("AI 自动忽略: 只返回仍未分组的 starred 仓库，并支持显式清除")
    func aiAutoIgnoredReposOnlyIncludeEligibleRepositories() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixture(id: 1, owner: "octo", name: "one")
        try await db.insertRepoFixture(id: 2, owner: "octo", name: "two")
        try await db.insertRepoFixture(id: 3, owner: "octo", name: "three")
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE repos SET is_starred = 0 WHERE id = 3")
        }
        try await repo.replaceRemoteSnapshot(
            lists: [remoteList(id: "list-1", name: "Tools")],
            memberships: [
                GitHubStarListRemoteMembership(listId: "list-1", repoFullName: "octo/two")
            ],
            syncedAt: Date(timeIntervalSince1970: 0)
        )
        for repoID in 1...3 {
            try await repo.upsertAIAutoIgnoredRepo(GitHubStarListAIAutoIgnoredRepo(
                repoId: Int64(repoID),
                reason: .organizationOAuthRestriction,
                updatedAt: "2026-08-29T00:00:0\(repoID)Z"
            ))
        }

        #expect(try await repo.fetchAIAutoIgnoredRepos().map(\.repoId) == [1])

        try await repo.deleteAIAutoIgnoredRepo(repoId: 1)
        #expect(try await repo.fetchAIAutoIgnoredRepos().isEmpty)
    }
}
