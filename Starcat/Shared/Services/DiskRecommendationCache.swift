//
//  DiskRecommendationCache.swift
//  Starcat
//
//  相似仓库推荐结果磁盘缓存（2026-06-29，与 `DiskWikiCache` 同款 SWR 形态）。
//
//  模块职责：
//  - 把 `RecommendAPI.fetchRecommendations(repoID:)` 一次往返拿到的 `[RepoRecommendationItem]`
//    落盘，后续命中直接读盘，省掉重复网络往返。
//  - 给 `RepoRecommendationViewModel` 用 SWR 模式消费：
//      1) 详情页打开 → 同步读 cache 立刻显示（秒返回）；
//      2) 后台触发 `RecommendationContextService.refreshInBackground` 异步拉新 + 写盘；
//      3) 同一 repo 多次进入详情页都吃 cache，TTL 过期才重拉。
//  - 暴露 `@Observable` 派生量给设置页存储 Tab 渲染「推荐缓存 X 项 · Y KB」+ 清除按钮。
//
//  与 `DiskWikiCache` 的差异（已踩过的坑 / 推荐场景的特殊性）：
//    1. **key 用 `repoID: Int64` 而非 `owner/repo` 字符串**：RecommendAPI 的入参就是
//       `repoID`（gh_repo_id），保持 key 与 API 同步省一次 join；且推荐不面向
//       ephemeral repo（trending/weekly id=0），repoID > 0 是天然守卫。
//    2. **TTL 比 wiki 短（24h / 1h vs wiki 30d / 3d）**：wiki 一旦 indexed 基本永久
//       稳定，可走月级 TTL；推荐随用户 star 新 repo 会持续更新，**同一天内多次
//       拉**才是合理预期（用户连续进详情页不应感知「数据永远不变」）。
//    3. **不做 stale 后台刷新**：wiki 有 SWR 模式（cachedLinks + refreshInBackground
//       并发去重）是因为 wiki 列表通常较稳定；推荐是"看到新东西"的发现型能力，
//       stale 直接重新拉即可，不保留旧值。`RecommendationContextService` 提供
//       最小同步接口，VM 走简单两段式（cache → fetch）。
//    4. **不做单 repo 清理入口**：与 wiki 同款决策 —— 推荐与 star 状态解耦，
//       unstar 不删 cache。设置页只有"清除全部"一个总闸。
//    5. **错误不落盘**：与 wiki 同款（wiki 也只在 save 成功路径上写盘）。API 失败
//       时保留旧 cache（如果有），下次 loadInitial 自然重试。
//    6. **不做 LRU**：推荐数据极小（每 repo < 1KB，10000 repos < 10MB），TTL 自然
//       控制重探频率。**少一套机制少一套 bug**。
//

import Foundation
import Observation

/// 推荐缓存错误。
enum DiskRecommendationCacheError: LocalizedError {
    case applicationSupportUnavailable

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return String.l10n("cache.recommendation.error.applicationSupportUnavailable")
        }
    }
}

/// 推荐缓存的"新鲜度"。
enum RecommendationCacheFreshness: Sendable, Equatable {
    /// `now < snapshot.nextProbeAt`：直接用。
    case fresh
    /// `now >= snapshot.nextProbeAt`：缓存过期，应重新拉。
    case stale
}

/// 磁盘缓存里一个 repo 的推荐快照。
///
/// 一个 repo 只有一份此结构（repoID 唯一定位文件路径）。
struct RecommendationCacheSnapshot: Codable, Sendable, Equatable {

    /// GitHub repo id（gh_repo_id）。与 `RepoRecommendationItem.repoID` / `Repo.id` 同类型。
    let repoID: Int64

    /// 本次探测时刻（UTC）。给排查 / UI 显示用，**不参与 fresh / stale 判定**——
    /// 判定一律看 `nextProbeAt`。
    let probedAt: Date

    /// 下一次重探时刻（UTC）。`now < nextProbeAt` → fresh；`now >= nextProbeAt` → stale。
    ///
    /// 计算规则（`Self.computeNextProbeAt`）：
    /// - `items.isEmpty` → `now + 1h`（推荐空了，可能是后端还没算 / 用户刚 star 新东西，
    ///   短 TTL 让下次进入能拿到新数据）；
    /// - `!items.isEmpty` → `now + 24h`（有结果了就别每天刷，省 API）。
    let nextProbeAt: Date

    /// 推荐项列表（空数组 = 后端返回了空结果，不是错误状态）。
    let items: [RepoRecommendationItem]

    /// 是否还有下一页（对应原 `RepoRecommendationPage.hasMore`）。
    let hasMore: Bool

    /// 下一页的 offset（`hasMore == true` 时才有值）。
    let nextOffset: Int?

    /// 按当前 `now` 判定本快照的新鲜度。
    func freshness(at now: Date = Date()) -> RecommendationCacheFreshness {
        now < nextProbeAt ? .fresh : .stale
    }

    /// 根据探测结果算下一次重探时刻（双 TTL 策略，与 wiki 同款公式）。
    ///
    /// `nonisolated static`：纯函数，测试可从 sync 上下文直接断言。
    nonisolated static func computeNextProbeAt(
        items: [RepoRecommendationItem],
        now: Date = Date()
    ) -> Date {
        let ttl: TimeInterval = items.isEmpty ? shortTTL : longTTL
        return now.addingTimeInterval(ttl)
    }

    /// 空结果短 TTL：1 小时。推荐随用户 star 新 repo 持续更新，短的 TTL 让
    /// 一天内多次进入详情页能感知到"刚 star 的新东西被推荐了"。
    nonisolated static let shortTTL: TimeInterval = 1 * 60 * 60

    /// 有结果长 TTL：24 小时。推荐 embedding 一旦算过基本稳定，每天刷一次足够。
    nonisolated static let longTTL: TimeInterval = 24 * 60 * 60
}

/// 推荐磁盘缓存（线程：所有公开方法 `@MainActor`）。
///
/// 单例由 `DiskRecommendationCache.shared` 暴露；测试通过 `init(rootOverride:)`
/// 注入临时目录隔离。
@MainActor
@Observable
final class DiskRecommendationCache {

    /// 进程级单例。设置页 + `RecommendationContextService` + tests 共用同一份 Observable 状态。
    static let shared = DiskRecommendationCache()

    // MARK: - Observable 派生量（设置页存储 Tab 渲染用）

    /// 缓存条目数（按 `<repoID>.json` 文件计）。
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

    /// 默认走 `Application Support/com.starcat.app/recommendation-cache/`。
    /// `rootOverride` 仅供单元测试隔离用。
    init(fileManager: FileManager = .default, rootOverride: URL? = nil) {
        self.fileManager = fileManager
        self.rootOverride = rootOverride
        reload()
    }

    // MARK: - 读

    /// 读盘命中？返回 nil 表示 miss（文件不存在 / 损坏 / repoID 无效）。
    ///
    /// **不删过期文件**：本 cache 没 sweep / LRU，stale 文件留盘，下次 write 时覆写。
    /// fresh / stale 由调用方根据 `snapshot.freshness(at:)` 决策。
    func load(repoID: Int64) -> RecommendationCacheSnapshot? {
        guard repoID > 0 else { return nil }
        let url: URL
        do {
            url = try cacheFileURL(repoID: repoID)
        } catch {
            AppLog.network.warning("Recommendation cache: invalid path repoID=\(repoID, privacy: .public)")
            return nil
        }
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            AppLog.network.warning("Recommendation cache: read failed path=\(url.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }

        do {
            return try decoder.decode(RecommendationCacheSnapshot.self, from: data)
        } catch {
            // 损坏 JSON → 删文件让下次 miss 后重新写入（与 wiki / AnySearch / chat history 同款兜底）。
            AppLog.network.warning("Recommendation cache: decode failed, removing path=\(url.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            try? fileManager.removeItem(at: url)
            reload()
            return nil
        }
    }

    // MARK: - 写

    /// 写入一份新快照（覆写同一 repoID 下旧文件）。
    func save(snapshot: RecommendationCacheSnapshot) throws {
        let url = try cacheFileURL(repoID: snapshot.repoID)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
        reload()
    }

    // MARK: - 清理

    /// 设置页"清除推荐缓存"按钮入口：删整个 `recommendation-cache/` 目录后立即 reload。
    func deleteEverything() throws {
        let root = try rootURL()
        if fileManager.fileExists(atPath: root.path) {
            try fileManager.removeItem(at: root)
        }
        reload()
    }

    // MARK: - 重扫盘：刷新 totalBytes / itemCount

    /// 扫盘更新派生量。**只读统计，不删任何文件**（与 `DiskWikiCache.reload` 同款语义）。
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
            throw DiskRecommendationCacheError.applicationSupportUnavailable
        }
        return appSupport
            .appendingPathComponent(AppConstants.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("recommendation-cache", isDirectory: true)
    }

    /// `recommendation-cache/<repoID>.json`。
    ///
    /// 用 Int64 而非 owner/repo 字符串：RecommendAPI 的入参就是 repoID，且推荐
    /// 不面向 ephemeral repo（trending/weekly id=0），所以路径段都是纯数字，
    /// 不需要 path-traversal 校验。
    private func cacheFileURL(repoID: Int64) throws -> URL {
        try rootURL()
            .appendingPathComponent("\(repoID).json")
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
}
