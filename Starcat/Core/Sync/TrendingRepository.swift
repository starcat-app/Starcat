//
//  TrendingRepository.swift
//  Starcat
//
//  Trending 数据仓库。
//
//  职责：
//  - 调用 TrendingAPI 获取数据
//  - 内存缓存避免频繁请求
//  - 提供便捷方法给 ViewModel
//
//  设计约束：
//  - 不做持久化存储，Trending 数据由 API 提供
//  - 缓存 TTL：daily 1小时，weekly 6小时，monthly 12小时
//

import Foundation

/// TrendingRepository 协议。
/// 便于测试时注入 Mock。
protocol TrendingRepositoryProtocol: Sendable {
    /// 获取 Trending 仓库列表。
    func fetchTrending(since: TrendingPeriod, language: TrendingLanguage) async throws -> [TrendingRepo]
}

/// Trending 数据仓库实现。
actor TrendingRepository: TrendingRepositoryProtocol {

    // MARK: - Cache

    private struct CacheKey: Hashable {
        let period: TrendingPeriod
        let language: TrendingLanguage
    }

    /// 缓存条目
    private struct CacheEntry {
        let repos: [TrendingRepo]
        let cachedAt: Date

        /// 缓存是否过期
        func isExpired(ttl: TimeInterval) -> Bool {
            Date().timeIntervalSince(cachedAt) > ttl
        }
    }

    // MARK: - Properties

    private let api: TrendingAPI
    /// 内存缓存。按 period + language 分桶，避免切换筛选项时把刚拉到的数据覆盖掉。
    private var cache: [CacheKey: CacheEntry] = [:]

    // MARK: - TTL

    /// 根据周期返回缓存 TTL（秒）
    static func ttl(for period: TrendingPeriod) -> TimeInterval {
        switch period {
        case .daily:   return 60 * 60       // 1 小时
        case .weekly:  return 6 * 60 * 60   // 6 小时
        case .monthly: return 12 * 60 * 60  // 12 小时
        }
    }

    // MARK: - Initialization

    init(api: TrendingAPI = TrendingAPI()) {
        self.api = api
    }

    // MARK: - Public API

    /// 获取 Trending 仓库列表。
    ///
    /// 策略：
    /// 1. 检查缓存是否存在且未过期
    /// 2. 若缓存有效，直接返回缓存数据
    /// 3. 否则调用 API 获取新数据，更新缓存后返回
    func fetchTrending(
        since: TrendingPeriod,
        language: TrendingLanguage
    ) async throws -> [TrendingRepo] {
        let key = CacheKey(period: since, language: language)

        // 检查缓存
        if let cached = cache[key],
           !cached.isExpired(ttl: Self.ttl(for: since)) {
            AppLog.network.debug("Trending cache hit: \(since.rawValue)/\(language.rawValue)")
            return cached.repos
        }

        // 缓存未命中或已过期，调用 API
        AppLog.network.info("Fetching trending: \(since.rawValue)/\(language.rawValue)")
        let repos = try await api.fetchTrending(since: since, language: language)

        // 更新缓存
        cache[key] = CacheEntry(
            repos: repos,
            cachedAt: Date()
        )

        return repos
    }
}
