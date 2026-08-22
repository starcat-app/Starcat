//
//  DiskIssueTimelineCache.swift
//  Starcat
//
//  Issue / PR Timeline 磁盘缓存。
//
//  为什么走文件、不入库：
//  - 这是 GitHub 可重建的只读快照，不是用户私有数据。
//  - 通知行已经在 SQLite；再加 `timeline_json` 要 `registerVN`，老用户库会被绑死。
//  - 形态跟 Wiki / 推荐一样：Application Support JSON + 内存热缓存。
//
//  路径：`issue-timeline-cache/<owner>/<repo>/<number>.json`
//  按仓库和 Issue 号定位，Finder 能对上，也不跟通知 threadId 绑定。
//

import Foundation
import Observation

enum DiskIssueTimelineCacheError: LocalizedError {
    case applicationSupportUnavailable
    case unsafePathComponent(String)

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return String.l10n("cache.issueTimeline.error.applicationSupportUnavailable")
        case .unsafePathComponent(let value):
            return String(format: String.l10n("cache.issueTimeline.error.unsafePathComponentFormat"), value)
        }
    }
}

/// 一条 Issue / PR 的 timeline 落盘快照。
struct IssueTimelineCacheSnapshot: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let owner: String
    let repo: String
    let number: Int
    /// 写入时刻。通知 `updated_at` 更新时 Inbox 会当 stale 重拉。
    let fetchedAt: Date
    let items: [GitHubNotificationIssueTimelineItem]
}

/// Issue 事件流磁盘缓存。公开方法都在 `@MainActor`。
///
/// 测试用 `rootOverride` 隔离，不要碰生产目录。
@MainActor
@Observable
final class DiskIssueTimelineCache {

    static let shared = DiskIssueTimelineCache()

    private(set) var itemCount: Int = 0
    private(set) var totalBytes: Int64 = 0

    private let fileManager: FileManager
    private let rootOverride: URL?

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

    init(fileManager: FileManager = .default, rootOverride: URL? = nil) {
        self.fileManager = fileManager
        self.rootOverride = rootOverride
        reload()
    }

    func load(owner: String, repo: String, number: Int) -> IssueTimelineCacheSnapshot? {
        let url: URL
        do {
            url = try cacheFileURL(owner: owner, repo: repo, number: number)
        } catch {
            AppLog.network.warning(
                "Issue timeline cache: invalid path owner=\(owner, privacy: .public) repo=\(repo, privacy: .public)"
            )
            return nil
        }
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            AppLog.network.warning(
                "Issue timeline cache: read failed path=\(url.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return nil
        }

        do {
            let snapshot = try decoder.decode(IssueTimelineCacheSnapshot.self, from: data)
            guard snapshot.formatVersion == IssueTimelineCacheSnapshot.currentFormatVersion else {
                try? fileManager.removeItem(at: url)
                reload()
                return nil
            }
            return snapshot
        } catch {
            AppLog.network.warning(
                "Issue timeline cache: decode failed, removing path=\(url.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            try? fileManager.removeItem(at: url)
            reload()
            return nil
        }
    }

    func save(snapshot: IssueTimelineCacheSnapshot) throws {
        let url = try cacheFileURL(owner: snapshot.owner, repo: snapshot.repo, number: snapshot.number)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
        reload()
    }

    func remove(owner: String, repo: String, number: Int) {
        guard let url = try? cacheFileURL(owner: owner, repo: repo, number: number),
              fileManager.fileExists(atPath: url.path)
        else { return }
        try? fileManager.removeItem(at: url)
        reload()
    }

    func deleteEverything() throws {
        let root = try rootURL()
        if fileManager.fileExists(atPath: root.path) {
            try fileManager.removeItem(at: root)
        }
        reload()
    }

    func reload() {
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
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
                count += 1
            }
        }
        totalBytes = total
        itemCount = count
    }

    private func rootURL() throws -> URL {
        if let rootOverride { return rootOverride }
        guard let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw DiskIssueTimelineCacheError.applicationSupportUnavailable
        }
        return appSupport
            .appendingPathComponent(AppConstants.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("issue-timeline-cache", isDirectory: true)
    }

    private func cacheFileURL(owner: String, repo: String, number: Int) throws -> URL {
        try Self.assertSafePathComponent(owner)
        try Self.assertSafePathComponent(repo)
        return try rootURL()
            .appendingPathComponent(owner, isDirectory: true)
            .appendingPathComponent(repo, isDirectory: true)
            .appendingPathComponent("\(number).json")
    }

    private func collectJSONFiles(under dir: URL) -> [URL] {
        var out: [URL] = []
        let children = (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for child in children {
            if child.hasDirectoryPath {
                out.append(contentsOf: collectJSONFiles(under: child))
            } else if child.pathExtension == "json" {
                out.append(child)
            }
        }
        return out
    }

    nonisolated static func assertSafePathComponent(_ value: String) throws {
        guard !value.isEmpty,
              value != ".",
              value != "..",
              !value.contains("/"),
              !value.contains("\\"),
              !value.contains("\0")
        else {
            throw DiskIssueTimelineCacheError.unsafePathComponent(value)
        }
    }
}
