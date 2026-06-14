//
//  AnySearchWebProvider.swift
//  Starcat
//
//  AnySearch 到统一 ReferenceCandidate 的适配器。设置在每次请求前从 MainActor 快照，
//  让用户切换匿名模式或 API Key 后立即生效；结果仅做 15 分钟会话缓存。
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

    init(
        cache: SearchSessionCache<SearchProviderPage> = SearchSessionCache(ttl: 15 * 60),
        counter: AnySearchUsageCounter = AnySearchUsageCounter()
    ) {
        self.cache = cache
        self.counter = counter
    }

    func search(_ request: SearchRequest) async throws -> SearchProviderPage {
        guard request.scope == .web || (request.scope == .all && request.includeWebInAll) else { return .empty }
        let config = await MainActor.run {
            let settings = AppSettings.shared
            return (
                enabled: settings.anySearchEnabled,
                anonymous: settings.anySearchAnonymousMode,
                apiKey: settings.anySearchAPIKey()
            )
        }
        guard config.enabled else { throw AnySearchError.disabled }

        // Bearer Key 变化必须自然 miss，避免用户修正无效 Key 后仍读到旧会话缓存。
        // 只使用进程内 hashValue，不把密钥原文写入 key、日志或磁盘。
        let credentialVersion = config.anonymous ? "anonymous" : "bearer:\(config.apiKey?.hashValue ?? 0)"
        let key = "\(request.query.lowercased())|\(credentialVersion)"
        if let cached = await cache.value(for: key) {
            // cache hit 也算一次"用户搜索"：在用户体感里"我又搜了一次"，sessionUsed 必须 +1。
            // 取出 cache 后，把 webMetadata.rateLimit.sessionUsed 用最新计数覆写。
            let used = await counter.increment()
            return cached.withUpdatedSessionUsed(used)
        }

        let client = AnySearchClient(apiKey: config.apiKey, anonymous: config.anonymous)
        let response = try await client.search(AnySearchRequest(
            query: request.query,
            maxResults: min(request.perPage, 20),
            language: Locale.current.language.languageCode?.identifier
        ))
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
        // 网络成功后再 +1（避免 client 抛错时也累加导致 counter 与"成功搜索"不一致）。
        let used = await counter.increment()
        // 把 vendor-specific 的 metadata + rateLimit 适配成 search 域的 WebSearchMetadata。
        // 关键差异：rateLimit.sessionUsed 来自**本地 counter**，不是 API 的 remaining（恒定假值）。
        // limit / resetAt 仍取 API 真值。
        // 解耦目的：未来换 Tavily / Brave provider 时 SearchCoordinator / ViewModel / View
        // 零改动，仅 provider 层重写适配逻辑。
        let webMetadata = WebSearchMetadata(
            totalResults: response.metadata?.totalResults,
            searchTimeMs: response.metadata?.searchTimeMs,
            rateLimit: response.rateLimit.map { rl in
                WebRateLimit(limit: rl.limit, sessionUsed: used, resetAt: rl.resetAt)
            }
        )
        let page = SearchProviderPage(
            repositories: [],
            references: references,
            totalCount: response.metadata?.totalResults ?? references.count,
            hasNextPage: false,
            webMetadata: webMetadata
        )
        await cache.insert(page, for: key)
        return page
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
