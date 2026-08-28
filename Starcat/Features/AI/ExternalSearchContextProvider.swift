//
//  ExternalSearchContextProvider.swift
//  Starcat
//
//  AI External Context 的 External Search 编排器。
//
//  关键约束：
//  - SearchCenter filters 不影响 AI External Context；
//  - 私有仓库即使允许外部上下文，也只发送 repo fullName；
//  - 单 Provider 对所有用户开放，聚合搜索只在 Pro 运行时启用；
//  - 外部搜索失败不能阻断 AI 摘要主流程，聚合模式允许部分成功。
//

import Foundation

@MainActor
final class ExternalSearchContextProvider {
    typealias ProviderFactory = @Sendable (ExternalSearchProviderID) -> any ExternalSearchProvider

    private let settings: AppSettings
    private let diskCache: DiskExternalSearchCache?
    private let providerFactory: ProviderFactory?

    init(
        settings: AppSettings,
        diskCache: DiskExternalSearchCache? = DiskExternalSearchCache.shared,
        providerFactory: ProviderFactory? = nil
    ) {
        self.settings = settings
        self.diskCache = diskCache
        self.providerFactory = providerFactory
    }

    func collect(for repo: Repo, enabledOverride: Bool? = nil) async throws -> AIExternalContext? {
        guard Self.allowsExternalContext(
            repoIsPrivate: repo.isPrivate,
            enabled: enabledOverride ?? settings.externalContextEnabled,
            allowPrivate: settings.externalSearchAllowPrivateRepos
        ) else {
            return nil
        }

        let queries = Self.queries(for: repo).prefix(2).map(\.self)
        let fingerprint = Self.queryFingerprint(queries)
        let registry = makeRegistry()

        if settings.aggregateExternalContextSearchEnabled, settings.isProUser {
            return try await collectAggregate(repo: repo, queries: queries, fingerprint: fingerprint, registry: registry)
        }

        guard let providerID = selectedSingleProvider(registry: registry) else { return nil }
        let hits = try await collectHits(
            providerID: providerID,
            requests: queries.map {
                ExternalSearchRequest(query: $0, purpose: .aiContext, maxResults: 5)
            },
            fingerprint: fingerprint,
            registry: registry,
            cacheScopeID: repo.id
        )
        return makeAIContext(providerID: providerID, hits: Array(Self.deduplicated(hits).prefix(6)), aggregate: false)
    }

    /// 执行由 Agent 模型产生的结构化搜索请求。
    ///
    /// 此入口只负责 Provider 编排和缓存；私有仓库是否允许进入查询由调用方在拥有完整
    /// `AgentRunContext` 时判定，避免底层 Provider 猜测业务上下文。
    func collect(request: ExternalSearchRequest, cacheScopeID: Int64 = 0) async throws -> AIExternalContext? {
        guard settings.externalContextEnabled else { return nil }

        let fingerprint = Self.queryFingerprint(for: request)
        let registry = makeRegistry()
        if settings.aggregateExternalContextSearchEnabled, settings.isProUser {
            return try await collectAggregate(
                request: request,
                fingerprint: fingerprint,
                registry: registry,
                cacheScopeID: cacheScopeID
            )
        }

        guard let providerID = selectedSingleProvider(registry: registry) else { return nil }
        let hits = try await collectHits(
            providerID: providerID,
            requests: [request],
            fingerprint: fingerprint,
            registry: registry,
            cacheScopeID: cacheScopeID
        )
        return makeAIContext(
            providerID: providerID,
            hits: Array(Self.deduplicated(hits).prefix(request.maxResults)),
            aggregate: false
        )
    }

    nonisolated static func queries(for repo: Repo) -> [String] {
        if repo.isPrivate {
            return [
                "\(repo.fullName) documentation release notes",
                "\(repo.fullName) alternatives review"
            ]
        }
        let description = repo.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return [
            "\(repo.fullName) documentation release notes",
            "\(repo.fullName) alternatives review \(String(description.prefix(120)))"
        ]
    }

    nonisolated static func allowsExternalContext(
        repoIsPrivate: Bool,
        enabled: Bool,
        allowPrivate: Bool
    ) -> Bool {
        enabled && (!repoIsPrivate || allowPrivate)
    }

    nonisolated static func queryFingerprint(_ queries: [String]) -> String {
        queries.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "|")
    }

    nonisolated static func queryFingerprint(for request: ExternalSearchRequest) -> String {
        [
            request.query.lowercased(),
            "max=\(request.maxResults)",
            "freshness=\(request.freshness ?? "")",
            "include=\(request.includeDomains.map { $0.lowercased() }.sorted().joined(separator: ","))",
            "exclude=\(request.excludeDomains.map { $0.lowercased() }.sorted().joined(separator: ","))"
        ].joined(separator: "|")
    }

    private func collectAggregate(
        repo: Repo,
        queries: [String],
        fingerprint: String,
        registry: ExternalSearchRegistry
    ) async throws -> AIExternalContext? {
        let providerIDs = ExternalSearchProviderID.automaticContextPriority.filter { id in
            registry.usableProviderIDs().contains(id)
        }
        guard !providerIDs.isEmpty else { return nil }

        let outcomes = await withTaskGroup(of: ProviderHitsOutcome.self) { group in
            for providerID in providerIDs {
                group.addTask {
                    do {
                        let hits = try await self.collectHits(
                            providerID: providerID,
                            requests: queries.map {
                                ExternalSearchRequest(query: $0, purpose: .aiContext, maxResults: 3)
                            },
                            fingerprint: fingerprint,
                            registry: registry,
                            cacheScopeID: repo.id
                        )
                        return ProviderHitsOutcome(providerID: providerID, result: .success(hits))
                    } catch {
                        return ProviderHitsOutcome(providerID: providerID, result: .failure(error))
                    }
                }
            }

            var collected: [ProviderHitsOutcome] = []
            for await outcome in group {
                collected.append(outcome)
            }
            return collected
        }

        let hits = outcomes.flatMap { outcome -> [ExternalSearchContextHit] in
            (try? outcome.result.get()) ?? []
        }
        let sorted = Self.deduplicated(hits).sorted { lhs, rhs in
            providerPriority(lhs.providerID) < providerPriority(rhs.providerID)
        }
        return makeAIContext(providerID: nil, hits: Array(sorted.prefix(8)), aggregate: true)
    }

    private func collectAggregate(
        request: ExternalSearchRequest,
        fingerprint: String,
        registry: ExternalSearchRegistry,
        cacheScopeID: Int64
    ) async throws -> AIExternalContext? {
        let usable = registry.usableProviderIDs()
        let providerIDs = ExternalSearchProviderID.automaticContextPriority.filter(usable.contains)
        guard !providerIDs.isEmpty else { return nil }

        let outcomes = await withTaskGroup(of: ProviderHitsOutcome.self) { group in
            for providerID in providerIDs {
                group.addTask {
                    do {
                        let hits = try await self.collectHits(
                            providerID: providerID,
                            requests: [request],
                            fingerprint: fingerprint,
                            registry: registry,
                            cacheScopeID: cacheScopeID
                        )
                        return ProviderHitsOutcome(providerID: providerID, result: .success(hits))
                    } catch {
                        return ProviderHitsOutcome(providerID: providerID, result: .failure(error))
                    }
                }
            }

            var collected: [ProviderHitsOutcome] = []
            for await outcome in group {
                collected.append(outcome)
            }
            return collected
        }

        let hits = outcomes.flatMap { (try? $0.result.get()) ?? [] }
        let sorted = Self.deduplicated(hits).sorted {
            providerPriority($0.providerID) < providerPriority($1.providerID)
        }
        return makeAIContext(providerID: nil, hits: Array(sorted.prefix(request.maxResults)), aggregate: true)
    }

    private func collectHits(
        providerID: ExternalSearchProviderID,
        requests: [ExternalSearchRequest],
        fingerprint: String,
        registry: ExternalSearchRegistry,
        cacheScopeID: Int64
    ) async throws -> [ExternalSearchContextHit] {
        if let cached = try? await diskCache?.loadAIContext(
            provider: providerID,
            repoID: cacheScopeID,
            queryFingerprint: fingerprint
        ) {
            return cached.hits.map { ExternalSearchContextHit(providerID: providerID, hit: $0) }
        }

        let provider = providerFactory?(providerID) ?? registry.provider(for: providerID)
        var hits: [ExternalSearchHit] = []
        for request in requests {
            let response = try await provider.search(request)
            hits.append(contentsOf: response.hits)
        }
        let response = ExternalSearchResponse(
            hits: hits,
            metadata: ExternalSearchMetadata(provider: providerID, totalResults: hits.count)
        )
        if !hits.isEmpty {
            try? await diskCache?.saveAIContext(
                provider: providerID,
                repoID: cacheScopeID,
                queryFingerprint: fingerprint,
                response: response
            )
        }
        return hits.map { ExternalSearchContextHit(providerID: providerID, hit: $0) }
    }

    private func selectedSingleProvider(registry: ExternalSearchRegistry) -> ExternalSearchProviderID? {
        let usable = registry.usableProviderIDs()
        if let explicit = settings.externalContextProviderSelection.explicitProviderID {
            guard usable.contains(explicit) else { return explicit }
            return explicit
        }
        return ExternalSearchProviderID.automaticContextPriority.first { usable.contains($0) }
    }

    private func makeRegistry() -> ExternalSearchRegistry {
        ExternalSearchRegistry(settings: settings)
    }

    private func makeAIContext(
        providerID: ExternalSearchProviderID?,
        hits: [ExternalSearchContextHit],
        aggregate: Bool
    ) -> AIExternalContext? {
        guard !hits.isEmpty else { return nil }
        let fetchedAt = ISO8601DateFormatter.shared.string(from: Date())
        let source = aggregate ? "Aggregate" : (providerID?.displayName ?? "External Search")
        let entries = hits.map { contextHit -> String in
            let hit = contextHit.hit
            let body = String((hit.extractedText ?? hit.snippet ?? "").prefix(700))
            let prefix = aggregate ? "[\(contextHit.providerID.displayName)] " : ""
            return "- \(prefix)[\(hit.title)](\(hit.url.absoluteString))\n  \(body)"
        }
        let markdown = """

        <external_context source="\(source)">
        \(entries.joined(separator: "\n"))
        </external_context>
        """
        let sourceItems = hits.map { contextHit in
            AIExternalContextSource(
                title: contextHit.hit.title,
                url: contextHit.hit.url,
                host: contextHit.hit.url.host ?? contextHit.providerID.displayName,
                provider: contextHit.providerID,
                fetchedAt: fetchedAt
            )
        }
        return AIExternalContext(markdown: markdown, sources: hits.map(\.hit.url), sourceItems: sourceItems)
    }

    private func providerPriority(_ providerID: ExternalSearchProviderID) -> Int {
        ExternalSearchProviderID.automaticContextPriority.firstIndex(of: providerID) ?? Int.max
    }

    private static func deduplicated(_ hits: [ExternalSearchContextHit]) -> [ExternalSearchContextHit] {
        var bestByURL: [String: ExternalSearchContextHit] = [:]
        for hit in hits {
            let key = normalizedURL(hit.hit.url).absoluteString
            guard let current = bestByURL[key] else {
                bestByURL[key] = hit
                continue
            }
            if current.hit.extractedText?.isEmpty != false, hit.hit.extractedText?.isEmpty == false {
                bestByURL[key] = hit
            }
        }
        return Array(bestByURL.values)
    }

    private static func normalizedURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.fragment = nil
        components.host = components.host?.lowercased()
        return components.url ?? url
    }
}

private struct ExternalSearchContextHit: Sendable, Equatable {
    let providerID: ExternalSearchProviderID
    let hit: ExternalSearchHit
}

private struct ProviderHitsOutcome: Sendable {
    let providerID: ExternalSearchProviderID
    let result: Result<[ExternalSearchContextHit], Error>
}
