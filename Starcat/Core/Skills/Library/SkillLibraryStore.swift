//
//  SkillLibraryStore.swift
//  Starcat
//
//  账号外的独立 GRDB 库。构造时只做渠道判断，首次 actor 方法访问时才打开磁盘，
//  避免 Scene 求值、App Store 启动或 MainActor 初始化触发建库。
//

import Foundation
import GRDB

/// 路径计算没有文件系统写入，也不接收账号参数。
struct SkillLibraryPaths: Sendable {
    let root: URL
    var database: URL { root.appendingPathComponent("library.sqlite") }
    var managed: URL { root.appendingPathComponent("managed", isDirectory: true) }
    var transactions: URL { root.appendingPathComponent("transactions", isDirectory: true) }

    static func applicationDefault() throws -> Self {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { throw CocoaError(.fileReadUnknown) }
        return Self(root: support
            .appendingPathComponent(AppConstants.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("skill-library", isDirectory: true))
    }

    func entryDirectory(_ entryID: UUID) -> URL {
        managed.appendingPathComponent(entryID.uuidString, isDirectory: true)
    }
}

/// actor 串行组织关系写入，GRDB 负责 SQLite 事务；方法内部不跨 await 拆开一次提交。
actor SkillLibraryStore {
    nonisolated let paths: SkillLibraryPaths
    private var databaseQueue: DatabaseQueue?

    init(
        distributionGate: DistributionGate = DistributionGate(),
        paths: SkillLibraryPaths? = nil
    ) throws {
        try distributionGate.requireDirect(.skillManagement)
        self.paths = try paths ?? .applicationDefault()
    }

    /// 所有关联在同一 read 中读取；不会把读取失败替换成一个成功的空库。
    func snapshot() throws -> SkillLibrarySnapshot {
        try writer().read { db in
            try SkillLibrarySnapshot(
                sources: SkillLibrarySource.fetchAll(db),
                entries: SkillLibraryEntry.order(Column("manifest_name"), Column("id")).fetchAll(db),
                revisions: SkillLibraryRevision.fetchAll(db),
                roots: SkillLibraryRoot.fetchAll(db),
                locations: SkillLibraryLocation.fetchAll(db)
            )
        }
    }

    func save(_ source: SkillLibrarySource) throws {
        try writer().write { try source.save($0) }
    }

    func save(_ entry: SkillLibraryEntry) throws {
        try writer().write { try entry.save($0) }
    }

    func save(_ revision: SkillLibraryRevision) throws {
        try writer().write { try revision.save($0) }
    }

    func save(_ root: SkillLibraryRoot) throws {
        try writer().write { try root.save($0) }
    }

    func save(_ location: SkillLibraryLocation) throws {
        try writer().write { try location.save($0) }
    }

    /// 缺失与损坏分开处理；权限错误不能被当成“没有回执”而重新接管内容。
    func receipt(for entryID: UUID) throws -> SkillLibraryReceipt? {
        let url = paths.entryDirectory(entryID).appendingPathComponent("receipt.json")
        do {
            let receipt = try JSONDecoder().decode(SkillLibraryReceipt.self, from: Data(contentsOf: url))
            guard receipt.formatVersion == 1, receipt.entryID == entryID else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return receipt
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    /// 用于显式结束会话或重开验证；下一次访问会按同一路径重新打开。
    func close() throws {
        try databaseQueue?.close()
        databaseQueue = nil
    }

    /// 只在 actor 执行域创建目录、打开连接和迁移，不在 UI getter 做同步 I/O。
    private func writer() throws -> DatabaseQueue {
        if let databaseQueue { return databaseQueue }
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue = try DatabaseQueue(path: paths.database.path, configuration: configuration)
        try Self.migrate(queue)
        databaseQueue = queue
        return queue
    }

    /// 独立库有自己的迁移账本，不修改正式用户主库的任何历史 migration。
    private static func migrate(_ writer: some DatabaseWriter) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-skill-library") { db in
            try db.execute(sql: """
                CREATE TABLE skill_sources (
                    id TEXT PRIMARY KEY NOT NULL,
                    kind TEXT NOT NULL CHECK(kind IN ('local', 'github')),
                    canonical_locator TEXT NOT NULL,
                    subdirectory TEXT NOT NULL,
                    default_ref TEXT,
                    UNIQUE(kind, canonical_locator, subdirectory)
                );
                CREATE TABLE skill_entries (
                    id TEXT PRIMARY KEY NOT NULL,
                    source_id TEXT REFERENCES skill_sources(id),
                    manifest_name TEXT NOT NULL,
                    summary TEXT NOT NULL,
                    management_kind TEXT NOT NULL CHECK(management_kind IN ('managed', 'external')),
                    current_revision_id TEXT,
                    diagnostic TEXT,
                    created_at DOUBLE NOT NULL,
                    updated_at DOUBLE NOT NULL
                );
                CREATE INDEX idx_skill_entries_source ON skill_entries(source_id);
                CREATE TABLE skill_revisions (
                    id TEXT PRIMARY KEY NOT NULL,
                    entry_id TEXT NOT NULL REFERENCES skill_entries(id),
                    content_digest TEXT NOT NULL,
                    manifest_digest TEXT NOT NULL,
                    upstream_commit TEXT,
                    created_at DOUBLE NOT NULL,
                    UNIQUE(entry_id, content_digest)
                );
                CREATE TABLE skill_roots (
                    id TEXT PRIMARY KEY NOT NULL,
                    configured_path TEXT NOT NULL UNIQUE,
                    resolved_path TEXT,
                    agent_ids_json TEXT NOT NULL,
                    scope TEXT NOT NULL,
                    coverage TEXT NOT NULL,
                    diagnostic TEXT,
                    last_success_at DOUBLE
                );
                CREATE TABLE skill_locations (
                    id TEXT PRIMARY KEY NOT NULL,
                    entry_id TEXT NOT NULL REFERENCES skill_entries(id),
                    root_id TEXT NOT NULL REFERENCES skill_roots(id),
                    lexical_path TEXT NOT NULL,
                    resolved_path TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    scan_state TEXT NOT NULL,
                    last_seen_generation TEXT,
                    UNIQUE(root_id, lexical_path)
                );
                CREATE INDEX idx_skill_locations_entry ON skill_locations(entry_id);
                CREATE INDEX idx_skill_locations_resolved ON skill_locations(resolved_path);
                """)
        }
        try migrator.migrate(writer)
    }
}
