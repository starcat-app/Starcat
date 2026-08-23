//
//  DiskNotificationCommentDraftCache.swift
//  Starcat
//
//  通知详情未提交评论草稿。
//
//  为什么走文件、不入库：
//  - 这是本机未发出的正文，不是要同步的用户主数据。
//  - 加 SQLite 列要 `registerVN`；文件缓存跟事件流 / Wiki 同一形态。
//  - 切帖会复用同一个 Composer `@State`，必须按 threadId 先存再清，否则 AI / 手写稿都会丢。
//
//  路径：`issue-comment-draft-cache/<safeThreadId>.json`
//  内存热缓存避免每次切帖都读盘；设置 → 存储可单独清除。
//

import Foundation
import Observation

enum DiskNotificationCommentDraftCacheError: LocalizedError {
    case applicationSupportUnavailable
    case unsafePathComponent(String)

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return String.l10n("cache.issueCommentDraft.error.applicationSupportUnavailable")
        case .unsafePathComponent(let value):
            return String(format: String.l10n("cache.issueCommentDraft.error.unsafePathComponentFormat"), value)
        }
    }
}

/// 一条通知会话的未提交评论。
struct NotificationCommentDraftSnapshot: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let threadId: String
    let draft: String
    /// 最后写入时刻。超过 `maxAge` 会在读取或 prune 时丢掉。
    let updatedAt: Date
}

/// 未提交评论草稿。公开方法都在 `@MainActor`。
///
/// 测试用 `rootOverride` + `clock` 隔离，不要碰生产 Application Support。
@MainActor
@Observable
final class DiskNotificationCommentDraftCache {

    static let shared = DiskNotificationCommentDraftCache()

    nonisolated static let maxItemCount = 50
    nonisolated static let maxAge: TimeInterval = 30 * 24 * 60 * 60
    /// GitHub Issue 评论上限约 65536 字节。
    nonisolated static let maxDraftUTF8Bytes = 65_536

    private(set) var itemCount: Int = 0
    private(set) var totalBytes: Int64 = 0

    private var memory: [String: NotificationCommentDraftSnapshot] = [:]

    private let fileManager: FileManager
    private let rootOverride: URL?
    private let clock: () -> Date

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(
        fileManager: FileManager = .default,
        rootOverride: URL? = nil,
        clock: @escaping () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.rootOverride = rootOverride
        self.clock = clock
        reload()
    }

    /// 生成中只留点 AI 之前的原文，避免半截流式稿写进下一帖或落盘。
    static func persistableDraft(
        current: String,
        previous: String?,
        isGenerating: Bool
    ) -> String {
        let raw = isGenerating ? (previous ?? "") : current
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func load(threadId: String) -> NotificationCommentDraftSnapshot? {
        let key: String
        do {
            key = try Self.safeThreadId(threadId)
        } catch {
            return nil
        }

        if let cached = memory[key] {
            if isExpired(cached) {
                remove(threadId: threadId)
                return nil
            }
            return cached
        }

        guard let url = try? cacheFileURL(threadId: threadId),
              fileManager.fileExists(atPath: url.path)
        else { return nil }

        let snapshot: NotificationCommentDraftSnapshot
        do {
            let data = try Data(contentsOf: url)
            snapshot = try decoder.decode(NotificationCommentDraftSnapshot.self, from: data)
        } catch {
            AppLog.network.warning(
                "Issue comment draft: decode failed, removing path=\(url.path, privacy: .public)"
            )
            try? fileManager.removeItem(at: url)
            reload()
            return nil
        }

        guard snapshot.formatVersion == NotificationCommentDraftSnapshot.currentFormatVersion else {
            try? fileManager.removeItem(at: url)
            reload()
            return nil
        }
        if isExpired(snapshot) {
            try? fileManager.removeItem(at: url)
            reload()
            return nil
        }
        memory[key] = snapshot
        return snapshot
    }

    /// 空正文删除该帖缓存；有正文则截断后写入，并按条数 / 天数淘汰。
    func upsert(threadId: String, draft: String) {
        let clamped = Self.clampedDraft(draft)
        if clamped.isEmpty {
            remove(threadId: threadId)
            return
        }
        let snapshot = NotificationCommentDraftSnapshot(
            formatVersion: NotificationCommentDraftSnapshot.currentFormatVersion,
            threadId: threadId,
            draft: clamped,
            updatedAt: clock()
        )
        do {
            try save(snapshot)
            pruneIfNeeded()
        } catch {
            AppLog.network.warning(
                "Issue comment draft: save failed thread=\(threadId, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func remove(threadId: String) {
        let key = (try? Self.safeThreadId(threadId)) ?? threadId
        memory[key] = nil
        guard let url = try? cacheFileURL(threadId: threadId),
              fileManager.fileExists(atPath: url.path)
        else {
            reload()
            return
        }
        try? fileManager.removeItem(at: url)
        reload()
    }

    func deleteEverything() throws {
        memory.removeAll(keepingCapacity: false)
        let root = try rootURL()
        if fileManager.fileExists(atPath: root.path) {
            try fileManager.removeItem(at: root)
        }
        reload()
    }

    func reload() {
        memory.removeAll(keepingCapacity: true)
        guard let root = try? rootURL(),
              fileManager.fileExists(atPath: root.path)
        else {
            totalBytes = 0
            itemCount = 0
            return
        }

        var total: Int64 = 0
        var count = 0
        for file in collectJSONFiles(under: root) {
            guard let data = try? Data(contentsOf: file),
                  let snapshot = try? decoder.decode(NotificationCommentDraftSnapshot.self, from: data),
                  snapshot.formatVersion == NotificationCommentDraftSnapshot.currentFormatVersion,
                  !isExpired(snapshot),
                  let key = try? Self.safeThreadId(snapshot.threadId)
            else {
                try? fileManager.removeItem(at: file)
                continue
            }
            memory[key] = snapshot
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
            count += 1
        }
        totalBytes = total
        itemCount = count
    }

    private func save(_ snapshot: NotificationCommentDraftSnapshot) throws {
        let key = try Self.safeThreadId(snapshot.threadId)
        let url = try cacheFileURL(threadId: snapshot.threadId)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
        memory[key] = snapshot
        reloadCountsFromMemory()
    }

    private func pruneIfNeeded() {
        let overflow = memory.values
            .sorted { $0.updatedAt < $1.updatedAt }
        guard overflow.count > Self.maxItemCount else { return }
        for snapshot in overflow.prefix(overflow.count - Self.maxItemCount) {
            remove(threadId: snapshot.threadId)
        }
    }

    private func isExpired(
        _ snapshot: NotificationCommentDraftSnapshot,
        now: Date? = nil
    ) -> Bool {
        (now ?? clock()).timeIntervalSince(snapshot.updatedAt) > Self.maxAge
    }

    private func reloadCountsFromMemory() {
        itemCount = memory.count
        var total: Int64 = 0
        if let root = try? rootURL() {
            for file in collectJSONFiles(under: root) {
                if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    total += Int64(size)
                }
            }
        }
        totalBytes = total
    }

    private func rootURL() throws -> URL {
        if let rootOverride { return rootOverride }
        guard let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw DiskNotificationCommentDraftCacheError.applicationSupportUnavailable
        }
        return appSupport
            .appendingPathComponent(AppConstants.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("issue-comment-draft-cache", isDirectory: true)
    }

    private func cacheFileURL(threadId: String) throws -> URL {
        let safe = try Self.safeThreadId(threadId)
        return try rootURL().appendingPathComponent("\(safe).json")
    }

    private func collectJSONFiles(under dir: URL) -> [URL] {
        let children = (try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return children.filter { $0.pathExtension == "json" }
    }

    nonisolated static func safeThreadId(_ threadId: String) throws -> String {
        let safe = GitHubNotificationTranslation.cacheRepo(threadId: threadId)
        try DiskIssueTimelineCache.assertSafePathComponent(safe)
        return safe
    }

    nonisolated static func clampedDraft(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count > maxDraftUTF8Bytes else { return trimmed }
        var result = trimmed
        while result.utf8.count > maxDraftUTF8Bytes, !result.isEmpty {
            result.removeLast()
        }
        return result
    }
}
