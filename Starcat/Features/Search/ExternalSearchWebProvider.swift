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

    private let diskCache: DiskExternalSearchCache?

    init(
        diskCache: DiskExternalSearchCache? = nil
    ) {
        if let diskCache {
            self.diskCache = diskCache
        } else if Thread.isMainThread {
            self.diskCache = MainActor.assumeIsolated { DiskExternalSearchCache.shared }
        } else {
            self.diskCache = nil
        }
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
        let filters = request.externalSearchFilters
        let externalRequest = ExternalSearchRequest(
            query: request.query,
            purpose: .globalSearch,
            maxResults: filters.clampedMaxResults(),
            freshness: filters.freshness == .any ? nil : filters.freshness.rawValue,
            includeDomains: filters.includeDomains.sorted(),
            excludeDomains: filters.excludeDomains.sorted(),
            anySearchFilters: providerID == .anySearch ? request.anySearchFilters : nil
        )
        if let cached = try? await diskCache?.loadGlobal(provider: providerID, request: externalRequest) {
            return makePage(from: cached, providerID: providerID, requestedMaxResults: externalRequest.maxResults)
        }
        let response = try await provider.search(externalRequest)
        if !response.hits.isEmpty {
            try? await diskCache?.saveGlobal(provider: providerID, request: externalRequest, response: response)
        }
        return makePage(from: response, providerID: providerID, requestedMaxResults: externalRequest.maxResults)
    }

    private func makePage(
        from response: ExternalSearchResponse,
        providerID: ExternalSearchProviderID,
        requestedMaxResults: Int
    ) -> SearchProviderPage {
        let references = response.hits.map { hit in
            ReferenceCandidate(
                normalizedURL: AnySearchClient.normalize(hit.url) ?? hit.url,
                originalURL: hit.url,
                title: hit.title,
                snippet: hit.snippet ?? hit.extractedText,
                domain: hit.url.host ?? providerID.displayName,
                source: .web,
                providerID: providerID
            )
        }
        let totalResults = max(response.metadata.totalResults ?? references.count, references.count)
        let canRequestMore = references.count < 100
            && (totalResults > references.count || references.count >= requestedMaxResults)
        return SearchProviderPage(
            repositories: [],
            references: references,
            totalCount: totalResults,
            hasNextPage: canRequestMore,
            webMetadata: WebSearchMetadata(
                totalResults: totalResults,
                searchTimeMs: response.metadata.searchTimeMs,
                rateLimit: nil
            )
        )
    }

    private func unavailableProviderError(
        _ provider: ExternalSearchProviderID,
        snapshot: ExternalSearchRegistry.SettingsSnapshot
    ) -> ExternalSearchError {
        let settings = snapshot.providerSettings[provider]
            ?? ExternalSearchProviderSettings.defaultSettings(for: provider)
        guard settings.isEnabled else { return .disabled(provider: provider) }
        if provider.supportsAnonymous, settings.anonymousMode { return .disabled(provider: provider) }
        guard snapshot.apiKeys[provider]?.isEmpty == false else {
            return .missingAPIKey(provider: provider)
        }
        return .unverifiedCredential(provider: provider)
    }
}
