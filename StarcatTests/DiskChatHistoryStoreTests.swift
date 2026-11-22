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
import GRDB
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

    private func makeIsolatedSQLiteStore(
        maxTotalBytes: Int64? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (store: DiskChatHistoryStore, root: URL)
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("starcat-chat-history-sqlite-test-\(UUID().uuidString)", isDirectory: true)
        // maxTotalBytes 仅测试注入：小配额驱动 LRU 淘汰路径，生产保持默认 100 MiB。
        let store = DiskChatHistoryStore(
            rootOverride: root,
            storageKind: .sqlite,
            sqliteMaxTotalBytes: maxTotalBytes
        )
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

    /// 构造指定近似逻辑字节量的会话：ASCII 填充 content，字符数即 UTF-8 字节数，
    /// 便于精确断言 LRU 淘汰的扣减口径。
    private func makeSizedSession(
        id: UUID = UUID(),
        title: String,
        contentBytes: Int,
        updatedAt: Date
    ) -> ChatSession {
        let content = String(repeating: "a", count: contentBytes)
        let message = ChatMessage(id: UUID(), role: .user, content: content, timestamp: updatedAt)
        return ChatSession(id: id, title: title, createdAt: updatedAt, updatedAt: updatedAt, messages: [message])
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

    // MARK: - SQLite 后端：LRU 淘汰

    @Test("SQLite 后端：略超配额按最旧优先淘汰，删到达标即停不清空")
    func sqliteLruSweepStopsAtQuota() throws {
        // 配额 2000 逻辑字节：A(1501) 保存后未超；B(701) 加入后共 2202 超配额 → 只删 A；
        // C(701) 加入后共 1402 未超 → no-op。旧实现用物理文件大小做停止条件
        // （事务内 DELETE 不缩文件，页开销恒真），会把 A、B、C 全部删光。
        let (store, root) = try makeIsolatedSQLiteStore(maxTotalBytes: 2000)
        defer { cleanup(root) }

        let a = makeSizedSession(title: "A", contentBytes: 1500, updatedAt: Date(timeIntervalSince1970: 1000))
        let b = makeSizedSession(title: "B", contentBytes: 700, updatedAt: Date(timeIntervalSince1970: 2000))
        let c = makeSizedSession(title: "C", contentBytes: 700, updatedAt: Date(timeIntervalSince1970: 3000))

        // saveSession 内部隐式触发 sweep，即生产真实路径。
        try store.saveSession(owner: "octo", repo: "demo", session: a)
        try store.saveSession(owner: "octo", repo: "demo", session: b)
        try store.saveSession(owner: "octo", repo: "demo", session: c)

        #expect(try store.loadSession(owner: "octo", repo: "demo", sessionId: a.id) == nil)
        // #require 的宏展开不传播外层 try，内层抛错表达式必须自带 try。
        let loadedB = try #require(try store.loadSession(owner: "octo", repo: "demo", sessionId: b.id))
        #expect(loadedB.messages.first?.content == String(repeating: "a", count: 700))
        let loadedC = try #require(try store.loadSession(owner: "octo", repo: "demo", sessionId: c.id))
        #expect(loadedC.messages.first?.content == String(repeating: "a", count: 700))
        #expect(store.sessionCount == 2)

        // 幂等：再次显式 sweep，保留集不变。
        try store.lruSweep()
        #expect(store.sessionCount == 2)
        #expect(try store.loadSession(owner: "octo", repo: "demo", sessionId: b.id) != nil)
        #expect(try store.loadSession(owner: "octo", repo: "demo", sessionId: c.id) != nil)
    }

    @Test("SQLite 后端：连续超配额时逐轮扣减逻辑字节")
    func sqliteLruSweepDeductsPerSession() throws {
        // 每加入一个会话都触发 sweep：A(1201) 存活 → B(1101) 加入后共 2302 删 A →
        // C(1001) 加入后共 2102 删 B → 只剩 C。
        let (store, root) = try makeIsolatedSQLiteStore(maxTotalBytes: 2000)
        defer { cleanup(root) }

        let a = makeSizedSession(title: "A", contentBytes: 1200, updatedAt: Date(timeIntervalSince1970: 1000))
        let b = makeSizedSession(title: "B", contentBytes: 1100, updatedAt: Date(timeIntervalSince1970: 2000))
        let c = makeSizedSession(title: "C", contentBytes: 1000, updatedAt: Date(timeIntervalSince1970: 3000))

        try store.saveSession(owner: "octo", repo: "demo", session: a)
        try store.saveSession(owner: "octo", repo: "demo", session: b)
        try store.saveSession(owner: "octo", repo: "demo", session: c)

        #expect(store.sessionCount == 1)
        #expect(try store.loadSession(owner: "octo", repo: "demo", sessionId: a.id) == nil)
        #expect(try store.loadSession(owner: "octo", repo: "demo", sessionId: b.id) == nil)
        #expect(try store.loadSession(owner: "octo", repo: "demo", sessionId: c.id) != nil)
    }

    @Test("SQLite 后端：默认配额下小库 sweep no-op")
    func sqliteLruSweepDefaultQuotaNoop() throws {
        // 默认 100 MiB 配额：极小测试库不应有任何淘汰（对照 JSON 后端 lruSweepUnderLimitNoop）。
        let (store, root) = try makeIsolatedSQLiteStore()
        defer { cleanup(root) }

        try store.saveSession(owner: "octo", repo: "demo", session: makeSession())
        try store.saveSession(owner: "octo", repo: "demo", session: makeSession())

        try store.lruSweep()
        #expect(store.sessionCount == 2)
    }

    // MARK: - P1-1 增量保存（全仓性能优化专项回归）

    // 追加保存是对话回合的热路径（每回合至少 2 次）。旧实现每次整会话重写：
    // JSON 重写全部分块并遍历全库统计；SQLite 删光该会话消息再全量重插。
    // 本区块锁定增量语义：
    // 1. JSON 只重写受影响的尾部 chunk（mtime 断言即「200 条会话写入量对比」的验收证据）；
    // 2. 全库字节统计走 delta 维护，口径与 reload() 全量重算严格一致；
    // 3. 消息数回退（读盘失败降级）走整体重建并清掉多余 chunk，不留脏残留；
    // 4. SQLite 追加时不删已有行（rowid 不变），回退时清掉多余 ordinal。

    /// 会话 chunk 文件路径（与实现侧 `%06d.json` 命名一一对应）。
    private func chunkURL(_ root: URL, sessionId: UUID, index: Int) -> URL {
        root.appendingPathComponent("octo")
            .appendingPathComponent("demo")
            .appendingPathComponent(sessionId.uuidString)
            .appendingPathComponent("chunks")
            .appendingPathComponent(String(format: "%06d.json", index))
    }

    private func setMtime(_ url: URL, to date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// mtime 读回。断言一律用相对比较：任何重写都会把 mtime 推到当前时间
    /// （与 1970 基准差 5 亿秒以上），1 秒容差只吸收文件系统的时间格式化误差。
    private func mtimeOf(_ url: URL) throws -> Date {
        try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    }

    /// 在既有会话尾部追加一条消息——对话回合的唯一真实形态（RepoAIChatViewModel 只在尾部追加）。
    private func sessionAppending(_ message: ChatMessage, to session: ChatSession) -> ChatSession {
        ChatSession(
            id: session.id,
            title: session.title,
            createdAt: session.createdAt,
            updatedAt: session.updatedAt,
            messages: session.messages + [message]
        )
    }

    /// 用只读第二连接查 chat_messages 的 ordinal → rowid 快照。
    /// rowid 由 SQLite 按插入顺序分配：删光重插会全部变化，原地保留则不变。
    private func sqliteRowidSnapshot(_ reader: DatabaseQueue, sessionId: UUID) throws -> [Int: Int64] {
        try reader.read { db in
            // 用 Int/Int64.fetchAll（DatabaseValueConvertible 核心取数 API），不依赖
            // Row 下标的列读取语法；两条查询同 WHERE 同 ORDER，行序一致可 zip。
            let ordinals = try Int.fetchAll(
                db,
                sql: "SELECT ordinal FROM chat_messages WHERE session_id = ? ORDER BY ordinal",
                arguments: [sessionId.uuidString]
            )
            let rowids = try Int64.fetchAll(
                db,
                sql: "SELECT rowid FROM chat_messages WHERE session_id = ? ORDER BY ordinal",
                arguments: [sessionId.uuidString]
            )
            return Dictionary(uniqueKeysWithValues: zip(ordinals, rowids))
        }
    }

    private func makeReadonlyReader(root: URL) throws -> DatabaseQueue {
        var config = Configuration()
        config.readonly = true
        return try DatabaseQueue(path: root.appendingPathComponent("chat-history.sqlite").path, configuration: config)
    }

    @Test("P1-1 追加保存只重写受影响的尾部 chunk")
    func jsonIncrementalSaveOnlyTouchesTailChunks() throws {
        let (store, root) = try makeIsolatedStore()
        defer { cleanup(root) }

        // 200 条 = 10 个整满 chunk（messagesPerChunk = 20），对应验收口径的会话量级。
        let base = makeSession(messageCount: 200)
        try store.saveSession(owner: "octo", repo: "demo", session: base)

        // 把全部落盘文件 mtime 固定到 1970 基准；此后被重写的文件 mtime 会跳到当前时间。
        let oldDate = Date(timeIntervalSince1970: 1000)
        let metadataURL = root.appendingPathComponent("octo").appendingPathComponent("demo")
            .appendingPathComponent(base.id.uuidString).appendingPathComponent("metadata.json")
        let indexURL = root.appendingPathComponent("octo").appendingPathComponent("demo")
            .appendingPathComponent("index.json")
        for index in 0..<10 { try setMtime(chunkURL(root, sessionId: base.id, index: index), to: oldDate) }
        try setMtime(metadataURL, to: oldDate)
        try setMtime(indexURL, to: oldDate)

        // 回合 1：追加第 201 条 → 落在新 chunk 10，chunk 0-9 不得重写。
        let session = sessionAppending(
            ChatMessage(id: UUID(), role: .user, content: "msg-200", timestamp: Date()),
            to: base
        )
        try store.saveSession(owner: "octo", repo: "demo", session: session)
        for index in 0..<10 {
            #expect(
                try mtimeOf(chunkURL(root, sessionId: base.id, index: index)).timeIntervalSince(oldDate) < 1,
                "chunk \(index) 不应被追加保存重写"
            )
        }
        #expect(try mtimeOf(chunkURL(root, sessionId: base.id, index: 10)).timeIntervalSince(oldDate) > 1000)
        #expect(try mtimeOf(metadataURL).timeIntervalSince(oldDate) > 1000)
        #expect(try mtimeOf(indexURL).timeIntervalSince(oldDate) > 1000)

        // 回合 2：再追加第 202 条 → chunk 10 变为部分填充，增量重写仍只落它自己。
        let session2 = sessionAppending(
            ChatMessage(id: UUID(), role: .assistant, content: "msg-201", timestamp: Date()),
            to: session
        )
        try store.saveSession(owner: "octo", repo: "demo", session: session2)
        for index in 0..<10 {
            #expect(
                try mtimeOf(chunkURL(root, sessionId: base.id, index: index)).timeIntervalSince(oldDate) < 1,
                "chunk \(index) 不应被第二轮追加重写"
            )
        }
        #expect(try mtimeOf(chunkURL(root, sessionId: base.id, index: 10)).timeIntervalSince(oldDate) > 1000)

        // 写入面收窄的同时内容必须完整：全量读回逐位校验首、中、尾。
        let loaded = try #require(try store.loadSession(owner: "octo", repo: "demo", sessionId: base.id))
        #expect(loaded.messages.count == 202)
        #expect(loaded.messages[0].content == "msg-0")
        #expect(loaded.messages[200].content == "msg-200")
        #expect(loaded.messages[201].content == "msg-201")
    }

    @Test("P1-1 增量保存后统计与全量重算一致")
    func jsonIncrementalSaveKeepsStatsConsistent() throws {
        let (store, root) = try makeIsolatedStore()
        defer { cleanup(root) }

        let base = makeSession(messageCount: 200)
        try store.saveSession(owner: "octo", repo: "demo", session: base)
        let afterFull = store.totalBytes
        store.reload()
        #expect(store.totalBytes == afterFull, "全量路径的统计 delta 必须与重算口径一致")

        let session = sessionAppending(
            ChatMessage(id: UUID(), role: .user, content: "msg-200", timestamp: Date()),
            to: base
        )
        try store.saveSession(owner: "octo", repo: "demo", session: session)
        // 先快照增量维护值再 reload：计数累加逻辑发生在保存内，reload 之后断言会掩盖
        // 维护值本身的错误（reload 全量重算总能得到正确值）。
        let sessionCountAfterSave = store.sessionCount
        let repoCountAfterSave = store.repoCount
        let afterIncrement = store.totalBytes
        store.reload()
        #expect(store.totalBytes == afterIncrement, "增量路径的统计 delta 必须与重算口径一致")
        #expect(sessionCountAfterSave == 1, "追加保存不得重复累加会话计数")
        #expect(repoCountAfterSave == 1)
        #expect(store.sessionCount == 1)
        #expect(store.repoCount == 1)
    }

    @Test("P1-1 消息数回退走整体重建并清掉多余 chunk")
    func jsonTruncatedSaveRebuildsAndCleansChunks() throws {
        let (store, root) = try makeIsolatedStore()
        defer { cleanup(root) }

        let base = makeSession(messageCount: 200)
        try store.saveSession(owner: "octo", repo: "demo", session: base)

        // 读盘失败降级时 VM 会以内存窗口整会话重存（persistedMessages ?? messages）。
        // 消息数回退必须整体重建：若残留尾部 chunk，读取端按 metadata 计数虽不会读到，
        // 但残留会污染下一次全量重建的目录大小统计。
        let truncated = ChatSession(
            id: base.id,
            title: base.title,
            createdAt: base.createdAt,
            updatedAt: base.updatedAt,
            messages: Array(base.messages[0..<12])
        )
        try store.saveSession(owner: "octo", repo: "demo", session: truncated)

        let loaded = try #require(try store.loadSession(owner: "octo", repo: "demo", sessionId: base.id))
        #expect(loaded.messages.count == 12)
        let chunksDir = root.appendingPathComponent("octo").appendingPathComponent("demo")
            .appendingPathComponent(base.id.uuidString).appendingPathComponent("chunks")
        let remaining = try FileManager.default.contentsOfDirectory(atPath: chunksDir.path).sorted()
        #expect(remaining == ["000000.json"], "回退重建后只应剩 1 个 chunk，实际：\(remaining)")
    }

    @Test("P1-1 消息数不变时只更新 metadata 不触碰 chunk")
    func jsonSameCountSaveSkipsChunks() throws {
        let (store, root) = try makeIsolatedStore()
        defer { cleanup(root) }

        // 21 条 = 1 个整满 chunk + 1 个含最后一条的非整块：同数保存若错误地按
        // oldCount 重写「受影响 chunk」，非整块 chunk 1 必然被触碰，正好暴露该缺陷
        // （200 条整除边界测不出来）。
        let base = makeSession(messageCount: 21)
        try store.saveSession(owner: "octo", repo: "demo", session: base)

        let oldDate = Date(timeIntervalSince1970: 1000)
        for index in 0..<2 { try setMtime(chunkURL(root, sessionId: base.id, index: index), to: oldDate) }

        // 取消 / 失败路径会以相同消息列表补存标题与时间戳：消息内容没变，chunk 不得重写。
        let renamed = ChatSession(
            id: base.id,
            title: "renamed",
            createdAt: base.createdAt,
            updatedAt: base.updatedAt.addingTimeInterval(5),
            messages: base.messages
        )
        try store.saveSession(owner: "octo", repo: "demo", session: renamed)

        for index in 0..<2 {
            #expect(
                try mtimeOf(chunkURL(root, sessionId: base.id, index: index)).timeIntervalSince(oldDate) < 1,
                "chunk \(index) 不应被同内容保存重写"
            )
        }
        let loaded = try #require(try store.loadSession(owner: "octo", repo: "demo", sessionId: base.id))
        #expect(loaded.title == "renamed")
        #expect(loaded.messages.count == 21)
    }

    @Test("P1-1 SQLite 追加保存保留已有行（rowid 不变）")
    func sqliteIncrementalSavePreservesExistingRows() throws {
        let (store, root) = try makeIsolatedSQLiteStore()
        defer { cleanup(root) }

        let base = makeSession(messageCount: 200)
        try store.saveSession(owner: "octo", repo: "demo", session: base)

        // base 落盘后再插入占位会话抬高全表 rowid 上限：旧实现删光重插时 SQLite 从
        // 剩余 max(rowid)+1 重新分配，占位必须插在 base 之后才能让重插的 rowid 落到
        // 新空间、与原值不同——否则删光后的重插会复用相同 rowid，破坏行为测不出来。
        let placeholder = makeSession(messageCount: 5)
        try store.saveSession(owner: "octo", repo: "other", session: placeholder)

        let reader = try makeReadonlyReader(root: root)
        let before = try sqliteRowidSnapshot(reader, sessionId: base.id)
        #expect(before.count == 200)

        let session = sessionAppending(
            ChatMessage(id: UUID(), role: .user, content: "msg-200", timestamp: Date()),
            to: base
        )
        try store.saveSession(owner: "octo", repo: "demo", session: session)

        let after = try sqliteRowidSnapshot(reader, sessionId: base.id)
        // 旧实现删光重插会让全部 rowid 变化；增量路径必须逐行原地保留。
        for (ordinal, rowid) in before {
            #expect(after[ordinal] == rowid, "ordinal \(ordinal) 的行不应被追加保存删掉重插")
        }
        #expect(after.count == 201)

        let loaded = try #require(try store.loadSession(owner: "octo", repo: "demo", sessionId: base.id))
        #expect(loaded.messages.count == 201)
        #expect(loaded.messages[0].content == "msg-0")
        #expect(loaded.messages[200].content == "msg-200")
    }

    @Test("P1-1 SQLite 消息数回退按传入内容重建并清掉多余 ordinal 行")
    func sqliteTruncatedSaveDeletesTailRows() throws {
        let (store, root) = try makeIsolatedSQLiteStore()
        defer { cleanup(root) }

        let base = makeSession(messageCount: 200)
        try store.saveSession(owner: "octo", repo: "demo", session: base)

        // 读盘失败降级的截断窗口：传入即权威——前缀必须按传入内容重写（而非保留旧
        // 内容），多余 ordinal 删掉，落盘状态与旧全量重插完全等价。传入消息用全新
        // 内容，才能区分「落盘传入值」和「落盘旧前缀」。
        let freshMessages = (0..<12).map { index in
            ChatMessage(id: UUID(), role: .user, content: "fresh-\(index)", timestamp: Date())
        }
        let truncated = ChatSession(
            id: base.id,
            title: base.title,
            createdAt: base.createdAt,
            updatedAt: base.updatedAt,
            messages: freshMessages
        )
        try store.saveSession(owner: "octo", repo: "demo", session: truncated)

        let loaded = try #require(try store.loadSession(owner: "octo", repo: "demo", sessionId: base.id))
        #expect(loaded.messages.count == 12)
        #expect(loaded.messages[0].content == "fresh-0", "前缀必须按传入内容落盘")
        #expect(loaded.messages[11].content == "fresh-11", "前缀必须按传入内容落盘")
    }

    @Test("P1-1 chunks 目录缺失时追加保存降级全量重建恢复前缀")
    func jsonMissingChunksDirRebuildsPrefixOnAppend() throws {
        let (store, root) = try makeIsolatedStore()
        defer { cleanup(root) }

        let base = makeSession(messageCount: 40)
        try store.saveSession(owner: "octo", repo: "demo", session: base)

        // 异常态：会话目录在、metadata 在，但前缀 chunk 已丢失（如外部清理误删）。
        // 增量写无法恢复前缀（旧全量重建路径可以），必须降级整体重建，否则追加后
        // [0, 40) 段永久读不回来——数据完整性优先于写入量优化。
        let chunksDir = root.appendingPathComponent("octo").appendingPathComponent("demo")
            .appendingPathComponent(base.id.uuidString).appendingPathComponent("chunks")
        try FileManager.default.removeItem(at: chunksDir)

        let session = sessionAppending(
            ChatMessage(id: UUID(), role: .user, content: "msg-40", timestamp: Date()),
            to: base
        )
        try store.saveSession(owner: "octo", repo: "demo", session: session)

        let loaded = try #require(try store.loadSession(owner: "octo", repo: "demo", sessionId: base.id))
        #expect(loaded.messages.count == 41)
        #expect(loaded.messages[0].content == "msg-0", "重建必须恢复丢失的前缀 chunk")
        #expect(loaded.messages[39].content == "msg-39")
        #expect(loaded.messages[40].content == "msg-40")
    }

    @Test("P1-1 metadata messageCount 损坏为负数时重建且不崩溃")
    func jsonNegativeMetadataCountRebuildsInsteadOfCrashing() throws {
        let (store, root) = try makeIsolatedStore()
        defer { cleanup(root) }

        let base = makeSession(messageCount: 30)
        try store.saveSession(owner: "octo", repo: "demo", session: base)

        // 模拟 metadata 可正常解码但 messageCount 被外部改坏为负：负 oldCount 若直接
        // 进入增量路径会产生负下标崩溃，必须归一化按损坏处理走整体重建。
        let metadataURL = root.appendingPathComponent("octo").appendingPathComponent("demo")
            .appendingPathComponent(base.id.uuidString).appendingPathComponent("metadata.json")
        var object = (try JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL), options: [])) as? [String: Any] ?? [:]
        object["messageCount"] = -5
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]).write(to: metadataURL)

        let session = sessionAppending(
            ChatMessage(id: UUID(), role: .user, content: "msg-30", timestamp: Date()),
            to: base
        )
        try store.saveSession(owner: "octo", repo: "demo", session: session)

        let loaded = try #require(try store.loadSession(owner: "octo", repo: "demo", sessionId: base.id))
        #expect(loaded.messages.count == 31)
        #expect(loaded.messages[0].content == "msg-0")
        #expect(loaded.messages[30].content == "msg-30")
    }
}
