//
//  SkillBatchAssignmentTests.swift
//  StarcatTests
//
//  用真实临时分配验证批量范围、部分失败、取消与重试；
//  不依赖 UI 乐观状态，不触碰用户 Home。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Skill 批量分配")
struct SkillBatchAssignmentTests {
    @Test("App Store 在构造批量服务时拒绝")
    func rejectsAppStore() async throws {
        let fixture = try await AssignmentFixture.make()
        defer { fixture.base.remove() }
        let assignments = try fixture.coordinator()
        #expect(throws: DistributionGateError.self) {
            _ = try SkillBatchAssignmentService(assignments: assignments, distributionGate: DistributionGate(channel: .appStore))
        }
    }

    @Test("重复选择和共享物理根只形成一个计划")
    func deduplicatesSelection() async throws {
        let fixture = try await AssignmentFixture.make(shared: true)
        defer { fixture.base.remove() }
        let assignments = try fixture.coordinator()
        let service = try SkillBatchAssignmentService(assignments: assignments, distributionGate: DistributionGate(channel: .direct))
        let target = try #require(try await assignments.targets().first)
        let rows = try await service.prepare(entryIDs: [fixture.entry.id, fixture.entry.id], action: .assign, targetIDs: [target.id])
        #expect(rows.count == 1)
        #expect(rows.first?.target?.configuredPaths.count == 2)
        #expect(try await fixture.base.store.snapshot().assignments.isEmpty)
        #expect(await service.execute(rows).first?.result?.isSuccess == true)
        #expect(try await fixture.base.store.snapshot().assignments.count == 1)
    }

    @Test("外部项和无分配项保留明确失败，不能丢出结果列表")
    func retainsBlockedRows() async throws {
        let fixture = try await AssignmentFixture.make()
        defer { fixture.base.remove() }
        let external = SkillLibraryEntry(manifestName: "outside", summary: "", managementKind: .external)
        try await fixture.base.store.save(external)
        let assignments = try fixture.coordinator()
        let service = try SkillBatchAssignmentService(assignments: assignments, distributionGate: DistributionGate(channel: .direct))
        let target = try #require(try await assignments.targets().first)
        let rows = try await service.prepare(entryIDs: [fixture.entry.id, external.id], action: .assign, targetIDs: [target.id])
        let results = await service.execute(rows)
        #expect(results.count == 2)
        #expect(results.first?.result?.isSuccess == true)
        #expect(results.last?.result?.status == .conflict)
        let absent = try await service.prepare(entryIDs: [external.id], action: .uninstall, targetIDs: [])
        #expect(absent.count == 1)
        #expect(absent.first?.result?.status == .conflict)
    }

    @Test("部分失败仅重新预检失败目标，成功项不再次提交")
    func retriesOnlyFailure() async throws {
        let fixture = try await AssignmentFixture.make()
        defer { fixture.base.remove() }
        let other = try await secondTarget(fixture)
        let assignments = try fixture.coordinator()
        let service = try SkillBatchAssignmentService(assignments: assignments, distributionGate: DistributionGate(channel: .direct))
        let targets = try await assignments.targets()
        let rows = try await service.prepare(
            entryIDs: [fixture.entry.id], action: .assign, targetIDs: Set(targets.map(\.id))
        )
        let occupied = other.appendingPathComponent("sample")
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        let completed = await service.execute(rows)
        #expect(completed.filter { $0.result?.isSuccess == true }.count == 1)
        #expect(completed.filter { $0.result?.canRetry == true }.count == 1)
        let success = try #require(completed.first { $0.result?.isSuccess == true })
        try FileManager.default.removeItem(at: occupied)
        let retry = try await service.retryPreview(completed)
        #expect(retry.filter(\.isReady).count == 1)
        #expect(retry.first { $0.id == success.id }?.result?.id == success.result?.id)
        let finished = await service.execute(retry)
        #expect(finished.allSatisfy { $0.result?.isSuccess == true })
        #expect(try await fixture.base.store.snapshot().assignments.count == 2)
    }

    @Test("取消保留当前项成功，其余项目明确 cancelled")
    func cancelsRemaining() async throws {
        let fixture = try await AssignmentFixture.make()
        defer { fixture.base.remove() }
        _ = try await secondTarget(fixture)
        let assignments = try fixture.coordinator()
        let service = try SkillBatchAssignmentService(assignments: assignments, distributionGate: DistributionGate(channel: .direct))
        let rows = try await service.prepare(
            entryIDs: [fixture.entry.id], action: .assign, targetIDs: Set(try await assignments.targets().map(\.id))
        )
        let task = Task {
            await service.execute(rows) { event in
                if case .finished = event { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        let completed = await task.value
        #expect(completed.first?.result?.isSuccess == true)
        #expect(completed.last?.result?.status == .cancelled)
        #expect(try await fixture.base.store.snapshot().assignments.count == 1)
    }

    @Test("提交后故障保留 needsRecovery，不能进入普通失败重试")
    func excludesRecoveryFromRetry() async throws {
        let fixture = try await AssignmentFixture.make()
        defer { fixture.base.remove() }
        let assignments = try fixture.coordinator { if $0 == .afterLink { throw CocoaError(.fileWriteUnknown) } }
        let service = try SkillBatchAssignmentService(assignments: assignments, distributionGate: DistributionGate(channel: .direct))
        let rows = try await service.prepare(
            entryIDs: [fixture.entry.id], action: .assign, targetIDs: Set(try await assignments.targets().map(\.id))
        )
        let completed = await service.execute(rows)
        #expect(completed.first?.result?.status == .needsRecovery)
        #expect(try await service.retryPreview(completed).first?.isReady == false)
        #expect(SkillFilePrimitives.isSymbolicLink(fixture.target))
    }

    /// 第二个独立物理根与共享别名分别测试，避免把两种去重语义混在一起。
    private func secondTarget(_ fixture: AssignmentFixture) async throws -> URL {
        let root = fixture.home.appendingPathComponent(".claude/skills")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await fixture.base.store.save(SkillLibraryRoot(configuredPath: root.path, agentIDs: ["claudeCode"], scope: .global))
        return root
    }
}
