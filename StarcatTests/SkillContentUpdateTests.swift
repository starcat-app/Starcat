//
//  SkillContentUpdateTests.swift
//  StarcatTests
//
//  用真实目录和 SQLite 验证三方保护、显式备份、回退及有界保留，
//  不以按钮状态或模拟成功代替文件证据。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Skill 安全更新与回退")
struct SkillContentUpdateTests {
    @Test("无变化仍复核当前内容，不接受过期的相同预览")
    func validatesUnchangedPreview() async throws {
        let fixture = try await ContentUpdateFixture.make()
        defer { fixture.base.remove() }
        let unchanged = try await fixture.service.prepare(entryID: fixture.entryID)
        #expect(unchanged.isUnchanged)
        #expect(await fixture.service.execute(unchanged).status == .alreadySatisfied)
        let stale = try await fixture.service.prepare(entryID: fixture.entryID)
        try Data("changed".utf8).write(to: fixture.content.appendingPathComponent("SKILL.md"))
        #expect(await fixture.service.execute(stale).status == .conflict)
    }

    @Test("本地来源比较列出差异，确认后更新并可回退")
    func updatesAndRollsBack() async throws {
        let fixture = try await ContentUpdateFixture.make()
        defer { fixture.base.remove() }
        let link = fixture.base.root.appendingPathComponent("assigned-sample")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.content)
        try await fixture.changeSource("remote")
        let update = try await fixture.service.prepare(entryID: fixture.entryID)
        #expect(!update.hasLocalChanges)
        #expect(update.remoteDifferences.contains { $0.path == "SKILL.md" && $0.kind == .modified })
        #expect(await fixture.service.execute(update).status == .succeeded)
        #expect(try fixture.text().contains("remote"))
        #expect(try String(contentsOf: link.appendingPathComponent("SKILL.md"), encoding: .utf8).contains("remote"))
        let rollback = try await fixture.service.prepareRollback(entryID: fixture.entryID)
        #expect(await fixture.service.execute(rollback).status == .succeeded)
        #expect(try fixture.text().contains("original"))
        #expect(try String(contentsOf: link.appendingPathComponent("SKILL.md"), encoding: .utf8).contains("original"))
        #expect(try await fixture.base.store.snapshot().revisions.count == 2)
    }

    @Test("本地修改默认阻断；明确批准后备份修改并可恢复原文")
    func protectsLocalChanges() async throws {
        let fixture = try await ContentUpdateFixture.make()
        defer { fixture.base.remove() }
        try await fixture.changeSource("remote")
        try Data("---\nname: sample\ndescription: Sample\n---\nlocal edits\n".utf8)
            .write(to: fixture.content.appendingPathComponent("SKILL.md"))
        let update = try await fixture.service.prepare(entryID: fixture.entryID)
        #expect(update.hasLocalChanges)
        #expect(update.localManifest.contains("local edits"))
        #expect(await fixture.service.execute(update).status == .conflict)
        #expect(try fixture.text().contains("local edits"))
        #expect(await fixture.service.execute(update, replacingLocalChanges: true).status == .succeeded)
        let rollback = try await fixture.service.prepareRollback(entryID: fixture.entryID)
        #expect(rollback.remoteManifest.contains("local edits"))
        #expect(await fixture.service.execute(rollback).status == .succeeded)
        #expect(try fixture.text().contains("local edits"))
    }

    @Test("预览后再次编辑，即使批准覆盖也拒绝旧计划")
    func rejectsEditedPreview() async throws {
        let fixture = try await ContentUpdateFixture.make()
        defer { fixture.base.remove() }
        try await fixture.changeSource("remote")
        let update = try await fixture.service.prepare(entryID: fixture.entryID)
        try Data("later edits".utf8).write(to: fixture.content.appendingPathComponent("SKILL.md"))
        #expect(await fixture.service.execute(update, replacingLocalChanges: true).status == .conflict)
        #expect(try fixture.text() == "later edits")
    }

    @Test("连续更新只保留一个可验证上一版本，回退指向最近版本")
    func boundsBackups() async throws {
        let fixture = try await ContentUpdateFixture.make()
        defer { fixture.base.remove() }
        for index in 1...3 {
            try await fixture.changeSource("version \(index)")
            #expect(await fixture.service.execute(try await fixture.service.prepare(entryID: fixture.entryID)).isSuccess)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.content.deletingLastPathComponent().path)
        #expect(names.filter { $0.hasPrefix(".starcat-backup-") }.count == 1)
        let rollback = try await fixture.service.prepareRollback(entryID: fixture.entryID)
        #expect(rollback.remoteManifest.contains("version 2"))
        #expect(await fixture.service.execute(rollback).isSuccess)
        #expect(try fixture.text().contains("version 2"))
    }

    @Test("被外部改动的上一版本不能回退覆盖")
    func rejectsChangedBackup() async throws {
        let fixture = try await ContentUpdateFixture.make()
        defer { fixture.base.remove() }
        try await fixture.changeSource("remote")
        #expect(await fixture.service.execute(try await fixture.service.prepare(entryID: fixture.entryID)).isSuccess)
        let parent = fixture.content.deletingLastPathComponent()
        let name = try #require(try FileManager.default.contentsOfDirectory(atPath: parent.path).first { $0.hasPrefix(".starcat-backup-") })
        try Data("foreign".utf8).write(to: parent.appendingPathComponent(name).appendingPathComponent("SKILL.md"))
        await #expect(throws: SkillOperationError.ownership) { try await fixture.service.prepareRollback(entryID: fixture.entryID) }
        #expect(try fixture.text().contains("remote"))
    }

    @Test("保存本地副本不更新原条目")
    func preservesCopy() async throws {
        let fixture = try await ContentUpdateFixture.make()
        defer { fixture.base.remove() }
        try await fixture.changeSource("remote")
        let preview = try await fixture.service.prepare(entryID: fixture.entryID)
        #expect(await fixture.service.saveLocalCopy(preview).isSuccess)
        #expect(try await fixture.base.store.snapshot().entries.count == 2)
        #expect(try fixture.text().contains("original"))
    }

    @Test("更新发布后元数据故障可恢复，并建立回退基线")
    func recoversUpdate() async throws {
        let fixture = try await ContentUpdateFixture.make(fault: true)
        defer { fixture.base.remove() }
        try await fixture.changeSource("remote")
        #expect(await fixture.service.execute(try await fixture.service.prepare(entryID: fixture.entryID)).status == .needsRecovery)
        #expect(try await fixture.base.coordinator().recover().map(\.status) == [.succeeded])
        let rollback = try await fixture.base.coordinator().prepareRollback(entryID: fixture.entryID)
        #expect(rollback.previousEntry?.id == fixture.entryID)
    }

    @Test("差异包含新增、删除、类型及权限变化")
    func comparesFileEvidence() async throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        let plan = try await fixture.plan()
        let old = plan.fingerprint
        try FileManager.default.removeItem(at: fixture.incoming.appendingPathComponent("assets/data.txt"))
        try Data("new".utf8).write(to: fixture.incoming.appendingPathComponent("new.txt"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.incoming.appendingPathComponent("SKILL.md").path)
        let changed = try await SkillFilePrimitives.fingerprint(fixture.incoming)
        let diff = SkillContentUpdateService.differences(old, changed)
        #expect(diff.contains { $0.path == "assets/data.txt" && $0.kind == .removed })
        #expect(diff.contains { $0.path == "new.txt" && $0.kind == .added })
        #expect(diff.contains { $0.path == "SKILL.md" && $0.kind == .permissions })
    }
}

/// 更新来源与受管副本始终位于不同目录，确保测试能发现意外双向写入。
struct ContentUpdateFixture {
    let base: SkillOperationFixture
    let entryID: UUID
    let service: SkillContentUpdateService
    var content: URL { base.store.paths.entryDirectory(entryID).appendingPathComponent("content/sample") }

    static func make(fault: Bool = false) async throws -> Self {
        let base = try SkillOperationFixture()
        do {
            let plan = try await base.plan()
            #expect(try await base.coordinator().execute(plan).isSuccess)
            let operations = try base.coordinator { if fault && $0 == .afterContentCommit { throw CocoaError(.fileWriteUnknown) } }
            let imports = try SkillImportService(
                store: base.store, operations: operations, distributionGate: DistributionGate(channel: .direct),
                tokenProvider: ImportTestToken()
            )
            let service = try SkillContentUpdateService(
                store: base.store, imports: imports, operations: operations, distributionGate: DistributionGate(channel: .direct)
            )
            return Self(base: base, entryID: plan.entry.id, service: service)
        } catch { base.remove(); throw error }
    }

    func changeSource(_ text: String) async throws { _ = try await base.plan(text: text) }
    func text() throws -> String { try String(contentsOf: content.appendingPathComponent("SKILL.md"), encoding: .utf8) }
}
