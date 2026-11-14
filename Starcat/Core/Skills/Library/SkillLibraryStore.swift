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
    var assignmentTransactions: URL { root.appendingPathComponent("assignment-transactions", isDirectory: true) }
    var removalTransactions: URL { root.appendingPathComponent("removal-transactions", isDirectory: true) }

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
    private var currentScanGeneration: UUID?

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
                locations: SkillLibraryLocation.fetchAll(db),
                assignments: SkillAssignment.fetchAll(db),
                updateChecks: SkillUpdateCheck.fetchAll(db)
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

    func operations() throws -> [SkillOperationRecord] {
        try writer().read { try SkillOperationRecord.order(Column("created_at").desc).fetchAll($0) }
    }

    func save(_ operation: SkillOperationRecord) throws {
        try writer().write { try operation.save($0) }
    }

    /// 检查期间安装指针可能变化；旧 revision 的响应直接忽略，避免恢复旧更新角标。
    func save(_ check: SkillUpdateCheck) throws {
        try writer().write { db in
            guard let entry = try SkillLibraryEntry.fetchOne(db, key: check.entryID.uuidString),
                  entry.currentRevisionID == check.revisionID else { return }
            try check.save(db)
        }
    }

    /// 分配回执与索引同一次写事务更新；旧计划不能覆盖后来建立的另一分配。
    func commitAssignment(_ journal: SkillAssignmentJournal) throws {
        currentScanGeneration = nil
        try writer().write { db in
            let plan = journal.plan
            let path = URL(fileURLWithPath: plan.target.resolvedParent).appendingPathComponent(plan.entry.manifestName).path
            let current = try SkillAssignment.filter(Column("target_path") == path).fetchOne(db)
            guard current == plan.previous || current == journal.assignment else { throw SkillOperationError.ownership }
            if let assignment = journal.assignment { try assignment.save(db) }
            else if let current { try current.delete(db) }
        }
    }

    /// 来源唯一键可能已被前一个导入创建；只复用来源身份，不合并两个受管条目。
    func commitContent(_ plan: SkillContentOperationPlan) throws {
        currentScanGeneration = nil
        try writer().write { db in
            let source = try SkillLibrarySource
                .filter(Column("kind") == plan.source.kind.rawValue)
                .filter(Column("canonical_locator") == plan.source.canonicalLocator)
                .filter(Column("subdirectory") == plan.source.subdirectory)
                .fetchOne(db) ?? plan.source
            try source.save(db)
            var entry = plan.entry
            entry.sourceID = source.id
            entry.currentRevisionID = plan.revision.id
            try entry.save(db)
            try plan.revision.save(db)
        }
    }

    /// 旧 revision 仍在历史表中；回滚只恢复旧指针和条目元数据，不删除历史版本。
    func restoreEntry(_ entry: SkillLibraryEntry) throws {
        currentScanGeneration = nil
        try writer().write { try entry.save($0) }
    }

    /// 文件已移到有 journal 的暂存区后才删除索引。显式按外键次序删除，
    /// 保留操作历史及共享来源；撤销旧扫描代次，避免已移除条目被旧报告重新创建。
    func commitRemoval(_ plan: SkillRemovalPlan) throws {
        currentScanGeneration = nil
        try writer().write { db in
            guard let entry = try SkillLibraryEntry.fetchOne(db, key: plan.entry.id.uuidString) else { return }
            guard entry == plan.entry,
                  try SkillAssignment.filter(Column("entry_id") == entry.id.uuidString).fetchCount(db) == 0
            else { throw SkillOperationError.planChanged }
            try SkillUpdateCheck.filter(Column("entry_id") == entry.id.uuidString).deleteAll(db)
            try SkillLibraryLocation.filter(Column("entry_id") == entry.id.uuidString).deleteAll(db)
            try SkillLibraryRevision.filter(Column("entry_id") == entry.id.uuidString).deleteAll(db)
            try entry.delete(db)
            if let sourceID = entry.sourceID,
               try SkillLibraryEntry.filter(Column("source_id") == sourceID.uuidString).fetchCount(db) == 0 {
                try SkillLibrarySource.deleteOne(db, key: sourceID.uuidString)
            }
        }
    }

    /// 发放新的扫描代次；数据库提交前再次比较，旧扫描即使晚返回也不能污染索引。
    func beginScan() -> UUID {
        let generation = UUID()
        currentScanGeneration = generation
        return generation
    }

    /// 只撤销自己的代次，旧窗口的异步清理不能使新窗口的扫描失效。
    func invalidateScan(generation: UUID) {
        if currentScanGeneration == generation { currentScanGeneration = nil }
    }

    /// 一次事务合并全部根，只有完整覆盖或确认缺失才能把未见位置标为 missing。
    @discardableResult
    func apply(_ report: SkillScanReport) throws -> Bool {
        guard currentScanGeneration == report.generationID else { return false }
        let paths = paths
        try writer().write { db in
            let storedEntries = try SkillLibraryEntry.fetchAll(db)
            let storedLocations = try SkillLibraryLocation.fetchAll(db)
            let storedRoots = try SkillLibraryRoot.fetchAll(db)
            var entriesByID = Dictionary(uniqueKeysWithValues: storedEntries.map { ($0.id, $0) })
            var physicalEntries: [String: UUID] = [:]
            var locationsByRoot: [UUID: [String: SkillLibraryLocation]] = [:]
            for location in storedLocations {
                physicalEntries[location.resolvedPath] = location.entryID
                locationsByRoot[location.rootID, default: [:]][location.lexicalPath] = location
            }
            // 只有已登记的受管条目能关联私有内容。根名或外部 receipt 不触发自动接管。
            for entry in storedEntries where entry.managementKind == .managed {
                let content = paths.entryDirectory(entry.id).appendingPathComponent("content")
                    .appendingPathComponent(entry.manifestName).resolvingSymlinksInPath()
                physicalEntries[content.path] = entry.id
            }
            let grouped = Dictionary(grouping: report.results.flatMap(\.candidates), by: \.resolvedPath)
            // 发布后、元数据补写前可能触发扫描。使用已批准操作的 entryID 保持只读身份，
            // 避免恢复后留下另一条“外部副本”；操作记录本身不授予受管写权限。
            let pending = try SkillOperationRecord
                .filter(Column("state") == "running" || Column("state") == "needsRecovery").fetchAll(db)
            for operation in pending {
                guard let entryID = operation.entryID else { continue }
                let prefix = paths.entryDirectory(entryID).appendingPathComponent("content")
                    .resolvingSymlinksInPath().path + "/"
                for path in grouped.keys where path.hasPrefix(prefix)
                    && !path.dropFirst(prefix.count).contains("/") {
                    physicalEntries[path] = entryID
                }
            }
            for (path, candidates) in grouped {
                let entryID = physicalEntries[path] ?? UUID()
                let previous = entriesByID[entryID]
                let metadata = candidates.compactMap(\.metadata).first
                var entry = previous ?? SkillLibraryEntry(
                    id: entryID, manifestName: URL(fileURLWithPath: path).lastPathComponent,
                    summary: "", managementKind: .external
                )
                if let metadata {
                    entry.manifestName = metadata.name
                    entry.summary = metadata.description
                }
                let diagnostics = Set(candidates.compactMap(\.diagnostic)).sorted()
                entry.diagnostic = diagnostics.isEmpty ? nil : diagnostics.joined(separator: "\n")
                if previous != entry {
                    entry.updatedAt = Date().timeIntervalSince1970
                    try entry.save(db)
                }
                entriesByID[entryID] = entry
                physicalEntries[path] = entryID
            }
            for result in report.results {
                var root = result.root
                root.resolvedPath = result.resolvedPath
                root.coverage = result.coverage
                root.diagnostic = result.diagnostics.isEmpty ? nil : result.diagnostics.joined(separator: "\n")
                if result.coverage == .complete { root.lastSuccessAt = Date().timeIntervalSince1970 }
                try root.save(db)
                let previous = locationsByRoot[root.id, default: [:]]
                var seen: Set<String> = []
                for candidate in result.candidates {
                    guard let entryID = physicalEntries[candidate.resolvedPath] else { continue }
                    let location = SkillLibraryLocation(
                        id: previous[candidate.lexicalPath]?.id ?? UUID(),
                        entryID: entryID, rootID: root.id, lexicalPath: candidate.lexicalPath,
                        resolvedPath: candidate.resolvedPath, kind: candidate.kind,
                        lastSeenGeneration: report.generationID
                    )
                    try location.save(db)
                    seen.insert(candidate.lexicalPath)
                }
                for var location in previous.values where !seen.contains(location.lexicalPath) {
                    if result.coverage.confirmsAbsence {
                        location.scanState = .missing
                    } else if location.scanState != .missing {
                        location.scanState = .stale
                    }
                    try location.save(db)
                }
            }
            let activeRoots = Set(report.results.map { $0.root.id })
            for var root in storedRoots where !activeRoots.contains(root.id) {
                root.coverage = .notScanned
                root.diagnostic = "Root is no longer configured"
                try root.save(db)
                for var location in locationsByRoot[root.id, default: [:]].values where location.scanState != .missing {
                    location.scanState = .stale
                    try location.save(db)
                }
            }
        }
        return true
    }

    /// 缺失与损坏分开处理；权限错误不能被当成“没有回执”而重新接管内容。
    func receipt(for entryID: UUID) throws -> SkillLibraryReceipt? {
        let url = paths.entryDirectory(entryID).appendingPathComponent("receipt.json")
        do {
            guard !SkillFilePrimitives.isSymbolicLink(url) else { throw CocoaError(.fileReadCorruptFile) }
            let receipt = try JSONDecoder().decode(SkillLibraryReceipt.self, from: Data(contentsOf: url))
            guard receipt.formatVersion == 1, receipt.entryID == entryID,
                  receipt.contentDigest == receipt.fingerprint.digest else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return receipt
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    /// 用于显式结束会话或重开验证；下一次访问会按同一路径重新打开。
    func close() throws {
        currentScanGeneration = nil
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
        migrator.registerMigration("v2-skill-operations") { db in
            // 导入的 operation 早于 entry 存在，因此 entry_id 有意不建立外键。
            try db.execute(sql: """
                ALTER TABLE skill_entries ADD COLUMN tracking_ref TEXT;
                CREATE TABLE skill_operations (
                    id TEXT PRIMARY KEY NOT NULL,
                    entry_id TEXT,
                    kind TEXT NOT NULL,
                    state TEXT NOT NULL,
                    journal_path TEXT NOT NULL,
                    result_json TEXT,
                    created_at DOUBLE NOT NULL,
                    updated_at DOUBLE NOT NULL
                );
                CREATE INDEX idx_skill_operations_entry ON skill_operations(entry_id);
                """)
        }
        migrator.registerMigration("v3-skill-assignments") { db in
            try db.execute(sql: """
                CREATE TABLE skill_assignments (
                    id TEXT PRIMARY KEY NOT NULL,
                    entry_id TEXT NOT NULL REFERENCES skill_entries(id),
                    target_json TEXT NOT NULL,
                    target_path TEXT NOT NULL UNIQUE,
                    content_path TEXT NOT NULL,
                    desired_state TEXT NOT NULL,
                    link_identity_json TEXT
                );
                CREATE INDEX idx_skill_assignments_entry ON skill_assignments(entry_id);
                """)
        }
        migrator.registerMigration("v4-skill-update-checks") { db in
            try db.execute(sql: """
                CREATE TABLE skill_update_checks (
                    entry_id TEXT PRIMARY KEY NOT NULL REFERENCES skill_entries(id),
                    revision_id TEXT,
                    state TEXT NOT NULL,
                    has_update BOOLEAN NOT NULL DEFAULT 0,
                    available_commit TEXT,
                    attempted_at DOUBLE NOT NULL,
                    succeeded_at DOUBLE,
                    message TEXT
                );
                """)
        }
        try migrator.migrate(writer)
    }
}
