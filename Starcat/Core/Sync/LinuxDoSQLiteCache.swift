//
//  LinuxDoSQLiteCache.swift
//  Starcat
//
//  Linux.do 公共缓存独立于账号库。查询列供 SQLite 筛选和排序，完整 DTO 只在取页时解码。
//

import Foundation
import GRDB

struct LinuxDoCacheMetadata: Equatable, Sendable {
    let revision: Int64
    let etag: String?
    let checkedAt: Date
}

struct LinuxDoCatalogSummary: Sendable {
    var metadata: LinuxDoCacheMetadata
    let total: Int
    let languages: [DiscoveryLanguageDTO]
    let licenses: [String]
}

/// 读页时核对 SQLite 中的版本，避免将一个版本的 OFFSET 用到新目录上。
struct LinuxDoCatalogKey: Hashable, Sendable {
    let providerID: String
    let revision: Int64
}

/// 基础条件可直接下推 SQLite，账号和磁盘信号只在使用对应筛选时传入 ID 集合。
struct LinuxDoCatalogQuery: Hashable, Sendable {
    var language: String? = nil
    var interestedLanguages: [String] = []
    var globalLanguages: [String] = []
    var license: RepoLicenseFilter = .all
    var hideArchived = false
    var hideForks = false
    var search = ""
    var recentPromotionFirst = true

    static func languageLabel(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func languageKey(_ value: String?) -> String { languageLabel(value).lowercased() }
}

struct LinuxDoRepoMembership: Sendable {
    let ids: Set<Int64>
    let includes: Bool
}

struct LinuxDoCatalogPage: Sendable {
    let rows: [DiscoveryRepoDTO]
    let total: Int
}

/// 所有读写由 LinuxDoRepository 在后台执行。只在新版本的事务中投影查询列和核验时间。
struct LinuxDoSQLiteCache {
    private let reader: DatabaseQueue

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var config = Configuration()
        config.prepareDatabase { db in
            // 保持原快捷搜索的 Unicode 匹配规则，只在实际搜索时执行。
            db.add(function: DatabaseFunction("linuxdo_search", argumentCount: 3, pure: true) { values in
                let term = String.fromDatabaseValue(values[2]) ?? ""
                return (String.fromDatabaseValue(values[0])?.localizedCaseInsensitiveContains(term) ?? false)
                    || (String.fromDatabaseValue(values[1])?.localizedCaseInsensitiveContains(term) ?? false)
            })
        }
        reader = try DatabaseQueue(path: directory.appendingPathComponent("cache.sqlite").path, configuration: config)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-linuxdo-cache") { db in
            try db.execute(sql: """
                CREATE TABLE snapshots (
                    provider TEXT NOT NULL, resource TEXT NOT NULL, revision INTEGER NOT NULL,
                    etag TEXT, checked_at REAL NOT NULL, discussion_url TEXT,
                    PRIMARY KEY (provider, resource)
                );
                CREATE TABLE catalog (
                    provider TEXT NOT NULL, repo_id INTEGER NOT NULL, owner TEXT NOT NULL, name TEXT NOT NULL,
                    full_name TEXT NOT NULL, description TEXT, language TEXT NOT NULL, language_key TEXT NOT NULL,
                    license_key TEXT NOT NULL, stars INTEGER NOT NULL, archived INTEGER NOT NULL, fork INTEGER NOT NULL,
                    promoted_at REAL NOT NULL, body BLOB NOT NULL,
                    PRIMARY KEY (provider, repo_id)
                );
                CREATE INDEX catalog_promoted ON catalog (provider, promoted_at DESC, stars DESC, repo_id DESC);
                CREATE INDEX catalog_stars ON catalog (provider, stars DESC, repo_id DESC);
                CREATE TABLE origins (
                    provider TEXT NOT NULL, repo_id INTEGER NOT NULL, topic_count INTEGER NOT NULL, verified_at REAL NOT NULL,
                    PRIMARY KEY (provider, repo_id)
                )
                """)
        }
        try migrator.migrate(reader)
    }

    func metadata(_ resource: LinuxDoResource, providerID: String) throws -> LinuxDoCacheMetadata? {
        try reader.read { db in try Self.metadata(db, resource, providerID: providerID) }
    }

    func catalogSummary(providerID: String) throws -> LinuxDoCatalogSummary? {
        try reader.read { db in
            guard let metadata = try Self.metadata(db, .catalog, providerID: providerID) else { return nil }
            let groups = try Row.fetchAll(db, sql: """
                SELECT language_key, MIN(language) AS label, COUNT(*) AS count
                FROM catalog WHERE provider = ? GROUP BY language_key
                """, arguments: [providerID])
            var languages = groups.map { row -> DiscoveryLanguageDTO in
                let key: String = row["language_key"]
                let label: String = row["label"]
                return DiscoveryLanguageDTO(
                    key: key.isEmpty ? TrendingLanguage.uncategorizedKey : label,
                    label: key.isEmpty ? TrendingLanguage.uncategorized.localizedDisplayName : label,
                    count: row["count"]
                )
            }
            if !languages.contains(where: { $0.key == TrendingLanguage.uncategorizedKey }) {
                languages.append(DiscoveryLanguageDTO(
                    key: TrendingLanguage.uncategorizedKey,
                    label: TrendingLanguage.uncategorized.localizedDisplayName,
                    count: 0
                ))
            }
            let licenses = try String.fetchAll(db, sql: "SELECT DISTINCT license_key FROM catalog WHERE provider = ?", arguments: [providerID])
            return LinuxDoCatalogSummary(
                metadata: metadata, total: languages.reduce(0) { $0 + $1.count },
                languages: languages.sorted { $0.key < $1.key },
                licenses: RepoLicenseFilter.options(licenses)
            )
        }
    }

    func page(
        key: LinuxDoCatalogKey, query: LinuxDoCatalogQuery, memberships: [LinuxDoRepoMembership],
        limit: Int, offset: Int, knownTotal: Int?
    ) throws -> LinuxDoCatalogPage? {
        let filter = try Self.filter(providerID: key.providerID, query: query, memberships: memberships)
        return try reader.read { db in
            guard try Self.metadata(db, .catalog, providerID: key.providerID)?.revision == key.revision else { return nil }
            let total = try knownTotal ?? (Int.fetchOne(db, sql: "SELECT COUNT(*) FROM catalog WHERE \(filter.sql)", arguments: filter.args) ?? 0)
            let order = query.recentPromotionFirst ? "promoted_at DESC, stars DESC, repo_id DESC" : "stars DESC, repo_id DESC"
            let bodies = try Data.fetchAll(db, sql: """
                SELECT body FROM catalog WHERE \(filter.sql) ORDER BY \(order) LIMIT ? OFFSET ?
                """, arguments: filter.args + [limit, offset])
            let decoder = JSONDecoder()
            return LinuxDoCatalogPage(rows: try bodies.map { try decoder.decode(DiscoveryRepoDTO.self, from: $0) }, total: total)
        }
    }

    /// Wiki 仍是磁盘缓存，只投影候选仓库的路径。常规查询无需遍历目录。
    func signalCandidates(key: LinuxDoCatalogKey, query: LinuxDoCatalogQuery) throws -> [WikiAvailabilityRequest] {
        let filter = try Self.filter(providerID: key.providerID, query: query, memberships: [])
        return try reader.read { db in
            guard try Self.metadata(db, .catalog, providerID: key.providerID)?.revision == key.revision else { return [] }
            return try Row.fetchAll(db, sql: "SELECT repo_id, owner, name FROM catalog WHERE \(filter.sql)", arguments: filter.args)
                .map { WikiAvailabilityRequest(id: $0["repo_id"], owner: $0["owner"], repo: $0["name"]) }
        }
    }

    /// 仅跨分类使用来源证明。数据库按当前服务和当前批次筛选，切页无须解码整个名单。
    func verifiedIDs(_ ids: [Int64], providerID: String, now: Date) throws -> Set<Int64> {
        guard !ids.isEmpty else { return [] }
        let idList = try Self.json(ids)
        return try reader.read { db in
            guard let metadata = try Self.metadata(db, .provenance, providerID: providerID),
                  now.timeIntervalSince(metadata.checkedAt) <= 7 * 86400 else { return [] }
            return Set(try Int64.fetchAll(db, sql: """
                SELECT repo_id FROM origins WHERE provider = ? AND repo_id IN (SELECT value FROM json_each(?))
                    AND verified_at >= ?
                """, arguments: [providerID, idList, now.timeIntervalSince1970 - 30 * 86400]))
        }
    }

    func contains(repoID: Int64, providerID: String) throws -> Bool {
        try reader.read { db in
            try Int.fetchOne(db, sql: "SELECT 1 FROM catalog WHERE provider = ? AND repo_id = ?", arguments: [providerID, repoID]) != nil
        }
    }

    func discussionURL(repoID: Int64, providerID: String, minimumRevision: Int64) throws -> URL? {
        try reader.read { db in
            let url = try String.fetchOne(db, sql: """
                SELECT discussion_url FROM snapshots WHERE provider = ? AND resource = ? AND revision >= ?
                """, arguments: [providerID, LinuxDoResource.topics(repoID).path, minimumRevision])
            return url.flatMap(URL.init(string:))
        }
    }

    /// nil 正文只更新校验时间和 ETag。目录、关系与元数据同事务写入，失败时继续使用上一版。
    func save(
        _ payload: LinuxDoPayload?, metadata: LinuxDoCacheMetadata, resource: LinuxDoResource, providerID: String
    ) throws {
        try reader.write { db in
            if let payload {
                var discussionURL: String?
                switch resource {
                case .catalog:
                    try Self.saveCatalog(db, payload: payload, providerID: providerID)
                case .provenance:
                    try Self.saveOrigins(db, origins: payload.origins ?? [], providerID: providerID)
                case .topics:
                    discussionURL = Self.latestDiscussionURL(payload.topics ?? [])
                }
                try db.execute(sql: """
                    INSERT INTO snapshots (provider, resource, revision, etag, checked_at, discussion_url) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(provider, resource) DO UPDATE SET revision = excluded.revision,
                        etag = excluded.etag, checked_at = excluded.checked_at, discussion_url = excluded.discussion_url
                    """, arguments: [providerID, resource.path, metadata.revision, metadata.etag, metadata.checkedAt.timeIntervalSince1970, discussionURL])
                if case .topics = resource {
                    try db.execute(sql: """
                        DELETE FROM snapshots WHERE rowid IN (
                            SELECT rowid FROM snapshots WHERE resource LIKE '%/topics'
                            ORDER BY checked_at DESC, rowid DESC LIMIT -1 OFFSET 64
                        )
                        """)
                }
            } else {
                try db.execute(sql: "UPDATE snapshots SET etag = ?, checked_at = ? WHERE provider = ? AND resource = ?",
                               arguments: [metadata.etag, metadata.checkedAt.timeIntervalSince1970, providerID, resource.path])
            }
        }
    }

    private static func metadata(_ db: Database, _ resource: LinuxDoResource, providerID: String) throws -> LinuxDoCacheMetadata? {
        try Row.fetchOne(db, sql: "SELECT revision, etag, checked_at FROM snapshots WHERE provider = ? AND resource = ?",
                         arguments: [providerID, resource.path]).map { row in
            LinuxDoCacheMetadata(revision: row["revision"], etag: row["etag"], checkedAt: Date(timeIntervalSince1970: row["checked_at"]))
        }
    }

    /// RFC3339 字符串可能使用不同的时区或精度，先转时间再按帖子 ID 稳定决胜。
    private static func latestDiscussionURL(_ topics: [LinuxDoTopic]) -> String? {
        let timestamp = LinuxDoTimestampParser()
        let datedTopics = topics.map { topic in
            (topic: topic, date: timestamp.parse(topic.publishedAt) ?? Date.distantPast)
        }
        let latest = datedTopics.max { lhs, rhs in
            lhs.date == rhs.date ? lhs.topic.id < rhs.topic.id : lhs.date < rhs.date
        }
        return latest?.topic.safeURL?.absoluteString
    }

    private static func saveCatalog(_ db: Database, payload: LinuxDoPayload, providerID: String) throws {
        let repositories = payload.repositories ?? []
        let promotions = payload.promotionDates ?? [:]
        let timestamp = LinuxDoTimestampParser()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let upsert = try db.makeStatement(sql: """
            INSERT INTO catalog VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(provider, repo_id) DO UPDATE SET
                owner = excluded.owner, name = excluded.name, full_name = excluded.full_name, description = excluded.description,
                language = excluded.language, language_key = excluded.language_key, license_key = excluded.license_key,
                stars = excluded.stars, archived = excluded.archived, fork = excluded.fork,
                promoted_at = excluded.promoted_at, body = excluded.body
            WHERE body IS NOT excluded.body OR promoted_at IS NOT excluded.promoted_at
            """)
        for repo in repositories {
            guard let date = timestamp.parse(promotions[String(repo.repoID)]) else {
                throw LinuxDoCacheError.invalidSnapshot
            }
            try upsert.execute(arguments: [providerID, repo.repoID, repo.owner, repo.name, repo.fullName, repo.description,
                LinuxDoCatalogQuery.languageLabel(repo.language), LinuxDoCatalogQuery.languageKey(repo.language),
                RepoLicenseFilter.key(repo.licenseSpdx), repo.stars, repo.isArchived, repo.isFork, date.timeIntervalSince1970,
                try encoder.encode(repo)])
        }
        // 只有 complete 快照才允许移除缺席项。绑定一个 JSON ID 数组避免碰到 SQL 参数上限。
        try db.execute(sql: "DELETE FROM catalog WHERE provider = ? AND repo_id NOT IN (SELECT value FROM json_each(?))",
                       arguments: [providerID, try json(repositories.map(\.repoID))])
    }

    private static func saveOrigins(_ db: Database, origins: [LinuxDoOrigin], providerID: String) throws {
        let timestamp = LinuxDoTimestampParser()
        let upsert = try db.makeStatement(sql: """
            INSERT INTO origins VALUES (?, ?, ?, ?)
            ON CONFLICT(provider, repo_id) DO UPDATE SET topic_count = excluded.topic_count, verified_at = excluded.verified_at
            WHERE topic_count IS NOT excluded.topic_count OR verified_at IS NOT excluded.verified_at
            """)
        for origin in origins {
            guard let date = timestamp.parse(origin.verifiedAt) else { throw LinuxDoCacheError.invalidSnapshot }
            try upsert.execute(arguments: [providerID, origin.repoID, origin.topicCount, date.timeIntervalSince1970])
        }
        try db.execute(sql: "DELETE FROM origins WHERE provider = ? AND repo_id NOT IN (SELECT value FROM json_each(?))",
                       arguments: [providerID, try json(origins.map(\.repoID))])
    }

    private static func filter(
        providerID: String, query: LinuxDoCatalogQuery, memberships: [LinuxDoRepoMembership]
    ) throws -> (sql: String, args: StatementArguments) {
        var clauses = ["provider = ?"]
        var args: StatementArguments = [providerID]
        switch LinuxDoCatalogQuery.languageKey(query.language) {
        case "": break
        case TrendingLanguage.uncategorizedKey: clauses.append("language_key = ''")
        case TrendingLanguage.otherRawValue:
            clauses.append("language_key != '' AND language_key NOT IN (SELECT value FROM json_each(?))")
            args += [try json(query.interestedLanguages.map(LinuxDoCatalogQuery.languageKey))]
        case let language:
            clauses.append("language_key = ?")
            args += [language]
        }
        if !query.globalLanguages.isEmpty {
            clauses.append("language_key IN (SELECT value FROM json_each(?))")
            args += [try json(query.globalLanguages.map(LinuxDoCatalogQuery.languageKey))]
        }
        if query.license.isActive {
            clauses.append("license_key IN (SELECT value FROM json_each(?))")
            args += [try json(query.license.persistedValues)]
        }
        if query.hideArchived { clauses.append("archived = 0") }
        if query.hideForks { clauses.append("fork = 0") }
        if !query.search.isEmpty {
            clauses.append("linuxdo_search(full_name, description, ?)")
            args += [query.search]
        }
        for membership in memberships {
            clauses.append("repo_id \(membership.includes ? "IN" : "NOT IN") (SELECT value FROM json_each(?))")
            args += [try json(membership.ids)]
        }
        return (clauses.joined(separator: " AND "), args)
    }

    private static func json(_ values: some Encodable) throws -> String {
        String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
    }
}
