//
//  DatabaseMigrationsV1.swift
//  Starcat
//
//  数据库 schema 迁移注册入口。
//
//  设计原则（2026-07-12 起：正式版已发布）：
//
//  1. **v1-initial 已冻结**：上线前曾把历史变更摊平进 v1；此后禁止再改已落地的
//     v1 建表 SQL 来「偷偷加字段」。已发布用户的库不会重跑 v1。
//  2. **正式版后只追加迁移**：已随正式版发出的 schema，加字段 / 建表 / 加索引一律
//     `registerVN(into:)`；禁止回改已落地的 `v1-initial`，禁止要求用户删库重建。
//  3. **未发布功能收口**：开发期可改该功能草稿 SQL + `ensurePrelaunch*`；封版时压成单次
//     `registerVN` 并从 v1/ensure 抽掉。依赖未建表的中间 migration 必须对「表不存在」
//     no-op（见 `v5`/`v6`），避免炸死仅有 1.0.0 schema 的用户。
//     RAG 已于 2026-07-14 收口为 `v7-knowledge-rag`。
//  4. **不支持降级**（见 `docs/1-立项/开发前问题清单.md` §5.2）。
//  5. GRDB 迁移名采用语义化字符串（如 `"v7-knowledge-rag"`）。
//  6. 表创建顺序遵循外键依赖：先 repos / tags，再依赖它们的关联 / 缓存表。
//  7. FTS5 触发器与 repos 表同步：外部内容模式 `content='repos', content_rowid='id'`
//     + tokenize `unicode61 remove_diacritics 2`。
//
//  ---
//  **上线前历史（已合并进 v1-initial，仅供 git blame 考古）**：
//  - 原 v2：sync_state 加 stars_etag                  → 合并进 `createSyncState`
//  - 原 v3：repos 加 2 个性能复合索引（HOM-46）        → 合并进 `createRepos`
//  - 原 v4：trending_repos + trending_readmes 两张表  → `createTrendingRepos` / `createTrendingReadmes`
//  - 原 v5：repo_embeddings + ai_summaries 两张表     → `createRepoEmbeddings` / `createAISummaries`
//  - 原 v6：release_subscriptions + releases 两张表   → `createReleaseSubscriptions` / `createReleases`
//  - 原 v7：readme_translations → 已删除（改磁盘缓存）
//  - 原 v8 / v9 / R-05：trending / repos 列扩展       → 合并进对应 create*
//
//  **正式版后的追加迁移（不要与上方「原 vN」混淆）**：
//  - `v2-undo-star` / `v3-agent-runs` / `v4-agent-tool-outputs` /
//    `v5-rag-conversation-pin` / `v6-rag-conversation-groups` / `v7-knowledge-rag` /
//    `v8-rag-suggested-actions` / `v9-rag-metadata-keyword-only` /
//    `v10-rag-conversation-pinned-at` / `v11-rag-embedding-claim` /
//    `v12-rag-metadata-revision` / `v13-weekly-multi-source` /
//    `v14-ai-usage-events` / `v15-repo-pins` / `v16-repository-insights` /
//    `v17-my-projects` / `v18-rag-structured-citations` / `v19-release-1.4.0` /
//    `v20-agent-runtime-trace`
//
//  **1.4.0 开发期迁移（已由正式 v19 合并接管）**：
//  `v19-agent-message-contract` 至 `v26-github-timeline-conversations` 仅在开发构建中出现过。
//  正式 v19 使用 GRDB merging migration，既让 v18 正式用户一次升级，也让已执行部分或全部
//  开发期迁移的本机数据库原子收口到同一个正式标识。
//

import Foundation
import GRDB

/// 数据库迁移定义。
///
/// 暴露一个 `registerAll(into:)` 方法将所有版本注册到 GRDB DatabaseMigrator，
/// 由 DatabaseManager 在启动时调用。
enum DatabaseMigrations {

    private static let releaseV19Identifier = "v19-release-1.4.0"
    private static let releaseV19DevelopmentIdentifiers: Set<String> = [
        "v19-agent-message-contract",
        "v20-rag-chunks-fts-trigram",
        "v21-github-notifications",
        "v22-github-notification-comments",
        "v23-github-notification-subject-created",
        "v24-user-repo-activity",
        "v25-user-repo-activity-actor",
        "v26-github-timeline-conversations",
    ]

    /// 将所有版本的迁移注册到 migrator。
    ///
    /// `v1-initial` 已冻结；正式版后的 schema 变更只追加 `registerVN`，
    /// 详见文件头部「设计原则」。
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
        registerV10(into: &migrator)
        registerV11(into: &migrator)
        registerV12(into: &migrator)
        registerV13(into: &migrator)
        registerV14(into: &migrator)
        registerV15(into: &migrator)
        registerV16(into: &migrator)
        registerV17(into: &migrator)
        registerV18(into: &migrator)
        registerV19(into: &migrator)
        registerV20(into: &migrator)
    }

    // MARK: - v20-agent-runtime-trace：Runtime 原生执行过程（2026-08-22）

    /// 对话消息无法表达 Codex item lifecycle、重试和 Provider warning。单独保存经过
    /// Adapter 清洗的产品投影，不保存 JSON-RPC 原始帧、环境变量或隐藏思维链。
    private static func registerV20(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v20-agent-runtime-trace") { db in
            try db.create(table: "agent_trace_events") { table in
                table.column("id", .text).primaryKey()
                table.column("run_id", .text).notNull()
                    .references("agent_runs", column: "id", onDelete: .cascade)
                table.column("sequence", .integer).notNull()
                table.column("event_json", .text).notNull()
                table.column("created_at", .text).notNull()
                table.column("updated_at", .text).notNull()
                table.uniqueKey(["run_id", "sequence"])
            }
            try db.create(
                index: "idx_agent_trace_events_run_sequence",
                on: "agent_trace_events",
                columns: ["run_id", "sequence"]
            )
        }
    }

    // MARK: - v19-release-1.4.0：1.4.0 正式版 schema 收口（2026-08-21）

    /// 开发期为便于独立验证，先后登记了 v19...v26。正式发布时这些变更对线上 v18 用户
    /// 必须表现为一次升级；同时开发机可能停在任意中间版本，不能要求删库重建。
    ///
    /// GRDB 的 merging migration 会在同一事务中：
    /// 1. 把已执行的开发期标识传入闭包，只补缺失步骤；
    /// 2. 删除旧标识并写入唯一的正式 v19 标识。
    ///
    /// 禁止手工改写 `grdb_migrations`，否则 schema 与迁移账本可能失配。
    private static func registerV19(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration(
            releaseV19Identifier,
            merging: releaseV19DevelopmentIdentifiers
        ) { db, appliedIdentifiers in
            if !appliedIdentifiers.contains("v19-agent-message-contract") {
                try applyAgentMessageContractV19(db)
            }
            if !appliedIdentifiers.contains("v20-rag-chunks-fts-trigram") {
                try applyRAGChunksFTSTrigramV19(db)
            }
            if !appliedIdentifiers.contains("v21-github-notifications") {
                try applyGitHubNotificationsV19(db)
            }
            if !appliedIdentifiers.contains("v22-github-notification-comments") {
                try applyGitHubNotificationCommentsV19(db)
            }
            if !appliedIdentifiers.contains("v23-github-notification-subject-created") {
                try applyGitHubNotificationSubjectCreatedV19(db)
            }
            if !appliedIdentifiers.contains("v24-user-repo-activity") {
                try applyUserRepoActivityV19(db)
            }
            if !appliedIdentifiers.contains("v25-user-repo-activity-actor") {
                try applyUserRepoActivityActorV19(db)
            }
            if !appliedIdentifiers.contains("v26-github-timeline-conversations") {
                try applyGitHubTimelineConversationsV19(db)
            }
        }
    }

#if DEBUG
    /// 只供迁移测试重建开发期数据库状态，生产启动路径始终只注册正式 v19。
    static func registerRelease140DevelopmentMigrationsForTesting(
        into migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v19-agent-message-contract", migrate: applyAgentMessageContractV19)
        migrator.registerMigration("v20-rag-chunks-fts-trigram", migrate: applyRAGChunksFTSTrigramV19)
        migrator.registerMigration("v21-github-notifications", migrate: applyGitHubNotificationsV19)
        migrator.registerMigration(
            "v22-github-notification-comments",
            migrate: applyGitHubNotificationCommentsV19
        )
        migrator.registerMigration(
            "v23-github-notification-subject-created",
            migrate: applyGitHubNotificationSubjectCreatedV19
        )
        migrator.registerMigration("v24-user-repo-activity", migrate: applyUserRepoActivityV19)
        migrator.registerMigration("v25-user-repo-activity-actor", migrate: applyUserRepoActivityActorV19)
        migrator.registerMigration(
            "v26-github-timeline-conversations",
            migrate: applyGitHubTimelineConversationsV19
        )
    }
#endif

    // MARK: - v26-github-timeline-conversations：组织 Issue 并入本地时间线（2026-08-21）

    /// v21 的通知表已经承载会话正文、评论和游标分页。这里把它扩成统一时间线会话缓存，
    /// 真实 GitHub 通知仍保留独立 thread id；组织 Issue 只复用展示和详情能力，不伪造已读 / Done。
    /// 私有 Issue 仍跟随当前 GitHub 用户数据库隔离，不进入 CloudKit、导出或 Discovery。
    private static func applyGitHubTimelineConversationsV19(_ db: Database) throws {
        guard try db.tableExists("github_notification_threads") else { return }
        let columns = try db.columns(in: "github_notification_threads").map(\.name)
        try db.alter(table: "github_notification_threads") { t in
            if !columns.contains("notification_thread_id") {
                t.add(column: "notification_thread_id", .text)
            }
            if !columns.contains("source_kind") {
                t.add(column: "source_kind", .text).notNull().defaults(to: "notification")
            }
            if !columns.contains("organization_login") {
                t.add(column: "organization_login", .text)
            }
            if !columns.contains("credential_source") {
                t.add(column: "credential_source", .text)
            }
            if !columns.contains("issue_state") {
                t.add(column: "issue_state", .text)
            }
        }
        try db.execute(
            sql: """
                UPDATE github_notification_threads
                SET notification_thread_id = id
                WHERE notification_thread_id IS NULL AND source_kind = 'notification'
                """
        )
        try db.create(
            index: "idx_github_timeline_subject_api_url",
            on: "github_notification_threads",
            columns: ["subject_api_url"],
            ifNotExists: true
        )
        try db.create(
            index: "idx_github_timeline_source",
            on: "github_notification_threads",
            columns: ["source_kind", "organization_login", "updated_at"],
            ifNotExists: true
        )

        try db.create(table: "github_organization_issue_sync_state", ifNotExists: true) { t in
            t.column("scope_key", .text).primaryKey()
            t.column("organization_login", .text).notNull()
            t.column("credential_source", .text).notNull()
            t.column("next_page", .integer)
            t.column("watermark_updated_at", .text)
            t.column("backfill_completed_at", .text)
            t.column("last_fetched_at", .text)
            t.column("last_error", .text)
        }
    }

    // MARK: - v25-user-repo-activity-actor：账本补 user_id / user_name（2026-08-20）

    /// 推荐要用「谁 star 了哪个项目」。v24 行没有身份，库又按 GitHub user 目录隔离，
    /// 导出后会变成匿名 `(repo, time)`。已落地表只能 ALTER，不能改 v24 建表语句。
    /// `user_name` 存 GitHub `login`；旧行的 `user_id` 能从 `starred_repos` 抄，login 等打开时间线再补。
    private static func applyUserRepoActivityActorV19(_ db: Database) throws {
        guard try db.tableExists("user_repo_activity") else { return }
        let columns = try db.columns(in: "user_repo_activity").map(\.name)
        if !columns.contains("user_id") {
            try db.alter(table: "user_repo_activity") { t in
                t.add(column: "user_id", .integer)
            }
        }
        if !columns.contains("user_name") {
            try db.alter(table: "user_repo_activity") { t in
                t.add(column: "user_name", .text)
            }
        }
        try db.create(
            index: "idx_user_repo_activity_user",
            on: "user_repo_activity",
            columns: ["user_id", "occurred_at"],
            ifNotExists: true
        )
        guard try db.tableExists("starred_repos") else { return }
        try db.execute(
            sql: """
                UPDATE user_repo_activity
                SET user_id = (
                    SELECT sr.user_id FROM starred_repos sr
                    WHERE sr.repo_id = user_repo_activity.repo_id
                )
                WHERE user_id IS NULL
                """
        )
    }

    // MARK: - v24-user-repo-activity：当前用户 Star / Unstar / Fork 账本（2026-08-20）

    /// 通知时间线要混入「我自己对仓库做的事」。GitHub Notifications 没有这些事件，
    /// 也不能写进 `github_notification_threads`（那张表的 id / PATCH / Done 都按 GitHub thread）。
    /// 只追加、不覆盖；Star 可能来自 App 或 Stars 同步，Unstar 的 GitHub 网页操作只能在全量同步发现。
    private static func applyUserRepoActivityV19(_ db: Database) throws {
        try db.create(table: "user_repo_activity") { t in
            t.column("id", .text).primaryKey()
            t.column("kind", .text).notNull()
            t.column("source", .text).notNull()
            t.column("repo_id", .integer).notNull()
            t.column("full_name", .text).notNull()
            t.column("html_url", .text).notNull()
            t.column("occurred_at", .text).notNull()
            t.column("created_at", .text).notNull()
        }
        try db.create(
            index: "idx_user_repo_activity_occurred",
            on: "user_repo_activity",
            columns: ["occurred_at", "id"]
        )
        try db.create(
            index: "idx_user_repo_activity_repo",
            on: "user_repo_activity",
            columns: ["repo_id", "occurred_at"]
        )
    }

    // MARK: - v23-github-notification-subject-created：Issue / PR 开帖时间（2026-08-19）

    /// 详情「发布了这条」需要 `created_at`；列表 `updated_at` 是最后一条评论时间。
    /// 表不存在则 no-op。已 hydrate 但缺这个字段的行，选中后会再补一次 subject。
    private static func applyGitHubNotificationSubjectCreatedV19(_ db: Database) throws {
        guard try db.tableExists("github_notification_threads") else { return }
        let columns = try db.columns(in: "github_notification_threads").map(\.name)
        if !columns.contains("subject_created_at") {
            try db.alter(table: "github_notification_threads") { t in
                t.add(column: "subject_created_at", .text)
            }
        }
    }

    // MARK: - v22-github-notification-comments：通知详情存全文 + 评论（2026-08-19）

    /// v21 把正文截成 500 字，详情页对不上 GitHub Issue。本迁移加 `comments_json`，
    /// 并清掉已截断的 hydrate 缓存，选中后重拉全文和评论。表不存在则 no-op。
    private static func applyGitHubNotificationCommentsV19(_ db: Database) throws {
        guard try db.tableExists("github_notification_threads") else { return }
        let columns = try db.columns(in: "github_notification_threads").map(\.name)
        if !columns.contains("comments_json") {
            try db.alter(table: "github_notification_threads") { t in
                t.add(column: "comments_json", .text)
            }
        }
        try db.execute(sql: """
            UPDATE github_notification_threads
            SET excerpt = NULL, hydrated_at = NULL, comments_json = NULL
            """)
    }

    // MARK: - v21-github-notifications：GitHub 通知时间线（2026-08-19）

    /// 活动页「通知」inbox。独立于 `activity_events`（那是 following 的 received_events）。
    /// 已发布库只能追加迁移；thread 已读 / 摘录缓存均为本机数据，不进 CloudKit。
    private static func applyGitHubNotificationsV19(_ db: Database) throws {
        try db.create(table: "github_notification_threads") { t in
            t.column("id", .text).primaryKey()
            t.column("reason", .text).notNull()
            t.column("unread", .boolean).notNull().defaults(to: true)
            t.column("github_unread", .boolean).notNull().defaults(to: true)
            t.column("repository_id", .integer)
            t.column("repository_full_name", .text).notNull()
            t.column("subject_title", .text).notNull()
            t.column("subject_type", .text).notNull()
            t.column("subject_api_url", .text).notNull()
            t.column("subject_number", .integer)
            t.column("html_url", .text)
            t.column("actor_login", .text)
            t.column("excerpt", .text)
            t.column("hydrated_at", .text)
            t.column("updated_at", .text).notNull()
            t.column("first_seen_at", .text).notNull()
            t.column("notified_at", .text)
            t.column("mark_read_state", .text).notNull().defaults(to: "idle")
            t.column("fetched_at", .text).notNull()
        }
        try db.create(
            index: "idx_github_notification_threads_updated",
            on: "github_notification_threads",
            columns: ["updated_at"]
        )
        try db.create(
            index: "idx_github_notification_threads_unread",
            on: "github_notification_threads",
            columns: ["unread"]
        )
        try db.create(
            index: "idx_github_notification_threads_reason",
            on: "github_notification_threads",
            columns: ["reason"]
        )

        try db.create(table: "github_notification_sync_state") { t in
            t.column("id", .text).primaryKey()
            t.column("last_modified", .text)
            t.column("watermark_updated_at", .text)
            t.column("last_fetched_at", .text)
            t.column("backfill_completed_at", .text)
            t.column("last_poll_interval_seconds", .integer)
        }
    }

    // MARK: - v20-rag-chunks-fts-trigram：chunk FTS 与笔记同款 trigram（2026-08-18）

    /// unicode61 把连续 CJK 当成单个 token，「部署失败」打不中「试过部署失败」。
    /// 与 `notes_fts` 同一决策：trigram 做中缀；不足 3 个字符的 query 无法命中，
    /// 由 `RAGKeywordQueryBuilder` 从 SQLite 表达式里丢掉。`repos_fts` 保持 unicode61。
    /// v7 建表 SQL 已冻结，这里只重建 FTS；尚无 `rag_chunks` 的安装 no-op。
    private static func applyRAGChunksFTSTrigramV19(_ db: Database) throws {
        guard try db.tableExists("rag_chunks") else { return }

        try db.execute(sql: "DROP TRIGGER IF EXISTS rag_chunks_ai")
        try db.execute(sql: "DROP TRIGGER IF EXISTS rag_chunks_ad")
        try db.execute(sql: "DROP TRIGGER IF EXISTS rag_chunks_au")
        try db.execute(sql: "DROP TABLE IF EXISTS rag_chunks_fts")

        try db.execute(sql: """
            CREATE VIRTUAL TABLE rag_chunks_fts USING fts5(
                title,
                section_path,
                content,
                content='rag_chunks',
                content_rowid='id',
                tokenize='trigram'
            )
            """)
        try db.execute(sql: """
            CREATE TRIGGER rag_chunks_ai AFTER INSERT ON rag_chunks BEGIN
                INSERT INTO rag_chunks_fts(rowid, title, section_path, content)
                VALUES (new.id, new.title, new.section_path, new.content);
            END
            """)
        try db.execute(sql: """
            CREATE TRIGGER rag_chunks_ad AFTER DELETE ON rag_chunks BEGIN
                INSERT INTO rag_chunks_fts(rag_chunks_fts, rowid, title, section_path, content)
                VALUES ('delete', old.id, old.title, old.section_path, old.content);
            END
            """)
        try db.execute(sql: """
            CREATE TRIGGER rag_chunks_au AFTER UPDATE ON rag_chunks BEGIN
                INSERT INTO rag_chunks_fts(rag_chunks_fts, rowid, title, section_path, content)
                VALUES ('delete', old.id, old.title, old.section_path, old.content);
                INSERT INTO rag_chunks_fts(rowid, title, section_path, content)
                VALUES (new.id, new.title, new.section_path, new.content);
            END
            """)
        // 外部内容表 CREATE 后是空索引；rebuild 从 rag_chunks 回填，避免老用户升级后全文检索全空。
        try db.execute(sql: "INSERT INTO rag_chunks_fts(rag_chunks_fts) VALUES('rebuild')")
    }

    // MARK: - v19-agent-message-contract：Agent 可回放事实契约（2026-08-04）

    /// v3/v4 的 step/trace/tool-output 是早期 UI 投影模型，新版 Runtime 只以
    /// message/approval/artifact 为事实源。这里一次性完成 schema 收口，并保留可识别历史：
    ///
    /// - 旧 prompt / assistant_output 转成 user / assistant message；
    /// - 旧 artifact_index 搬到 sequence，彻底移除会阻断新版 insert 的 NOT NULL 列；
    /// - 无法无损映射为新版 tool-call 关系的旧事件表改名归档，应用层不做永久双读。
    private static func applyAgentMessageContractV19(_ db: Database) throws {
        try db.alter(table: "agent_runs") { table in
            // 默认值只服务 ALTER TABLE 对既有行的兼容；下方会立刻写入可解码的快照。
            table.add(column: "context_json", .text).notNull().defaults(to: "")
            table.add(column: "model", .text)
            table.add(column: "usage_json", .text)
        }

        try createAgentMessagesV19(db)
        try createAgentApprovalsV19(db)
        try migrateLegacyAgentRunsV19(db)
        try rebuildAgentArtifactsV19(db)
        try archiveLegacyAgentEventTablesV19(db)
    }

    /// 消息按 run 内 sequence 唯一，事务测试依赖数据库拒绝重复序号。
    private static func createAgentMessagesV19(_ db: Database) throws {
        try db.create(table: "agent_messages") { table in
            table.column("id", .text).primaryKey()
            table.column("run_id", .text).notNull()
                .references("agent_runs", column: "id", onDelete: .cascade)
            table.column("role", .text).notNull()
            table.column("turn", .integer).notNull()
            table.column("sequence", .integer).notNull()
            table.column("parts_json", .text).notNull()
            table.column("usage_json", .text)
            table.column("created_at", .text).notNull()
            table.uniqueKey(["run_id", "sequence"])
        }
    }

    /// 审批事实与 message 分表保存，既能恢复 waiting 状态，也不把审批结果伪装成模型消息。
    private static func createAgentApprovalsV19(_ db: Database) throws {
        try db.create(table: "agent_approvals") { table in
            table.column("id", .text).primaryKey()
            table.column("run_id", .text).notNull()
                .references("agent_runs", column: "id", onDelete: .cascade)
            table.column("tool_call_id", .text).notNull()
            table.column("tool_name", .text).notNull()
            table.column("input_json", .text).notNull()
            table.column("permission", .text).notNull()
            table.column("sequence", .integer).notNull()
            table.column("status", .text).notNull()
            table.column("created_at", .text).notNull()
            table.column("decided_at", .text)
            table.uniqueKey(["run_id", "sequence"])
        }
    }

    /// 把 v3 中仍可无损识别的输入、输出和上下文来源写入新版事实表。
    private static func migrateLegacyAgentRunsV19(_ db: Database) throws {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, user_prompt, context_source, assistant_output, created_at, updated_at
                FROM agent_runs
                """
        )
        for row in rows {
            let runID: String = row["id"]
            let prompt: String = row["user_prompt"]
            let contextSource: String = row["context_source"]
            let assistantOutput: String = row["assistant_output"]
            let createdAt: String = row["created_at"]
            let updatedAt: String = row["updated_at"]

            let contextJSON = try legacyAgentContextJSONV19(
                sourceDescription: contextSource,
                generatedAt: createdAt
            )
            try db.execute(
                sql: "UPDATE agent_runs SET context_json = ? WHERE id = ?",
                arguments: [contextJSON, runID]
            )

            try insertLegacyAgentTextMessageV19(
                db,
                runID: runID,
                role: "user",
                sequence: 0,
                text: prompt,
                createdAt: createdAt
            )
            if !assistantOutput.isEmpty {
                try insertLegacyAgentTextMessageV19(
                    db,
                    runID: runID,
                    role: "assistant",
                    sequence: 1,
                    text: assistantOutput,
                    createdAt: updatedAt
                )
            }
        }
    }

    private static func insertLegacyAgentTextMessageV19(
        _ db: Database,
        runID: String,
        role: String,
        sequence: Int,
        text: String,
        createdAt: String
    ) throws {
        let partsJSON = try agentJSONV19([
            ["type": "text", "text": text]
        ])
        try db.execute(
            sql: """
                INSERT INTO agent_messages (
                    id, run_id, role, turn, sequence, parts_json, created_at
                ) VALUES (?, ?, ?, 0, ?, ?, ?)
                """,
            arguments: [UUID().uuidString, runID, role, sequence, partsJSON, createdAt]
        )
    }

    /// 旧 run 没有 repo/attachment 快照，只能冻结当时记录的 context_source。
    /// generatedAt 不是合法 ISO8601 时使用 Unix epoch，保证历史记录至少可以被 Repository 打开。
    private static func legacyAgentContextJSONV19(
        sourceDescription: String,
        generatedAt: String
    ) throws -> String {
        let formatter = ISO8601DateFormatter()
        let safeGeneratedAt = formatter.date(from: generatedAt) == nil
            ? "1970-01-01T00:00:00Z"
            : generatedAt
        return try agentJSONV19([
            "attachments": [],
            "generatedAt": safeGeneratedAt,
            "repos": [],
            "sourceDescription": sourceDescription
        ])
    }

    private static func agentJSONV19(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self)
    }

    /// SQLite 无法移除 v3 的 artifact_index NOT NULL，只能重建表后复制历史数据。
    private static func rebuildAgentArtifactsV19(_ db: Database) throws {
        try db.execute(sql: "DROP INDEX IF EXISTS idx_agent_artifacts_run_index")
        try db.execute(sql: "ALTER TABLE agent_artifacts RENAME TO agent_artifacts_v3")
        try db.create(table: "agent_artifacts") { table in
            table.column("id", .text).primaryKey()
            table.column("run_id", .text).notNull()
                .references("agent_runs", column: "id", onDelete: .cascade)
            table.column("tool_call_id", .text)
            table.column("message_id", .text)
                .references("agent_messages", column: "id", onDelete: .setNull)
            table.column("sequence", .integer).notNull()
            table.column("type", .text).notNull()
            table.column("title", .text).notNull()
            table.column("content", .text).notNull()
            table.column("created_at", .text).notNull()
        }
        try db.execute(sql: """
            INSERT INTO agent_artifacts (
                id, run_id, tool_call_id, message_id, sequence,
                type, title, content, created_at
            )
            SELECT
                id, run_id, NULL, NULL, artifact_index,
                type, title, content, created_at
            FROM agent_artifacts_v3
            """)
        try db.drop(table: "agent_artifacts_v3")
        try db.create(
            index: "idx_agent_artifacts_run_sequence",
            on: "agent_artifacts",
            columns: ["run_id", "sequence"]
        )
    }

    /// 旧事件无法可靠还原 tool-call/result 的强关联，直接改名为 legacy archive，
    /// 避免 Timeline 在新版事实表与旧 UI 投影之间长期猜测、双读。
    private static func archiveLegacyAgentEventTablesV19(_ db: Database) throws {
        let tables = [
            ("agent_run_steps", "agent_legacy_run_steps", "idx_agent_run_steps_run_index", "idx_agent_legacy_run_steps_run_index", "step_index"),
            ("agent_run_traces", "agent_legacy_run_traces", "idx_agent_run_traces_run_index", "idx_agent_legacy_run_traces_run_index", "trace_index"),
            ("agent_run_tool_outputs", "agent_legacy_run_tool_outputs", "idx_agent_run_tool_outputs_run_index", "idx_agent_legacy_run_tool_outputs_run_index", "output_index")
        ]
        for (source, archive, sourceIndex, archiveIndex, orderColumn) in tables {
            try db.execute(sql: "DROP INDEX IF EXISTS \(sourceIndex)")
            try db.execute(sql: "ALTER TABLE \(source) RENAME TO \(archive)")
            try db.create(
                index: archiveIndex,
                on: archive,
                columns: ["run_id", orderColumn]
            )
        }
    }

    // MARK: - v18-rag-structured-citations：结构化知识库事实引用（2026-07-30）

    /// 全局知识库统计不属于单个仓库，也没有可在未来重新加载的 chunk。引用表因此需要：
    ///
    /// - 允许 `repo_id` 为空，并将仓库删除改为 SET NULL，保留用户可见历史；
    /// - 保存结构化证据正文快照，避免旧回答重新打开后显示当前数据库的新统计；
    /// - 通过重建表修改 SQLite 的 NOT NULL / FK 约束，不能回写已发布的 v7 schema。
    private static func registerV18(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v18-rag-structured-citations") { db in
            try db.execute(sql: "DROP INDEX IF EXISTS idx_rag_citations_message_rank")
            try db.execute(sql: """
                ALTER TABLE rag_message_citations
                RENAME TO rag_message_citations_v17
                """)
            try db.create(table: "rag_message_citations") { table in
                table.column("id", .text).primaryKey()
                table.column("message_id", .text).notNull()
                    .references("rag_messages", column: "id", onDelete: .cascade)
                table.column("chunk_id", .integer)
                    .references("rag_chunks", column: "id", onDelete: .setNull)
                table.column("repo_id", .integer)
                    .references("repos", column: "id", onDelete: .setNull)
                table.column("repo_full_name", .text).notNull()
                table.column("marker", .text).notNull().defaults(to: "")
                table.column("source", .text).notNull()
                table.column("section_title", .text).notNull().defaults(to: "")
                table.column("rank", .integer).notNull()
                table.column("score", .double).notNull()
                table.column("hit_kind", .text).notNull().defaults(to: "hybrid")
                table.column("vector_similarity", .double)
                table.column("score_breakdown_json", .text)
                table.column("source_url", .text)
                table.column("evidence_content", .text)
                table.column("fetched_at", .text)
            }
            try db.execute(sql: """
                INSERT INTO rag_message_citations (
                    id, message_id, chunk_id, repo_id, repo_full_name, marker, source,
                    section_title, rank, score, hit_kind, vector_similarity,
                    score_breakdown_json, source_url, evidence_content, fetched_at
                )
                SELECT
                    id, message_id, chunk_id, repo_id, repo_full_name, marker, source,
                    section_title, rank, score, hit_kind, vector_similarity,
                    score_breakdown_json, source_url, NULL, fetched_at
                FROM rag_message_citations_v17
                """)
            try db.drop(table: "rag_message_citations_v17")
            try db.create(
                index: "idx_rag_citations_message_rank",
                on: "rag_message_citations",
                columns: ["message_id", "rank"]
            )
        }
    }

    // MARK: - v17-my-projects：当前用户的个人 / 组织项目关系（2026-07-29）

    /// “我的项目”是用户与 Repo 的独立关系，不能塞进 `repos` 缓存表：
    ///
    /// - 同一个 Repo 可以同时是 Star、Project 和 Library，远端元数据刷新不能覆盖这些关系；
    /// - Starcat 为每个 GitHub 用户使用独立数据库，但仍保留 `user_id`，避免异步切库边界出错时
    ///   把旧账号结果误写进新账号视图；
    /// - 项目同步按 credential + affiliation 分页，只有完整 generation 成功后才能清理旧关系，
    ///   所以同步状态必须独立持久化，不能复用只服务 Stars 的 `sync_state`。
    ///
    /// 表中刻意不保存 token、响应 body 或 Private repo full name 形式的错误文本。
    private static func registerV17(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v17-my-projects") { db in
            try db.create(table: "user_projects") { table in
                table.column("user_id", .integer).notNull()
                table.column("repo_id", .integer).notNull()
                    .references("repos", column: "id", onDelete: .cascade)
                table.column("affiliation", .text).notNull()
                table.column("owner_login", .text).notNull()
                table.column("owner_type", .text).notNull()
                table.column("visibility", .text).notNull()
                table.column("permission", .text).notNull()
                table.column("authorization_source", .text).notNull()
                table.column("installation_id", .integer)
                table.column("generation", .text).notNull()
                table.column("last_seen_at", .text).notNull()
                table.column("created_at", .text).notNull()
                table.column("updated_at", .text).notNull()
                table.primaryKey(["user_id", "repo_id"])
            }
            try db.create(
                index: "idx_user_projects_user_affiliation",
                on: "user_projects",
                columns: ["user_id", "affiliation"]
            )
            try db.create(
                index: "idx_user_projects_user_owner",
                on: "user_projects",
                columns: ["user_id", "owner_login"]
            )
            try db.create(
                index: "idx_user_projects_user_visibility",
                on: "user_projects",
                columns: ["user_id", "visibility"]
            )
            try db.create(
                index: "idx_user_projects_user_permission",
                on: "user_projects",
                columns: ["user_id", "permission"]
            )
            try db.create(
                index: "idx_user_projects_user_generation",
                on: "user_projects",
                columns: ["user_id", "generation"]
            )

            try db.create(table: "project_sync_state") { table in
                table.column("user_id", .integer).notNull()
                table.column("credential_kind", .text).notNull()
                table.column("affiliation", .text).notNull()
                table.column("etag", .text)
                table.column("generation", .text)
                table.column("last_attempt_at", .text)
                table.column("last_success_at", .text)
                table.column("sync_status", .text).notNull().defaults(to: "idle")
                table.column("error_code", .text)
                table.column("updated_at", .text).notNull()
                table.primaryKey(["user_id", "credential_kind", "affiliation"])
            }
            try db.create(
                index: "idx_project_sync_state_status",
                on: "project_sync_state",
                columns: ["user_id", "sync_status"]
            )
        }
    }

    // MARK: - v16-repository-insights：仓库洞察与 Star 历史缓存（2026-07-27）

    /// 两张表都属于可重建缓存，但生命周期不同：远端指标按 dataset/range 整体覆盖，
    /// Star 历史按日期和来源长期累积。保持独立表可避免刷新远端估算时误删本地精确点。
    private static func registerV16(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v16-repository-insights") { db in
            try db.create(table: "repo_insights_snapshots") { table in
                table.column("repo_id", .integer).notNull()
                    .references("repos", column: "id", onDelete: .cascade)
                table.column("dataset", .text).notNull()
                table.column("range_key", .text).notNull()
                table.column("payload_json", .blob).notNull()
                table.column("default_branch_sha", .text)
                table.column("fetched_at", .text).notNull()
                table.column("stale_after", .text).notNull()
                table.column("response_etag", .text)
                table.primaryKey(["repo_id", "dataset", "range_key"])
            }
            try db.create(
                index: "idx_repo_insights_snapshots_stale",
                on: "repo_insights_snapshots",
                columns: ["stale_after"]
            )

            try db.create(table: "repo_star_history_points") { table in
                table.column("repo_id", .integer).notNull()
                    .references("repos", column: "id", onDelete: .cascade)
                table.column("observed_on", .text).notNull()
                table.column("stars_count", .integer).notNull()
                    .check { $0 >= 0 }
                table.column("source", .text).notNull()
                table.column("precision", .text).notNull()
                table.column("fetched_at", .text).notNull()
                table.primaryKey(["repo_id", "observed_on", "source"])
            }
            try db.create(
                index: "idx_repo_star_history_points_lookup",
                on: "repo_star_history_points",
                columns: ["repo_id", "observed_on"]
            )
        }
    }

    // MARK: - v15-repo-pins：Manage 仓库置顶（2026-07-22）

    /// Repo Pin 是用户私有的整理状态，不能写进可由 GitHub 重新拉取的 `repos` 缓存表。
    /// 独立关系表让同步刷新只更新仓库元数据，不会覆盖用户的置顶选择；`repo_id` 主键同时
    /// 保证一个仓库只有一份全局 Pin 状态。`pinned_at` 用于多个置顶仓库按最近操作排序。
    private static func registerV15(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v15-repo-pins") { db in
            try db.create(table: "repo_pins") { table in
                table.column("repo_id", .integer).primaryKey()
                    .references("repos", column: "id", onDelete: .cascade)
                table.column("pinned_at", .double).notNull()
            }
            try db.create(index: "idx_repo_pins_pinned_at", on: "repo_pins", columns: ["pinned_at"])
        }
    }

    // MARK: - v14-ai-usage-events：AI 请求用量事件（2026-07-19）

    /// 每次 Chat / Embedding HTTP 推理请求对应一行本地事件。
    ///
    /// 为什么保存原始事件而不是预聚合日报：功能、模型和 Provider 都是低基数维度，SQLite
    /// 可以实时聚合；原始事件还能在统计口径调整后重新计算。表刻意不包含 prompt、response、
    /// API Key、Base URL 和完整错误文本，避免统计功能扩大敏感数据落盘面。
    private static func registerV14(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v14-ai-usage-events") { db in
            try db.create(table: "ai_usage_events") { table in
                table.column("id", .text).primaryKey()
                table.column("started_at", .double).notNull()
                table.column("completed_at", .double).notNull()
                table.column("duration_ms", .integer).notNull()
                table.column("provider_id", .text).notNull()
                table.column("provider_kind", .text).notNull()
                table.column("model", .text).notNull()
                table.column("feature", .text).notNull()
                table.column("phase", .text).notNull()
                table.column("operation", .text).notNull()
                table.column("input_tokens", .integer)
                table.column("output_tokens", .integer)
                table.column("total_tokens", .integer)
                table.column("cached_input_tokens", .integer)
                table.column("reasoning_output_tokens", .integer)
                table.column("item_count", .integer).notNull().defaults(to: 1)
                table.column("usage_source", .text).notNull()
                table.column("status", .text).notNull()
                table.column("error_category", .text)
                table.column("correlation_id", .text)
            }
            try db.create(index: "idx_ai_usage_events_completed", on: "ai_usage_events", columns: ["completed_at"])
            try db.create(index: "idx_ai_usage_events_feature_completed", on: "ai_usage_events", columns: ["feature", "completed_at"])
            try db.create(index: "idx_ai_usage_events_model_completed", on: "ai_usage_events", columns: ["model", "completed_at"])
        }
    }

    // MARK: - v12-rag-metadata-revision：元数据快照修订号（2026-07-16）

    /// Planner / Generator 共用的全局元数据快照包含多张表的聚合事实。单调修订号让缓存只在
    /// 数据确实变化时失效，不能把 UI 当前碰巧持有的快照当作数据库真值。触发器在同一写事务
    /// 内推进版本，因此提交前不可见、回滚时也会一起回滚，不存在通知先于落库的竞态。
    private static func registerV12(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v12-rag-metadata-revision") { db in
            try db.create(table: "rag_metadata_revision", ifNotExists: true) { table in
                table.column("id", .integer).primaryKey()
                table.column("revision", .integer).notNull().defaults(to: 0)
            }
            try db.execute(sql: "INSERT OR IGNORE INTO rag_metadata_revision (id, revision) VALUES (1, 0)")

            // 这些表覆盖快照的知识库边界、Repo 事实、标签/状态、摘要和索引健康度。
            // 每行触发虽然会多次递增，但同一事务只提交 singleton 页的最终值；读取端只比较版本。
            for table in [
                "repos", "repo_notes", "tags", "repo_tags", "ai_summaries",
                "rag_chunks", "rag_chunk_overrides"
            ] where try db.tableExists(table) {
                for operation in ["INSERT", "UPDATE", "DELETE"] {
                    let suffix = operation.lowercased()
                    try db.execute(sql: """
                        CREATE TRIGGER IF NOT EXISTS rag_metadata_revision_\(table)_\(suffix)
                        AFTER \(operation) ON \(table)
                        BEGIN
                            UPDATE rag_metadata_revision SET revision = revision + 1 WHERE id = 1;
                        END
                        """)
                }
            }
        }
    }

    // MARK: - v13-weekly-multi-source：Weekly 通用来源与置顶缓存（2026-07-16）

    /// Weekly 分支最初基于旧基线占用了 v11；合并时 v11/v12 已正式发布，故必须顺延为 v13。
    /// 表不存在时 no-op，避免旧安装尚未具备 Weekly cache 时启动失败。
    private static func registerV13(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v13-weekly-multi-source") { db in
            guard try db.tableExists("weekly_bulk_repos") else { return }
            let columns = try db.columns(in: "weekly_bulk_repos").map(\.name)
            try db.alter(table: "weekly_bulk_repos") { table in
                if !columns.contains("source_entries_json") {
                    table.add(column: "source_entries_json", .text)
                }
                if !columns.contains("is_pinned") {
                    table.add(column: "is_pinned", .boolean).notNull().defaults(to: false)
                }
                if !columns.contains("pin_position") {
                    table.add(column: "pin_position", .integer)
                }
            }
            if try db.tableExists("weekly_bulk_sources") == false {
                try db.create(table: "weekly_bulk_sources") { table in
                    table.column("code", .text).primaryKey()
                    table.column("display_name_zh", .text).notNull()
                    table.column("display_name_en", .text).notNull()
                    table.column("icon_key", .text).notNull()
                    table.column("sort_order", .integer).notNull()
                    table.column("count", .integer).notNull().defaults(to: 0)
                }
            }
        }
    }

    // MARK: - v11-rag-embedding-claim：Embedding 写回所有权（2026-07-16）

    /// Embedding 请求跨越网络 await，期间 source 可能刷新并复用同一个 chunk id。
    /// claim id 让返回结果只能写回自己领取的 pending 正文；表不存在时 no-op，禁止回写已发布 v7。
    private static func registerV11(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v11-rag-embedding-claim") { db in
            guard try db.tableExists("rag_chunks") else { return }
            let columns = try db.columns(in: "rag_chunks").map(\.name)
            guard !columns.contains("embedding_claim_id") else { return }
            try db.alter(table: "rag_chunks") { table in
                table.add(column: "embedding_claim_id", .text)
            }
        }
    }

    // MARK: - v10-rag-conversation-pinned-at：置顶时间戳（2026-07-15）

    /// 置顶顺序必须跟「最后一次置顶操作」走，不能复用 `updated_at`（发消息也会改它），
    /// 否则旧会话被置顶后仍沉在置顶区底部，看起来像 Pin 没生效。
    /// 对无表 / 已有列都幂等；已置顶行用 `updated_at` 回填，保留相对次序。
    private static func registerV10(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v10-rag-conversation-pinned-at") { db in
            guard try db.tableExists("rag_conversations") else { return }
            try ensureRAGConversationPinnedAtSchema(db)
        }
    }

    // MARK: - v9-rag-metadata-keyword-only：动态 Metadata 改为纯 FTS（2026-07-14）

    /// 已发布用户原有 Metadata 可能带旧 embedding。该迁移只清理可重建缓存并标记为
    /// keyword_only；表不存在时 no-op，以支持尚未获得 v7 RAG schema 的旧安装。
    private static func registerV9(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v9-rag-metadata-keyword-only") { db in
            guard try db.tableExists("rag_chunks") else { return }
            try db.execute(sql: """
                UPDATE rag_chunks
                SET embedding = NULL,
                    embedding_dim = NULL,
                    embedding_model = NULL,
                    embedding_status = 'keyword_only',
                    embedding_error = NULL,
                    indexed_at = NULL
                WHERE source = 'metadata'
                """)
        }
    }

    // MARK: - v8-rag-suggested-actions：RAG 推荐问题持久化（2026-07-14）

    /// 推荐问题必须跟随 assistant message 回放。迁移对表不存在和开发库已手工补列都幂等，
    /// 但不会回写已收口的 v7 schema，确保正式用户只走向前追加的升级路径。
    private static func registerV8(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v8-rag-suggested-actions") { db in
            guard try db.tableExists("rag_messages") else { return }
            let columns = try db.columns(in: "rag_messages").map(\.name)
            guard !columns.contains("suggested_actions_json") else { return }
            try db.alter(table: "rag_messages") { table in
                table.add(column: "suggested_actions_json", .text)
            }
        }
    }

    // MARK: - v7-knowledge-rag：知识库 RAG 整包最终 schema（2026-07-14）

    /// 正式版升迁通道：App Store 1.0.0 等无 RAG 用户在此一次性建出最终表结构。
    ///
    /// 方案 A 收口：RAG 已从 `v1-initial` 草稿与 `ensurePrelaunchRAGSchema` 抽离；
    /// 新装走 v1（无 RAG）→ … → v7 建表；已有开发期草稿库则在此幂等补齐。
    /// `v5`/`v6` 保留为历史增量标识（已应用库不能删迁移名），对无表用户仍 no-op。
    private static func registerV7(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v7-knowledge-rag") { db in
            try ensureKnowledgeRAGSchema(db)
        }
    }

    // MARK: - v6-rag-conversation-groups：RAG 会话一级分组（2026-07-12）

    /// 开发期增量：仅服务「库里已有 `rag_conversations`」的预览包。
    /// 无表的正式版用户整段 no-op；最终整包以 `v7-knowledge-rag` 为准。
    private static func registerV6(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v6-rag-conversation-groups") { db in
            guard try db.tableExists("rag_conversations") else { return }
            try ensureRAGConversationGroupsSchema(db)
        }
    }

    // MARK: - v5-rag-conversation-pin：RAG 会话置顶（2026-07-12）

    /// 开发期增量：仅服务「库里已经有 `rag_conversations`」的预览包。
    /// App Store `1.0.0` 等尚未建 RAG 表的用户整段跳过；最终整包在 `v7-knowledge-rag`。
    private static func registerV5(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v5-rag-conversation-pin") { db in
            guard try db.tableExists("rag_conversations") else { return }

            // 幂等：本机若曾被开发期补丁加过列，跳过 ADD，避免正式迁移失败。
            let columns = try db.columns(in: "rag_conversations").map(\.name)
            if !columns.contains("is_pinned") {
                try db.alter(table: "rag_conversations") { t in
                    // 置顶排在列表最前；不改 updated_at，避免置顶本身影响「最近活跃」语义。
                    t.add(column: "is_pinned", .boolean).notNull().defaults(to: false)
                }
            }
            let indexes = try db.indexes(on: "rag_conversations").map(\.name)
            if !indexes.contains("idx_rag_conversations_pinned_updated") {
                try db.create(
                    index: "idx_rag_conversations_pinned_updated",
                    on: "rag_conversations",
                    columns: ["is_pinned", "updated_at"]
                )
            }
        }
    }

    // MARK: - v4-agent-tool-outputs：Agent 工具输出事件（2026-07-07）

    private static func registerV4(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v4-agent-tool-outputs") { db in
            try createAgentRunToolOutputs(db)
        }
    }

    // MARK: - v3-agent-runs：Agent 运行历史（2026-07-07）

    private static func registerV3(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v3-agent-runs") { db in
            try createAgentRuns(db)
            try createAgentRunSteps(db)
            try createAgentRunTraces(db)
            try createAgentArtifacts(db)
        }
    }

    private static func createAgentRuns(_ db: Database) throws {
        try db.create(table: "agent_runs") { t in
            t.column("id", .text).primaryKey()
            t.column("agent_id", .text).notNull()
            t.column("title", .text).notNull()
            t.column("user_prompt", .text).notNull()
            t.column("context_source", .text).notNull()
            t.column("status", .text).notNull()
            t.column("assistant_output", .text).notNull().defaults(to: "")
            t.column("error_message", .text)
            t.column("created_at", .text).notNull()
            t.column("updated_at", .text).notNull()
            t.column("finished_at", .text)
        }
        try db.create(index: "idx_agent_runs_agent_created", on: "agent_runs", columns: ["agent_id", "created_at"])
        try db.create(index: "idx_agent_runs_created", on: "agent_runs", columns: ["created_at"])
    }

    private static func createAgentRunSteps(_ db: Database) throws {
        try db.create(table: "agent_run_steps") { t in
            t.column("id", .text).primaryKey()
            t.column("run_id", .text).notNull()
                .references("agent_runs", column: "id", onDelete: .cascade)
            t.column("step_index", .integer).notNull()
            t.column("title", .text).notNull()
            t.column("detail", .text).notNull()
            t.column("status", .text).notNull()
            t.column("updated_at", .text).notNull()
        }
        try db.create(index: "idx_agent_run_steps_run_index", on: "agent_run_steps", columns: ["run_id", "step_index"])
    }

    private static func createAgentRunTraces(_ db: Database) throws {
        try db.create(table: "agent_run_traces") { t in
            t.column("id", .text).primaryKey()
            t.column("run_id", .text).notNull()
                .references("agent_runs", column: "id", onDelete: .cascade)
            t.column("trace_index", .integer).notNull()
            t.column("kind", .text).notNull()
            t.column("title", .text).notNull()
            t.column("summary", .text).notNull()
            t.column("input", .text).notNull()
            t.column("output", .text).notNull()
            t.column("log", .text).notNull()
            t.column("status", .text).notNull()
            t.column("related_tool_output_id", .text)
            t.column("related_artifact_id", .text)
            t.column("created_at", .text).notNull()
        }
        try db.create(index: "idx_agent_run_traces_run_index", on: "agent_run_traces", columns: ["run_id", "trace_index"])
    }

    private static func createAgentRunToolOutputs(_ db: Database) throws {
        try db.create(table: "agent_run_tool_outputs") { t in
            t.column("id", .text).primaryKey()
            t.column("run_id", .text).notNull()
                .references("agent_runs", column: "id", onDelete: .cascade)
            t.column("output_index", .integer).notNull()
            t.column("tool_name", .text).notNull()
            t.column("summary", .text).notNull()
            t.column("detail", .text).notNull()
            t.column("input", .text).notNull()
            t.column("output", .text).notNull()
            t.column("log", .text).notNull()
            t.column("created_at", .text).notNull()
        }
        try db.create(index: "idx_agent_run_tool_outputs_run_index", on: "agent_run_tool_outputs", columns: ["run_id", "output_index"])
    }

    private static func createAgentArtifacts(_ db: Database) throws {
        try db.create(table: "agent_artifacts") { t in
            t.column("id", .text).primaryKey()
            t.column("run_id", .text).notNull()
                .references("agent_runs", column: "id", onDelete: .cascade)
            t.column("artifact_index", .integer).notNull()
            t.column("type", .text).notNull()
            t.column("title", .text).notNull()
            t.column("content", .text).notNull()
            t.column("created_at", .text).notNull()
        }
        try db.create(index: "idx_agent_artifacts_run_index", on: "agent_artifacts", columns: ["run_id", "artifact_index"])
    }

    // MARK: - v2-undo-star：Unstar 撤销历史记录（2026-07-05）

    private static func registerV2(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v2-undo-star") { db in
            try createUndoStarHistory(db)
        }
    }

    private static func createUndoStarHistory(_ db: Database) throws {
        try db.create(table: "undo_star_history") { t in
            t.column("gh_repo_id", .integer).primaryKey()
                .references("repos", column: "id", onDelete: .cascade)
            t.column("owner", .text).notNull()
            t.column("name", .text).notNull()
            t.column("full_name", .text).notNull()
            t.column("description", .text)
            t.column("language", .text)
            t.column("stars_count", .integer).notNull().defaults(to: 0)
            t.column("forks_count", .integer).notNull().defaults(to: 0)
            t.column("watchers_count", .integer).notNull().defaults(to: 0)
            t.column("html_url", .text).notNull()
            t.column("unstarred_at", .text).notNull()
        }
        try db.create(index: "idx_undo_star_unstarred_at", on: "undo_star_history", columns: ["unstarred_at"])
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
            try createInitialWarmupJobs(db)
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
            // RAG 已收口到 `v7-knowledge-rag`，不再出现在已冻结的 v1-initial 草稿里。
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
            t.column("access_state", .text).notNull().defaults(to: "accessible")
            t.column("access_reason", .text)
            t.column("access_checked_at", .text)

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

    /// repo_notes：用户对 repo 的私有笔记 + 阅读状态 + Starcat 私有知识库状态。
    ///
    /// `library_state` 放在这里，而不是 `repos` / `starred_repos`：
    /// - `repos` 是可重建的 GitHub 元数据缓存；
    /// - `starred_repos` 是 GitHub 公开 star 关系；
    /// - 知识库状态与 notes/status 一样是用户私有数据，后续 CloudKit 也应同层同步。
    private static func createRepoNotes(_ db: Database) throws {
        try db.create(table: "repo_notes") { t in
            t.column("repo_id", .integer).primaryKey()
                .references("repos", column: "id", onDelete: .cascade)
            t.column("content", .text)
            t.column("status", .text).notNull().defaults(to: "unread")
            t.column("library_state", .text).notNull().defaults(to: "outside_library")
            t.column("library_updated_at", .text)
            t.column("is_ai_generated", .boolean).notNull().defaults(to: false)
            t.column("edited_at", .text)
        }

        try db.create(index: "idx_repo_notes_library_state", on: "repo_notes", columns: ["library_state"])
        try db.create(index: "idx_repo_notes_library_updated_at", on: "repo_notes", columns: ["library_updated_at"])
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

    /// initial_warmup_jobs：新用户首次 starred 全量同步后的 README / Health 预热作业。
    ///
    /// 本表只保存“作业阶段 + 恢复点 + 当前覆盖率”，不保存 repo 队列。原因是 starred
    /// 仓库集合会随同步、取消 star、清理缓存变化；每批从当前 DB 事实重新查询候选，应用
    /// 关闭或崩溃后才能准确恢复。
    private static func createInitialWarmupJobs(_ db: Database) throws {
        try db.create(table: "initial_warmup_jobs") { t in
            t.column("user_id", .integer).primaryKey()
            t.column("phase", .text).notNull()
            t.column("scheduled_at", .text)
            t.column("started_at", .text)
            t.column("completed_at", .text)
            t.column("next_retry_at", .text)
            t.column("last_error_kind", .text)
            t.column("readme_covered", .integer).notNull().defaults(to: 0)
            t.column("readme_total", .integer).notNull().defaults(to: 0)
            t.column("health_covered", .integer).notNull().defaults(to: 0)
            t.column("health_total", .integer).notNull().defaults(to: 0)
            t.column("updated_at", .text).notNull()
        }

        try db.create(index: "idx_initial_warmup_phase_retry", on: "initial_warmup_jobs", columns: ["phase", "next_retry_at"])
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
    /// - **ttl_c（历史）**：初版列表与 README 不设 TTL；R-06.1 后列表改为由 ViewModel
    ///   基于 `cached_at` 执行 daily 1h / weekly 6h / monthly 24h 分桶 TTL，表结构无需变化。
    ///   README 仍走自身独立缓存策略。
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
            t.column("cached_at", .text).notNull()               // ViewModel 按桶取 max 做分周期 TTL

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
    /// ViewModel 据此判断 6h TTL。
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

    // MARK: - Knowledge RAG（chunk 索引 + 本地会话）

    /// 创建知识库 RAG 的派生索引与本地会话表。
    ///
    /// `rag_chunks` 是可重建缓存，`rag_conversations` / `rag_messages` /
    /// `rag_message_citations` 是用户可见历史。citation 的 `chunk_id` 故意允许为空并使用
    /// `ON DELETE SET NULL`：清理索引后仍保留历史回答及引用元数据，Inspector 再提示
    /// “引用片段已清理”，不能级联删除用户历史。
    private static func createRAGSchema(_ db: Database) throws {
        try db.create(table: "rag_chunks") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("repo_id", .integer).notNull()
                .references("repos", column: "id", onDelete: .cascade)
            t.column("source", .text).notNull()
            t.column("source_id", .text).notNull().defaults(to: "")
            t.column("parent_type", .text).notNull().defaults(to: "repo")
            t.column("parent_key", .text).notNull()
            t.column("parent_title", .text).notNull().defaults(to: "")
            t.column("chunk_key", .text).notNull()
            t.column("chunk_index", .integer).notNull()
            t.column("section_path", .text).notNull().defaults(to: "")
            t.column("title", .text).notNull().defaults(to: "")
            t.column("content", .text).notNull()
            t.column("content_hash", .text).notNull()
            t.column("token_count", .integer).notNull()
            t.column("is_truncated", .boolean).notNull().defaults(to: false)
            t.column("embedding_model", .text)
            t.column("embedding_dim", .integer)
            t.column("embedding", .blob)
            t.column("embedding_status", .text).notNull().defaults(to: "pending")
            t.column("embedding_error", .text)
            t.column("indexed_at", .text)
            t.column("created_at", .text).notNull()
            t.column("updated_at", .text).notNull()
            t.uniqueKey(["repo_id", "source", "source_id", "chunk_key"])
        }
        try db.create(index: "idx_rag_chunks_repo", on: "rag_chunks", columns: ["repo_id"])
        try db.create(index: "idx_rag_chunks_parent", on: "rag_chunks", columns: ["repo_id", "parent_type", "parent_key"])
        try db.create(index: "idx_rag_chunks_source", on: "rag_chunks", columns: ["source"])
        try db.create(index: "idx_rag_chunks_model_status", on: "rag_chunks", columns: ["embedding_model", "embedding_status"])
        try createRAGChunkOverrideSchema(db)
        try createRAGChunkTombstoneSchema(db)

        // 外部内容 FTS 只镜像可展示文本；知识库边界在 Retriever 查询时通过 repo_notes join 强制执行。
        try db.execute(sql: """
            CREATE VIRTUAL TABLE rag_chunks_fts USING fts5(
                title,
                section_path,
                content,
                content='rag_chunks',
                content_rowid='id',
                tokenize='unicode61 remove_diacritics 2'
            )
            """)
        try db.execute(sql: """
            CREATE TRIGGER rag_chunks_ai AFTER INSERT ON rag_chunks BEGIN
                INSERT INTO rag_chunks_fts(rowid, title, section_path, content)
                VALUES (new.id, new.title, new.section_path, new.content);
            END
            """)
        try db.execute(sql: """
            CREATE TRIGGER rag_chunks_ad AFTER DELETE ON rag_chunks BEGIN
                INSERT INTO rag_chunks_fts(rag_chunks_fts, rowid, title, section_path, content)
                VALUES ('delete', old.id, old.title, old.section_path, old.content);
            END
            """)
        try db.execute(sql: """
            CREATE TRIGGER rag_chunks_au AFTER UPDATE ON rag_chunks BEGIN
                INSERT INTO rag_chunks_fts(rag_chunks_fts, rowid, title, section_path, content)
                VALUES ('delete', old.id, old.title, old.section_path, old.content);
                INSERT INTO rag_chunks_fts(rowid, title, section_path, content)
                VALUES (new.id, new.title, new.section_path, new.content);
            END
            """)

        try db.create(table: "rag_conversation_groups") { t in
            t.column("id", .text).primaryKey()
            t.column("title", .text).notNull()
            t.column("sort_order", .integer).notNull().defaults(to: 0)
            t.column("created_at", .text).notNull()
            t.column("updated_at", .text).notNull()
        }
        try db.create(
            index: "idx_rag_conversation_groups_sort",
            on: "rag_conversation_groups",
            columns: ["sort_order", "created_at"]
        )

        try db.create(table: "rag_conversations") { t in
            t.column("id", .text).primaryKey()
            t.column("title", .text).notNull()
            t.column("scope", .text).notNull().defaults(to: "knowledge")
            // 置顶排在列表最前；不改 updated_at，避免置顶本身影响「最近活跃」语义。
            t.column("is_pinned", .boolean).notNull().defaults(to: false)
            // 一级分组：NULL = 未分组；删除分组时会话回到未分组（ON DELETE SET NULL）。
            t.column("group_id", .text)
                .references("rag_conversation_groups", column: "id", onDelete: .setNull)
            // 语义摘要是可从原始消息重建的派生数据；coverage 用消息条数而非时间戳，
            // 使后续增量压缩能精确知道哪些旧消息已经进入摘要。
            t.column("context_summary", .text)
            t.column("context_summary_message_count", .integer).notNull().defaults(to: 0)
            t.column("created_at", .text).notNull()
            t.column("updated_at", .text).notNull()
        }
        try db.create(index: "idx_rag_conversations_updated", on: "rag_conversations", columns: ["updated_at"])
        try db.create(
            index: "idx_rag_conversations_pinned_updated",
            on: "rag_conversations",
            columns: ["is_pinned", "updated_at"]
        )
        try db.create(
            index: "idx_rag_conversations_group_updated",
            on: "rag_conversations",
            columns: ["group_id", "updated_at"]
        )

        try db.create(table: "rag_messages") { t in
            t.column("id", .text).primaryKey()
            t.column("conversation_id", .text).notNull()
                .references("rag_conversations", column: "id", onDelete: .cascade)
            t.column("role", .text).notNull()
            t.column("content", .text).notNull()
            t.column("model", .text)
            // 脱敏的用户可见执行轨迹：历史重开仍可核验本轮过程。
            t.column("execution_trace_json", .text)
            // 从用户提交到最终 LLM 流结束的秒数，供历史回答保留本轮处理耗时。
            t.column("processing_duration", .double)
            t.column("created_at", .text).notNull()
        }
        try db.create(index: "idx_rag_messages_conversation_created", on: "rag_messages", columns: ["conversation_id", "created_at"])

        try db.create(table: "rag_message_citations") { t in
            t.column("id", .text).primaryKey()
            t.column("message_id", .text).notNull()
                .references("rag_messages", column: "id", onDelete: .cascade)
            t.column("chunk_id", .integer)
                .references("rag_chunks", column: "id", onDelete: .setNull)
            t.column("repo_id", .integer).notNull()
                .references("repos", column: "id", onDelete: .cascade)
            t.column("repo_full_name", .text).notNull()
            // 与回答正文 `[S1]` 对齐；不能靠 rank+1 反推（引用可能跳号）。
            t.column("marker", .text).notNull().defaults(to: "")
            t.column("source", .text).notNull()
            t.column("section_title", .text).notNull().defaults(to: "")
            t.column("rank", .integer).notNull()
            t.column("score", .double).notNull()
            t.column("hit_kind", .text).notNull().defaults(to: "hybrid")
            // 融合分仅用于排序；单独保留原始向量分，避免 UI 把低量纲融合分误称为相关度。
            t.column("vector_similarity", .double)
            // 引用审计快照：同一分片在不同问题的排名与权重不同，必须随消息引用保存。
            t.column("score_breakdown_json", .text)
            t.column("source_url", .text)
            t.column("fetched_at", .text)
        }
        try db.create(index: "idx_rag_citations_message_rank", on: "rag_message_citations", columns: ["message_id", "rank"])
        try createRAGRemoteContextAuditSchema(db)
        try createRAGIndexRefreshSummarySchema(db)
    }

    /// GitHub 临时上下文不保存正文；历史只需要恢复“本轮查了什么、何时查、是否降级”。
    private static func createRAGRemoteContextAuditSchema(_ db: Database) throws {
        try db.create(table: "rag_message_remote_contexts") { t in
            t.column("id", .text).primaryKey()
            t.column("message_id", .text).notNull()
                .references("rag_messages", column: "id", onDelete: .cascade)
            t.column("repo_id", .integer).notNull()
                .references("repos", column: "id", onDelete: .cascade)
            t.column("resource", .text).notNull()
            t.column("title", .text).notNull()
            t.column("source_url", .text)
            t.column("fetched_at", .text).notNull()
            t.column("error_message", .text)
        }
        try db.create(index: "idx_rag_remote_contexts_message", on: "rag_message_remote_contexts", columns: ["message_id"])
    }

    /// 全库刷新摘要只服务当前用户数据库的 RAG Inspector；单行持久化使重启后仍能核验上次成功刷新。
    private static func createRAGIndexRefreshSummarySchema(_ db: Database) throws {
        try db.create(table: "rag_index_refresh_summary", ifNotExists: true) { t in
            t.column("id", .integer).primaryKey()
            t.column("total_repos", .integer).notNull()
            t.column("readmes_processed", .integer).notNull()
            t.column("source_repos_processed", .integer).notNull()
            t.column("embedding_processed", .integer).notNull()
            t.column("embedding_total", .integer).notNull()
            t.column("ready_chunks_before_embedding", .integer).notNull()
            t.column("total_chunks_at_embedding", .integer).notNull()
            t.column("completed_at", .text).notNull()
        }
    }

    /// `v7-knowledge-rag` 的整包幂等入口：无表则建最终形态；有开发期草稿则补齐列/附属表。
    ///
    /// 正式版升迁只走本函数（经 v7）；不再经启动期 `ensurePrelaunch*` 旁路。
    static func ensureKnowledgeRAGSchema(_ db: Database) throws {
        guard try db.tableExists("rag_chunks") else {
            try createRAGSchema(db)
            return
        }
        if try !db.tableExists("rag_message_remote_contexts") {
            try createRAGRemoteContextAuditSchema(db)
        }
        if try !db.tableExists("rag_index_refresh_summary") {
            try createRAGIndexRefreshSummarySchema(db)
        }
        if try !db.tableExists("rag_chunk_overrides") {
            try createRAGChunkOverrideSchema(db)
        }
        if try !db.tableExists("rag_chunk_tombstones") {
            try createRAGChunkTombstoneSchema(db)
        }
        // 旧草稿库已有 citations / messages / conversations 时不会重跑 createRAGSchema，在此补列。
        if try db.tableExists("rag_message_citations") {
            let citationColumns = try db.columns(in: "rag_message_citations").map(\.name)
            if !citationColumns.contains("marker") {
                try db.alter(table: "rag_message_citations") { t in
                    t.add(column: "marker", .text).notNull().defaults(to: "")
                }
            }
            if !citationColumns.contains("vector_similarity") {
                try db.alter(table: "rag_message_citations") { t in
                    t.add(column: "vector_similarity", .double)
                }
            }
            if !citationColumns.contains("score_breakdown_json") {
                try db.alter(table: "rag_message_citations") { t in
                    t.add(column: "score_breakdown_json", .text)
                }
            }
        }
        if try db.tableExists("rag_messages") {
            let messageColumns = try db.columns(in: "rag_messages").map(\.name)
            if !messageColumns.contains("execution_trace_json") {
                try db.alter(table: "rag_messages") { t in
                    t.add(column: "execution_trace_json", .text)
                }
            }
            if !messageColumns.contains("processing_duration") {
                try db.alter(table: "rag_messages") { t in
                    t.add(column: "processing_duration", .double)
                }
            }
        }
        // v5/v6 对「当时尚无表」的用户会 no-op；开发期旧表在此补 is_pinned / 分组 / 摘要列。
        if try db.tableExists("rag_conversations") {
            let columns = try db.columns(in: "rag_conversations").map(\.name)
            if !columns.contains("is_pinned") {
                try db.alter(table: "rag_conversations") { t in
                    t.add(column: "is_pinned", .boolean).notNull().defaults(to: false)
                }
            }
            if !columns.contains("context_summary") {
                try db.alter(table: "rag_conversations") { t in
                    t.add(column: "context_summary", .text)
                }
            }
            if !columns.contains("context_summary_message_count") {
                try db.alter(table: "rag_conversations") { t in
                    t.add(column: "context_summary_message_count", .integer).notNull().defaults(to: 0)
                }
            }
            let indexes = try db.indexes(on: "rag_conversations").map(\.name)
            if !indexes.contains("idx_rag_conversations_pinned_updated") {
                try db.create(
                    index: "idx_rag_conversations_pinned_updated",
                    on: "rag_conversations",
                    columns: ["is_pinned", "updated_at"]
                )
            }
            try ensureRAGConversationGroupsSchema(db)
        }
    }

    /// 幂等补齐 `pinned_at`：置顶区按「最后置顶时刻」降序，取消后清空。
    private static func ensureRAGConversationPinnedAtSchema(_ db: Database) throws {
        guard try db.tableExists("rag_conversations") else { return }
        let columns = try db.columns(in: "rag_conversations").map(\.name)
        if !columns.contains("pinned_at") {
            try db.alter(table: "rag_conversations") { t in
                t.add(column: "pinned_at", .text)
            }
            // 已置顶行用 updated_at 回填，避免升级后全部挤在同一 NULL 桶里顺序乱跳。
            try db.execute(sql: """
                UPDATE rag_conversations
                SET pinned_at = updated_at
                WHERE is_pinned = 1 AND pinned_at IS NULL
                """)
        }
        let indexes = try db.indexes(on: "rag_conversations").map(\.name)
        if !indexes.contains("idx_rag_conversations_pinned_at") {
            try db.create(
                index: "idx_rag_conversations_pinned_at",
                on: "rag_conversations",
                columns: ["is_pinned", "pinned_at"]
            )
        }
    }

    /// 幂等补齐一级会话分组表与 `group_id`（v6 / v7 共用）。
    private static func ensureRAGConversationGroupsSchema(_ db: Database) throws {
        if try !db.tableExists("rag_conversation_groups") {
            try db.create(table: "rag_conversation_groups") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }
            try db.create(
                index: "idx_rag_conversation_groups_sort",
                on: "rag_conversation_groups",
                columns: ["sort_order", "created_at"]
            )
        }

        guard try db.tableExists("rag_conversations") else { return }
        let columns = try db.columns(in: "rag_conversations").map(\.name)
        if !columns.contains("group_id") {
            try db.alter(table: "rag_conversations") { t in
                t.add(column: "group_id", .text)
                    .references("rag_conversation_groups", column: "id", onDelete: .setNull)
            }
        }
        let indexes = try db.indexes(on: "rag_conversations").map(\.name)
        if !indexes.contains("idx_rag_conversations_group_updated") {
            try db.create(
                index: "idx_rag_conversations_group_updated",
                on: "rag_conversations",
                columns: ["group_id", "updated_at"]
            )
        }
    }

    /// 人工编辑与删除不能直接依赖生成分片本身：README/摘要重建会覆写 `rag_chunks`。
    /// 覆盖层保留源内容与用户意图，重建时可继续投影到可检索分片。
    private static func createRAGChunkOverrideSchema(_ db: Database) throws {
        try db.create(table: "rag_chunk_overrides", ifNotExists: true) { t in
            t.column("chunk_id", .integer).primaryKey()
                .references("rag_chunks", column: "id", onDelete: .cascade)
            t.column("original_title", .text).notNull()
            t.column("original_section_path", .text).notNull()
            t.column("original_content", .text).notNull()
            t.column("override_title", .text)
            t.column("override_section_path", .text)
            t.column("override_content", .text)
            t.column("is_excluded", .boolean).notNull().defaults(to: false)
            t.column("updated_at", .text).notNull()
        }
    }

    /// 物理删除的分片不能只删 `rag_chunks`：README 下次重建会再次生成它。
    /// Tombstone 不设外键，才能在源分片已被删掉后仍保留用户“永不入库”的意图。
    private static func createRAGChunkTombstoneSchema(_ db: Database) throws {
        try db.create(table: "rag_chunk_tombstones", ifNotExists: true) { t in
            t.column("repo_id", .integer).notNull()
            t.column("source", .text).notNull()
            t.column("source_id", .text).notNull().defaults(to: "")
            t.column("chunk_key", .text).notNull()
            t.column("removed_at", .text).notNull()
            t.primaryKey(["repo_id", "source", "source_id", "chunk_key"])
        }
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
