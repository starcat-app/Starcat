//
//  AnySearchWebProvider.swift
//  Starcat
//
//  AnySearch 到统一 ReferenceCandidate 的适配器。设置在每次请求前从 MainActor 快照，
//  让用户切换匿名模式或 API Key 后立即生效；结果仅做 15 分钟会话缓存。
//

import Foundation

struct AnySearchWebProvider: SearchProvider {
    let source: SearchSource = .web

    private let cache: SearchSessionCache<SearchProviderPage>

    init(cache: SearchSessionCache<SearchProviderPage> = SearchSessionCache(ttl: 15 * 60)) {
        self.cache = cache
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
        if let cached = await cache.value(for: key) { return cached }

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
        let page = SearchProviderPage(
            repositories: [],
            references: references,
            totalCount: response.metadata?.totalResults ?? references.count,
            hasNextPage: false
        )
        await cache.insert(page, for: key)
        return page
    }
}
