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
//  - 缓存 TTL：daily 5分钟，weekly 15分钟，monthly 30分钟
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

    /// 缓存条目
    private struct CacheEntry {
        let repos: [TrendingRepo]
        let cachedAt: Date
        let period: TrendingPeriod
        let language: TrendingLanguage

        /// 缓存是否过期
        func isExpired(ttl: TimeInterval) -> Bool {
            Date().timeIntervalSince(cachedAt) > ttl
        }
    }

    // MARK: - Properties

    private let api: TrendingAPI
    /// 内存缓存
    private var cache: CacheEntry?

    // MARK: - TTL

    /// 根据周期返回缓存 TTL（秒）
    private func ttl(for period: TrendingPeriod) -> TimeInterval {
        switch period {
        case .daily:   return 300    // 5 分钟
        case .weekly:  return 900    // 15 分钟
        case .monthly: return 1800   // 30 分钟
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
        // 检查缓存
        if let cached = cache,
           cached.period == since,
           cached.language == language,
           !cached.isExpired(ttl: ttl(for: since)) {
            AppLog.network.debug("Trending cache hit: \(since.rawValue)/\(language.rawValue)")
            return cached.repos
        }

        // 缓存未命中或已过期，调用 API
        AppLog.network.info("Fetching trending: \(since.rawValue)/\(language.rawValue)")
        let repos = try await api.fetchTrending(since: since, language: language)

        // 更新缓存
        cache = CacheEntry(
            repos: repos,
            cachedAt: Date(),
            period: since,
            language: language
        )

        return repos
    }
}
