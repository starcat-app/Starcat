//
//  DiskChatHistoryStore.swift
//  Starcat
//
//  AI 对话历史磁盘存储（HOM-70 / 2026-06-15 chunk 分片重构）。
//
//  模块职责：
//  - 把 `(owner, repo)` 维度的多 session 对话历史以 JSON 落盘到
//    `~/Library/Application Support/com.starcat.app/chat-history/<owner>/<repo>/`；
//  - 每个 session 拆成 metadata + chunks，避免首次进入聊天时整包读取大量 Markdown；
//  - 给 `RepoAIChatViewModel` 提供 session 列表、尾部页、向前分页、完整导出/发送历史；
//  - 暴露 `@Observable` 汇总量给设置页存储 Tab 渲染「对话历史 N 项 · XX MB」；
//  - LRU 淘汰：总占用 > 100 MB 时按 session metadata mtime 升序删。
//
//  目录布局：
//      chat-history/
//        <owner>/
//          <repo>/
//            index.json
//            <session-id>/
//              metadata.json
//              chunks/
//                000000.json     // 第 0...19 条消息
//                000001.json     // 第 20...39 条消息
//
//  关键约束：
//  1. 本项目未上线，无需兼容旧 `<session-id>.json` 单文件 schema；旧路径不再读取。
//  2. chunk 大小固定 20 条，正好对应 UI「加载更早消息」的一页，首屏只从尾部页切 2 条渲染。
//  3. `index.json` 仍是轻量列表缓存，不是 source of truth；损坏时从 session 目录重建。
//  4. 写入用临时目录再替换 session 目录，避免半写入留下缺 chunk 的 session。
//

import Foundation
import Observation

/// 对话历史存储错误。
enum DiskChatHistoryStoreError: LocalizedError {
    case applicationSupportUnavailable
    case invalidPathComponent(String)

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "无法定位对话历史目录，请重试或重启应用。"
        case .invalidPathComponent(let value):
            return "对话历史路径包含非法字符：\(value)。"
        }
    }
}

/// 从 chunk 化 session 中读取的一页消息。
struct ChatSessionPage: Equatable, Sendable {
    var session: ChatSession
    var messageStartIndex: Int
    var totalMessageCount: Int
}

/// AI 对话历史磁盘存储（线程：所有公开方法 `@MainActor`）。
@MainActor
@Observable
final class DiskChatHistoryStore {

    static let shared = DiskChatHistoryStore()

    /// 每个 chunk 固定 20 条消息。UI 点击「加载更早消息」也按这个粒度向前读取。
    nonisolated static let messagesPerChunk = 20

    private let maxTotalBytes: Int64 = 100 * 1024 * 1024 // 100 MB

    /// 全部 chat-history（index + metadata + chunks）总字节数。
    private(set) var totalBytes: Int64 = 0

    /// session 总数（按包含 `metadata.json` 的 session 目录计）。
    private(set) var sessionCount: Int = 0

    /// 已使用 chat 的仓库数（owner/repo 目录数）。
    private(set) var repoCount: Int = 0

    private let fileManager: FileManager
    private let rootOverride: URL?

    private var saveCountSinceLastSweep: Int = 0
    private let saveCountSweepThreshold: Int = 5

    private let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        enc.dateEncodingStrategy = .iso8601
        return enc
    }()

    private let decoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }()

    init(fileManager: FileManager = .default, rootOverride: URL? = nil) {
        self.fileManager = fileManager
        self.rootOverride = rootOverride
        reload()
    }

    // MARK: - Session 增删查改

    /// 列出某 repo 的所有 session 概要，按 `updatedAt` 倒序（最新在前）。
    func listSessions(owner: String, repo: String) throws -> [ChatSessionSummary] {
        let indexURL = try indexFile(owner: owner, repo: repo)

        if fileManager.fileExists(atPath: indexURL.path),
           let data = try? Data(contentsOf: indexURL),
           let index = try? decoder.decode(ChatSessionIndex.self, from: data) {
            return index.sessions.sorted { $0.updatedAt > $1.updatedAt }
        }

        AppLog.ai.warning("Chat history: index missing/corrupted, rebuilding owner=\(owner, privacy: .public) repo=\(repo, privacy: .public)")
        let rebuilt = try rebuildIndex(owner: owner, repo: repo)
        return rebuilt.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 常规命中路径在后台线程读取并解码 index，避免首次进入聊天面板时阻塞主线程。
    func listSessionsAsync(owner: String, repo: String) async throws -> [ChatSessionSummary] {
        let indexURL = try indexFile(owner: owner, repo: repo)
        let indexed = await Task.detached(priority: .userInitiated) {
            guard FileManager.default.fileExists(atPath: indexURL.path),
                  let data = try? Data(contentsOf: indexURL) else {
                return Optional<[ChatSessionSummary]>.none
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(ChatSessionIndex.self, from: data).sessions
        }.value

        if let indexed {
            return indexed.sorted { $0.updatedAt > $1.updatedAt }
        }
        return try listSessions(owner: owner, repo: repo)
    }

    /// 读取完整 session。发送请求与复制完整对话需要完整历史；普通首屏不要走这条。
    func loadSession(owner: String, repo: String, sessionId: UUID) throws -> ChatSession? {
        guard let metadata = try loadMetadata(owner: owner, repo: repo, sessionId: sessionId) else {
            return nil
        }
        do {
            let messages = try loadMessages(owner: owner, repo: repo, sessionId: sessionId, range: 0..<metadata.messageCount)
            touchSession(owner: owner, repo: repo, sessionId: sessionId)
            return metadata.makeSession(messages: messages)
        } catch {
            AppLog.ai.warning("Chat history: full load failed, removing owner=\(owner, privacy: .public) repo=\(repo, privacy: .public) sid=\(sessionId.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            try? deleteSession(owner: owner, repo: repo, sessionId: sessionId)
            return nil
        }
    }

    /// 后台读取并解码完整 session。用于发送前组装 prompt 历史和复制完整对话。
    func loadSessionAsync(owner: String, repo: String, sessionId: UUID) async throws -> ChatSession? {
        let sessionDir = try sessionDirectory(owner: owner, repo: repo, sessionId: sessionId)
        guard fileManager.fileExists(atPath: sessionDir.path) else { return nil }

        do {
            return try await Task.detached(priority: .userInitiated) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let metadataURL = sessionDir.appendingPathComponent("metadata.json")
                let metadata = try decoder.decode(ChatSessionMetadata.self, from: Data(contentsOf: metadataURL))
                let messages = try Self.loadMessagesDetached(
                    sessionDir: sessionDir,
                    range: 0..<metadata.messageCount,
                    decoder: decoder
                )
                try? FileManager.default.setAttributes(
                    [.modificationDate: Date()],
                    ofItemAtPath: metadataURL.path
                )
                return metadata.makeSession(messages: messages)
            }.value
        } catch {
            AppLog.ai.warning("Chat history: async full load failed, removing owner=\(owner, privacy: .public) repo=\(repo, privacy: .public) sid=\(sessionId.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            try? deleteSession(owner: owner, repo: repo, sessionId: sessionId)
            return nil
        }
    }

    /// 读取 session 尾部一页。`tailCount` 传 2 即首屏只渲染最近两条消息。
    func loadSessionTailAsync(owner: String, repo: String, sessionId: UUID, tailCount: Int) async throws -> ChatSessionPage? {
        let sessionDir = try sessionDirectory(owner: owner, repo: repo, sessionId: sessionId)
        guard fileManager.fileExists(atPath: sessionDir.path) else { return nil }

        do {
            return try await Task.detached(priority: .userInitiated) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let metadataURL = sessionDir.appendingPathComponent("metadata.json")
                let metadata = try decoder.decode(ChatSessionMetadata.self, from: Data(contentsOf: metadataURL))
                let start = max(0, metadata.messageCount - max(0, tailCount))
                let messages = try Self.loadMessagesDetached(
                    sessionDir: sessionDir,
                    range: start..<metadata.messageCount,
                    decoder: decoder
                )
                try? FileManager.default.setAttributes(
                    [.modificationDate: Date()],
                    ofItemAtPath: metadataURL.path
                )
                return ChatSessionPage(
                    session: metadata.makeSession(messages: messages),
                    messageStartIndex: start,
                    totalMessageCount: metadata.messageCount
                )
            }.value
        } catch {
            AppLog.ai.warning("Chat history: async tail load failed, removing owner=\(owner, privacy: .public) repo=\(repo, privacy: .public) sid=\(sessionId.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            try? deleteSession(owner: owner, repo: repo, sessionId: sessionId)
            return nil
        }
    }

    /// 读取 `[start, end)` 范围内的消息。调用方负责传入合法窗口；本方法会自动夹紧。
    func loadMessagesAsync(owner: String, repo: String, sessionId: UUID, start: Int, end: Int) async throws -> [ChatMessage] {
        let sessionDir = try sessionDirectory(owner: owner, repo: repo, sessionId: sessionId)
        guard fileManager.fileExists(atPath: sessionDir.path), start < end else { return [] }

        return try await Task.detached(priority: .userInitiated) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let metadataURL = sessionDir.appendingPathComponent("metadata.json")
            let metadata = try decoder.decode(ChatSessionMetadata.self, from: Data(contentsOf: metadataURL))
            let clampedStart = max(0, min(start, metadata.messageCount))
            let clampedEnd = max(clampedStart, min(end, metadata.messageCount))
            return try Self.loadMessagesDetached(
                sessionDir: sessionDir,
                range: clampedStart..<clampedEnd,
                decoder: decoder
            )
        }.value
    }

    /// 写入 / 覆盖整个 session。同时更新 `index.json`。
    func saveSession(owner: String, repo: String, session: ChatSession) throws {
        let dir = try projectDirectory(owner: owner, repo: repo)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let sessionDir = try sessionDirectory(owner: owner, repo: repo, sessionId: session.id)
        let tmpDir = dir.appendingPathComponent(".\(session.id.uuidString).tmp-\(UUID().uuidString)", isDirectory: true)
        let chunksDir = tmpDir.appendingPathComponent("chunks", isDirectory: true)
        try fileManager.createDirectory(at: chunksDir, withIntermediateDirectories: true)

        let metadata = ChatSessionMetadata(session: session, messageCount: session.messages.count)
        try encoder.encode(metadata).write(
            to: tmpDir.appendingPathComponent("metadata.json"),
            options: .atomic
        )

        for (chunkIndex, start) in stride(from: 0, to: session.messages.count, by: Self.messagesPerChunk).enumerated() {
            let end = min(start + Self.messagesPerChunk, session.messages.count)
            let chunk = ChatMessageChunk(startIndex: start, messages: Array(session.messages[start..<end]))
            try encoder.encode(chunk).write(
                to: chunksDir.appendingPathComponent(Self.chunkFileName(chunkIndex)),
                options: .atomic
            )
        }

        if fileManager.fileExists(atPath: sessionDir.path) {
            try fileManager.removeItem(at: sessionDir)
        }
        try fileManager.moveItem(at: tmpDir, to: sessionDir)

        let size = directorySize(sessionDir)
        try upsertIndex(
            owner: owner,
            repo: repo,
            summary: ChatSessionSummary(
                id: session.id,
                title: session.title,
                createdAt: session.createdAt,
                updatedAt: session.updatedAt,
                messageCount: session.messages.count,
                bytes: size
            )
        )

        saveCountSinceLastSweep += 1
        reload()
        try maybeTriggerLRUSweep()
    }

    /// 删某 session（用户主动“删对话”入口）。
    func deleteSession(owner: String, repo: String, sessionId: UUID) throws {
        let dir = try sessionDirectory(owner: owner, repo: repo, sessionId: sessionId)
        try? fileManager.removeItem(at: dir)
        try syncIndexAfterRemove(owner: owner, repo: repo, sessionId: sessionId)
        try? removeEmptyProjectDirectory(owner: owner, repo: repo)
        reload()
    }

    /// 删某 repo 全部 session。
    func deleteAllForRepo(owner: String, repo: String) throws {
        let dir = try projectDirectory(owner: owner, repo: repo)
        if fileManager.fileExists(atPath: dir.path) {
            try fileManager.removeItem(at: dir)
        }
        try? removeEmptyOwnerDirectory(owner: owner)
        reload()
    }

    /// 清掉全部 chat-history。
    func deleteEverything() throws {
        let root = try rootURL()
        if fileManager.fileExists(atPath: root.path) {
            try fileManager.removeItem(at: root)
        }
        saveCountSinceLastSweep = 0
        reload()
    }

    // MARK: - LRU sweep

    func lruSweep() throws {
        let root = try rootURL()
        guard fileManager.fileExists(atPath: root.path) else { return }

        var entries: [(url: URL, owner: String, repo: String, sessionId: UUID, mtime: Date, size: Int64)] = []
        for (owner, repo, sessionDir, sessionId) in collectSessionDirectories(under: root) {
            let metadataURL = sessionDir.appendingPathComponent("metadata.json")
            let mtime = (try? metadataURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            entries.append((sessionDir, owner, repo, sessionId, mtime, directorySize(sessionDir)))
        }

        var bytes = entries.reduce(0) { $0 + $1.size }
        guard bytes > maxTotalBytes else {
            saveCountSinceLastSweep = 0
            return
        }

        entries.sort { $0.mtime < $1.mtime }
        for entry in entries {
            guard bytes > maxTotalBytes else { break }
            try? fileManager.removeItem(at: entry.url)
            try? syncIndexAfterRemove(owner: entry.owner, repo: entry.repo, sessionId: entry.sessionId)
            bytes -= entry.size
        }

        cleanEmptyDirectories()
        saveCountSinceLastSweep = 0
        reload()
    }

    // MARK: - 索引维护

    @discardableResult
    func rebuildIndex(owner: String, repo: String) throws -> [ChatSessionSummary] {
        let dir = try projectDirectory(owner: owner, repo: repo)
        guard fileManager.fileExists(atPath: dir.path) else { return [] }

        let children = (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var summaries: [ChatSessionSummary] = []
        for sessionDir in children where sessionDir.hasDirectoryPath {
            guard let sessionId = UUID(uuidString: sessionDir.lastPathComponent),
                  let metadata = try? readMetadata(at: sessionDir.appendingPathComponent("metadata.json")) else {
                continue
            }
            summaries.append(ChatSessionSummary(
                id: sessionId,
                title: metadata.title,
                createdAt: metadata.createdAt,
                updatedAt: metadata.updatedAt,
                messageCount: metadata.messageCount,
                bytes: directorySize(sessionDir)
            ))
        }

        let index = ChatSessionIndex(sessions: summaries)
        let indexURL = try indexFile(owner: owner, repo: repo)
        try encoder.encode(index).write(to: indexURL, options: .atomic)
        return summaries
    }

    private func upsertIndex(owner: String, repo: String, summary: ChatSessionSummary) throws {
        let indexURL = try indexFile(owner: owner, repo: repo)
        var index: ChatSessionIndex
        if fileManager.fileExists(atPath: indexURL.path),
           let data = try? Data(contentsOf: indexURL),
           let existing = try? decoder.decode(ChatSessionIndex.self, from: data) {
            index = existing
        } else {
            index = ChatSessionIndex(sessions: [])
        }

        if let pos = index.sessions.firstIndex(where: { $0.id == summary.id }) {
            index.sessions[pos] = summary
        } else {
            index.sessions.append(summary)
        }

        try encoder.encode(index).write(to: indexURL, options: .atomic)
    }

    private func syncIndexAfterRemove(owner: String, repo: String, sessionId: UUID) throws {
        let indexURL = try indexFile(owner: owner, repo: repo)
        guard fileManager.fileExists(atPath: indexURL.path),
              let data = try? Data(contentsOf: indexURL),
              var index = try? decoder.decode(ChatSessionIndex.self, from: data)
        else { return }

        index.sessions.removeAll { $0.id == sessionId }
        if index.sessions.isEmpty {
            try? fileManager.removeItem(at: indexURL)
        } else {
            try encoder.encode(index).write(to: indexURL, options: .atomic)
        }
    }

    // MARK: - 汇总统计

    func reload() {
        var bytes: Int64 = 0
        var sessions = 0
        var repos = 0

        guard let root = try? rootURL(),
              fileManager.fileExists(atPath: root.path) else {
            totalBytes = 0
            sessionCount = 0
            repoCount = 0
            return
        }

        for (_, _, sessionDir, _) in collectSessionDirectories(under: root) {
            bytes += directorySize(sessionDir)
            sessions += 1
        }

        let ownerDirs = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for ownerDir in ownerDirs where ownerDir.hasDirectoryPath {
            let repoDirs = (try? fileManager.contentsOfDirectory(at: ownerDir, includingPropertiesForKeys: nil)) ?? []
            for repoDir in repoDirs where repoDir.hasDirectoryPath {
                let children = (try? fileManager.contentsOfDirectory(at: repoDir, includingPropertiesForKeys: nil)) ?? []
                if children.contains(where: { $0.hasDirectoryPath && UUID(uuidString: $0.lastPathComponent) != nil }) {
                    repos += 1
                }
                if let indexSize = try? repoDir.appendingPathComponent("index.json").resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    bytes += Int64(indexSize)
                }
            }
        }

        totalBytes = bytes
        sessionCount = sessions
        repoCount = repos
    }

    // MARK: - 私有读取

    private func loadMetadata(owner: String, repo: String, sessionId: UUID) throws -> ChatSessionMetadata? {
        let metadataURL = try metadataFile(owner: owner, repo: repo, sessionId: sessionId)
        guard fileManager.fileExists(atPath: metadataURL.path) else { return nil }
        do {
            return try readMetadata(at: metadataURL)
        } catch {
            AppLog.ai.warning("Chat history: metadata decode failed, removing sid=\(sessionId.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            try? deleteSession(owner: owner, repo: repo, sessionId: sessionId)
            return nil
        }
    }

    private func readMetadata(at url: URL) throws -> ChatSessionMetadata {
        try decoder.decode(ChatSessionMetadata.self, from: Data(contentsOf: url))
    }

    private func loadMessages(owner: String, repo: String, sessionId: UUID, range: Range<Int>) throws -> [ChatMessage] {
        let sessionDir = try sessionDirectory(owner: owner, repo: repo, sessionId: sessionId)
        return try Self.loadMessagesDetached(sessionDir: sessionDir, range: range, decoder: decoder)
    }

    nonisolated private static func loadMessagesDetached(sessionDir: URL, range: Range<Int>, decoder: JSONDecoder) throws -> [ChatMessage] {
        guard !range.isEmpty else { return [] }
        let startChunk = range.lowerBound / messagesPerChunk
        let endChunk = (range.upperBound - 1) / messagesPerChunk
        var result: [ChatMessage] = []
        result.reserveCapacity(range.count)

        for chunkIndex in startChunk...endChunk {
            let url = sessionDir
                .appendingPathComponent("chunks", isDirectory: true)
                .appendingPathComponent(chunkFileName(chunkIndex))
            let chunk = try decoder.decode(ChatMessageChunk.self, from: Data(contentsOf: url))
            let chunkStart = chunk.startIndex
            for (offset, message) in chunk.messages.enumerated() {
                let absoluteIndex = chunkStart + offset
                if range.contains(absoluteIndex) {
                    result.append(message)
                }
            }
        }
        return result
    }

    private func touchSession(owner: String, repo: String, sessionId: UUID) {
        guard let metadataURL = try? metadataFile(owner: owner, repo: repo, sessionId: sessionId) else { return }
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: metadataURL.path)
    }

    // MARK: - 文件系统辅助

    private func maybeTriggerLRUSweep() throws {
        guard saveCountSinceLastSweep >= saveCountSweepThreshold else { return }
        try lruSweep()
    }

    private func cleanEmptyDirectories() {
        guard let root = try? rootURL() else { return }
        let ownerDirs = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for ownerDir in ownerDirs where ownerDir.hasDirectoryPath {
            let repoDirs = (try? fileManager.contentsOfDirectory(at: ownerDir, includingPropertiesForKeys: nil)) ?? []
            for repoDir in repoDirs where repoDir.hasDirectoryPath {
                let files = (try? fileManager.contentsOfDirectory(at: repoDir, includingPropertiesForKeys: nil)) ?? []
                if files.isEmpty {
                    try? fileManager.removeItem(at: repoDir)
                }
            }
            let remainingRepos = (try? fileManager.contentsOfDirectory(at: ownerDir, includingPropertiesForKeys: nil)) ?? []
            if remainingRepos.isEmpty {
                try? fileManager.removeItem(at: ownerDir)
            }
        }
    }

    private func removeEmptyProjectDirectory(owner: String, repo: String) throws {
        let dir = try projectDirectory(owner: owner, repo: repo)
        let files = (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        if files.isEmpty {
            try? fileManager.removeItem(at: dir)
        }
        try? removeEmptyOwnerDirectory(owner: owner)
    }

    private func removeEmptyOwnerDirectory(owner: String) throws {
        let owners = try ownerDirectory(owner: owner)
        let children = (try? fileManager.contentsOfDirectory(at: owners, includingPropertiesForKeys: nil)) ?? []
        if children.isEmpty {
            try? fileManager.removeItem(at: owners)
        }
    }

    private func directorySize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        while let file = enumerator?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    private func collectSessionDirectories(under root: URL) -> [(owner: String, repo: String, sessionDir: URL, sessionId: UUID)] {
        var result: [(String, String, URL, UUID)] = []
        let ownerDirs = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for ownerDir in ownerDirs where ownerDir.hasDirectoryPath {
            let owner = ownerDir.lastPathComponent
            let repoDirs = (try? fileManager.contentsOfDirectory(at: ownerDir, includingPropertiesForKeys: nil)) ?? []
            for repoDir in repoDirs where repoDir.hasDirectoryPath {
                let repo = repoDir.lastPathComponent
                let sessionDirs = (try? fileManager.contentsOfDirectory(at: repoDir, includingPropertiesForKeys: nil)) ?? []
                for sessionDir in sessionDirs where sessionDir.hasDirectoryPath {
                    guard let sessionId = UUID(uuidString: sessionDir.lastPathComponent),
                          fileManager.fileExists(atPath: sessionDir.appendingPathComponent("metadata.json").path) else {
                        continue
                    }
                    result.append((owner, repo, sessionDir, sessionId))
                }
            }
        }
        return result
    }

    // MARK: - 路径构造

    private func rootURL() throws -> URL {
        if let rootOverride { return rootOverride }
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw DiskChatHistoryStoreError.applicationSupportUnavailable
        }
        return appSupport
            .appendingPathComponent(AppConstants.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("chat-history", isDirectory: true)
    }

    private func ownerDirectory(owner: String) throws -> URL {
        try assertSafePathComponent(owner)
        return try rootURL().appendingPathComponent(owner, isDirectory: true)
    }

    private func projectDirectory(owner: String, repo: String) throws -> URL {
        try assertSafePathComponent(repo)
        return try ownerDirectory(owner: owner).appendingPathComponent(repo, isDirectory: true)
    }

    private func indexFile(owner: String, repo: String) throws -> URL {
        try projectDirectory(owner: owner, repo: repo).appendingPathComponent("index.json")
    }

    private func sessionDirectory(owner: String, repo: String, sessionId: UUID) throws -> URL {
        try projectDirectory(owner: owner, repo: repo)
            .appendingPathComponent(sessionId.uuidString, isDirectory: true)
    }

    private func metadataFile(owner: String, repo: String, sessionId: UUID) throws -> URL {
        try sessionDirectory(owner: owner, repo: repo, sessionId: sessionId)
            .appendingPathComponent("metadata.json")
    }

    nonisolated private static func chunkFileName(_ index: Int) -> String {
        String(format: "%06d.json", index)
    }

    /// 防御 path traversal：禁止 `.` / `..` / `/` 出现在 path component 中。
    private func assertSafePathComponent(_ value: String) throws {
        if value.isEmpty || value.contains("/") || value == "." || value == ".." {
            throw DiskChatHistoryStoreError.invalidPathComponent(value)
        }
    }
}

// MARK: - 内部 schema

private struct ChatSessionIndex: Codable {
    var sessions: [ChatSessionSummary]
}

private struct ChatSessionMetadata: Codable {
    let id: UUID
    var title: String
    let createdAt: Date
    var updatedAt: Date
    var carriedOverSummary: String?
    var messageCount: Int

    init(session: ChatSession, messageCount: Int) {
        self.id = session.id
        self.title = session.title
        self.createdAt = session.createdAt
        self.updatedAt = session.updatedAt
        self.carriedOverSummary = session.carriedOverSummary
        self.messageCount = messageCount
    }

    func makeSession(messages: [ChatMessage]) -> ChatSession {
        ChatSession(
            id: id,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            messages: messages,
            carriedOverSummary: carriedOverSummary
        )
    }
}

private struct ChatMessageChunk: Codable {
    let startIndex: Int
    var messages: [ChatMessage]
}
