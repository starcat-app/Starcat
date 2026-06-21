//
//  AnySearchWebProvider.swift
//  Starcat
//
//  AnySearch 到统一 ReferenceCandidate 的适配器。设置在每次请求前从 MainActor 快照，
//  让用户切换匿名模式或 API Key 后立即生效；结果走两层缓存：
//    - L1 内存：15 分钟会话级缓存（SearchSessionCache，进程退出丢失）
//    - L2 磁盘：6 小时长效缓存（DiskAnySearchCache，HOM-69 / 2026-06-15 加入，跨进程持久）
//

import Foundation

/// 进程级 AnySearch 调用计数器。
///
/// 设计意图（dong4j 2026-06-14）：API 响应头 `x-ratelimit-remaining` 在匿名 / Bearer 两种
/// 模式下都是「假信号」（恒定 limit-2，不反映真实剩余），不能用于驱动 UI 上的「已用 N/M」。
/// 改成进程内本地累加 —— 每次 provider 完成一次搜索调用（含 cache hit）就 +1。
///
/// 关键约束：
/// - **actor 实例必须长寿命**：必须随 `AnySearchWebProvider` 一起被 `SearchCenterViewModel`
///   持有（@State 保活）。若 provider 每次 search 都 new 一个新 counter，计数永远为 1。
/// - **不持久化**：进程退出归零（符合「会话内配额追踪」的轻量定位）。
/// - **含 cache hit**：用户「我点了 N 次搜索」的直观感受 ≠「网络真实调用 N 次」。
///   选前者，因为 chip 的目的是给用户"今天用了多少"的体感，不是给 API 端做精确计数。
actor AnySearchUsageCounter {
    private(set) var count: Int = 0

    /// 累加并返回新值。原子操作。
    func increment() -> Int {
        count += 1
        return count
    }

    /// 仅在单测场景使用。生产代码不应调用。
    func reset() { count = 0 }
}

struct AnySearchWebProvider: SearchProvider {
    let source: SearchSource = .web

    private let cache: SearchSessionCache<SearchProviderPage>
    /// 长寿命的进程级计数器。`SearchCenterViewModel` 通过 @State 保活 provider，
    /// counter 跟着保活，每次 search 累加；进程退出归零。
    private let counter: AnySearchUsageCounter

    /// 磁盘缓存（HOM-69 / 2026-06-15 dong4j 拍板 6h TTL）。
    ///
    /// **二级缓存设计**：L1 内存（15min）+ L2 磁盘（6h）。
    ///   - L1 命中：直接返回，0 IO；
    ///   - L1 miss → 查 L2：命中即把 disk 上的 `AnySearchResponse` 解码后 map 成
    ///     `SearchProviderPage`（map 开销 < 1ms），同时回填 L1 避免再访 L2；
    ///   - 两者都 miss：调 client 打网络 → 同步写两层。
    ///
    /// 不抹掉 L1：L1 在 15min 内省一次解码 + 文件 IO；L2 让用户跨进程 / 6h 内重复查
    /// 同一关键词都命中。两层叠加而非替换。
    ///
    /// 测试场景：传 `diskCache: nil` 完全关闭磁盘路径；或传 `DiskAnySearchCache(rootOverride:)`
    /// 的实例隔离不污染真实路径。
    private let diskCache: DiskAnySearchCache?
    private let entitlementGate: EntitlementGate?

    init(
        cache: SearchSessionCache<SearchProviderPage> = SearchSessionCache(ttl: 15 * 60),
        counter: AnySearchUsageCounter = AnySearchUsageCounter(),
        diskCache: DiskAnySearchCache? = nil,
        entitlementGate: EntitlementGate? = nil
    ) {
        self.cache = cache
        self.counter = counter
        self.entitlementGate = entitlementGate
        // 默认在主线程构造 → 引用 .shared 单例；非主线程构造（理论不会发生）则置 nil。
        // 测试显式传 nil 可彻底关闭磁盘路径，避免污染真实 appSupport 目录。
        if let injected = diskCache {
            self.diskCache = injected
        } else if Thread.isMainThread {
            self.diskCache = MainActor.assumeIsolated { DiskAnySearchCache.shared }
        } else {
            self.diskCache = nil
        }
    }

    func search(_ request: SearchRequest) async throws -> SearchProviderPage {
        guard request.scope == .web || (request.scope == .all && request.includeWebInAll) else { return .empty }
        // 2026-06-21 dong4j 拍板：网页搜索对所有用户开放，删 Pro 拦截。
        // 旧实现：`try entitlementGate?.requirePro(.anySearchWeb)` → 失败时上层
        // SearchCenterViewModel 设 paywallContext 弹付费墙。
        // 现版本：entitlementGate 字段保留（其他能力仍在用），provider 这一层不再抛
        // `EntitlementGateError.requiresPro` —— AnySearch 永远不阻挡 free 用户。
        // 未来若加"每日 N 次免费"等软限速，仍可复用 entitlementGate 注入配额检查器。
        let config = await MainActor.run {
            let settings = AppSettings.shared
            return (
                enabled: settings.anySearchEnabled,
                anonymous: settings.anySearchAnonymousMode,
                apiKey: settings.anySearchAPIKey()
            )
        }
        guard config.enabled else { throw AnySearchError.disabled }

        // Bearer Key 变化必须让 L1 自然 miss，避免用户修正无效 Key 后仍读到旧会话缓存。
        // 只使用进程内 hashValue，不把密钥原文写入 key、日志或磁盘。
        let credentialVersion = config.anonymous ? "anonymous" : "bearer:\(config.apiKey?.hashValue ?? 0)"
        // L1 内存 cache key 必须把 filters fingerprint 纳入 —— 同 query 切 domain / zone /
        // contentTypes / maxResults 时如果还命中旧 cache 就违反"应用筛选"语义。
        // fingerprint 用 sorted+join 而非 hashValue，跨进程稳定（虽然 cache 是内存的,
        // 显式稳定 key 更利于排障）。
        let filtersFingerprint = request.anySearchFilters.fingerprint
        let memKey = "\(request.query.lowercased())|\(credentialVersion)|\(filtersFingerprint)"
        if let cached = await cache.value(for: memKey) {
            // L1 命中也算一次"用户搜索"：在用户体感里"我又搜了一次"，sessionUsed +1。
            let used = await counter.increment()
            return cached.withUpdatedSessionUsed(used)
        }

        // 构造本次要发的 request（同时复用于 L2 disk key 派生）。
        let filters = request.anySearchFilters
        let effectiveMaxResults = min(max(1, filters.maxResults), 100)
        let anyRequest = AnySearchRequest(
            query: request.query,
            maxResults: effectiveMaxResults,
            domain: filters.domain,
            contentTypes: filters.contentTypes.isEmpty ? nil : Array(filters.contentTypes).sorted(),
            zone: filters.zone?.rawValue,
            language: Locale.current.language.languageCode?.identifier
        )

        // L2 磁盘 cache 命中：直接 map 成 SearchProviderPage 返回，同时回填 L1。
        //
        // disk key 不含 credentialVersion —— 磁盘 cache 按"搜索条件"维度缓存，
        // 用户换 API Key 不应让全部磁盘缓存失效（结果与 key 无关，跟 query / domain
        // / filters 才有关）。与 L1 内存 cache 的 credentialVersion 守护不冲突：
        // L1 是"会话内一致性"，L2 是"长效结果缓存"。
        //
        // 注：L2 写盘前已清空 rateLimit（持久化语义见 `AnySearchResponse` 注释），
        // 所以构造 SearchProviderPage 时 webMetadata.rateLimit 为 nil（UI 不显示配额条），
        // 直到下次 cache miss 触发真实 HTTP 后才会拿到新 rateLimit。这是有意取舍：
        // 缓存命中节省了一次 API 调用，但用户暂时看不到配额条。
        if let disk = diskCache,
           let cachedResponse = try? await disk.loadGlobal(request: anyRequest) {
            let used = await counter.increment()
            let page = makePage(from: cachedResponse, sessionUsed: used)
            await cache.insert(page, for: memKey)
            return page
        }

        let client = AnySearchClient(apiKey: config.apiKey, anonymous: config.anonymous)
        let response = try await client.search(anyRequest)
        // 网络成功后再 +1（避免 client 抛错时也累加导致 counter 与"成功搜索"不一致）。
        let used = await counter.increment()
        let page = makePage(from: response, sessionUsed: used)
        await cache.insert(page, for: memKey)
        // 写磁盘 L2：失败仅静默吞错（不能因写盘失败让用户没看到结果）。
        if let disk = diskCache {
            try? await disk.saveGlobal(request: anyRequest, response: response)
        }
        return page
    }

    /// 把 `AnySearchResponse` 映射成 search 模块通用的 `SearchProviderPage`。
    /// L2 命中 + L2 miss 走网络两条路径共用同一映射逻辑，避免分支两份。
    private func makePage(from response: AnySearchResponse, sessionUsed: Int) -> SearchProviderPage {
        let references = response.results.map { result in
            ReferenceCandidate(
                normalizedURL: result.normalizedURL,
                originalURL: result.url,
                title: result.title,
                snippet: result.snippet,
                domain: result.sourceDomain ?? result.normalizedURL.host ?? "Web",
                source: .web
            )
        }
        // 把 vendor-specific 的 metadata + rateLimit 适配成 search 域的 WebSearchMetadata。
        // rateLimit.sessionUsed 来自**本地 counter**，不是 API 的 remaining（恒定假值）。
        // limit / resetAt 仍取 API 真值；L2 命中时 rateLimit 整体为 nil（cache 写盘时清空）。
        let webMetadata = WebSearchMetadata(
            totalResults: response.metadata?.totalResults,
            searchTimeMs: response.metadata?.searchTimeMs,
            rateLimit: response.rateLimit.map { rl in
                WebRateLimit(limit: rl.limit, sessionUsed: sessionUsed, resetAt: rl.resetAt)
            }
        )
        return SearchProviderPage(
            repositories: [],
            references: references,
            totalCount: response.metadata?.totalResults ?? references.count,
            hasNextPage: false,
            webMetadata: webMetadata
        )
    }
}

private extension SearchProviderPage {
    /// 把 cache 命中时取出的 page 复制一份，仅把 webMetadata.rateLimit.sessionUsed 字段
    /// 替换成最新本地计数值。其它字段（references / totalCount / hasNextPage / metadata
    /// 的 totalResults / searchTimeMs / rateLimit.limit / resetAt）保持原样。
    func withUpdatedSessionUsed(_ used: Int) -> SearchProviderPage {
        guard let oldMeta = webMetadata, let oldRL = oldMeta.rateLimit else { return self }
        let newRL = WebRateLimit(limit: oldRL.limit, sessionUsed: used, resetAt: oldRL.resetAt)
        let newMeta = WebSearchMetadata(
            totalResults: oldMeta.totalResults,
            searchTimeMs: oldMeta.searchTimeMs,
            rateLimit: newRL
        )
        return SearchProviderPage(
            repositories: repositories,
            references: references,
            totalCount: totalCount,
            hasNextPage: hasNextPage,
            webMetadata: newMeta
        )
    }
}
