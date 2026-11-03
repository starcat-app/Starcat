//
//  DiskChatHistoryMigrationTests.swift
//  StarcatTests
//
//  仓库 AI 对话历史自动迁移的完整性与失败恢复测试。
//  全部使用临时目录，覆盖两个方向、活动读写、冲突合并与超限历史，不接触用户数据。
//

import Foundation
import Testing
@testable import Starcat

/// 在真实 JSON 分片与独立 SQLite 之间迁移，不能用存储替身掩盖格式或目录发布错误。
@MainActor
@Suite("DiskChatHistoryMigration")
struct DiskChatHistoryMigrationTests {
    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("starcat-chat-migration-test-\(UUID())")
    }

    private func session(title: String = "history", count: Int = 25) -> ChatSession {
        let date = Date(timeIntervalSince1970: 123.125)
        let messages = (0..<count).map {
            ChatMessage(role: $0.isMultiple(of: 2) ? .user : .assistant, content: "message-\($0)", timestamp: date)
        }
        return ChatSession(title: title, createdAt: date, messages: messages, carriedOverSummary: "Earlier context\nwith citations")
    }

    private func cleanup(_ root: URL) { try? FileManager.default.removeItem(at: root) }

    /// 同一 facade 双向切换，检查分页、时间、推理、摘要与重启前未写偏好的恢复。
    @Test("双向迁移保留完整字段、分页与重启恢复")
    func roundTrip() async throws {
        let root = temporaryRoot()
        defer { cleanup(root) }
        let store = DiskChatHistoryStore(rootOverride: root)
        var history = session(count: 45)
        history.messages[1].reasoning = "Reasoning"
        history.messages[1].reasoningStartedAt = Date(timeIntervalSince1970: 123.5)
        history.messages[1].reasoningCompletedAt = Date(timeIntervalSince1970: 125.75)
        history.messages[1].responseCompletedAt = Date(timeIntervalSince1970: 128.125)
        let other = session(title: "other", count: 0)
        try store.saveSession(owner: "octo", repo: "demo", session: history)
        try store.saveSession(owner: "another", repo: "project", session: other)
        for kind in [ChatHistoryStorageKind.sqlite, .jsonFiles] {
            try await store.migrate(to: kind)
            #expect(store.storageKind == kind)
            #expect(!store.isMigrating)
            #expect(store.sessionCount == 2)
            #expect(store.repoCount == 2)
            #expect(try store.loadSession(owner: "octo", repo: "demo", sessionId: history.id) == history)
            #expect(try store.loadSession(owner: "another", repo: "project", sessionId: other.id) == other)
            let page = try await store.loadSessionTailAsync(owner: "octo", repo: "demo", sessionId: history.id, tailCount: 2)
            #expect(page?.messageStartIndex == 43)
            #expect(page?.session.messages == Array(history.messages.suffix(2)))
            let reopened = DiskChatHistoryStore(rootOverride: root, storageKind: kind == .sqlite ? .jsonFiles : .sqlite)
            #expect(reopened.storageKind == kind)
            #expect(try reopened.loadSession(owner: "octo", repo: "demo", sessionId: history.id) == history)
        }
    }

    @Test("目标已有历史保留，相同内容去重，冲突版本另存", arguments: [ChatHistoryStorageKind.jsonFiles, .sqlite])
    func merge(sourceKind: ChatHistoryStorageKind) async throws {
        let root = temporaryRoot()
        defer { cleanup(root) }
        let targetKind: ChatHistoryStorageKind = sourceKind == .jsonFiles ? .sqlite : .jsonFiles
        let same = session(title: "same")
        let current = session(title: "current")
        var previous = current
        previous.title = "previous"
        previous.messages[0].content = "Earlier version"
        let targetOnly = session(title: "target only")
        do {
            let target = DiskChatHistoryStore(rootOverride: root, storageKind: targetKind)
            try target.saveSession(owner: "octo", repo: "demo", session: same)
            try target.saveSession(owner: "octo", repo: "demo", session: previous)
            try target.saveSession(owner: "extra", repo: "project", session: targetOnly)
        }
        let store = DiskChatHistoryStore(rootOverride: root, storageKind: sourceKind)
        try store.saveSession(owner: "octo", repo: "demo", session: same)
        try store.saveSession(owner: "octo", repo: "demo", session: current)
        try await store.migrate(to: targetKind)
        #expect(store.sessionCount == 4)
        #expect(try store.loadSession(owner: "octo", repo: "demo", sessionId: current.id) == current)
        let copies = try store.listSessions(owner: "octo", repo: "demo").filter { $0.title == "previous" }
        let copyID = try #require(copies.first?.id)
        #expect(copyID != current.id)
        #expect(try store.loadSession(owner: "octo", repo: "demo", sessionId: copyID)?.messages == previous.messages)
        #expect(try store.loadSession(owner: "extra", repo: "project", sessionId: targetOnly.id) == targetOnly)
        // 切回时不能从已停用后端复活迁移后删除的历史。
        try store.deleteSession(owner: "extra", repo: "project", sessionId: targetOnly.id)
        try await store.migrate(to: sourceKind)
        #expect(store.sessionCount == 3)
        #expect(try store.loadSession(owner: "extra", repo: "project", sessionId: targetOnly.id) == nil)
    }

    @Test("损坏源文件阻止迁移，原文件不被自愈删除")
    func corruptSource() async throws {
        let root = temporaryRoot()
        defer { cleanup(root) }
        let store = DiskChatHistoryStore(rootOverride: root)
        let history = session()
        try store.saveSession(owner: "octo", repo: "demo", session: history)
        let metadata = root.appendingPathComponent("octo/demo/\(history.id)/metadata.json")
        let chunk = root.appendingPathComponent("octo/demo/\(history.id)/chunks/000001.json")
        let original = try Data(contentsOf: metadata)
        try Data("damaged".utf8).write(to: chunk)
        await #expect(throws: (any Error).self) { try await store.migrate(to: .sqlite) }
        #expect(store.storageKind == .jsonFiles)
        #expect(!store.isMigrating)
        #expect(try Data(contentsOf: metadata) == original)
        #expect(try Data(contentsOf: chunk) == Data("damaged".utf8))
        let healthy = session(title: "still writable")
        try store.saveSession(owner: "octo", repo: "healthy", session: healthy)
        #expect(try store.loadSession(owner: "octo", repo: "healthy", sessionId: healthy.id) == healthy)
    }

    @Test("目标 SQLite 打开失败时不误判为空历史或迁移成功")
    func unavailableDestination() async throws {
        let root = temporaryRoot()
        defer { cleanup(root) }
        let store = DiskChatHistoryStore(rootOverride: root)
        let history = session()
        try store.saveSession(owner: "octo", repo: "demo", session: history)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("chat-history.sqlite"), withIntermediateDirectories: true)
        await #expect(throws: (any Error).self) { try await store.migrate(to: .sqlite) }
        #expect(store.storageKind == .jsonFiles)
        #expect(try store.loadSession(owner: "octo", repo: "demo", sessionId: history.id) == history)
    }

    @Test("迁移中的回复保存、新增会话与删除均重放到目标", arguments: [ChatHistoryStorageKind.jsonFiles, .sqlite])
    func concurrentWrites(sourceKind: ChatHistoryStorageKind) async throws {
        let root = temporaryRoot()
        defer { cleanup(root) }
        let store = DiskChatHistoryStore(rootOverride: root, storageKind: sourceKind)
        var current = session(title: "streaming")
        let removed = session(title: "removed")
        try store.saveSession(owner: "octo", repo: "demo", session: current)
        try store.saveSession(owner: "octo", repo: "demo", session: removed)
        let migration = Task { try await store.migrate(to: sourceKind == .jsonFiles ? .sqlite : .jsonFiles) }
        while !store.isMigrating { await Task.yield() }
        current.messages.append(ChatMessage(role: .assistant, content: "Completed during migration"))
        let added = session(title: "new")
        try store.saveSession(owner: "octo", repo: "demo", session: current)
        try store.saveSession(owner: "octo", repo: "demo", session: added)
        try store.deleteSession(owner: "octo", repo: "demo", sessionId: removed.id)
        let savedCurrent = try #require(try store.loadSession(owner: "octo", repo: "demo", sessionId: current.id))
        try await migration.value
        #expect(store.sessionCount == 2)
        #expect(try store.loadSession(owner: "octo", repo: "demo", sessionId: current.id) == savedCurrent)
        #expect(try store.loadSession(owner: "octo", repo: "demo", sessionId: added.id) == added)
        #expect(try store.loadSession(owner: "octo", repo: "demo", sessionId: removed.id) == nil)
    }

    @Test("取消迁移保留原后端和数据")
    func cancellation() async throws {
        let root = temporaryRoot()
        defer { cleanup(root) }
        let store = DiskChatHistoryStore(rootOverride: root)
        let history = session()
        try store.saveSession(owner: "octo", repo: "demo", session: history)
        let migration = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await store.migrate(to: .sqlite)
        }
        await #expect(throws: CancellationError.self) { try await migration.value }
        #expect(store.storageKind == .jsonFiles)
        #expect(!store.isMigrating)
        #expect(try store.loadSession(owner: "octo", repo: "demo", sessionId: history.id) == history)
    }

    @Test("迁移中的清空和后续新会话不复活旧历史", arguments: [ChatHistoryStorageKind.jsonFiles, .sqlite])
    func clearDuringMigration(sourceKind: ChatHistoryStorageKind) async throws {
        let root = temporaryRoot()
        defer { cleanup(root) }
        let store = DiskChatHistoryStore(rootOverride: root, storageKind: sourceKind)
        try store.saveSession(owner: "octo", repo: "demo", session: session())
        try store.saveSession(owner: "another", repo: "project", session: session())
        let migration = Task { try await store.migrate(to: sourceKind == .jsonFiles ? .sqlite : .jsonFiles) }
        while !store.isMigrating { await Task.yield() }
        try store.deleteEverything()
        let added = session(title: "after clear")
        try store.saveSession(owner: "octo", repo: "demo", session: added)
        try await migration.value
        #expect(store.sessionCount == 1)
        #expect(try store.loadSession(owner: "octo", repo: "demo", sessionId: added.id) == added)
        #expect(try store.listSessions(owner: "another", repo: "project").isEmpty)
    }

    @Test("正在进行的异步读盘在目录发布前完成")
    func readsDuringMigration() async throws {
        let root = temporaryRoot()
        defer { cleanup(root) }
        let store = DiskChatHistoryStore(rootOverride: root)
        let history = session(count: 85)
        try store.saveSession(owner: "octo", repo: "demo", session: history)
        let readers = (0..<10).map { _ in
            Task { try await store.loadSessionAsync(owner: "octo", repo: "demo", sessionId: history.id) }
        }
        let migration = Task { try await store.migrate(to: .sqlite) }
        for reader in readers { #expect(try await reader.value == history) }
        try await migration.value
        #expect(try store.loadSession(owner: "octo", repo: "demo", sessionId: history.id) == history)
    }

    @Test("原子发布失败后重新打开原 SQLite，保持数据可读写")
    func publicationFailure() async throws {
        let parent = temporaryRoot()
        let root = parent.appendingPathComponent("chat-history")
        let manager = PublicationFailingFileManager(parent: parent)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
            cleanup(parent)
        }
        let store = DiskChatHistoryStore(fileManager: manager, rootOverride: root, storageKind: .sqlite)
        let history = session()
        try store.saveSession(owner: "octo", repo: "demo", session: history)
        await #expect(throws: POSIXError.self) { try await store.migrate(to: .jsonFiles) }
        #expect(store.storageKind == .sqlite)
        #expect(!store.isMigrating)
        #expect(try store.loadSession(owner: "octo", repo: "demo", sessionId: history.id) == history)
        let later = session(title: "still writable")
        try store.saveSession(owner: "octo", repo: "demo", session: later)
        #expect(try store.loadSession(owner: "octo", repo: "demo", sessionId: later.id) == later)
    }

    /// 两端分别未超限、合并后超限，导入不能触发日常 LRU 而静默丢掉旧对话。
    @Test("合并超过 100 MB 时不触发 LRU 淘汰")
    func noEvictionDuringMigration() async throws {
        let root = temporaryRoot()
        defer { cleanup(root) }
        let store = DiskChatHistoryStore(rootOverride: root)
        let largeText = String(repeating: "x", count: 53 * 1024 * 1024)
        var source = session(count: 1)
        source.messages[0].content = largeText
        var target = session(count: 1)
        target.messages[0].content = largeText
        try store.saveSession(owner: "octo", repo: "demo", session: source)
        do {
            let destination = DiskChatHistoryStore(rootOverride: root, storageKind: .sqlite)
            try destination.saveSession(owner: "extra", repo: "demo", session: target)
        }
        try await store.migrate(to: .sqlite)
        #expect(store.sessionCount == 2)
        #expect(try store.loadSession(owner: "octo", repo: "demo", sessionId: source.id)?.messages[0].content == largeText)
        #expect(try store.loadSession(owner: "extra", repo: "demo", sessionId: target.id)?.messages[0].content == largeText)
    }
}

/// 在发布前撤销隔离父目录的写权限，真实触发 rename 失败，覆盖关闭原库后的恢复。
/// 实例仅由对应 @MainActor 测试使用；不会修改系统临时目录本身的权限。
private final class PublicationFailingFileManager: FileManager, @unchecked Sendable {
    private let parent: URL
    private var stageCreations = 0

    init(parent: URL) {
        self.parent = parent
        super.init()
    }

    override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey: Any]? = nil) throws {
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
        if url.lastPathComponent.hasPrefix(".chat-history-migration-") {
            stageCreations += 1
            if stageCreations == 2 {
                try super.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
            }
        }
    }
}
