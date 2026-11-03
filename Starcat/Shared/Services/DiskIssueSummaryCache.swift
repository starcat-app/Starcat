//
//  DiskIssueSummaryCache.swift
//  Starcat
//
//  Issue 总结磁盘缓存。
//
//  为什么走文件、不入库（与 DiskIssueTimelineCache 同一套理由）：
//  - 总结是可随时重新生成的 AI 派生内容，不是用户私有数据。
//  - 通知行已经在 SQLite；再加总结表要 `registerVN`，老用户库会被绑死。
//  - 形态跟 timeline / Wiki 一样：Application Support JSON，重启后面板直接回放，
//    由用户看时间戳后自己决定是否重新总结。
//
//  路径：`issue-summary-cache/<owner>/<repo>/<language>/<number>.json`
//  语言进路径：切换 AI 输出语言后是另一份缓存，各自带各自的 generatedAt。
//

import Foundation

/// 一条 Issue 总结的落盘快照。
struct IssueSummaryCacheSnapshot: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let owner: String
    let repo: String
    let number: Int
    /// AI 输出语言描述符原文，加载时精确比对；路径上只保留安全 slug。
    let language: String
    /// 成功完成时刻，面板 footer 展示「总结于 …」。
    let generatedAt: Date
    /// 上次成功总结的完整正文。
    let markdown: String
    let title: String
    /// 生成时的完整来源快照：恢复后 `matchesSource` 与内存版共用同一套陈旧判定。
    let payload: ActivityNotificationPayload
    let timeline: [GitHubNotificationIssueTimelineItem]
    /// 只保留统计位（评论数 / 事件数 / 截断标记），prompt 全文不落盘（重生成会重算）。
    let contextStats: ContextStats

    struct ContextStats: Codable, Equatable, Sendable {
        let includedCommentCount: Int
        let availableCommentCount: Int
        let includedEventCount: Int
        let availableEventCount: Int
        let isTruncated: Bool
    }
}

/// Issue 总结磁盘缓存。公开方法都在 `@MainActor`；save 失败只记日志不上抛，
/// 落盘是生成成功的附属动作，不能让它反过来打断会话状态机。
///
/// 测试用 `rootOverride` 隔离，不要碰生产目录。
@MainActor
final class DiskIssueSummaryCache {

    static let shared = DiskIssueSummaryCache()

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
    }

    /// 按 Issue + 语言读取缓存；语言不一致按 miss 处理（不删文件），交给上层重新生成。
    func load(payload: ActivityNotificationPayload, language: String) -> IssueSummaryCacheSnapshot? {
        guard let key = Self.cacheKey(payload: payload, language: language),
              let url = try? cacheFileURL(key: key),
              fileManager.fileExists(atPath: url.path)
        else { return nil }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            AppLog.network.warning(
                "Issue summary cache: read failed path=\(url.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return nil
        }

        do {
            let snapshot = try decoder.decode(IssueSummaryCacheSnapshot.self, from: data)
            guard snapshot.formatVersion == IssueSummaryCacheSnapshot.currentFormatVersion else {
                try? fileManager.removeItem(at: url)
                return nil
            }
            guard snapshot.language == language else { return nil }
            return snapshot
        } catch {
            AppLog.network.warning(
                "Issue summary cache: decode failed, removing path=\(url.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            try? fileManager.removeItem(at: url)
            return nil
        }
    }

    /// 生成成功后落盘；同一 Issue 重新总结会原子覆盖并刷新 generatedAt。
    func save(
        title: String,
        payload: ActivityNotificationPayload,
        timeline: [GitHubNotificationIssueTimelineItem],
        language: String,
        context: GitHubNotificationIssueSummary.Context,
        markdown: String,
        generatedAt: Date
    ) {
        guard let key = Self.cacheKey(payload: payload, language: language),
              !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = try? cacheFileURL(key: key)
        else { return }

        let snapshot = IssueSummaryCacheSnapshot(
            formatVersion: IssueSummaryCacheSnapshot.currentFormatVersion,
            owner: key.owner,
            repo: key.repo,
            number: key.number,
            language: language,
            generatedAt: generatedAt,
            markdown: markdown,
            title: title,
            payload: payload,
            timeline: timeline,
            contextStats: IssueSummaryCacheSnapshot.ContextStats(
                includedCommentCount: context.includedCommentCount,
                availableCommentCount: context.availableCommentCount,
                includedEventCount: context.includedEventCount,
                availableEventCount: context.availableEventCount,
                isTruncated: context.isTruncated
            )
        )
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(snapshot).write(to: url, options: .atomic)
        } catch {
            AppLog.network.warning(
                "Issue summary cache: save failed path=\(url.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - 路径

    private struct CacheKey {
        let owner: String
        let repo: String
        let languageSlug: String
        let number: Int
    }

    enum CacheError: Error {
        case applicationSupportUnavailable
        case unsafePathComponent(String)
    }

    /// owner/repo/number 与 timeline 缓存同源，不跟通知 threadId 绑定；
    /// 缺 number 或仓库全名畸形时返回 nil，缓存静默旁路（功能退化为每次重新生成）。
    private static func cacheKey(payload: ActivityNotificationPayload, language: String) -> CacheKey? {
        guard let number = payload.subjectNumber else { return nil }
        let parts = payload.repositoryFullName.split(separator: "/")
        guard parts.count == 2 else { return nil }
        let owner = String(parts[0])
        let repo = String(parts[1])
        guard (try? assertSafePathComponent(owner)) != nil,
              (try? assertSafePathComponent(repo)) != nil
        else { return nil }
        return CacheKey(owner: owner, repo: repo, languageSlug: languageSlug(language), number: number)
    }

    /// 描述符是 LLM 友好的英文语言名（如 "Simplified Chinese"）；非字母数字折叠成
    /// 连字符得到安全目录名，文件内 `language` 字段仍是精确比对的真源。
    static func languageSlug(_ language: String) -> String {
        var collapsed = String(language.map { ($0.isLetter || $0.isNumber) ? $0 : "-" })
        // 先去首尾连字符，再把连续非字母数字折叠成单个连字符；保持原字符顺序。
        while collapsed.first == "-" { collapsed.removeFirst() }
        while collapsed.last == "-" { collapsed.removeLast() }
        var result = ""
        var previousWasDash = false
        for character in collapsed {
            if character == "-" {
                guard !previousWasDash else { continue }
                previousWasDash = true
            } else {
                previousWasDash = false
            }
            result.append(character)
        }
        return result.isEmpty ? "default" : result
    }

    static func assertSafePathComponent(_ value: String) throws {
        guard !value.isEmpty,
              value != ".",
              value != "..",
              !value.contains("/"),
              !value.contains("\\"),
              !value.contains("\0")
        else {
            throw CacheError.unsafePathComponent(value)
        }
    }

    private func cacheFileURL(key: CacheKey) throws -> URL {
        try Self.assertSafePathComponent(key.languageSlug)
        return try rootURL()
            .appendingPathComponent(key.owner, isDirectory: true)
            .appendingPathComponent(key.repo, isDirectory: true)
            .appendingPathComponent(key.languageSlug, isDirectory: true)
            .appendingPathComponent("\(key.number).json")
    }

    private func rootURL() throws -> URL {
        if let rootOverride { return rootOverride }
        guard let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CacheError.applicationSupportUnavailable
        }
        return appSupport
            .appendingPathComponent(AppConstants.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("issue-summary-cache", isDirectory: true)
    }
}
