//
//  DiskChatHistoryStoreTests.swift
//  StarcatTests
//
//  覆盖 DiskChatHistoryStore CRUD + LRU + index 自愈（HOM-70 / 2026-06-15）。
//
//  关注点：
//  - listSessions：index.json 读到 / 损坏自愈重建 / 完全缺失从 session 文件重建；
//  - saveSession：metadata + chunks 写入并维护 index；同一 sessionId 重复保存覆盖不重复；
//  - deleteSession：清 session 文件 + index 同步移除；删完最后一个 → index.json 也删；
//  - deleteAllForRepo：清整个 <owner>/<repo>/ 目录；
//  - deleteEverything：清整个 chat-history 根目录；
//  - LRU sweep：仅在总量 > 100 MB 时触发，按 mtime 升序删；无 TTL；
//  - Observable 派生量 totalBytes / sessionCount / repoCount 同步更新；
//  - 损坏 JSON → loadSession 返 nil 且自动删损坏文件 + 同步 index。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("DiskChatHistoryStore")
struct DiskChatHistoryStoreTests {

    private func makeIsolatedStore(file: StaticString = #filePath, line: UInt = #line) throws
        -> (store: DiskChatHistoryStore, root: URL)
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("starcat-chat-history-test-\(UUID().uuidString)", isDirectory: true)
        let store = DiskChatHistoryStore(rootOverride: root)
        return (store, root)
    }

    private func makeIsolatedSQLiteStore(file: StaticString = #filePath, line: UInt = #line) throws
        -> (store: DiskChatHistoryStore, root: URL)
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("starcat-chat-history-sqlite-test-\(UUID().uuidString)", isDirectory: true)
        let store = DiskChatHistoryStore(rootOverride: root, storageKind: .sqlite)
        return (store, root)
    }

    private func cleanup(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSession(
        id: UUID = UUID(),
        title: String = "hello",
        messageCount: Int = 2,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) -> ChatSession {
        let messages = (0..<messageCount).map { i in
            ChatMessage(
                id: UUID(),
                role: i % 2 == 0 ? .user : .assistant,
                content: "msg-\(i)",
                timestamp: createdAt
            )
        }
        return ChatSession(
            id: id,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            messages: messages
        )
    }

    // MARK: - listSessions

    @Test("listSessions 无任何 session 返回空数组")
    func listSessionsEmpty() throws {
        let (store, root) = try makeIsolatedStore()
        defer { cleanup(root) }
        let list = try store.listSessions(owner: "octo", repo: "demo")
        #expect(list.isEmpty)
    }

    @Test("saveSession + listSessions 同 (owner,repo) 往返")
    func saveAndList() throws {
        let (store, root) = try makeIsolatedStore()
        defer { cleanup(root) }
        let session = makeSession(title: "first")
        try store.saveSession(owner: "octo", repo: "demo", session: session)

        let list = try store.listSessions(owner: "octo", repo: "demo")
        #expect(list.count == 1)
        #expect(list.first?.id == session.id)
        #expect(list.first?.title == "first")
        #expect(list.first?.messageCount == 2)
    }

    @Test("loadSession 命中往返")
    func loadSession() throws {
        let (store, root) = try makeIsolatedStore()
        defer { cleanup(root) }
        let session = makeSession(title: "loadme", messageCount: 3)
        try store.saveSession(owner: "octo", repo: "demo", session: session)

        let loaded = try store.loadSession(owner: "octo", repo: "demo", sessionId: session.id)
        #expect(loaded?.id == session.id)
        #expect(loaded?.title == "loadme")
        #expect(loaded?.messages.count == 3)
    }

    @Test("JSON 与 SQLite 后端都保留 assistant reasoning")
    func reasoningRoundTripsAcrossStorageBackends() throws {
        let stores = [try makeIsolatedStore(), try makeIsolatedSQLiteStore()]

        for (store, root) in stores {
            defer { cleanup(root) }
            let assistant = ChatMessage(
                role: .assistant,
                content: "最终回答",
                reasoning: "先检查上下文，再组织回答",
                reasoningStartedAt: Date(timeIntervalSince1970: 100),
                reasoningCompletedAt: Date(timeIntervalSince1970: 102.5),
                responseCompletedAt: Date(timeIntervalSince1970: 105),
                isStreaming: false
            )
            let session = ChatSession(title: "reasoning", messages: [assistant])

            try store.saveSession(owner: "octo", repo: "demo", session: session)
            let loaded = try store.loadSession(
                owner: "octo",
                repo: "demo",
                sessionId: session.id
            )

            #expect(loaded?.messages.first?.reasoning == "先检查上下文，再组织回答")
            #expect(loaded?.messages.first?.reasoningStartedAt == Date(timeIntervalSince1970: 100))
            #expect(loaded?.messages.first?.reasoningCompletedAt == Date(timeIntervalSince1970: 102.5))
            #expect(loaded?.messages.first?.responseCompletedAt == Date(timeIntervalSince1970: 105))
            #expect(loaded?.messages.first?.content == "最终回答")
        }
    }

    @Test("异步 listSessions 与同步入口结果一致")
    func listSessionsAsync() async throws {
        let (store, root) = try makeIsolatedStore()
        defer { cleanup(root) }
        let session = makeSession(title: "async-list")
        try store.saveSession(owner: "octo", repo: "demo", session: session)

        let list = try await store.listSessionsAsync(owner: "octo", repo: "demo")
        #expect(list.map(\.id) == [session.id])
    }

    @Test("异步 loadSession 完整解码消息")
    func loadSessionAsync() async throws {
        let (store, root) = try makeIsolatedStore()
        defer { cleanup(root) }
        let session = makeSession(title: "async-load", messageCount: 4)
        try store.saveSession(owner: "octo", repo: "demo", session: session)

        let loaded = try await store.loadSessionAsync(
            owner: "octo",
            repo: "demo",
            sessionId: session.id
        )
        #expect(loaded?.id == session.id)
        #expect(loaded?.title == "async-load")
        #expect(loaded?.messages.map(\.content) == ["msg-0", "msg-1", "msg-2", "msg-3"])
    }

    @Test("loadSessionTailAsync 首屏只读取尾部 2 条消息")
    func loadSessionTailAsync() async throws {
        let (store, root) = try makeIsolatedStore()
        defer { cleanup(root) }
        let session = makeSession(title: "tail", messageCount: 25)
        try store.saveSession(owner: "octo", repo: "demo", session: session)

        let page = try await store.loadSessionTailAsync(
            owner: "octo",
            repo: "demo",
            sessionId: session.id,
            tailCount: 2
        )

        #expect(page?.messageStartIndex == 23)
        #expect(page?.totalMessageCount == 25)
        #expect(page?.session.messages.map(\.content) == ["msg-23", "msg-24"])
    }

    @Test("loadMessagesAsync 可跨 chunk 读取更早 20 条消息")
    func loadEarlierMessagesAcrossChunks() async throws {
        let (store, root) = try makeIsolatedStore()
        defer { cleanup(root) }
        let session = makeSession(title: "chunks", messageCount: 45)
        try store.saveSession(owner: "octo", repo: "demo", session: session)

        let messages = try await store.loadMessagesAsync(
            owner: "octo",
            repo: "demo",
            sessionId: session.id,
            start: 23,
            end: 43
        )

        #expect(messages.count == 20)
        #expect(messages.first?.content == "msg-23")
        #expect(messages.last?.content == "msg-42")
    }

    @Test("loadSession 未命中返回 nil")
    func loadMissing() throws {
        let (store, root) = try makeIsolatedStore()
        defer { cleanup(root) }
        let loaded = try store.loadSession(owner: "octo", repo: "demo", sessionId: UUID())
        #expect(loaded == nil)
    }

    @Test("同 sessionId 重复保存覆盖且 index 不重复")
    func saveOverwrites() throws {
        let (store, root) = try makeIsolatedStore()
        defer { cleanup(root) }
        let id = UUID()
        let v1 = makeSession(id: id, title: "v1", messageCount: 1)
        let v2 = makeSession(id: id, title: "v2", messageCount: 4)
        try store.saveSession(owner: "octo", repo: "demo", session: v1)
        try store.saveSession(owner: "octo", repo: "demo", session: v2)

        let list = try store.listSessions(owner: "octo", repo: "demo")
        #expect(list.count == 1)
        #expect(list.first?.title == "v2")
        #expect(list.first?.messageCount == 4)
    }

    @Test("listSessions 按 updatedAt 倒序（最新在前）")
    func listSortedNewestFirst() throws {
        let (store, root) = try makeIsolatedStore()
        defer { cleanup(root) }
        let old = makeSession(title: "old", updatedAt: Date(timeIntervalSinceNow: -3600))
        let new = makeSession(title: "new", updatedAt: Date())
        try store.saveSession(owner: "octo", repo: "demo", session: old)
        try store.saveSession(owner: "octo", repo: "demo", session: new)

        let list = try store.listSessions(owner: "octo", repo: "demo")
        #expect(list.count == 2)
        #expect(list.first?.title == "new")
        #expect(list.last?.title == "old")
    }

    @Test("不同 (owner,repo) 互不干扰")
    func differentReposIsolated() throws {
        let (store, root) = try makeIsolatedStore()
        defer { cleanup(root) }
        let a = makeSession(title: "A")
        let b = makeSession(title: "B")
        try store.saveSession(owner: "octo", repo: "demo", session: a)
        try store.saveSession(owner: "octo", repo: "other", session: b)

        #expect(try store.listSessions(owner: "octo", repo: "demo").map(\.title) == ["A"])
        #expect(try store.listSessions(owner: "octo", repo: "other").map(\.title) == ["B"])
    }

    // MARK: - delete

    @Test("deleteSession 移除文件 + index 同步移除条目")
    func deleteSessionSyncsIndex() throws {
        let (store, root) = try makeIsolatedStore()
        defer { cleanup(root) }
        let a = makeSession(title: "A")
        let b = makeSession(title: "B")
        try store.saveSession(owner: "octo", repo: "demo", session: a)
        try store.saveSession(owner: "octo", repo: "demo", session: b)

        try store.deleteSession(owner: "octo", repo: "demo", sessionId: a.id)

        let remaining = try store.listSessions(owner: "octo", repo: "demo")
        #expect(remaining.count == 1)
        #expect(remaining.first?.title == "B")
        #expect(try store.loadSession(owner: "octo", repo: "demo", sessionId: a.id) == nil)
    }

    @Test("deleteAllForRepo 清空该 repo 全部 sessions")
    func deleteAllForRepoWipesRepo() throws {
        let (store, root) = try makeIsolatedStore()
        defer { cleanup(root) }
        try store.saveSession(owner: "octo", repo: "demo", session: makeSession(title: "A"))
        try store.saveSession(owner: "octo", repo: "demo", session: makeSession(title: "B"))
        try store.saveSession(owner: "octo", repo: "other", session: makeSession(title: "C"))

        try store.deleteAllForRepo(owner: "octo", repo: "demo")

        #expect(try store.listSessions(owner: "octo", repo: "demo").isEmpty)
        #expect(try store.listSessions(owner: "octo", repo: "other").count == 1)
    }

    @Test("deleteEverything 清空整个 chat-history 根")
    func deleteEverythingWipesAll() throws {
        let (store, root) = try makeIsolatedStore()
        defer { cleanup(root) }
        try store.saveSession(owner: "octo", repo: "demo", session: makeSession())
        try store.saveSession(owner: "octo", repo: "other", session: makeSession())

        try store.deleteEverything()

        #expect(store.sessionCount == 0)
        #expect(store.totalBytes == 0)
        #expect(store.repoCount == 0)
        #expect(try store.listSessions(owner: "octo", repo: "demo").isEmpty)
    }

    // MARK: - Observable 派生量

    @Test("Observable 派生量随 save / delete 同步更新")
    func observableUpdates() throws {
        let (store, root) = try makeIsolatedStore()
        defer { cleanup(root) }
        #expect(store.sessionCount == 0)
        #expect(store.repoCount == 0)
        #expect(store.totalBytes == 0)

        try store.saveSession(owner: "octo", repo: "demo", session: makeSession())
        #expect(store.sessionCount == 1)
        #expect(store.repoCount == 1)
        #expect(store.totalBytes > 0)

        try store.saveSession(owner: "octo", repo: "other", session: makeSession())
        #expect(store.sessionCount == 2)
        #expect(store.repoCount == 2)

        try store.deleteEverything()
        #expect(store.sessionCount == 0)
        #expect(store.repoCount == 0)
        #expect(store.totalBytes == 0)
    }

    // MARK: - index 自愈

    @Test("index.json 损坏 → listSessions 自动从 session 文件重建")
    func corruptedIndexAutoRebuilds() throws {
        let (store, root) = try makeIsolatedStore()
        defer { cleanup(root) }
        let session = makeSession(title: "valid")
        try store.saveSession(owner: "octo", repo: "demo", session: session)

        // 直接破坏 index.json
        let indexPath = root
            .appendingPathComponent("octo", isDirectory: true)
            .appendingPathComponent("demo", isDirectory: true)
            .appendingPathComponent("index.json")
        try Data("garbage not json".utf8).write(to: indexPath)

        let list = try store.listSessions(owner: "octo", repo: "demo")
        #expect(list.count == 1)
        #expect(list.first?.title == "valid")
    }

    @Test("index.json 完全缺失 → listSessions 仍能从 session 文件重建")
    func missingIndexAutoRebuilds() throws {
        let (store, root) = try makeIsolatedStore()
        defer { cleanup(root) }
        let session = makeSession(title: "orphan")
        try store.saveSession(owner: "octo", repo: "demo", session: session)

        let indexPath = root
            .appendingPathComponent("octo", isDirectory: true)
            .appendingPathComponent("demo", isDirectory: true)
            .appendingPathComponent("index.json")
        try FileManager.default.removeItem(at: indexPath)

        let list = try store.listSessions(owner: "octo", repo: "demo")
        #expect(list.count == 1)
        #expect(list.first?.title == "orphan")
    }

    // MARK: - 损坏 session 文件

    @Test("loadSession decode 失败 → 返 nil 且删损坏 session 目录 + 同步 index")
    func corruptedSessionRemoved() throws {
        let (store, root) = try makeIsolatedStore()
        defer { cleanup(root) }
        let id = UUID()
        let dir = root.appendingPathComponent("octo/demo/\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let badPath = dir.appendingPathComponent("metadata.json")
        try Data("{ not metadata }".utf8).write(to: badPath)
        // 也写一个伪 index 让自愈逻辑早期返回它，避免 fallback 路径覆盖结果
        let indexPath = root.appendingPathComponent("octo/demo/index.json")
        let fakeIndex = """
        { "sessions": [
            { "id": "\(id.uuidString)", "title": "fake", "createdAt": "\(ISO8601DateFormatter().string(from: Date()))", "updatedAt": "\(ISO8601DateFormatter().string(from: Date()))", "messageCount": 0, "bytes": 0 }
        ] }
        """
        try Data(fakeIndex.utf8).write(to: indexPath)

        let loaded = try store.loadSession(owner: "octo", repo: "demo", sessionId: id)
        #expect(loaded == nil)
        // 损坏 session 目录被删
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        // index 同步更新（id 移除）
        let list = try store.listSessions(owner: "octo", repo: "demo")
        #expect(list.allSatisfy { $0.id != id })
    }

    // MARK: - LRU

    @Test("LRU sweep：未超 100MB 不删任何文件")
    func lruSweepUnderLimitNoop() throws {
        let (store, root) = try makeIsolatedStore()
        defer { cleanup(root) }
        try store.saveSession(owner: "octo", repo: "demo", session: makeSession())
        let before = store.sessionCount

        try store.lruSweep()
        #expect(store.sessionCount == before)
    }

    // MARK: - HOM-70 v2 carry-over 持久化

    /// HOM-70 v2：carry-over 字段必须穿越落盘 → load → 完整 round-trip。
    /// 这是 v2 闭环的"持久化端"防线 —— v1 漏掉 prompt 注入是另一端（service），
    /// 持久化这边历来没问题，但加 case 防止后续重构把 `carriedOverSummary` 字段
    /// 从 ChatSession 的 Codable keys 里漏掉。
    @Test("carriedOverSummary 字段：save 后 load 出来还在（含 markdown 与换行）")
    func carriedOverSummaryRoundTrip() throws {
        let (store, root) = try makeIsolatedStore()
        defer { cleanup(root) }

        let carry = """
        - 上一轮我们聊了 SwiftUI ScrollView geometry 监听；
        - 然后扯到 LazyVStack id 复用引发的卡顿。
        """
        var session = makeSession(title: "carry-over session", messageCount: 1)
        session.carriedOverSummary = carry
        try store.saveSession(owner: "octo", repo: "demo", session: session)

        let loaded = try store.loadSession(owner: "octo", repo: "demo", sessionId: session.id)
        #expect(loaded?.carriedOverSummary == carry)
        // 多行 markdown 应原样保留（不应被 JSON encode/decode 折断换行符）
        let loadedSummary = try #require(loaded?.carriedOverSummary)
        #expect(loadedSummary.contains("\n"))
    }

    /// HOM-70 v2：默认 session（无承接）carriedOverSummary 必须是 nil，
    /// 而不是空字符串 —— 空字符串与 nil 在 view 端 `shouldShowCarryOverBanner` 都
    /// 判定不显示 banner，但 nil 语义更清晰（"没有承接" vs "承接段被清空了"）。
    @Test("默认 session：carriedOverSummary 持久化后仍为 nil（非空字符串）")
    func defaultSessionCarryOverIsNil() throws {
        let (store, root) = try makeIsolatedStore()
        defer { cleanup(root) }
        try store.saveSession(owner: "octo", repo: "demo", session: makeSession())
        let list = try store.listSessions(owner: "octo", repo: "demo")
        let id = try #require(list.first?.id)
        let loaded = try store.loadSession(owner: "octo", repo: "demo", sessionId: id)
        #expect(loaded?.carriedOverSummary == nil)
    }

    // MARK: - SQLite 后端

    @Test("SQLite 后端：save/list/load 完整往返")
    func sqliteSaveListLoadRoundTrip() throws {
        let (store, root) = try makeIsolatedSQLiteStore()
        defer { cleanup(root) }

        let session = makeSession(title: "sqlite", messageCount: 5)
        try store.saveSession(owner: "octo", repo: "demo", session: session)

        let list = try store.listSessions(owner: "octo", repo: "demo")
        #expect(list.count == 1)
        #expect(list.first?.id == session.id)
        #expect(list.first?.title == "sqlite")
        #expect(list.first?.messageCount == 5)

        let loaded = try store.loadSession(owner: "octo", repo: "demo", sessionId: session.id)
        #expect(loaded?.messages.map(\.content) == ["msg-0", "msg-1", "msg-2", "msg-3", "msg-4"])
        #expect(store.storageKind == .sqlite)
        #expect(store.totalBytes > 0)
    }

    @Test("SQLite 后端：尾部 2 条与加载更早 20 条")
    func sqliteTailAndEarlierMessages() async throws {
        let (store, root) = try makeIsolatedSQLiteStore()
        defer { cleanup(root) }

        let session = makeSession(title: "sqlite-page", messageCount: 45)
        try store.saveSession(owner: "octo", repo: "demo", session: session)

        let tail = try await store.loadSessionTailAsync(
            owner: "octo",
            repo: "demo",
            sessionId: session.id,
            tailCount: 2
        )
        #expect(tail?.messageStartIndex == 43)
        #expect(tail?.totalMessageCount == 45)
        #expect(tail?.session.messages.map(\.content) == ["msg-43", "msg-44"])

        let earlier = try await store.loadMessagesAsync(
            owner: "octo",
            repo: "demo",
            sessionId: session.id,
            start: 23,
            end: 43
        )
        #expect(earlier.count == 20)
        #expect(earlier.first?.content == "msg-23")
        #expect(earlier.last?.content == "msg-42")
    }

    @Test("SQLite 后端：deleteEverything 清空独立数据库")
    func sqliteDeleteEverything() throws {
        let (store, root) = try makeIsolatedSQLiteStore()
        defer { cleanup(root) }

        try store.saveSession(owner: "octo", repo: "demo", session: makeSession())
        try store.saveSession(owner: "octo", repo: "other", session: makeSession())
        #expect(store.sessionCount == 2)
        #expect(store.repoCount == 2)

        try store.deleteEverything()
        #expect(store.sessionCount == 0)
        #expect(store.repoCount == 0)
        #expect(try store.listSessions(owner: "octo", repo: "demo").isEmpty)
    }
}
