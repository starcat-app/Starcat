//
//  SkillRemovalCoordinatorTests.swift
//  StarcatTests
//
//  只在临时 Home 和注入的临时“废纸篓”中验证库移除。
//  使用真实 SQLite、链接和故障点覆盖部分卸载、外键事务及中断恢复，不访问用户文件。
//

import Foundation
import GRDB
import Testing
@testable import Starcat

@Suite("Skill 库移除与恢复")
struct SkillRemovalCoordinatorTests {
    @Test("App Store 执行层在建库前拒绝")
    func rejectsAppStore() throws {
        let base = try SkillOperationFixture()
        defer { base.remove() }
        let operations = try base.coordinator()
        let assignments = try SkillAssignmentCoordinator(
            store: base.store, operations: operations, distributionGate: DistributionGate(channel: .direct)
        )
        #expect(throws: DistributionGateError.self) {
            _ = try SkillRemovalCoordinator(
                store: base.store, operations: operations, assignments: assignments,
                distributionGate: DistributionGate(channel: .appStore)
            )
        }
        #expect(!SkillFilePrimitives.exists(base.store.paths.database))
    }

    @Test("移除活动及暂停分配，保留原始来源与共享来源记录")
    func removesAssignmentsAndLibrary() async throws {
        let fixture = try await AssignmentFixture.make()
        defer { fixture.base.remove() }
        let extra = fixture.home.appendingPathComponent(".claude/skills")
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        try await fixture.base.store.save(SkillLibraryRoot(configuredPath: extra.path, agentIDs: ["claudeCode"], scope: .global))
        let services = try services(fixture)
        let targets = try await services.assignments.targets()
        #expect(targets.count == 2)
        for target in targets {
            let plan = try await services.assignments.prepare(entryID: fixture.entry.id, action: .assign, targetID: target.id)
            #expect(await services.assignments.execute(plan).isSuccess)
        }
        let snapshot = try await fixture.base.store.snapshot()
        let assignment = try #require(snapshot.assignments.first)
        let pause = try await services.assignments.prepare(
            entryID: fixture.entry.id, action: .pause, assignmentID: assignment.id
        )
        #expect(await services.assignments.execute(pause).isSuccess)
        let root = try #require(snapshot.roots.first)
        try await fixture.base.store.save(SkillLibraryLocation(
            entryID: fixture.entry.id, rootID: root.id, lexicalPath: fixture.target.path,
            resolvedPath: fixture.content.path, kind: .symbolicLink
        ))
        let sibling = SkillLibraryEntry(
            sourceID: fixture.entry.sourceID, manifestName: "external", summary: "", managementKind: .external
        )
        try await fixture.base.store.save(sibling)
        let plan = try await services.removals.prepare(entryID: fixture.entry.id)
        #expect(plan.assignments.count == 2)
        let outcome = await services.removals.execute(plan)
        #expect(outcome.result.status == .succeeded)
        #expect(outcome.assignmentResults.count == 2)
        #expect(outcome.assignmentResults.allSatisfy { $0.isSuccess })
        let remaining = try await fixture.base.store.snapshot()
        #expect(remaining.entries.map(\.id) == [sibling.id])
        #expect(remaining.assignments.isEmpty && remaining.revisions.isEmpty && remaining.locations.isEmpty)
        #expect(remaining.sources.count == 1)
        #expect(!SkillFilePrimitives.exists(fixture.base.store.paths.entryDirectory(fixture.entry.id)))
        #expect(SkillFilePrimitives.exists(fixture.base.incoming.appendingPathComponent("SKILL.md")))
        for target in targets {
            #expect(!SkillFilePrimitives.exists(URL(fileURLWithPath: target.resolvedParent).appendingPathComponent("sample")))
        }
        let trashed = URL(fileURLWithPath: try #require(outcome.result.message))
        #expect(try await SkillFilePrimitives.fingerprint(trashed).digest == plan.fingerprint.digest)
        #expect(await services.removals.execute(plan).result.isSuccess)
    }

    @Test("共享物理根只卸载一次，其他工具创建的链接保留")
    func preservesForeignLinks() async throws {
        let fixture = try await AssignmentFixture.make(shared: true)
        defer { fixture.base.remove() }
        let services = try services(fixture)
        let assignment = try await fixture.prepare(services.assignments)
        #expect(await services.assignments.execute(assignment).isSuccess)
        let foreign = fixture.base.root.appendingPathComponent("external-link")
        try FileManager.default.createSymbolicLink(atPath: foreign.path, withDestinationPath: fixture.content.path)
        let plan = try await services.removals.prepare(entryID: fixture.entry.id)
        #expect(plan.assignments.count == 1)
        #expect(plan.assignments.first?.target.agentIDs.count == 3)
        #expect(await services.removals.execute(plan).result.isSuccess)
        #expect(SkillFilePrimitives.isSymbolicLink(foreign))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: foreign.path) == fixture.content.path)
    }

    @Test("本地修改阻断预览和旧计划执行，尚未卸载分配")
    func preservesLocalChanges() async throws {
        let fixture = try await AssignmentFixture.make()
        defer { fixture.base.remove() }
        let services = try services(fixture)
        let assignment = try await fixture.prepare(services.assignments)
        #expect(await services.assignments.execute(assignment).isSuccess)
        let plan = try await services.removals.prepare(entryID: fixture.entry.id)
        let changed = fixture.content.appendingPathComponent("user.txt")
        try Data("local".utf8).write(to: changed)
        #expect(await services.removals.execute(plan).result.status == .conflict)
        await #expect(throws: SkillOperationError.self) { try await services.removals.prepare(entryID: fixture.entry.id) }
        #expect(try String(contentsOf: changed, encoding: .utf8) == "local")
        #expect(SkillFilePrimitives.isSymbolicLink(fixture.target))
    }

    @Test("审核后新增分配或外部重建链接均拒绝旧计划", arguments: [false, true])
    func rejectsChangedAssignments(rebuild: Bool) async throws {
        let fixture = try await AssignmentFixture.make()
        defer { fixture.base.remove() }
        let services = try services(fixture)
        let assignment = try await fixture.prepare(services.assignments)
        if rebuild { #expect(await services.assignments.execute(assignment).isSuccess) }
        let plan = try await services.removals.prepare(entryID: fixture.entry.id)
        if rebuild {
            let held = fixture.base.root.appendingPathComponent("held-link")
            try SkillFilePrimitives.moveExclusively(fixture.target, to: held)
            try FileManager.default.createSymbolicLink(atPath: fixture.target.path, withDestinationPath: fixture.content.path)
        } else {
            #expect(await services.assignments.execute(assignment).isSuccess)
        }
        #expect(await services.removals.execute(plan).result.status == .conflict)
        #expect(SkillFilePrimitives.isSymbolicLink(fixture.target))
        #expect(SkillFilePrimitives.exists(fixture.content))
    }

    @Test("提交前取消保留库内容并清理自有 journal")
    func cancelsBeforeMove() async throws {
        let fixture = try await AssignmentFixture.make()
        defer { fixture.base.remove() }
        let services = try services(fixture, checkpoint: { point in
            if point == .beforeMove { throw CancellationError() }
        })
        let plan = try await services.removals.prepare(entryID: fixture.entry.id)
        #expect(await services.removals.execute(plan).result.status == .cancelled)
        #expect(SkillFilePrimitives.exists(fixture.content))
        #expect(!SkillFilePrimitives.exists(directory(fixture, plan)))
        #expect(await services.removals.recover().isEmpty)
    }

    @Test("部分卸载后另一目标冲突，保留库内容和逐项结果")
    func preservesPartiallyUnassignedEntry() async throws {
        let fixture = try await AssignmentFixture.make()
        defer { fixture.base.remove() }
        let extra = fixture.home.appendingPathComponent(".claude/skills")
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        try await fixture.base.store.save(SkillLibraryRoot(configuredPath: extra.path, agentIDs: ["claudeCode"], scope: .global))
        let services = try services(fixture)
        for target in try await services.assignments.targets() {
            let assignment = try await services.assignments.prepare(entryID: fixture.entry.id, action: .assign, targetID: target.id)
            #expect(await services.assignments.execute(assignment).isSuccess)
        }
        let plan = try await services.removals.prepare(entryID: fixture.entry.id)
        let second = try #require(plan.assignments.last?.previous)
        let occupied = URL(fileURLWithPath: second.targetPath)
        try SkillFilePrimitives.moveExclusively(occupied, to: fixture.base.root.appendingPathComponent("held-second-link"))
        try FileManager.default.createSymbolicLink(atPath: occupied.path, withDestinationPath: fixture.content.path)
        let outcome = await services.removals.execute(plan)
        #expect(outcome.result.status == .conflict)
        #expect(outcome.assignmentResults.map(\.status) == [.succeeded, .conflict])
        #expect(SkillFilePrimitives.exists(fixture.content))
        #expect(SkillFilePrimitives.isSymbolicLink(occupied))
        #expect(try await fixture.base.store.snapshot().assignments.map(\.id) == [second.id])
    }

    @Test("发布后取消不得报告已取消，保留现场并可恢复")
    func keepsCommittedCancellationRecoverable() async throws {
        let fixture = try await AssignmentFixture.make()
        defer { fixture.base.remove() }
        let interrupted = try services(fixture, checkpoint: { point in
            if point == .afterMove { throw CancellationError() }
        })
        let plan = try await interrupted.removals.prepare(entryID: fixture.entry.id)
        #expect(await interrupted.removals.execute(plan).result.status == .needsRecovery)
        #expect(try await services(fixture).removals.recover().map(\.status) == [.succeeded])
    }

    @Test("目录移动及元数据阶段中断后重开继续恢复", arguments: [
        SkillRemovalCheckpoint.afterMove, .beforeMetadata, .afterMetadata, .afterTrash
    ])
    func recoversInterruptedRemoval(point: SkillRemovalCheckpoint) async throws {
        let fixture = try await AssignmentFixture.make()
        defer { fixture.base.remove() }
        let interrupted = try services(fixture, checkpoint: { current in
            if current == point { throw CocoaError(.fileWriteUnknown) }
        })
        let plan = try await interrupted.removals.prepare(entryID: fixture.entry.id)
        #expect(await interrupted.removals.execute(plan).result.status == .needsRecovery)
        let restarted = try services(fixture)
        #expect(await restarted.removals.recover().map(\.status) == [.succeeded])
        #expect(try await fixture.base.store.snapshot().entries.isEmpty)
        #expect(!SkillFilePrimitives.exists(directory(fixture, plan)))
        #expect(await restarted.removals.recover().isEmpty)
    }

    @Test("SQLite 删除失败整体回滚外键记录，暂存内容供后续恢复")
    func recoversDatabaseFailure() async throws {
        let fixture = try await AssignmentFixture.make()
        defer { fixture.base.remove() }
        let services = try services(fixture)
        let db = try DatabaseQueue(path: fixture.base.store.paths.database.path)
        try await db.write {
            try $0.execute(sql: """
                CREATE TRIGGER reject_removal BEFORE DELETE ON skill_entries
                BEGIN SELECT RAISE(ABORT, 'fixture removal failure'); END;
                """)
        }
        let plan = try await services.removals.prepare(entryID: fixture.entry.id)
        #expect(await services.removals.execute(plan).result.status == .needsRecovery)
        let snapshot = try await fixture.base.store.snapshot()
        #expect(snapshot.entries.count == 1 && snapshot.revisions.count == 1 && snapshot.sources.count == 1)
        #expect(SkillFilePrimitives.exists(directory(fixture, plan).appendingPathComponent("payload")))
        try await db.write { try $0.execute(sql: "DROP TRIGGER reject_removal") }
        #expect(await services.removals.recover().map(\.status) == [.succeeded])
    }

    @Test("废纸篓失败保留暂存，重试不永久删除")
    func recoversTrashFailure() async throws {
        let fixture = try await AssignmentFixture.make()
        defer { fixture.base.remove() }
        let interrupted = try services(fixture, trash: { _ in throw CocoaError(.fileWriteNoPermission) })
        let plan = try await interrupted.removals.prepare(entryID: fixture.entry.id)
        #expect(await interrupted.removals.execute(plan).result.status == .needsRecovery)
        #expect(try await fixture.base.store.snapshot().entries.isEmpty)
        let payload = directory(fixture, plan).appendingPathComponent("payload")
        #expect(try await SkillFilePrimitives.fingerprint(payload).digest == plan.fingerprint.digest)
        #expect(try await services(fixture).removals.recover().map(\.status) == [.succeeded])
    }

    @Test("未知暂存内容或遗失 journal 不自动清理", arguments: [false, true])
    func preservesUnknownRecovery(missingJournal: Bool) async throws {
        let fixture = try await AssignmentFixture.make()
        defer { fixture.base.remove() }
        let interrupted = try services(fixture, checkpoint: { point in
            if point == .afterMove { throw CocoaError(.fileWriteUnknown) }
        })
        let plan = try await interrupted.removals.prepare(entryID: fixture.entry.id)
        #expect(await interrupted.removals.execute(plan).result.status == .needsRecovery)
        let folder = directory(fixture, plan)
        if missingJournal { try FileManager.default.removeItem(at: folder.appendingPathComponent("journal.json")) }
        else { try Data("user".utf8).write(to: folder.appendingPathComponent("payload/user.txt")) }
        #expect(try await services(fixture).removals.recover().map(\.status) == [.needsRecovery])
        #expect(SkillFilePrimitives.exists(folder.appendingPathComponent("payload")))
        #expect(try await fixture.base.store.snapshot().entries.count == 1)
    }

    @Test("Trash 已移动但未能记录结果时保留不确定状态")
    func preservesUncertainTrashOutcome() async throws {
        let fixture = try await AssignmentFixture.make()
        defer { fixture.base.remove() }
        let lostResult = try services(fixture, trash: { payload in
            try SkillFilePrimitives.moveExclusively(payload, to: fixture.base.root.appendingPathComponent("lost-trash-result"))
            throw CocoaError(.fileWriteUnknown)
        })
        let plan = try await lostResult.removals.prepare(entryID: fixture.entry.id)
        #expect(await lostResult.removals.execute(plan).result.status == .needsRecovery)
        #expect(try await services(fixture).removals.recover().map(\.status) == [.needsRecovery])
        #expect(SkillFilePrimitives.exists(directory(fixture, plan).appendingPathComponent("journal.json")))
        #expect(SkillFilePrimitives.exists(fixture.base.root.appendingPathComponent("lost-trash-result/receipt.json")))
    }

    @Test("原位置被外部重新占用时保留两处目录")
    func preservesRecreatedCanonicalDirectory() async throws {
        let fixture = try await AssignmentFixture.make()
        defer { fixture.base.remove() }
        let interrupted = try services(fixture, checkpoint: { point in
            if point == .afterMove { throw CocoaError(.fileWriteUnknown) }
        })
        let plan = try await interrupted.removals.prepare(entryID: fixture.entry.id)
        #expect(await interrupted.removals.execute(plan).result.status == .needsRecovery)
        let original = fixture.base.store.paths.entryDirectory(fixture.entry.id)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try Data("foreign".utf8).write(to: original.appendingPathComponent("foreign.txt"))
        #expect(try await services(fixture).removals.recover().map(\.status) == [.needsRecovery])
        #expect(try String(contentsOf: original.appendingPathComponent("foreign.txt"), encoding: .utf8) == "foreign")
        #expect(SkillFilePrimitives.exists(directory(fixture, plan).appendingPathComponent("payload/receipt.json")))
    }

    @Test("外部条目不能移除，成功移除后旧扫描不能重新落库")
    func rejectsExternalAndOldScan() async throws {
        let fixture = try await AssignmentFixture.make()
        defer { fixture.base.remove() }
        let services = try services(fixture)
        let external = SkillLibraryEntry(manifestName: "outside", summary: "", managementKind: .external)
        try await fixture.base.store.save(external)
        await #expect(throws: SkillOperationError.self) { try await services.removals.prepare(entryID: external.id) }
        let plan = try await services.removals.prepare(entryID: fixture.entry.id)
        let generation = await fixture.base.store.beginScan()
        #expect(await services.removals.execute(plan).result.isSuccess)
        #expect(try await !fixture.base.store.apply(SkillScanReport(generationID: generation, results: [])))
        #expect(try await fixture.base.store.snapshot().entries.map(\.id) == [external.id])
    }

    /// 三种操作协调器必须持有同一个队列，注入的 Trash 仅排他移动到临时根。
    private func services(
        _ fixture: AssignmentFixture,
        trash: SkillRemovalCoordinator.Trash? = nil,
        checkpoint: @escaping @Sendable (SkillRemovalCheckpoint) throws -> Void = { _ in }
    ) throws -> (removals: SkillRemovalCoordinator, assignments: SkillAssignmentCoordinator) {
        let operations = try fixture.base.coordinator()
        let assignments = try SkillAssignmentCoordinator(
            store: fixture.base.store, operations: operations, distributionGate: DistributionGate(channel: .direct),
            home: fixture.home, environment: [:], detectedPresets: [.codex, .claudeCode]
        )
        let sink = fixture.base.root.appendingPathComponent("fixture-trash")
        let move: SkillRemovalCoordinator.Trash = trash ?? { payload in
            try FileManager.default.createDirectory(at: sink, withIntermediateDirectories: true)
            let target = sink.appendingPathComponent(payload.deletingLastPathComponent().lastPathComponent)
            try SkillFilePrimitives.moveExclusively(payload, to: target)
            return target
        }
        return (
            try SkillRemovalCoordinator(
                store: fixture.base.store, operations: operations, assignments: assignments,
                distributionGate: DistributionGate(channel: .direct), trash: move, checkpoint: checkpoint
            ),
            assignments
        )
    }

    private func directory(_ fixture: AssignmentFixture, _ plan: SkillRemovalPlan) -> URL {
        fixture.base.store.paths.removalTransactions.appendingPathComponent(plan.id.uuidString)
    }
}
