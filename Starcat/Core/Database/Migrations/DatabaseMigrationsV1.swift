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
//  5. 不支持降级（见 `docs/1-立项/开发前问题清单.md` §5.2）。
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
//  - 原 v7：readme_translations 一张表（HOM-68）       → **已删除（2026-06-15）**：
//          翻译缓存改走纯磁盘 `DiskReadmeTranslationCache`（路径
//          `~/Library/Application Support/com.starcat.app/translations-cache/<owner>/<repo>/<lang>.{html,json}`）。
//          原因：trending/activity 未 star 撞 FK + CASCADE 删 vs "翻译资产不应跟随
//          star 削减"的产品语义冲突；CloudKit / FTS / JSON 导入导出全 0 引用，砍掉
//          无任何业务损失。详见 `ReadmeTranslationRepositoryProtocol` 顶部注释。
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
            try createGitHubStarLists(db)
            try createRepoGitHubStarLists(db)
            try createRepoNotes(db)
            try createReadmes(db)
            try createReadmeContents(db)
            try createReadmePrefetchStates(db)
            try createSavedSearches(db)
            try createSmartCollections(db)
            try createSearchHistory(db)
            try createSyncState(db)
            try createTagStatsCache(db)
            try createReposFTS(db)
            try createNotesFTS(db)
            // 独立缓存表（与上面用户数据 / repos 缓存共享 repos 外键 cascade）
            try createTrendingRepos(db)
            try createTrendingReadmes(db)
            // 探索发现缓存：公开服务端快照，可删除重建，不与用户 star/tag/note 数据耦合。
            try createDiscoveryListPages(db)
            try createDiscoveryListItems(db)
            try createDiscoverySummaryModes(db)
            try createDiscoverySummaryFacets(db)
            try createDiscoveryBulkRepos(db)
            try createDiscoveryBulkCategoryMemberships(db)
            try createDiscoveryBulkMeta(db)
            try createRepoEmbeddings(db)
            try createAISummaries(db)
            try createReleaseSubscriptions(db)
            try createReleases(db)
            // R-06.4（2026-06-15）：Weekly 渐进式 SWR 双轨制专用 bulk 缓存表。
            try createWeeklyBulkRepos(db)
            try createWeeklyBulkLanguages(db)
            try createWeeklyBulkMeta(db)
            // OpenSSF Scorecard 公开安全评分缓存（仅 starred repo，失败态也落库冷却）。
            try createOpenSSFScores(db)
            // Repo Health 派生缓存：聚合 repos / releases / OpenSSF 的健康度快照。
            try createRepoHealthSnapshots(db)
            // Activity 公告与关注（2026-06-16）：following events / 双源 announcement / 单行 sync_state 三表。
            try createActivityEvents(db)
            try createActivityAnnouncements(db)
            try createActivitySyncState(db)
            // 原 createReadmeTranslations 已删除（2026-06-15 HOM-68 v2 砍 DB 改纯磁盘）。
            // 翻译缓存现走 `DiskReadmeTranslationCache`，详见文件头「原 v7」段说明。
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
    ///   的同名列,节省 1810 行 × 5 字段约 100KB+ 存储。
    /// - `tokenize = 'unicode61 remove_diacritics 2'`：CJK 友好（按字切分），去重音符
    ///   （café → cafe）；**不用 porter**（porter 是英文词干算法 running→run，对中文反而切碎语义）。
    /// - 3 个触发器 (AFTER INSERT / DELETE / UPDATE) 保持 FTS 索引与 repos 表同步。
    /// - 长期方向：若中文搜索体验不够，可后续替换为 `simple` + jieba 分词或集成 sqlite-vec。
    ///
    /// **2026-06-14 召回扩展**：加 `full_name` 列（如 `"google/guava"`）。
    /// unicode61 把 `/` 当切词符，`full_name` 自动拆出 `google` + `guava` 两个 token，
    /// 让"只搜 owner"或"完整 owner/repo"两种用户输入都能命中——之前 `name` 只是 repo 部分，
    /// 搜 `google` 必匹不上 `google/guava`。冗余 token（repo 名段同时进 `name` 和 `full_name`）
    /// 可忽略，倒排表自动按 docid 去重。
    private static func createReposFTS(_ db: Database) throws {
        try db.execute(sql: """
            CREATE VIRTUAL TABLE repos_fts USING fts5(
                name,
                full_name,
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
                INSERT INTO repos_fts(rowid, name, full_name, description, language, topics)
                VALUES (new.id, new.name, new.full_name, new.description, new.language, new.topics);
            END
            """)

        try db.execute(sql: """
            CREATE TRIGGER repos_ad AFTER DELETE ON repos BEGIN
                INSERT INTO repos_fts(repos_fts, rowid, name, full_name, description, language, topics)
                VALUES('delete', old.id, old.name, old.full_name, old.description, old.language, old.topics);
            END
            """)

        try db.execute(sql: """
            CREATE TRIGGER repos_au AFTER UPDATE ON repos BEGIN
                INSERT INTO repos_fts(repos_fts, rowid, name, full_name, description, language, topics)
                VALUES('delete', old.id, old.name, old.full_name, old.description, old.language, old.topics);
                INSERT INTO repos_fts(rowid, name, full_name, description, language, topics)
                VALUES (new.id, new.name, new.full_name, new.description, new.language, new.topics);
            END
            """)
    }

    /// 私有笔记 FTS5 全文搜索（2026-06-14 dong4j 召回扩展）。
    ///
    /// **设计动机**：用户在 `repo_notes.content` 写下的笔记是"私人记忆词"
    /// （如 "试过部署失败"、"pyenv 替代品"），命中率高、相关性高，是 Starcat
    /// 区别 GitHub 自带搜索的核心差异点。原 `repos_fts` 只索引 4 个 repo 字段，
    /// 笔记完全在搜索之外。
    ///
    /// **结构选择**（Q2 方案 Y）：独立 `notes_fts` 虚拟表 + 在 `searchFTS` 里 UNION
    /// `repos_fts`。优点：
    /// 1. 表语义清晰，互不干扰（笔记触发器只管 notes_fts，未来加 readme_fts 同款模板）
    /// 2. 外部内容模式 `content='repo_notes', content_rowid='repo_id'`：repo_notes
    ///    PK 已是 repo_id（INTEGER），直接当 rowid 桥接，不引入新关联表
    /// 3. UNION 后两侧 rowid 都是 `repos.id`，搜索结果合并去重 by repo_id 自然成立
    ///
    /// **tokenizer 选 `trigram` 而非 `unicode61`**（2026-06-14 dong4j 决策方案 A）：
    /// SQLite `unicode61` 对**连续 CJK 字符不切分**，整段中文笔记被当作单个 token，
    /// 用户搜中间词（如笔记 "试过部署失败" 搜 "部署失败"）必匹不上。`trigram`（SQLite
    /// 3.34+ 内置）按 3-字符滑动窗口建索引，CJK 中缀友好；同时英文也按子串匹配
    /// （`deploy` 命中 `deployment`）—— 笔记主要是长文本中文 + 较长英文短语，trigram
    /// 完美适配。**代价**：query 长度 < 3 字符时 trigram 无法命中（如笔记搜 "AI" /
    /// "Go" 没结果），但笔记场景里这种短词搜索极少。
    ///
    /// **`repos_fts` 不一并换 trigram**：`repos_fts.language` 列含 `Go` / `C` / `R`
    /// 等 ≤2 字符词，trigram 完全无法索引；`repos_fts.name` 也常出现短缩写（`AI` /
    /// `ML` / `JS`）—— 短词搜索是 repo 列的核心需求，unicode61 必须保留。
    ///
    /// **只索引 `content`**（Q1 决策）：status / edited_at / is_ai_generated 不进 FTS。
    /// status 词频太高（'unread'/'reading'/...）会反向稀释相关性；状态过滤已有 UI 入口。
    ///
    /// **UPDATE 触发器的 `WHEN` 守门**：repo_notes 同时承载笔记与阅读状态，每次
    /// `applyStatusChange` 都会 UPDATE 整行；如果触发器无条件重建索引，状态切换的
    /// 高频路径会产生大量空 IO。`WHEN OLD.content IS NOT NEW.content` 让 status 变化
    /// 时触发器空跑（SQLite `IS NOT` 正确处理 NULL，不同于 `!=`）。
    ///
    /// **不索引空笔记**：`content` 为 NULL 或空字符串时 INSERT/UPDATE 触发器仍会写入，
    /// 但 fts5 对空 token 序列自然不命中——无需额外 WHEN 过滤，留 fts5 自己处理简洁。
    private static func createNotesFTS(_ db: Database) throws {
        try db.execute(sql: """
            CREATE VIRTUAL TABLE notes_fts USING fts5(
                content,
                content='repo_notes',
                content_rowid='repo_id',
                tokenize = 'trigram'
            )
            """)

        try db.execute(sql: """
            CREATE TRIGGER repo_notes_ai AFTER INSERT ON repo_notes BEGIN
                INSERT INTO notes_fts(rowid, content)
                VALUES (new.repo_id, new.content);
            END
            """)

        try db.execute(sql: """
            CREATE TRIGGER repo_notes_ad AFTER DELETE ON repo_notes BEGIN
                INSERT INTO notes_fts(notes_fts, rowid, content)
                VALUES('delete', old.repo_id, old.content);
            END
            """)

        try db.execute(sql: """
            CREATE TRIGGER repo_notes_au AFTER UPDATE ON repo_notes
                WHEN OLD.content IS NOT NEW.content
                BEGIN
                INSERT INTO notes_fts(notes_fts, rowid, content)
                VALUES('delete', old.repo_id, old.content);
                INSERT INTO notes_fts(rowid, content)
                VALUES (new.repo_id, new.content);
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

    /// github_star_lists：GitHub Stars 页面中的 List 本地镜像。
    ///
    /// `color_hex` 是 Starcat 本地字段，GitHub API 不提供颜色；首次同步时按 list id
    /// 稳定 hash 生成，后续用户修改颜色后远端同步不得覆盖。
    private static func createGitHubStarLists(_ db: Database) throws {
        try db.create(table: "github_star_lists") { t in
            t.column("id", .text).primaryKey()
            t.column("name", .text).notNull()
            t.column("description", .text)
            t.column("is_private", .boolean).notNull().defaults(to: false)
            t.column("color_hex", .text).notNull()
            t.column("position", .integer).notNull().defaults(to: 0)
            t.column("created_at", .text)
            t.column("updated_at", .text)
            t.column("synced_at", .text).notNull()
        }

        try db.create(index: "idx_github_star_lists_position", on: "github_star_lists", columns: ["position", "name"])
    }

    /// repo_github_star_lists：repo ↔ GitHub Stars List 多对多关系。
    ///
    /// 不能在 repos 表放单个 group_id，因为 GitHub 允许一个 repo 同时属于多个 List。
    private static func createRepoGitHubStarLists(_ db: Database) throws {
        try db.create(table: "repo_github_star_lists") { t in
            t.column("repo_id", .integer).notNull()
                .references("repos", column: "id", onDelete: .cascade)
            t.column("list_id", .text).notNull()
                .references("github_star_lists", column: "id", onDelete: .cascade)

            t.primaryKey(["repo_id", "list_id"])
        }

        try db.create(index: "idx_repo_github_star_lists_list", on: "repo_github_star_lists", columns: ["list_id"])
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
    ///
    /// HOM-201 P2-1(2026-06-14):`rendered_html` 列由 TEXT 改为 BLOB,应用层用 zlib
    /// 透明压缩(5-8x 比),磁盘占用显著下降。语义不变(Model `renderedHtml` 仍是
    /// `String?`),由 `ReadmeHTMLCodec` 在 `Readme.init(row:)` / `encode(to:)` 边界
    /// 处理编解码;`size` 仍是明文字节数(LRU 决策口径稳定)。
    ///
    /// HOM-201 P2-2(2026-06-14):原 `content` 列(raw Markdown)拆到独立表
    /// `readme_contents`(见 `createReadmeContents`),让 `find(repoId:)` 默认查询不
    /// 再带出几百 KB Markdown body;只有 AI / 向量索引等"纯文本消费方"显式调
    /// `findContent(repoId:)` 时才查 readme_contents 表。详见 `ReadmeRepository`。
    private static func createReadmes(_ db: Database) throws {
        try db.create(table: "readmes") { t in
            t.column("repo_id", .integer).primaryKey()
                .references("repos", column: "id", onDelete: .cascade)
            t.column("rendered_html", .blob)
            t.column("etag", .text)
            t.column("last_modified", .text)
            t.column("cached_at", .text).notNull()
            t.column("size", .integer).notNull().defaults(to: 0)
        }

        try db.create(index: "idx_readmes_cached", on: "readmes", columns: ["cached_at"])
    }

    /// readme_contents:raw Markdown 文本独立表(HOM-201 P2-2,2026-06-14)。
    ///
    /// 设计动机:`readmes.content` 此前是 raw markdown,但**只有 AI / 向量索引**少数
    /// 路径用,详情页 WebView 走 `rendered_html`。原 schema 让详情页每次 `find` 都
    /// 把几百 KB markdown 一起拉回内存,纯浪费 IO 与内存。拆表后:
    ///  - `readmes.find(repoId:)` 默认只回元数据 + 压缩 HTML;
    ///  - `readme_contents.findContent(repoId:)` 显式拉 markdown(AI / 向量索引专用)。
    ///
    /// 与 `readmes` 表的关系:PK 都是 `repo_id`,FK 指向 `repos.id` ON DELETE CASCADE;
    /// 但**没有 FK 指向 readmes**,因为 markdown backfill 早于或独立于 HTML 写入路径
    /// 时不应被强约束。调用方(`ReadmeAPI.refreshMarkdownIfNeeded`)负责保证"HTML 已
    /// 抓过 → 才写 markdown"的业务约束。
    ///
    /// `content` 同样用 `.blob` + zlib 透明压缩(`ReadmeHTMLCodec`,markdown 也是
    /// 结构化文本,压缩比 3-5x)。`size` 仍是明文字节数,与 `readmes.size` 口径对齐。
    private static func createReadmeContents(_ db: Database) throws {
        try db.create(table: "readme_contents") { t in
            t.column("repo_id", .integer).primaryKey()
                .references("repos", column: "id", onDelete: .cascade)
            t.column("content", .blob)
            t.column("cached_at", .text).notNull()
            t.column("size", .integer).notNull().defaults(to: 0)
        }
    }

    /// readme_prefetch_states:README 后台预拉调度状态。
    ///
    /// 这里只记录调度与失败冷却，不保存正文；正文仍分别落在 `readmes`(HTML) 和
    /// `readme_contents`(raw Markdown)。这样设置页清理 README 缓存时不需要理解新的正文来源，
    /// 后台任务也可以通过 `next_retry_at` 避免网络错误或 404 后反复打 GitHub。
    private static func createReadmePrefetchStates(_ db: Database) throws {
        try db.create(table: "readme_prefetch_states") { t in
            t.column("repo_id", .integer).primaryKey()
                .references("repos", column: "id", onDelete: .cascade)
            t.column("html_status", .text).notNull().defaults(to: "pending")
            t.column("markdown_status", .text).notNull().defaults(to: "pending")
            t.column("last_attempt_at", .text)
            t.column("next_retry_at", .text)
            t.column("failure_count", .integer).notNull().defaults(to: 0)
            t.column("last_error_kind", .text)
        }

        try db.create(index: "idx_readme_prefetch_retry", on: "readme_prefetch_states", columns: ["next_retry_at"])
        try db.create(index: "idx_readme_prefetch_html_status", on: "readme_prefetch_states", columns: ["html_status"])
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

    /// smart_collections：用户自定义智能集合。
    ///
    /// 只存规则定义，不存命中结果。命中列表仍由 HomeViewModel 每次按 rule 即时派生，
    /// 避免 repo/tag/status 改动后需要维护额外同步表。
    private static func createSmartCollections(_ db: Database) throws {
        try db.create(table: "smart_collections") { t in
            t.column("id", .text).primaryKey()
            t.column("name", .text).notNull()
            t.column("icon", .text).notNull().defaults(to: "line.3.horizontal.decrease.circle")
            t.column("color", .text)
            t.column("rule_json", .text).notNull()
            t.column("sort_order", .integer).notNull().defaults(to: 0)
            t.column("created_at", .text).notNull()
            t.column("updated_at", .text).notNull()
        }

        try db.create(index: "idx_smart_collections_sort", on: "smart_collections", columns: ["sort_order", "created_at"])
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
    /// - 详细 schema 与冲突合并策略见 `docs/2-产品/需求讨论/正式方案/CloudKit数据同步设计.md` §2.x
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
    ///
    /// HOM-201 P2-1(2026-06-14):`rendered_html` 列由 TEXT 改为 BLOB,与 `readmes` 同款
    /// zlib 透明压缩;详见 `createReadmes` 注释与 `ReadmeHTMLCodec` 文件头。
    private static func createTrendingReadmes(_ db: Database) throws {
        try db.create(table: "trending_readmes") { t in
            t.column("full_name", .text).primaryKey()
            t.column("rendered_html", .blob)
            t.column("etag", .text)
            t.column("last_modified", .text)
            t.column("cached_at", .text).notNull()
            t.column("size", .integer).notNull().defaults(to: 0)
        }

        try db.create(index: "idx_trending_readmes_cached", on: "trending_readmes", columns: ["cached_at"])
    }

    // MARK: - discovery_*（探索发现客户端本地缓存）

    /// discovery_list_pages：按 mode + filter + sort + page 缓存分页元信息。
    ///
    /// `cache_key` 不包含 page，方便同一查询下多个 page 共用一个分桶；page 单独入 PK。
    /// 列表项明细放在 `discovery_list_items`，两张表同 transaction 写入，避免 total 与 rows 不一致。
    private static func createDiscoveryListPages(_ db: Database) throws {
        try db.create(table: "discovery_list_pages") { t in
            t.column("cache_key", .text).notNull()
            t.column("page", .integer).notNull()
            t.column("total", .integer).notNull().defaults(to: 0)
            t.column("page_size", .integer).notNull().defaults(to: 20)
            t.column("next_page", .integer)
            t.column("cached_at", .text).notNull()
            t.primaryKey(["cache_key", "page"])
        }

        try db.create(index: "idx_discovery_list_pages_cached", on: "discovery_list_pages", columns: ["cached_at"])
    }

    /// discovery_list_items：Discovery API 返回的公开仓库快照。
    ///
    /// 该表只用于探索页离线兜底与快速首屏，不参与 Manage/Starred 主数据。用户点击 Star 后，
    /// 仍由 `StarActionService` 走 GitHub 真值写入 `repos`，避免公共榜单快照污染用户库。
    private static func createDiscoveryListItems(_ db: Database) throws {
        try db.create(table: "discovery_list_items") { t in
            t.column("cache_key", .text).notNull()
            t.column("page", .integer).notNull()
            t.column("sort_order", .integer).notNull()
            t.column("repo_id", .integer).notNull()
            t.column("full_name", .text).notNull()
            t.column("owner", .text).notNull()
            t.column("name", .text).notNull()
            t.column("description", .text)
            t.column("homepage", .text)
            t.column("language", .text)
            t.column("stars", .integer).notNull().defaults(to: 0)
            t.column("forks", .integer).notNull().defaults(to: 0)
            t.column("watchers", .integer).notNull().defaults(to: 0)
            t.column("subscribers", .integer).notNull().defaults(to: 0)
            t.column("open_issues", .integer).notNull().defaults(to: 0)
            t.column("owner_avatar", .text)
            t.column("default_branch", .text)
            t.column("license_spdx", .text)
            t.column("topics_json", .text).notNull().defaults(to: "[]")
            t.column("platforms_json", .text).notNull().defaults(to: "[]")
            t.column("pushed_at", .text)
            t.column("updated_at", .text)
            t.column("created_at", .text)
            t.column("is_archived", .integer).notNull().defaults(to: false)
            t.column("is_fork", .integer).notNull().defaults(to: false)
            t.column("latest_release_tag", .text)
            t.column("latest_release_at", .text)
            t.column("latest_release_url", .text)
            t.column("release_download_count", .integer).notNull().defaults(to: 0)
            t.column("item_rank", .integer)
            t.column("score", .double)
            t.column("reasons_json", .text).notNull().defaults(to: "[]")
            t.column("signals_json", .text).notNull().defaults(to: "[]")
            t.column("cached_at", .text).notNull()
            t.primaryKey(["cache_key", "page", "repo_id"])
        }

        try db.create(index: "idx_discovery_list_items_lookup", on: "discovery_list_items", columns: ["cache_key", "page", "sort_order"])
        try db.create(index: "idx_discovery_list_items_repo", on: "discovery_list_items", columns: ["repo_id"])
    }

    /// discovery_summary_modes：探索四个模式的 repo 总量缓存。
    private static func createDiscoverySummaryModes(_ db: Database) throws {
        try db.create(table: "discovery_summary_modes") { t in
            t.column("mode", .text).primaryKey()
            t.column("total", .integer).notNull().defaults(to: 0)
            t.column("generated_at", .text)
            t.column("cached_at", .text).notNull()
        }
    }

    /// discovery_summary_facets：探索 Sidebar 各维度筛选项的 repo 计数缓存。
    private static func createDiscoverySummaryFacets(_ db: Database) throws {
        try db.create(table: "discovery_summary_facets") { t in
            t.column("mode", .text).notNull()
            t.column("facet", .text).notNull()
            t.column("key", .text).notNull()
            t.column("label", .text).notNull()
            t.column("system_name", .text)
            t.column("count", .integer).notNull().defaults(to: 0)
            t.column("sort_order", .integer).notNull().defaults(to: 0)
            t.column("cached_at", .text).notNull()
            t.primaryKey(["mode", "facet", "key"])
        }

        try db.create(index: "idx_discovery_summary_facets_lookup", on: "discovery_summary_facets", columns: ["mode", "facet", "sort_order"])
    }

    /// discovery_bulk_repos：Discovery bulk endpoint 返回的全量公开仓库快照。
    ///
    /// 与 Weekly bulk 同款，客户端拿到完整 catalog 后，本地完成发现 / 热门 / 新发布的
    /// sort / filter / page，不再为每个排序组合维护一份远端分页缓存。
    private static func createDiscoveryBulkRepos(_ db: Database) throws {
        try db.create(table: "discovery_bulk_repos") { t in
            t.column("repo_id", .integer).primaryKey()
            t.column("full_name", .text).notNull()
            t.column("owner", .text).notNull()
            t.column("name", .text).notNull()
            t.column("description", .text)
            t.column("homepage", .text)
            t.column("language", .text)
            t.column("stars", .integer).notNull().defaults(to: 0)
            t.column("forks", .integer).notNull().defaults(to: 0)
            t.column("watchers", .integer).notNull().defaults(to: 0)
            t.column("subscribers", .integer).notNull().defaults(to: 0)
            t.column("open_issues", .integer).notNull().defaults(to: 0)
            t.column("owner_avatar", .text)
            t.column("default_branch", .text)
            t.column("license_spdx", .text)
            t.column("topics_json", .text).notNull().defaults(to: "[]")
            t.column("platforms_json", .text).notNull().defaults(to: "[]")
            t.column("pushed_at", .text)
            t.column("updated_at", .text)
            t.column("created_at", .text)
            t.column("is_archived", .integer).notNull().defaults(to: false)
            t.column("is_fork", .integer).notNull().defaults(to: false)
            t.column("latest_release_tag", .text)
            t.column("latest_release_at", .text)
            t.column("latest_release_url", .text)
            t.column("release_download_count", .integer).notNull().defaults(to: 0)
            t.column("item_rank", .integer)
            t.column("score", .double)
            t.column("trending_score", .double).notNull().defaults(to: 0)
            t.column("popularity_score", .double).notNull().defaults(to: 0)
            t.column("release_score", .double).notNull().defaults(to: 0)
            t.column("discovery_score", .double).notNull().defaults(to: 0)
            t.column("search_score", .double).notNull().defaults(to: 0)
            t.column("reasons_json", .text).notNull().defaults(to: "[]")
            t.column("signals_json", .text).notNull().defaults(to: "[]")
            t.column("cached_at", .text).notNull()
        }

        try db.create(index: "idx_discovery_bulk_language", on: "discovery_bulk_repos", columns: ["language"])
        try db.create(index: "idx_discovery_bulk_stars", on: "discovery_bulk_repos", columns: ["stars"])
        try db.create(index: "idx_discovery_bulk_updated", on: "discovery_bulk_repos", columns: ["updated_at"])
        try db.create(index: "idx_discovery_bulk_release", on: "discovery_bulk_repos", columns: ["latest_release_at"])
        try db.create(index: "idx_discovery_bulk_discovery_score", on: "discovery_bulk_repos", columns: ["discovery_score"])
        try db.create(index: "idx_discovery_bulk_popularity_score", on: "discovery_bulk_repos", columns: ["popularity_score"])
        try db.create(index: "idx_discovery_bulk_release_score", on: "discovery_bulk_repos", columns: ["release_score"])
    }

    /// discovery_bulk_category_memberships：bulk repo 与探索子模块的归属关系。
    ///
    /// 归属关系来自 discovery-api 的 `category_rankings`，单独成表是为了不把
    /// "热门 / 新发布 / 趋势" 这种榜单维度塞回仓库基础快照。
    private static func createDiscoveryBulkCategoryMemberships(_ db: Database) throws {
        try db.create(table: "discovery_bulk_category_memberships") { t in
            t.column("repo_id", .integer).notNull()
            t.column("category", .text).notNull()
            t.column("item_rank", .integer)
            t.column("cached_at", .text).notNull()
            t.primaryKey(["repo_id", "category"])
        }

        try db.create(index: "idx_discovery_bulk_category_lookup", on: "discovery_bulk_category_memberships", columns: ["category", "item_rank"])
    }

    /// discovery_bulk_meta：bulk cache 元信息单行表（PK = "singleton"）。
    private static func createDiscoveryBulkMeta(_ db: Database) throws {
        try db.create(table: "discovery_bulk_meta") { t in
            t.column("id", .text).primaryKey()
            t.column("etag", .text)
            t.column("last_fetched_at", .text).notNull()
            t.column("generated_at", .text)
            t.column("total", .integer).notNull().defaults(to: 0)
        }
    }

    // MARK: - weekly_bulk_*（R-06.4 客户端 bulk 缓存 / 渐进式 SWR 双轨制）

    /// `weekly_bulk_repos`：weekly bulk endpoint 一次性返回的 ~4000 条聚合 repo 全量落盘。
    ///
    /// 设计原则：
    /// - 这是 R-06.4 客户端缓存层的**核心表**：后端 `/api/v1/repos/bulk` 返回的全量数据一次写入，
    ///   后续 sort / language / page 全部在本地查询，**完全消除"切 picker 又拉一次网络"的浪费**。
    /// - 与 `trending_repos` 同设计思路："cache 表 + cached_at"，但 PK 用 `gh_repo_id` 单列
    ///   而非 (period, language_filter, rank) 复合——weekly 是全量聚合无榜单维度，
    ///   gh_repo_id 是 GitHub 端 stable identity 直接当 PK 最简。
    /// - 字段镜像后端 `model.RepoFeedItem`（card + 4 个 snapshot），与 `WeeklyFeedItem` 1:1 对齐。
    /// - `weekly_snapshot_json / zread_snapshot_json / discovery_snapshot_json` 三列 JSON 直存
    ///   而非分子表：snapshot 是 weekly 专属 wire payload（issueURL / weekLabel /
    ///   publishedAt 等），分表毫无业务价值还引入 N+1 + cascade；保留 JSON 字符串透传到
    ///   `WeeklyFeedItem.weekly/zread/discovery` 即可。
    /// - `source_types_json` 同理 JSON 数组字符串（如 `["weekly","zread"]`）。
    /// - 时间戳全部 ISO8601 TEXT，与项目其它缓存表（trending_repos / repos）对齐。
    /// - `cached_at` 不参与单行 TTL：TTL 是"整批 bulk fetch 的新鲜度"由 `weekly_bulk_meta` 一行统管。
    ///
    /// 关键约束:
    /// - 入库走"先 DELETE 整表 + 再批量 INSERT"全量替换语义（在 repository 内一个 transaction 内
    ///   完成）；不做增量 upsert，因为 bulk endpoint 本身就是"当前全量快照"语义。
    /// - 索引覆盖三条最热查询路径：language 筛选 / latest_event_at DESC 排序 / stars DESC 排序。
    ///   pushed_at DESC 排序不加索引（用户极少切到，全表扫 4000 行无压力）。
    private static func createWeeklyBulkRepos(_ db: Database) throws {
        try db.create(table: "weekly_bulk_repos") { t in
            t.column("gh_repo_id", .integer).primaryKey()
            t.column("full_name", .text).notNull()
            t.column("owner", .text).notNull()
            t.column("repo", .text).notNull()
            t.column("name", .text).notNull()

            // Card 基础字段（镜像 StarcatRepoCardDTO）
            t.column("owner_avatar", .text)
            t.column("description", .text)
            t.column("language", .text)
            t.column("stars", .integer).notNull().defaults(to: 0)
            t.column("forks", .integer).notNull().defaults(to: 0)
            t.column("watchers", .integer).notNull().defaults(to: 0)
            t.column("subscribers", .integer).notNull().defaults(to: 0)
            t.column("topics_json", .text)            // JSON 数组字符串
            t.column("homepage", .text)
            t.column("license_spdx", .text)
            t.column("is_archived", .integer).notNull().defaults(to: 0)
            t.column("is_fork", .integer).notNull().defaults(to: 0)
            t.column("is_private", .integer).notNull().defaults(to: 0)
            t.column("default_branch", .text)
            t.column("open_issues", .integer).notNull().defaults(to: 0)
            t.column("pushed_at", .text)
            t.column("updated_at", .text)
            t.column("created_at", .text)
            t.column("html_url", .text)

            // Feed 专属字段
            t.column("is_available", .integer).notNull().defaults(to: 1)
            t.column("source_types_json", .text)      // JSON 数组（["weekly","zread",...]）
            t.column("first_event_at", .text).notNull()
            t.column("latest_event_at", .text).notNull()
            t.column("weekly_snapshot_json", .text)   // JSON object 或 NULL
            t.column("zread_snapshot_json", .text)
            t.column("discovery_snapshot_json", .text)

            // 缓存维度（不参与 TTL，仅给"调试为何这条 repo 是旧的"留痕）
            t.column("cached_at", .text).notNull()
        }

        // 排序索引——latest_event_at DESC（默认排序）+ stars DESC（备选）
        try db.create(index: "idx_weekly_bulk_latest_event", on: "weekly_bulk_repos", columns: ["latest_event_at"])
        try db.create(index: "idx_weekly_bulk_stars", on: "weekly_bulk_repos", columns: ["stars"])
        // language 筛选索引
        try db.create(index: "idx_weekly_bulk_language", on: "weekly_bulk_repos", columns: ["language"])
    }

    /// `weekly_bulk_languages`：bulk endpoint 返回的语言聚合直存。
    ///
    /// 不从 `weekly_bulk_repos` GROUP BY 派生（虽然技术上等价）：
    /// - 后端聚合走的是 SQL CASE-WHEN 处理"未分类" + 排序逻辑，客户端复制一套
    ///   只会引入不一致风险；
    /// - 后端聚合输出本来就是一起返回的小 payload（~50 行），直接落盘极简单；
    /// - 让 `WeeklyLanguageStore` 可以直接读这个表（如果 bulk 缓存命中），
    ///   不需要再单独发 `/repos/languages` 请求。
    private static func createWeeklyBulkLanguages(_ db: Database) throws {
        try db.create(table: "weekly_bulk_languages") { t in
            t.column("key", .text).primaryKey()       // 语言 key（"Go" / "uncategorized" / 空串）
            t.column("label", .text).notNull()
            t.column("count", .integer).notNull().defaults(to: 0)
            t.column("sort_order", .integer).notNull() // 保留后端原始顺序
        }
    }

    /// `weekly_bulk_meta`：bulk cache 元信息单行表（PK = "singleton"）。
    ///
    /// 单行设计避免"meta 表只有 1 行还做唯一约束"的丑陋写法；PK 固定字符串就够了。
    /// 跨 App 重启读这一行即可知道"上次什么时候拉的 / 拉了多少条 / 后端 ETag 是啥"，
    /// ViewModel 据此判断 12h TTL。
    private static func createWeeklyBulkMeta(_ db: Database) throws {
        try db.create(table: "weekly_bulk_meta") { t in
            t.column("id", .text).primaryKey()                // 固定值 "singleton"
            t.column("etag", .text)                            // bulk endpoint ETag（W/"sha[:8]"）
            t.column("last_fetched_at", .text).notNull()       // ISO8601 客户端拉取完成时刻
            t.column("generated_at", .text)                    // 后端 envelope.meta.generated_at
            t.column("total", .integer).notNull().defaults(to: 0) // = len(repos)
        }
    }

    /// OpenSSF Scorecard 评分缓存。
    ///
    /// **产品语义**：只服务已 star repo。表通过 `repo_id -> repos.id ON DELETE CASCADE`
    /// 绑定本地仓库缓存，取消 star 后如果未来清理 repos 行，评分缓存自然随行消失。
    ///
    /// **`fetched_at` 语义**：最近一次尝试时间，而不是最近一次成功时间。success / 404 /
    /// networkError / parseError 都会写入，避免失败状态在详情页或后台任务里连续重试。
    ///
    /// **`checks_json` 原始 payload**：OpenSSF 响应当前约 7KB~50KB，直接存 BLOB
    /// 比拆 18 维明细表更简单。雷达图读取时再 decode；后续展示 scorecard version /
    /// documentation / details 不需要重新拉历史数据。
    private static func createOpenSSFScores(_ db: Database) throws {
        try db.create(table: "open_ssf_scores") { t in
            t.column("repo_id", .integer).primaryKey()
                .references("repos", column: "id", onDelete: .cascade)
            t.column("fetch_status", .text).notNull()
            t.column("aggregate_score", .double)
            t.column("checks_json", .blob)
            t.column("score_date", .text)
            t.column("fetched_at", .text).notNull()
            t.column("last_error", .text)
        }

        try db.create(index: "idx_open_ssf_scores_status_fetched", on: "open_ssf_scores", columns: ["fetch_status", "fetched_at"])
    }

    /// repo_health_snapshots：Repo Health 总分与解释 payload 缓存。
    ///
    /// 关键设计：
    /// - 这是派生缓存，不是用户数据；产品未上线阶段直接摊平进 v1-initial。
    /// - `payload_json` 存维度证据，避免 UI 只看到不可解释的总分。
    /// - `stale_after` 是后台调度的唯一 TTL 判定字段，后续调整评分策略时只需重算快照。
    private static func createRepoHealthSnapshots(_ db: Database) throws {
        try db.create(table: "repo_health_snapshots") { t in
            t.column("repo_id", .integer).primaryKey()
                .references("repos", column: "id", onDelete: .cascade)
            t.column("overall_score", .double).notNull()
            t.column("grade", .text).notNull()
            t.column("maintenance_score", .double).notNull()
            t.column("popularity_score", .double).notNull()
            t.column("quality_score", .double).notNull()
            t.column("security_score", .double).notNull()
            t.column("payload_json", .text).notNull()
            t.column("computed_at", .text).notNull()
            t.column("stale_after", .text).notNull()
            t.column("fetch_status", .text).notNull()
            t.column("last_error", .text)
        }

        try db.create(index: "idx_repo_health_stale_after", on: "repo_health_snapshots", columns: ["stale_after"])
        try db.create(index: "idx_repo_health_overall_score", on: "repo_health_snapshots", columns: ["overall_score"])
    }

    // MARK: - repo_embeddings / ai_summaries（AI 语义搜索 + 单仓智能化）

    /// repo_embeddings：repo 语义向量缓存（详见 `docs/3-设计/详细设计/26-向量搜索改进.md`）。
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

    // MARK: - activity_events / activity_announcements / activity_sync_state（Activity 公告与关注 PR-1，2026-06-16）

    /// activity_events：following 分类 GitHub Events feed 缓存。
    ///
    /// **数据源**：`GET /users/{username}/received_events/public`（一次拉当前用户「关注的所有人」
    /// 30 天内最多 300 条 public events 聚合 feed）。
    ///
    /// **设计决策（dong4j 2026-06-16 方案 v2 拍板，详见
    /// `docs/需求讨论/activity-公告与关注-数据接入方案.md`）**：
    ///
    /// - **`id` 用 TEXT PRIMARY KEY**：GitHub event id 在 API 里是数字字符串，但跨 actor
    ///   全局唯一即可当 PK；与 `releases.id (Int64)` 不同——后者是 Release-level 数字 id，
    ///   而 events 的 id 在 GitHub 内部本就是字符串型。
    ///
    /// - **`payload_json` 全量直存**：与 `releases.assets_json` 同款模式。每种 EventType
    ///   payload schema 完全不同（WatchEvent 只有 `action`，PullRequestEvent 嵌套整个
    ///   `pull_request` 对象），开关联表毫无价值；ViewModel 按 event_type 走 switch
    ///   反解码到具体子类型，不命中时 fallback 到事件名本身的文案。
    ///
    /// - **`is_read` device-local，不挂 CloudKit**（决策 M2）：Activity 是 ephemeral feed，
    ///   跨设备同步「上次看到哪条 feed」价值低；30 天 × 多设备会推高 zone 体积。
    ///
    /// - **`repo_id` + `repo_name` 都存**：repo_id 是 GitHub repo 数字 id（INTEGER），
    ///   repo_name 是 "owner/repo" 字符串（TEXT）。同时存避免 ViewModel 渲染时还要查
    ///   `repos` 表（events 里的 repo 大多不是用户 starred）；id 做反查索引，name 做显示。
    ///
    /// - **过滤 ReleaseEvent**（决策 Q1）：网络层从 GitHub 拉回来直接丢弃 ReleaseEvent
    ///   类型行，不写入此表。避免与已有 `release_subscriptions` + `releases` 表（HOM-47）
    ///   的「订阅 release」语义双显困惑。本表只承载剩 7 类 event：Watch / Fork / Create /
    ///   Push / Issues / PullRequest / Discussion。schema 不强制约束 event_type 取值
    ///   （SQLite 没 enum），由 Repository 写入层做过滤。
    ///
    /// **索引选择**：
    /// - `created_at`：主查询路径——按时间倒序展示 feed
    /// - `event_type`：分组渲染 / 按类型过滤
    /// - `repo_id`：未来「该 repo 的 following 活动」反查（详情页扩展）
    private static func createActivityEvents(_ db: Database) throws {
        try db.create(table: "activity_events") { t in
            t.column("id", .text).primaryKey()                  // GitHub event id（数字字符串）
            t.column("event_type", .text).notNull()             // "WatchEvent" / "ForkEvent" / ...
            t.column("actor_login", .text).notNull()
            t.column("actor_avatar_url", .text)
            t.column("repo_name", .text).notNull()              // "owner/repo"
            t.column("repo_id", .integer).notNull()             // GitHub repo 数字 id
            t.column("payload_json", .text).notNull()           // 完整 payload（同 releases.assets_json 模式）
            t.column("is_read", .boolean).notNull().defaults(to: false)
            t.column("created_at", .text).notNull()             // GitHub 事件时间 ISO8601
            t.column("fetched_at", .text).notNull()             // 本地抓取时间 ISO8601
        }
        try db.create(index: "idx_activity_events_created", on: "activity_events", columns: ["created_at"])
        try db.create(index: "idx_activity_events_type",    on: "activity_events", columns: ["event_type"])
        try db.create(index: "idx_activity_events_repo",    on: "activity_events", columns: ["repo_id"])
    }

    /// activity_announcements：announcement 分类双源公告聚合缓存。
    ///
    /// **数据源**：
    /// - GitHub Blog RSS（`github.blog/feed/`）：100% 覆盖率，所有用户都看到 GitHub 平台公告
    /// - GitHub Security Advisory（`GET /repos/{o}/{r}/security-advisories`）：~2-3% 覆盖率，
    ///   仅查「最近 30 天有 push」的 starred repo（约 50~200 个，避免 1810 repo 全打
    ///   导致 rate limit 爆掉）
    ///
    /// **删除的源**（dong4j 2026-06-16 决策 Q2）：GitHub Discussions GraphQL `search` 在
    /// starred repos 范围拉 Announcements 类别 discussion。删除原因：① 启用 Discussions
    /// 的 repo < 15%、再启用 Announcements 类别的 < 5%，命中率极低；② 1810 repo 拼
    /// query string 接近 GraphQL 50KB 上限，技术风险高。
    ///
    /// **设计决策**：
    ///
    /// - **`id` 加 source 前缀做命名空间隔离**（决策 P1）：`"blog:96773"` /
    ///   `"security:GHSA-xxxx-..."`。debug 时一眼看出来源，与 `ActivityItem.id`（如
    ///   `"star:42:..."` / `"release-repo:123"`）命名风格一致。本表 schema 仅约束
    ///   `id TEXT PRIMARY KEY`，前缀语义由 Repository 写入层 enforce。
    ///
    /// - **`body_markdown` 字段名沿用「markdown」语义**：实际 RSS 拉到的是 HTML
    ///   片段（`content:encoded`），UI 走 WKWebView 渲染（复用 `ReadmeWebView`）；
    ///   命名 markdown 是为了与 `releases.body_markdown` 风格统一（都是「正文 blob」语义），
    ///   不限定具体 markup 格式。
    ///
    /// - **`repo_name` nullable**：blog 来源没有 repo（GitHub 平台公告非个性化），
    ///   security 来源有（绑定具体 repo 的 GHSA）。
    ///
    /// - **`categories` JSON 数组字符串**：RSS 单条公告可有多 category（如
    ///   `["AI & ML", "Security"]`）；与 `repos.topics` 同款 JSON 直存策略。
    ///
    /// - **`is_read` device-local，不挂 CloudKit**（决策 M2）：同 activity_events 理由。
    ///
    /// **索引选择**：
    /// - `created_at`：主查询路径——按发布时间倒序
    /// - `source`：按来源过滤（blog 全展示 / security 仅显示与 starred repo 相关）
    private static func createActivityAnnouncements(_ db: Database) throws {
        try db.create(table: "activity_announcements") { t in
            t.column("id", .text).primaryKey()                  // "blog:..." / "security:GHSA-..."
            t.column("source", .text).notNull()                 // "blog" / "security"
            t.column("title", .text).notNull()
            t.column("body_markdown", .text)                    // 正文（实为 HTML，命名沿用 markdown 语义）
            t.column("author", .text)
            t.column("url", .text).notNull()
            t.column("repo_name", .text)                        // security 有，blog 无
            t.column("categories", .text)                       // JSON 数组字符串
            t.column("is_read", .boolean).notNull().defaults(to: false)
            t.column("created_at", .text).notNull()             // 发布时间 ISO8601
            t.column("fetched_at", .text).notNull()             // 本地抓取时间 ISO8601
        }
        try db.create(index: "idx_activity_announcements_created", on: "activity_announcements", columns: ["created_at"])
        try db.create(index: "idx_activity_announcements_source",  on: "activity_announcements", columns: ["source"])
    }

    /// activity_sync_state：Activity 数据接入的单行 meta 表（PK 固定 `"singleton"`）。
    ///
    /// **设计动机**：
    ///
    /// 1. **ETag 304 短路**（决策 P3）：GitHub Events / Blog RSS 都支持 `If-None-Match`
    ///    → 304 短路。把 etag 落库让跨 App 重启也能复用，省 rate limit + 网络带宽。
    ///    参考 `sync_state.stars_etag`（W4-4 C2 同款模式）。
    ///
    /// 2. **数据清理 ≥ 24h 判定**（决策 P6）：30 天数据清理不放主刷新路径（避免阻塞
    ///    UI loading），而是在 ViewModel `reload` 完成网络刷新后异步派发
    ///    `cleanupIfNeeded()`——读 `last_cleanup_at` 判断「距上次清理 > 24h」才跑。
    ///
    /// **单行设计**：与 `weekly_bulk_meta` 同款风格——PK 固定字符串 `"singleton"`
    /// 比「meta 表只有 1 行还做唯一约束」干净。本类型唯一字段都是「全局会话级元数据」，
    /// 不存在分行存储语义。
    ///
    /// **per-source ETag 字段**：Events / Blog RSS 各自一列，因为两源生命周期独立，
    /// 一源 ETag 失效不影响另一源命中率。Security Advisory 是 per-repo 端点（每个 repo
    /// 一次独立请求），ETag 落到每个请求自管不在这里集中存（如未来要做 per-repo etag
    /// 缓存，应该走独立的 `activity_security_etag(repo_id, etag, ...)` 表，不挤进这里）。
    private static func createActivitySyncState(_ db: Database) throws {
        try db.create(table: "activity_sync_state") { t in
            t.column("id", .text).primaryKey()                  // 固定值 "singleton"
            t.column("events_etag", .text)                      // /users/{u}/received_events ETag
            t.column("blog_rss_etag", .text)                    // github.blog/feed/ ETag
            t.column("last_events_fetched_at", .text)           // 上次成功拉 events 时间 ISO8601
            t.column("last_blog_fetched_at", .text)             // 上次成功拉 blog rss 时间 ISO8601
            t.column("last_security_fetched_at", .text)         // 上次成功拉 security advisory 时间 ISO8601
            t.column("last_cleanup_at", .text)                  // 上次跑 30 天清理时间 ISO8601
        }
    }

    // MARK: - readme_translations（已删除，2026-06-15 HOM-68 v2）
    //
    // 历史 `createReadmeTranslations` 整段已删除。翻译缓存改走纯磁盘
    // `DiskReadmeTranslationCache`（路径 `<appSupport>/com.starcat.app/translations-cache/`）。
    // 删除原因详见文件头「原 v7」段 + `ReadmeTranslationRepositoryProtocol` 顶部注释。
    //
    // 切换关键决策（写给后来人）：
    //   - 产品未上线 → 直接砍 v1 表，不留过渡迁移；
    //   - 工程 grep 全量确认除了 service / repository 自身没人消费这张表；
    //   - 产品语义"翻译资产不应跟随 star 削减"与 CASCADE 直接冲突，砍后语义清晰。
}
