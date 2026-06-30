//
//  DiscoveryRepository.swift
//  Starcat
//
//  探索发现与榜单的客户端缓存仓库。
//
//  职责:
//  - 对 starcat-discovery-api 的列表和 summary 响应做 SQLite 持久化;
//  - 提供 cached-first + remote refresh 所需的读缓存 / 拉网络双路径;
//  - 网络失败时尽量回退到本地缓存,让探索页和 Sidebar 保持可用。
//

import Foundation
import GRDB

protocol DiscoveryRepositoryProtocol: Sendable {
    func cachedPage(mode: DiscoveryListMode, query: DiscoveryListQuery) async -> DiscoveryCachedPage?
    func fetchPage(mode: DiscoveryListMode, query: DiscoveryListQuery) async throws -> DiscoveryCachedPage
    func cachedBulk() async -> DiscoveryBulkCachedSnapshot?
    func fetchBulk() async throws -> DiscoveryBulkResult
    func cachedSummary() async -> DiscoverySummaryDTO?
    func fetchSummary() async throws -> DiscoverySummaryDTO
    func clearCache() async
}

/// starcat-discovery-api 的本地缓存仓库实现。
actor DiscoveryRepository: DiscoveryRepositoryProtocol {

    private let api: DiscoveryAPI
    private let database: any DatabaseManaging

    init(api: DiscoveryAPI, database: any DatabaseManaging) {
        self.api = api
        self.database = database
    }

    func cachedPage(mode: DiscoveryListMode, query: DiscoveryListQuery) async -> DiscoveryCachedPage? {
        let cacheKey = Self.cacheKey(mode: mode, query: query)
        do {
            return try await database.writer.read { db -> DiscoveryCachedPage? in
                guard let pageRecord = try DiscoveryListPageRecord
                    .filter(Column("cache_key") == cacheKey && Column("page") == query.page)
                    .fetchOne(db)
                else {
                    return nil
                }
                let itemRecords = try DiscoveryListItemRecord
                    .filter(Column("cache_key") == cacheKey && Column("page") == query.page)
                    .order(Column("sort_order").asc)
                    .fetchAll(db)
                guard let cachedAt = ISO8601DateFormatter.shared.date(from: pageRecord.cachedAt) else {
                    AppLog.network.warning("Discovery cached page has invalid cached_at: \(pageRecord.cachedAt, privacy: .public)")
                    return nil
                }
                let page = DiscoveryPage(
                    items: itemRecords.map { $0.toDomain() },
                    total: pageRecord.total,
                    page: pageRecord.page,
                    pageSize: pageRecord.pageSize,
                    nextPage: pageRecord.nextPage
                )
                return DiscoveryCachedPage(page: page, cachedAt: cachedAt)
            }
        } catch {
            AppLog.network.warning("Discovery cachedPage read failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func fetchPage(mode: DiscoveryListMode, query: DiscoveryListQuery) async throws -> DiscoveryCachedPage {
        do {
            let page = try await fetchRemotePage(mode: mode, query: query)
            let cachedAt = Date()
            try await save(page: page, mode: mode, query: query, cachedAt: cachedAt)
            return DiscoveryCachedPage(page: page, cachedAt: cachedAt)
        } catch {
            if let cached = await cachedPage(mode: mode, query: query) {
                AppLog.network.warning("Discovery network failed, falling back to cached page: \(error.localizedDescription, privacy: .public)")
                return cached
            }
            throw error
        }
    }

    func cachedBulk() async -> DiscoveryBulkCachedSnapshot? {
        do {
            return try await database.writer.read { db -> DiscoveryBulkCachedSnapshot? in
                guard let meta = try DiscoveryBulkMetaRecord
                    .filter(Column("id") == DiscoveryBulkMetaRecord.singletonID)
                    .fetchOne(db)
                else {
                    return nil
                }
                guard let lastFetchedAt = ISO8601DateFormatter.shared.date(from: meta.lastFetchedAt) else {
                    AppLog.network.warning(
                        "Discovery bulk cache has invalid last_fetched_at: \(meta.lastFetchedAt, privacy: .public)"
                    )
                    return nil
                }
                let records = try DiscoveryBulkRepoRecord
                    .order(Column("discovery_score").desc, Column("stars").desc, Column("repo_id").desc)
                    .fetchAll(db)
                guard !records.isEmpty else { return nil }

                let summary = try Self.readSummary(db: db) ?? DiscoverySummaryDTO(modes: [], generatedAt: meta.generatedAt)
                return DiscoveryBulkCachedSnapshot(
                    repos: records.map { $0.toDomain() },
                    summary: summary,
                    etag: meta.etag,
                    lastFetchedAt: lastFetchedAt,
                    generatedAt: meta.generatedAt,
                    total: meta.total
                )
            }
        } catch {
            AppLog.network.warning("Discovery cachedBulk read failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func fetchBulk() async throws -> DiscoveryBulkResult {
        do {
            let result = try await api.fetchBulk()
            try await save(bulk: result, cachedAt: Date())
            return result
        } catch {
            if let cached = await cachedBulk(), !cached.repos.isEmpty {
                AppLog.network.warning("Discovery bulk network failed, falling back to cache (\(cached.repos.count) repos): \(error.localizedDescription, privacy: .public)")
                return DiscoveryBulkResult(
                    repos: cached.repos,
                    summary: cached.summary,
                    etag: cached.etag,
                    generatedAt: cached.generatedAt,
                    total: cached.total
                )
            }
            throw error
        }
    }

    func cachedSummary() async -> DiscoverySummaryDTO? {
        do {
            return try await database.writer.read { db in
                try Self.readSummary(db: db)
            }
        } catch {
            AppLog.network.warning("Discovery cachedSummary read failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func fetchSummary() async throws -> DiscoverySummaryDTO {
        do {
            let summary = try await api.fetchSummary()
            try await save(summary: summary, cachedAt: Date())
            return summary
        } catch {
            if let cached = await cachedSummary() {
                AppLog.network.warning("Discovery summary network failed, falling back to cache: \(error.localizedDescription, privacy: .public)")
                return cached
            }
            throw error
        }
    }

    func clearCache() async {
        do {
            try await database.writer.write { db in
                try db.execute(sql: "DELETE FROM discovery_list_items")
                try db.execute(sql: "DELETE FROM discovery_list_pages")
                try db.execute(sql: "DELETE FROM discovery_bulk_repos")
                try db.execute(sql: "DELETE FROM discovery_bulk_meta")
                try db.execute(sql: "DELETE FROM discovery_summary_facets")
                try db.execute(sql: "DELETE FROM discovery_summary_modes")
            }
        } catch {
            AppLog.network.error("Discovery clearCache failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func fetchRemotePage(mode: DiscoveryListMode, query: DiscoveryListQuery) async throws -> DiscoveryPage {
        switch mode {
        case .discover:
            return try await api.fetchFeed(query: query)
        case .popular:
            return try await api.fetchMostPopular(query: query)
        case .newReleases:
            return try await api.fetchNewReleases(query: query)
        case .trending:
            return try await api.fetchTrendingCandidate(query: query)
        }
    }

    private func save(
        page: DiscoveryPage,
        mode: DiscoveryListMode,
        query: DiscoveryListQuery,
        cachedAt: Date
    ) async throws {
        let cacheKey = Self.cacheKey(mode: mode, query: query)
        let cachedAtString = ISO8601DateFormatter.shared.string(from: cachedAt)
        try await database.writer.write { db in
            try db.execute(
                sql: "DELETE FROM discovery_list_items WHERE cache_key = ? AND page = ?",
                arguments: [cacheKey, query.page]
            )
            try db.execute(
                sql: "DELETE FROM discovery_list_pages WHERE cache_key = ? AND page = ?",
                arguments: [cacheKey, query.page]
            )

            let pageRecord = DiscoveryListPageRecord(
                cacheKey: cacheKey,
                page: page.page,
                total: page.total,
                pageSize: page.pageSize,
                nextPage: page.nextPage,
                cachedAt: cachedAtString
            )
            try pageRecord.insert(db)

            for (index, item) in page.items.enumerated() {
                let record = DiscoveryListItemRecord.from(
                    item,
                    cacheKey: cacheKey,
                    page: page.page,
                    sortOrder: index,
                    cachedAt: cachedAt
                )
                try record.insert(db)
            }
        }
    }

    private func save(summary: DiscoverySummaryDTO, cachedAt: Date) async throws {
        let cachedAtString = ISO8601DateFormatter.shared.string(from: cachedAt)
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM discovery_summary_facets")
            try db.execute(sql: "DELETE FROM discovery_summary_modes")

            for mode in summary.modes {
                let modeRecord = DiscoverySummaryModeRecord(
                    mode: mode.mode,
                    total: mode.total,
                    generatedAt: summary.generatedAt,
                    cachedAt: cachedAtString
                )
                try modeRecord.insert(db)

                try Self.insertFacets(mode.topics ?? [], mode: mode.mode, facet: "topics", cachedAt: cachedAtString, db: db)
                try Self.insertFacets(mode.platforms ?? [], mode: mode.mode, facet: "platforms", cachedAt: cachedAtString, db: db)
                try Self.insertFacets(mode.languages ?? [], mode: mode.mode, facet: "languages", cachedAt: cachedAtString, db: db)
            }
        }
    }

    private func save(bulk: DiscoveryBulkResult, cachedAt: Date) async throws {
        let cachedAtString = ISO8601DateFormatter.shared.string(from: cachedAt)
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM discovery_bulk_repos")
            try db.execute(sql: "DELETE FROM discovery_bulk_meta")
            try db.execute(sql: "DELETE FROM discovery_summary_facets")
            try db.execute(sql: "DELETE FROM discovery_summary_modes")

            for repo in bulk.repos {
                let record = DiscoveryBulkRepoRecord.from(repo, cachedAt: cachedAt)
                try record.insert(db)
            }

            try Self.save(summary: bulk.summary, cachedAtString: cachedAtString, db: db)

            let meta = DiscoveryBulkMetaRecord(
                id: DiscoveryBulkMetaRecord.singletonID,
                etag: bulk.etag,
                lastFetchedAt: cachedAtString,
                generatedAt: bulk.generatedAt,
                total: bulk.total
            )
            try meta.save(db)
        }
    }

    private static func insertFacets(
        _ facets: [DiscoveryFacetCountDTO],
        mode: String,
        facet: String,
        cachedAt: String,
        db: Database
    ) throws {
        for (index, item) in facets.enumerated() {
            let record = DiscoverySummaryFacetRecord(
                mode: mode,
                facet: facet,
                key: item.key,
                label: item.label,
                systemName: item.systemName,
                count: item.count,
                sortOrder: index,
                cachedAt: cachedAt
            )
            try record.insert(db)
        }
    }

    private static func save(summary: DiscoverySummaryDTO, cachedAtString: String, db: Database) throws {
        for mode in summary.modes {
            let modeRecord = DiscoverySummaryModeRecord(
                mode: mode.mode,
                total: mode.total,
                generatedAt: summary.generatedAt,
                cachedAt: cachedAtString
            )
            try modeRecord.insert(db)

            try insertFacets(mode.topics ?? [], mode: mode.mode, facet: "topics", cachedAt: cachedAtString, db: db)
            try insertFacets(mode.platforms ?? [], mode: mode.mode, facet: "platforms", cachedAt: cachedAtString, db: db)
            try insertFacets(mode.languages ?? [], mode: mode.mode, facet: "languages", cachedAt: cachedAtString, db: db)
        }
    }

    private static func readSummary(db: Database) throws -> DiscoverySummaryDTO? {
        let modeRecords = try DiscoverySummaryModeRecord.fetchAll(db)
        guard !modeRecords.isEmpty else { return nil }

        let facetRecords = try DiscoverySummaryFacetRecord
            .order(Column("mode").asc, Column("facet").asc, Column("sort_order").asc)
            .fetchAll(db)
        let facetsByMode = Dictionary(grouping: facetRecords, by: \.mode)
        let modeOrder = ["discover", "popular", "new_releases", "trending"]
        let sortedModes = modeRecords.sorted { lhs, rhs in
            let lhsIndex = modeOrder.firstIndex(of: lhs.mode) ?? Int.max
            let rhsIndex = modeOrder.firstIndex(of: rhs.mode) ?? Int.max
            if lhsIndex == rhsIndex {
                return lhs.mode < rhs.mode
            }
            return lhsIndex < rhsIndex
        }

        let modes = sortedModes.map { modeRecord in
            let facets = facetsByMode[modeRecord.mode] ?? []
            return DiscoveryModeSummaryDTO(
                mode: modeRecord.mode,
                total: modeRecord.total,
                topics: facets.filter { $0.facet == "topics" }.map(\.toFacetDTO),
                platforms: facets.filter { $0.facet == "platforms" }.map(\.toFacetDTO),
                languages: facets.filter { $0.facet == "languages" }.map(\.toFacetDTO)
            )
        }
        return DiscoverySummaryDTO(
            modes: modes,
            generatedAt: sortedModes.first?.generatedAt
        )
    }

    private static func cacheKey(mode: DiscoveryListMode, query: DiscoveryListQuery) -> String {
        [
            "mode=\(mode.rawValue)",
            "language=\(normalized(query.language))",
            "platform=\(normalized(query.platform))",
            "topic=\(normalized(query.topic))",
            "sort=\(normalized(query.sort))",
            "limit=\(query.limit)"
        ].joined(separator: "|")
    }

    private static func normalized(_ value: String?) -> String {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return "__all__"
        }
        return value
    }
}
