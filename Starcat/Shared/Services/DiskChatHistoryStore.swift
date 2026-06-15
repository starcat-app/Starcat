//
//  DiskChatHistoryStore.swift
//  Starcat
//
//  AI 对话历史存储 facade（HOM-70 / 2026-06-15 双后端）。
//
//  模块职责：
//  - 保持 `RepoAIChatViewModel` 依赖的 `DiskChatHistoryStore` API 不变；
//  - 支持两种本地后端：
//    1. JSON chunk 文件：保留当前 metadata + chunks 的磁盘文件实现；
//    2. 独立 SQLite：`chat-history.sqlite`，与主业务库完全分离；
//  - 设置页继续读取 `totalBytes/sessionCount/repoCount` 汇总量，清理入口仍走同一 facade。
//
//  关键约束：
//  - SQLite 后端不接入主库 `DatabaseManager` / `DatabaseMigrationsV1`，避免大量聊天历史
//    与 stars、tags、README 等主业务读写抢同一个 SQLite writer。
//  - 本项目未上线，无需兼容已删除旧 schema；JSON chunk 作为一个正式后端保留。
//  - facade 是 `@MainActor @Observable`，后端可以在内部把重 IO 放进 detached task。
//

import Foundation
import GRDB
import Observation

/// 对话历史存储错误。
enum DiskChatHistoryStoreError: LocalizedError {
    case applicationSupportUnavailable
    case invalidPathComponent(String)

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return String(localized: "store.chatHistory.error.applicationSupportUnavailable")
        case .invalidPathComponent(let value):
            return String(format: String(localized: "store.chatHistory.error.invalidPathComponentFormat"), value)
        }
    }
}

/// AI 对话历史存储后端。
enum ChatHistoryStorageKind: String, CaseIterable, Identifiable, Sendable, Codable {
    case jsonFiles
    case sqlite

    var id: String { rawValue }

    var displayNameKey: String {
        switch self {
        case .jsonFiles: return "settings.storage.chatHistoryBackend.jsonFiles"
        case .sqlite:    return "settings.storage.chatHistoryBackend.sqlite"
        }
    }
}

/// 从 session 中读取的一页消息。
struct ChatSessionPage: Equatable, Sendable {
    var session: ChatSession
    var messageStartIndex: Int
    var totalMessageCount: Int
}

@MainActor
private protocol ChatHistoryStorageBackend: AnyObject {
    var totalBytes: Int64 { get }
    var sessionCount: Int { get }
    var repoCount: Int { get }

    func reload()
    func listSessions(owner: String, repo: String) throws -> [ChatSessionSummary]
    func listSessionsAsync(owner: String, repo: String) async throws -> [ChatSessionSummary]
    func loadSession(owner: String, repo: String, sessionId: UUID) throws -> ChatSession?
    func loadSessionAsync(owner: String, repo: String, sessionId: UUID) async throws -> ChatSession?
    func loadSessionTailAsync(owner: String, repo: String, sessionId: UUID, tailCount: Int) async throws -> ChatSessionPage?
    func loadMessagesAsync(owner: String, repo: String, sessionId: UUID, start: Int, end: Int) async throws -> [ChatMessage]
    func saveSession(owner: String, repo: String, session: ChatSession) throws
    func deleteSession(owner: String, repo: String, sessionId: UUID) throws
    func deleteAllForRepo(owner: String, repo: String) throws
    func deleteEverything() throws
    func lruSweep() throws
}

/// AI 对话历史存储 facade（线程：所有公开方法 `@MainActor`）。
@MainActor
@Observable
final class DiskChatHistoryStore {

    static let shared = DiskChatHistoryStore(storageKind: AppSettings.shared.chatHistoryStorageKind)

    /// 每次「加载更早消息」的页大小。JSON 后端也用它作为 chunk 大小。
    nonisolated static let messagesPerChunk = 20

    private let backend: ChatHistoryStorageBackend
    let storageKind: ChatHistoryStorageKind

    var totalBytes: Int64 { backend.totalBytes }
    var sessionCount: Int { backend.sessionCount }
    var repoCount: Int { backend.repoCount }

    init(
        fileManager: FileManager = .default,
        rootOverride: URL? = nil,
        storageKind: ChatHistoryStorageKind = .jsonFiles
    ) {
        self.storageKind = storageKind
        switch storageKind {
        case .jsonFiles:
            self.backend = JSONChatHistoryStorageBackend(fileManager: fileManager, rootOverride: rootOverride)
        case .sqlite:
            self.backend = SQLiteChatHistoryStorageBackend(fileManager: fileManager, rootOverride: rootOverride)
        }
        backend.reload()
    }

    func reload() {
        backend.reload()
    }

    func listSessions(owner: String, repo: String) throws -> [ChatSessionSummary] {
        try backend.listSessions(owner: owner, repo: repo)
    }

    func listSessionsAsync(owner: String, repo: String) async throws -> [ChatSessionSummary] {
        try await backend.listSessionsAsync(owner: owner, repo: repo)
    }

    func loadSession(owner: String, repo: String, sessionId: UUID) throws -> ChatSession? {
        try backend.loadSession(owner: owner, repo: repo, sessionId: sessionId)
    }

    func loadSessionAsync(owner: String, repo: String, sessionId: UUID) async throws -> ChatSession? {
        try await backend.loadSessionAsync(owner: owner, repo: repo, sessionId: sessionId)
    }

    func loadSessionTailAsync(owner: String, repo: String, sessionId: UUID, tailCount: Int) async throws -> ChatSessionPage? {
        try await backend.loadSessionTailAsync(owner: owner, repo: repo, sessionId: sessionId, tailCount: tailCount)
    }

    func loadMessagesAsync(owner: String, repo: String, sessionId: UUID, start: Int, end: Int) async throws -> [ChatMessage] {
        try await backend.loadMessagesAsync(owner: owner, repo: repo, sessionId: sessionId, start: start, end: end)
    }

    func saveSession(owner: String, repo: String, session: ChatSession) throws {
        try backend.saveSession(owner: owner, repo: repo, session: session)
    }

    func deleteSession(owner: String, repo: String, sessionId: UUID) throws {
        try backend.deleteSession(owner: owner, repo: repo, sessionId: sessionId)
    }

    func deleteAllForRepo(owner: String, repo: String) throws {
        try backend.deleteAllForRepo(owner: owner, repo: repo)
    }

    func deleteEverything() throws {
        try backend.deleteEverything()
    }

    func lruSweep() throws {
        try backend.lruSweep()
    }
}

// MARK: - JSON chunk 后端

@MainActor
private final class JSONChatHistoryStorageBackend: ChatHistoryStorageBackend {

    private let maxTotalBytes: Int64 = 100 * 1024 * 1024

    private(set) var totalBytes: Int64 = 0
    private(set) var sessionCount: Int = 0
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
    }

    func listSessions(owner: String, repo: String) throws -> [ChatSessionSummary] {
        let indexURL = try indexFile(owner: owner, repo: repo)

        if fileManager.fileExists(atPath: indexURL.path),
           let data = try? Data(contentsOf: indexURL),
           let index = try? decoder.decode(ChatSessionIndex.self, from: data) {
            return index.sessions.sorted { $0.updatedAt > $1.updatedAt }
        }

        AppLog.ai.warning("Chat history JSON: index missing/corrupted, rebuilding owner=\(owner, privacy: .public) repo=\(repo, privacy: .public)")
        let rebuilt = try rebuildIndex(owner: owner, repo: repo)
        return rebuilt.sorted { $0.updatedAt > $1.updatedAt }
    }

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

    func loadSession(owner: String, repo: String, sessionId: UUID) throws -> ChatSession? {
        guard let metadata = try loadMetadata(owner: owner, repo: repo, sessionId: sessionId) else {
            return nil
        }
        do {
            let messages = try loadMessages(owner: owner, repo: repo, sessionId: sessionId, range: 0..<metadata.messageCount)
            touchSession(owner: owner, repo: repo, sessionId: sessionId)
            return metadata.makeSession(messages: messages)
        } catch {
            AppLog.ai.warning("Chat history JSON: full load failed, removing sid=\(sessionId.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            try? deleteSession(owner: owner, repo: repo, sessionId: sessionId)
            return nil
        }
    }

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
            AppLog.ai.warning("Chat history JSON: async full load failed, removing sid=\(sessionId.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            try? deleteSession(owner: owner, repo: repo, sessionId: sessionId)
            return nil
        }
    }

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
            AppLog.ai.warning("Chat history JSON: async tail load failed, removing sid=\(sessionId.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            try? deleteSession(owner: owner, repo: repo, sessionId: sessionId)
            return nil
        }
    }

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

        for (chunkIndex, start) in stride(from: 0, to: session.messages.count, by: DiskChatHistoryStore.messagesPerChunk).enumerated() {
            let end = min(start + DiskChatHistoryStore.messagesPerChunk, session.messages.count)
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

    func deleteSession(owner: String, repo: String, sessionId: UUID) throws {
        let dir = try sessionDirectory(owner: owner, repo: repo, sessionId: sessionId)
        try? fileManager.removeItem(at: dir)
        try syncIndexAfterRemove(owner: owner, repo: repo, sessionId: sessionId)
        try? removeEmptyProjectDirectory(owner: owner, repo: repo)
        reload()
    }

    func deleteAllForRepo(owner: String, repo: String) throws {
        let dir = try projectDirectory(owner: owner, repo: repo)
        if fileManager.fileExists(atPath: dir.path) {
            try fileManager.removeItem(at: dir)
        }
        try? removeEmptyOwnerDirectory(owner: owner)
        reload()
    }

    func deleteEverything() throws {
        let root = try rootURL()
        if fileManager.fileExists(atPath: root.path) {
            try fileManager.removeItem(at: root)
        }
        saveCountSinceLastSweep = 0
        reload()
    }

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

    private func loadMetadata(owner: String, repo: String, sessionId: UUID) throws -> ChatSessionMetadata? {
        let metadataURL = try metadataFile(owner: owner, repo: repo, sessionId: sessionId)
        guard fileManager.fileExists(atPath: metadataURL.path) else { return nil }
        do {
            return try readMetadata(at: metadataURL)
        } catch {
            AppLog.ai.warning("Chat history JSON: metadata decode failed, removing sid=\(sessionId.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
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
        let startChunk = range.lowerBound / DiskChatHistoryStore.messagesPerChunk
        let endChunk = (range.upperBound - 1) / DiskChatHistoryStore.messagesPerChunk
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

    private func assertSafePathComponent(_ value: String) throws {
        if value.isEmpty || value.contains("/") || value == "." || value == ".." {
            throw DiskChatHistoryStoreError.invalidPathComponent(value)
        }
    }
}

// MARK: - SQLite 后端

@MainActor
private final class SQLiteChatHistoryStorageBackend: ChatHistoryStorageBackend {

    private let maxTotalBytes: Int64 = 100 * 1024 * 1024

    private(set) var totalBytes: Int64 = 0
    private(set) var sessionCount: Int = 0
    private(set) var repoCount: Int = 0

    private let fileManager: FileManager
    private let rootOverride: URL?
    private let dbQueue: DatabaseQueue?
    private let dbURL: URL?

    init(fileManager: FileManager = .default, rootOverride: URL? = nil) {
        self.fileManager = fileManager
        self.rootOverride = rootOverride

        do {
            let root = try Self.resolveRootURL(fileManager: fileManager, rootOverride: rootOverride)
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            let url = root.appendingPathComponent("chat-history.sqlite")
            var config = Configuration()
            config.prepareDatabase { db in
                try db.execute(sql: "PRAGMA foreign_keys = ON")
                try db.execute(sql: "PRAGMA journal_mode = WAL")
            }
            let queue = try DatabaseQueue(path: url.path, configuration: config)
            try Self.runMigrations(on: queue)
            self.dbURL = url
            self.dbQueue = queue
        } catch {
            AppLog.ai.error("Chat history SQLite open failed: \(error.localizedDescription, privacy: .public)")
            self.dbURL = nil
            self.dbQueue = nil
        }
    }

    func listSessions(owner: String, repo: String) throws -> [ChatSessionSummary] {
        guard let dbQueue else { return [] }
        return try dbQueue.read { db in
            try ChatSessionSQLRow
                .filter(Column("owner") == owner && Column("repo") == repo)
                .order(Column("updated_at").desc)
                .fetchAll(db)
                .map(\.summary)
        }
    }

    func listSessionsAsync(owner: String, repo: String) async throws -> [ChatSessionSummary] {
        try listSessions(owner: owner, repo: repo)
    }

    func loadSession(owner: String, repo: String, sessionId: UUID) throws -> ChatSession? {
        guard let dbQueue else { return nil }
        return try dbQueue.read { db in
            guard let row = try Self.sessionRow(db: db, owner: owner, repo: repo, sessionId: sessionId) else {
                return nil
            }
            let messages = try Self.messages(db: db, sessionId: sessionId, start: 0, end: row.messageCount)
            return row.makeSession(messages: messages)
        }
    }

    func loadSessionAsync(owner: String, repo: String, sessionId: UUID) async throws -> ChatSession? {
        try loadSession(owner: owner, repo: repo, sessionId: sessionId)
    }

    func loadSessionTailAsync(owner: String, repo: String, sessionId: UUID, tailCount: Int) async throws -> ChatSessionPage? {
        guard let dbQueue else { return nil }
        return try await dbQueue.read { db in
            guard let row = try Self.sessionRow(db: db, owner: owner, repo: repo, sessionId: sessionId) else {
                return nil
            }
            let start = max(0, row.messageCount - max(0, tailCount))
            let tail = try Self.messages(db: db, sessionId: sessionId, start: start, end: row.messageCount)
            return ChatSessionPage(
                session: row.makeSession(messages: tail),
                messageStartIndex: start,
                totalMessageCount: row.messageCount
            )
        }
    }

    func loadMessagesAsync(owner _: String, repo _: String, sessionId: UUID, start: Int, end: Int) async throws -> [ChatMessage] {
        guard let dbQueue, start < end else { return [] }
        return try await dbQueue.read { db in
            try Self.messages(db: db, sessionId: sessionId, start: start, end: end)
        }
    }

    func saveSession(owner: String, repo: String, session: ChatSession) throws {
        guard let dbQueue else { return }
        try dbQueue.write { db in
            var sessionRow = ChatSessionSQLRow(
                id: session.id.uuidString,
                owner: owner,
                repo: repo,
                title: session.title,
                createdAt: session.createdAt.timeIntervalSince1970,
                updatedAt: session.updatedAt.timeIntervalSince1970,
                carriedOverSummary: session.carriedOverSummary,
                messageCount: session.messages.count
            )
            try sessionRow.save(db)

            try ChatMessageSQLRow
                .filter(Column("session_id") == session.id.uuidString)
                .deleteAll(db)

            for (index, message) in session.messages.enumerated() {
                var messageRow = ChatMessageSQLRow(
                    sessionId: session.id.uuidString,
                    ordinal: index,
                    id: message.id.uuidString,
                    role: message.role.rawValue,
                    content: message.content,
                    timestamp: message.timestamp.timeIntervalSince1970
                )
                try messageRow.insert(db)
            }
        }
        reload()
        try lruSweep()
    }

    func deleteSession(owner _: String, repo _: String, sessionId: UUID) throws {
        guard let dbQueue else { return }
        try dbQueue.write { db in
            try ChatSessionSQLRow
                .filter(Column("id") == sessionId.uuidString)
                .deleteAll(db)
        }
        reload()
    }

    func deleteAllForRepo(owner: String, repo: String) throws {
        guard let dbQueue else { return }
        try dbQueue.write { db in
            try ChatSessionSQLRow
                .filter(Column("owner") == owner && Column("repo") == repo)
                .deleteAll(db)
        }
        reload()
    }

    func deleteEverything() throws {
        guard let dbQueue else { return }
        _ = try dbQueue.write { db in
            try ChatMessageSQLRow.deleteAll(db)
            try ChatSessionSQLRow.deleteAll(db)
        }
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
        }
        reload()
    }

    func lruSweep() throws {
        guard totalBytes > maxTotalBytes, let dbQueue else { return }
        let dbURL = dbURL
        _ = try dbQueue.write { db in
            while Self.databaseFileSize(dbURL: dbURL) > maxTotalBytes {
                guard let oldest = try ChatSessionSQLRow
                    .order(Column("updated_at").asc)
                    .fetchOne(db) else {
                    break
                }
                try ChatSessionSQLRow
                    .filter(Column("id") == oldest.id)
                    .deleteAll(db)
            }
        }
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
        }
        reload()
    }

    func reload() {
        guard let dbQueue else {
            totalBytes = 0
            sessionCount = 0
            repoCount = 0
            return
        }

        do {
            let stats = try dbQueue.read { db in
                let sessions = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chat_sessions") ?? 0
                let repos = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM (SELECT owner, repo FROM chat_sessions GROUP BY owner, repo)") ?? 0
                return (sessions, repos)
            }
            totalBytes = databaseFileSize()
            sessionCount = stats.0
            repoCount = stats.1
        } catch {
            AppLog.ai.warning("Chat history SQLite reload failed: \(error.localizedDescription, privacy: .public)")
            totalBytes = databaseFileSize()
            sessionCount = 0
            repoCount = 0
        }
    }

    private static func resolveRootURL(fileManager: FileManager, rootOverride: URL?) throws -> URL {
        if let rootOverride { return rootOverride }
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw DiskChatHistoryStoreError.applicationSupportUnavailable
        }
        return appSupport
            .appendingPathComponent(AppConstants.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("chat-history", isDirectory: true)
    }

    private static func runMigrations(on writer: DatabaseWriter) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-chat-history-sqlite") { db in
            try db.create(table: "chat_sessions", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("owner", .text).notNull()
                table.column("repo", .text).notNull()
                table.column("title", .text).notNull()
                table.column("created_at", .double).notNull()
                table.column("updated_at", .double).notNull()
                table.column("carried_over_summary", .text)
                table.column("message_count", .integer).notNull()
            }

            try db.create(table: "chat_messages", ifNotExists: true) { table in
                table.column("session_id", .text).notNull()
                    .references("chat_sessions", column: "id", onDelete: .cascade)
                table.column("ordinal", .integer).notNull()
                table.column("id", .text).notNull()
                table.column("role", .text).notNull()
                table.column("content", .text).notNull()
                table.column("timestamp", .double).notNull()
                table.primaryKey(["session_id", "ordinal"])
            }

            try db.create(index: "idx_chat_sessions_repo_updated", on: "chat_sessions", columns: ["owner", "repo", "updated_at"])
            try db.create(index: "idx_chat_messages_session_ordinal", on: "chat_messages", columns: ["session_id", "ordinal"])
        }
        try migrator.migrate(writer)
    }

    nonisolated private static func sessionRow(db: Database, owner: String, repo: String, sessionId: UUID) throws -> ChatSessionSQLRow? {
        try ChatSessionSQLRow
            .filter(Column("id") == sessionId.uuidString && Column("owner") == owner && Column("repo") == repo)
            .fetchOne(db)
    }

    nonisolated private static func messages(db: Database, sessionId: UUID, start: Int, end: Int) throws -> [ChatMessage] {
        guard start < end else { return [] }
        return try ChatMessageSQLRow
            .filter(Column("session_id") == sessionId.uuidString && Column("ordinal") >= start && Column("ordinal") < end)
            .order(Column("ordinal").asc)
            .fetchAll(db)
            .map(\.message)
    }

    private func databaseFileSize() -> Int64 {
        Self.databaseFileSize(dbURL: dbURL)
    }

    nonisolated private static func databaseFileSize(dbURL: URL?) -> Int64 {
        guard let dbURL else { return 0 }
        let urls = [
            dbURL,
            URL(fileURLWithPath: dbURL.path + "-wal"),
            URL(fileURLWithPath: dbURL.path + "-shm")
        ]
        return urls.reduce(Int64(0)) { partial, url in
            partial + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}

// MARK: - JSON schema

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

// MARK: - SQLite rows

private struct ChatSessionSQLRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "chat_sessions"

    var id: String
    var owner: String
    var repo: String
    var title: String
    var createdAt: Double
    var updatedAt: Double
    var carriedOverSummary: String?
    var messageCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case owner
        case repo
        case title
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case carriedOverSummary = "carried_over_summary"
        case messageCount = "message_count"
    }

    var summary: ChatSessionSummary {
        ChatSessionSummary(
            id: UUID(uuidString: id) ?? UUID(),
            title: title,
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            messageCount: messageCount,
            bytes: 0
        )
    }

    func makeSession(messages: [ChatMessage]) -> ChatSession {
        ChatSession(
            id: UUID(uuidString: id) ?? UUID(),
            title: title,
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            messages: messages,
            carriedOverSummary: carriedOverSummary
        )
    }
}

private struct ChatMessageSQLRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "chat_messages"

    var sessionId: String
    var ordinal: Int
    var id: String
    var role: String
    var content: String
    var timestamp: Double

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case ordinal
        case id
        case role
        case content
        case timestamp
    }

    var message: ChatMessage {
        ChatMessage(
            id: UUID(uuidString: id) ?? UUID(),
            role: ChatMessage.Role(rawValue: role) ?? .assistant,
            content: content,
            timestamp: Date(timeIntervalSince1970: timestamp),
            isStreaming: false
        )
    }
}
