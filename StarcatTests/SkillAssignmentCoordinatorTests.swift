//
//  SkillAssignmentCoordinatorTests.swift
//  StarcatTests
//
//  使用临时 Home、真实 symlink 与独立 SQLite 验证自有链接生命周期，
//  不运行 Agent，也不访问用户配置目录。
//

import Foundation
import GRDB
import Testing
@testable import Starcat

@Suite("Skill 自有分配生命周期")
struct SkillAssignmentCoordinatorTests {
    @Test("App Store 服务构造在写入前拒绝")
    func rejectsAppStore() throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        #expect(throws: DistributionGateError.self) {
            _ = try SkillAssignmentCoordinator(store: fixture.store, distributionGate: DistributionGate(channel: .appStore))
        }
        #expect(!SkillFilePrimitives.exists(fixture.store.paths.database))
    }

    @Test("分配、暂停、恢复、卸载始终保留受管内容和原目录")
    func completesLifecycle() async throws {
        let fixture = try await AssignmentFixture.make()
        defer { fixture.base.remove() }
        let service = try fixture.coordinator()
        let plan = try await fixture.prepare(service)
        #expect(await service.execute(plan).status == .succeeded)
        let assigned = try #require(try await fixture.base.store.snapshot().assignments.first)
        #expect(SkillFilePrimitives.isSymbolicLink(fixture.target))
        let pause = try await service.prepare(entryID: fixture.entry.id, action: .pause, assignmentID: assigned.id)
        #expect(await service.execute(pause).status == .succeeded)
        #expect(!SkillFilePrimitives.exists(fixture.target))
        #expect(try await service.observations(entryID: fixture.entry.id).first?.state == .paused)
        let resume = try await service.prepare(entryID: fixture.entry.id, action: .resume, assignmentID: assigned.id)
        #expect(await service.execute(resume).status == .succeeded)
        #expect(try await service.observations(entryID: fixture.entry.id).first?.state == .linked)
        let uninstall = try await service.prepare(entryID: fixture.entry.id, action: .uninstall, assignmentID: assigned.id)
        #expect(await service.execute(uninstall).status == .succeeded)
        #expect(!SkillFilePrimitives.exists(fixture.target))
        #expect(try await fixture.base.store.snapshot().assignments.isEmpty)
        #expect(SkillFilePrimitives.exists(fixture.content.appendingPathComponent("SKILL.md")))
        #expect(SkillFilePrimitives.exists(fixture.base.incoming.appendingPathComponent("SKILL.md")))
    }

    @Test("物理共享根只分配一次，逻辑工具与路径仍完整保留")
    func deduplicatesSharedRoots() async throws {
        let fixture = try await AssignmentFixture.make(shared: true)
        defer { fixture.base.remove() }
        let service = try fixture.coordinator()
        let targets = try await service.targets()
        #expect(targets.count == 1)
        #expect(targets.first?.configuredPaths.count == 2)
        #expect(Set(targets.first?.agentIDs ?? []) == ["codex", "claudeCode", "cline"])
        let plan = try await fixture.prepare(service)
        async let first = service.execute(plan)
        async let second = service.execute(plan)
        #expect(await [first, second].allSatisfy(\.isSuccess))
        let again = try await fixture.prepare(service)
        #expect(await service.execute(again).status == .alreadySatisfied)
        #expect(try await fixture.base.store.snapshot().assignments.count == 1)
    }

    @Test("外部同名目录或链接均不能由分配覆盖", arguments: [false, true])
    func rejectsExternalTargets(link: Bool) async throws {
        let fixture = try await AssignmentFixture.make()
        defer { fixture.base.remove() }
        if link {
            try FileManager.default.createSymbolicLink(atPath: fixture.target.path, withDestinationPath: fixture.content.path)
        } else {
            try FileManager.default.createDirectory(at: fixture.target, withIntermediateDirectories: true)
        }
        let service = try fixture.coordinator()
        await #expect(throws: SkillOperationError.ownership) { try await fixture.prepare(service) }
        #expect(SkillFilePrimitives.exists(fixture.target))
    }

    @Test("同指向但被用户重新创建的链接不再属于原分配")
    func refusesReplacedLink() async throws {
        let fixture = try await AssignmentFixture.make()
        defer { fixture.base.remove() }
        let service = try fixture.coordinator()
        #expect(await service.execute(try await fixture.prepare(service)).isSuccess)
        let assignment = try #require(try await fixture.base.store.snapshot().assignments.first)
        try FileManager.default.moveItem(at: fixture.target, to: fixture.target.deletingLastPathComponent().appendingPathComponent("saved"))
        try FileManager.default.createSymbolicLink(atPath: fixture.target.path, withDestinationPath: fixture.content.path)
        await #expect(throws: SkillOperationError.ownership) {
            try await service.prepare(entryID: fixture.entry.id, action: .pause, assignmentID: assignment.id)
        }
        #expect(try await service.observations(entryID: fixture.entry.id).first?.state == .conflict)
        #expect(SkillFilePrimitives.isSymbolicLink(fixture.target))
    }

    @Test("暂停后被占用的目标不能恢复覆盖")
    func refusesOccupiedResume() async throws {
        let fixture = try await AssignmentFixture.make()
        defer { fixture.base.remove() }
        let service = try fixture.coordinator()
        #expect(await service.execute(try await fixture.prepare(service)).isSuccess)
        let assignment = try #require(try await fixture.base.store.snapshot().assignments.first)
        #expect(await service.execute(try await service.prepare(
            entryID: fixture.entry.id, action: .pause, assignmentID: assignment.id
        )).isSuccess)
        try FileManager.default.createDirectory(at: fixture.target, withIntermediateDirectories: true)
        await #expect(throws: SkillOperationError.ownership) {
            try await service.prepare(entryID: fixture.entry.id, action: .resume, assignmentID: assignment.id)
        }
        #expect(try await fixture.base.store.snapshot().assignments.first?.desiredState == .paused)
    }

    @Test("缺失链接只显示事实，刷新不会自动重建")
    func observesMissingWithoutRepair() async throws {
        let fixture = try await AssignmentFixture.make()
        defer { fixture.base.remove() }
        let service = try fixture.coordinator()
        #expect(await service.execute(try await fixture.prepare(service)).isSuccess)
        try FileManager.default.removeItem(at: fixture.target)
        #expect(try await service.observations(entryID: fixture.entry.id).first?.state == .missing)
        #expect(await service.recover().isEmpty)
        #expect(!SkillFilePrimitives.exists(fixture.target))
    }

    @Test("链接改变后元数据失败可恢复", arguments: SkillAssignmentAction.allCases)
    func recoversMetadata(action: SkillAssignmentAction) async throws {
        let fixture = try await AssignmentFixture.make()
        defer { fixture.base.remove() }
        let normal = try fixture.coordinator()
        var assignmentID: UUID?
        if action != .assign {
            #expect(await normal.execute(try await fixture.prepare(normal)).isSuccess)
            assignmentID = try #require(try await fixture.base.store.snapshot().assignments.first?.id)
        }
        if action == .resume {
            #expect(await normal.execute(try await normal.prepare(
                entryID: fixture.entry.id, action: .pause, assignmentID: assignmentID
            )).isSuccess)
        }
        let fault = try fixture.coordinator { if $0 == .afterLink { throw CocoaError(.fileWriteUnknown) } }
        let plan = if action == .assign { try await fixture.prepare(fault) }
            else { try await fault.prepare(entryID: fixture.entry.id, action: action, assignmentID: assignmentID) }
        #expect(await fault.execute(plan).status == .needsRecovery)
        #expect(try await fixture.base.coordinator().recover().isEmpty)
        #expect(await normal.recover().map(\.status) == [.succeeded])
        #expect(await normal.recover().isEmpty)
        let remaining = try await fixture.base.store.snapshot().assignments
        if action == .uninstall { #expect(remaining.isEmpty) }
        else { #expect(remaining.first?.desiredState == (action == .pause ? .paused : .active)) }
    }

    @Test("真正 SQLite 写入失败保留链接与 journal")
    func recoversDatabaseFailure() async throws {
        let fixture = try await AssignmentFixture.make()
        defer { fixture.base.remove() }
        let database = try DatabaseQueue(path: fixture.base.store.paths.database.path)
        try await database.write {
            try $0.execute(sql: """
                CREATE TRIGGER reject_assignment BEFORE INSERT ON skill_assignments
                BEGIN SELECT RAISE(ABORT, 'fixture assignment failure'); END;
                """)
        }
        let service = try fixture.coordinator()
        #expect(await service.execute(try await fixture.prepare(service)).status == .needsRecovery)
        #expect(SkillFilePrimitives.isSymbolicLink(fixture.target))
        #expect(try await fixture.base.store.snapshot().assignments.isEmpty)
        try await database.write { try $0.execute(sql: "DROP TRIGGER reject_assignment") }
        #expect(await service.recover().map(\.status) == [.succeeded])
    }

    @Test("恢复遇到外部替换保留未知现场")
    func preservesForeignRecovery() async throws {
        let fixture = try await AssignmentFixture.make()
        defer { fixture.base.remove() }
        let fault = try fixture.coordinator { if $0 == .afterLink { throw CocoaError(.fileWriteUnknown) } }
        #expect(await fault.execute(try await fixture.prepare(fault)).status == .needsRecovery)
        try FileManager.default.removeItem(at: fixture.target)
        try FileManager.default.createDirectory(at: fixture.target, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: fixture.target.appendingPathComponent("user.txt"))
        #expect(try await fixture.coordinator().recover().map(\.status) == [.needsRecovery])
        #expect(try String(contentsOf: fixture.target.appendingPathComponent("user.txt"), encoding: .utf8) == "keep")
    }

    @Test("发布前取消清理本轮临时链接")
    func cancelsBeforePublish() async throws {
        let fixture = try await AssignmentFixture.make()
        defer { fixture.base.remove() }
        let service = try fixture.coordinator { if $0 == .beforeLink { throw CancellationError() } }
        #expect(await service.execute(try await fixture.prepare(service)).status == .cancelled)
        #expect(!SkillFilePrimitives.exists(fixture.target))
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.target.deletingLastPathComponent().path)
        #expect(!names.contains { $0.hasPrefix(".starcat-link-") })
    }

    @Test("预览后配置根改指向不向新位置写入")
    func rejectsRetargetedRoot() async throws {
        let fixture = try await AssignmentFixture.make(shared: true)
        defer { fixture.base.remove() }
        let service = try fixture.coordinator()
        let plan = try await fixture.prepare(service)
        let alias = fixture.home.appendingPathComponent(".claude/skills")
        try FileManager.default.removeItem(at: alias)
        let foreign = fixture.home.appendingPathComponent("foreign")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: foreign.path)
        #expect(await service.execute(plan).status == .conflict)
        #expect(!SkillFilePrimitives.exists(foreign.appendingPathComponent("sample")))
    }

    @Test("缺失 journal 的未完成操作阻止同条目的后续内容和分配写入")
    func blocksUnresolvedOperation() async throws {
        let fixture = try await AssignmentFixture.make()
        defer { fixture.base.remove() }
        let service = try fixture.coordinator()
        let assignment = try await fixture.prepare(service)
        try await fixture.base.store.save(SkillOperationRecord(
            id: UUID(), entryID: fixture.entry.id, kind: "assignment.assign",
            state: "running", journalPath: fixture.base.root.appendingPathComponent("missing.json").path
        ))
        #expect(await service.execute(assignment).status == .conflict)
        let update = try await fixture.base.plan(text: "updated", previous: fixture.entry)
        #expect(try await fixture.base.coordinator().execute(update).status == .conflict)
        #expect(!SkillFilePrimitives.exists(fixture.target))
    }

    @Test("排他发布在目标已存在时保留双方链接")
    func exclusivePublishPreservesForeignTarget() throws {
        let base = try SkillOperationFixture()
        defer { base.remove() }
        let staged = base.root.appendingPathComponent("staged")
        let target = base.root.appendingPathComponent("target")
        try FileManager.default.createSymbolicLink(atPath: staged.path, withDestinationPath: "managed")
        try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: "foreign")
        #expect(throws: POSIXError.self) { try SkillFilePrimitives.moveExclusively(staged, to: target) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.path) == "foreign")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: staged.path) == "managed")
        try FileManager.default.removeItem(at: target)
        try SkillFilePrimitives.moveExclusively(staged, to: target)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.path) == "managed")
        #expect(!SkillFilePrimitives.exists(staged))
    }
}

/// 临时 Home 显式注入支持工具，测试不依赖开发机安装了哪些 Agent。
struct AssignmentFixture {
    let base: SkillOperationFixture
    let entry: SkillLibraryEntry
    var home: URL { base.root.appendingPathComponent("home") }
    var target: URL { home.appendingPathComponent(".agents/skills").resolvingSymlinksInPath().appendingPathComponent("sample") }
    var content: URL {
        base.store.paths.entryDirectory(entry.id).appendingPathComponent("content/sample").resolvingSymlinksInPath()
    }

    static func make(shared: Bool = false) async throws -> Self {
        let base = try SkillOperationFixture()
        do {
            let plan = try await base.plan()
            let result = try await base.coordinator().execute(plan)
            #expect(result.isSuccess)
            let entry = try #require(try await base.store.snapshot().entries.first)
            let fixture = Self(base: base, entry: entry)
            let root = fixture.home.appendingPathComponent(".agents/skills")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try await base.store.save(SkillLibraryRoot(configuredPath: root.path, agentIDs: ["codex", "cline"], scope: .global))
            if shared {
                let alias = fixture.home.appendingPathComponent(".claude/skills")
                try FileManager.default.createDirectory(at: alias.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: root.path)
                try await base.store.save(SkillLibraryRoot(configuredPath: alias.path, agentIDs: ["claudeCode"], scope: .global))
            }
            return fixture
        } catch { base.remove(); throw error }
    }

    func coordinator(
        checkpoint: @escaping @Sendable (SkillAssignmentCheckpoint) throws -> Void = { _ in }
    ) throws -> SkillAssignmentCoordinator {
        try SkillAssignmentCoordinator(
            store: base.store, distributionGate: DistributionGate(channel: .direct),
            home: home, environment: [:], detectedPresets: [.codex, .claudeCode], checkpoint: checkpoint
        )
    }

    func prepare(_ service: SkillAssignmentCoordinator) async throws -> SkillAssignmentPlan {
        let target = try #require(try await service.targets().first)
        return try await service.prepare(entryID: entry.id, action: .assign, targetID: target.id)
    }
}
