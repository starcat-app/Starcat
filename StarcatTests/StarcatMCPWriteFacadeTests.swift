//
//  StarcatMCPWriteFacadeTests.swift
//  StarcatTests
//
//  MCP 写入门面单测。
//
//  覆盖重点不是 MCP HTTP 协议本身，而是写入工具是否复用 Starcat 现有业务仓库：
//  notes/status 走 RepoNoteRepository，tags 走 GatedTagRepository，状态变更发通知，
//  并且设置页权限关闭时不会写库。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("StarcatMCPWriteFacade")
struct StarcatMCPWriteFacadeTests {

    private func makeSUT(
        isPro: Bool = true,
        allowLocalWrites: Bool = true,
        allowDestructiveWrites: Bool = false
    ) throws -> (
        StarcatMCPWriteFacade,
        GRDBRepoNoteRepository,
        GRDBRepoTagRepository,
        GRDBTagRepository,
        any DatabaseManaging,
        RefreshCounter
    ) {
        let db = try InMemoryDatabaseManager()
        let settings = AppSettings(defaults: UserDefaults(suiteName: "test.starcat.mcp.\(UUID().uuidString)")!)
        settings.mcpAllowLocalWrites = allowLocalWrites
        settings.mcpAllowDestructiveWrites = allowDestructiveWrites

        let gate = EntitlementGate(
            entitlementProvider: TestProEntitlementProvider(isPro: isPro),
            userIDProvider: { 1 }
        )
        let rawTagRepo = GRDBTagRepository(database: db)
        let tagRepo = GatedTagRepository(base: rawTagRepo, entitlementGate: gate)
        let repoTagRepo = GRDBRepoTagRepository(database: db)
        let noteRepo = GRDBRepoNoteRepository(database: db)
        let refreshCounter = RefreshCounter()
        let tmpLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("starcat-mcp-audit-\(UUID().uuidString).jsonl")
        let facade = StarcatMCPWriteFacade(
            repoRepository: GRDBRepoRepository(database: db),
            tagRepository: tagRepo,
            repoTagRepository: repoTagRepo,
            repoNoteRepository: noteRepo,
            settings: settings,
            entitlementGate: gate,
            auditLog: StarcatMCPAuditLog(fileURL: tmpLog),
            refreshSemanticIndex: { _ in refreshCounter.count += 1 }
        )
        return (facade, noteRepo, repoTagRepo, rawTagRepo, db, refreshCounter)
    }

    @Test("本地写入关闭时 upsert_repo_note 被拒绝且不写库")
    func localWriteDisabledRejectsNote() async throws {
        let (facade, noteRepo, _, _, db, _) = try makeSUT(allowLocalWrites: false)
        try await db.insertRepoFixture(id: 1)

        do {
            _ = try await facade.upsertRepoNote(
                repoID: 1,
                owner: nil,
                name: nil,
                content: "blocked",
                dryRun: false
            )
            Issue.record("MCP local writes disabled should reject note writes")
        } catch {
            #expect(error.localizedDescription.contains("disabled"))
        }

        let note = try await noteRepo.find(repoId: 1)
        #expect(note == nil)
    }

    @Test("upsert_repo_note 写入笔记并触发语义索引刷新")
    func upsertNoteWritesAndRefreshesIndex() async throws {
        let (facade, noteRepo, _, _, db, refreshCounter) = try makeSUT()
        try await db.insertRepoFixture(id: 1)

        let result = try await facade.upsertRepoNote(
            repoID: 1,
            owner: nil,
            name: nil,
            content: "Agent generated note",
            dryRun: false
        )

        #expect(result.changed == true)
        #expect(result.note?.content == "Agent generated note")
        #expect(try await noteRepo.find(repoId: 1)?.content == "Agent generated note")
        #expect(refreshCounter.count == 1)
    }

    @Test("set_repo_status 写入状态并发出 repoStatusDidChange 通知")
    func setStatusPostsNotification() async throws {
        let (facade, noteRepo, _, _, db, _) = try makeSUT()
        try await db.insertRepoFixture(id: 1)

        var receivedStatus: String?
        let token = NotificationCenter.default.addObserver(
            forName: .repoStatusDidChange,
            object: nil,
            queue: nil
        ) { note in
            receivedStatus = note.userInfo?["status"] as? String
        }
        defer { NotificationCenter.default.removeObserver(token) }

        _ = try await facade.setRepoStatus(
            repoID: 1,
            owner: nil,
            name: nil,
            status: .using,
            dryRun: false
        )

        #expect(try await noteRepo.find(repoId: 1)?.status == "using")
        #expect(receivedStatus == "using")
    }

    @Test("add_repo_tags 自动创建缺失标签并绑定 repo")
    func addRepoTagsCreatesMissingTags() async throws {
        let (facade, _, repoTagRepo, tagRepo, db, refreshCounter) = try makeSUT()
        try await db.insertRepoFixture(id: 1)

        let result = try await facade.addRepoTags(
            repoID: 1,
            owner: nil,
            name: nil,
            tagNames: ["swift", "ai"],
            createMissing: true,
            dryRun: false
        )

        #expect(result.tags.map(\.name).sorted() == ["ai", "swift"])
        #expect(try await tagRepo.findByName("swift") != nil)
        #expect(try await tagRepo.findByName("ai") != nil)
        #expect(Set(try await repoTagRepo.fetchTags(forRepo: 1).map(\.name)) == ["swift", "ai"])
        #expect(refreshCounter.count == 1)
    }
}

@MainActor
private final class TestProEntitlementProvider: ProEntitlementProviding {
    let entitlement: ProEntitlement

    init(isPro: Bool) {
        self.entitlement = ProEntitlement(
            isActive: isPro,
            productID: isPro ? "test.pro" : nil,
            expirationDate: nil,
            verifiedAt: Date(),
            source: isPro ? .testEnvironment : .none
        )
    }
}

@MainActor
private final class RefreshCounter {
    var count = 0
}

