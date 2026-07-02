//
//  RepoNoteRepositoryTests.swift
//  StarcatTests
//
//  GRDBRepoNoteRepository 单测（W4 Batch A1；阅读状态 v2 更新 2026-06-12）。
//
//  覆盖：find / fetchStatusMap / fetchRepos(byStatus) / statusCounts /
//  upsert / updateContent(new+existing) / updateStatus(new+existing) /
//  markAsReadIfNeeded（v2 自动状态机入口） / 旧值 reading/deprecated → read 的 lenient 解析
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
            status: RepoStatus.read.rawValue,
            isAIGenerated: false,
            editedAt: "2026-05-30T10:00:00Z"
        )
        try await repo.upsert(note)

        let got = try #require(try await repo.find(repoId: 1))
        #expect(got.content == "这是一段测试笔记")
        #expect(got.status == "read")
        #expect(got.libraryState == LibraryState.outsideLibrary.rawValue)
        #expect(got.libraryUpdatedAt == nil)
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
        try await repo.updateLibraryState(repoId: 1, state: .inLibrary)
        let before = try #require(try await repo.find(repoId: 1))

        try await repo.updateStatus(repoId: 1, status: .read) // 先设状态
        try await repo.updateContent(repoId: 1, content: "later edit")

        let got = try #require(try await repo.find(repoId: 1))
        #expect(got.content == "later edit")
        #expect(got.status == "read") // status 保留
        #expect(got.libraryState == LibraryState.inLibrary.rawValue)
        #expect(got.libraryUpdatedAt == before.libraryUpdatedAt)
    }

    @Test("updateContent: nil 表示清空内容（status 保留）")
    func updateContentNil() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixture(id: 1)
        try await repo.updateContent(repoId: 1, content: "draft")
        try await repo.updateStatus(repoId: 1, status: .read)

        try await repo.updateContent(repoId: 1, content: nil)
        let got = try #require(try await repo.find(repoId: 1))
        #expect(got.content == nil)
        #expect(got.status == "read")
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

        try await repo.updateStatus(repoId: 1, status: .using)
        let got = try #require(try await repo.find(repoId: 1))
        #expect(got.content == "已写笔记")
        #expect(got.status == "using")
        #expect(got.libraryState == LibraryState.inLibrary.rawValue)
        #expect(got.libraryUpdatedAt != nil)
    }

    @Test("updateStatus: 设置 using 会自动入库，取消 using 不会自动移出")
    func updateStatusUsingAutoEntersLibraryOnly() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixture(id: 1)

        try await repo.updateStatus(repoId: 1, status: .using)
        let usingNote = try #require(try await repo.find(repoId: 1))
        let libraryUpdatedAt = try #require(usingNote.libraryUpdatedAt)
        #expect(usingNote.status == RepoStatus.using.rawValue)
        #expect(usingNote.libraryState == LibraryState.inLibrary.rawValue)

        try await repo.updateStatus(repoId: 1, status: .read)
        let readNote = try #require(try await repo.find(repoId: 1))
        #expect(readNote.status == RepoStatus.read.rawValue)
        #expect(readNote.libraryState == LibraryState.inLibrary.rawValue)
        #expect(readNote.libraryUpdatedAt == libraryUpdatedAt)
    }

    // MARK: - LibraryState

    @Test("fetchLibraryState: 未写过 repo_notes 时默认未入库")
    func fetchLibraryStateMissingDefaultsOutside() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixture(id: 1)

        let state = try await repo.fetchLibraryState(repoId: 1)
        #expect(state == .outsideLibrary)
    }

    @Test("updateLibraryState: 手动加入知识库会创建 unread 行")
    func updateLibraryStateCreatesUnreadRow() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixture(id: 1)

        try await repo.updateLibraryState(repoId: 1, state: .inLibrary)

        let got = try #require(try await repo.find(repoId: 1))
        #expect(got.status == RepoStatus.unread.rawValue)
        #expect(got.content == nil)
        #expect(got.libraryState == LibraryState.inLibrary.rawValue)
        #expect(got.libraryUpdatedAt != nil)
    }

    @Test("updateLibraryState: content/status/library state 互不覆盖")
    func updateLibraryStateDoesNotTouchContentOrStatus() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixture(id: 1)
        try await repo.updateContent(repoId: 1, content: "保留笔记")
        try await repo.updateStatus(repoId: 1, status: .read)

        try await repo.updateLibraryState(repoId: 1, state: .inLibrary)
        let inLibrary = try #require(try await repo.find(repoId: 1))
        #expect(inLibrary.content == "保留笔记")
        #expect(inLibrary.status == RepoStatus.read.rawValue)
        #expect(inLibrary.libraryState == LibraryState.inLibrary.rawValue)

        try await repo.updateLibraryState(repoId: 1, state: .outsideLibrary)
        let outside = try #require(try await repo.find(repoId: 1))
        #expect(outside.content == "保留笔记")
        #expect(outside.status == RepoStatus.read.rawValue)
        #expect(outside.libraryState == LibraryState.outsideLibrary.rawValue)
    }

    @Test("updateLibraryState: 重复加入已入库 repo 不更新 libraryUpdatedAt")
    func updateLibraryStateDuplicateDoesNotTouchTimestamp() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixture(id: 1)
        try await repo.updateLibraryState(repoId: 1, state: .inLibrary)
        let before = try #require(try await repo.find(repoId: 1))
        let beforeUpdatedAt = try #require(before.libraryUpdatedAt)

        try await repo.updateLibraryState(repoId: 1, state: .inLibrary)

        let after = try #require(try await repo.find(repoId: 1))
        #expect(after.libraryState == LibraryState.inLibrary.rawValue)
        #expect(after.libraryUpdatedAt == beforeUpdatedAt)
    }

    @Test("fetchLibraryStateMap + counts: 批量返回入库状态")
    func fetchLibraryStateMapAndCounts() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixtures(count: 3, idStart: 1)
        try await repo.updateLibraryState(repoId: 1, state: .inLibrary)
        try await repo.updateContent(repoId: 2, content: "只写笔记")

        let map = try await repo.fetchLibraryStateMap(repoIds: [1, 2, 3])
        #expect(map[1] == .inLibrary)
        #expect(map[2] == .outsideLibrary)
        #expect(map[3] == nil)

        let allMap = try await repo.fetchAllLibraryStateMap()
        #expect(allMap[1] == .inLibrary)
        #expect(allMap[2] == .outsideLibrary)

        let counts = try await repo.libraryStateCounts()
        #expect(counts[.inLibrary] == 1)
        #expect(counts[.outsideLibrary] == 1)
    }

    // MARK: - 状态批量查询

    @Test("fetchStatusMap: 批量返回多 repo 状态")
    func fetchStatusMapBulk() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixtures(count: 3, idStart: 1)
        try await repo.updateStatus(repoId: 1, status: .using)
        try await repo.updateStatus(repoId: 2, status: .read)
        // repo 3 没写过

        let map = try await repo.fetchStatusMap(repoIds: [1, 2, 3])
        #expect(map[1] == .using)
        #expect(map[2] == .read)
        #expect(map[3] == nil) // 没写过 → 不在 map 里
    }

    @Test("fetchRepos(byStatus:): 按状态过滤 starred repo")
    func fetchReposByStatus() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixtures(count: 3, idStart: 1)
        try await repo.updateStatus(repoId: 1, status: .using)
        try await repo.updateStatus(repoId: 2, status: .read)
        try await repo.updateStatus(repoId: 3, status: .using)

        let usingRepos = try await repo.fetchRepos(byStatus: .using)
        #expect(Set(usingRepos.map(\.id)) == [1, 3])

        let readRepos = try await repo.fetchRepos(byStatus: .read)
        #expect(readRepos.map(\.id) == [2])
    }

    @Test("statusCounts: group by 统计（v2 三态 + 旧值并入 read）")
    func statusCountsBulk() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixtures(count: 6, idStart: 1)
        try await repo.updateStatus(repoId: 1, status: .using)
        try await repo.updateStatus(repoId: 2, status: .using)
        try await repo.updateStatus(repoId: 3, status: .read)
        try await repo.updateStatus(repoId: 4, status: .unread)
        // repo 5: 直接 upsert 一个 v1 旧值 "reading" 模拟存量数据
        try await repo.upsert(RepoNote(
            repoId: 5,
            content: nil,
            status: "reading",
            isAIGenerated: false,
            editedAt: nil
        ))
        // repo 6 没写过

        let counts = try await repo.statusCounts()
        #expect(counts[.using] == 2)
        // .read 计数应包含真 read（repo 3）+ 旧值 reading 被 lenient 解析归入（repo 5）
        #expect(counts[.read] == 2)
        #expect(counts[.unread] == 1)
    }

    // MARK: - markAsReadIfNeeded（v2 自动状态机）

    @Test("markAsReadIfNeeded: 行不存在 → 创建 read 行")
    func markAsReadCreatesRow() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixture(id: 1)

        try await repo.markAsReadIfNeeded(repoId: 1)
        let got = try #require(try await repo.find(repoId: 1))
        #expect(got.status == "read")
        #expect(got.content == nil)
        #expect(got.editedAt != nil)
    }

    @Test("markAsReadIfNeeded: unread → read 升级")
    func markAsReadUpgradesUnread() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixture(id: 1)
        try await repo.updateStatus(repoId: 1, status: .unread)

        try await repo.markAsReadIfNeeded(repoId: 1)
        let got = try #require(try await repo.find(repoId: 1))
        #expect(got.status == "read")
    }

    @Test("markAsReadIfNeeded: read 行幂等不变")
    func markAsReadIdempotentOnRead() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixture(id: 1)
        try await repo.updateStatus(repoId: 1, status: .read)
        let before = try #require(try await repo.find(repoId: 1))

        try await repo.markAsReadIfNeeded(repoId: 1)
        let after = try #require(try await repo.find(repoId: 1))
        #expect(after.status == "read")
        // editedAt 不应被无意义擦动（保留首次 read 时间）
        #expect(after.editedAt == before.editedAt)
    }

    @Test("markAsReadIfNeeded: using 不被覆盖（绝不下行）")
    func markAsReadNeverOverridesUsing() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixture(id: 1)
        try await repo.updateStatus(repoId: 1, status: .using)

        try await repo.markAsReadIfNeeded(repoId: 1)
        let got = try #require(try await repo.find(repoId: 1))
        #expect(got.status == "using")
    }

    @Test("markAsReadIfNeeded: 不动 v1 旧值 reading/deprecated（保守不覆盖）")
    func markAsReadDoesNotTouchLegacyValues() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixtures(count: 2, idStart: 1)
        // 直接灌 v1 旧裸值
        try await repo.upsert(RepoNote(
            repoId: 1, content: nil, status: "reading",
            isAIGenerated: false, editedAt: "2026-01-01T00:00:00Z"
        ))
        try await repo.upsert(RepoNote(
            repoId: 2, content: nil, status: "deprecated",
            isAIGenerated: false, editedAt: "2026-01-01T00:00:00Z"
        ))

        try await repo.markAsReadIfNeeded(repoId: 1)
        try await repo.markAsReadIfNeeded(repoId: 2)

        let r1 = try #require(try await repo.find(repoId: 1))
        let r2 = try #require(try await repo.find(repoId: 2))
        // SQL WHERE 锁 status='unread'，所以 reading/deprecated 不被改写到 read。
        // UI 层通过 RepoStatus.parse 把它们渲染为 .read（被动归一），DB 列保留原值
        // 直到用户主动 setStatus 覆盖。
        #expect(r1.status == "reading")
        #expect(r2.status == "deprecated")
    }

    // MARK: - RepoStatus.parse（lenient 解析）

    @Test("RepoStatus.parse: 三态识别 + 旧值回落到 read")
    func parseLenient() {
        #expect(RepoStatus.parse("unread") == .unread)
        #expect(RepoStatus.parse("read")   == .read)
        #expect(RepoStatus.parse("using")  == .using)
        // v1 旧值
        #expect(RepoStatus.parse("reading")    == .read)
        #expect(RepoStatus.parse("deprecated") == .read)
        // 未知值保守回落到 read
        #expect(RepoStatus.parse("garbage") == .read)
    }
}
