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
        allowWrites: Bool = true,
        starMutationService: MCPStarMutationServiceStub? = nil
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
        settings.mcpAllowWrites = allowWrites

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
        let repoRepository = GRDBRepoRepository(database: db)
        let metadataCapability = RepositoryMetadataCapabilityExecutor(
            source: DatabaseRepositoryMetadataCapabilitySource(
                repoRepository: repoRepository,
                repoNoteRepository: noteRepo,
                onRepositoryMutation: { repo, mutation in
                    if case .status(let status) = mutation {
                        NotificationCenter.default.post(
                            name: .repoStatusDidChange,
                            object: nil,
                            userInfo: ["repoId": repo.id, "status": status.rawValue]
                        )
                    }
                    refreshCounter.count += 1
                }
            )
        )
        let tagCapability = RepositoryTagCapabilityExecutor(
            source: DatabaseRepositoryTagCapabilitySource(
                repoRepository: repoRepository,
                tagRepository: tagRepo,
                repoTagRepository: repoTagRepo,
                onRepositoryMutation: { _ in refreshCounter.count += 1 }
            )
        )
        let facade = StarcatMCPWriteFacade(
            repoRepository: repoRepository,
            metadataCapability: metadataCapability,
            tagCapability: tagCapability,
            starMutationService: starMutationService ?? MCPStarMutationServiceStub(),
            settings: settings,
            entitlementGate: gate,
            auditLog: StarcatMCPAuditLog(fileURL: tmpLog)
        )
        return (facade, noteRepo, repoTagRepo, rawTagRepo, db, refreshCounter)
    }

    @Test("GitHub Star 写入关闭时拒绝调用远端 Service")
    func githubStarWriteDisabledRejectsMutation() async throws {
        let starService = MCPStarMutationServiceStub()
        let (facade, _, _, _, _, _) = try makeSUT(allowWrites: false, starMutationService: starService)

        do {
            _ = try await facade.starRepo(
                repoID: nil,
                owner: "apple",
                name: "swift",
                dryRun: false
            )
            Issue.record("MCP GitHub Star writes disabled should reject the mutation")
        } catch {
            #expect(error.localizedDescription.contains("disabled"))
        }

        #expect(starService.starredTargets.isEmpty)
    }

    @Test("star_repo 可直接处理尚未进入本地缓存的 GitHub 搜索结果")
    func starRepoAcceptsExternalOwnerAndName() async throws {
        var starred = Repo.makeMinimal(owner: "apple", name: "swift")
        starred.id = 99
        starred.isStarred = true
        let starService = MCPStarMutationServiceStub(starResult: starred)
        let (facade, _, _, _, _, _) = try makeSUT(
            starMutationService: starService
        )

        let result = try await facade.starRepo(
            repoID: nil,
            owner: " apple ",
            name: " swift ",
            dryRun: false
        )

        #expect(result.changed == true)
        #expect(result.target_full_name == "apple/swift")
        #expect(result.repo?.id == 99)
        #expect(starService.starredTargets == ["apple/swift"])
    }

    @Test("unstar_repo 复用远端 Service 且保留统一仓库选择语义")
    func unstarRepoDelegatesToStarActionBoundary() async throws {
        let starService = MCPStarMutationServiceStub()
        let (facade, _, _, _, db, _) = try makeSUT(
            starMutationService: starService
        )
        try await db.insertRepoFixture(id: 7, owner: "octo", name: "remove-me")

        let result = try await facade.unstarRepo(
            repoID: nil,
            owner: "octo",
            name: "remove-me",
            dryRun: false
        )

        #expect(result.changed == true)
        #expect(starService.unstarredTargets == ["octo/remove-me"])
    }

    @Test("Star dry-run 不调用 GitHub 且仍返回明确目标")
    func starRepoDryRunDoesNotCallRemoteService() async throws {
        let starService = MCPStarMutationServiceStub()
        let (facade, _, _, _, _, _) = try makeSUT(
            starMutationService: starService
        )

        let result = try await facade.starRepo(
            repoID: nil,
            owner: "openai",
            name: "codex",
            dryRun: true
        )

        #expect(result.dry_run == true)
        #expect(result.changed == true)
        #expect(result.target_full_name == "openai/codex")
        #expect(starService.starredTargets.isEmpty)
    }

    @Test("本地写入关闭时 upsert_repo_note 被拒绝且不写库")
    func localWriteDisabledRejectsNote() async throws {
        let (facade, noteRepo, _, _, db, _) = try makeSUT(allowWrites: false)
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

        let notificationRecorder = StatusNotificationRecorder()
        let token = NotificationCenter.default.addObserver(
            forName: .repoStatusDidChange,
            object: nil,
            queue: nil
        ) { note in
            notificationRecorder.record(status: note.userInfo?["status"] as? String)
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
        #expect(notificationRecorder.status == "using")
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

    @Test("写入工具按 owner/name 复用统一仓库选择语义")
    func ownerNameSelectorUsesSharedReadCapability() async throws {
        let (facade, _, repoTagRepo, _, db, _) = try makeSUT()
        try await db.insertRepoFixture(id: 7, owner: "octo", name: "shared-capability")

        let result = try await facade.addRepoTags(
            repoID: nil,
            owner: "octo",
            name: "shared-capability",
            tagNames: ["agent"],
            createMissing: true,
            dryRun: false
        )

        #expect(result.repo?.id == 7)
        #expect(try await repoTagRepo.fetchTags(forRepo: 7).map(\.name) == ["agent"])
    }

    @Test("写入工具保持已发布的无效仓库选择错误")
    func invalidSelectorKeepsMCPErrorContract() async throws {
        let (facade, _, _, _, _, _) = try makeSUT()

        await #expect(throws: StarcatMCPError.invalidArguments("Provide repo_id or owner + name")) {
            _ = try await facade.addRepoTags(
                repoID: nil,
                owner: nil,
                name: nil,
                tagNames: ["agent"],
                createMissing: true,
                dryRun: true
            )
        }
    }

    @Test("共享 Capability 错误保持 MCP 已发布的 NOT_FOUND 分类")
    func missingTagKeepsMCPNotFoundError() async throws {
        let (facade, _, _, _, db, _) = try makeSUT()
        try await db.insertRepoFixture(id: 1)

        do {
            _ = try await facade.addRepoTags(
                repoID: 1,
                owner: nil,
                name: nil,
                tagNames: ["missing"],
                createMissing: false,
                dryRun: false
            )
            Issue.record("Missing tag should keep MCP not-found semantics")
        } catch let StarcatMCPError.notFound(message) {
            #expect(message == "Tag not found: missing")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("批量写入关闭时拒绝整批操作且不修改仓库")
    func batchWriteDisabledRejectsAllMutations() async throws {
        let (facade, noteRepo, _, tagRepo, db, _) = try makeSUT(allowWrites: false)
        try await db.insertRepoFixture(id: 1)

        do {
            _ = try await facade.batchOrganizeRepos(
                items: [MCPBatchOrganizeItemInput(
                    repoID: 1,
                    owner: nil,
                    name: nil,
                    tagNames: ["act/test"],
                    note: "blocked"
                )],
                createMissing: true,
                dryRun: false
            )
            Issue.record("MCP batch writes disabled should reject the whole request")
        } catch {
            #expect(error.localizedDescription.contains("disabled"))
        }

        #expect(try await noteRepo.find(repoId: 1) == nil)
        #expect(try await tagRepo.findByName("act/test") == nil)
    }

    @Test("批量整理可在一次请求中为多个仓库添加标签和更新笔记")
    func batchOrganizeWritesTagsAndNotes() async throws {
        let (facade, noteRepo, repoTagRepo, tagRepo, db, _) = try makeSUT()
        try await db.insertRepoFixture(id: 1, owner: "apple", name: "swift")
        try await db.insertRepoFixture(id: 2, owner: "openai", name: "codex")

        let result = try await facade.batchOrganizeRepos(
            items: [
                MCPBatchOrganizeItemInput(
                    repoID: 1,
                    owner: nil,
                    name: nil,
                    tagNames: ["act/test"],
                    note: "Review this repository"
                ),
                MCPBatchOrganizeItemInput(
                    repoID: nil,
                    owner: "openai",
                    name: "codex",
                    tagNames: ["act/test"],
                    note: nil
                )
            ],
            createMissing: true,
            dryRun: false
        )

        let tag = try #require(try await tagRepo.findByName("act/test"))
        #expect(result.ok == true)
        #expect(result.requested_count == 2)
        #expect(result.succeeded_count == 2)
        #expect(result.failed_count == 0)
        #expect(result.changed_count == 2)
        #expect(try await noteRepo.find(repoId: 1)?.content == "Review this repository")
        #expect(try await noteRepo.find(repoId: 2) == nil)
        #expect(try await repoTagRepo.fetchTags(forRepo: 1).map(\.id) == [tag.id])
        #expect(try await repoTagRepo.fetchTags(forRepo: 2).map(\.id) == [tag.id])
    }

    @Test("批量整理 dry-run 只校验且不写入标签或笔记")
    func batchOrganizeDryRunDoesNotPersist() async throws {
        let (facade, noteRepo, repoTagRepo, tagRepo, db, _) = try makeSUT()
        try await db.insertRepoFixture(id: 1)

        let result = try await facade.batchOrganizeRepos(
            items: [MCPBatchOrganizeItemInput(
                repoID: 1,
                owner: nil,
                name: nil,
                tagNames: ["act/study"],
                note: "Preview only"
            )],
            createMissing: true,
            dryRun: true
        )

        #expect(result.ok == true)
        #expect(result.dry_run == true)
        #expect(result.changed_count == 0)
        #expect(result.results.first?.note_requested == true)
        #expect(try await noteRepo.find(repoId: 1) == nil)
        #expect(try await tagRepo.findByName("act/study") == nil)
        #expect(try await repoTagRepo.fetchTags(forRepo: 1).isEmpty)
    }

    @Test("批量整理任一项目预检失败时整批不写入")
    func batchOrganizePreflightFailurePreventsAllWrites() async throws {
        let (facade, noteRepo, _, tagRepo, db, _) = try makeSUT()
        try await db.insertRepoFixture(id: 1)

        do {
            _ = try await facade.batchOrganizeRepos(
                items: [
                    MCPBatchOrganizeItemInput(
                        repoID: 1,
                        owner: nil,
                        name: nil,
                        tagNames: ["act/adopt"],
                        note: "Must remain untouched"
                    ),
                    MCPBatchOrganizeItemInput(
                        repoID: 999,
                        owner: nil,
                        name: nil,
                        tagNames: [],
                        note: "missing repo"
                    )
                ],
                createMissing: true,
                dryRun: false
            )
            Issue.record("A preflight failure should reject the whole batch")
        } catch let StarcatMCPError.notFound(message) {
            #expect(message == "Repo not found: 999")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(try await noteRepo.find(repoId: 1) == nil)
        #expect(try await tagRepo.findByName("act/adopt") == nil)
    }

    @Test("批量整理单次最多处理一百个仓库")
    func batchOrganizeRejectsMoreThanOneHundredItems() async throws {
        let (facade, _, _, _, _, _) = try makeSUT()
        let items = (0..<101).map { index in
            MCPBatchOrganizeItemInput(
                repoID: Int64(index + 1),
                owner: nil,
                name: nil,
                tagNames: [],
                note: "note"
            )
        }

        await #expect(throws: StarcatMCPError.invalidArguments("items must contain no more than 100 repositories")) {
            _ = try await facade.batchOrganizeRepos(
                items: items,
                createMissing: false,
                dryRun: false
            )
        }
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

/// 隔离 GitHub 网络写入；Facade 测试只验证权限、目标解析与业务 Service 委托。
@MainActor
private final class MCPStarMutationServiceStub: MCPStarMutationServicing {
    private let starResult: Repo
    private(set) var starredTargets: [String] = []
    private(set) var unstarredTargets: [String] = []

    init(starResult: Repo = Repo.makeMinimal(owner: "test", name: "repo")) {
        self.starResult = starResult
    }

    func star(owner: String, repo: String, displayedStarsCount: Int?) async throws -> Repo {
        starredTargets.append("\(owner)/\(repo)")
        return starResult
    }

    func unstar(repo: Repo) async throws {
        unstarredTargets.append(repo.fullName)
    }
}

/// Notification 回调可能脱离 MainActor 执行；锁保护测试观察值，避免并发读写竞态。
private final class StatusNotificationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedStatus: String?

    var status: String? {
        lock.withLock { recordedStatus }
    }

    func record(status: String?) {
        lock.withLock { recordedStatus = status }
    }
}
