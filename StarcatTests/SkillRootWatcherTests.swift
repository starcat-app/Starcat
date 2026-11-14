//
//  SkillRootWatcherTests.swift
//  StarcatTests
//
//  使用系统 FSEvents 验证真实递归文件事件与回调上下文生命周期，
//  全部读写限定在测试临时目录，不依赖或操作任何应用窗口。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Skill 递归目录监听")
struct SkillRootWatcherTests {
    @Test("内部文件变化触发事件，停止后不再回调")
    func observesNestedFilesAndStops() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("skills/foo/references", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("guide.md")
        try Data("before".utf8).write(to: file)
        let counter = Counter()
        let watcher = try SkillRootWatcher(distributionGate: DistributionGate(channel: .direct))
        try await watcher.start(paths: [root.appendingPathComponent("skills").path]) { counter.record() }
        try await Task.sleep(for: .milliseconds(450))
        let before = counter.count
        try Data("changed".utf8).write(to: file)
        try await wait { counter.count > before }
        watcher.stop()
        try await Task.sleep(for: .milliseconds(450))
        let stopped = counter.count
        try Data("after stop".utf8).write(to: file)
        try await Task.sleep(for: .milliseconds(600))
        #expect(counter.count == stopped)
    }

    @Test("相邻 SQLite 写入不会使缺失 managed 根持续自刷新")
    func filtersSiblingChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sibling = root.appendingPathComponent("library.sqlite")
        try Data("before".utf8).write(to: sibling)
        let counter = Counter()
        let watcher = try SkillRootWatcher(distributionGate: DistributionGate(channel: .direct))
        try await watcher.start(paths: [root.appendingPathComponent("managed").path]) { counter.record() }
        try await Task.sleep(for: .milliseconds(450))
        let before = counter.count
        try Data("database write".utf8).write(to: sibling)
        try await Task.sleep(for: .milliseconds(700))
        #expect(counter.count == before)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("managed"), withIntermediateDirectories: true
        )
        try await wait { counter.count > before }
        watcher.stop()
    }

    @Test("重复更换根与停止安全释放 C 回调上下文")
    func restartsAndReleasesContext() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let counter = Counter()
        let watcher = try SkillRootWatcher(distributionGate: DistributionGate(channel: .direct))
        for index in 0..<12 {
            try await watcher.start(paths: [root.path]) { counter.record() }
            try Data("\(index)".utf8).write(to: root.appendingPathComponent("file.md"))
            watcher.stop()
            watcher.stop()
        }
        try await watcher.start(paths: []) { counter.record() }
        watcher.stop()
    }

    @Test("已取消的重启请求不能停止当前监听")
    func cancelledRestartKeepsCurrentStream() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("file.md")
        try Data("before".utf8).write(to: file)
        let counter = Counter()
        let watcher = try SkillRootWatcher(distributionGate: DistributionGate(channel: .direct))
        try await watcher.start(paths: [root.path]) { counter.record() }
        try await Task.sleep(for: .milliseconds(450))
        let before = counter.count
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await watcher.start(paths: []) { counter.record() }
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        try Data("after cancellation".utf8).write(to: file)
        try await wait { counter.count > before }
        watcher.stop()
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CocoaError(.userCancelled) }
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    /// C 回调在专属队列执行；计数通过锁读取，避免测试自身制造数据竞争。
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func record() { lock.withLock { value += 1 } }
    }
}
