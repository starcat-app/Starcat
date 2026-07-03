//
//  ExternalSearchWebProvider.swift
//  Starcat
//
//  SearchCenter Web tab 的 External Search 适配器。
//
//  关键约束：
//  - Web tab 是单 Provider View，不做跨 Provider 聚合；
//  - `.all` scope 使用 `SearchRequest.externalSearchProvider`，由 ViewModel 写入设置页默认值；
//  - 外部结果只映射为 `ReferenceCandidate`，即使 URL 指向 GitHub repo，也不自动入库。
//

import Foundation

struct ExternalSearchWebProvider: SearchProvider {
    let source: SearchSource = .web

    private let counter: AnySearchUsageCounter

    init(counter: AnySearchUsageCounter = AnySearchUsageCounter()) {
        self.counter = counter
    }

    func search(_ request: SearchRequest) async throws -> SearchProviderPage {
        guard request.scope == .web || (request.scope == .all && request.includeWebInAll) else { return .empty }

        let snapshot = await MainActor.run {
            ExternalSearchRegistry.SettingsSnapshot(settings: AppSettings.shared)
        }
        let registry = ExternalSearchRegistry(settingsSnapshot: snapshot)
        let providerID = request.externalSearchProvider
        guard registry.usableProviderIDs(includeUnverified: false).contains(providerID) else {
            throw unavailableProviderError(providerID, snapshot: snapshot)
        }

        let provider = registry.provider(for: providerID)
        let externalRequest = ExternalSearchRequest(
            query: request.query,
            purpose: .globalSearch,
            maxResults: request.anySearchFilters.maxResults,
            anySearchFilters: providerID == .anySearch ? request.anySearchFilters : nil
        )
        let response = try await provider.search(externalRequest)
        let used = await counter.increment()
        let references = response.hits.map { hit in
            ReferenceCandidate(
                normalizedURL: AnySearchClient.normalize(hit.url) ?? hit.url,
                originalURL: hit.url,
                title: hit.title,
                snippet: hit.snippet ?? hit.extractedText,
                domain: hit.url.host ?? providerID.displayName,
                source: .web
            )
        }
        return SearchProviderPage(
            repositories: [],
            references: references,
            totalCount: response.metadata.totalResults ?? references.count,
            hasNextPage: false,
            webMetadata: WebSearchMetadata(
                totalResults: response.metadata.totalResults ?? references.count,
                searchTimeMs: response.metadata.searchTimeMs,
                rateLimit: nil
            ).withSessionUsedIfNeeded(used)
        )
    }

    private func unavailableProviderError(
        _ provider: ExternalSearchProviderID,
        snapshot: ExternalSearchRegistry.SettingsSnapshot
    ) -> ExternalSearchError {
        let settings = snapshot.providerSettings[provider]
            ?? ExternalSearchProviderSettings.defaultSettings(for: provider)
        guard settings.isEnabled else { return .disabled(provider: provider) }
        if provider == .anySearch, settings.anonymousMode { return .disabled(provider: provider) }
        guard snapshot.apiKeys[provider]?.isEmpty == false else {
            return .missingAPIKey(provider: provider)
        }
        return .unverifiedCredential(provider: provider)
    }
}

private extension WebSearchMetadata {
    /// External Search 多数 Provider 不返回可用的统一 quota header。
    /// 这里保留本地 sessionUsed 的计算入口，等后续某个 Provider 暴露稳定 quota 时可复用。
    func withSessionUsedIfNeeded(_ used: Int) -> WebSearchMetadata {
        guard let rateLimit else { return self }
        return WebSearchMetadata(
            totalResults: totalResults,
            searchTimeMs: searchTimeMs,
            rateLimit: WebRateLimit(limit: rateLimit.limit, sessionUsed: used, resetAt: rateLimit.resetAt)
        )
    }
}
