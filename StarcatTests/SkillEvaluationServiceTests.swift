//
//  SkillEvaluationServiceTests.swift
//  StarcatTests
//
//  通过真实共享任务、快照与磁盘缓存验证评估生命周期。外部命令和数据只使用本地 fixture。
//

import Foundation
import MCP
import Testing
@testable import Starcat

@MainActor
@Suite("Skill 评估共享任务")
struct SkillEvaluationServiceTests {
    @Test("批量进行中可回接同一任务；取消后公共任务与缓存保留已完成项")
    func batchCancellationAndReattachment() async throws {
        try await withFixture { fixture in
            let first = try await fixture.addSkill("notes", id: firstID)
            let second = try await fixture.addSkill("planning", id: secondID)
            fixture.pause.subject = second.target.identity
            let service = fixture.service
            let targets = [second.target, first.target]

            let id = try service.start(targets: targets, mode: .quick, model: nil, consent: false)
            try await waitUntil { fixture.pause.entered }
            #expect(try service.taskState(id: id) == "running")
            #expect(try fixture.tasks.status(id: id).objectValue?["state"]?.stringValue == "running")
            #expect(throws: StarcatPublicCapabilityError.self) { try fixture.tasks.result(id: id) }

            // 面板监听停止时只取消观察。重开的调用按同一选择回接，顺序变化不生成新任务。
            var observedState: String?
            let observation = Task {
                observedState = try service.taskState(id: id)
                try await waitUntil { try service.taskState(id: id) != "running" }
            }
            defer { observation.cancel() }
            try await waitUntil { observedState == "running" }
            observation.cancel()
            await #expect(throws: CancellationError.self) { try await observation.value }
            #expect(service.activeTask(targets: Array(targets.reversed()), mode: .quick) == id)
            #expect(service.matchesTask(id: id, within: targets, mode: .quick))
            #expect(service.activeTask(targets: [second.target], mode: .quick) == nil)
            expectFailure("busy") {
                try service.start(targets: [second.target], mode: .quick, model: nil, consent: false)
            }

            try service.cancel(id: id)
            #expect(try service.taskState(id: id) == "cancelling")
            expectFailure("busy") {
                try service.start(targets: [first.target], mode: .quick, model: nil, consent: false)
            }
            fixture.pause.release()
            try await waitForState("cancelled", id: id, service: service)
            #expect(service.activeTask(targets: targets, mode: .quick) == nil)
            #expect(service.latestTask(targets: targets, mode: .quick) == id)
            #expect(service.matchesTask(id: id, within: targets, mode: .quick))
            #expect(try service.taskFailures(id: id).isEmpty)

            let reports = try await service.latest(targets: targets, mode: .quick)
            let report = try #require(reports.first)
            #expect(reports.count == 1)
            #expect(report.report.subjects == [first.target.identity])
            #expect(report.report.state == .passed)
            #expect(!report.stale)
            let result = try fixture.tasks.result(id: id).objectValue?["result"]?.objectValue
            #expect(result?["report_ids"]?.arrayValue?.compactMap(\.stringValue) == [report.report.id.uuidString])
            #expect(result?["failures"]?.arrayValue?.isEmpty == true)
        }
    }

    @Test("仓库同目录的新 commit 不接回旧任务，运行中的单项与重叠批次互斥")
    func repositoryCommitAndOverlap() async throws {
        try await withFixture { fixture in
            let database = try InMemoryDatabaseManager()
            try await database.insertRepoFixture(id: 1, name: "notes-fixture")
            let repo = try #require(try await GRDBRepoRepository(database: database).findById(1))
            let old = fixture.repositoryTarget(repo, commit: String(repeating: "a", count: 40))
            let updated = fixture.repositoryTarget(repo, commit: String(repeating: "b", count: 40))
            let other = try await fixture.addSkill("planning", id: secondID)
            fixture.pause.subject = old.identity
            let service = fixture.service

            let first = try service.start(targets: [old], mode: .quick, model: nil, consent: false)
            try await waitUntil { fixture.pause.entered }
            #expect(service.activeTask(targets: [old], mode: .quick) == first)
            #expect(service.activeTask(targets: [updated], mode: .quick) == nil)
            #expect(!service.matchesTask(id: first, within: [updated, other.target], mode: .quick))
            #expect(service.matchesTask(id: first, within: [old, other.target], mode: .quick))
            expectFailure("busy") {
                try service.start(targets: [old, other.target], mode: .quick, model: nil, consent: false)
            }
            expectFailure("busy") {
                try service.start(targets: [updated, other.target], mode: .security, model: nil, consent: false)
            }
            // 与单项无重叠的目标仍可独立运行。
            let disjoint = try service.start(targets: [other.target], mode: .quick, model: nil, consent: false)
            try await waitForState("succeeded", id: disjoint, service: service)

            fixture.pause.release()
            try await waitForState("succeeded", id: first, service: service)
            #expect(service.latestTask(targets: [old], mode: .quick) == first)
            #expect(service.latestTask(targets: [updated], mode: .quick) == nil)
            let stale = try #require(try await service.latest(targets: [updated], mode: .quick).first)
            #expect(stale.stale)
            #expect(stale.report.versions == [String(repeating: "a", count: 40)])

            let next = try service.start(targets: [updated], mode: .quick, model: nil, consent: false)
            #expect(next != first)
            try await waitForState("succeeded", id: next, service: service)
            let current = try #require(try await service.latest(targets: [updated], mode: .quick).first)
            #expect(!current.stale)
            #expect(current.report.versions == [String(repeating: "b", count: 40)])
            #expect(current.report.id != stale.report.id)
        }
    }

    @Test("切账号等待旧任务退出，隔离缓存与句柄，新账号可重跑相同条目")
    func accountSwitchAndRerun() async throws {
        try await withFixture { fixture in
            let first = try await fixture.addSkill("notes", id: firstID)
            let second = try await fixture.addSkill("planning", id: secondID)
            let service = fixture.service
            let targets = [first.target, second.target]
            fixture.pause.subject = second.target.identity
            let old = try service.start(targets: targets, mode: .quick, model: nil, consent: false)
            try await waitUntil { fixture.pause.entered }
            let previous = try #require(try await service.latest(targets: targets, mode: .quick).first)

            service.beginAccountChange()
            #expect(service.activeTask(targets: targets, mode: .quick) == nil)
            #expect(throws: CancellationError.self) {
                try service.start(targets: targets, mode: .quick, model: nil, consent: false)
            }
            await #expect(throws: CancellationError.self) {
                try await service.latest(targets: targets, mode: .quick)
            }
            let drain = Task { await fixture.tasks.cancelAllAndWait() }
            // 等任务存储关闭请求入口，说明正在等待尚未释放的执行器。
            try await waitUntil {
                do {
                    try fixture.tasks.beginRequest()
                    fixture.tasks.endRequest()
                    return false
                } catch let error as StarcatPublicCapabilityError {
                    return error.code == "SESSION_CHANGING"
                }
            }
            #expect(try fixture.tasks.status(id: old).objectValue?["finished_at"]?.stringValue == nil)
            fixture.pause.release()
            await drain.value

            fixture.account = "account-b"
            service.finishAccountChange(succeeded: true)
            #expect(throws: StarcatPublicCapabilityError.self) { try service.taskState(id: old) }
            #expect(throws: StarcatPublicCapabilityError.self) { try fixture.tasks.result(id: old) }
            #expect(service.latestTask(targets: targets, mode: .quick) == nil)
            #expect(try await service.latest(targets: targets, mode: .quick).isEmpty)

            let next = try service.start(targets: targets, mode: .quick, model: nil, consent: false)
            #expect(next != old)
            try await waitForState("succeeded", id: next, service: service)
            let current = try await service.latest(targets: targets, mode: .quick)
            #expect(current.count == 2)
            #expect(current.allSatisfy { !$0.stale && $0.report.id != previous.report.id })

            service.beginAccountChange()
            await fixture.tasks.cancelAllAndWait()
            fixture.account = "account-a"
            service.finishAccountChange(succeeded: true)
            #expect(try await service.latest(targets: targets, mode: .quick) == [previous])
        }
    }

    @Test("本机同大小文件改变后标记过期，损坏的缓存可以由成功重跑替换")
    func fileChangeAndCorruptCache() async throws {
        try await withFixture { fixture in
            let skill = try await fixture.addSkill("notes", id: firstID)
            let service = fixture.service
            let targets = [skill.target]
            let first = try service.start(targets: targets, mode: .quick, model: nil, consent: false)
            try await waitForState("succeeded", id: first, service: service)
            let original = try #require(try await service.latest(targets: targets, mode: .quick).first)
            #expect(!original.stale)

            let updated = Data("# Meeting memo\n".utf8)
            #expect(updated.count == EvaluationServiceBlob.manifest.count)
            try updated.write(to: skill.manifest)
            let stale = try #require(try await service.latest(targets: targets, mode: .quick).first)
            #expect(stale.stale)
            #expect(stale.report.id == original.report.id)

            let files = try FileManager.default.contentsOfDirectory(at: fixture.cacheRoot, includingPropertiesForKeys: nil)
            let cacheFile = try #require(files.first)
            #expect(files.count == 1)
            try Data("{ truncated".utf8).write(to: cacheFile)
            #expect(try await service.latest(targets: targets, mode: .quick).isEmpty)

            let next = try service.start(targets: targets, mode: .quick, model: nil, consent: false)
            try await waitForState("succeeded", id: next, service: service)
            let report = try #require(try await service.latest(targets: targets, mode: .quick).first)
            #expect(!report.stale)
            #expect(report.report.id != original.report.id)
            #expect(report.report.versions != original.report.versions)
        }
    }

    @Test("AI 校验同意、模型与端点，执行前复核配置，只有合法运行读取凭据")
    func aiConsentAndModelValidation() async throws {
        try await withFixture { fixture in
            let skill = try await fixture.addSkill("notes", id: firstID)
            let service = fixture.service
            let targets = [skill.target]
            let selection = fixture.selection

            expectFailure("model") {
                try service.start(targets: targets, mode: .rubric, model: selection, consent: false)
            }
            expectFailure("model") {
                try service.start(targets: targets, mode: .rubric, model: nil, consent: true)
            }
            expectFailure("model") {
                try service.start(targets: targets, mode: .quick, model: selection, consent: true)
            }
            let wrongEndpoint = SkillEvaluationSelection(
                providerID: selection.providerID, endpoint: "https://other.invalid/v1", chat: selection.chat, embedding: nil
            )
            expectFailure("model") {
                try service.start(targets: targets, mode: .rubric, model: wrongEndpoint, consent: true)
            }
            let wrongModel = SkillEvaluationSelection(
                providerID: selection.providerID, endpoint: selection.endpoint, chat: "disabled-model", embedding: nil
            )
            expectFailure("model") {
                try service.start(targets: targets, mode: .rubric, model: wrongModel, consent: true)
            }
            #expect(!fixture.tasks.hasActive(kind: "skill_evaluation"))
            #expect(fixture.keyReads.isEmpty)
            #expect(service.latestTask(targets: targets, mode: .rubric) == nil)

            fixture.pause.subject = skill.target.identity
            let revoked = try service.start(targets: targets, mode: .rubric, model: selection, consent: true)
            try await waitUntil { fixture.pause.entered }
            fixture.profile.baseURL = wrongEndpoint.endpoint
            fixture.pause.release()
            try await waitForState("failed", id: revoked, service: service)
            #expect(fixture.keyReads.isEmpty)
            #expect(service.latestTask(targets: targets, mode: .rubric) == revoked)
            let failures = try service.taskFailures(id: revoked)
            #expect(failures.count == 1)
            #expect(failures.first?.hasPrefix(skill.target.identity.sortKey) == true)
            #expect(try await service.latest(targets: targets, mode: .rubric).isEmpty)

            fixture.profile.baseURL = selection.endpoint
            let accepted = try service.start(targets: targets, mode: .rubric, model: selection, consent: true)
            try await waitForState("succeeded", id: accepted, service: service)
            #expect(fixture.keyReads == [selection.providerID])
            let report = try #require(try await service.latest(targets: targets, mode: .rubric).first)
            #expect(report.report.model == selection)
            #expect(report.report.state == .passed)
        }
    }

    // UUID 的稳定排序让测试能明确控制哪个条目先写入。
    private let firstID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
    private let secondID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2))

    private func expectFailure(_ code: String, starting: () throws -> String) {
        do {
            _ = try starting()
            Issue.record("预期启动失败 \(code)")
        } catch {
            #expect((error as? SkillEvaluationFailure)?.code == code)
        }
    }

    private func waitForState(_ state: String, id: String, service: SkillEvaluationService) async throws {
        var actual = "queued"
        try await waitUntil {
            actual = try service.taskState(id: id)
            return ["succeeded", "failed", "cancelled"].contains(actual)
        }
        try #require(actual == state)
    }

    /// 等真实就绪信号或共享任务状态，只以超时为测试失败上限。
    private func waitUntil(_ condition: () throws -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(8))
        while clock.now < deadline {
            try Task.checkCancellation()
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw EvaluationServiceFixtureError.timedOut
    }

    /// 即使断言提前退出，也先排空任务和 SQLite，再删除本次测试的隔离数据。
    private func withFixture(_ test: @MainActor (EvaluationServiceFixture) async throws -> Void) async throws {
        let fixture = try EvaluationServiceFixture()
        do {
            try await test(fixture)
        } catch {
            await fixture.clean()
            throw error
        }
        await fixture.clean()
    }
}

private enum EvaluationServiceFixtureError: Error {
    case missingFixture, timedOut
}

/// 临时挂起一次真实任务的目标校验，精确观察“已请求取消”与“执行器已退出”之间的状态。
@MainActor
private final class EvaluationVerificationPause {
    var subject: SkillEvaluationSubject?
    private(set) var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func verify(_ target: SkillEvaluationTarget) async throws {
        guard !released, subject == target.identity else { return }
        await withCheckedContinuation {
            continuation = $0
            entered = true
        }
        try Task.checkCancellation()
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

/// 每个用例拥有独立本机库、偏好域、任务存储和磁盘缓存。密钥与账号仅为内存值。
@MainActor
private final class EvaluationServiceFixture {
    let root: URL
    let cacheRoot: URL
    let defaults: UserDefaults
    let library: SkillLibraryStore
    let tasks = StarcatMCPTaskStore()
    let pause = EvaluationVerificationPause()
    var account = "account-a"
    var profile = AIProviderProfile(
        id: "fixture-provider", provider: .openAICompatible, baseURL: "https://model.invalid/v1",
        models: [
            .init(providerID: "fixture-provider", name: "fixture-chat", capability: .chat),
            .init(providerID: "fixture-provider", name: "disabled-model", capability: .chat, isEnabled: false),
        ],
        lastTestStatus: .success(modelCount: 2)
    )
    private(set) var keyReads: [String] = []
    private let suiteName: String

    var selection: SkillEvaluationSelection {
        .init(providerID: profile.id, endpoint: profile.baseURL, chat: "fixture-chat", embedding: nil)
    }

    private(set) lazy var service = SkillEvaluationService(
        gate: .init(channel: .direct), tasks: tasks, cache: .init(root: cacheRoot), defaults: defaults,
        account: { [unowned self] in account },
        providers: { [unowned self] in [profile] },
        readKey: { [unowned self] in
            keyReads.append($0)
            return "fixture-key"
        },
        source: { [library] _ in .init(store: library, downloader: EvaluationServiceBlob()) },
        verifyTarget: { [pause] in try await pause.verify($0) }
    )

    init() throws {
        suiteName = "test.starcat.skill-evaluation." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw EvaluationServiceFixtureError.missingFixture
        }
        self.defaults = defaults
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(suiteName)
        cacheRoot = root.appendingPathComponent("cache")
        library = try SkillLibraryStore(
            distributionGate: .init(channel: .direct), paths: .init(root: root.appendingPathComponent("library"))
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        do {
            try service.setExecutable(SkillEvaluationTestTool.executable())
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func addSkill(_ name: String, id: UUID) async throws -> (target: SkillEvaluationTarget, manifest: URL) {
        let entry = SkillLibraryEntry(id: id, manifestName: name, summary: "", managementKind: .managed)
        try await library.save(entry)
        let content = library.paths.entryDirectory(id).appendingPathComponent("content/" + name, isDirectory: true)
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        let manifest = content.appendingPathComponent("SKILL.md")
        try EvaluationServiceBlob.manifest.write(to: manifest)
        return (.library(id), manifest)
    }

    func repositoryTarget(_ repo: Repo, commit: String) -> SkillEvaluationTarget {
        .repository(repo, RepoSkill(
            repositoryID: repo.id, commitSHA: commit, directory: "skills/notes/", name: "notes", summary: "",
            manifest: String(decoding: EvaluationServiceBlob.manifest, as: UTF8.self),
            files: [.init(path: "SKILL.md", sha: RepoFileDownloader.gitBlobSHA(EvaluationServiceBlob.manifest),
                          size: EvaluationServiceBlob.manifest.count, mode: "100644")],
            installationIssue: nil, evaluationSnapshotComplete: true
        ))
    }

    func clean() async {
        pause.release()
        await tasks.cancelAllAndWait()
        try? await library.close()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

}

/// 仓库快照从固定 blob 获得与本机 fixture 相同的清单。
private struct EvaluationServiceBlob: RepoFileDownloading {
    static let manifest = Data("# Meeting note\n".utf8)

    func evaluationBlob(owner: String, repo: String, sha: String, size: Int) async throws -> Data {
        guard size == Self.manifest.count, sha == RepoFileDownloader.gitBlobSHA(Self.manifest) else {
            throw RepoSkillError.verification
        }
        return Self.manifest
    }

    func download(owner: String, repo: String, sha: String, relativePath: String, toRoot root: URL,
                  onProgress: (@Sendable (Double) -> Void)?) async throws -> URL {
        throw RepoSkillError.incomplete
    }
}
