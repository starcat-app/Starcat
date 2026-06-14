//
//  DiskAnySearchCache.swift
//  Starcat
//
//  AnySearch 结果磁盘缓存（HOM-69 / 2026-06-15 dong4j 拍板 6h 全局 / 24h AI 摘要 + 30 MB LRU）。
//
//  模块职责：
//  - 给两条 AnySearch 消费路径提供**统一**的磁盘缓存：
//      1. 全局搜索（`AnySearchWebProvider`）：key = SHA256(规范化后的 `AnySearchRequest` JSON)，
//         TTL = 6 小时；
//      2. AI 摘要外部上下文（`AnySearchContextProvider`）：key = `repo_id`，
//         TTL = 24 小时（dong4j 拍板"搜索结果大概率变化不大"）。
//  - 暴露 `@Observable` 派生量给设置页存储 Tab 渲染「搜索缓存 XX 项 · YY KB」。
//  - LRU 淘汰：总占用 > 30 MB 或文件 mtime 超过对应 TTL 时由 `lruSweep` 删掉。
//
//  关键约束（与 `DiskReadmeTranslationCache` 的差异 / 已踩过的坑）：
//    1. **两条路径目录拆开**：`anysearch-cache/global/<sha256[:2]>/<sha256>.json`
//       与 `anysearch-cache/ai-summary/<repo-id>.json`，因为 TTL / key 形态都不同，
//       拆目录让 lruSweep 能按目录使用各自的 TTL 判过期，也方便用户在 Finder 排障。
//    2. **global 目录用前 2 字符分桶**：SHA256 是均匀分布的 16 进制串，按前 2 字符
//       分 256 个桶，避免单目录文件爆炸（macOS HFS+ / APFS 都能扛单目录万级文件
//       但 Finder 打开会卡，分桶让人工排查友好）。
//    3. **`rateLimit` 字段写盘前清空**：rateLimit 是请求时刻的 HTTP 头快照
//       （remaining / resetAt），cache 命中时已过期，再回填给 UI 会显示"剩余 -3 /
//       重置时间已过去 2 小时"。`saveGlobal` 在编码前显式置 nil。
//    4. **键派生稳定性**：`AnySearchRequest` 已是 Codable，但默认 `JSONEncoder` 字典
//       序不稳定 → 不同进程算出的 SHA256 可能漂移。本文件统一用 `.sortedKeys` +
//       snake_case 输出 + `withoutEscapingSlashes` 让 hash 跨进程稳定。
//    5. **AI 摘要 key 用 repo_id 不带 query**：dong4j 决议——repo description 极少变，
//       即使变了 24h 内继续复用旧 cache 也可接受；用 repo_id 命中率最高，简化路径。
//       trending / activity 这类 ephemeral repo 拿不到稳定 GitHub id 时（id == 0），
//       直接绕过本 cache 不写盘（避免所有 ephemeral repo 撞到同 key=0 互相覆盖）。
//    6. **@MainActor + 同步 IO**：与 `DiskReadmeTranslationCache` 同款。单次写入
//       通常 < 30 KB（results.prefix(6) 的 markdown 才几 KB），主线程 IO < 10 ms。
//

import CryptoKit
import Foundation
import Observation

/// 搜索缓存错误。
enum DiskAnySearchCacheError: LocalizedError {
    case applicationSupportUnavailable
    case unsafeKey(String)

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "无法定位搜索缓存目录，请重试或重启应用。"
        case .unsafeKey(let value):
            return "搜索缓存键包含非法字符：\(value)。"
        }
    }
}

/// 搜索缓存类型，决定子目录与 TTL。
enum AnySearchCacheKind: String, Sendable {
    /// 全局搜索 `⌘K` 弹层（AnySearchWebProvider）。
    case global
    /// AI 摘要外部上下文（AnySearchContextProvider）。
    case aiSummary = "ai-summary"
}

/// AnySearch 磁盘缓存（线程：所有公开方法 `@MainActor`）。
///
/// 单例由 `DiskAnySearchCache.shared` 暴露；测试通过 `init(rootOverride:)` 注入
/// 临时目录隔离不污染真实路径。
@MainActor
@Observable
final class DiskAnySearchCache {

    /// 进程级单例。设置页 + provider × 2 + tests 都共用同一份 Observable 状态。
    static let shared = DiskAnySearchCache()

    // MARK: - LRU 策略（dong4j 2026-06-15 拍板）

    /// 总占用上限。超过即触发 LRU 删除（按 mtime 升序删，直到 < limit）。
    private let maxTotalBytes: Int64 = 30 * 1024 * 1024 // 30 MB

    /// 全局搜索单条最长不访问时长。6 小时。
    static let globalTTL: TimeInterval = 6 * 60 * 60

    /// AI 摘要单条最长不访问时长。24 小时（dong4j 拍板"结果变化不大"）。
    static let aiSummaryTTL: TimeInterval = 24 * 60 * 60

    // MARK: - Observable 派生量（设置页存储 Tab 渲染用）

    /// 全部缓存（global + aiSummary）总字节数。
    private(set) var totalBytes: Int64 = 0

    /// 缓存条目数（按所有 JSON 文件计）。
    private(set) var itemCount: Int = 0

    // MARK: - 内部状态

    private let fileManager: FileManager
    private let rootOverride: URL?

    /// upsert 计数（每 5 次触发一次 LRU sweep）。与 `DiskReadmeTranslationCache` 同款。
    private var upsertCountSinceLastSweep: Int = 0
    private let upsertCountSweepThreshold: Int = 5

    /// 值编解码器（**仅用于落盘**，与 HTTP 协议解耦）。
    ///
    /// **关键约束**：不能开 `convertToSnakeCase` / `convertFromSnakeCase`：
    /// `AnySearchResult.normalizedURL`（全大写 URL）会被编码成 `normalized_url`，
    /// 但 `convertFromSnakeCase` 反向解出来是 `normalizedUrl`（小写 url），
    /// 与 struct 属性名不匹配 → decode 全部失败（已踩过坑，见 2026-06-15）。
    /// 磁盘 cache 是内部存储，没必要保持 wire 风格，直接用默认 camelCase 即可。
    private let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return enc
    }()

    private let decoder = JSONDecoder()

    /// 用于计算 key SHA256 的稳定编码器（sortedKeys 保证跨进程 hash 一致）。
    /// 这里**保留** snake_case：key 派生不涉及解码回原 struct，所以无前述大写陷阱；
    /// snake_case 让人工排查 `<sha>.json` 文件时能直接对照 AnySearch HTTP 字段名。
    private let keyEncoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        enc.keyEncodingStrategy = .convertToSnakeCase
        return enc
    }()

    /// 默认走 `Application Support/com.starcat.app/anysearch-cache/`。
    /// `rootOverride` 仅供单元测试隔离用。
    init(fileManager: FileManager = .default, rootOverride: URL? = nil) {
        self.fileManager = fileManager
        self.rootOverride = rootOverride
        reload()
    }

    // MARK: - 全局搜索路径（key = SHA256(request)）

    /// 查命中？命中时 touch mtime 并返回缓存的响应。
    ///
    /// 副作用：每次命中都更新文件 mtime，让 LRU sweep 把"刚命中过的"视为最新访问，
    /// 不在尚未到 TTL 时被错误清理。
    func loadGlobal(request: AnySearchRequest) async throws -> AnySearchResponse? {
        let key = try Self.cacheKey(forRequest: request, encoder: keyEncoder)
        let fileURL = try globalFile(forKey: key)
        return try loadAndTouch(
            at: fileURL,
            maxIdle: Self.globalTTL,
            decode: AnySearchResponse.self
        )
    }

    /// 写入全局搜索结果。写盘前会**清空 `rateLimit`**（持久化语义见 `AnySearchResponse` 注释）。
    func saveGlobal(request: AnySearchRequest, response: AnySearchResponse) async throws {
        let key = try Self.cacheKey(forRequest: request, encoder: keyEncoder)
        let fileURL = try globalFile(forKey: key)
        // 清掉 rateLimit：cache 命中时旧的 remaining / resetAt 已过期，留着会误导 UI。
        let sanitized = AnySearchResponse(
            results: response.results,
            metadata: response.metadata,
            rateLimit: nil
        )
        try writeAtomically(sanitized, to: fileURL)
    }

    // MARK: - AI 摘要外部上下文路径（key = repo_id）

    /// 查命中？仅当 `repoId > 0` 才查（ephemeral repo id == 0 直接跳过）。
    func loadAISummary(repoId: Int64) async throws -> AIExternalContext? {
        guard repoId > 0 else { return nil }
        let fileURL = try aiSummaryFile(forRepoId: repoId)
        return try loadAndTouch(
            at: fileURL,
            maxIdle: Self.aiSummaryTTL,
            decode: AIExternalContext.self
        )
    }

    /// 写入 AI 摘要外部上下文。仅当 `repoId > 0` 才写（ephemeral repo 直接跳过避免撞 key=0）。
    func saveAISummary(repoId: Int64, context: AIExternalContext) async throws {
        guard repoId > 0 else { return }
        let fileURL = try aiSummaryFile(forRepoId: repoId)
        try writeAtomically(context, to: fileURL)
    }

    // MARK: - 清理

    /// 清掉全部搜索缓存（设置页"清除搜索缓存"按钮入口）。
    /// 实现：删完整个 `<root>/anysearch-cache/` 目录后立即 reload。
    func deleteEverything() async throws {
        let root = try rootURL()
        if fileManager.fileExists(atPath: root.path) {
            try fileManager.removeItem(at: root)
        }
        upsertCountSinceLastSweep = 0
        reload()
    }

    // MARK: - LRU sweep

    /// 触发 LRU 淘汰：先按各自 TTL 删过期条目，若总量仍 > 30 MB 则继续按 mtime
    /// 升序删到 < limit 为止。**不在 read 路径触发**，由 upsert 累计 5 次后调一次。
    func lruSweep() throws {
        let root = try rootURL()
        guard fileManager.fileExists(atPath: root.path) else { return }

        let now = Date()
        var entries: [(url: URL, mtime: Date, size: Int64)] = []

        // 1) 先按各自 TTL 删过期 + 收集所有"仍活着"的条目供后续按总量裁剪
        for kind in [AnySearchCacheKind.global, .aiSummary] {
            let kindRoot = root.appendingPathComponent(kind.rawValue, isDirectory: true)
            guard fileManager.fileExists(atPath: kindRoot.path) else { continue }
            let ttl = kind == .global ? Self.globalTTL : Self.aiSummaryTTL

            let files = collectJSONFiles(under: kindRoot)
            for file in files {
                let attrs = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = Int64(attrs?.fileSize ?? 0)
                let mtime = attrs?.contentModificationDate ?? .distantPast
                if now.timeIntervalSince(mtime) > ttl {
                    try? fileManager.removeItem(at: file)
                } else {
                    entries.append((file, mtime, size))
                }
            }
        }

        // 2) 若仍超 30 MB，按 mtime 升序（最久未访问优先）继续删
        var totalBytes: Int64 = entries.reduce(0) { $0 + $1.size }
        if totalBytes > maxTotalBytes {
            entries.sort { $0.mtime < $1.mtime }
            for entry in entries {
                guard totalBytes > maxTotalBytes else { break }
                try? fileManager.removeItem(at: entry.url)
                totalBytes -= entry.size
            }
        }

        // 3) 收拾空桶目录 + 空 kind 目录
        cleanEmptyDirectories()
        upsertCountSinceLastSweep = 0
        reload()
    }

    // MARK: - 重扫盘：刷新 totalBytes / itemCount

    /// 扫盘更新派生量。**与 `lruSweep` 不同**：reload 不删任何文件，纯只读统计。
    func reload() {
        var totalBytes: Int64 = 0
        var itemCount: Int = 0

        guard let root = try? rootURL(),
              fileManager.fileExists(atPath: root.path) else {
            self.totalBytes = 0
            self.itemCount = 0
            return
        }

        for kind in [AnySearchCacheKind.global, .aiSummary] {
            let kindRoot = root.appendingPathComponent(kind.rawValue, isDirectory: true)
            guard fileManager.fileExists(atPath: kindRoot.path) else { continue }
            for file in collectJSONFiles(under: kindRoot) {
                if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    totalBytes += Int64(size)
                    itemCount += 1
                }
            }
        }

        self.totalBytes = totalBytes
        self.itemCount = itemCount
    }

    // MARK: - 私有：通用读写

    /// 命中并 touch mtime。文件不存在 / 过期 / 解码失败都返回 nil。
    private func loadAndTouch<T: Decodable>(
        at fileURL: URL,
        maxIdle: TimeInterval,
        decode: T.Type
    ) throws -> T? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }

        // 过期判定：mtime 超过 TTL 直接当 miss + 删文件（让 LRU 不再背它的体积）。
        if let mtime = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           Date().timeIntervalSince(mtime) > maxIdle {
            try? fileManager.removeItem(at: fileURL)
            return nil
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            AppLog.ai.warning("AnySearch disk cache: read failed path=\(fileURL.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }

        do {
            let value = try decoder.decode(T.self, from: data)
            // touch mtime 表达"最近访问"：让 LRU sweep 优先淘汰真的没人访问的条目。
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
            return value
        } catch {
            // 损坏的 cache → 删文件让下次 miss 后重新写入。
            AppLog.ai.warning("AnySearch disk cache: decode failed, removing path=\(fileURL.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            try? fileManager.removeItem(at: fileURL)
            return nil
        }
    }

    private func writeAtomically<T: Encodable>(_ value: T, to fileURL: URL) throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(value)
        try data.write(to: fileURL, options: .atomic)
        upsertCountSinceLastSweep += 1
        reload()
        try maybeTriggerLRUSweep()
    }

    private func maybeTriggerLRUSweep() throws {
        guard upsertCountSinceLastSweep >= upsertCountSweepThreshold else { return }
        try lruSweep()
    }

    // MARK: - 私有：路径构造

    private func rootURL() throws -> URL {
        if let rootOverride { return rootOverride }
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw DiskAnySearchCacheError.applicationSupportUnavailable
        }
        return appSupport
            .appendingPathComponent(AppConstants.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("anysearch-cache", isDirectory: true)
    }

    /// 全局搜索文件：`anysearch-cache/global/<sha256[:2]>/<sha256>.json`。
    private func globalFile(forKey key: String) throws -> URL {
        // SHA256 输出是 64 字符 hex，理论不会含非法字符；防御性 assert 一次。
        try Self.assertHexKey(key)
        let bucket = String(key.prefix(2))
        return try rootURL()
            .appendingPathComponent(AnySearchCacheKind.global.rawValue, isDirectory: true)
            .appendingPathComponent(bucket, isDirectory: true)
            .appendingPathComponent("\(key).json")
    }

    /// AI 摘要文件：`anysearch-cache/ai-summary/<repo-id>.json`。
    private func aiSummaryFile(forRepoId repoId: Int64) throws -> URL {
        try rootURL()
            .appendingPathComponent(AnySearchCacheKind.aiSummary.rawValue, isDirectory: true)
            .appendingPathComponent("\(repoId).json")
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

    private func cleanEmptyDirectories() {
        guard let root = try? rootURL() else { return }
        for kind in [AnySearchCacheKind.global, .aiSummary] {
            let kindRoot = root.appendingPathComponent(kind.rawValue, isDirectory: true)
            guard fileManager.fileExists(atPath: kindRoot.path) else { continue }
            let buckets = (try? fileManager.contentsOfDirectory(at: kindRoot, includingPropertiesForKeys: nil)) ?? []
            for bucket in buckets where bucket.hasDirectoryPath {
                let leftover = (try? fileManager.contentsOfDirectory(at: bucket, includingPropertiesForKeys: nil)) ?? []
                if leftover.isEmpty {
                    try? fileManager.removeItem(at: bucket)
                }
            }
        }
    }

    // MARK: - 私有：key 派生

    /// 算 `AnySearchRequest` 的稳定缓存 key（SHA256 of sortedKeys snake_case JSON）。
    ///
    /// `nonisolated` + `static`：让测试可以从 sync 上下文断言相同输入产出相同 key。
    nonisolated static func cacheKey(
        forRequest request: AnySearchRequest,
        encoder: JSONEncoder
    ) throws -> String {
        let data = try encoder.encode(request)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// SHA256 hex 校验：必须 64 字符全 hex。防御性兜底（理论上 cacheKey 算出来必合规）。
    private static func assertHexKey(_ key: String) throws {
        guard key.count == 64,
              key.allSatisfy({ $0.isHexDigit })
        else {
            throw DiskAnySearchCacheError.unsafeKey(key)
        }
    }
}
