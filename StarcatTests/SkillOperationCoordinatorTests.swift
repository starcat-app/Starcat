//
//  SkillOperationCoordinatorTests.swift
//  StarcatTests
//
//  使用临时本机库验证事务边界、SQLite 原子写入与中断现场恢复，
//  不读取或修改用户的实际 Agent 根。
//

import Foundation
import GRDB
import Testing
@testable import Starcat

@Suite("Skill 管理操作与恢复")
struct SkillOperationCoordinatorTests {
    @Test("App Store 内部入口在磁盘副作用前拒绝")
    func rejectsAppStore() throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        #expect(throws: DistributionGateError.self) {
            _ = try SkillOperationCoordinator(
                store: fixture.store, distributionGate: DistributionGate(channel: .appStore)
            )
        }
        #expect(!SkillFilePrimitives.exists(fixture.store.paths.database))
    }

    @Test("导入完整目录，回执持有逐文件基线且相同计划幂等")
    func importsAndReplays() async throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        let plan = try await fixture.plan()
        let coordinator = try fixture.coordinator()
        #expect(await coordinator.execute(plan).status == .succeeded)
        #expect(try await SkillFilePrimitives.fingerprint(fixture.destination(plan)) == plan.fingerprint)
        #expect(try await fixture.store.receipt(for: plan.entry.id)?.fingerprint == plan.fingerprint)
        #expect(try await fixture.store.snapshot().entries.count == 1)
        #expect(await coordinator.execute(plan).status == .succeeded)
        #expect(try await fixture.store.operations().count == 1)
        #expect(SkillFilePrimitives.exists(fixture.incoming.appendingPathComponent("assets/empty")))
    }

    @Test("来源变化拒绝旧预览，不创建受管内容")
    func rejectsChangedSource() async throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        let plan = try await fixture.plan()
        try Data("changed".utf8).write(to: fixture.incoming.appendingPathComponent("assets/data.txt"))
        #expect(try await fixture.coordinator().execute(plan).status == .conflict)
        #expect(!SkillFilePrimitives.exists(fixture.destination(plan)))
    }

    @Test("取消发生在发布之前，清理自有 stage，保留原始文件")
    func cancelsBeforePublishing() async throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        let plan = try await fixture.plan()
        let coordinator = try fixture.coordinator { point in
            if point == .afterStage { throw CancellationError() }
        }
        #expect(await coordinator.execute(plan).status == .cancelled)
        #expect(!SkillFilePrimitives.exists(fixture.destination(plan)))
        #expect(!SkillFilePrimitives.exists(fixture.staging(plan).stage))
        #expect(try await fixture.store.snapshot().entries.isEmpty)
        #expect(SkillFilePrimitives.exists(fixture.incoming.appendingPathComponent("SKILL.md")))
    }

    @Test("阶段失败后重开可按现场补齐回执与元数据", arguments: [
        SkillOperationCheckpoint.afterContentCommit, .beforeReceipt, .beforeMetadata, .afterMetadata
    ])
    func recoversAfterPublish(point: SkillOperationCheckpoint) async throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        let plan = try await fixture.plan()
        let coordinator = try fixture.coordinator { current in
            if current == point { throw CocoaError(.fileWriteUnknown) }
        }
        #expect(await coordinator.execute(plan).status == .needsRecovery)
        #expect(SkillFilePrimitives.exists(fixture.destination(plan)))
        let restarted = try fixture.coordinator()
        #expect(await restarted.recover().map(\.status) == [.succeeded])
        #expect(try await fixture.store.snapshot().entries.first?.currentRevisionID == plan.revision.id)
        #expect(try await fixture.store.receipt(for: plan.entry.id) == plan.receipt)
        #expect(await restarted.recover().isEmpty)
    }

    @Test("SQLite 元数据失败整体回滚，保留文件 journal 直到可恢复")
    func rollsBackMetadataTransaction() async throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        _ = try await fixture.store.snapshot()
        let db = try DatabaseQueue(path: fixture.store.paths.database.path)
        try await db.write {
            try $0.execute(sql: """
                CREATE TRIGGER reject_revision BEFORE INSERT ON skill_revisions
                BEGIN SELECT RAISE(ABORT, 'fixture revision failure'); END;
                """)
        }
        let plan = try await fixture.plan()
        #expect(try await fixture.coordinator().execute(plan).status == .needsRecovery)
        let failed = try await fixture.store.snapshot()
        #expect(failed.entries.isEmpty && failed.sources.isEmpty && failed.revisions.isEmpty)
        try await db.write { try $0.execute(sql: "DROP TRIGGER reject_revision") }
        #expect(try await fixture.coordinator().recover().map(\.status) == [.succeeded])
        #expect(try await fixture.store.snapshot().entries.count == 1)
    }

    @Test("扫描中断后的新内容保留批准身份，恢复后不会多出外部幽灵条目")
    func reconcilesPendingIdentity() async throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        let plan = try await fixture.plan()
        let coordinator = try fixture.coordinator { point in
            if point == .beforeMetadata { throw CocoaError(.fileWriteUnknown) }
        }
        #expect(await coordinator.execute(plan).status == .needsRecovery)
        let root = SkillLibraryRoot(
            configuredPath: fixture.store.paths.managed.path, agentIDs: [], scope: .managed
        )
        let generation = await fixture.store.beginScan()
        let scanner = try LocalSkillScanner(distributionGate: DistributionGate(channel: .direct))
        let report = await scanner.scan(SkillScanRequest(generationID: generation, roots: [root]))
        #expect(try await fixture.store.apply(report))
        #expect(try await fixture.store.snapshot().entries.map(\.id) == [plan.entry.id])
        #expect(try await fixture.store.snapshot().entries.first?.managementKind == .external)
        #expect(try await fixture.coordinator().recover().map(\.status) == [.succeeded])
        #expect(try await fixture.store.snapshot().entries.map(\.id) == [plan.entry.id])
        #expect(try await fixture.store.snapshot().entries.first?.managementKind == .managed)
    }

    @Test("恢复遇到用户修改时保留内容与 journal")
    func preservesUnknownContent() async throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        let plan = try await fixture.plan()
        let coordinator = try fixture.coordinator { point in
            if point == .afterContentCommit { throw CocoaError(.fileWriteUnknown) }
        }
        #expect(await coordinator.execute(plan).status == .needsRecovery)
        let changed = fixture.destination(plan).appendingPathComponent("user.txt")
        try Data("user".utf8).write(to: changed)
        #expect(try await fixture.coordinator().recover().map(\.status) == [.needsRecovery])
        #expect(try String(contentsOf: changed, encoding: .utf8) == "user")
        #expect(SkillFilePrimitives.exists(fixture.journal(plan)))
    }

    @Test("预览后目标被其他内容占用时不覆盖或删除")
    func preservesChangedDestination() async throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        let plan = try await fixture.plan()
        let destination = fixture.destination(plan)
        let coordinator = try fixture.coordinator { point in
            if point == .afterStage {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try Data("foreign".utf8).write(to: destination.appendingPathComponent("foreign.txt"))
            }
        }
        #expect(await coordinator.execute(plan).status == .conflict)
        #expect(try String(contentsOf: destination.appendingPathComponent("foreign.txt"), encoding: .utf8) == "foreign")
        #expect(!SkillFilePrimitives.exists(fixture.staging(plan).stage))
    }

    @Test("恢复不覆盖外来回执")
    func preservesForeignReceipt() async throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        let plan = try await fixture.plan()
        let coordinator = try fixture.coordinator { point in
            if point == .beforeReceipt { throw CocoaError(.fileWriteUnknown) }
        }
        #expect(await coordinator.execute(plan).status == .needsRecovery)
        let file = fixture.store.paths.entryDirectory(plan.entry.id).appendingPathComponent("receipt.json")
        let foreign = SkillLibraryReceipt(
            entryID: UUID(), revisionID: plan.revision.id, contentDigest: plan.fingerprint.digest,
            installedAt: plan.createdAt, fingerprint: plan.fingerprint
        )
        let data = try JSONEncoder().encode(foreign)
        try data.write(to: file)
        #expect(try await fixture.coordinator().recover().map(\.status) == [.needsRecovery])
        #expect(try Data(contentsOf: file) == data)
    }

    @Test("更新只接受仍与旧回执一致的完整目录")
    func protectsLocalChanges() async throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        let first = try await fixture.plan()
        #expect(try await fixture.coordinator().execute(first).status == .succeeded)
        let entry = try #require(try await fixture.store.snapshot().entries.first)
        let update = try await fixture.plan(text: "new", previous: entry)
        let local = fixture.destination(first).appendingPathComponent("local.txt")
        try Data("local".utf8).write(to: local)
        #expect(try await fixture.coordinator().execute(update).status == .conflict)
        #expect(try await fixture.store.receipt(for: entry.id) == first.receipt)
        #expect(SkillFilePrimitives.exists(local))
    }

    @Test("更新保留旧版本目录供回退")
    func retainsUpdateBackup() async throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        let first = try await fixture.plan()
        #expect(try await fixture.coordinator().execute(first).status == .succeeded)
        let entry = try #require(try await fixture.store.snapshot().entries.first)
        let update = try await fixture.plan(text: "new", previous: entry)
        #expect(try await fixture.coordinator().execute(update).status == .succeeded)
        #expect(try await SkillFilePrimitives.fingerprint(fixture.staging(update).backup) == first.fingerprint)
        #expect(try await fixture.store.snapshot().revisions.count == 2)
    }

    @Test("两次 rename 之间的中断恢复旧内容，丢弃尚未发布的新暂存")
    func restoresBackupBetweenRenames() async throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        let first = try await fixture.plan()
        #expect(try await fixture.coordinator().execute(first).status == .succeeded)
        let entry = try #require(try await fixture.store.snapshot().entries.first)
        let update = try await fixture.plan(text: "new", previous: entry)
        let paths = fixture.staging(update)
        try await SkillFilePrimitives.stageCopy(from: fixture.incoming, expected: update.fingerprint, paths: paths)
        try FileManager.default.moveItem(at: fixture.destination(first), to: paths.backup)
        try fixture.writeJournal(.init(plan: update, phase: .committing))
        #expect(try await fixture.coordinator().recover().map(\.status) == [.cancelled])
        #expect(try await SkillFilePrimitives.fingerprint(fixture.destination(first)) == first.fingerprint)
        #expect(try await fixture.store.receipt(for: entry.id) == first.receipt)
        #expect(!SkillFilePrimitives.exists(paths.stage))
    }

    @Test("同来源复用身份且多个并发请求不会互相恢复尚未提交的 journal")
    func serializesOperations() async throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        let first = try await fixture.plan()
        let second = try await fixture.plan()
        let coordinator = try fixture.coordinator()
        async let firstResult = coordinator.execute(first)
        async let secondResult = coordinator.execute(second)
        let statuses = await [firstResult.status, secondResult.status]
        #expect(statuses.allSatisfy { $0 == .succeeded })
        #expect(try await fixture.store.snapshot().entries.count == 2)
        #expect(try await fixture.store.snapshot().sources.count == 1)
        #expect(await coordinator.recover().isEmpty)
    }

    @Test("损坏 journal 保留现场并报告，不能当空库成功")
    func preservesInvalidJournal() async throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        let folder = fixture.store.paths.transactions.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("journal.json")
        try Data("invalid".utf8).write(to: file)
        #expect(try await fixture.coordinator().recover().map(\.status) == [.needsRecovery])
        #expect(SkillFilePrimitives.exists(file))
    }
}

/// 后续导入／更新回归共用的真实磁盘 fixture；每个实例拥有独立 UUID 根。
struct SkillOperationFixture {
    let root: URL
    let store: SkillLibraryStore
    let incoming: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SkillOperation-\(UUID().uuidString)")
        store = try SkillLibraryStore(
            distributionGate: DistributionGate(channel: .direct),
            paths: SkillLibraryPaths(root: root.appendingPathComponent("library"))
        )
        incoming = root.appendingPathComponent("incoming/sample")
        try FileManager.default.createDirectory(at: incoming.appendingPathComponent("assets/empty"), withIntermediateDirectories: true)
        try Data("asset".utf8).write(to: incoming.appendingPathComponent("assets/data.txt"))
    }

    func plan(text: String = "original", previous: SkillLibraryEntry? = nil) async throws -> SkillContentOperationPlan {
        try Data("---\nname: sample\ndescription: Sample\n---\n\(text)\n".utf8)
            .write(to: incoming.appendingPathComponent("SKILL.md"))
        let snapshot = try await store.snapshot()
        let source = snapshot.sources.first
            ?? SkillLibrarySource(kind: .local, canonicalLocator: incoming.resolvingSymlinksInPath().path, subdirectory: "")
        var entry = previous ?? SkillLibraryEntry(
            sourceID: source.id, manifestName: "sample", summary: "Sample", managementKind: .managed
        )
        entry.updatedAt = Date().timeIntervalSince1970
        let fingerprint = try await SkillFilePrimitives.fingerprint(incoming)
        let manifestDigest = try #require(fingerprint.members.first { $0.path == "SKILL.md" }?.digest)
        let revision = snapshot.revisions.first { $0.entryID == entry.id && $0.contentDigest == fingerprint.digest }
            ?? SkillLibraryRevision(
                entryID: entry.id, contentDigest: fingerprint.digest,
                manifestDigest: manifestDigest,
                upstreamCommit: nil
            )
        let previousReceipt: SkillLibraryReceipt?
        if let previous { previousReceipt = try await store.receipt(for: previous.id) }
        else { previousReceipt = nil }
        return SkillContentOperationPlan(
            source: source, entry: entry, revision: revision, incomingDirectory: incoming.path,
            fingerprint: fingerprint, previousEntry: previous,
            previousReceipt: previousReceipt
        )
    }

    func coordinator(
        checkpoint: @escaping @Sendable (SkillOperationCheckpoint) throws -> Void = { _ in }
    ) throws -> SkillOperationCoordinator {
        try SkillOperationCoordinator(
            store: store, distributionGate: DistributionGate(channel: .direct), checkpoint: checkpoint
        )
    }

    func destination(_ plan: SkillContentOperationPlan) -> URL {
        store.paths.entryDirectory(plan.entry.id).appendingPathComponent("content/sample")
    }

    func staging(_ plan: SkillContentOperationPlan) -> SkillStagingPaths {
        SkillStagingPaths(parent: destination(plan).deletingLastPathComponent(), operationID: plan.id)
    }

    func journal(_ plan: SkillContentOperationPlan) -> URL {
        store.paths.transactions.appendingPathComponent(plan.id.uuidString).appendingPathComponent("journal.json")
    }

    func writeJournal(_ journal: SkillContentJournal) throws {
        let url = self.journal(journal.plan)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(journal).write(to: url)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
