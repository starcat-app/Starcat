//
//  DiskWikiCache.swift
//  Starcat
//
//  Wiki 探测结果磁盘缓存（2026-06-15 dong4j 拍板，形态 C = 磁盘 JSON + 双 TTL）。
//
//  模块职责：
//  - 把 `WikiAPI.fetchStatus(owner:repo:)` 一次往返拿到的 `[WikiStatusItem]` 落盘，
//    后续命中直接读盘，省掉重复网络往返。
//  - 给两类消费方共用：
//      1) `RepoAIChatViewModel.bootstrap` 把已收录 wiki 链接喂给 chat system prompt
//         的 `{starcatResources}` section；
//      2) （未来）详情页 toolbar Wiki popover / 搜索详情卡片渲染时优先读 cache。
//  - 暴露 `@Observable` 派生量给设置页存储 Tab 渲染「Wiki 探测缓存 X 项 · Y KB」+ 清除按钮。
//
//  关键设计（与 `DiskAnySearchCache` 的差异 / 已踩过的坑）：
//    1. **TTL 写进 snapshot 自身**：不像 AnySearch cache 用文件 mtime + 全局 TTL 常量
//       判过期，本 cache 在 snapshot JSON 里直接存 `nextProbeAt`，read 时只看
//       `now < nextProbeAt` 就够了。这样**双 TTL**（已收录 30 天 / 任一未收录 3 天）
//       可以按"本次探测结果"动态计算，不需要为两种 TTL 拆目录。
//    2. **零 LRU**：wiki 数据极小（每个 repo < 1KB，10000 repos < 10MB），TTL 自然
//       控制重探频率，文件不会无限增长（一个 repo 永远只有一份 JSON）。**少一套机制
//       少一套 bug**，与翻译缓存（50MB / 60d LRU）/ AnySearch cache（30MB LRU）的
//       重量级方案明确分开。
//    3. **路径用 `<owner>/<repo>.json`**：与 HOM-68 v2 / HOM-69 / HOM-70 一脉相承
//       —— 按 owner/repo 而非 repo_id，让 ephemeral repo（搜索弹窗 id=0）也能命中，
//       Finder 排查也直观。
//    4. **不做单 repo 清理入口**：跟翻译缓存"翻译资产与 star 状态解耦"同款决策；
//       unstar 不删 wiki cache。设置页只有"清除全部"一个总闸。
//    5. **SWR 不在本层处理**：cache 只回答"现在 fresh 还是 stale"，SWR 的"返回旧值 +
//       后台刷新"由上层 `WikiContextService` 编排。本层保持纯 CRUD + freshness 判定。
//    6. **路径校验**：owner / repo 来自用户 star 数据，理论上 GitHub 已校验过字符集，
//       但防御性走 `assertSafePathComponent` 挡 `..` / `/` 等 path traversal 形态。
//

import Foundation
import Observation

/// Wiki 缓存错误。
enum DiskWikiCacheError: LocalizedError {
    case applicationSupportUnavailable
    case unsafePathComponent(String)

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return String(localized: "cache.wiki.error.applicationSupportUnavailable")
        case .unsafePathComponent(let value):
            return String(format: String(localized: "cache.wiki.error.unsafePathComponentFormat"), value)
        }
    }
}

/// Wiki 探测结果的"新鲜度"。
enum WikiCacheFreshness: Sendable, Equatable {
    /// `now < snapshot.nextProbeAt`：直接用。
    case fresh
    /// `now >= snapshot.nextProbeAt`：返回旧值给调用方使用，同时由调用方决定要不要后台刷新。
    case stale
}

/// 磁盘缓存里一个 repo 的 wiki 探测快照。
///
/// 一个 repo 只有一份此结构（owner/repo 唯一定位文件路径）。
struct WikiCacheSnapshot: Codable, Sendable, Equatable {

    /// GitHub owner / org login。
    let owner: String

    /// GitHub repo 名（短名，不含 owner 前缀）。
    let repo: String

    /// 本次探测时刻（UTC）。给排查 / UI 显示用，**不参与 fresh / stale 判定**——
    /// 判定一律看 `nextProbeAt`。
    let probedAt: Date

    /// 下一次重探时刻（UTC）。`now < nextProbeAt` → fresh；`now >= nextProbeAt` → stale。
    ///
    /// 计算规则（`Self.computeNextProbeAt`）：
    /// - 任意 source 是 `not_indexed` / `error` / `unknown` → `now + 3 天`（让"新收录"能被发现）；
    /// - 全部 3 源都 `indexed` → `now + 30 天`（省 API）。
    let nextProbeAt: Date

    /// 探测结果原样（网络 DTO 直接落盘，wire schema = disk schema，未上线无迁移负担）。
    let items: [WikiStatusItem]

    /// 已收录链接列表（派生属性，UI / prompt 注入用）。
    /// 与 `RepoWikiMenuState.make` 的过滤规则保持一致 —— 只保留 indexed + http(s) + 有 host。
    var indexedLinks: [WikiLink] {
        RepoWikiMenuState.make(items: items)
    }

    /// 按当前 `now` 判定本快照的新鲜度。
    func freshness(at now: Date = Date()) -> WikiCacheFreshness {
        now < nextProbeAt ? .fresh : .stale
    }

    /// 根据探测结果算下一次重探时刻（双 TTL 策略）。
    ///
    /// `nonisolated static`：纯函数，测试可从 sync 上下文直接断言。
    nonisolated static func computeNextProbeAt(
        items: [WikiStatusItem],
        now: Date = Date()
    ) -> Date {
        let hasUnindexed = items.contains { item in
            item.status != .indexed
        }
        let ttl: TimeInterval = hasUnindexed ? shortTTL : longTTL
        return now.addingTimeInterval(ttl)
    }

    /// 任一源未收录时的短 TTL：3 天。让"今天未收录、下周收录"的 repo 能被刷出来。
    nonisolated static let shortTTL: TimeInterval = 3 * 24 * 60 * 60

    /// 全部源都已收录时的长 TTL：30 天。已收录的 wiki URL pattern 基本永久稳定，省 API。
    nonisolated static let longTTL: TimeInterval = 30 * 24 * 60 * 60
}

/// Wiki 磁盘缓存（线程：所有公开方法 `@MainActor`）。
///
/// 单例由 `DiskWikiCache.shared` 暴露；测试通过 `init(rootOverride:)` 注入临时目录隔离。
@MainActor
@Observable
final class DiskWikiCache {

    /// 进程级单例。设置页 + 多消费方 + tests 共用同一份 Observable 状态。
    static let shared = DiskWikiCache()

    // MARK: - Observable 派生量（设置页存储 Tab 渲染用）

    /// 缓存条目数（按 `<owner>/<repo>.json` 文件计）。
    private(set) var itemCount: Int = 0

    /// 全部缓存文件总字节数。
    private(set) var totalBytes: Int64 = 0

    // MARK: - 内部状态

    private let fileManager: FileManager
    private let rootOverride: URL?

    private let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        return enc
    }()

    private let decoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }()

    /// 默认走 `Application Support/com.starcat.app/wiki-cache/`。
    /// `rootOverride` 仅供单元测试隔离用。
    init(fileManager: FileManager = .default, rootOverride: URL? = nil) {
        self.fileManager = fileManager
        self.rootOverride = rootOverride
        reload()
    }

    // MARK: - 读

    /// 读盘命中？返回 nil 表示 miss（文件不存在 / 损坏 / 路径非法）。
    ///
    /// **不删过期文件**：本 cache 没 sweep / LRU，stale 文件留盘，下次 write 时覆写。
    /// fresh / stale 由调用方根据 `snapshot.freshness(at:)` 决策。
    func load(owner: String, repo: String) -> WikiCacheSnapshot? {
        let url: URL
        do {
            url = try cacheFileURL(owner: owner, repo: repo)
        } catch {
            AppLog.ai.warning("Wiki cache: invalid path component owner=\(owner, privacy: .public) repo=\(repo, privacy: .public)")
            return nil
        }
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            AppLog.ai.warning("Wiki cache: read failed path=\(url.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }

        do {
            return try decoder.decode(WikiCacheSnapshot.self, from: data)
        } catch {
            // 损坏 JSON → 删文件让下次 miss 后重新写入（与 HOM-69 / HOM-70 同款兜底）。
            AppLog.ai.warning("Wiki cache: decode failed, removing path=\(url.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            try? fileManager.removeItem(at: url)
            reload()
            return nil
        }
    }

    // MARK: - 写

    /// 写入一份新快照（覆写同一 owner/repo 下旧文件）。
    func save(snapshot: WikiCacheSnapshot) throws {
        let url = try cacheFileURL(owner: snapshot.owner, repo: snapshot.repo)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
        reload()
    }

    // MARK: - 清理

    /// 设置页"清除 Wiki 缓存"按钮入口：删整个 `wiki-cache/` 目录后立即 reload。
    func deleteEverything() throws {
        let root = try rootURL()
        if fileManager.fileExists(atPath: root.path) {
            try fileManager.removeItem(at: root)
        }
        reload()
    }

    // MARK: - 重扫盘：刷新 totalBytes / itemCount

    /// 扫盘更新派生量。**只读统计，不删任何文件**（与 `DiskAnySearchCache.reload` 同款语义）。
    func reload() {
        var total: Int64 = 0
        var count: Int = 0

        guard let root = try? rootURL(),
              fileManager.fileExists(atPath: root.path) else {
            self.totalBytes = 0
            self.itemCount = 0
            return
        }

        for file in collectJSONFiles(under: root) {
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
                count += 1
            }
        }

        self.totalBytes = total
        self.itemCount = count
    }

    // MARK: - 私有：路径

    private func rootURL() throws -> URL {
        if let rootOverride { return rootOverride }
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw DiskWikiCacheError.applicationSupportUnavailable
        }
        return appSupport
            .appendingPathComponent(AppConstants.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("wiki-cache", isDirectory: true)
    }

    /// `wiki-cache/<owner>/<repo>.json`。
    private func cacheFileURL(owner: String, repo: String) throws -> URL {
        try Self.assertSafePathComponent(owner)
        try Self.assertSafePathComponent(repo)
        return try rootURL()
            .appendingPathComponent(owner, isDirectory: true)
            .appendingPathComponent("\(repo).json")
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

    /// 路径段安全校验：挡 `..` / 含路径分隔符 / 空串 / 控制字符。
    /// 与 `WikiAPI.isValidRepoPart` 共同构成多层防御。
    nonisolated static func assertSafePathComponent(_ value: String) throws {
        guard !value.isEmpty,
              value != ".",
              value != "..",
              !value.contains("/"),
              !value.contains("\\"),
              !value.contains("\0")
        else {
            throw DiskWikiCacheError.unsafePathComponent(value)
        }
    }
}
