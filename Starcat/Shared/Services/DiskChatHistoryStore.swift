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
//  - SQLite 已承载正式版用户历史；schema 只能追加 migration，禁止回写 v1 或要求删库。
//    JSON chunk 作为另一个正式后端保留。
//  - facade 是 `@MainActor @Observable`，后端可以在内部把重 IO 放进 detached task。
//

import Foundation
import GRDB
import Observation
import Darwin

/// 对话历史存储错误。
enum DiskChatHistoryStoreError: LocalizedError {
    case applicationSupportUnavailable
    case invalidPathComponent(String)
    case migrationUnavailable

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return String.l10n("store.chatHistory.error.applicationSupportUnavailable")
        case .invalidPathComponent(let value):
            return String(format: String.l10n("store.chatHistory.error.invalidPathComponentFormat"), value)
        case .migrationUnavailable:
            return String.l10n("settings.storage.refinement.invalidHistory")
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
    /// `replacingExisting`：传入会话即权威版本，无视磁盘已有内容整体替换。
    /// 仅迁移写入（同 UUID 可能已有不同内容的旧版本）使用；常规追加保存传 false。
    /// 注意：protocol 声明不带默认值，existential 调用点必须显式传参。
    func saveSession(owner: String, repo: String, session: ChatSession, replacingExisting: Bool) throws
    func deleteSession(owner: String, repo: String, sessionId: UUID) throws
    func deleteAllForRepo(owner: String, repo: String) throws
    func deleteEverything() throws
    func lruSweep() throws
    var suspendsRetention: Bool { get set }
    func migrationLocations() throws -> [ChatHistoryLocation]
    func migrationSession(at location: ChatHistoryLocation) throws -> ChatSession
    func closeForMigration() throws
}

/// 迁移必须保留仓库归属；不能仅按 UUID 合并不同仓库下的记录。
private struct ChatHistoryLocation: Hashable {
    let owner: String
    let repo: String
    let id: UUID
}

/// AI 对话历史存储 facade（线程：所有公开方法 `@MainActor`）。
@MainActor
@Observable
final class DiskChatHistoryStore {

    static let shared = DiskChatHistoryStore(storageKind: AppSettings.shared.chatHistoryStorageKind)

    /// 每次「加载更早消息」的页大小。JSON 后端也用它作为 chunk 大小。
    nonisolated static let messagesPerChunk = 20

    private var backend: ChatHistoryStorageBackend
    private(set) var storageKind: ChatHistoryStorageKind
    private(set) var isMigrating = false
    private let fileManager: FileManager
    private let rootOverride: URL?
    private var activeReads = 0
    private var isPublishingMigration = false
    private var migrationWrites: [MigrationWrite] = []

    /// 迁移逐会话让出主线程时，正常写入仍先落原后端，再在发布前重放到目标。
    private enum MigrationWrite {
        case save(String, String, UUID)
        case delete(String, String, UUID)
        case deleteRepo(String, String)
        case deleteAll
    }

    var totalBytes: Int64 { backend.totalBytes }
    var sessionCount: Int { backend.sessionCount }
    var repoCount: Int { backend.repoCount }

    /// - Parameter sqliteMaxTotalBytes: 仅测试注入：SQLite 后端 LRU 配额覆盖；
    ///   生产保持默认 100 MiB，普通调用点不需要也不应该传。
    init(
        fileManager: FileManager = .default,
        rootOverride: URL? = nil,
        storageKind: ChatHistoryStorageKind = .jsonFiles,
        sqliteMaxTotalBytes: Int64? = nil
    ) {
        self.fileManager = fileManager
        self.rootOverride = rootOverride
        // 发布目录与活动后端标记原子交换；即使偏好写入前进程退出，下次也能打开正确的数据。
        let root = rootOverride ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(AppConstants.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("chat-history", isDirectory: true)
        let marker = root.flatMap { try? String(contentsOf: $0.appendingPathComponent(".active-storage"), encoding: .utf8) }
        let resolvedKind = marker.flatMap(ChatHistoryStorageKind.init(rawValue:)) ?? storageKind
        self.storageKind = resolvedKind
        switch resolvedKind {
        case .jsonFiles:
            self.backend = JSONChatHistoryStorageBackend(fileManager: fileManager, rootOverride: rootOverride)
        case .sqlite:
            self.backend = SQLiteChatHistoryStorageBackend(
                fileManager: fileManager,
                rootOverride: rootOverride,
                maxTotalBytes: sqliteMaxTotalBytes ?? SQLiteChatHistoryStorageBackend.defaultMaxTotalBytes
            )
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
        await waitForMigrationPublication()
        activeReads += 1
        defer { activeReads -= 1 }
        return try await backend.listSessionsAsync(owner: owner, repo: repo)
    }

    func loadSession(owner: String, repo: String, sessionId: UUID) throws -> ChatSession? {
        try backend.loadSession(owner: owner, repo: repo, sessionId: sessionId)
    }

    func loadSessionAsync(owner: String, repo: String, sessionId: UUID) async throws -> ChatSession? {
        await waitForMigrationPublication()
        activeReads += 1
        defer { activeReads -= 1 }
        return try await backend.loadSessionAsync(owner: owner, repo: repo, sessionId: sessionId)
    }

    func loadSessionTailAsync(owner: String, repo: String, sessionId: UUID, tailCount: Int) async throws -> ChatSessionPage? {
        await waitForMigrationPublication()
        activeReads += 1
        defer { activeReads -= 1 }
        return try await backend.loadSessionTailAsync(owner: owner, repo: repo, sessionId: sessionId, tailCount: tailCount)
    }

    func loadMessagesAsync(owner: String, repo: String, sessionId: UUID, start: Int, end: Int) async throws -> [ChatMessage] {
        await waitForMigrationPublication()
        activeReads += 1
        defer { activeReads -= 1 }
        return try await backend.loadMessagesAsync(owner: owner, repo: repo, sessionId: sessionId, start: start, end: end)
    }

    func saveSession(owner: String, repo: String, session: ChatSession) throws {
        // facade 只暴露常规追加保存；迁移的「传入即权威」替换语义仅经 backend 直达。
        try backend.saveSession(owner: owner, repo: repo, session: session, replacingExisting: false)
        if isMigrating { migrationWrites.append(.save(owner, repo, session.id)) }
    }

    func deleteSession(owner: String, repo: String, sessionId: UUID) throws {
        try backend.deleteSession(owner: owner, repo: repo, sessionId: sessionId)
        if isMigrating { migrationWrites.append(.delete(owner, repo, sessionId)) }
    }

    func deleteAllForRepo(owner: String, repo: String) throws {
        try backend.deleteAllForRepo(owner: owner, repo: repo)
        if isMigrating { migrationWrites.append(.deleteRepo(owner, repo)) }
    }

    func deleteEverything() throws {
        try backend.deleteEverything()
        if isMigrating { migrationWrites.append(.deleteAll) }
    }

    func lruSweep() throws {
        try backend.lruSweep()
    }

    private func waitForMigrationPublication() async {
        while isPublishingMigration { await Task.yield() }
    }

    private func makeBackend(kind: ChatHistoryStorageKind, root: URL) -> ChatHistoryStorageBackend {
        switch kind {
        case .jsonFiles: return JSONChatHistoryStorageBackend(fileManager: fileManager, rootOverride: root)
        case .sqlite: return SQLiteChatHistoryStorageBackend(fileManager: fileManager, rootOverride: root)
        }
    }

    /// 在独立目录合并并逐条回读，最后原子交换整个目录，不逐文件覆盖线上历史。
    ///
    /// 迁移期间禁用 LRU，避免格式变化或目标端已有数据使旧对话在导入中被淘汰。
    /// 所有源端写入都在原端成功后排队；发布前等待旧异步读取结束，并无挂起地重放、切换。
    /// 失败不修改活动后端及偏好，损坏历史也不会走普通加载路径的自动删除逻辑。
    func migrate(to kind: ChatHistoryStorageKind) async throws {
        guard !isMigrating else { throw DiskChatHistoryStoreError.migrationUnavailable }
        guard kind != storageKind else { return }
        guard let root = rootOverride ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(AppConstants.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("chat-history", isDirectory: true) else {
            throw DiskChatHistoryStoreError.applicationSupportUnavailable
        }
        isMigrating = true
        backend.suspendsRetention = true
        let originalKind = storageKind
        let stage = root.deletingLastPathComponent()
            .appendingPathComponent(".chat-history-migration-\(UUID().uuidString)", isDirectory: true)
        var didCloseSource = false
        var didExchange = false
        defer {
            backend.suspendsRetention = false
            isPublishingMigration = false
            isMigrating = false
            migrationWrites.removeAll()
        }
        let destination = makeBackend(kind: kind, root: root)
        let staged = makeBackend(kind: kind, root: stage)
        staged.suspendsRetention = true
        var locations: [UUID: ChatHistoryLocation] = [:]
        var importedSourceIDs = Set<UUID>()

        func writeAndVerify(_ session: ChatSession, at location: ChatHistoryLocation) throws {
            var persisted = session
            for index in persisted.messages.indices { persisted.messages[index].isStreaming = false }
            // 迁移写入必须是整体替换（replacingExisting: true）：staged 库里同 UUID 可能
            // 已有不同内容的旧版本（冲突另存场景），增量路径会保留旧前缀导致回读校验
            // 比对的是旧内容而非传入内容，校验失败会误报迁移不可用。
            try staged.saveSession(owner: location.owner, repo: location.repo, session: persisted, replacingExisting: true)
            guard try staged.migrationSession(at: location) == persisted else {
                throw DiskChatHistoryStoreError.migrationUnavailable
            }
            locations[location.id] = location
        }

        func importSource(_ session: ChatSession, at location: ChatHistoryLocation) throws {
            if let existingLocation = locations[location.id],
               !importedSourceIDs.contains(location.id) {
                let existing = try staged.migrationSession(at: existingLocation)
                if existingLocation != location || existing != session {
                    // 保留原 UUID 给正在打开的源会话；目标端的不同版本另存一份，绝不静默覆盖。
                    let copy = ChatSession(
                        title: existing.title, createdAt: existing.createdAt, updatedAt: existing.updatedAt,
                        messages: existing.messages, carriedOverSummary: existing.carriedOverSummary
                    )
                    try writeAndVerify(copy, at: ChatHistoryLocation(owner: existingLocation.owner, repo: existingLocation.repo, id: copy.id))
                }
                if existingLocation != location {
                    try staged.deleteSession(owner: existingLocation.owner, repo: existingLocation.repo, sessionId: existingLocation.id)
                }
            }
            importedSourceIDs.insert(location.id)
            try writeAndVerify(session, at: location)
        }

        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: stage, withIntermediateDirectories: true)
            for location in try destination.migrationLocations() {
                try Task.checkCancellation()
                try writeAndVerify(destination.migrationSession(at: location), at: location)
                await Task.yield()
            }
            try destination.closeForMigration()
            let sourceLocations = try backend.migrationLocations()
            // JSON 可容纳跨仓库的相同 UUID，SQLite 主键不能；此类异常先停止，保留原数据。
            guard Set(sourceLocations.map(\.id)).count == sourceLocations.count else {
                throw DiskChatHistoryStoreError.migrationUnavailable
            }
            for location in sourceLocations {
                try Task.checkCancellation()
                // 用户在让出主线程期间删除的会话由写日志处理，不应当作损坏数据。
                let wasDeleted = migrationWrites.reduce(false) { deleted, write in
                    switch write {
                    case .save(let owner, let repo, let id)
                        where owner == location.owner && repo == location.repo && id == location.id: return false
                    case .delete(let owner, let repo, let id)
                        where owner == location.owner && repo == location.repo && id == location.id: return true
                    case .deleteRepo(let owner, let repo)
                        where owner == location.owner && repo == location.repo: return true
                    case .deleteAll: return true
                    default: return deleted
                    }
                }
                if wasDeleted { continue }
                try importSource(backend.migrationSession(at: location), at: location)
                await Task.yield()
            }
            isPublishingMigration = true
            while activeReads > 0 {
                try Task.checkCancellation()
                await Task.yield()
            }
            try Task.checkCancellation()
            // 这里开始不再挂起；回复完成后的最后一次保存不会落到已经关闭的旧库。
            let finalSourceLocations = Set(try backend.migrationLocations())
            for write in migrationWrites {
                switch write {
                case .save(let owner, let repo, let id):
                    let location = ChatHistoryLocation(owner: owner, repo: repo, id: id)
                    if finalSourceLocations.contains(location) {
                        // 迁移的是源端实际保存的最终版本，不再用落盘前的内存对象；
                        // 否则 Date 的纪元转换精度可能让回读校验误判失败。
                        try importSource(backend.migrationSession(at: location), at: location)
                    }
                case .delete(let owner, let repo, let id):
                    try staged.deleteSession(owner: owner, repo: repo, sessionId: id)
                    locations.removeValue(forKey: id)
                case .deleteRepo(let owner, let repo):
                    try staged.deleteAllForRepo(owner: owner, repo: repo)
                    locations = locations.filter { $0.value.owner != owner || $0.value.repo != repo }
                case .deleteAll:
                    try staged.deleteEverything()
                    locations.removeAll()
                }
            }
            guard Set(try staged.migrationLocations()) == Set(locations.values) else {
                throw DiskChatHistoryStoreError.migrationUnavailable
            }
            try fileManager.createDirectory(at: stage, withIntermediateDirectories: true)
            try Data(kind.rawValue.utf8).write(to: stage.appendingPathComponent(".active-storage"), options: .atomic)
            try staged.closeForMigration()
            try backend.closeForMigration()
            didCloseSource = true
            // macOS 的目录交换是单次原子操作，进程退出不会留下半个目标目录或丢失原目录。
            guard renameatx_np(AT_FDCWD, stage.path, AT_FDCWD, root.path, UInt32(RENAME_SWAP)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            didExchange = true
            let replacement = makeBackend(kind: kind, root: root)
            guard Set(try replacement.migrationLocations()) == Set(locations.values) else {
                try replacement.closeForMigration()
                throw DiskChatHistoryStoreError.migrationUnavailable
            }
            backend = replacement
            backend.reload()
            storageKind = kind
            // 校验、发布全部成功后才回收旧目录；它在失败或交换前始终完整保留。
            try? fileManager.removeItem(at: stage)
        } catch {
            try? destination.closeForMigration()
            try? staged.closeForMigration()
            if didExchange {
                guard renameatx_np(AT_FDCWD, stage.path, AT_FDCWD, root.path, UInt32(RENAME_SWAP)) == 0 else {
                    // 原目录仍在 stage；活动标记可保证重启读到已发布的目标，不能删除任何一端。
                    backend = makeBackend(kind: kind, root: root)
                    storageKind = kind
                    throw error
                }
            }
            if didCloseSource {
                backend = makeBackend(kind: originalKind, root: root)
                backend.reload()
            }
            try? fileManager.removeItem(at: stage)
            throw error
        }
    }
}

// MARK: - JSON chunk 后端

/// JSON 历史日期编码的单一入口。
///
/// `JSONEncoder.DateEncodingStrategy.iso8601` 会丢弃亚秒，导致 reasoning/response 耗时
/// 在 JSON 后端与 SQLite 后端不一致。新数据改存精确的 Unix 秒数；读端同时接受旧版
/// ISO8601 字符串，正式版用户无需迁移或重建历史文件。
private enum ChatHistoryJSONCoding {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            let raw = try container.decode(String.self)
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: raw) { return date }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid chat-history date: \(raw)"
            )
        }
        return decoder
    }
}

@MainActor
private final class JSONChatHistoryStorageBackend: ChatHistoryStorageBackend {

    private let maxTotalBytes: Int64 = 100 * 1024 * 1024
    var suspendsRetention = false

    private(set) var totalBytes: Int64 = 0
    private(set) var sessionCount: Int = 0
    private(set) var repoCount: Int = 0

    private let fileManager: FileManager
    private let rootOverride: URL?

    private var saveCountSinceLastSweep: Int = 0
    private let saveCountSweepThreshold: Int = 5

    private let encoder = ChatHistoryJSONCoding.makeEncoder()
    private let decoder = ChatHistoryJSONCoding.makeDecoder()

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
            let decoder = ChatHistoryJSONCoding.makeDecoder()
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
                let decoder = ChatHistoryJSONCoding.makeDecoder()
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
                let decoder = ChatHistoryJSONCoding.makeDecoder()
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
            let decoder = ChatHistoryJSONCoding.makeDecoder()
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

    func saveSession(owner: String, repo: String, session: ChatSession, replacingExisting: Bool) throws {
        let dir = try projectDirectory(owner: owner, repo: repo)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let sessionDir = try sessionDirectory(owner: owner, repo: repo, sessionId: session.id)
        let metadata = ChatSessionMetadata(session: session, messageCount: session.messages.count)
        let existed = fileManager.fileExists(atPath: sessionDir.path)
        // 旧 messageCount：新会话或 metadata 损坏时读不到，按 nil 处理走整体重建自愈。
        // 可解码但 messageCount 为负属损坏数据：负值会让 writeMessageChunks 生成负下标，
        // 必须归一化为 nil 走重建（迁移路径 :769 有同样防御，这里对齐）。
        let rawOldCount = existed ? (try? readMetadata(at: sessionDir.appendingPathComponent("metadata.json")))?.messageCount : nil
        let oldCount = rawOldCount.flatMap { $0 >= 0 ? $0 : nil }
        // 前缀分块必须仍在磁盘上才允许增量写：chunks 目录缺失意味着历史 chunk 已丢失，
        // 增量写无法恢复前缀（旧全量重建路径可以），此时降级整体重建恢复数据完整性。
        let chunksDirExists = fileManager.fileExists(
            atPath: sessionDir.appendingPathComponent("chunks", isDirectory: true).path
        )
        let indexExisted = fileManager.fileExists(atPath: try indexFile(owner: owner, repo: repo).path)

        // 追加保存（每个对话回合的热路径）只重写受影响的尾部 chunk；旧实现每次重建
        // 整个会话目录并重写全部分块，200 条消息 = 10 个 chunk 全量 IO。
        // 消息数回退（读盘失败降级）、metadata 损坏、chunks 缺失或迁移显式替换
        // （replacingExisting，传入即权威）时整体重建，顺带清掉多余 chunk。
        var summaryBytes: Int64 = 0
        var sessionDirDelta: Int64 = 0
        var bytesDeltaForIndex: Int64? = nil
        if let oldCount, !replacingExisting, chunksDirExists, session.messages.count >= oldCount {
            // 同数保存（仅标题 / 时间戳变化）没有新消息，跳过分块写避免无谓重写含最后
            // 一条的非整块；历史消息从不改写（调用方契约），磁盘分块已是最新内容。
            if session.messages.count > oldCount {
                sessionDirDelta = try writeMessageChunks(sessionDir: sessionDir, messages: session.messages, fromMessage: oldCount)
            }
            sessionDirDelta += try writeAtomically(try encoder.encode(metadata), to: sessionDir.appendingPathComponent("metadata.json"))
            // 目录大小按「index 旧值 + delta」解析，不再为统计枚举整个会话目录。
            bytesDeltaForIndex = sessionDirDelta
        } else {
            let oldSize: Int64 = existed ? directorySize(sessionDir) : 0
            try writeFullSession(dir: dir, sessionDir: sessionDir, session: session, metadata: metadata)
            summaryBytes = directorySize(sessionDir)
            sessionDirDelta = summaryBytes - oldSize
        }

        let indexDelta = try upsertIndex(
            owner: owner,
            repo: repo,
            summary: ChatSessionSummary(
                id: session.id,
                title: session.title,
                createdAt: session.createdAt,
                updatedAt: session.updatedAt,
                messageCount: session.messages.count,
                bytes: summaryBytes
            ),
            bytesDelta: bytesDeltaForIndex
        )

        // 统计增量维护（口径与 reload 一致：会话目录 + index.json）。保存热路径不再
        // 全库遍历；全库重算只在 init / 删除 / LRU sweep 后执行。
        if !existed {
            sessionCount += 1
            if !indexExisted { repoCount += 1 }
        }
        totalBytes += sessionDirDelta + indexDelta

        saveCountSinceLastSweep += 1
        if !suspendsRetention { try maybeTriggerLRUSweep() }
    }

    /// 增量写消息分块：从 `fromMessage` 所在 chunk 起重写到末尾（旧实现每次重建整个目录）。
    /// 契约：调用方保证 chunks 目录存在且 `fromMessage >= 0`（saveSession 已用
    /// chunksDirExists 与 oldCount 归一化把关，任一不满足走整体重建恢复前缀）；
    /// 且传入消息列表的 [0, fromMessage) 前缀与磁盘内容一致——本仓库唯一热路径
    /// 调用方 RepoAIChatViewModel 只在尾部追加，历史消息从不改写。选择「增量快」而非
    /// 「逐字节校验前缀」，因为校验需要读回并解码全部分块，抵消增量收益。
    /// metadata 由调用方在 chunk 之后最后写入，充当提交点：chunk 写一半失败时旧 metadata
    /// 仍指向旧 messageCount，多写的尾部 chunk 不会被读取端读到，下次保存覆盖自愈。
    /// - Returns: 写入文件的字节增量（新内容大小 − 旧文件大小），供 totalBytes 增量维护。
    private func writeMessageChunks(sessionDir: URL, messages: [ChatMessage], fromMessage: Int) throws -> Int64 {
        let perChunk = DiskChatHistoryStore.messagesPerChunk
        let chunksDir = sessionDir.appendingPathComponent("chunks", isDirectory: true)
        var delta: Int64 = 0
        var chunkIndex = fromMessage / perChunk
        while chunkIndex * perChunk < messages.count {
            let chunkStart = chunkIndex * perChunk
            let end = min(chunkStart + perChunk, messages.count)
            let chunk = ChatMessageChunk(startIndex: chunkStart, messages: Array(messages[chunkStart..<end]))
            delta += try writeAtomically(try encoder.encode(chunk), to: chunksDir.appendingPathComponent(Self.chunkFileName(chunkIndex)))
            chunkIndex += 1
        }
        return delta
    }

    /// 整目录重建：tmp 组装 + 原子换入。仅用于首次落盘与会话长度回退的低频路径；
    /// 常规追加保存走 `writeMessageChunks`，不为每条新消息重写全部分块。
    private func writeFullSession(dir: URL, sessionDir: URL, session: ChatSession, metadata: ChatSessionMetadata) throws {
        let tmpDir = dir.appendingPathComponent(".\(session.id.uuidString).tmp-\(UUID().uuidString)", isDirectory: true)
        let chunksDir = tmpDir.appendingPathComponent("chunks", isDirectory: true)
        try fileManager.createDirectory(at: chunksDir, withIntermediateDirectories: true)
        try encoder.encode(metadata).write(to: tmpDir.appendingPathComponent("metadata.json"), options: .atomic)
        for (chunkIndex, start) in stride(from: 0, to: session.messages.count, by: DiskChatHistoryStore.messagesPerChunk).enumerated() {
            let end = min(start + DiskChatHistoryStore.messagesPerChunk, session.messages.count)
            let chunk = ChatMessageChunk(startIndex: start, messages: Array(session.messages[start..<end]))
            try encoder.encode(chunk).write(to: chunksDir.appendingPathComponent(Self.chunkFileName(chunkIndex)), options: .atomic)
        }
        if fileManager.fileExists(atPath: sessionDir.path) {
            try fileManager.removeItem(at: sessionDir)
        }
        try fileManager.moveItem(at: tmpDir, to: sessionDir)
    }

    /// 原子写单文件并返回字节差（旧文件不存在按 0 计）。原子写落盘内容与 `data` 逐字节
    /// 一致，新大小直接取 `data.count`，省一次 stat。
    private func writeAtomically(_ data: Data, to url: URL) throws -> Int64 {
        let oldSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        try data.write(to: url, options: .atomic)
        return Int64(data.count) - oldSize
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
        guard !suspendsRetention else { return }
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

    func closeForMigration() throws {}

    /// 使用严格读盘而非 index 自愈；无法读出的会话必须阻止迁移，不能当作空历史跳过。
    func migrationLocations() throws -> [ChatHistoryLocation] {
        let root = try rootURL()
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        var result: [ChatHistoryLocation] = []
        for owner in try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) where owner.hasDirectoryPath {
            for repo in try fileManager.contentsOfDirectory(at: owner, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) where repo.hasDirectoryPath {
                for session in try fileManager.contentsOfDirectory(at: repo, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) where session.hasDirectoryPath {
                    guard let id = UUID(uuidString: session.lastPathComponent) else { continue }
                    result.append(ChatHistoryLocation(owner: owner.lastPathComponent, repo: repo.lastPathComponent, id: id))
                }
            }
        }
        return result
    }

    func migrationSession(at location: ChatHistoryLocation) throws -> ChatSession {
        let dir = try sessionDirectory(owner: location.owner, repo: location.repo, sessionId: location.id)
        let metadata = try decoder.decode(ChatSessionMetadata.self, from: Data(contentsOf: dir.appendingPathComponent("metadata.json")))
        guard metadata.messageCount >= 0 else { throw DiskChatHistoryStoreError.migrationUnavailable }
        let messages = try loadMessages(owner: location.owner, repo: location.repo, sessionId: location.id, range: 0..<metadata.messageCount)
        guard metadata.id == location.id, messages.count == metadata.messageCount else {
            throw DiskChatHistoryStoreError.migrationUnavailable
        }
        return metadata.makeSession(messages: messages)
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

    /// 更新 index.json 中单会话摘要，返回 index.json 的字节差（供 totalBytes 增量维护，
    /// 口径与 reload 一致：reload 把 index.json 计入全库字节）。
    /// `bytesDelta` 非 nil（追加保存热路径）时，目录大小按「index 旧值 + delta」解析，
    /// 避免为统计重新枚举会话目录；为 nil（整体重建路径）时直接使用 summary.bytes。
    private func upsertIndex(owner: String, repo: String, summary: ChatSessionSummary, bytesDelta: Int64? = nil) throws -> Int64 {
        let indexURL = try indexFile(owner: owner, repo: repo)
        let oldIndexSize = (try? indexURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        var index: ChatSessionIndex
        if fileManager.fileExists(atPath: indexURL.path),
           let data = try? Data(contentsOf: indexURL),
           let existing = try? decoder.decode(ChatSessionIndex.self, from: data) {
            index = existing
        } else {
            index = ChatSessionIndex(sessions: [])
        }

        var resolved = summary
        if let bytesDelta {
            let oldBytes = index.sessions.first(where: { $0.id == summary.id })?.bytes ?? 0
            resolved.bytes = oldBytes + bytesDelta
        }

        if let pos = index.sessions.firstIndex(where: { $0.id == summary.id }) {
            index.sessions[pos] = resolved
        } else {
            index.sessions.append(resolved)
        }

        let encoded = try encoder.encode(index)
        try encoded.write(to: indexURL, options: .atomic)
        return Int64(encoded.count) - oldIndexSize
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

    /// 聊天历史配额（逻辑字节）。生产默认 100 MiB；测试经 facade 注入小配额驱动淘汰路径。
    /// 不加 private：facade 需要读取默认值（类本身 private，可见性已限制在文件内）。
    nonisolated static let defaultMaxTotalBytes: Int64 = 100 * 1024 * 1024
    private let maxTotalBytes: Int64
    var suspendsRetention = false

    private(set) var totalBytes: Int64 = 0
    private(set) var sessionCount: Int = 0
    private(set) var repoCount: Int = 0

    private let fileManager: FileManager
    private let rootOverride: URL?
    private let dbQueue: DatabaseQueue?
    private let dbURL: URL?

    init(
        fileManager: FileManager = .default,
        rootOverride: URL? = nil,
        maxTotalBytes: Int64 = SQLiteChatHistoryStorageBackend.defaultMaxTotalBytes
    ) {
        self.maxTotalBytes = maxTotalBytes
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
            DiagnosticLogStore.record(
                level: .critical,
                visibility: .issue,
                category: "database",
                operation: "chatHistory.openDatabase",
                message: "Chat history database could not be opened or migrated",
                summary: .chatHistoryUnavailable,
                impact: .blocked,
                underlying: DiagnosticEvent.summarize(error), error: error
            )
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

    func saveSession(owner: String, repo: String, session: ChatSession, replacingExisting: Bool) throws {
        guard let dbQueue else { return }
        try dbQueue.write { db in
            // 先读旧行拿旧 messageCount，再覆盖会话行；新会话无旧行按 0 处理。
            let oldCount = try ChatSessionSQLRow
                .filter(Column("id") == session.id.uuidString)
                .fetchOne(db)?.messageCount ?? 0
            let newCount = session.messages.count

            var sessionRow = ChatSessionSQLRow(
                id: session.id.uuidString,
                owner: owner,
                repo: repo,
                title: session.title,
                createdAt: session.createdAt.timeIntervalSince1970,
                updatedAt: session.updatedAt.timeIntervalSince1970,
                carriedOverSummary: session.carriedOverSummary,
                messageCount: newCount
            )
            try sessionRow.save(db)

            // 单条消息按 ordinal 落盘；onConflict: .replace 兜底异常态下 ordinal 撞主键，
            // 落盘值仍以此刻传入的消息为准。
            func insertMessage(at index: Int) throws {
                let message = session.messages[index]
                var messageRow = ChatMessageSQLRow(
                    sessionId: session.id.uuidString,
                    ordinal: index,
                    id: message.id.uuidString,
                    role: message.role.rawValue,
                    content: message.content,
                    reasoning: message.reasoning,
                    reasoningStartedAt: message.reasoningStartedAt?.timeIntervalSince1970,
                    reasoningCompletedAt: message.reasoningCompletedAt?.timeIntervalSince1970,
                    responseCompletedAt: message.responseCompletedAt?.timeIntervalSince1970,
                    timestamp: message.timestamp.timeIntervalSince1970
                )
                try messageRow.insert(db, onConflict: .replace)
            }

            // 常规追加路径的契约：调用方只在尾部追加（RepoAIChatViewModel 的历史消息
            // 从不改写），已有 ordinal 不再删光重插——200 条会话每个回合从
            // 「200 删 + 200 插」降为 1~2 条 insert。
            if replacingExisting {
                // 迁移写入：同 UUID 在 staged 库里可能已有不同内容的旧版本（冲突另存前的
                // 原位覆盖），传入即权威——必须删光重插。若沿用追加路径，旧前缀会顶替
                // 传入内容，迁移后的回读校验（比对落盘与传入）将失败并中断迁移。
                try ChatMessageSQLRow
                    .filter(Column("session_id") == session.id.uuidString)
                    .deleteAll(db)
                for index in 0..<newCount {
                    try insertMessage(at: index)
                }
            } else if newCount >= oldCount {
                for index in oldCount..<newCount {
                    try insertMessage(at: index)
                }
            } else {
                // 消息数回退（如读盘失败降级保存的截断窗口）：传入即权威——前缀按传入
                // 内容重写 + 清掉多余 ordinal，落盘状态与旧实现删光重插完全等价。
                // 只删不插会让旧前缀顶替传入内容，本次保存的新消息直接丢失。
                for index in 0..<newCount {
                    try insertMessage(at: index)
                }
                try ChatMessageSQLRow
                    .filter(Column("session_id") == session.id.uuidString && Column("ordinal") >= newCount)
                    .deleteAll(db)
            }
        }
        reload()
        try lruSweep()
    }

    func deleteSession(owner _: String, repo _: String, sessionId: UUID) throws {
        guard let dbQueue else { return }
        _ = try dbQueue.write { db in
            try ChatSessionSQLRow
                .filter(Column("id") == sessionId.uuidString)
                .deleteAll(db)
        }
        reload()
    }

    func deleteAllForRepo(owner: String, repo: String) throws {
        guard let dbQueue else { return }
        _ = try dbQueue.write { db in
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

    /// 按配额淘汰最旧会话。计量用「逻辑字节」（会话文本的 UTF-8 字节数）而非 db 文件物理大小：
    /// SQLite 事务内的 DELETE 只把页标记为空闲、不缩文件（WAL 甚至先变大），
    /// 用物理大小做 while 停止条件会恒真，最坏把全部会话删光。
    /// 淘汰语义与 JSON 后端对齐：updated_at 最旧优先、逐条扣减、删到达标即停。
    func lruSweep() throws {
        guard !suspendsRetention, totalBytes > maxTotalBytes, let dbQueue else { return }
        // 门禁上的 totalBytes 是物理大小，可能因碎片 / WAL 虚高；用逻辑字节复核，
        // 未超配额直接返回，避免无意义的空扫和 VACUUM。
        var remainingBytes = try dbQueue.read { db in
            try Self.logicalTotalBytes(db: db)
        }
        guard remainingBytes > maxTotalBytes else { return }
        var deletedAny = false
        try dbQueue.write { db in
            while remainingBytes > maxTotalBytes {
                guard let oldest = try ChatSessionSQLRow
                    .order(Column("updated_at").asc)
                    .fetchOne(db) else {
                    break
                }
                remainingBytes -= try Self.logicalSessionBytes(db: db, sessionId: oldest.id)
                // FK cascade 会级联删除该会话的 chat_messages 行。
                try ChatSessionSQLRow
                    .filter(Column("id") == oldest.id)
                    .deleteAll(db)
                deletedAny = true
            }
        }
        // VACUUM 不能在事务内执行，且只在确有删除时才值得付出整库重写的代价。
        if deletedAny {
            try dbQueue.writeWithoutTransaction { db in
                try db.execute(sql: "VACUUM")
            }
            reload()
        }
    }

    func closeForMigration() throws {
        try dbQueue?.close()
    }

    func migrationLocations() throws -> [ChatHistoryLocation] {
        guard let dbQueue else { throw DiskChatHistoryStoreError.migrationUnavailable }
        return try dbQueue.read { db in
            try ChatSessionSQLRow.fetchAll(db).map { row in
                guard let id = UUID(uuidString: row.id) else { throw DiskChatHistoryStoreError.migrationUnavailable }
                return ChatHistoryLocation(owner: row.owner, repo: row.repo, id: id)
            }
        }
    }

    func migrationSession(at location: ChatHistoryLocation) throws -> ChatSession {
        guard let session = try loadSession(owner: location.owner, repo: location.repo, sessionId: location.id),
              let summary = try listSessions(owner: location.owner, repo: location.repo).first(where: { $0.id == location.id }),
              session.messages.count == summary.messageCount else {
            throw DiskChatHistoryStoreError.migrationUnavailable
        }
        return session
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
        migrator.registerMigration("v2-chat-message-reasoning") { db in
            // 独立 chat-history SQLite 也可能来自已发布版本。reasoning 是可空列，
            // 旧消息迁移后自然保持 nil，新消息开始保存 provider 公开的 Think 内容。
            try db.alter(table: "chat_messages") { table in
                table.add(column: "reasoning", .text)
            }
        }
        migrator.registerMigration("v3-chat-message-reasoning-timing") { db in
            // 历史库已发布；为 Think 耗时追加可空列，旧消息保持 nil，不能要求用户删库。
            try db.alter(table: "chat_messages") { table in
                table.add(column: "reasoning_started_at", .double)
                table.add(column: "reasoning_completed_at", .double)
            }
        }
        migrator.registerMigration("v4-chat-message-response-completion") { db in
            // 回复总耗时与 Think 耗时语义不同，单独追加完成时刻，旧历史保持 nil。
            try db.alter(table: "chat_messages") { table in
                table.add(column: "response_completed_at", .double)
            }
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

    /// 单会话逻辑字节 SQL 片段（依赖外层 `FROM chat_sessions s` 别名）。
    /// LENGTH(CAST(x AS BLOB)) 取 UTF-8 字节数；可空列用 COALESCE 归零，空串计 0。
    /// 逻辑字节是配额近似值：不含行头 / 索引 / WAL 等物理开销，但与 JSON 后端的
    /// 计量口径（内容字节数）一致，足够做淘汰决策。
    private nonisolated static let sessionLogicalBytesSQL = """
        LENGTH(CAST(s.title AS BLOB))
        + LENGTH(CAST(COALESCE(s.carried_over_summary, '') AS BLOB))
        + COALESCE((
            SELECT SUM(LENGTH(CAST(m.content AS BLOB)) + LENGTH(CAST(COALESCE(m.reasoning, '') AS BLOB)))
            FROM chat_messages m
            WHERE m.session_id = s.id
        ), 0)
        """

    /// 全库逻辑字节总和，用于配额门禁复核。
    nonisolated private static func logicalTotalBytes(db: Database) throws -> Int64 {
        try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(\(sessionLogicalBytesSQL)), 0) FROM chat_sessions s") ?? 0
    }

    /// 单会话逻辑字节，用于淘汰时逐条扣减剩余量。
    nonisolated private static func logicalSessionBytes(db: Database, sessionId: String) throws -> Int64 {
        try Int64.fetchOne(db, sql: "SELECT \(sessionLogicalBytesSQL) FROM chat_sessions s WHERE s.id = ?", arguments: [sessionId]) ?? 0
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
    var reasoning: String?
    var reasoningStartedAt: Double?
    var reasoningCompletedAt: Double?
    var responseCompletedAt: Double?
    var timestamp: Double

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case ordinal
        case id
        case role
        case content
        case reasoning
        case reasoningStartedAt = "reasoning_started_at"
        case reasoningCompletedAt = "reasoning_completed_at"
        case responseCompletedAt = "response_completed_at"
        case timestamp
    }

    var message: ChatMessage {
        ChatMessage(
            id: UUID(uuidString: id) ?? UUID(),
            role: ChatMessage.Role(rawValue: role) ?? .assistant,
            content: content,
            reasoning: reasoning,
            reasoningStartedAt: reasoningStartedAt.map(Date.init(timeIntervalSince1970:)),
            reasoningCompletedAt: reasoningCompletedAt.map(Date.init(timeIntervalSince1970:)),
            responseCompletedAt: responseCompletedAt.map(Date.init(timeIntervalSince1970:)),
            timestamp: Date(timeIntervalSince1970: timestamp),
            isStreaming: false
        )
    }
}
