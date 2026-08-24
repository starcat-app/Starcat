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
    func hasCompletedSourceSetup() async -> Bool
    func refreshCatalog() async throws -> [AwesomeSource]
    func refreshEnabledEntries() async -> [String: String]
    func completeSourceSetup(enabledSourceIDs: Set<String>) async throws
    func updateSubscriptions(enabledSourceIDs: Set<String>) async throws
    func saveCustomSource(_ source: AwesomeSource, entries: [AwesomeEntryDTO]) async throws
    func removeCustomSource(id: String) async throws
}

actor AwesomeRepository: AwesomeRepositoryProtocol {
    private let api: any AwesomeAPIProtocol
    private let database: any DatabaseManaging

    init(api: any AwesomeAPIProtocol, database: any DatabaseManaging) {
        self.api = api
        self.database = database
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

    func refreshCatalog() async throws -> [AwesomeSource] {
        let etag = try await database.writer.read { db in
            try AwesomeStateRecord
                .filter(Column("id") == AwesomeStateRecord.singletonID)
                .fetchOne(db)?.catalogETag
        }
        let result = try await api.fetchAwesomeSources(ifNoneMatch: etag)
        let checkedAt = ISO8601DateFormatter.shared.string(from: Date())
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
                        entriesETag: existing?.entriesETag
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
            }
            try state.save(db)
        }
        return await sources()
    }

    /// 逐来源刷新，单一来源失败不阻塞其它来源；返回 source_id -> error 供 UI 非阻断展示。
    func refreshEnabledEntries() async -> [String: String] {
        let managed = await enabledSources().filter { $0.kind == .managed && $0.isAvailable }
        var failures: [String: String] = [:]
        for source in managed {
            do {
                try Task.checkCancellation()
                try await refreshEntries(for: source.id)
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

    func saveCustomSource(_ source: AwesomeSource, entries: [AwesomeEntryDTO]) async throws {
        guard source.kind == .custom else { return }
        let cachedAt = ISO8601DateFormatter.shared.string(from: Date())
        try await database.writer.write { db in
            try AwesomeSourceRecord.fromCustom(source).save(db)
            try AwesomeSubscriptionRecord(
                sourceID: source.id,
                isEnabled: source.isEnabled,
                enabledAt: source.isEnabled ? cachedAt : nil
            ).save(db)
            try db.execute(sql: "DELETE FROM awesome_entries WHERE source_id = ?", arguments: [source.id])
            for entry in entries {
                try AwesomeEntryRecord.from(entry, sourceID: source.id, cachedAt: cachedAt).insert(db)
            }
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

    private func refreshEntries(for sourceID: String) async throws {
        let currentETag = try await database.writer.read { db in
            try AwesomeSourceRecord
                .filter(Column("source_id") == sourceID)
                .fetchOne(db)?.entriesETag
        }
        let result = try await api.fetchAwesomeEntries(sourceID: sourceID, ifNoneMatch: currentETag)
        guard !result.notModified, let snapshot = result.snapshot else { return }
        let cachedAt = ISO8601DateFormatter.shared.string(from: Date())
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM awesome_entries WHERE source_id = ?", arguments: [sourceID])
            for entry in snapshot.entries {
                try AwesomeEntryRecord.from(entry, sourceID: sourceID, cachedAt: cachedAt).insert(db)
            }
            try db.execute(
                sql: "UPDATE awesome_sources SET entries_etag = ?, github_repo_count = ?, last_synced_at = ? WHERE source_id = ?",
                arguments: [result.etag, snapshot.entries.count, result.generatedAt ?? cachedAt, sourceID]
            )
        }
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
                    language: first.language,
                    stars: first.stars,
                    isArchived: first.isArchived,
                    updatedAt: first.repoUpdatedAt.flatMap(ISO8601DateFormatter.githubDate(from:)),
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
        entriesETag: String?
    ) -> AwesomeSourceRecord {
        AwesomeSourceRecord(
            sourceID: dto.id,
            kind: AwesomeSourceKind.managed.rawValue,
            displayName: dto.displayName,
            repoFullName: dto.repoFullName,
            repoURL: dto.repoURL,
            imageURL: dto.imageURL,
            summaryZH: dto.summaryZH,
            summaryEN: dto.summaryEN,
            featured: dto.featured,
            sortOrder: dto.sortOrder,
            sourceStars: dto.sourceStars ?? 0,
            githubRepoCount: dto.githubRepoCount,
            externalEntryCount: dto.externalEntryCount,
            isAvailable: true,
            catalogETag: catalogETag,
            entriesETag: entriesETag,
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
            imageURL: source.imageURL?.absoluteString,
            summaryZH: source.summaryZH,
            summaryEN: source.summaryEN,
            featured: false,
            sortOrder: source.sortOrder,
            sourceStars: source.sourceStars,
            githubRepoCount: source.githubRepoCount,
            externalEntryCount: source.externalEntryCount,
            isAvailable: source.isAvailable,
            catalogETag: nil,
            entriesETag: nil,
            addedAt: ISO8601DateFormatter.shared.string(from: source.addedAt),
            lastSyncedAt: ISO8601DateFormatter.shared.string(from: source.updatedAt),
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
            imageURL: imageURL
                .flatMap(URL.init(string:))
                .flatMap { $0.scheme?.lowercased() == "https" ? $0 : nil },
            summaryZH: summaryZH,
            summaryEN: summaryEN,
            featured: featured,
            sortOrder: sortOrder,
            sourceStars: sourceStars,
            githubRepoCount: githubRepoCount,
            externalEntryCount: externalEntryCount,
            isAvailable: isAvailable,
            isEnabled: isEnabled,
            addedAt: addedAt,
            lastSyncedAt: lastSyncedAt.flatMap(ISO8601DateFormatter.githubDate(from:)),
            updatedAt: updatedAt
        )
    }
}

private extension AwesomeEntryRecord {
    static func from(_ dto: AwesomeEntryDTO, sourceID: String, cachedAt: String) -> AwesomeEntryRecord {
        let sectionData = (try? JSONEncoder().encode(dto.sectionPath)) ?? Data("[]".utf8)
        return AwesomeEntryRecord(
            sourceID: sourceID,
            ghRepoID: dto.ghRepoID,
            owner: dto.owner,
            name: dto.name,
            fullName: dto.fullName,
            description: dto.description,
            ownerAvatar: dto.ownerAvatar,
            language: dto.language,
            stars: dto.stars,
            // 旧版 Discovery 曾在 false 时省略字段；按 GitHub 默认语义降级，避免整批快照丢失。
            isArchived: dto.isArchived ?? false,
            repoUpdatedAt: dto.updatedAt,
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
}
