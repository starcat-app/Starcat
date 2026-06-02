//
//  DatabaseMigrationsV1.swift
//  Starcat
//
//  数据库初始 schema 迁移，对应 docs/详细设计/01-数据库设计.md 中的 P0 表。
//
//  设计原则：
//  - 使用 GRDB DatabaseMigrator，迁移名采用语义化字符串（"v1-initial"）
//  - 不支持降级（见开发前问题清单 5.2）
//  - 表创建顺序遵循外键依赖：先 repos / tags，再依赖它们的表
//  - FTS5 触发器与 repos 表同步，使用外部内容模式（content='repos', content_rowid='id'）
//  - tokenize = 'unicode61 remove_diacritics 2'，中文友好，不用 porter
//
//  后续版本：
//  - v2：ai_summaries / repo_embeddings（AI 功能上线时）
//  - v3：release_subscriptions / releases（Release 订阅功能上线时）
//

import Foundation
import GRDB

/// 数据库迁移定义。
///
/// 暴露一个 `register(into:)` 方法将所有版本注册到 GRDB DatabaseMigrator，
/// 由 DatabaseManager 在启动时调用。
enum DatabaseMigrations {

    /// 将所有版本的迁移注册到 migrator。
    /// 调用顺序按版本递增。
    static func registerAll(into migrator: inout DatabaseMigrator) {
        registerV1(into: &migrator)
        registerV2(into: &migrator)
        registerV3(into: &migrator)
    }

    // MARK: - v3（HOM-46 性能优化：列表查询复合索引）

    /// v3：为中栏 sidebar 列表查询补复合索引。
    ///
    /// **背景**：HOM-46 性能排查发现，1810 条 starred repos 的列表查询耗时 400~700ms。
    /// 主因是 v1 schema 没有覆盖最常见的查询模式：
    ///   - `WHERE is_starred = 1 ORDER BY starred_at DESC`（fetchAllStarred / fetchUntagged）
    ///   - `WHERE is_starred = 1 AND language = ? ORDER BY starred_at DESC`（fetchByLanguage）
    ///
    /// 现有 `idx_repos_language` / `idx_repos_starred_at` 都是单列索引，SQLite
    /// query planner 在带 WHERE 多列 + ORDER BY 时往往退化到「单列扫描 + 内存排序 + filter」。
    ///
    /// **方案**：加两个复合索引
    ///   - `(is_starred, starred_at)` — 覆盖通用 starred 列表查询
    ///   - `(is_starred, language, starred_at)` — 覆盖按语言筛选
    ///
    /// SQLite 索引列顺序：等值条件列在前（is_starred / language），范围 / 排序列在后（starred_at）。
    /// SQLite 默认可以反向扫描索引（无需 DESC 关键字），所以 `ORDER BY starred_at DESC` 无需 DESC 标记。
    ///
    /// **风险**：
    /// - 写放大：每次 upsert 1 条 repo 多更新 2 个 B-tree。对 sync 影响 < 5%（写本来就批量事务）。
    /// - 空间开销：2 个索引 × 1810 行 × ~16 字节 ≈ 60KB，可忽略。
    /// - IF NOT EXISTS：兼容已经手动加过索引的调试库。
    private static func registerV3(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v3-repos-perf-indexes") { db in
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_repos_is_starred_starred_at
                ON repos(is_starred, starred_at)
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_repos_is_starred_language_starred_at
                ON repos(is_starred, language, starred_at)
                """)
        }
    }

    // MARK: - v2（W4-4 C2：sync_state 增加 stars_etag 列）

    /// v2：sync_state 增加 `stars_etag TEXT` 列，存 `/user/starred?page=1` 的 ETag。
    ///
    /// 设计说明：
    /// - 用 ALTER TABLE 增加可空列，对历史用户无破坏性
    /// - 也没必要回填初始值（NULL 即"首次同步"语义）
    /// - 列位置追加在表尾即可，GRDB / CodingKeys 都按 name 而非 ordinal 取值
    private static func registerV2(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v2-sync-state-etag") { db in
            try db.execute(sql: "ALTER TABLE sync_state ADD COLUMN stars_etag TEXT")
        }
    }

    // MARK: - v1

    /// v1：MVP P0 全部表 + FTS5。
    private static func registerV1(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1-initial") { db in
            try createRepos(db)
            try createStarredRepos(db)
            try createTags(db)
            try createRepoTags(db)
            try createRepoNotes(db)
            try createReadmes(db)
            try createSavedSearches(db)
            try createSyncState(db)
            try createTagStatsCache(db)
            try createReposFTS(db)
        }
    }

    // MARK: - v1 表创建

    private static func createRepos(_ db: Database) throws {
        try db.create(table: "repos") { t in
            t.column("id", .integer).primaryKey()
            t.column("owner", .text).notNull()
            t.column("name", .text).notNull()
            t.column("full_name", .text).notNull().unique()

            t.column("description", .text)
            t.column("language", .text)
            t.column("stars_count", .integer).notNull().defaults(to: 0)
            t.column("forks_count", .integer).notNull().defaults(to: 0)
            t.column("watchers_count", .integer).notNull().defaults(to: 0)
            t.column("topics", .text)

            t.column("license", .text)
            t.column("homepage", .text)
            t.column("html_url", .text).notNull()
            t.column("clone_url", .text)
            t.column("ssh_url", .text)

            t.column("is_private", .boolean).notNull().defaults(to: false)
            t.column("is_fork", .boolean).notNull().defaults(to: false)
            t.column("is_archived", .boolean).notNull().defaults(to: false)
            t.column("is_starred", .boolean).notNull().defaults(to: true)

            t.column("pushed_at", .text)
            t.column("created_at", .text)
            t.column("updated_at", .text)
            t.column("starred_at", .text)

            t.column("cached_at", .text)
        }

        try db.create(index: "idx_repos_language", on: "repos", columns: ["language"])
        try db.create(index: "idx_repos_stars", on: "repos", columns: ["stars_count"])
        try db.create(index: "idx_repos_starred_at", on: "repos", columns: ["starred_at"])
        try db.create(index: "idx_repos_owner_language", on: "repos", columns: ["owner", "language"])
    }

    private static func createStarredRepos(_ db: Database) throws {
        try db.create(table: "starred_repos") { t in
            t.column("repo_id", .integer).primaryKey()
                .references("repos", column: "id", onDelete: .cascade)
            t.column("user_id", .integer).notNull()
            t.column("starred_at", .text).notNull()
            t.column("sync_status", .text).notNull().defaults(to: "synced")
            t.column("last_sync_at", .text)
        }

        try db.create(index: "idx_starred_repos_user", on: "starred_repos", columns: ["user_id"])
        try db.create(index: "idx_starred_repos_starred_at", on: "starred_repos", columns: ["starred_at"])
    }

    private static func createTags(_ db: Database) throws {
        try db.create(table: "tags") { t in
            t.column("id", .text).primaryKey()
            t.column("name", .text).notNull().unique()
            t.column("color", .text)
            t.column("icon", .text)
            t.column("sort_order", .integer).notNull().defaults(to: 0)
            t.column("is_preset", .boolean).notNull().defaults(to: false)
            t.column("parent_id", .text)
                .references("tags", column: "id", onDelete: .setNull)
            t.column("created_at", .text).notNull()
            t.column("updated_at", .text).notNull()
        }

        try db.create(index: "idx_tags_parent", on: "tags", columns: ["parent_id"])
    }

    private static func createRepoTags(_ db: Database) throws {
        try db.create(table: "repo_tags") { t in
            t.column("repo_id", .integer).notNull()
                .references("repos", column: "id", onDelete: .cascade)
            t.column("tag_id", .text).notNull()
                .references("tags", column: "id", onDelete: .cascade)
            t.column("created_at", .text).notNull()

            t.primaryKey(["repo_id", "tag_id"])
        }

        try db.create(index: "idx_repo_tags_tag", on: "repo_tags", columns: ["tag_id"])
    }

    private static func createRepoNotes(_ db: Database) throws {
        try db.create(table: "repo_notes") { t in
            t.column("repo_id", .integer).primaryKey()
                .references("repos", column: "id", onDelete: .cascade)
            t.column("content", .text)
            t.column("status", .text).notNull().defaults(to: "unread")
            t.column("is_ai_generated", .boolean).notNull().defaults(to: false)
            t.column("edited_at", .text)
        }
    }

    private static func createReadmes(_ db: Database) throws {
        try db.create(table: "readmes") { t in
            t.column("repo_id", .integer).primaryKey()
                .references("repos", column: "id", onDelete: .cascade)
            t.column("content", .text)
            t.column("rendered_html", .text)
            t.column("etag", .text)
            t.column("last_modified", .text)
            t.column("cached_at", .text).notNull()
            t.column("size", .integer).notNull().defaults(to: 0)
        }

        try db.create(index: "idx_readmes_cached", on: "readmes", columns: ["cached_at"])
    }

    private static func createSavedSearches(_ db: Database) throws {
        try db.create(table: "saved_searches") { t in
            t.column("id", .text).primaryKey()
            t.column("name", .text).notNull()
            t.column("query", .text).notNull()
            t.column("created_at", .text).notNull()
            t.column("updated_at", .text).notNull()
            t.column("last_used_at", .text)
        }
    }

    private static func createSyncState(_ db: Database) throws {
        try db.create(table: "sync_state") { t in
            t.column("user_id", .integer).primaryKey()
            t.column("last_sync_at", .text)
            t.column("last_incremental_at", .text)
            t.column("starred_count", .integer).notNull().defaults(to: 0)
            t.column("synced_count", .integer).notNull().defaults(to: 0)
            t.column("failed_count", .integer).notNull().defaults(to: 0)
            t.column("sync_status", .text).notNull().defaults(to: "idle")
            t.column("error_message", .text)
        }
    }

    private static func createTagStatsCache(_ db: Database) throws {
        try db.create(table: "tag_stats_cache") { t in
            t.column("tag_id", .text).primaryKey()
                .references("tags", column: "id", onDelete: .cascade)
            t.column("repo_count", .integer).notNull()
            t.column("cached_at", .text).notNull()
        }
    }

    // MARK: - FTS5

    /// FTS5 全文搜索：使用外部内容模式与 repos 表零冗余同步。
    /// tokenize = 'unicode61 remove_diacritics 2'：CJK 按字切分、去重音符。
    private static func createReposFTS(_ db: Database) throws {
        // 使用裸 SQL 因为 GRDB 的 create(virtualTable:) DSL 对外部内容 + tokenize 选项组合表达不够直观。
        try db.execute(sql: """
            CREATE VIRTUAL TABLE repos_fts USING fts5(
                name,
                description,
                language,
                topics,
                content='repos',
                content_rowid='id',
                tokenize = 'unicode61 remove_diacritics 2'
            )
            """)

        // 触发器：保持 FTS 索引与 repos 表同步。
        try db.execute(sql: """
            CREATE TRIGGER repos_ai AFTER INSERT ON repos BEGIN
                INSERT INTO repos_fts(rowid, name, description, language, topics)
                VALUES (new.id, new.name, new.description, new.language, new.topics);
            END
            """)

        try db.execute(sql: """
            CREATE TRIGGER repos_ad AFTER DELETE ON repos BEGIN
                INSERT INTO repos_fts(repos_fts, rowid, name, description, language, topics)
                VALUES('delete', old.id, old.name, old.description, old.language, old.topics);
            END
            """)

        try db.execute(sql: """
            CREATE TRIGGER repos_au AFTER UPDATE ON repos BEGIN
                INSERT INTO repos_fts(repos_fts, rowid, name, description, language, topics)
                VALUES('delete', old.id, old.name, old.description, old.language, old.topics);
                INSERT INTO repos_fts(rowid, name, description, language, topics)
                VALUES (new.id, new.name, new.description, new.language, new.topics);
            END
            """)
    }
}
