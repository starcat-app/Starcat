//
//  RepoNoteRepository.swift
//  Starcat
//
//  RepoNote 持久化 Repository（GRDB 实现，承载笔记 + 状态 + 私有知识库状态）。
//
//  ⚠️ 命名约定（与 D-01 一致）：
//  - 内部 struct `GRDBRepoNoteRepository`
//  - 协议 `RepoNoteRepositoryProtocol`（同目录）
//
//  schema 对照（DatabaseMigrationsV1.createRepoNotes）：
//    repo_id INTEGER PRIMARY KEY → repos.id ON DELETE CASCADE
//    content TEXT
//    status  TEXT NOT NULL DEFAULT 'unread'
//    library_state TEXT NOT NULL DEFAULT 'outside_library'
//    library_updated_at TEXT
//    is_ai_generated BOOLEAN NOT NULL DEFAULT 0
//    edited_at TEXT
//
//  幂等性 / 自动创建逻辑：
//  - `updateContent` / `updateStatus` 在 repo_notes 行缺失时，会先插入一行
//    （另一字段保持默认/nil），再 UPDATE 真正要改的字段。
//  - 这样 UI 端不必先 `find` 再决定 insert/update，调用更顺。
//

import Foundation
import GRDB

struct GRDBRepoNoteRepository: RepoNoteRepositoryProtocol {

    private let database: any DatabaseManaging

    init(database: any DatabaseManaging) {
        self.database = database
    }

    // MARK: - 查询

    func find(repoId: Int64) async throws -> RepoNote? {
        try await database.writer.read { db in
            try RepoNote.fetchOne(db, key: repoId)
        }
    }

    func fetchStatusMap(repoIds: [Int64]) async throws -> [Int64: RepoStatus] {
        guard !repoIds.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: repoIds.count).joined(separator: ",")
        // 注意：`args` 必须在闭包内构造。GRDB 的 `writer.read { ... }` 闭包是 `@Sendable`，
        // 但 `[any DatabaseValueConvertible]` 是非 Sendable（GRDB 的协议未标 Sendable）。
        // 若在闭包外构造 args 然后被捕获，会触发 Swift 6 严格模式的 "non-Sendable type
        // captured in @Sendable closure" 报错。改为闭包内构造后，跨 actor 边界的只有
        // `[Int64]`（天然 Sendable）和 `placeholders`（String，Sendable），安全。
        return try await database.writer.read { db in
            let args = repoIds.map { $0 as DatabaseValueConvertible }
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT repo_id, status FROM repo_notes WHERE repo_id IN (\(placeholders))",
                arguments: StatementArguments(args)
            )
            var map: [Int64: RepoStatus] = [:]
            for row in rows {
                let id: Int64 = row["repo_id"]
                let raw: String = row["status"]
                // 用 lenient parse：v1 旧值 reading/deprecated 会被回落到 .read。
                map[id] = RepoStatus.parse(raw)
            }
            return map
        }
    }

    func fetchLibraryState(repoId: Int64) async throws -> LibraryState {
        try await database.writer.read { db in
            let raw = try String.fetchOne(
                db,
                sql: "SELECT library_state FROM repo_notes WHERE repo_id = ?",
                arguments: [repoId]
            )
            return LibraryState.parse(raw)
        }
    }

    func fetchLibraryStateMap(repoIds: [Int64]) async throws -> [Int64: LibraryState] {
        guard !repoIds.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: repoIds.count).joined(separator: ",")
        return try await database.writer.read { db in
            let args = repoIds.map { $0 as DatabaseValueConvertible }
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT repo_id, library_state FROM repo_notes WHERE repo_id IN (\(placeholders))",
                arguments: StatementArguments(args)
            )
            var map: [Int64: LibraryState] = [:]
            for row in rows {
                let id: Int64 = row["repo_id"]
                let raw: String? = row["library_state"]
                map[id] = LibraryState.parse(raw)
            }
            return map
        }
    }

    /// 全表 status 映射。
    ///
    /// 性能特征：
    /// - 无参数 → 调用方不必先拿到 fetched ids，可与 repo fetch 真正并行（`async let`）。
    /// - 无 `IN (...)` → 省掉 1800+ 个占位符的 SQL 解析 + 参数绑定（之前是这部分让 fetchStatusMap 慢 50~100ms）。
    /// - `repo_notes` 表通常很小（只在用户主动标记状态 / 写笔记时建行），全表扫描成本远低于带参 IN 查询。
    func fetchAllStatusMap() async throws -> [Int64: RepoStatus] {
        try await database.writer.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT repo_id, status FROM repo_notes")
            var map: [Int64: RepoStatus] = [:]
            for row in rows {
                let id: Int64 = row["repo_id"]
                let raw: String = row["status"]
                map[id] = RepoStatus.parse(raw)
            }
            return map
        }
    }

    func fetchAllLibraryStateMap() async throws -> [Int64: LibraryState] {
        try await database.writer.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT repo_id, library_state FROM repo_notes")
            var map: [Int64: LibraryState] = [:]
            for row in rows {
                let id: Int64 = row["repo_id"]
                let raw: String? = row["library_state"]
                map[id] = LibraryState.parse(raw)
            }
            return map
        }
    }

    func fetchRepos(byStatus status: RepoStatus) async throws -> [Repo] {
        try await database.writer.read { db in
            try Repo.fetchAll(db, sql: """
                SELECT r.* FROM repos r
                JOIN repo_notes n ON n.repo_id = r.id
                WHERE n.status = ? AND r.is_starred = 1
                ORDER BY r.starred_at DESC
                """, arguments: [status.rawValue])
        }
    }

    /// 有非空私有笔记的 repo id 集合（`requireNote` predicate 用）。
    func fetchRepoIdsWithNonEmptyContent() async throws -> Set<Int64> {
        try await database.writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT repo_id FROM repo_notes
                WHERE content IS NOT NULL AND TRIM(content) != ''
                """)
            return Set(rows.map { $0["repo_id"] as Int64 })
        }
    }

    func statusCounts() async throws -> [RepoStatus: Int] {
        try await database.writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT n.status AS status, COUNT(*) AS cnt
                FROM repo_notes n
                JOIN repos r ON r.id = n.repo_id
                WHERE r.is_starred = 1
                GROUP BY n.status
                """)
            var result: [RepoStatus: Int] = [:]
            for row in rows {
                let raw: String = row["status"]
                let count: Int = row["cnt"]
                // 用 lenient parse：v1 旧值 reading/deprecated 会被并入 .read 计数。
                let status = RepoStatus.parse(raw)
                result[status, default: 0] += count
            }
            return result
        }
    }

    func libraryStateCounts() async throws -> [LibraryState: Int] {
        try await database.writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT library_state, COUNT(*) AS cnt
                FROM repo_notes
                GROUP BY library_state
                """)
            var result: [LibraryState: Int] = [:]
            for row in rows {
                let raw: String? = row["library_state"]
                let count: Int = row["cnt"]
                let state = LibraryState.parse(raw)
                result[state, default: 0] += count
            }
            return result
        }
    }

    // MARK: - 写入

    func upsert(_ note: RepoNote) async throws {
        try await database.writer.write { db in
            var copy = note
            try copy.upsert(db)
        }
        postContentDidChange(
            repoId: note.repoId,
            content: note.content,
            editedAt: note.editedAt
        )
    }

    /// 仅更新 content；行不存在则创建一行（status="unread"，is_ai_generated=0）。
    /// content 传 nil 表示清空。editedAt 自动设为 now。
    func updateContent(repoId: Int64, content: String?) async throws {
        let nowISO = ISO8601DateFormatter.shared.string(from: Date())
        try await database.writer.write { db in
            // 用 UPSERT 语义：先 INSERT（如不存在），ON CONFLICT 时 UPDATE content + edited_at
            try db.execute(
                sql: """
                INSERT INTO repo_notes (
                    repo_id, content, status, library_state, library_updated_at, is_ai_generated, edited_at
                )
                VALUES (?, ?, 'unread', 'outside_library', NULL, 0, ?)
                ON CONFLICT(repo_id) DO UPDATE SET
                    content = excluded.content,
                    edited_at = excluded.edited_at
                """,
                arguments: [repoId, content, nowISO]
            )
        }
        postContentDidChange(repoId: repoId, content: content, editedAt: nowISO)
    }

    /// 仅更新 status；行不存在则创建一行（content=NULL）。editedAt 自动设为 now。
    func updateStatus(repoId: Int64, status: RepoStatus) async throws {
        let nowISO = ISO8601DateFormatter.shared.string(from: Date())
        let insertedLibraryState = status == .using
            ? LibraryState.inLibrary.rawValue
            : LibraryState.outsideLibrary.rawValue
        let insertedLibraryUpdatedAt: String? = status == .using ? nowISO : nil
        try await database.writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO repo_notes (
                    repo_id, content, status, library_state, library_updated_at, is_ai_generated, edited_at
                )
                VALUES (?, NULL, ?, ?, ?, 0, ?)
                ON CONFLICT(repo_id) DO UPDATE SET
                    status = excluded.status,
                    library_state = CASE
                        WHEN excluded.status = 'using' THEN 'in_library'
                        ELSE repo_notes.library_state
                    END,
                    library_updated_at = CASE
                        WHEN excluded.status = 'using' AND repo_notes.library_state != 'in_library'
                            THEN excluded.edited_at
                        ELSE repo_notes.library_updated_at
                    END,
                    edited_at = excluded.edited_at
                """,
                arguments: [repoId, status.rawValue, insertedLibraryState, insertedLibraryUpdatedAt, nowISO]
            )
        }
        if status == .using {
            postLibraryStateDidChange(repoId: repoId, state: .inLibrary)
        }
    }

    /// 确保 repo 在 `repos` 表中至少有一条基础行，否则 `repo_notes` 的 FK 约束会拒绝写入。
    ///
    /// 探索模块（发现/趋势/热门/新发布）的仓库可能尚未同步到本地，加入知识库时先补一条
    /// 占位行（owner/name 来自 SelectionSnapshot），后续 README 加载 / 详情页展开时会用
    /// 远程数据覆写为完整字段。
    func ensureRepoRowExists(repoId: Int64, owner: String, name: String) async throws {
        let fullName = "\(owner)/\(name)"
        try await database.writer.write { db in
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO repos (id, owner, name, full_name, html_url, stars_count, forks_count, watchers_count, is_private, is_fork, is_archived, is_starred)
                VALUES (?, ?, ?, ?, ?, 0, 0, 0, 0, 0, 0, 0)
                """,
                arguments: [repoId, owner, name, fullName, "https://github.com/\(fullName)"]
            )
        }
    }

    func updateLibraryState(repoId: Int64, state: LibraryState) async throws {
        let nowISO = ISO8601DateFormatter.shared.string(from: Date())
        try await database.writer.write { db in
            switch state {
            case .inLibrary:
                try db.execute(
                    sql: """
                    INSERT INTO repo_notes (
                        repo_id, content, status, library_state, library_updated_at, is_ai_generated, edited_at
                    )
                    VALUES (?, NULL, 'unread', 'in_library', ?, 0, ?)
                    ON CONFLICT(repo_id) DO UPDATE SET
                        library_state = excluded.library_state,
                        library_updated_at = excluded.library_updated_at
                    WHERE repo_notes.library_state != excluded.library_state
                    """,
                    arguments: [repoId, nowISO, nowISO]
                )

            case .outsideLibrary:
                // 默认状态不创建空 repo_notes 行；只有已有用户数据时才记录这次实际移出。
                try db.execute(
                    sql: """
                    UPDATE repo_notes
                    SET library_state = 'outside_library',
                        library_updated_at = ?
                    WHERE repo_id = ? AND library_state != 'outside_library'
                    """,
                    arguments: [nowISO, repoId]
                )
            }
        }
        postLibraryStateDidChange(repoId: repoId, state: state)
    }

    /// 自动状态机：unread → read，单条 SQL 实现幂等升级。
    ///
    /// **SQL 设计**：
    /// - INSERT 缺省 status = 'read'（首次进详情页 + README 加载完即升级）
    /// - ON CONFLICT 时仅在 status='unread' 才写新值；其他状态（read/using 或 v1 兼容值
    ///   reading/deprecated）保持不动。WHERE 子句锁住"绝不下行"语义。
    /// - editedAt 同样只在 unread 升级路径上更新；read/using 行不被擦动（避免无意义触发
    ///   CloudKit 同步）。
    func markAsReadIfNeeded(repoId: Int64) async throws {
        let nowISO = ISO8601DateFormatter.shared.string(from: Date())
        try await database.writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO repo_notes (
                    repo_id, content, status, library_state, library_updated_at, is_ai_generated, edited_at
                )
                VALUES (?, NULL, 'read', 'outside_library', NULL, 0, ?)
                ON CONFLICT(repo_id) DO UPDATE SET
                    status = 'read',
                    edited_at = excluded.edited_at
                WHERE repo_notes.status = 'unread'
                """,
                arguments: [repoId, nowISO]
            )
        }
    }

    private func postContentDidChange(repoId: Int64, content: String?, editedAt: String?) {
        var userInfo: [String: Any] = [
            "repoId": repoId,
            "content": content ?? ""
        ]
        if let editedAt {
            userInfo["editedAt"] = editedAt
        }
        NotificationCenter.default.post(
            name: .repoNoteContentDidChange,
            object: nil,
            userInfo: userInfo
        )
    }

    private func postLibraryStateDidChange(repoId: Int64, state: LibraryState) {
        NotificationCenter.default.post(
            name: .repoLibraryStateDidChange,
            object: nil,
            userInfo: [
                "repoId": repoId,
                "libraryState": state.rawValue
            ]
        )
    }
}
