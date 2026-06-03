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
//  - v5：repo_embeddings / ai_summaries（AI 功能上线时）
//  - v6：release_subscriptions / releases（Release 订阅功能上线时）
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
        registerV4(into: &migrator)
        registerV5(into: &migrator)
    }

    // MARK: - v5（AI 语义搜索 + 单仓智能化缓存）

    /// v5：新增 AI 语义搜索与单仓智能化需要的两张本地缓存表。
    ///
    /// **repo_embeddings**
    /// - 采用 SQLite BLOB 保存 Float32 向量，不依赖 sqlite-vss / sqlite-vec 动态扩展。
    ///   原因：macOS 沙盒分发动态 SQLite extension 会引入签名、加载路径和 App Review 风险；
    ///   Starcat MVP 规模在几千条 starred repo 内，Swift 内存 cosine 排名足够稳定。
    /// - `content_hash` 记录参与向量化的 repo 文本指纹；repo 描述 / topics 变更后自动重建。
    /// - `(model, content_hash)` 与 `dimensions` 让后续换 embedding model 时不会误用旧向量。
    ///
    /// **ai_summaries**
    /// - 单仓智能化结果只缓存 AI 输出 JSON，不自动写标签；标签应用仍由用户显式确认。
    /// - `source_hash` 与 `model` 用于判断 README / repo 元数据变更后是否需要重新生成。
    private static func registerV5(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v5-ai-cache") { db in
            try createRepoEmbeddings(db)
            try createAISummaries(db)
        }
    }

    private static func createRepoEmbeddings(_ db: Database) throws {
        try db.create(table: "repo_embeddings") { t in
            t.column("repo_id", .integer).notNull()
                .references("repos", column: "id", onDelete: .cascade)
            t.column("model", .text).notNull()
            t.column("content_hash", .text).notNull()
            t.column("dimensions", .integer).notNull()
            t.column("embedding", .blob).notNull()
            t.column("indexed_text", .text).notNull()
            t.column("updated_at", .text).notNull()

            t.primaryKey(["repo_id", "model"])
        }

        try db.create(index: "idx_repo_embeddings_model_hash", on: "repo_embeddings", columns: ["model", "content_hash"])
    }

    private static func createAISummaries(_ db: Database) throws {
        try db.create(table: "ai_summaries") { t in
            t.column("repo_id", .integer).notNull()
                .references("repos", column: "id", onDelete: .cascade)
            t.column("model", .text).notNull()
            t.column("source_hash", .text).notNull()
            t.column("summary_json", .text).notNull()
            t.column("generated_at", .text).notNull()

            t.primaryKey(["repo_id", "model"])
        }

        try db.create(index: "idx_ai_summaries_repo", on: "ai_summaries", columns: ["repo_id"])
    }

    // MARK: - v4（Trending 列表 + README 持久化）

    /// v4：新增 Trending 缓存两张表（与 manage 路径完全隔离）。
    ///
    /// **背景**：原 `TrendingRepository` 仅在 actor 内用 Dictionary 做内存缓存，
    /// 进程退出即丢；`ReadmeAPI.refreshTrendingReadme` 也完全不读写本地数据库。
    /// 用户进入 Trending → 切日/周/月榜 / 切语言 / 杀进程后重开 都要重新从外部
    /// API 拉一次，离线场景什么都看不到，且每次首屏要等到网络回来才有内容。
    ///
    /// 决策（dong4j 2026-06-02）：scope_b + schema_a + readme_pk_c + ttl_c。
    /// - scope_b：列表 + README 两块都做持久化
    /// - schema_a：独立 `trending_repos` / `trending_readmes` 表，与 `repos` /
    ///   `readmes` 完全隔离（trending 没有真实 GitHub repo id，强制复用 `repos.id`
    ///   PK 会触发"何时从外部 API 补 id"的链式问题；与 manage 路径解耦最干净）
    /// - readme_pk_c：`trending_readmes` 用 `full_name` 作 PK（trending 只有 `owner/repo`，
    ///   没 Int64 id；与 `readmes.repo_id` 保持隔离）
    /// - ttl_c：列表与 README 都不设 TTL，每次进 Trending 都强制走网络重拉，本地
    ///   缓存只承担"离线兜底 + 快速首屏 SWR"角色（先把缓存立即上屏，再后台拉网络覆盖）
    ///
    /// **`trending_repos` 表设计**：
    /// - 复合 PK `(period, language_filter, rank)`：同一榜单（period+language_filter）内
    ///   按 `rank` 排序定位每行；同一 repo 出现在不同榜单（如 daily Swift 第 3 + weekly Swift 第 5）
    ///   各算一行，互不覆盖。
    /// - `language_filter` 用空串 `""` 表示"全部语言"（与 `TrendingLanguage.all.apiValue == ""` 对齐）。
    /// - `contributors_json` 存 JSON 数组字符串，避免再开一张明细表（trending 贡献者数量稳定 ≤ 5，
    ///   且只读不查询单个贡献者）。
    /// - `cached_at` 仅用于"缓存于 X 时间前"展示，不参与 TTL 判断。
    /// - 索引 `(full_name)`：将来如做"该 repo 在哪些榜单出现过"反查时复用，当前未启用。
    ///
    /// **`trending_readmes` 表设计**：
    /// - PK `full_name`（TEXT）：trending 没有真实 repo id，用 `owner/name` 唯一标识。
    /// - 字段语义与 `readmes` 表完全对齐：`rendered_html` / `etag` / `last_modified` /
    ///   `cached_at` / `size`，让 `ReadmeAPI` 复用同一套 SWR + ETag 304 + 大小统计逻辑。
    ///
    /// **保留的差异（与 readmes / repos 表对比）**：
    /// - 不挂 FTS5 触发器：trending 列表是榜单切换型，不需要全文搜索。
    /// - 不与 `starred_repos` / `repo_tags` 等用户数据表关联：trending 是临时榜单，
    ///   不应该有 cascade 删除影响用户数据的可能。
    private static func registerV4(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v4-trending-cache") { db in
            try createTrendingRepos(db)
            try createTrendingReadmes(db)
        }
    }

    private static func createTrendingRepos(_ db: Database) throws {
        try db.create(table: "trending_repos") { t in
            // 榜单维度
            t.column("period", .text).notNull()                  // daily / weekly / monthly
            t.column("language_filter", .text).notNull()         // "" 表示全部语言
            t.column("rank", .integer).notNull()                 // 在该 (period, language_filter) 列表里的排名（0-based）

            // repo 维度
            t.column("full_name", .text).notNull()
            t.column("owner", .text).notNull()
            t.column("name", .text).notNull()
            t.column("description", .text)
            t.column("language", .text)
            t.column("stars_count", .integer).notNull().defaults(to: 0)
            t.column("forks_count", .integer).notNull().defaults(to: 0)
            t.column("stars_in_period", .integer).notNull().defaults(to: 0)
            t.column("contributors_json", .text)                 // JSON [{username, avatarURL, profileURL}]

            // 缓存维度
            t.column("cached_at", .text).notNull()

            t.primaryKey(["period", "language_filter", "rank"])
        }

        // full_name 反查索引（可选；先建好避免后续 ALTER）
        try db.create(index: "idx_trending_repos_full_name", on: "trending_repos", columns: ["full_name"])
    }

    private static func createTrendingReadmes(_ db: Database) throws {
        try db.create(table: "trending_readmes") { t in
            t.column("full_name", .text).primaryKey()
            t.column("rendered_html", .text)
            t.column("etag", .text)
            t.column("last_modified", .text)
            t.column("cached_at", .text).notNull()
            t.column("size", .integer).notNull().defaults(to: 0)
        }

        try db.create(index: "idx_trending_readmes_cached", on: "trending_readmes", columns: ["cached_at"])
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
