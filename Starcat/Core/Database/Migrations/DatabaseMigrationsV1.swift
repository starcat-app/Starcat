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
//  - v7：readme_translations（HOM-68 README 翻译缓存）
//  - v8：repos / trending_repos 新增 4 列 owner_avatar / subscribers_count /
//        default_branch / open_issues_count（R-01 v1.2 StarcatRepoCardDTO 14 新字段消化）
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
        registerV6(into: &migrator)
        registerV7(into: &migrator)
        registerV8(into: &migrator)
        registerV9(into: &migrator)
    }

    // MARK: - v8（R-01 StarcatRepoCardDTO v1.2 新字段消化）

    /// v8：repos / trending_repos 表加 4 列消化 `StarcatRepoCardDTO` v1.2 新增字段。
    ///
    /// **背景**：R-01 三场景共用架构（`docs/详细设计/18-三场景共用架构.md` v1.2 §6.1）
    /// 引入统一后端 DTO `StarcatRepoCardDTO`，相对 v1 schema 多了 4 个核心字段：
    /// - `owner_avatar`（owner 头像 URL，UI hero 区直接渲染，免去额外 GitHub user API 调用）
    /// - `subscribers_count`（GitHub `subscribers_count`，发现型场景排序参考）
    /// - `default_branch`（默认分支，如 `main` / `master`，README 和文件浏览的入口）
    /// - `open_issues_count`（未关闭 issue 数，UI hero 区与 stars/forks 并列展示）
    ///
    /// 在 v8 之前，`Repo.toEphemeralRepo()` 把 DTO 转 in-memory `Repo` 时丢弃这 4 字段
    /// （Repo 没字段承载，落 DB 也落不进去），导致：
    /// - 详情页拿不到 owner 头像、必须走另一次 GitHub avatar URL 拼接
    /// - 不能展示 subscribers / open issues 数（虽然 hero 区已有 placeholder UI）
    /// - 默认分支信息丢失（影响后续接 README + commits/{branch}/{path} 路径展开）
    ///
    /// **决策**：
    /// - **加列而非新建表**：4 字段全部与 GitHub Repo metadata 原生语义对齐，与 `repos`
    ///   表已有的 stars/forks/topics 等是同一抽象层级；新建子表会让查询变 JOIN，得不偿失
    /// - **NULL 而非默认值**：所有 4 字段都标 nullable，老用户 `repos` 表的历史行迁过来
    ///   全部为 NULL；新拉的 repo（GitHub /repos API 或 StarcatRepoCardDTO）会写入实际值
    /// - **同步加到 `trending_repos`**：trending 缓存也来自 DTO，让 trending 离线模式
    ///   也能看到 owner 头像和默认分支等信息（不强制要求 owner_avatar 命中，但能命中就用）
    /// - 不加索引：这 4 字段都不参与 sidebar / 搜索路径的查询条件
    ///
    /// **风险**：
    /// - SQLite ALTER TABLE ADD COLUMN 是 O(1) 的（不 rewrite 表），对 1810 行
    ///   `repos` 表完全无感
    /// - GRDB Codable 行映射按字段名匹配；`Repo` struct 同步加 4 字段后历史 SELECT
    ///   能把新列读为 NULL → 模型 Optional 字段；写入路径用 `MutablePersistableRecord`
    ///   默认 upsert 全字段，新列从 model 取（写 NULL or 实际值）
    private static func registerV8(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v8-starcat-card-fields") { db in
            // repos 表：加 4 列
            try db.execute(sql: "ALTER TABLE repos ADD COLUMN owner_avatar TEXT")
            try db.execute(sql: "ALTER TABLE repos ADD COLUMN subscribers_count INTEGER")
            try db.execute(sql: "ALTER TABLE repos ADD COLUMN default_branch TEXT")
            try db.execute(sql: "ALTER TABLE repos ADD COLUMN open_issues_count INTEGER")

            // trending_repos 表：加同样 4 列
            try db.execute(sql: "ALTER TABLE trending_repos ADD COLUMN owner_avatar TEXT")
            try db.execute(sql: "ALTER TABLE trending_repos ADD COLUMN subscribers_count INTEGER")
            try db.execute(sql: "ALTER TABLE trending_repos ADD COLUMN default_branch TEXT")
            try db.execute(sql: "ALTER TABLE trending_repos ADD COLUMN open_issues_count INTEGER")
        }
    }

    // MARK: - v9（R-01 v1.2 trending_repos.gh_repo_id 跨场景标记 PK）

    /// v9：`trending_repos` 表加 `gh_repo_id` 列（R-01 v1.2 跨场景 ✓ 标记必备）。
    ///
    /// **背景**：R-01 §3.1.2 跨场景标记设计要求：trending row 通过
    /// `StarredRegistry.contains(ghRepoId:)` 判断当前用户是否已 star。
    /// `RepoCardViewData.id = Int64 (ghRepoId)` 是稳定主键（rename 不漂移）。
    ///
    /// **为什么 v8 没一并加**：v8 落地（2026-06-10 早些时）时仅消化 4 个最常用
    /// hero 字段（owner_avatar / subscribers_count / default_branch /
    /// open_issues_count）。`gh_repo_id` 当时被列入「v1.2 边界内但 trending UI
    /// 暂不需要」清单——因为 trending 列表 row 还在用旧的独立 row 视图，列表 diff
    /// 键用 fullName 不依赖 ghRepoId。R-01 v1.2 Phase B 切到 UnifiedRepoRow 后，
    /// 跨场景 ✓ 标记必须 ghRepoId，所以单独提一次 v9 解锁。
    ///
    /// **NULL 兼容**：`gh_repo_id INTEGER`（无 NOT NULL），v8 之前的行迁移到 v9 后
    /// 该列为 NULL；下次 `fetchTrending` 网络回来整批替换时被填实（trending v1.2
    /// envelope 永远返回 ghRepoId）。`TrendingRepoRecord.toDomain()` 把 NULL 当 0
    /// 处理，UI 看到 0 哨兵 = 过渡 row（registry 永远不命中 → ✓ 标记不出现，可接受）。
    private static func registerV9(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v9-trending-gh-repo-id") { db in
            try db.execute(sql: "ALTER TABLE trending_repos ADD COLUMN gh_repo_id INTEGER")
        }
    }

    // MARK: - v7（HOM-68 README 翻译缓存）

    /// v7：README AI 翻译结果缓存。
    ///
    /// **背景**：HOM-68 在 README 详情区新增"翻译 README"入口，调用 AI 把原 HTML
    /// 翻译成目标语言（默认简体中文）。翻译消耗 AI 配额、耗时显著，必须落地缓存
    /// 避免用户每次切回详情页都重复消耗——这是验收标准之一。
    ///
    /// **设计要点**：
    /// - **PK `(repo_id, target_language)`**：同一仓库每种目标语言保留最新一份
    ///   翻译，覆盖式 upsert。第一版不保留历史版本（用户可手动重新翻译触发覆盖）。
    /// - **`source_hash`**：对参与翻译的 README HTML 做 SHA256 指纹；README 被
    ///   作者更新（远端 ETag 改变 → 本地 readmes 表 upsert 新内容）后旧翻译
    ///   `source_hash` 不再匹配，调用方按需重新生成而不是误用旧译文。
    /// - **`model`**：记录当时使用的 LLM 模型名，便于排查"为什么这份翻译质量
    ///   不如另一份"，第二版若做多模型对比也能复用。
    /// - **`translated_html`**：保存模型回填后的 HTML 片段，与 `readmes.rendered_html`
    ///   结构对齐，UI 端可直接喂给 `ReadmeWebView` 渲染，无需重新组装。
    /// - **`size` 字段**：与 `readmes` 对齐，便于后续缓存清理按字节排序。
    /// - 外键 `repo_id → repos.id ON DELETE CASCADE`：取消 star → 本地 repo 行
    ///   被删 → 联级清理翻译，避免孤立缓存膨胀。
    ///
    /// **为什么独立表而不是把翻译塞进 `readmes` 表**：
    /// - `readmes` 是"GitHub 原 README 缓存"，由 ReadmeAPI 的 ETag 流程独占管理；
    ///   塞翻译会让 ETag 304 命中时既要 touchCachedAt 又要保留 translation 字段，
    ///   写入逻辑容易踩进"翻译被原 README 304 路径误清"之类的坑。
    /// - 一个 repo 可能存多个目标语言（中/英/日同时缓存），独立表用复合 PK 更直观。
    /// - 翻译表 schema 完全独立于 ETag/Last-Modified 流程，未来要加分块翻译进度
    ///   或质量评分字段时不影响 readmes。
    private static func registerV7(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v7-readme-translations") { db in
            try createReadmeTranslations(db)
        }
    }

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

    // MARK: - v6（HOM-47 Release 订阅追踪）

    /// v6：Release 订阅追踪需要的两张表。
    ///
    /// **release_subscriptions**：用户对某仓库的 Release 订阅设置。
    /// - 主键 `repo_id`：一个 repo 至多一条订阅记录
    /// - `is_subscribed`：用户当前是否订阅
    /// - `notify_enabled`：是否在新 Release 出现时弹系统通知（与 `is_subscribed` 解耦，
    ///   未来可支持"订阅但静默"——MVP 默认 true）
    /// - `last_known_release_id` / `last_known_tag_name`：上次轮询见过的最新 Release
    ///   游标。用于在下次轮询时判断"出现了哪些新 Release 需要通知"
    /// - `created_at` / `modified_at`：CloudKit 同步时按 Last-Write-Wins 比较 modifiedAt
    ///
    /// **releases**：拉到的 Release 元数据缓存。
    /// - 主键 `id`：GitHub Release 的全局 id，跨 repo 唯一
    /// - `repo_id` 外键 → repos.id ON DELETE CASCADE：repo 取消 star 时联级清理
    /// - `assets_json`：把资产数组直接存 JSON 字符串。理由——assets 数量稳定 ≤ 10 条，
    ///   只在时间线展示时需要，没有"按平台筛选所有 release 资产"的查询场景；
    ///   开一张 release_assets 关联表会引入 N+1 与 cascade，性价比低
    /// - `is_read`：用户已读状态。与 `repo_notes.status` 类似，UI 端默认未读
    /// - `body_truncated`：Release notes 截取首段（最多 600 字符），用于时间线行展示
    private static func registerV6(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v6-release-subscriptions") { db in
            try createReleaseSubscriptions(db)
            try createReleases(db)
        }
    }

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

    private static func createReleases(_ db: Database) throws {
        try db.create(table: "releases") { t in
            t.column("id", .integer).primaryKey()
            t.column("repo_id", .integer).notNull()
                .references("repos", column: "id", onDelete: .cascade)
            t.column("tag_name", .text).notNull()
            t.column("name", .text)
            t.column("body_truncated", .text)
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
