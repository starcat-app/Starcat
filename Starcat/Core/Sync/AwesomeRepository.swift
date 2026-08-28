//
//  AwesomeRepository.swift
//  Starcat
//
//  Awesome 来源目录、账户订阅、自定义来源和条目快照的本地优先仓储。
//
//  关键约束：精选目录刷新只能替换 managed 行，不能删除 custom 行；条目按
//  (source_id, gh_repo_id) 保存，读取“全部 Awesome”时才按 GitHub 稳定 ID 聚合，
//  这样同一 Repo 的每份 README 来源证据都能保留下来。
//

import Foundation
import GRDB

protocol AwesomeAPIProtocol: Sendable {
    func fetchAwesomeSources(ifNoneMatch: String?) async throws -> AwesomeCatalogResult
    func fetchAwesomeEntries(sourceID: String, ifNoneMatch: String?) async throws -> AwesomeEntriesResult
}

extension DiscoveryAPI: AwesomeAPIProtocol {}

protocol AwesomeRepositoryProtocol: Sendable {
    func sources() async -> [AwesomeSource]
    func enabledSources() async -> [AwesomeSource]
    func repositories(sourceID: String?) async -> [AwesomeRepositoryItem]
    func repositoryPage(sourceID: String?, limit: Int, offset: Int) async -> AwesomeRepositoryPage
    func repositorySections(sourceID: String?) async -> [String]
    func resources(sourceID: String?) async -> [AwesomeResourceItem]
    func hasCompletedSourceSetup() async -> Bool
    func refreshCatalog(policy: AwesomeRefreshPolicy) async throws -> [AwesomeSource]
    func refreshEnabledEntries(policy: AwesomeRefreshPolicy) async -> [String: String]
    func completeSourceSetup(enabledSourceIDs: Set<String>) async throws
    func updateSubscriptions(enabledSourceIDs: Set<String>) async throws
    func saveCustomSource(_ source: AwesomeSource, entries: [AwesomeEntryDTO]) async throws
    func saveCustomSource(
        _ source: AwesomeSource,
        entries: [AwesomeEntryDTO],
        parseState: AwesomeCustomSourceParseState
    ) async throws
    func customSourceParseStates() async -> [AwesomeCustomSourceParseState]
    func updateCustomSourceParseState(_ state: AwesomeCustomSourceParseState) async throws
    func customSourceEntryFullNames(sourceID: String) async -> Set<String>
    func customSourceEntryCount(sourceID: String) async -> Int
    func saveCustomSourceEntries(
        _ entries: [AwesomeEntryDTO],
        sourceID: String,
        parseState: AwesomeCustomSourceParseState
    ) async throws
    func completeCustomSourceParsing(
        sourceID: String,
        externalEntryCount: Int,
        parseState: AwesomeCustomSourceParseState
    ) async throws
    func removeCustomSource(id: String) async throws
}

/// 自动刷新遵守本地 TTL；只有用户明确点击刷新时才绕过新鲜度判断。
enum AwesomeRefreshPolicy: Sendable, Equatable {
    case ifStale
    case force
}

extension AwesomeRepositoryProtocol {
    /// 测试替身和轻量实现可继续只提供全量读取；生产仓储会覆写为真正的 SQL 分页。
    func repositoryPage(sourceID: String?, limit: Int, offset: Int) async -> AwesomeRepositoryPage {
        let all = await repositories(sourceID: sourceID)
        let safeOffset = max(0, offset)
        let safeLimit = max(0, limit)
        let page = Array(all.dropFirst(safeOffset).prefix(safeLimit))
        return AwesomeRepositoryPage(
            repositories: page,
            totalCount: all.count,
            hasMore: safeOffset + page.count < all.count
        )
    }

    func repositorySections(sourceID: String?) async -> [String] {
        guard sourceID != nil else { return [] }
        var seen: Set<String> = []
        return await repositories(sourceID: sourceID).compactMap { repository in
            let section = repository.evidence.first?.sectionPath.joined(separator: " / ") ?? ""
            guard !section.isEmpty, seen.insert(section).inserted else { return nil }
            return section
        }
    }

    func resources(sourceID _: String? = nil) async -> [AwesomeResourceItem] { [] }

    func refreshCatalog() async throws -> [AwesomeSource] {
        try await refreshCatalog(policy: .ifStale)
    }

    func refreshEnabledEntries() async -> [String: String] {
        await refreshEnabledEntries(policy: .ifStale)
    }

    func saveCustomSource(_ source: AwesomeSource, entries: [AwesomeEntryDTO]) async throws {
        try await saveCustomSource(
            source,
            entries: entries,
            parseState: AwesomeCustomSourceParseState(
                sourceID: source.id,
                phase: .completed,
                processedCount: entries.count,
                totalCount: entries.count,
                errorMessage: nil,
                updatedAt: source.updatedAt
            )
        )
    }
}

actor AwesomeRepository: AwesomeRepositoryProtocol {
    /// Awesome 内容并非实时信息；六小时窗口可避免每次进入都请求，同时保留手动刷新能力。
    private static let freshnessInterval: TimeInterval = 6 * 60 * 60

    private let api: any AwesomeAPIProtocol
    private let database: any DatabaseManaging
    private let now: @Sendable () -> Date

    init(
        api: any AwesomeAPIProtocol,
        database: any DatabaseManaging,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.api = api
        self.database = database
        self.now = now
    }

    func sources() async -> [AwesomeSource] {
        do {
            return try await database.writer.read { db in
                try Self.readSources(db: db, enabledOnly: false)
            }
        } catch {
            if error is CancellationError || Task.isCancelled { return [] }
            AppLog.database.warning("Awesome sources read failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func enabledSources() async -> [AwesomeSource] {
        do {
            return try await database.writer.read { db in
                try Self.readSources(db: db, enabledOnly: true)
            }
        } catch {
            if error is CancellationError || Task.isCancelled { return [] }
            AppLog.database.warning("Awesome enabled sources read failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func repositories(sourceID: String? = nil) async -> [AwesomeRepositoryItem] {
        do {
            return try await database.writer.read { db in
                let sources = try Self.readSources(db: db, enabledOnly: true)
                let visibleSources = sourceID.map { id in sources.filter { $0.id == id } } ?? sources
                guard !visibleSources.isEmpty else { return [] }
                let sourceMap = Dictionary(uniqueKeysWithValues: visibleSources.map { ($0.id, $0) })
                let sourceIDs = visibleSources.map(\.id)
                let records = try AwesomeEntryRecord
                    .filter(sourceIDs.contains(Column("source_id")))
                    .order(Column("entry_order").asc, Column("gh_repo_id").asc)
                    .fetchAll(db)
                return Self.aggregate(records: records, sourceMap: sourceMap)
            }
        } catch {
            if error is CancellationError || Task.isCancelled { return [] }
            AppLog.database.warning("Awesome repositories read failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func repositoryPage(sourceID: String?, limit: Int, offset: Int) async -> AwesomeRepositoryPage {
        let safeLimit = max(1, limit)
        let safeOffset = max(0, offset)
        do {
            return try await database.writer.read { db in
                let sources = try Self.readSources(db: db, enabledOnly: true)
                let visibleSources = sourceID.map { id in sources.filter { $0.id == id } } ?? sources
                guard !visibleSources.isEmpty else {
                    return AwesomeRepositoryPage(repositories: [], totalCount: 0, hasMore: false)
                }

                let sourceIDs = visibleSources.map(\.id)
                let sourcePlaceholders = Array(repeating: "?", count: sourceIDs.count).joined(separator: ", ")
                let totalCount = try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(DISTINCT gh_repo_id)
                        FROM awesome_entries
                        WHERE source_id IN (\(sourcePlaceholders))
                        """,
                    arguments: StatementArguments(sourceIDs)
                ) ?? 0

                // “全部 Awesome”需要先按 Repo ID 去重再分页。sourceRank 复用 readSources 的
                // 稳定顺序，避免先 LIMIT 原始条目造成跨来源重复仓库挤占页容量或跨页重现。
                var pageArguments: [any DatabaseValueConvertible] = []
                let sourceRankSQL = visibleSources.enumerated().map { rank, source in
                    pageArguments.append(source.id)
                    pageArguments.append(rank)
                    return "WHEN ? THEN ?"
                }.joined(separator: " ")
                pageArguments.append(contentsOf: sourceIDs)
                pageArguments.append(safeLimit)
                pageArguments.append(safeOffset)
                let pageIDs = try Int64.fetchAll(
                    db,
                    sql: """
                        WITH visible AS (
                            SELECT gh_repo_id, source_id, entry_order,
                                   CASE source_id \(sourceRankSQL) ELSE 2147483647 END AS source_rank
                            FROM awesome_entries
                            WHERE source_id IN (\(sourcePlaceholders))
                        ), ranked AS (
                            SELECT gh_repo_id, source_id, entry_order, source_rank,
                                   ROW_NUMBER() OVER (
                                       PARTITION BY gh_repo_id
                                       ORDER BY source_rank, entry_order, source_id, gh_repo_id
                                   ) AS occurrence
                            FROM visible
                        )
                        SELECT gh_repo_id
                        FROM ranked
                        WHERE occurrence = 1
                        ORDER BY source_rank, entry_order, source_id, gh_repo_id
                        LIMIT ? OFFSET ?
                        """,
                    arguments: StatementArguments(pageArguments)
                )
                guard !pageIDs.isEmpty else {
                    return AwesomeRepositoryPage(repositories: [], totalCount: totalCount, hasMore: false)
                }

                var recordArguments: [any DatabaseValueConvertible] = sourceIDs
                recordArguments.append(contentsOf: pageIDs)
                let repoPlaceholders = Array(repeating: "?", count: pageIDs.count).joined(separator: ", ")
                let records = try AwesomeEntryRecord.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM awesome_entries
                        WHERE source_id IN (\(sourcePlaceholders))
                          AND gh_repo_id IN (\(repoPlaceholders))
                        """,
                    arguments: StatementArguments(recordArguments)
                )
                let sourceMap = Dictionary(uniqueKeysWithValues: visibleSources.map { ($0.id, $0) })
                let aggregatedByID = Dictionary(
                    uniqueKeysWithValues: Self.aggregate(records: records, sourceMap: sourceMap).map { ($0.id, $0) }
                )
                let repositories = pageIDs.compactMap { aggregatedByID[$0] }
                return AwesomeRepositoryPage(
                    repositories: repositories,
                    totalCount: totalCount,
                    hasMore: safeOffset + repositories.count < totalCount
                )
            }
        } catch {
            if error is CancellationError || Task.isCancelled {
                return AwesomeRepositoryPage(repositories: [], totalCount: 0, hasMore: false)
            }
            AppLog.database.warning("Awesome repository page read failed: \(error.localizedDescription, privacy: .public)")
            return AwesomeRepositoryPage(repositories: [], totalCount: 0, hasMore: false)
        }
    }

    func repositorySections(sourceID: String?) async -> [String] {
        guard let sourceID else { return [] }
        do {
            return try await database.writer.read { db in
                let enabledSourceIDs = try Self.readSources(db: db, enabledOnly: true).map(\.id)
                guard enabledSourceIDs.contains(sourceID) else { return [] }
                let encodedPaths = try String.fetchAll(
                    db,
                    sql: """
                        SELECT section_path_json
                        FROM awesome_entries
                        WHERE source_id = ?
                        GROUP BY section_path_json
                        ORDER BY MIN(entry_order), section_path_json
                        """,
                    arguments: [sourceID]
                )
                var seen: Set<String> = []
                return encodedPaths.compactMap { encodedPath in
                    let path = encodedPath.data(using: .utf8)
                        .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
                    let title = path.joined(separator: " / ")
                    guard !title.isEmpty, seen.insert(title).inserted else { return nil }
                    return title
                }
            }
        } catch {
            if error is CancellationError || Task.isCancelled { return [] }
            AppLog.database.warning("Awesome repository sections read failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func resources(sourceID: String? = nil) async -> [AwesomeResourceItem] {
        do {
            return try await database.writer.read { db in
                let sources = try Self.readSources(db: db, enabledOnly: true)
                let visibleSources = sourceID.map { id in sources.filter { $0.id == id } } ?? sources
                guard !visibleSources.isEmpty else { return [] }
                let sourceMap = Dictionary(uniqueKeysWithValues: visibleSources.map { ($0.id, $0) })
                let records = try AwesomeResourceEntryRecord
                    .filter(visibleSources.map(\.id).contains(Column("source_id")))
                    .order(Column("entry_order").asc, Column("target_key").asc)
                    .fetchAll(db)
                return records.compactMap { record in
                    guard let source = sourceMap[record.sourceID] else { return nil }
                    return record.toDomain(source: source)
                }
            }
        } catch {
            if error is CancellationError || Task.isCancelled { return [] }
            AppLog.database.warning("Awesome resources read failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func hasCompletedSourceSetup() async -> Bool {
        do {
            return try await database.writer.read { db in
                try AwesomeStateRecord
                    .filter(Column("id") == AwesomeStateRecord.singletonID)
                    .fetchOne(db)?.hasCompletedSourceSetup ?? false
            }
        } catch {
            AppLog.database.warning("Awesome setup state read failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func refreshCatalog(policy: AwesomeRefreshPolicy) async throws -> [AwesomeSource] {
        let cache = try await database.writer.read { db in
            let state = try AwesomeStateRecord
                .filter(Column("id") == AwesomeStateRecord.singletonID)
                .fetchOne(db)
            let managedCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM awesome_sources WHERE kind = ?",
                arguments: [AwesomeSourceKind.managed.rawValue]
            ) ?? 0
            return (state?.catalogETag, state?.catalogCheckedAt, managedCount)
        }
        if policy == .ifStale,
           cache.2 > 0,
           isFresh(cache.1) {
            return await sources()
        }

        let result = try await api.fetchAwesomeSources(ifNoneMatch: cache.0)
        let checkedAt = ISO8601DateFormatter.shared.string(from: now())
        try await database.writer.write { db in
            var state = try AwesomeStateRecord
                .filter(Column("id") == AwesomeStateRecord.singletonID)
                .fetchOne(db)
                ?? AwesomeStateRecord(
                    id: AwesomeStateRecord.singletonID,
                    hasCompletedSourceSetup: false,
                    catalogETag: nil,
                    catalogCheckedAt: nil
                )
            state.catalogCheckedAt = checkedAt
            state.catalogETag = result.etag ?? state.catalogETag

            if !result.notModified {
                // 下架来源不静默删除：保留为不可用行，用户仍可在管理 Sheet 看见并取消订阅。
                try db.execute(
                    sql: "UPDATE awesome_sources SET is_available = 0 WHERE kind = ?",
                    arguments: [AwesomeSourceKind.managed.rawValue]
                )
                for dto in result.sources {
                    let existing = try AwesomeSourceRecord
                        .filter(Column("source_id") == dto.id)
                        .fetchOne(db)
                    let record = AwesomeSourceRecord.fromManaged(
                        dto,
                        catalogETag: result.etag,
                        addedAt: existing?.addedAt ?? checkedAt,
                        entriesETag: existing?.entriesETag,
                        entriesCheckedAt: existing?.entriesCheckedAt
                    )
                    try record.save(db)
                    if try AwesomeSubscriptionRecord
                        .filter(Column("source_id") == dto.id)
                        .fetchOne(db) == nil {
                        try AwesomeSubscriptionRecord(
                            sourceID: dto.id,
                            isEnabled: false,
                            enabledAt: nil
                        ).insert(db)
                    }
                }

                // 远端下架的内置来源仍保留行与订阅状态，方便用户在管理 Sheet 识别并取消；
                // 但条目属于可重建缓存，必须立即清空。否则该来源因 is_available=false 不再
                // 进入刷新队列，旧版外链或仓库文件会永久残留在中栏。
                let unavailableManagedSourceSQL = """
                    SELECT source_id FROM awesome_sources
                    WHERE kind = ? AND is_available = 0
                    """
                try db.execute(
                    sql: "DELETE FROM awesome_entries WHERE source_id IN (\(unavailableManagedSourceSQL))",
                    arguments: [AwesomeSourceKind.managed.rawValue]
                )
                try db.execute(
                    sql: "DELETE FROM awesome_resource_entries WHERE source_id IN (\(unavailableManagedSourceSQL))",
                    arguments: [AwesomeSourceKind.managed.rawValue]
                )
                try db.execute(
                    sql: """
                        UPDATE awesome_sources
                        SET github_repo_count = 0, external_entry_count = 0, resource_entry_count = 0
                        WHERE kind = ? AND is_available = 0
                        """,
                    arguments: [AwesomeSourceKind.managed.rawValue]
                )
            }
            try state.save(db)
        }
        return await sources()
    }

    /// 逐来源刷新，单一来源失败不阻塞其它来源；返回 source_id -> error 供 UI 非阻断展示。
    func refreshEnabledEntries(policy: AwesomeRefreshPolicy) async -> [String: String] {
        let managed = await enabledSources().filter { $0.kind == .managed && $0.isAvailable }
        var failures: [String: String] = [:]
        for source in managed {
            do {
                try Task.checkCancellation()
                try await refreshEntries(for: source.id, policy: policy)
            } catch is CancellationError {
                return failures
            } catch {
                failures[source.id] = error.localizedDescription
                AppLog.network.warning(
                    "Awesome entries refresh failed for \(source.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return failures
    }

    func completeSourceSetup(enabledSourceIDs: Set<String>) async throws {
        try await updateSubscriptions(enabledSourceIDs: enabledSourceIDs)
        try await database.writer.write { db in
            var state = try AwesomeStateRecord
                .filter(Column("id") == AwesomeStateRecord.singletonID)
                .fetchOne(db)
                ?? AwesomeStateRecord(
                    id: AwesomeStateRecord.singletonID,
                    hasCompletedSourceSetup: false,
                    catalogETag: nil,
                    catalogCheckedAt: nil
                )
            // 只有显式“完成”路径调用本方法；关闭 Sheet 永远不会误写这个状态。
            state.hasCompletedSourceSetup = true
            try state.save(db)
        }
    }

    func updateSubscriptions(enabledSourceIDs: Set<String>) async throws {
        let now = ISO8601DateFormatter.shared.string(from: Date())
        try await database.writer.write { db in
            let sourceIDs = try String.fetchAll(db, sql: "SELECT source_id FROM awesome_sources")
            for sourceID in sourceIDs {
                let enabled = enabledSourceIDs.contains(sourceID)
                let previous = try AwesomeSubscriptionRecord
                    .filter(Column("source_id") == sourceID)
                    .fetchOne(db)
                try AwesomeSubscriptionRecord(
                    sourceID: sourceID,
                    isEnabled: enabled,
                    enabledAt: enabled ? (previous?.enabledAt ?? now) : nil
                ).save(db)
            }
        }
    }

    func saveCustomSource(
        _ source: AwesomeSource,
        entries: [AwesomeEntryDTO],
        parseState: AwesomeCustomSourceParseState
    ) async throws {
        guard source.kind == .custom else { return }
        let cachedAt = ISO8601DateFormatter.shared.string(from: now())
        try await database.writer.write { db in
            try AwesomeSourceRecord.fromCustom(source).save(db)
            try AwesomeSubscriptionRecord(
                sourceID: source.id,
                isEnabled: source.isEnabled,
                enabledAt: source.isEnabled ? cachedAt : nil
            ).save(db)
            try db.execute(sql: "DELETE FROM awesome_entries WHERE source_id = ?", arguments: [source.id])
            for entry in entries {
                if let record = AwesomeEntryRecord.from(entry, sourceID: source.id, cachedAt: cachedAt) {
                    try record.insert(db)
                }
            }
            try AwesomeCustomSourceParseRecord.from(parseState).save(db)
        }
    }

    func customSourceParseStates() async -> [AwesomeCustomSourceParseState] {
        do {
            return try await database.writer.read { db in
                try AwesomeCustomSourceParseRecord.fetchAll(db).compactMap(\.domain)
            }
        } catch {
            if error is CancellationError || Task.isCancelled { return [] }
            AppLog.database.warning(
                "Awesome custom parse states read failed: \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    func updateCustomSourceParseState(_ state: AwesomeCustomSourceParseState) async throws {
        try await database.writer.write { db in
            try AwesomeCustomSourceParseRecord.from(state).save(db)
        }
    }

    func customSourceEntryFullNames(sourceID: String) async -> Set<String> {
        do {
            return try await database.writer.read { db in
                Set(try String.fetchAll(
                    db,
                    sql: "SELECT full_name FROM awesome_entries WHERE source_id = ?",
                    arguments: [sourceID]
                ).map { $0.lowercased() })
            }
        } catch {
            if error is CancellationError || Task.isCancelled { return [] }
            AppLog.database.warning(
                "Awesome custom entry names read failed: \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    func customSourceEntryCount(sourceID: String) async -> Int {
        do {
            return try await database.writer.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM awesome_entries WHERE source_id = ?",
                    arguments: [sourceID]
                ) ?? 0
            }
        } catch {
            if error is CancellationError || Task.isCancelled { return 0 }
            AppLog.database.warning(
                "Awesome custom entry count read failed: \(error.localizedDescription, privacy: .public)"
            )
            return 0
        }
    }

    /// 单批条目和进度必须原子提交。应用重启后只会从最后一批已提交位置恢复，不能出现
    /// UI 已显示进度、对应条目却尚未落库的假进度。
    func saveCustomSourceEntries(
        _ entries: [AwesomeEntryDTO],
        sourceID: String,
        parseState: AwesomeCustomSourceParseState
    ) async throws {
        let cachedAt = ISO8601DateFormatter.shared.string(from: now())
        try await database.writer.write { db in
            for entry in entries {
                if let record = AwesomeEntryRecord.from(entry, sourceID: sourceID, cachedAt: cachedAt) {
                    try record.save(db)
                }
            }
            let entryCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM awesome_entries WHERE source_id = ?",
                arguments: [sourceID]
            ) ?? 0
            try db.execute(
                sql: "UPDATE awesome_sources SET github_repo_count = ?, updated_at = ? WHERE source_id = ? AND kind = ?",
                arguments: [entryCount, cachedAt, sourceID, AwesomeSourceKind.custom.rawValue]
            )
            try AwesomeCustomSourceParseRecord.from(parseState).save(db)
        }
    }

    func completeCustomSourceParsing(
        sourceID: String,
        externalEntryCount: Int,
        parseState: AwesomeCustomSourceParseState
    ) async throws {
        let completedAt = ISO8601DateFormatter.shared.string(from: now())
        try await database.writer.write { db in
            let entryCount = try Int.fetchOne(
                db,
                sql: "SELECT (SELECT COUNT(*) FROM awesome_entries WHERE source_id = ?) + (SELECT COUNT(*) FROM awesome_resource_entries WHERE source_id = ?)",
                arguments: [sourceID, sourceID]
            ) ?? 0
            try db.execute(
                sql: """
                UPDATE awesome_sources
                SET github_repo_count = ?, external_entry_count = ?,
                    last_synced_at = ?, updated_at = ?
                WHERE source_id = ? AND kind = ?
                """,
                arguments: [
                    entryCount, externalEntryCount, completedAt, completedAt,
                    sourceID, AwesomeSourceKind.custom.rawValue,
                ]
            )
            try AwesomeCustomSourceParseRecord.from(parseState).save(db)
        }
    }

    func removeCustomSource(id: String) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "DELETE FROM awesome_sources WHERE source_id = ? AND kind = ?",
                arguments: [id, AwesomeSourceKind.custom.rawValue]
            )
        }
    }

    private func refreshEntries(for sourceID: String, policy: AwesomeRefreshPolicy) async throws {
        let cache = try await database.writer.read { db in
            let source = try AwesomeSourceRecord
                .filter(Column("source_id") == sourceID)
                .fetchOne(db)
            let entryCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM awesome_entries WHERE source_id = ?",
                arguments: [sourceID]
            ) ?? 0
            return (source?.entriesETag, source?.entriesCheckedAt, entryCount)
        }
        if policy == .ifStale,
           cache.2 > 0,
           isFresh(cache.1) {
            return
        }

        let result = try await api.fetchAwesomeEntries(sourceID: sourceID, ifNoneMatch: cache.0)
        let checkedAt = ISO8601DateFormatter.shared.string(from: now())
        if result.notModified {
            // 304 代表服务端确认快照仍有效；必须推进校验时间，否则下次进入仍会再次请求。
            try await database.writer.write { db in
                try db.execute(
                    sql: "UPDATE awesome_sources SET entries_etag = COALESCE(?, entries_etag), entries_checked_at = ? WHERE source_id = ?",
                    arguments: [result.etag, checkedAt, sourceID]
                )
            }
            return
        }
        guard let snapshot = result.snapshot else { return }
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM awesome_entries WHERE source_id = ?", arguments: [sourceID])
            try db.execute(sql: "DELETE FROM awesome_resource_entries WHERE source_id = ?", arguments: [sourceID])
            for entry in snapshot.entries {
                // Discovery 的公开契约只允许独立 GitHub 仓库。客户端再次收紧入口，
                // 即使服务端缓存或旧版本误返回资源条目，也不会写入本地数据库。
                if (entry.targetType == nil || entry.targetType == .githubRepository),
                   let record = AwesomeEntryRecord.from(entry, sourceID: sourceID, cachedAt: checkedAt) {
                    try record.insert(db)
                }
            }
            let githubCount = snapshot.entries.count { $0.targetType == nil || $0.targetType == .githubRepository }
            try db.execute(
                sql: "UPDATE awesome_sources SET entries_etag = ?, entries_checked_at = ?, github_repo_count = ?, external_entry_count = ?, resource_entry_count = ?, last_synced_at = ? WHERE source_id = ?",
                arguments: [
                    result.etag, checkedAt, githubCount, 0, 0,
                    result.generatedAt ?? checkedAt, sourceID,
                ]
            )
        }
    }

    private func isFresh(_ checkedAt: String?) -> Bool {
        guard let checkedAt,
              let date = ISO8601DateFormatter.githubDate(from: checkedAt) else { return false }
        let age = now().timeIntervalSince(date)
        return age >= 0 && age < Self.freshnessInterval
    }

    private static func readSources(db: Database, enabledOnly: Bool) throws -> [AwesomeSource] {
        let records = try AwesomeSourceRecord.fetchAll(db)
        let subscriptions = try AwesomeSubscriptionRecord.fetchAll(db)
        let enabledByID = Dictionary(uniqueKeysWithValues: subscriptions.map { ($0.sourceID, $0.isEnabled) })
        return records.compactMap { record in
            record.toDomain(isEnabled: enabledByID[record.sourceID] ?? false)
        }
        .filter { !enabledOnly || $0.isEnabled }
        .sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind == .managed }
            if lhs.kind == .managed {
                if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
                // 服务端公开目录使用 ID 作同序稳定键，客户端必须保持同一契约，
                // 避免运营仅修改展示名称就造成用户左栏顺序跳变。
                return lhs.id < rhs.id
            }
            if lhs.kind == .custom, lhs.addedAt != rhs.addedAt { return lhs.addedAt < rhs.addedAt }
            let nameOrder = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.id < rhs.id
        }
    }

    private static func aggregate(
        records: [AwesomeEntryRecord],
        sourceMap: [String: AwesomeSource]
    ) -> [AwesomeRepositoryItem] {
        Dictionary(grouping: records, by: \.ghRepoID)
            .compactMap { repoID, grouped -> AwesomeRepositoryItem? in
                guard let first = grouped.first else { return nil }
                let evidence = grouped.compactMap { record -> AwesomeEntryEvidence? in
                    guard let source = sourceMap[record.sourceID] else { return nil }
                    return record.toEvidence(source: source)
                }
                .sorted {
                    if $0.source.sortOrder != $1.source.sortOrder {
                        return $0.source.sortOrder < $1.source.sortOrder
                    }
                    if $0.entryOrder != $1.entryOrder { return $0.entryOrder < $1.entryOrder }
                    // 不能依赖 SQLite 在完全同序时的隐式返回顺序。
                    return $0.source.id < $1.source.id
                }
                guard !evidence.isEmpty else { return nil }
                return AwesomeRepositoryItem(
                    id: repoID,
                    owner: first.owner,
                    name: first.name,
                    fullName: first.fullName,
                    description: first.description,
                    ownerAvatarURL: first.ownerAvatar.flatMap(URL.init(string:)),
                    homepage: first.homepage,
                    language: first.language,
                    stars: first.stars,
                    forks: first.forks,
                    watchers: first.watchers,
                    subscribers: first.subscribers,
                    openIssues: first.openIssues,
                    defaultBranch: first.defaultBranch,
                    licenseSpdx: first.licenseSpdx,
                    topics: first.topics,
                    isArchived: first.isArchived,
                    isFork: first.isFork,
                    pushedAt: first.pushedAt.flatMap(ISO8601DateFormatter.githubDate(from:)),
                    updatedAt: first.repoUpdatedAt.flatMap(ISO8601DateFormatter.githubDate(from:)),
                    createdAt: first.createdAt.flatMap(ISO8601DateFormatter.githubDate(from:)),
                    evidence: evidence
                )
            }
            .sorted { lhs, rhs in
                let left = lhs.evidence.first
                let right = rhs.evidence.first
                if left?.source.sortOrder != right?.source.sortOrder {
                    return (left?.source.sortOrder ?? .max) < (right?.source.sortOrder ?? .max)
                }
                if left?.entryOrder != right?.entryOrder {
                    return (left?.entryOrder ?? .max) < (right?.entryOrder ?? .max)
                }
                return lhs.id < rhs.id
            }
    }
}

private extension AwesomeSourceRecord {
    static func fromManaged(
        _ dto: AwesomeSourceDTO,
        catalogETag: String?,
        addedAt: String,
        entriesETag: String?,
        entriesCheckedAt: String?
    ) -> AwesomeSourceRecord {
        AwesomeSourceRecord(
            sourceID: dto.id,
            kind: AwesomeSourceKind.managed.rawValue,
            displayName: dto.displayName,
            repoFullName: dto.repoFullName,
            repoURL: dto.repoURL,
            repoDescription: dto.repoDescription,
            imageURL: dto.imageURL,
            summaryZH: dto.summaryZH,
            summaryEN: dto.summaryEN,
            featured: dto.featured,
            sortOrder: dto.sortOrder,
            sourceStars: dto.sourceStars,
            sourceForks: dto.sourceForks,
            sourceWatchers: dto.sourceWatchers,
            sourceSubscribers: dto.sourceSubscribers,
            sourceOpenIssues: dto.sourceOpenIssues,
            sourceLanguage: dto.sourceLanguage,
            languageBytesJSON: Self.encodeLanguageBytes(dto.languageBytes ?? [:]),
            githubRepoCount: dto.githubRepoCount,
            externalEntryCount: dto.externalEntryCount,
            resourceEntryCount: dto.resourceEntryCount ?? 0,
            isAvailable: true,
            catalogETag: catalogETag,
            entriesETag: entriesETag,
            entriesCheckedAt: entriesCheckedAt,
            addedAt: addedAt,
            lastSyncedAt: dto.lastSyncedAt,
            updatedAt: dto.updatedAt
        )
    }

    static func fromCustom(_ source: AwesomeSource) -> AwesomeSourceRecord {
        AwesomeSourceRecord(
            sourceID: source.id,
            kind: source.kind.rawValue,
            displayName: source.displayName,
            repoFullName: source.repoFullName,
            repoURL: source.repoURL.absoluteString,
            repoDescription: source.repoDescription,
            imageURL: source.imageURL?.absoluteString,
            summaryZH: source.summaryZH,
            summaryEN: source.summaryEN,
            featured: false,
            sortOrder: source.sortOrder,
            sourceStars: source.sourceStars,
            sourceForks: source.sourceForks,
            sourceWatchers: source.sourceWatchers,
            sourceSubscribers: source.sourceSubscribers,
            sourceOpenIssues: source.sourceOpenIssues,
            sourceLanguage: source.sourceLanguage,
            languageBytesJSON: Self.encodeLanguageBytes(source.languageBytes),
            githubRepoCount: source.githubRepoCount,
            externalEntryCount: source.externalEntryCount,
            resourceEntryCount: source.resourceEntryCount,
            isAvailable: source.isAvailable,
            catalogETag: nil,
            entriesETag: nil,
            entriesCheckedAt: nil,
            addedAt: ISO8601DateFormatter.shared.string(from: source.addedAt),
            // 刚创建的空卡片尚未完成 README 解析，不能把创建时间伪装成同步完成时间。
            lastSyncedAt: source.lastSyncedAt.map { ISO8601DateFormatter.shared.string(from: $0) },
            updatedAt: ISO8601DateFormatter.shared.string(from: source.updatedAt)
        )
    }

    func toDomain(isEnabled: Bool) -> AwesomeSource? {
        guard let kind = AwesomeSourceKind(rawValue: kind),
              let repoURL = URL(string: repoURL),
              let addedAt = ISO8601DateFormatter.githubDate(from: addedAt),
              let updatedAt = ISO8601DateFormatter.githubDate(from: updatedAt)
        else { return nil }
        return AwesomeSource(
            id: sourceID,
            kind: kind,
            displayName: displayName,
            repoFullName: repoFullName,
            repoURL: repoURL,
            repoDescription: repoDescription,
            imageURL: imageURL
                .flatMap(URL.init(string:))
                .flatMap { $0.scheme?.lowercased() == "https" ? $0 : nil },
            summaryZH: summaryZH,
            summaryEN: summaryEN,
            featured: featured,
            sortOrder: sortOrder,
            sourceStars: sourceStars,
            sourceForks: sourceForks,
            sourceWatchers: sourceWatchers,
            sourceSubscribers: sourceSubscribers,
            sourceOpenIssues: sourceOpenIssues,
            sourceLanguage: sourceLanguage,
            languageBytes: Self.decodeLanguageBytes(languageBytesJSON),
            githubRepoCount: githubRepoCount,
            externalEntryCount: externalEntryCount,
            resourceEntryCount: resourceEntryCount,
            isAvailable: isAvailable,
            isEnabled: isEnabled,
            addedAt: addedAt,
            lastSyncedAt: lastSyncedAt.flatMap(ISO8601DateFormatter.githubDate(from:)),
            updatedAt: updatedAt
        )
    }

    /// 语言分布是可重建目录缓存，编码失败时使用空对象，不能阻断用户的来源订阅写入。
    private static func encodeLanguageBytes(_ values: [String: Int]) -> String {
        guard let data = try? JSONEncoder().encode(values) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func decodeLanguageBytes(_ value: String) -> [String: Int] {
        (try? JSONDecoder().decode([String: Int].self, from: Data(value.utf8))) ?? [:]
    }
}

private extension AwesomeEntryRecord {
    static func from(_ dto: AwesomeEntryDTO, sourceID: String, cachedAt: String) -> AwesomeEntryRecord? {
        guard let ghRepoID = dto.ghRepoID else { return nil }
        let sectionData = (try? JSONEncoder().encode(dto.sectionPath)) ?? Data("[]".utf8)
        let topicsData = (try? JSONEncoder().encode(dto.topics)) ?? Data("[]".utf8)
        return AwesomeEntryRecord(
            sourceID: sourceID,
            ghRepoID: ghRepoID,
            owner: dto.owner,
            name: dto.name,
            fullName: dto.fullName,
            description: dto.description,
            ownerAvatar: dto.ownerAvatar,
            homepage: dto.homepage,
            language: dto.language,
            stars: dto.stars,
            forks: dto.forks,
            watchers: dto.watchers,
            subscribers: dto.subscribers,
            openIssues: dto.openIssues,
            defaultBranch: dto.defaultBranch,
            licenseSpdx: dto.licenseSpdx,
            topicsJSON: String(decoding: topicsData, as: UTF8.self),
            isArchived: dto.isArchived,
            isFork: dto.isFork,
            pushedAt: dto.pushedAt,
            repoUpdatedAt: dto.updatedAt,
            createdAt: dto.createdAt,
            entryTitle: dto.entryTitle,
            entryDescription: dto.entryDescription,
            sectionPathJSON: String(decoding: sectionData, as: UTF8.self),
            entryOrder: dto.entryOrder,
            sourceAnchorURL: dto.sourceAnchorURL,
            cachedAt: cachedAt
        )
    }

    func toEvidence(source: AwesomeSource) -> AwesomeEntryEvidence {
        let path = sectionPathJSON.data(using: .utf8)
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        let anchor = sourceAnchorURL.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        return AwesomeEntryEvidence(
            source: source,
            entryTitle: entryTitle,
            entryDescription: entryDescription,
            sectionPath: path,
            entryOrder: entryOrder,
            sourceAnchorURL: anchor
        )
    }

    var topics: [String] {
        topicsJSON.data(using: .utf8)
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
    }
}

private extension AwesomeResourceEntryRecord {
    static func from(_ dto: AwesomeEntryDTO, sourceID: String, cachedAt: String) -> AwesomeResourceEntryRecord? {
        guard let targetType = dto.targetType,
              targetType != .githubRepository,
              let rawURL = dto.rawURL,
              let url = URL(string: rawURL),
              url.scheme?.lowercased() == "https"
        else { return nil }
        let sectionData = (try? JSONEncoder().encode(dto.sectionPath)) ?? Data("[]".utf8)
        return AwesomeResourceEntryRecord(
            sourceID: sourceID,
            targetKey: "\(targetType.rawValue):\(url.absoluteString)",
            targetType: targetType.rawValue,
            rawURL: url.absoluteString,
            entryTitle: dto.entryTitle,
            entryDescription: dto.entryDescription,
            sectionPathJSON: String(decoding: sectionData, as: UTF8.self),
            entryOrder: dto.entryOrder,
            sourceAnchorURL: dto.sourceAnchorURL,
            cachedAt: cachedAt
        )
    }

    func toDomain(source: AwesomeSource) -> AwesomeResourceItem? {
        guard let targetType = AwesomeEntryTargetType(rawValue: targetType),
              targetType != .githubRepository,
              let url = URL(string: rawURL),
              url.scheme?.lowercased() == "https"
        else { return nil }
        let path = sectionPathJSON.data(using: .utf8)
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        let anchor = sourceAnchorURL.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        return AwesomeResourceItem(
            id: "\(sourceID):\(targetKey)",
            targetType: targetType,
            title: entryTitle,
            description: entryDescription,
            url: url,
            evidence: AwesomeEntryEvidence(
                source: source,
                entryTitle: entryTitle,
                entryDescription: entryDescription,
                sectionPath: path,
                entryOrder: entryOrder,
                sourceAnchorURL: anchor
            )
        )
    }
}

private extension AwesomeCustomSourceParseRecord {
    static func from(_ state: AwesomeCustomSourceParseState) -> AwesomeCustomSourceParseRecord {
        AwesomeCustomSourceParseRecord(
            sourceID: state.sourceID,
            phase: state.phase.rawValue,
            processedCount: state.processedCount,
            totalCount: state.totalCount,
            errorMessage: state.errorMessage,
            updatedAt: ISO8601DateFormatter.shared.string(from: state.updatedAt)
        )
    }

    var domain: AwesomeCustomSourceParseState? {
        guard let phase = AwesomeCustomSourceParsePhase(rawValue: phase),
              let updatedAt = ISO8601DateFormatter.githubDate(from: updatedAt)
        else { return nil }
        return AwesomeCustomSourceParseState(
            sourceID: sourceID,
            phase: phase,
            processedCount: processedCount,
            totalCount: totalCount,
            errorMessage: errorMessage,
            updatedAt: updatedAt
        )
    }
}
