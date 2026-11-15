//
//  SkillLibraryEnvironmentTests.swift
//  StarcatTests
//
//  用可暂停的 scanner 检查刷新合并与关闭重开的时序。
//  store 只使用临时目录，根工厂与 watcher 均注入，绝不探测用户 Agent。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Skill 库可见期会话")
@MainActor
struct SkillLibraryEnvironmentTests {
    @Test("App Store 组合点在任何本机副作用前拒绝")
    func rejectsAppStore() throws {
        #expect(throws: DistributionGateError.self) {
            _ = try SkillLibraryEnvironment(
                viewModel: SkillWorkspaceViewModel(),
                distributionGate: DistributionGate(channel: .appStore)
            )
        }
        #expect(throws: DistributionGateError.self) {
            _ = try SkillRootWatcher(distributionGate: DistributionGate(channel: .appStore))
        }
    }

    @Test("扫描中重复刷新合并为一次补扫，停止后不再监听")
    func coalescesRefreshes() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let scanner = PendingScanner()
        let model = SkillWorkspaceViewModel()
        let watcher = SilentWatcher()
        let environment = try fixture.environment(model, scanner: scanner, watcher: watcher)
        environment.start()
        try await eventually { await scanner.count == 1 }
        environment.refresh()
        environment.refresh()
        environment.refresh()
        await scanner.finish(0, name: "first")
        try await eventually { await scanner.count == 2 }
        await scanner.finish(1, name: "second")
        try await eventually { model.loadState == .ready }
        #expect(await scanner.count == 2)
        #expect(model.items.map(\.name) == ["first", "second"])
        #expect(model.items.first { $0.name == "first" }?.locations.first?.state == .missing)
        environment.stop()
        #expect(watcher.stopCount == 1)
        try await fixture.store.close()
    }

    @Test("关闭再打开时，取消的旧结果不能发布或使新代次失效")
    func rejectsLateClosedSession() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let scanner = PendingScanner()
        let model = SkillWorkspaceViewModel()
        let environment = try fixture.environment(model, scanner: scanner)
        environment.start()
        try await eventually { await scanner.count == 1 }
        environment.stop()
        environment.start()
        try await eventually { await scanner.count == 2 }
        await scanner.finish(0, name: "obsolete")
        await scanner.finish(1, name: "current")
        try await eventually { model.loadState == .ready }
        #expect(model.items.map(\.name) == ["current"])
        #expect(try await fixture.store.snapshot().entries.map(\.manifestName) == ["current"])
        environment.stop()
        try await fixture.store.close()
    }

    @Test("监听事件在扫描中到达仍会补扫")
    func preservesDirtyEvents() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let scanner = PendingScanner()
        let model = SkillWorkspaceViewModel()
        let watcher = SilentWatcher()
        let environment = try fixture.environment(model, scanner: scanner, watcher: watcher)
        environment.start()
        try await eventually { await scanner.count == 1 }
        await scanner.finish(0, name: "first")
        try await eventually { model.loadState == .ready }
        environment.refresh()
        try await eventually { await scanner.count == 2 }
        watcher.emit()
        watcher.emit()
        try await Task.sleep(for: .milliseconds(50))
        await scanner.finish(1, name: "second")
        try await eventually { await scanner.count == 3 }
        await scanner.finish(2, name: "third")
        try await eventually { model.loadState == .ready }
        #expect(await scanner.count == 3)
        environment.stop()
        try await fixture.store.close()
    }

    @Test("没有事件仍会定期补扫，停止不清空现有快照")
    func reconcilesWithoutEvents() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = SkillWorkspaceViewModel()
        let scanner = PendingScanner()
        let environment = try fixture.environment(model, scanner: scanner, pollInterval: .milliseconds(80))
        environment.start()
        try await eventually { await scanner.count == 1 }
        await scanner.finish(0, name: "first")
        try await eventually { await scanner.count == 2 }
        environment.stop()
        await scanner.finish(1, name: "after-close")
        #expect(model.items.map(\.name) == ["first"])
        try await fixture.store.close()
    }

    @Test("失败根保留可读条目并发布部分可用状态")
    func keepsFailedRootEvidence() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = SkillWorkspaceViewModel()
        let scanner = PendingScanner()
        let environment = try fixture.environment(model, scanner: scanner)
        environment.start()
        try await eventually { await scanner.count == 1 }
        await scanner.finish(0, name: "first")
        try await eventually { model.loadState == .ready }
        environment.refresh()
        try await eventually { await scanner.count == 2 }
        await scanner.finish(1, name: nil, coverage: .inaccessible)
        try await eventually { model.loadState.message != nil }
        #expect(model.items.map(\.name) == ["first"])
        #expect(model.items.first?.locations.first?.state == .stale)
        #expect(model.items.first?.diagnostic != nil)
        #expect(model.loadState == .partial("\(fixture.root.configuredPath): fixture"))
        environment.stop()
        try await fixture.store.close()
    }

    /// 等待具体可观察条件而非依赖任务调度顺序；超时直接失败，避免测试无限挂起。
    private func eventually(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw CocoaError(.userCancelled) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private struct Fixture {
        let directory: URL
        let root: SkillLibraryRoot
        let store: SkillLibraryStore

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            root = SkillLibraryRoot(
                configuredPath: directory.appendingPathComponent("agents").path,
                agentIDs: ["codex"], scope: .global
            )
            store = try SkillLibraryStore(
                distributionGate: DistributionGate(channel: .direct), paths: .init(root: directory)
            )
        }

        @MainActor
        func environment(
            _ model: SkillWorkspaceViewModel, scanner: PendingScanner,
            watcher: SilentWatcher = SilentWatcher(), pollInterval: Duration = .seconds(60)
        ) throws -> SkillLibraryEnvironment {
            let configured = root
            return try SkillLibraryEnvironment(
                viewModel: model, distributionGate: DistributionGate(channel: .direct), store: store,
                scan: { await scanner.scan($0) }, roots: { _ in [configured] }, watcher: watcher,
                pollInterval: pollInterval, debounceInterval: .milliseconds(10)
            )
        }

        func cleanup() { try? FileManager.default.removeItem(at: directory) }
    }

    /// continuation 只由测试明确恢复，能模拟不立即响应取消的慢 I/O。
    private actor PendingScanner {
        private var requests: [SkillScanRequest] = []
        private var pending: [Int: CheckedContinuation<SkillScanReport, Never>] = [:]
        var count: Int { requests.count }

        func scan(_ request: SkillScanRequest) async -> SkillScanReport {
            let index = requests.count
            requests.append(request)
            return await withCheckedContinuation { pending[index] = $0 }
        }

        func finish(_ index: Int, name: String?, coverage: SkillScanCoverage = .complete) {
            let request = requests[index]
            let candidates = name.map { name in
                [SkillScanCandidate(
                    lexicalPath: request.roots[0].configuredPath + "/" + name,
                    resolvedPath: request.roots[0].configuredPath + "/" + name,
                    kind: .directory,
                    metadata: try? SkillFrontmatter.parse(
                        "---\nname: \(name)\ndescription: Fixture.\n---\n", directory: ""
                    ), diagnostic: nil
                )]
            } ?? []
            pending.removeValue(forKey: index)?.resume(returning: SkillScanReport(
                generationID: request.generationID,
                results: [.init(
                    root: request.roots[0], resolvedPath: request.roots[0].configuredPath,
                    coverage: coverage, candidates: candidates,
                    diagnostics: coverage == .complete ? [] : ["fixture"],
                    directoryCount: 1, entryCount: candidates.count
                )]
            ))
        }
    }

    /// 回调与停止计数都经锁保护，与生产 watcher 一样允许跨 executor 投递事件。
    private final class SilentWatcher: SkillRootWatching, @unchecked Sendable {
        private let lock = NSLock()
        private var callback: (@Sendable () -> Void)?
        private var stops = 0
        var stopCount: Int { lock.withLock { stops } }

        func start(paths: [String], onChange: @escaping @Sendable () -> Void) async throws {
            lock.withLock { callback = onChange }
        }

        func stop() { lock.withLock { callback = nil; stops += 1 } }
        func emit() { lock.withLock { callback }?() }
    }
}
