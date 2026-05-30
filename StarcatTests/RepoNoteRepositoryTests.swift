//
//  RepoNoteRepositoryTests.swift
//  StarcatTests
//
//  GRDBRepoNoteRepository 单测（W4 Batch A1）。
//
//  覆盖：find / fetchStatusMap / fetchRepos(byStatus) / statusCounts /
//  upsert / updateContent(new+existing) / updateStatus(new+existing)
//

import Testing
import Foundation
import GRDB
@testable import Starcat

@Suite("GRDBRepoNoteRepository")
struct RepoNoteRepositoryTests {

    private func makeRepo() throws -> (GRDBRepoNoteRepository, any DatabaseManaging) {
        let db = try InMemoryDatabaseManager()
        return (GRDBRepoNoteRepository(database: db), db)
    }

    // MARK: - 查询

    @Test("find: 未写过返回 nil")
    func findMiss() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixture(id: 1)
        let got = try await repo.find(repoId: 1)
        #expect(got == nil)
    }

    // MARK: - upsert

    @Test("upsert + find: 整记录往返")
    func upsertThenFind() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixture(id: 1)

        let note = RepoNote(
            repoId: 1,
            content: "这是一段测试笔记",
            status: RepoStatus.reading.rawValue,
            isAIGenerated: false,
            editedAt: "2026-05-30T10:00:00Z"
        )
        try await repo.upsert(note)

        let got = try #require(try await repo.find(repoId: 1))
        #expect(got.content == "这是一段测试笔记")
        #expect(got.status == "reading")
        #expect(got.editedAt == "2026-05-30T10:00:00Z")
    }

    // MARK: - updateContent

    @Test("updateContent: 行不存在 → 自动创建，status 默认 unread")
    func updateContentCreate() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixture(id: 1)

        try await repo.updateContent(repoId: 1, content: "first edit")

        let got = try #require(try await repo.find(repoId: 1))
        #expect(got.content == "first edit")
        #expect(got.status == RepoStatus.unread.rawValue)
        #expect(got.editedAt != nil) // 自动填充
    }

    @Test("updateContent: 行已存在 → 仅 content + editedAt，不动 status")
    func updateContentExisting() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixture(id: 1)
        try await repo.updateStatus(repoId: 1, status: .using) // 先设状态
        try await repo.updateContent(repoId: 1, content: "later edit")

        let got = try #require(try await repo.find(repoId: 1))
        #expect(got.content == "later edit")
        #expect(got.status == "using") // status 保留
    }

    @Test("updateContent: nil 表示清空内容（status 保留）")
    func updateContentNil() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixture(id: 1)
        try await repo.updateContent(repoId: 1, content: "draft")
        try await repo.updateStatus(repoId: 1, status: .reading)

        try await repo.updateContent(repoId: 1, content: nil)
        let got = try #require(try await repo.find(repoId: 1))
        #expect(got.content == nil)
        #expect(got.status == "reading")
    }

    // MARK: - updateStatus

    @Test("updateStatus: 行不存在 → 自动创建，content 为 nil")
    func updateStatusCreate() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixture(id: 1)

        try await repo.updateStatus(repoId: 1, status: .using)

        let got = try #require(try await repo.find(repoId: 1))
        #expect(got.status == "using")
        #expect(got.content == nil)
    }

    @Test("updateStatus: 行已存在 → 仅改 status，content 保留")
    func updateStatusExisting() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixture(id: 1)
        try await repo.updateContent(repoId: 1, content: "已写笔记")

        try await repo.updateStatus(repoId: 1, status: .deprecated)
        let got = try #require(try await repo.find(repoId: 1))
        #expect(got.content == "已写笔记")
        #expect(got.status == "deprecated")
    }

    // MARK: - 状态批量查询

    @Test("fetchStatusMap: 批量返回多 repo 状态")
    func fetchStatusMapBulk() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixtures(count: 3, idStart: 1)
        try await repo.updateStatus(repoId: 1, status: .using)
        try await repo.updateStatus(repoId: 2, status: .reading)
        // repo 3 没写过

        let map = try await repo.fetchStatusMap(repoIds: [1, 2, 3])
        #expect(map[1] == .using)
        #expect(map[2] == .reading)
        #expect(map[3] == nil) // 没写过 → 不在 map 里
    }

    @Test("fetchRepos(byStatus:): 按状态过滤 starred repo")
    func fetchReposByStatus() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixtures(count: 3, idStart: 1)
        try await repo.updateStatus(repoId: 1, status: .using)
        try await repo.updateStatus(repoId: 2, status: .reading)
        try await repo.updateStatus(repoId: 3, status: .using)

        let usingRepos = try await repo.fetchRepos(byStatus: .using)
        #expect(Set(usingRepos.map(\.id)) == [1, 3])

        let readingRepos = try await repo.fetchRepos(byStatus: .reading)
        #expect(readingRepos.map(\.id) == [2])
    }

    @Test("statusCounts: group by 统计")
    func statusCountsBulk() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixtures(count: 5, idStart: 1)
        try await repo.updateStatus(repoId: 1, status: .using)
        try await repo.updateStatus(repoId: 2, status: .using)
        try await repo.updateStatus(repoId: 3, status: .reading)
        try await repo.updateStatus(repoId: 4, status: .unread)
        // repo 5 没写过

        let counts = try await repo.statusCounts()
        #expect(counts[.using] == 2)
        #expect(counts[.reading] == 1)
        #expect(counts[.unread] == 1)
        #expect(counts[.deprecated] == nil) // 没有任何 repo 处于该状态
    }
}
