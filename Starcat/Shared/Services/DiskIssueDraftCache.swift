//
//  DiskIssueDraftCache.swift
//  Starcat
//
//  新建 Issue 表单的未提交草稿（按仓库一份：title + body）。
//
//  为什么走文件、不入库（沿用 DiskNotificationCommentDraftCache 的决策）：
//  - 这是本机未提交的表单内容，不是要同步的用户主数据。
//  - 加 SQLite 表要 `registerVN` 迁移账本；文件缓存跟事件流 / Wiki 同一形态。
//  - 按 repo 全名一份草稿：切换仓库 / 重启 App 后都能续写（产品设计要求）。
//
//  路径：`issue-draft-cache/<owner>-<repo>.json`（`/` 替换为 `-` 防 path traversal）
//  内存热缓存避免每次打开表单都读盘。暂未接入设置 → 存储清理页；
//  GeneralSettingsView 正在被其它任务改动，接入等国际化批处理收口后一并做。
//

import Foundation
import Observation

enum DiskIssueDraftCacheError: LocalizedError {
    case applicationSupportUnavailable
    case unsafePathComponent(String)

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return String.l10n("cache.issueDraft.error.applicationSupportUnavailable", defaultValue: "无法访问应用支持目录")
        case .unsafePathComponent(let value):
            return String(format: String.l10n("cache.issueDraft.error.unsafePathComponentFormat", defaultValue: "不安全的缓存路径：%@"), value)
        }
    }
}

/// 一个仓库的未提交 Issue 草稿。
struct IssueDraftSnapshot: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let repoFullName: String
    let title: String
    let body: String
    /// 最后写入时刻。超过 `maxAge` 会在读取或 prune 时丢掉。
    let updatedAt: Date
}

/// 未提交 Issue 草稿缓存。公开方法都在 `@MainActor`。
///
/// 测试用 `rootOverride` + `clock` 隔离，不要碰生产 Application Support。
@MainActor
@Observable
final class DiskIssueDraftCache {

    static let shared = DiskIssueDraftCache()

    nonisolated static let maxItemCount = 30
    nonisolated static let maxAge: TimeInterval = 30 * 24 * 60 * 60
    /// GitHub Issue 正文上限约 65536 字节。
    nonisolated static let maxBodyUTF8Bytes = 65_536
    /// GitHub 网页端标题输入上限 256 字符，提前钳制避免提交 422。
    nonisolated static let maxTitleLength = 256

    private(set) var itemCount: Int = 0
    private(set) var totalBytes: Int64 = 0

    private var memory: [String: IssueDraftSnapshot] = [:]

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

    func load(repoFullName: String) -> IssueDraftSnapshot? {
        let key: String
        do {
            key = try Self.safeRepoKey(repoFullName)
        } catch {
            return nil
        }

        if let cached = memory[key] {
            if isExpired(cached) {
                remove(repoFullName: repoFullName)
                return nil
            }
            return cached
        }

        guard let url = try? cacheFileURL(repoFullName: repoFullName),
              fileManager.fileExists(atPath: url.path)
        else { return nil }

        let snapshot: IssueDraftSnapshot
        do {
            let data = try Data(contentsOf: url)
            snapshot = try decoder.decode(IssueDraftSnapshot.self, from: data)
        } catch {
            AppLog.network.warning(
                "Issue draft: decode failed, removing path=\(url.path, privacy: .public)"
            )
            try? fileManager.removeItem(at: url)
            reload()
            return nil
        }

        guard snapshot.formatVersion == IssueDraftSnapshot.currentFormatVersion else {
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

    /// 空标题 + 空正文删除该仓缓存；否则钳制后写入，并按条数 / 天数淘汰。
    func upsert(repoFullName: String, title: String, body: String) {
        let clampedTitle = Self.clampedTitle(title)
        let clampedBody = Self.clampedBody(body)
        if clampedTitle.isEmpty && clampedBody.isEmpty {
            remove(repoFullName: repoFullName)
            return
        }
        let snapshot = IssueDraftSnapshot(
            formatVersion: IssueDraftSnapshot.currentFormatVersion,
            repoFullName: repoFullName,
            title: clampedTitle,
            body: clampedBody,
            updatedAt: clock()
        )
        do {
            try save(snapshot)
            pruneIfNeeded()
        } catch {
            AppLog.network.warning(
                "Issue draft: save failed repo=\(repoFullName, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func remove(repoFullName: String) {
        let key = (try? Self.safeRepoKey(repoFullName)) ?? repoFullName
        memory[key] = nil
        guard let url = try? cacheFileURL(repoFullName: repoFullName),
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
                  let snapshot = try? decoder.decode(IssueDraftSnapshot.self, from: data),
                  snapshot.formatVersion == IssueDraftSnapshot.currentFormatVersion,
                  !isExpired(snapshot),
                  let key = try? Self.safeRepoKey(snapshot.repoFullName)
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

    private func save(_ snapshot: IssueDraftSnapshot) throws {
        let key = try Self.safeRepoKey(snapshot.repoFullName)
        let url = try cacheFileURL(repoFullName: snapshot.repoFullName)
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
            remove(repoFullName: snapshot.repoFullName)
        }
    }

    private func isExpired(
        _ snapshot: IssueDraftSnapshot,
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
            throw DiskIssueDraftCacheError.applicationSupportUnavailable
        }
        return appSupport
            .appendingPathComponent(AppConstants.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("issue-draft-cache", isDirectory: true)
    }

    private func cacheFileURL(repoFullName: String) throws -> URL {
        let safe = try Self.safeRepoKey(repoFullName)
        return try rootURL().appendingPathComponent("\(safe).json")
    }

    private func collectJSONFiles(under dir: URL) -> [URL] {
        let children = (try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return children.filter { $0.pathExtension == "json" }
    }

    /// `owner/repo` 用作文件名：`/` 替换为 `-`（同 `GitHubNotificationTranslation.cacheRepo`），
    /// 避免路径穿越；再经 `assertSafePathComponent` 防御性校验。
    nonisolated static func safeRepoKey(_ repoFullName: String) throws -> String {
        let safe = GitHubNotificationTranslation.cacheRepo(threadId: repoFullName)
        try DiskIssueTimelineCache.assertSafePathComponent(safe)
        return safe
    }

    nonisolated static func clampedTitle(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxTitleLength))
    }

    nonisolated static func clampedBody(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count > maxBodyUTF8Bytes else { return trimmed }
        var result = trimmed
        while result.utf8.count > maxBodyUTF8Bytes, !result.isEmpty {
            result.removeLast()
        }
        return result
    }
}
