//
//  DatabaseMigrationsV1.swift
//  Starcat
//
//  数据库初始 schema 迁移，单一 v1-initial 一次性表达 Starcat 的最终 schema。
//
//  设计原则（2026-06-11 大合并后，原 v1~v9 + R-05 共 10 处变更全部摊平进 v1）：
//
//  1. **单一信任源**：所有表 / 索引 / 触发器 / 字段全部在 v1-initial 一次性建出，
//     读这一个迁移即可看清 Starcat 当前 schema 全貌，**不需要脑补累加历史 ALTER**。
//  2. **产品上线前不写 ALTER TABLE 迁移**（dong4j 决策 2026-06-11 16:23 / 16:40）：
//     产品未发布无用户数据兼容负担，加字段 / 改类型 / 删字段一律直接改本文件建表 SQL；
//     本地删 sqlite 重建即可生效（DatabaseMigrator 不会重跑已应用的 `v1-initial`）。
//  3. **产品上线后再恢复 v2+ 迁移**：v2-xxx / v3-xxx 等以追加形式注册到 registerAll，
//     届时再启用 ALTER TABLE 迁移以保证已发布用户数据不丢。
//  4. GRDB `DatabaseMigrator` 迁移名采用语义化字符串（"v1-initial"）。
//  5. 不支持降级（见 `docs/开发前问题清单.md` §5.2）。
//  6. 表创建顺序遵循外键依赖：先 repos / tags，再依赖它们的关联 / 缓存表。
//  7. FTS5 触发器与 repos 表同步：外部内容模式 `content='repos', content_rowid='id'`
//     + tokenize `unicode61 remove_diacritics 2`（CJK 按字切分、去重音符，不用 porter
//     因为 porter 是英文词干算法对中文切碎语义）。
//
//  ---
//  **历史（已合并，仅供 git blame 考古，不再独立存在）**：
//  - 原 v2：sync_state 加 stars_etag                  → 合并进 `createSyncState`
//  - 原 v3：repos 加 2 个性能复合索引（HOM-46）        → 合并进 `createRepos`
//  - 原 v4：trending_repos + trending_readmes 两张表  → `createTrendingRepos` / `createTrendingReadmes`
//  - 原 v5：repo_embeddings + ai_summaries 两张表     → `createRepoEmbeddings` / `createAISummaries`
//          （2026-06-12 v2 改造：repo_embeddings 用 snapshot_json 替代 content_hash + indexed_text）
//  - 原 v6：release_subscriptions + releases 两张表   → `createReleaseSubscriptions` / `createReleases`
//  - 原 v7：readme_translations 一张表（HOM-68）       → `createReadmeTranslations`
//  - 原 v8：repos / trending_repos 各加 4 列          → 合并进 `createRepos` / `createTrendingRepos`
//          （StarcatRepoCardDTO v1.2 owner_avatar / subscribers_count / default_branch / open_issues_count）
//  - 原 v9：trending_repos 加 gh_repo_id              → 合并进 `createTrendingRepos`
//  - R-05：trending_repos 加 10 详情页字段             → 合并进 `createTrendingRepos`
//          （watchers/topics/license/homepage/created/updated/pushed/archived/fork/private）
//

import Foundation
import GRDB

/// 数据库迁移定义。
///
/// 暴露一个 `registerAll(into:)` 方法将所有版本注册到 GRDB DatabaseMigrator，
/// 由 DatabaseManager 在启动时调用。
enum DatabaseMigrations {

    /// 将所有版本的迁移注册到 migrator。
    ///
    /// 当前只有一个 `v1-initial`（详见文件头部注释「设计原则 2」：产品上线前
    /// schema 演进直接改 v1，无需追加迁移）。产品上线后再追加 `registerV2(into:)` 等。
    static func registerAll(into migrator: inout DatabaseMigrator) {
        registerV1(into: &migrator)
    }

    // MARK: - v1-initial：最终 schema 一次性建出

    private static func registerV1(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1-initial") { db in
            // 顺序约束：被外键引用的表必须先于引用它的表创建
            try createRepos(db)
            try createStarredRepos(db)
            try createTags(db)
            try createRepoTags(db)
            try createRepoNotes(db)
            try createReadmes(db)
            try createSavedSearches(db)
            try createSearchHistory(db)
            try createSyncState(db)
            try createTagStatsCache(db)
            try createReposFTS(db)
            // 独立缓存表（与上面用户数据 / repos 缓存共享 repos 外键 cascade）
            try createTrendingRepos(db)
            try createTrendingReadmes(db)
            try createRepoEmbeddings(db)
            try createAISummaries(db)
            try createReleaseSubscriptions(db)
            try createReleases(db)
            try createReadmeTranslations(db)
        }
    }

    // MARK: - repos（核心仓库元数据 + FTS5）

    /// repos 表：核心仓库元数据。
    ///
    /// **字段分组**（共 28 列）：
    /// - **标识**：id (GitHub Repo ID, Int64 PK) / owner / name / full_name (unique)
    /// - **元数据**：description / language / stars/forks/watchers_count / topics (JSON 字符串)
    /// - **URL**：license / homepage / html_url / clone_url / ssh_url
    /// - **标志**：is_private / is_fork / is_archived / is_starred (SQLite 0/1 Bool)
    /// - **时间戳**：pushed_at / created_at / updated_at / starred_at（全部 ISO8601 TEXT）
    /// - **缓存**：cached_at
    /// - **StarcatRepoCardDTO v1.2 字段**：owner_avatar / subscribers_count / default_branch /
    ///   open_issues_count（来自 R-01 v1.2 三场景共用架构 §6.1，hero 区直接渲染免去 user API）
    ///
    /// **关键设计决策**：
    ///
    /// - **`topics` 存 JSON 数组字符串而非关联表**：topics 数量稳定 ≤ 20、只在卡片显示用，
    ///   关联表会引入 N+1 + cascade，性价比低；GRDB 端 `Repo.topics: String?` 直接 JSON 编解码。
    ///
    /// - **`owner_avatar / subscribers_count / default_branch / open_issues_count` 不分子表**：
    ///   这 4 字段与 GitHub Repo metadata 原生语义对齐，与 stars/forks/topics 是同一抽象层级；
    ///   分子表会让所有 SELECT 变 JOIN，得不偿失。全部 nullable：`StarcatRepoCardDTO`
    ///   不强保证返这些字段（GitHub API 偶发漏返），客户端 Repo 模型用 Optional 容错。
    ///
    /// - **`is_starred` 默认 true**：本地 repos 表只存「当前 / 曾经 star 过」的仓库；
    ///   `(is_starred, ...)` 复合索引用 false 标记软删除（取消 star 但保留 tags / notes 引用）。
    ///
    /// - **复合索引 `(is_starred, starred_at)` + `(is_starred, language, starred_at)`**：
    ///   HOM-46 性能优化（1810 行实测 400~700ms → ms 级），覆盖 sidebar 列表查询的两条最热路径：
    ///     - `WHERE is_starred=1 ORDER BY starred_at DESC`
    ///     - `WHERE is_starred=1 AND language=? ORDER BY starred_at DESC`
    ///   SQLite 反向扫描索引能力使 `ORDER BY starred_at DESC` 无需在索引定义里写 DESC。
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
            t.column("topics", .text)                                // JSON 数组字符串

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

            // StarcatRepoCardDTO v1.2 hero 区扩展字段（R-01 三场景共用架构）
            t.column("owner_avatar", .text)
            t.column("subscribers_count", .integer)
            t.column("default_branch", .text)
            t.column("open_issues_count", .integer)
        }

        // 基础单列索引
        try db.create(index: "idx_repos_language", on: "repos", columns: ["language"])
        try db.create(index: "idx_repos_stars", on: "repos", columns: ["stars_count"])
        try db.create(index: "idx_repos_starred_at", on: "repos", columns: ["starred_at"])
        try db.create(index: "idx_repos_owner_language", on: "repos", columns: ["owner", "language"])

        // HOM-46 性能优化复合索引（详见 createRepos doc 关键设计决策第 4 项）
        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_repos_is_starred_starred_at
            ON repos(is_starred, starred_at)
            """)
        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_repos_is_starred_language_starred_at
            ON repos(is_starred, language, starred_at)
            """)
    }

    /// FTS5 全文搜索：与 repos 表通过外部内容模式零冗余同步。
    ///
    /// **设计要点**：
    /// - `content='repos'` + `content_rowid='id'`：FTS 不存原始内容，直接引用 repos 表
    ///   的同名列，节省 1810 行 × 4 字段（name/description/language/topics）约 100KB+ 存储。
    /// - `tokenize = 'unicode61 remove_diacritics 2'`：CJK 友好（按字切分），去重音符
    ///   （café → cafe）；**不用 porter**（porter 是英文词干算法 running→run，对中文反而切碎语义）。
    /// - 3 个触发器 (AFTER INSERT / DELETE / UPDATE) 保持 FTS 索引与 repos 表同步。
    /// - 长期方向：若中文搜索体验不够，可后续替换为 `simple` + jieba 分词或集成 sqlite-vec。
    private static func createReposFTS(_ db: Database) throws {
        // 使用裸 SQL 因为 GRDB 的 create(virtualTable:) DSL 对「外部内容 + tokenize 选项」组合表达不够直观。
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

    // MARK: - starred_repos / tags / repo_tags / repo_notes / readmes / saved_searches / search_history / tag_stats_cache

    /// starred_repos：用户的 star 关系表（独立于 repos 缓存维度）。
    /// repos cascade 删除时关联清理；sync_status 跟踪与 GitHub 的双向 star 同步态。
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

    /// tags：用户标签（含预设分类）。
    /// - `is_preset`：1 = 系统预设（Languages / Tools / Frameworks 等），不可删；0 = 用户自定义。
    /// - `parent_id`：自引用外键，支持二级嵌套（如 "Web" → "React" / "Vue"）。
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

    /// repo_tags：repo ↔ tag 多对多关联。任意一端删除联级清理。
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

    /// repo_notes：用户对 repo 的私有笔记 + 阅读状态。
    /// `status` enum: `unread` / `reading` / `using` / `deprecated`；UI 侧排序 / 筛选用。
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

    /// readmes：GitHub 原 README 缓存（与翻译表 readme_translations 完全独立，ETag 流程独占）。
    /// `etag` / `last_modified` 支持 ReadmeAPI 的 304 短路；`size` 用于后续缓存清理排序。
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

    /// saved_searches：用户保存的搜索条件。`query` 存搜索过滤参数的 JSON 序列化。
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

    /// search_history：搜索浮层 `⌘K` 的关键词历史。
    ///
    /// 与 `saved_searches`（用户主动保存的命名查询条件）的区别：
    /// - search_history 是**自动记录**的最近输入；saved_searches 是用户**主动收藏**。
    /// - search_history 只存关键词字符串 + 计数 + 时间戳；saved_searches 存复杂 query JSON。
    ///
    /// CloudKit-ready 字段（W5 同步主线接入时使用）：
    /// - `id` UUID 字符串 → CloudKit recordName
    /// - `modified_at` ISO8601 → CloudKit LWW 时间戳
    /// - 详细 schema 与冲突合并策略见 `docs/CloudKit数据同步设计.md` §2.x
    ///
    /// 排序：UI 内存里按 `useCount × 0.5^(daysSinceLastUsed / 14)` 半衰期衰减；
    /// SQLite 不内置 pow()，全表只 50 条上限内存计算成本可忽略。
    /// 数据库索引按 `last_used_at` 倒序建立，便于"取最近 N 条"的快速预筛。
    private static func createSearchHistory(_ db: Database) throws {
        try db.create(table: "search_history") { t in
            t.column("id", .text).primaryKey()
            t.column("query", .text).notNull()
            t.column("query_lower", .text).notNull().unique()
            t.column("use_count", .integer).notNull().defaults(to: 1)
            t.column("last_used_at", .text).notNull()
            t.column("first_seen_at", .text).notNull()
            t.column("modified_at", .text).notNull()
        }
        try db.create(
            index: "idx_search_history_last_used_at",
            on: "search_history",
            columns: ["last_used_at"]
        )
    }

    /// sync_state：单用户全量 / 增量同步状态机。
    ///
    /// **关键字段**：
    /// - `last_sync_at`：上次全量同步完成时间（FULL_RESYNC 触发点）
    /// - `last_incremental_at`：上次增量同步完成时间
    /// - `sync_status`：`idle` / `syncing` / `failed`
    /// - `stars_etag`：W4-4 C2 用于 `/user/starred?page=1` 的 ETag 304 短路；
    ///   下次同步先 conditional GET，未变（304）则跳过整轮 starred 列表拉取，省 1810×30=~50KB 网络流量
    ///   并避免触发 GitHub rate limit。NULL = 首次同步语义。
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
            t.column("stars_etag", .text)        // /user/starred?page=1 ETag, W4-4 C2
        }
    }

    /// tag_stats_cache：tag 关联 repo 计数缓存（避免每次 sidebar 渲染都跑 COUNT(*)）。
    private static func createTagStatsCache(_ db: Database) throws {
        try db.create(table: "tag_stats_cache") { t in
            t.column("tag_id", .text).primaryKey()
                .references("tags", column: "id", onDelete: .cascade)
            t.column("repo_count", .integer).notNull()
            t.column("cached_at", .text).notNull()
        }
    }

    // MARK: - trending_repos / trending_readmes（Trending 缓存，与 repos / readmes 完全隔离）

    /// trending_repos：GitHub Trending 榜单本地缓存。
    ///
    /// **背景与设计决策**（dong4j 2026-06-02 选型 scope_b + schema_a + readme_pk_c + ttl_c）：
    /// - **scope_b**：列表 + README 两块都做持久化（不是只缓存列表）。
    /// - **schema_a**：独立表与 repos / readmes 完全隔离——trending 没有真实 GitHub repo id
    ///   （HTML scrape 出来的），强制复用 `repos.id` PK 会触发"何时从外部 API 补 id"的链式问题；
    ///   与 manage 路径解耦最干净。注意 `gh_repo_id` 字段是 R-01 v1.2 跨场景 ✓ 标记需要的辅助列，
    ///   不是 PK（PK 仍是榜单维度三元组）。
    /// - **readme_pk_c**：`trending_readmes` 用 `full_name` 作 PK（trending 只有 `owner/repo`，
    ///   没 Int64 id；与 `readmes.repo_id` 保持隔离）。
    /// - **ttl_c**：列表与 README 都不设 TTL，每次进 Trending 都强制走网络重拉，本地缓存只承担
    ///   「离线兜底 + 快速首屏 SWR」角色（先把缓存立即上屏，再后台拉网络覆盖）。
    ///
    /// **PK 设计**：复合 PK `(period, language_filter, rank)` —— 同一榜单（period+language_filter）
    /// 内按 rank 排序定位每行；同一 repo 出现在多个榜单（如 daily Swift 第 3 + weekly Swift 第 5）
    /// 各算一行互不覆盖。`language_filter` 用空串 `""` 表示「全部语言」（与
    /// `TrendingLanguage.all.apiValue == ""` 对齐）。
    ///
    /// **字段分组**：
    /// - 榜单维度：period / language_filter / rank（PK）
    /// - repo 标识：gh_repo_id (R-01 v1.2 跨场景 ✓ 标记) / full_name / owner / name
    /// - 基础元数据：description / language / stars/forks_count / watchers_count / topics (JSON)
    /// - URL / 许可：license / homepage
    /// - 状态标志：is_archived / is_fork / is_private (SQLite 0/1)
    /// - StarcatRepoCardDTO v1.2 字段：owner_avatar / subscribers_count / default_branch / open_issues_count
    /// - trending 特有：stars_in_period / contributors_json (JSON)
    /// - 时间戳：pushed_at / created_at / updated_at（GitHub 时间戳，ISO8601）/ cached_at（本地）
    ///
    /// **字段命名与 `repos` 表对齐**：topics / is_archived / pushed_at / homepage 等均用相同列名，
    /// 便于 toDomain / makeEphemeralRepo 等转换函数代码风格统一 + 复用 SELECT 思路。
    /// trending-api enricher 偶发字段缺失时退化为 NULL，下游 graceful 处理
    /// （Bool? → false / Int? → 0）。
    private static func createTrendingRepos(_ db: Database) throws {
        try db.create(table: "trending_repos") { t in
            // 榜单维度（PK）
            t.column("period", .text).notNull()                  // daily / weekly / monthly
            t.column("language_filter", .text).notNull()         // "" 表示全部语言
            t.column("rank", .integer).notNull()                 // 0-based

            // repo 标识
            t.column("gh_repo_id", .integer)                      // R-01 v1.2 跨场景 ✓ 标记用
            t.column("full_name", .text).notNull()
            t.column("owner", .text).notNull()
            t.column("name", .text).notNull()

            // 基础元数据
            t.column("description", .text)
            t.column("language", .text)
            t.column("stars_count", .integer).notNull().defaults(to: 0)
            t.column("forks_count", .integer).notNull().defaults(to: 0)
            t.column("watchers_count", .integer)
            t.column("topics", .text)                            // JSON 数组字符串（如 `["ai","swift"]`）

            // URL / 许可
            t.column("license", .text)
            t.column("homepage", .text)

            // 状态标志（SQLite 0/1 Bool）
            t.column("is_archived", .integer)
            t.column("is_fork", .integer)
            t.column("is_private", .integer)

            // StarcatRepoCardDTO v1.2 hero 区扩展字段
            t.column("owner_avatar", .text)
            t.column("subscribers_count", .integer)
            t.column("default_branch", .text)
            t.column("open_issues_count", .integer)

            // trending 特有
            t.column("stars_in_period", .integer).notNull().defaults(to: 0)
            t.column("contributors_json", .text)                 // JSON [{username, avatarURL, profileURL}]

            // 时间戳
            t.column("pushed_at", .text)
            t.column("created_at", .text)
            t.column("updated_at", .text)
            t.column("cached_at", .text).notNull()               // 本地缓存于 X 时间前，不参与 TTL

            t.primaryKey(["period", "language_filter", "rank"])
        }

        // full_name 反查索引（将来若做"该 repo 在哪些榜单出现过"反查复用）
        try db.create(index: "idx_trending_repos_full_name", on: "trending_repos", columns: ["full_name"])
    }

    /// trending_readmes：trending repo 的 README 缓存（PK 用 `full_name` 而非 repo_id）。
    /// 字段语义与 `readmes` 完全对齐，让 ReadmeAPI 复用同一套 SWR + ETag 304 + 大小统计逻辑。
    /// 不挂 FTS5 触发器：trending 是榜单切换型，不需要全文搜索。
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

    // MARK: - repo_embeddings / ai_summaries（AI 语义搜索 + 单仓智能化）

    /// repo_embeddings：repo 语义向量缓存（详见 `docs/详细设计/26-向量搜索改进.md`）。
    ///
    /// - SQLite BLOB 保存 Float32 向量，**不依赖 sqlite-vss / sqlite-vec 动态扩展**——
    ///   macOS 沙盒分发动态 SQLite extension 引入签名 / 加载路径 / App Review 风险；
    ///   Starcat MVP 规模在几千条 starred repo 内，Swift 内存 cosine 排名足够稳定。
    /// - PK `(repo_id, model)`：让后续换 embedding model 时不会误用旧向量。
    ///
    /// **2026-06-12 v2 schema 大改（产品上线前直接改 v1，不写 ALTER）**：
    ///   - **删除 `content_hash` 与 `indexed_text` 两列**——
    ///     原 hash 方案对 stars / forks 等高频变化字段敏感，每次同步就误触发全量重建；
    ///     `indexed_text` 也可从 `snapshot_json` 实时 render，无需独占一列。
    ///   - **新增 `snapshot_json` 列**：结构化快照 `IndexedSnapshot`（body / notes / metadata）
    ///     的 JSON 编码。判定 repo 是否需要重建走 `IndexedTextDiff.shouldRebuild`（行级
    ///     diff + 三档阈值），不再走 hash 全等比对。
    ///   - **删除 `idx_repo_embeddings_model_hash` 索引**：原索引基于 `content_hash`
    ///     做"命中查询"，新方案按 `(repo_id, model)` 主键直接命中，不再需要该索引。
    ///
    /// 涉及调用方：`SemanticSearchService.ensureIndexed` 走 `IndexedTextDiff` 而非
    /// `current.contentHash != record.contentHash`；`RepoEmbeddingRepository.upsert`
    /// 写入 snapshot_json 替代旧两列。
    private static func createRepoEmbeddings(_ db: Database) throws {
        try db.create(table: "repo_embeddings") { t in
            t.column("repo_id", .integer).notNull()
                .references("repos", column: "id", onDelete: .cascade)
            t.column("model", .text).notNull()
            t.column("dimensions", .integer).notNull()
            t.column("embedding", .blob).notNull()
            t.column("snapshot_json", .text).notNull()   // IndexedSnapshot JSON
            t.column("updated_at", .text).notNull()

            t.primaryKey(["repo_id", "model"])
        }
    }

    /// ai_summaries：单仓 AI 智能化结果（只缓存 JSON，不自动写标签——标签必须用户显式确认）。
    /// `source_hash` + `model` 用于判断 README / repo 元数据变更后是否需要重新生成。
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

    // MARK: - release_subscriptions / releases（HOM-47 Release 订阅追踪）

    /// release_subscriptions：用户对某仓库的 Release 订阅设置。
    ///
    /// - 主键 `repo_id`：一个 repo 至多一条订阅记录
    /// - `is_subscribed`：用户当前是否订阅
    /// - `notify_enabled`：是否在新 Release 出现时弹系统通知（与 `is_subscribed` 解耦，
    ///   未来可支持"订阅但静默"——MVP 默认 true）
    /// - `last_known_release_id` / `last_known_tag_name`：上次轮询见过的最新 Release 游标，
    ///   用于在下次轮询时判断"出现了哪些新 Release 需要通知"
    /// - `created_at` / `modified_at`：CloudKit 同步时按 Last-Write-Wins 比较 modifiedAt
    private static func createReleaseSubscriptions(_ db: Database) throws {
        try db.create(table: "release_subscriptions") { t in
            t.column("repo_id", .integer).primaryKey()
                .references("repos", column: "id", onDelete: .cascade)
            t.column("is_subscribed", .boolean).notNull().defaults(to: true)
            t.column("notify_enabled", .boolean).notNull().defaults(to: true)
            t.column("last_known_release_id", .integer)
            t.column("last_known_tag_name", .text)
            t.column("last_polled_at", .text)
            t.column("created_at", .text).notNull()
            t.column("modified_at", .text).notNull()
        }

        // 时间线视图查询路径："所有 is_subscribed = 1 的订阅"
        try db.create(index: "idx_release_subscriptions_active", on: "release_subscriptions", columns: ["is_subscribed"])
    }

    /// releases：拉到的 Release 元数据缓存。
    ///
    /// - 主键 `id`：GitHub Release 的全局 id，跨 repo 唯一
    /// - `repo_id` 外键 → repos.id ON DELETE CASCADE：repo 取消 star 时联级清理
    /// - `assets_json`：把资产数组直接存 JSON 字符串。理由——assets 数量稳定 ≤ 10 条，
    ///   只在时间线展示时需要，没有"按平台筛选所有 release 资产"的查询场景；
    ///   开一张 release_assets 关联表会引入 N+1 与 cascade，性价比低
    /// - `is_read`：用户已读状态，UI 端默认未读
    /// - `body_markdown`：GitHub 返回的完整 Release notes Markdown；列表摘要由 UI 层截断，
    ///   数据库必须保留原文，供发行版聚合详情页完整渲染
    private static func createReleases(_ db: Database) throws {
        try db.create(table: "releases") { t in
            t.column("id", .integer).primaryKey()
            t.column("repo_id", .integer).notNull()
                .references("repos", column: "id", onDelete: .cascade)
            t.column("tag_name", .text).notNull()
            t.column("name", .text)
            t.column("body_markdown", .text)
            t.column("html_url", .text).notNull()
            t.column("is_prerelease", .boolean).notNull().defaults(to: false)
            t.column("is_draft", .boolean).notNull().defaults(to: false)
            t.column("published_at", .text)
            t.column("created_at_remote", .text)
            t.column("assets_json", .text)
            t.column("is_read", .boolean).notNull().defaults(to: false)
            t.column("fetched_at", .text).notNull()
        }

        // 时间线主查询：按 published_at desc 排序所有订阅 repo 的 releases
        try db.create(index: "idx_releases_repo_published", on: "releases", columns: ["repo_id", "published_at"])
        try db.create(index: "idx_releases_published", on: "releases", columns: ["published_at"])
    }

    // MARK: - readme_translations（HOM-68 README AI 翻译缓存）

    /// readme_translations：README AI 翻译结果缓存。
    ///
    /// **背景**：HOM-68 在 README 详情区新增"翻译 README"入口，调用 AI 把原 HTML 翻译成
    /// 目标语言（默认简体中文）。翻译消耗 AI 配额、耗时显著，必须落地缓存避免用户每次切回详情页
    /// 都重复消耗——这是验收标准之一。
    ///
    /// **设计要点**：
    /// - **PK `(repo_id, target_language)`**：同一仓库每种目标语言保留最新一份翻译，
    ///   覆盖式 upsert。第一版不保留历史版本（用户可手动重新翻译触发覆盖）。
    /// - **`source_hash`**：对参与翻译的 README HTML 做 SHA256 指纹；README 被作者更新
    ///   （远端 ETag 改变 → 本地 readmes 表 upsert 新内容）后旧翻译 source_hash 不再匹配，
    ///   调用方按需重新生成而不是误用旧译文。
    /// - **`model`**：记录当时使用的 LLM 模型名，便于排查"为什么这份翻译质量不如另一份"，
    ///   第二版若做多模型对比也能复用。
    /// - **`translated_html`**：保存模型回填后的 HTML 片段，与 `readmes.rendered_html` 结构对齐，
    ///   UI 端可直接喂给 `ReadmeWebView` 渲染，无需重新组装。
    /// - **`size` 字段**：与 readmes 对齐，便于后续缓存清理按字节排序。
    /// - **外键 ON DELETE CASCADE**：取消 star → 本地 repo 行被删 → 联级清理翻译，
    ///   避免孤立缓存膨胀。
    ///
    /// **为什么独立表而不是把翻译塞进 `readmes` 表**：
    /// - `readmes` 是「GitHub 原 README 缓存」，由 ReadmeAPI 的 ETag 流程独占管理；
    ///   塞翻译会让 ETag 304 命中时既要 touchCachedAt 又要保留 translation 字段，
    ///   写入逻辑容易踩进「翻译被原 README 304 路径误清」之类的坑。
    /// - 一个 repo 可能存多个目标语言（中/英/日同时缓存），独立表用复合 PK 更直观。
    /// - 翻译表 schema 完全独立于 ETag/Last-Modified 流程，未来要加分块翻译进度
    ///   或质量评分字段时不影响 readmes。
    private static func createReadmeTranslations(_ db: Database) throws {
        try db.create(table: "readme_translations") { t in
            t.column("repo_id", .integer).notNull()
                .references("repos", column: "id", onDelete: .cascade)
            // 目标语言用 BCP-47 风格的 raw（如 `zh-Hans` / `en` / `ja`）
            t.column("target_language", .text).notNull()
            t.column("model", .text).notNull()
            t.column("source_hash", .text).notNull()
            t.column("translated_html", .text).notNull()
            t.column("size", .integer).notNull().defaults(to: 0)
            t.column("created_at", .text).notNull()

            t.primaryKey(["repo_id", "target_language"])
        }

        try db.create(index: "idx_readme_translations_repo", on: "readme_translations", columns: ["repo_id"])
    }
}
