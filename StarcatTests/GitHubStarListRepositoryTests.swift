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
        #expect(lists.allSatisfy { $0.colorHex.isEmpty })
    }

    @Test("upsertList: 新分组未指定颜色时默认无图标", arguments: [nil, ""] as [String?])
    func newListDefaultsToNoIcon(colorHex: String?) async throws {
        let (repo, _) = try makeRepo()
        try await repo.upsertList(
            remoteList(id: "list-1", name: "Tools"),
            colorHex: colorHex,
            syncedAt: Date(timeIntervalSince1970: 0)
        )

        let list = try #require(await repo.findList(id: "list-1"))
        #expect(list.colorHex.isEmpty)
    }

    @Test("无图标选择写入数据库，并跨 Repository 重建、编辑与远端刷新保留")
    func noIconSurvivesReloadAndSnapshot() async throws {
        let (repo, db) = try makeRepo()
        let remote = remoteList(id: "list-1", name: "Tools")
        try await repo.upsertList(remote, colorHex: "#123456", syncedAt: Date(timeIntervalSince1970: 0))
        // 空字符串明确清除颜色；nil 仍表示调用方未修改本地颜色。
        try await repo.upsertList(remote, colorHex: "", syncedAt: Date(timeIntervalSince1970: 1))
        let reloadedRepo = GRDBGitHubStarListRepository(database: db)
        #expect(try await reloadedRepo.findList(id: remote.id)?.colorHex == "")

        try await reloadedRepo.upsertList(remote, colorHex: nil, syncedAt: Date(timeIntervalSince1970: 2))
        try await reloadedRepo.replaceRemoteSnapshot(
            lists: [remoteList(id: remote.id, name: "Renamed")],
            memberships: [],
            syncedAt: Date(timeIntervalSince1970: 3)
        )
        let list = try #require(await reloadedRepo.findList(id: remote.id))
        #expect(list.name == "Renamed")
        #expect(list.colorHex.isEmpty)

        // 无图标不是不可逆状态，仍可重新选择颜色。
        try await reloadedRepo.upsertList(remote, colorHex: "#30D158", syncedAt: Date(timeIntervalSince1970: 4))
        #expect(try await reloadedRepo.findList(id: remote.id)?.colorHex == "#30D158")
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

    @Test("本地覆盖参与有效分组，并在远端刷新后保留或收敛")
    func localOverridesSurviveAndConvergeWithRemoteSnapshot() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixture(id: 1, owner: "octo", name: "one")
        let lists = [
            remoteList(id: "list-a", name: "A", position: 0),
            remoteList(id: "list-b", name: "B", position: 1)
        ]
        try await repo.replaceRemoteSnapshot(
            lists: lists,
            memberships: [GitHubStarListRemoteMembership(listId: "list-a", repoFullName: "octo/one")],
            syncedAt: Date(timeIntervalSince1970: 0)
        )

        try await repo.setLocalListIds(
            forRepo: 1,
            listIds: ["list-b"],
            failureReason: GitHubStarListAIAutoIgnoreReason.organizationOAuthRestriction.rawValue
        )

        #expect(try await repo.remoteListIds(forRepo: 1) == ["list-a"])
        #expect(try await repo.listIds(forRepo: 1) == ["list-b"])
        #expect(try await repo.repoCountsByList()["list-a"] == nil)
        #expect(try await repo.repoCountsByList()["list-b"] == 1)
        #expect(try await repo.ungroupedRepoCount() == 0)
        #expect(try await repo.hasLocalListOverrides(forRepo: 1))
        #expect(try await repo.fetchPendingLocalMembershipSyncs().first?.desiredListIDs == Set(["list-b"]))

        // GitHub 仍未接受目标集合时，本地覆盖必须跨刷新保留。
        try await repo.replaceRemoteSnapshot(
            lists: lists,
            memberships: [GitHubStarListRemoteMembership(listId: "list-a", repoFullName: "octo/one")],
            syncedAt: Date(timeIntervalSince1970: 1)
        )
        #expect(try await repo.listIds(forRepo: 1) == ["list-b"])

        // 远端最终与本地期望一致后，覆盖行自动收敛，不再进入待同步队列。
        try await repo.replaceRemoteSnapshot(
            lists: lists,
            memberships: [GitHubStarListRemoteMembership(listId: "list-b", repoFullName: "octo/one")],
            syncedAt: Date(timeIntervalSince1970: 2)
        )
        #expect(try await repo.listIds(forRepo: 1) == ["list-b"])
        #expect(try await repo.hasLocalListOverrides(forRepo: 1) == false)
        #expect(try await repo.fetchPendingLocalMembershipSyncs().isEmpty)
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
