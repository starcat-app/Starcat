//
//  TrendingLanguageStore.swift
//  Starcat
//
//  trending sidebar 语言列表的状态容器（2026-06-11 dong4j 新增）。
//
//  用途：
//  - 在 App 启动 / Home 页面进入时拉取后端 `/api/v1/languages`（聚合接口）
//  - 把结果缓存为 [TrendingLanguageAggregateDTO]，供 SidebarView 驱动 trending 语言列表
//  - 后端返空 / 不可达时：优先用上次成功的磁盘快照；再退 `trending_repos` 全部语言桶计数；
//    最后才用 `fallbackList`（count=0）保证侧栏仍有语言入口
//
//  历史背景（已踩过的坑）：
//  - SidebarView 的 `trendingLanguages` 之前从 `HomeViewModel.languageStats`（用户本地 stars 聚合）
//    读，与 trending 后端**实际是否有这些语言的 repo** 完全脱钩——用户是 Swift 开发者但本周
//    trending 一个 Swift 都没有时，sidebar 仍展示 Swift，点进去 0 条数据。
//  - 后端 `/api/v1/languages` v1（爬 GitHub trending 页面）返 700+ 全量语言菜单，绝大多数语言
//    在我们库里没数据。前端如果直接用，问题更严重。
//  - 改造：后端 v2 改基于 trending_repos 实际数据聚合 + 加 `__uncategorized__` 一项；前端切
//    sidebar 数据源到本 Store。
//  - 2026-08-08：聚合网关未部署时 TLS 失败，语言接口无本地缓存导致侧栏「趋势」总数空白，
//    而中栏仍能读 `trending_repos`——补磁盘快照 + repo 桶计数兜底。
//
//  设计约束：
//  - @MainActor + @Observable：sidebar 直接观察 `aggregates` 变化自动重渲染
//  - 语言聚合不写 GRDB schema（避免额外 migration）；磁盘 JSON 与 `trending_repos` 复用即可
//  - 失败兜底顺序：内存 aggregates → 磁盘快照 → daily/all repo 缓存计数 → fallbackList
//

import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class TrendingLanguageStore {

    // MARK: - 状态

    /// 当前后端聚合结果(dong4j 2026-06-16 调整: **未分类排第 1 位**, 其余按 count DESC 排好;
    /// 空数组 = 还未拉到 / 后端返空)。
    ///
    /// SidebarView 直接 ForEach 这个数组，转换成 `TrendingLanguage` row 渲染。
    /// 数组**不**包含 `.all`——「全部语言」是 sidebar 的固定首行，由 view 层独立渲染。
    private(set) var aggregates: [TrendingLanguageAggregateDTO] = []

    /// 最近一次拉取的状态，UI 可以观察决定是否显示加载指示。
    /// 当前 sidebar 的语言区域不显示 loader（列表很短，几乎瞬间到货 + 有 fallback 兜底），
    /// 仅作 debug / 未来扩展用。
    private(set) var loadState: LoadState = .idle

    /// `/languages` 与磁盘快照都不可用时，用「今日 / 全部语言」榜单缓存行数兜底侧栏总数。
    private(set) var repoCacheFallbackTotal: Int?

    enum LoadState: Equatable {
        case idle
        case loading
        case success
        case failed(String)
    }

    // MARK: - 兜底列表

    /// 后端不可达 / 返空时使用的兜底语言列表。
    ///
    /// 选用与 GitHub Linguist top languages 高度重合的一组常见语言；count 字段填 0
    /// 让 sidebar 行尾不显示数字（与「真聚合且 count > 0」的视觉差异由 view 层决定是否展示 count）。
    ///
    /// 顺序与后端 `/api/v1/languages` SQL 排序一致(dong4j 2026-06-16 调整):
    /// **未分类排第 1 位**, 其余按 count desc(兜底数据 count 全为 0,等价于按字母序)。
    /// SidebarView 已经把「全部」作为 sidebar 的固定首行独立渲染,本数组不再 prepend `.all`。
    static let fallbackList: [TrendingLanguageAggregateDTO] = [
        .init(key: TrendingLanguage.uncategorizedKey,
              label: "Uncategorized",
              count: 0),
        .init(key: "JavaScript", label: "JavaScript", count: 0),
        .init(key: "TypeScript", label: "TypeScript", count: 0),
        .init(key: "Python", label: "Python", count: 0),
        .init(key: "Go", label: "Go", count: 0),
        .init(key: "Rust", label: "Rust", count: 0),
        .init(key: "Java", label: "Java", count: 0),
        .init(key: "Swift", label: "Swift", count: 0),
        .init(key: "C++", label: "C++", count: 0),
        .init(key: "C", label: "C", count: 0),
        .init(key: "Shell", label: "Shell", count: 0),
    ]

    // MARK: - 依赖

    private let api: TrendingAPI
    private let trendingRepository: (any TrendingRepositoryProtocol)?
    private let diskCacheURL: URL?
    private var diskCachedAggregates: [TrendingLanguageAggregateDTO] = []

    /// 当前 in-flight 的拉取任务，新调进来取消老任务避免 race（同 `TrendingViewModel.reload` 模式）。
    private var currentLoadTask: Task<Void, Never>?

    // MARK: - Init

    /// - Parameters:
    ///   - api: trending languages 网络客户端
    ///   - trendingRepository: 可选；网络失败时用 `trending_repos` daily/all 桶计数兜底侧栏总数
    ///   - diskCacheURL: 单测可注入临时文件；默认 Application Support 下 JSON
    init(
        api: TrendingAPI,
        trendingRepository: (any TrendingRepositoryProtocol)? = nil,
        diskCacheURL: URL? = nil
    ) {
        self.api = api
        self.trendingRepository = trendingRepository
        self.diskCacheURL = diskCacheURL ?? Self.defaultDiskCacheURL()
        self.diskCachedAggregates = Self.loadDiskCache(from: self.diskCacheURL)
        // 启动即用磁盘快照填内存，避免首屏 reload 失败前侧栏总数空白一帧。
        if aggregates.isEmpty, !diskCachedAggregates.isEmpty {
            aggregates = diskCachedAggregates
        }
    }

    // MARK: - Public API

    /// 拉取后端聚合语言列表并更新 `aggregates`。
    ///
    /// 调用时机：
    /// - HomeView 首次进入时（`task` modifier）
    /// - 用户在设置页改 baseURL / API Key 后（AppDependencies 主动调）
    ///
    /// 行为：
    /// - 拉成功且 data 非空 → 写入 `aggregates`、落盘、状态 `.success`
    /// - 拉成功但 data 空 → 保留上次真实结果；状态 `.success`
    /// - 拉失败 → 保留内存 / 磁盘快照；必要时用 repo 缓存行数兜底；状态 `.failed`
    func reload() async {
        currentLoadTask?.cancel()

        let task = Task { [weak self] in
            guard let self else { return }
            self.loadState = .loading

            do {
                let dtos = try await self.api.fetchLanguages()
                guard !Task.isCancelled else { return }
                if !dtos.isEmpty {
                    self.aggregates = dtos
                    self.diskCachedAggregates = dtos
                    self.persistDiskCache(dtos)
                    self.repoCacheFallbackTotal = nil
                } else if self.aggregates.isEmpty, !self.diskCachedAggregates.isEmpty {
                    self.aggregates = self.diskCachedAggregates
                }
                self.loadState = .success
                AppLog.network.debug("Trending languages loaded: \(dtos.count) entries")
            } catch {
                guard !Task.isCancelled else { return }
                if self.aggregates.isEmpty, !self.diskCachedAggregates.isEmpty {
                    self.aggregates = self.diskCachedAggregates
                }
                await self.refreshRepoCacheFallbackTotalIfNeeded()
                self.loadState = .failed(error.localizedDescription)
                AppLog.network.warning(
                    "Trending languages load failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        currentLoadTask = task
        await task.value
    }

    /// SidebarView 实际使用的「展示用」数组。
    ///
    /// 优先真实聚合 → 磁盘快照 → `fallbackList`。
    var displayList: [TrendingLanguageAggregateDTO] {
        if !aggregates.isEmpty { return aggregates }
        if !diskCachedAggregates.isEmpty { return diskCachedAggregates }
        return Self.fallbackList
    }

    /// 侧栏「趋势」模式行右侧总数。
    ///
    /// 不用 fallbackList 的全 0 去冒充总数（否则 `reduce` 得 0 → UI 隐藏徽章）。
    /// 顺序：语言聚合/磁盘快照之和 → `trending_repos` daily/all 行数。
    var sidebarTotalCount: Int? {
        let source: [TrendingLanguageAggregateDTO]
        if !aggregates.isEmpty {
            source = aggregates
        } else if !diskCachedAggregates.isEmpty {
            source = diskCachedAggregates
        } else {
            return repoCacheFallbackTotal.flatMap { $0 > 0 ? $0 : nil }
        }
        let total = source.reduce(0) { $0 + $1.count }
        if total > 0 { return total }
        return repoCacheFallbackTotal.flatMap { $0 > 0 ? $0 : nil }
    }

    // MARK: - Disk / repo fallback

    private func refreshRepoCacheFallbackTotalIfNeeded() async {
        guard sidebarTotalCount == nil, let trendingRepository else { return }
        let cached = await trendingRepository.cachedTrending(since: .daily, language: .all)
        guard !Task.isCancelled else { return }
        repoCacheFallbackTotal = cached.isEmpty ? nil : cached.count
    }

    private static func defaultDiskCacheURL() -> URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        return appSupport
            .appendingPathComponent(AppConstants.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("trending-languages-cache.json", isDirectory: false)
    }

    private static func loadDiskCache(from url: URL?) -> [TrendingLanguageAggregateDTO] {
        guard let url else { return [] }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([TrendingLanguageAggregateDTO].self, from: data)
        } catch {
            // 首次安装或文件损坏：静默当无缓存。
            return []
        }
    }

    private func persistDiskCache(_ dtos: [TrendingLanguageAggregateDTO]) {
        guard let diskCacheURL else { return }
        do {
            let directory = diskCacheURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(dtos)
            try data.write(to: diskCacheURL, options: [.atomic])
        } catch {
            AppLog.network.warning(
                "Trending languages disk cache write failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
