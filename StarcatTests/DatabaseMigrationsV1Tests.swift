//
//  DatabaseMigrationsV1Tests.swift
//  StarcatTests
//
//  验证 v1 schema：所有 P0 表均建出来、FTS5 触发器工作正常。
//

import Testing
import Foundation
import GRDB
@testable import Starcat

@Suite("Database Migration v1")
struct DatabaseMigrationsV1Tests {

    /// 创建一个全新的内存数据库，已应用 v1。
    private func makeDB() throws -> any DatabaseWriter {
        let mgr = try InMemoryDatabaseManager()
        return mgr.writer
    }

    @Test("全量迁移应建出所有 P0 表与知识库 RAG 表")
    func allTablesCreated() throws {
        let db = try makeDB()
        let expectedTables = [
            "repos", "starred_repos", "tags", "repo_tags",
            "repo_notes", "readmes", "saved_searches", "smart_collections",
            "sync_state", "tag_stats_cache", "open_ssf_scores",
            "repo_pins", "repo_insights_snapshots", "repo_star_history_points",
            "user_projects", "project_sync_state",
            "agent_runs", "agent_messages", "agent_approvals", "agent_artifacts",
            "rag_chunks", "rag_chunks_fts", "rag_conversation_groups",
            "rag_conversations", "rag_messages", "rag_message_citations",
            "rag_message_remote_contexts", "rag_metadata_revision",
            "data_contribution_preferences", "data_contribution_outbox"
        ]
        try db.read { db in
            for table in expectedTables {
                let exists = try db.tableExists(table)
                #expect(exists, "Table \(table) should exist")
            }
        }
    }

    @Test("Agent v19 应建立 message/approval/artifact 最终契约")
    func agentMessageContractMigrationCreatesSchema() throws {
        let writer = try makeDB()

        try writer.read { db in
            let runColumns = try db.columns(in: "agent_runs").map(\.name)
            #expect(runColumns.contains("context_json"))
            #expect(runColumns.contains("model"))
            #expect(runColumns.contains("usage_json"))

            let messageColumns = try db.columns(in: "agent_messages").map(\.name)
            #expect(messageColumns == [
                "id", "run_id", "role", "turn", "sequence",
                "parts_json", "usage_json", "created_at"
            ])

            let approvalColumns = try db.columns(in: "agent_approvals").map(\.name)
            #expect(approvalColumns == [
                "id", "run_id", "tool_call_id", "tool_name", "input_json",
                "permission", "sequence", "status", "created_at", "decided_at"
            ])

            let artifactColumns = try db.columns(in: "agent_artifacts").map(\.name)
            #expect(artifactColumns == [
                "id", "run_id", "tool_call_id", "message_id", "sequence",
                "type", "title", "content", "created_at"
            ])
            #expect(!artifactColumns.contains("artifact_index"))
        }
    }

    @Test("1.4.0 正式迁移应只保留单个 v19 标识")
    func release140MigrationUsesSingleFormalIdentifier() throws {
        let writer = try makeDB()
        try writer.read { db in
            var migrator = DatabaseMigrator()
            DatabaseMigrations.registerAll(into: &migrator)
            let applied = try migrator.appliedIdentifiers(db)
            let developmentIdentifiers: Set<String> = [
                "v19-agent-message-contract",
                "v20-rag-chunks-fts-trigram",
                "v21-github-notifications",
                "v22-github-notification-comments",
                "v23-github-notification-subject-created",
                "v24-user-repo-activity",
                "v25-user-repo-activity-actor",
                "v26-github-timeline-conversations",
            ]

            #expect(applied.contains("v19-release-1.4.0"))
            #expect(applied.isDisjoint(with: developmentIdentifiers))
        }
    }

    @Test("v20 应追加 Runtime trace 表且保持 run 级顺序唯一")
    func agentRuntimeTraceMigration() throws {
        let writer = try makeDB()
        try writer.read { db in
            var migrator = DatabaseMigrator()
            DatabaseMigrations.registerAll(into: &migrator)
            let applied = try migrator.appliedIdentifiers(db)
            #expect(applied.contains("v20-agent-runtime-trace"))
            #expect(try db.tableExists("agent_trace_events"))
            let columns = try db.columns(in: "agent_trace_events").map(\.name)
            #expect(columns == ["id", "run_id", "sequence", "event_json", "created_at", "updated_at"])
        }
    }

    @Test("v21 给通知会话追加 labels_json")
    func githubIssueLabelsMigration() throws {
        let writer = try makeDB()
        try writer.read { db in
            var migrator = DatabaseMigrator()
            DatabaseMigrations.registerAll(into: &migrator)
            let applied = try migrator.appliedIdentifiers(db)
            #expect(applied.contains("v21-github-issue-labels"))
            let columns = try db.columns(in: "github_notification_threads").map(\.name)
            #expect(columns.contains("labels_json"))
        }
    }

    @Test("v22 应创建账户级数据贡献设置与单槽 Outbox")
    func dataContributionMigration() throws {
        let writer = try makeDB()
        try writer.read { db in
            var migrator = DatabaseMigrator()
            DatabaseMigrations.registerAll(into: &migrator)
            let applied = try migrator.appliedIdentifiers(db)
            #expect(applied.contains("v22-data-contribution"))
            #expect(try db.tableExists("data_contribution_preferences"))
            #expect(try db.tableExists("data_contribution_outbox"))

            let preferenceColumns = try db.columns(in: "data_contribution_preferences").map(\.name)
            #expect(preferenceColumns == ["account_id", "is_enabled", "participant_id", "updated_at"])

            let outboxColumns = try db.columns(in: "data_contribution_outbox").map(\.name)
            #expect(outboxColumns == [
                "id", "account_id", "participant_id", "schema_version", "payload",
                "content_hash", "state", "attempt_count", "next_attempt_at",
                "created_at", "updated_at"
            ])
        }
    }

    @Test("v22 创建 Awesome 来源、订阅、条目和账户状态表")
    func awesomeDiscoveryMigration() throws {
        let writer = try makeDB()
        try writer.read { db in
            var migrator = DatabaseMigrator()
            DatabaseMigrations.registerAll(into: &migrator)
            let applied = try migrator.appliedIdentifiers(db)
            #expect(applied.contains("v22-awesome-discovery"))
            #expect(try db.tableExists("awesome_sources"))
            #expect(try db.tableExists("awesome_source_subscriptions"))
            #expect(try db.tableExists("awesome_entries"))
            #expect(try db.tableExists("awesome_state"))
            #expect(try db.columns(in: "awesome_entries").map(\.name).contains("repo_updated_at"))
            let state = try AwesomeStateRecord.fetchOne(db)
            #expect(state?.hasCompletedSourceSetup == false)
        }
    }

    @Test("1.4.0 正式迁移应接管任意开发期中间版本")
    func release140MigrationConvergesDevelopmentDatabases() throws {
        let developmentBoundaries = [
            "v19-agent-message-contract",
            "v23-github-notification-subject-created",
            "v26-github-timeline-conversations",
        ]
        let developmentIdentifiers: Set<String> = [
            "v19-agent-message-contract",
            "v20-rag-chunks-fts-trigram",
            "v21-github-notifications",
            "v22-github-notification-comments",
            "v23-github-notification-subject-created",
            "v24-user-repo-activity",
            "v25-user-repo-activity-actor",
            "v26-github-timeline-conversations",
        ]

        for boundary in developmentBoundaries {
            let queue = try DatabaseQueue()
            var releaseMigrator = DatabaseMigrator()
            DatabaseMigrations.registerAll(into: &releaseMigrator)
            try releaseMigrator.migrate(queue, upTo: "v18-rag-structured-citations")

            // 复现开发机可能停在 v19、v23 或 v26 的真实迁移账本，再交给正式 v19 收口。
            var developmentMigrator = DatabaseMigrator()
            DatabaseMigrations.registerRelease140DevelopmentMigrationsForTesting(
                into: &developmentMigrator
            )
            try developmentMigrator.migrate(queue, upTo: boundary)
            try releaseMigrator.migrate(queue)

            try queue.read { db in
                let applied = try releaseMigrator.appliedIdentifiers(db)
                #expect(applied.contains("v19-release-1.4.0"), "boundary=\(boundary)")
                #expect(applied.isDisjoint(with: developmentIdentifiers), "boundary=\(boundary)")
                #expect(try db.tableExists("agent_messages"), "boundary=\(boundary)")
                #expect(try db.tableExists("github_notification_threads"), "boundary=\(boundary)")
                #expect(try db.tableExists("user_repo_activity"), "boundary=\(boundary)")
                #expect(
                    try db.tableExists("github_organization_issue_sync_state"),
                    "boundary=\(boundary)"
                )
            }
        }
    }

    @Test("Agent v19 应保留旧 run/artifact 并明确归档旧事件表")
    func agentMessageContractMigrationPreservesLegacyData() throws {
        let queue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        DatabaseMigrations.registerAll(into: &migrator)
        try migrator.migrate(queue, upTo: "v18-rag-structured-citations")

        let runID = "00000000-0000-0000-0000-000000000101"
        let artifactID = "00000000-0000-0000-0000-000000000102"
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO agent_runs (
                        id, agent_id, title, user_prompt, context_source, status,
                        assistant_output, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    runID, "github-weekly-report", "Legacy Weekly", "生成旧周刊",
                    "Legacy Selection", "completed", "# Legacy Weekly",
                    "2026-07-07T00:00:00Z", "2026-07-07T00:01:00Z"
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO agent_run_steps (
                        id, run_id, step_index, title, detail, status, updated_at
                    ) VALUES ('legacy-step', ?, 0, 'Collect', 'Collected repos', 'completed', ?)
                    """,
                arguments: [runID, "2026-07-07T00:00:10Z"]
            )
            try db.execute(
                sql: """
                    INSERT INTO agent_run_traces (
                        id, run_id, trace_index, kind, title, summary, input, output,
                        log, status, created_at
                    ) VALUES (
                        'legacy-trace', ?, 0, 'tool', 'Build', 'Built report', '{}',
                        '{}', '', 'completed', ?
                    )
                    """,
                arguments: [runID, "2026-07-07T00:00:20Z"]
            )
            try db.execute(
                sql: """
                    INSERT INTO agent_run_tool_outputs (
                        id, run_id, output_index, tool_name, summary, detail, input,
                        output, log, created_at
                    ) VALUES (
                        'legacy-output', ?, 0, 'artifact_build_weekly_report',
                        'Built report', 'Legacy detail', '{}', '{}', '', ?
                    )
                    """,
                arguments: [runID, "2026-07-07T00:00:30Z"]
            )
            try db.execute(
                sql: """
                    INSERT INTO agent_artifacts (
                        id, run_id, artifact_index, type, title, content, created_at
                    ) VALUES (?, ?, 3, 'markdown', 'Legacy', '# Legacy', ?)
                    """,
                arguments: [artifactID, runID, "2026-07-07T00:00:40Z"]
            )
        }

        try migrator.migrate(queue)
        // 再次执行用于覆盖真实启动路径：已应用的 v19 不得重复搬运历史消息。
        try migrator.migrate(queue)

        try queue.read { db in
            let contextJSON: String = try String.fetchOne(
                db,
                sql: "SELECT context_json FROM agent_runs WHERE id = ?",
                arguments: [runID]
            )!
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let context = try decoder.decode(AgentRunContext.self, from: Data(contextJSON.utf8))
            #expect(context.sourceDescription == "Legacy Selection")

            let messageRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT role, sequence, parts_json
                    FROM agent_messages
                    WHERE run_id = ?
                    ORDER BY sequence
                    """,
                arguments: [runID]
            )
            #expect(messageRows.count == 2)
            #expect(messageRows.map { $0["role"] as String } == ["user", "assistant"])
            #expect(messageRows.map { $0["sequence"] as Int } == [0, 1])

            let userPartsJSON: String = messageRows[0]["parts_json"]
            let userParts = try JSONDecoder().decode([AgentMessagePart].self, from: Data(userPartsJSON.utf8))
            #expect(userParts == [.text("生成旧周刊")])

            let artifactRow = try Row.fetchOne(
                db,
                sql: "SELECT sequence, title, content FROM agent_artifacts WHERE id = ?",
                arguments: [artifactID]
            )
            let artifact = try #require(artifactRow)
            #expect(artifact["sequence"] as Int == 3)
            #expect(artifact["title"] as String == "Legacy")
            #expect(artifact["content"] as String == "# Legacy")

            #expect(try db.tableExists("agent_legacy_run_steps"))
            #expect(try db.tableExists("agent_legacy_run_traces"))
            #expect(try db.tableExists("agent_legacy_run_tool_outputs"))
            let hasOldSteps = try db.tableExists("agent_run_steps")
            let hasOldTraces = try db.tableExists("agent_run_traces")
            let hasOldToolOutputs = try db.tableExists("agent_run_tool_outputs")
            #expect(!hasOldSteps)
            #expect(!hasOldTraces)
            #expect(!hasOldToolOutputs)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agent_legacy_run_steps") == 1)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agent_legacy_run_traces") == 1)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agent_legacy_run_tool_outputs") == 1)
        }
    }

    @Test("RAG v18 应支持无仓库的结构化引用并保留历史引用")
    func structuredCitationMigrationPreservesHistory() throws {
        let queue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        DatabaseMigrations.registerAll(into: &migrator)
        try migrator.migrate(queue, upTo: "v17-my-projects")

        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO repos (id, owner, name, full_name, html_url)
                VALUES (42, 'octo', 'demo', 'octo/demo', 'https://github.com/octo/demo')
                """)
            try db.execute(sql: """
                INSERT INTO rag_conversations (id, title, created_at, updated_at)
                VALUES ('conversation-1', 'History', '2026-07-30T00:00:00Z', '2026-07-30T00:00:00Z')
                """)
            try db.execute(sql: """
                INSERT INTO rag_messages (id, conversation_id, role, content, created_at)
                VALUES ('message-1', 'conversation-1', 'assistant', 'Answer [S1]', '2026-07-30T00:00:00Z')
                """)
            try db.execute(sql: """
                INSERT INTO rag_message_citations (
                    id, message_id, repo_id, repo_full_name, marker, source,
                    section_title, rank, score, hit_kind
                ) VALUES (
                    'citation-1', 'message-1', 42, 'octo/demo', 'S1', 'readme',
                    'README', 0, 0.8, 'keyword'
                )
                """)
        }

        try migrator.migrate(queue)

        try queue.write { db in
            let applied = try migrator.appliedMigrations(db)
            #expect(applied.contains("v18-rag-structured-citations"))
            let columns = try db.columns(in: "rag_message_citations").map(\.name)
            #expect(columns.contains("evidence_content"))
            let repoIDIsNotNull = try Int.fetchOne(
                db,
                sql: """
                    SELECT "notnull"
                    FROM pragma_table_info('rag_message_citations')
                    WHERE name = 'repo_id'
                    """
            )
            #expect(repoIDIsNotNull == 0)
            #expect(
                try String.fetchOne(
                    db,
                    sql: "SELECT repo_full_name FROM rag_message_citations WHERE id = 'citation-1'"
                ) == "octo/demo"
            )

            try db.execute(sql: """
                INSERT INTO rag_message_citations (
                    id, message_id, repo_id, repo_full_name, marker, source,
                    section_title, rank, score, hit_kind, evidence_content
                ) VALUES (
                    'citation-2', 'message-1', NULL, '', 'S2', 'knowledge_base_metadata',
                    'scope', 1, 1, 'structured', '- 1878 in-library repositories.'
                )
                """)
            try db.execute(sql: "DELETE FROM repos WHERE id = 42")

            #expect(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM rag_message_citations WHERE message_id = 'message-1'"
                ) == 2
            )
            #expect(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM rag_message_citations WHERE repo_id IS NULL"
                ) == 2
            )
            #expect(
                try String.fetchOne(
                    db,
                    sql: "SELECT evidence_content FROM rag_message_citations WHERE id = 'citation-2'"
                ) == "- 1878 in-library repositories."
            )
        }
    }

    @Test("我的项目 v17 应建立关系表、同步状态表和查询索引")
    func myProjectsMigrationCreatesTables() throws {
        let writer = try makeDB()
        try writer.read { db in
            var migrator = DatabaseMigrator()
            DatabaseMigrations.registerAll(into: &migrator)
            let applied = try migrator.appliedMigrations(db)
            #expect(applied.contains("v17-my-projects"))

            #expect(
                try db.columns(in: "user_projects").map(\.name) == [
                    "user_id", "repo_id", "affiliation", "owner_login", "owner_type",
                    "visibility", "permission", "authorization_source", "installation_id",
                    "generation", "last_seen_at", "created_at", "updated_at"
                ]
            )
            #expect(
                try db.columns(in: "project_sync_state").map(\.name) == [
                    "user_id", "credential_kind", "affiliation", "etag", "generation",
                    "last_attempt_at", "last_success_at", "sync_status", "error_code", "updated_at"
                ]
            )

            let indexes = try String.fetchAll(
                db,
                sql: """
                    SELECT name FROM sqlite_master
                    WHERE type = 'index'
                      AND tbl_name IN ('user_projects', 'project_sync_state')
                    """
            )
            #expect(indexes.contains("idx_user_projects_user_affiliation"))
            #expect(indexes.contains("idx_user_projects_user_owner"))
            #expect(indexes.contains("idx_user_projects_user_visibility"))
            #expect(indexes.contains("idx_user_projects_user_permission"))
            #expect(indexes.contains("idx_user_projects_user_generation"))
            #expect(indexes.contains("idx_project_sync_state_status"))
        }
    }

    @Test("v16 升级 v17 应保留 Repo、笔记、Star 历史和置顶")
    func myProjectsMigrationPreservesExistingData() throws {
        let queue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        DatabaseMigrations.registerAll(into: &migrator)
        try migrator.migrate(queue, upTo: "v16-repository-insights")

        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO repos (
                    id, owner, name, full_name, html_url, stars_count, is_starred
                ) VALUES (
                    188, 'octo', 'kept-project', 'octo/kept-project',
                    'https://github.com/octo/kept-project', 456, 1
                )
                """)
            try db.execute(sql: """
                INSERT INTO repo_notes (repo_id, content, status, library_state, is_ai_generated)
                VALUES (188, 'keep this note', 'using', 'in_library', 0)
                """)
            try db.execute(sql: """
                INSERT INTO repo_pins (repo_id, pinned_at)
                VALUES (188, 1000)
                """)
            try db.execute(sql: """
                INSERT INTO repo_star_history_points (
                    repo_id, observed_on, stars_count, source, precision, fetched_at
                ) VALUES (
                    188, '2026-07-29', 456, 'local_snapshot', 'snapshot', '2026-07-29T00:00:00Z'
                )
                """)
        }

        try migrator.migrate(queue)

        try queue.read { db in
            let isStarred = try Bool.fetchOne(db, sql: "SELECT is_starred FROM repos WHERE id = 188")
            let note = try String.fetchOne(db, sql: "SELECT content FROM repo_notes WHERE repo_id = 188")
            let pinCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM repo_pins WHERE repo_id = 188")
            let starsCount = try Int.fetchOne(
                db,
                sql: "SELECT stars_count FROM repo_star_history_points WHERE repo_id = 188"
            )
            let hasUserProjects = try db.tableExists("user_projects")
            let hasProjectSyncState = try db.tableExists("project_sync_state")

            #expect(isStarred == true)
            #expect(note == "keep this note")
            #expect(pinCount == 1)
            #expect(starsCount == 456)
            #expect(hasUserProjects)
            #expect(hasProjectSyncState)
        }
    }

    @Test("删除 Repo 只应级联项目关系，不删除同步状态")
    func myProjectsRelationCascadesWithRepo() throws {
        let writer = try makeDB()
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO repos (id, owner, name, full_name, html_url)
                VALUES (289, 'octo', 'project', 'octo/project', 'https://github.com/octo/project')
                """)
            try db.execute(sql: """
                INSERT INTO user_projects (
                    user_id, repo_id, affiliation, owner_login, owner_type, visibility,
                    permission, authorization_source, generation, last_seen_at, created_at, updated_at
                ) VALUES (
                    7, 289, 'owner', 'octo', 'user', 'private',
                    'admin', 'github_app', 'g1',
                    '2026-07-29T00:00:00Z', '2026-07-29T00:00:00Z', '2026-07-29T00:00:00Z'
                )
                """)
            try db.execute(sql: """
                INSERT INTO project_sync_state (
                    user_id, credential_kind, affiliation, sync_status, updated_at
                ) VALUES (
                    7, 'github_app', 'owner', 'idle', '2026-07-29T00:00:00Z'
                )
                """)

            try db.execute(sql: "DELETE FROM repos WHERE id = 289")

            let projectCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM user_projects")
            let syncStateCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM project_sync_state")
            #expect(projectCount == 0)
            #expect(syncStateCount == 1)
        }
    }

    @Test("仓库洞察 v16 应建立两张独立缓存表并支持重复迁移")
    func repositoryInsightsMigrationCreatesTables() throws {
        let writer = try makeDB()
        var migrator = DatabaseMigrator()
        DatabaseMigrations.registerAll(into: &migrator)
        try migrator.migrate(writer)

        try writer.read { db in
            let applied = try migrator.appliedMigrations(db)
            #expect(applied.contains("v16-repository-insights"))

            #expect(
                try db.columns(in: "repo_insights_snapshots").map(\.name) == [
                    "repo_id", "dataset", "range_key", "payload_json",
                    "default_branch_sha", "fetched_at", "stale_after", "response_etag"
                ]
            )
            #expect(
                try db.columns(in: "repo_star_history_points").map(\.name) == [
                    "repo_id", "observed_on", "stars_count", "source", "precision", "fetched_at"
                ]
            )

            let indexes = try String.fetchAll(
                db,
                sql: """
                    SELECT name FROM sqlite_master
                    WHERE type = 'index'
                      AND tbl_name IN ('repo_insights_snapshots', 'repo_star_history_points')
                    """
            )
            #expect(indexes.contains("idx_repo_insights_snapshots_stale"))
            #expect(indexes.contains("idx_repo_star_history_points_lookup"))
        }
    }

    @Test("v15 升级 v16 不改变既有仓库与用户数据")
    func repositoryInsightsMigrationPreservesExistingData() throws {
        let queue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        DatabaseMigrations.registerAll(into: &migrator)
        try migrator.migrate(queue, upTo: "v15-repo-pins")

        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO repos (id, owner, name, full_name, html_url, stars_count, is_starred)
                VALUES (88, 'octo', 'kept', 'octo/kept', 'https://github.com/octo/kept', 321, 1)
                """)
            try db.execute(sql: """
                INSERT INTO repo_notes (repo_id, content, status, library_state, is_ai_generated)
                VALUES (88, 'private note', 'using', 'in_library', 0)
                """)
        }

        try migrator.migrate(queue)

        try queue.read { db in
            let fullName = try String.fetchOne(
                db,
                sql: "SELECT full_name FROM repos WHERE id = 88"
            )
            let note = try String.fetchOne(
                db,
                sql: "SELECT content FROM repo_notes WHERE repo_id = 88"
            )
            let hasInsights = try db.tableExists("repo_insights_snapshots")
            let hasStarHistory = try db.tableExists("repo_star_history_points")
            #expect(fullName == "octo/kept")
            #expect(note == "private note")
            #expect(hasInsights)
            #expect(hasStarHistory)
        }
    }

    @Test("删除仓库应级联清理洞察缓存且 Star 数量不可为负")
    func repositoryInsightsCachesCascadeWithRepo() throws {
        let writer = try makeDB()
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO repos (id, owner, name, full_name, html_url)
                VALUES (99, 'octo', 'cache', 'octo/cache', 'https://github.com/octo/cache')
                """)
            try db.execute(
                sql: """
                    INSERT INTO repo_insights_snapshots (
                        repo_id, dataset, range_key, payload_json, fetched_at, stale_after
                    ) VALUES (?, 'contributors', 'all', ?, '2026-07-27', '2026-07-28')
                    """,
                arguments: [99, Data("{}".utf8)]
            )
            try db.execute(sql: """
                INSERT INTO repo_star_history_points (
                    repo_id, observed_on, stars_count, source, precision, fetched_at
                ) VALUES (99, '2026-07-27', 10, 'local_snapshot', 'snapshot', '2026-07-27')
                """)
            #expect(throws: (any Error).self) {
                try db.execute(sql: """
                    INSERT INTO repo_star_history_points (
                        repo_id, observed_on, stars_count, source, precision, fetched_at
                    ) VALUES (99, '2026-07-26', -1, 'local_snapshot', 'snapshot', '2026-07-27')
                    """)
            }
            try db.execute(sql: "DELETE FROM repos WHERE id = 99")

            let insightsCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM repo_insights_snapshots"
            )
            let historyCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM repo_star_history_points"
            )
            #expect(insightsCount == 0)
            #expect(historyCount == 0)
        }
    }

    @Test("Repo Pin v15 应建立独立用户状态表与时间索引")
    func repoPinMigrationCreatesTable() throws {
        let db = try makeDB()
        try db.read { db in
            var migrator = DatabaseMigrator()
            DatabaseMigrations.registerAll(into: &migrator)
            let applied = try migrator.appliedMigrations(db)
            #expect(applied.contains("v15-repo-pins"))

            let columns = try db.columns(in: "repo_pins").map(\.name)
            #expect(columns == ["repo_id", "pinned_at"])

            let indexes = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'repo_pins'"
            )
            #expect(indexes.contains("idx_repo_pins_pinned_at"))
        }
    }

    @Test("知识库 RAG 应建出 chunk FTS 与同步触发器")
    func ragChunkFTSExists() throws {
        let db = try makeDB()
        try db.read { db in
            #expect(try db.tableExists("rag_chunks_fts"))
            let sql = try String.fetchOne(
                db,
                sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'rag_chunks_fts'"
            )
            #expect(sql?.contains("tokenize='trigram'") == true)
            #expect(sql?.contains("unicode61") != true)
            let triggers = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' ORDER BY name"
            )
            #expect(triggers.contains("rag_chunks_ai"))
            #expect(triggers.contains("rag_chunks_ad"))
            #expect(triggers.contains("rag_chunks_au"))
        }
    }

    @Test("正式 v19 重建 rag_chunks_fts 后中文子串与英文身份词都能 MATCH")
    func ragChunkFTSTrigramMatchesCJKSubstringAndRebuildsExistingRows() throws {
        let queue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        DatabaseMigrations.registerAll(into: &migrator)
        try migrator.migrate(queue, upTo: "v18-rag-structured-citations")

        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO repos (id, owner, name, full_name, html_url)
                VALUES (30, 'starcat-app', 'Starcat', 'starcat-app/Starcat', 'https://github.com/starcat-app/Starcat')
                """)
            try db.execute(sql: """
                INSERT INTO rag_chunks (
                    repo_id, source, source_id, parent_type, parent_key, parent_title, chunk_key,
                    chunk_index, section_path, title, content, content_hash, token_count, is_truncated,
                    embedding_status, created_at, updated_at
                ) VALUES (
                    30, 'readme', '', 'readme', 'readme', 'README', 'readme:0',
                    0, '', 'README',
                    'Starcat 把 GitHub Star 整理成可搜索知识库。试过部署失败 已切到别的方案。',
                    'readme-starcat', 24, 0, 'ready', datetime('now'), datetime('now')
                )
                """)
        }

        try queue.read { db in
            let sql = try String.fetchOne(
                db,
                sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'rag_chunks_fts'"
            )
            #expect(sql?.contains("unicode61") == true)
        }

        try migrator.migrate(queue)

        try queue.read { db in
            let sql = try String.fetchOne(
                db,
                sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'rag_chunks_fts'"
            )
            #expect(sql?.contains("tokenize='trigram'") == true)

            let chineseQuery = RAGKeywordQueryBuilder.build(
                keywordQueries: ["部署失败"],
                semanticQuery: ""
            ).sqliteFTS5Expression
            let chineseHits = try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM rag_chunks_fts WHERE rag_chunks_fts MATCH ?",
                arguments: [chineseQuery]
            )
            #expect(chineseHits == 1, "trigram 应命中中文中缀，表达式=\(chineseQuery)")

            let identityQuery = RAGKeywordQueryBuilder.build(
                keywordQueries: ["starcat"],
                semanticQuery: ""
            ).sqliteFTS5Expression
            let identityHits = try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM rag_chunks_fts WHERE rag_chunks_fts MATCH ?",
                arguments: [identityQuery]
            )
            #expect(identityHits == 1, "trigram 应命中英文身份词，表达式=\(identityQuery)")

            let shortHits = try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM rag_chunks_fts WHERE rag_chunks_fts MATCH ?",
                arguments: ["\"AI\"*"]
            )
            #expect(shortHits == 0, "不足 3 字符的 trigram MATCH 必须为空")
        }
    }

    @Test("RAG v7-v12 与 Weekly v13 应在迁移列表中并具备最终列")
    func knowledgeRAGMigrationSealed() throws {
        let db = try makeDB()
        try db.read { db in
            var migrator = DatabaseMigrator()
            DatabaseMigrations.registerAll(into: &migrator)
            let applied = try migrator.appliedMigrations(db)
            #expect(applied.contains("v7-knowledge-rag"))
            #expect(applied.contains("v8-rag-suggested-actions"))
            #expect(applied.contains("v9-rag-metadata-keyword-only"))
            #expect(applied.contains("v10-rag-conversation-pinned-at"))
            #expect(applied.contains("v11-rag-embedding-claim"))
            #expect(applied.contains("v12-rag-metadata-revision"))
            #expect(applied.contains("v13-weekly-multi-source"))
            #expect(applied.contains("v19-release-1.4.0"))
            #expect(try db.tableExists("rag_metadata_revision"))

            let chunkColumns = try db.columns(in: "rag_chunks").map(\.name)
            #expect(chunkColumns.contains("embedding_claim_id"))

            let weeklyColumns = try db.columns(in: "weekly_bulk_repos").map(\.name)
            #expect(weeklyColumns.contains("source_entries_json"))
            #expect(weeklyColumns.contains("is_pinned"))
            #expect(weeklyColumns.contains("pin_position"))
            #expect(try db.tableExists("weekly_bulk_sources"))

            let conversationColumns = try db.columns(in: "rag_conversations").map(\.name)
            #expect(conversationColumns.contains("is_pinned"))
            #expect(conversationColumns.contains("pinned_at"))
            #expect(conversationColumns.contains("group_id"))
            #expect(conversationColumns.contains("context_summary"))
            #expect(conversationColumns.contains("context_summary_message_count"))

            let messageColumns = try db.columns(in: "rag_messages").map(\.name)
            #expect(messageColumns.contains("execution_trace_json"))
            #expect(messageColumns.contains("processing_duration"))
            #expect(messageColumns.contains("suggested_actions_json"))
        }
    }

    @Test("RAG 元数据修订号与相关写事务一起提交或回滚")
    func ragMetadataRevisionTracksCommittedWrites() throws {
        let writer = try makeDB()
        let initial = try writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT revision FROM rag_metadata_revision WHERE id = 1")!
        }
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO repos (id, owner, name, full_name, html_url)
                VALUES (991, 'octo', 'revision', 'octo/revision', 'https://github.com/octo/revision')
                """)
        }
        let committed = try writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT revision FROM rag_metadata_revision WHERE id = 1")!
        }
        #expect(committed > initial)

        do {
            try writer.write { db in
                try db.execute(sql: "UPDATE repos SET stars_count = 99 WHERE id = 991")
                throw CancellationError()
            }
        } catch is CancellationError {
            // 预期回滚；修订号必须和业务数据保持同一事务语义。
        }
        let rolledBack = try writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT revision FROM rag_metadata_revision WHERE id = 1")!
        }
        #expect(rolledBack == committed)
    }

    @Test("ensureKnowledgeRAGSchema 对旧草稿会话表应幂等补齐最终列")
    func knowledgeRAGUpgradesLegacyConversationDraft() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: """
                CREATE TABLE repos (
                    id INTEGER PRIMARY KEY,
                    owner TEXT NOT NULL,
                    name TEXT NOT NULL,
                    full_name TEXT NOT NULL,
                    html_url TEXT NOT NULL
                )
                """)
            // 模拟开发早期、尚无 pin/group/摘要列、也无附属审计表的草稿。
            try db.execute(sql: """
                CREATE TABLE rag_chunks (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    repo_id INTEGER NOT NULL REFERENCES repos(id) ON DELETE CASCADE,
                    source TEXT NOT NULL,
                    source_id TEXT NOT NULL DEFAULT '',
                    parent_type TEXT NOT NULL DEFAULT 'repo',
                    parent_key TEXT NOT NULL,
                    parent_title TEXT NOT NULL DEFAULT '',
                    chunk_key TEXT NOT NULL,
                    chunk_index INTEGER NOT NULL,
                    section_path TEXT NOT NULL DEFAULT '',
                    title TEXT NOT NULL DEFAULT '',
                    content TEXT NOT NULL,
                    content_hash TEXT NOT NULL,
                    token_count INTEGER NOT NULL,
                    is_truncated INTEGER NOT NULL DEFAULT 0,
                    embedding_status TEXT NOT NULL DEFAULT 'pending',
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE rag_conversations (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    scope TEXT NOT NULL DEFAULT 'knowledge',
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE rag_messages (
                    id TEXT PRIMARY KEY,
                    conversation_id TEXT NOT NULL
                        REFERENCES rag_conversations(id) ON DELETE CASCADE,
                    role TEXT NOT NULL,
                    content TEXT NOT NULL,
                    created_at TEXT NOT NULL
                )
                """)
            try DatabaseMigrations.ensureKnowledgeRAGSchema(db)

            let conversationColumns = try db.columns(in: "rag_conversations").map(\.name)
            #expect(conversationColumns.contains("is_pinned"))
            // `pinned_at` 属于 v10，v7 的封存 schema helper 不得旁路补入未来版本字段。
            #expect(!conversationColumns.contains("pinned_at"))
            #expect(conversationColumns.contains("group_id"))
            #expect(conversationColumns.contains("context_summary"))
            #expect(conversationColumns.contains("context_summary_message_count"))

            let messageColumns = try db.columns(in: "rag_messages").map(\.name)
            #expect(messageColumns.contains("execution_trace_json"))
            #expect(messageColumns.contains("processing_duration"))

            #expect(try db.tableExists("rag_conversation_groups"))
            #expect(try db.tableExists("rag_message_remote_contexts"))
            #expect(try db.tableExists("rag_index_refresh_summary"))
            #expect(try db.tableExists("rag_chunk_overrides"))
            #expect(try db.tableExists("rag_chunk_tombstones"))
        }
    }

    @Test("v1 应建出 repos_fts 虚拟表与触发器")
    func ftsExists() throws {
        let db = try makeDB()
        try db.read { db in
            let ftsExists = try db.tableExists("repos_fts")
            #expect(ftsExists, "repos_fts virtual table should exist")

            // 检查触发器
            let triggers = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' ORDER BY name"
            )
            #expect(triggers.contains("repos_ai"))
            #expect(triggers.contains("repos_ad"))
            #expect(triggers.contains("repos_au"))
        }
    }

    @Test("insert repo 后 FTS 应可搜到")
    func ftsInsertAndSearch() throws {
        let db = try makeDB()
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO repos (id, owner, name, full_name, description, language, html_url)
                VALUES (1, 'alice', 'cool-lib', 'alice/cool-lib', '一个测试用的酷库', 'Swift', 'https://github.com/alice/cool-lib')
                """)
        }
        try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT rowid FROM repos_fts WHERE repos_fts MATCH ?",
                arguments: ["cool"]
            )
            #expect(rows.count == 1)
            #expect(rows.first?["rowid"] as Int64? == 1)
        }
    }

    @Test("delete repo 后 FTS 索引应同步清理")
    func ftsDeleteCleansIndex() throws {
        let db = try makeDB()
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO repos (id, owner, name, full_name, description, language, html_url)
                VALUES (2, 'bob', 'tmp', 'bob/tmp', 'temporary', 'Go', 'https://github.com/bob/tmp')
                """)
            try db.execute(sql: "DELETE FROM repos WHERE id = 2")
        }
        try db.read { db in
            let count = try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM repos_fts WHERE repos_fts MATCH ?",
                arguments: ["tmp"]
            )
            #expect(count == 0)
        }
    }

    @Test("v1 应建出 notes_fts 虚拟表与触发器")
    func notesFtsExists() throws {
        let db = try makeDB()
        try db.read { db in
            let ftsExists = try db.tableExists("notes_fts")
            #expect(ftsExists, "notes_fts virtual table should exist")

            let triggers = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' ORDER BY name"
            )
            #expect(triggers.contains("repo_notes_ai"))
            #expect(triggers.contains("repo_notes_ad"))
            #expect(triggers.contains("repo_notes_au"))
        }
    }

    @Test("repo_notes 应包含知识库状态列")
    func repoNotesLibraryColumnsCreated() throws {
        let db = try makeDB()
        try db.read { db in
            let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(repo_notes)")
            let names = cols.compactMap { $0["name"] as String? }

            #expect(names.contains("library_state"))
            #expect(names.contains("library_updated_at"))

            let libraryState = try #require(cols.first { ($0["name"] as String?) == "library_state" })
            #expect(libraryState["notnull"] as Int == 1)
            #expect(libraryState["dflt_value"] as String? == "'outside_library'")
        }
    }

    @Test("repos 应包含远程访问状态列")
    func reposAccessStateColumnsCreated() throws {
        let db = try makeDB()
        try db.read { db in
            let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(repos)")
            let names = cols.compactMap { $0["name"] as String? }

            #expect(names.contains("access_state"))
            #expect(names.contains("access_reason"))
            #expect(names.contains("access_checked_at"))

            let accessState = try #require(cols.first { ($0["name"] as String?) == "access_state" })
            #expect(accessState["notnull"] as Int == 1)
            #expect(accessState["dflt_value"] as String? == "'accessible'")
        }
    }

    @Test("插入 repo_notes 后 notes_fts 应可搜到，且 status 变化不重建索引")
    func notesFtsInsertAndStatusUpdate() throws {
        let db = try makeDB()
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO repos (id, owner, name, full_name, html_url)
                VALUES (10, 'alice', 'r10', 'alice/r10', 'https://github.com/alice/r10')
                """)
            try db.execute(sql: """
                INSERT INTO repo_notes (repo_id, content, status)
                VALUES (10, '试过部署失败 已切到别的方案', 'unread')
                """)
        }
        try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT rowid FROM notes_fts WHERE notes_fts MATCH ?",
                arguments: ["部署失败"]
            )
            #expect(rows.count == 1)
            #expect(rows.first?["rowid"] as Int64? == 10)
        }

        // status 变化不应触发索引重建（WHEN OLD.content IS NOT NEW.content 守门）。
        // 这里只能验证更新后仍能搜到——索引重建是无副作用的，但 trigger fired 次数无法直接断言；
        // 退一步：确保 status 改变后索引仍正确。
        try db.write { db in
            try db.execute(sql: """
                UPDATE repo_notes SET status = 'read' WHERE repo_id = 10
                """)
        }
        try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT rowid FROM notes_fts WHERE notes_fts MATCH ?",
                arguments: ["部署失败"]
            )
            #expect(rows.count == 1, "status 改变后笔记仍应能被搜到")
        }
    }

    @Test("delete repo_notes 后 notes_fts 索引应同步清理")
    func notesFtsDeleteCleansIndex() throws {
        let db = try makeDB()
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO repos (id, owner, name, full_name, html_url)
                VALUES (11, 'bob', 'r11', 'bob/r11', 'https://github.com/bob/r11')
                """)
            try db.execute(sql: """
                INSERT INTO repo_notes (repo_id, content, status)
                VALUES (11, 'kubernetes 部署笔记', 'unread')
                """)
            try db.execute(sql: "DELETE FROM repo_notes WHERE repo_id = 11")
        }
        try db.read { db in
            let count = try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM notes_fts WHERE notes_fts MATCH ?",
                arguments: ["kubernetes"]
            )
            #expect(count == 0)
        }
    }

    @Test("repos_fts 应索引 full_name，单独搜 owner 能命中")
    func ftsFullNameOwnerMatch() throws {
        let db = try makeDB()
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO repos (id, owner, name, full_name, html_url)
                VALUES (20, 'colbymchenry', 'codegraph', 'colbymchenry/codegraph', 'https://github.com/colbymchenry/codegraph')
                """)
        }
        try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT rowid FROM repos_fts WHERE repos_fts MATCH ?",
                arguments: ["colbymchenry"]
            )
            #expect(rows.count == 1, "full_name 列应让 owner-only 搜索命中")
            #expect(rows.first?["rowid"] as Int64? == 20)
        }
    }

    @Test("foreign_keys 已启用，删除 repo 应级联清理 repo_notes")
    func foreignKeyCascade() throws {
        let db = try makeDB()
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO repos (id, owner, name, full_name, html_url)
                VALUES (3, 'carol', 'r', 'carol/r', 'https://github.com/carol/r')
                """)
            try db.execute(sql: """
                INSERT INTO repo_notes (repo_id, content, status)
                VALUES (3, 'note', 'unread')
                """)
            try db.execute(sql: "DELETE FROM repos WHERE id = 3")
        }
        try db.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM repo_notes WHERE repo_id = 3")
            #expect(count == 0, "repo_notes should cascade delete")
        }
    }

    // MARK: - v3 性能索引（HOM-46，2026-06-02）

    @Test("v3：复合索引 (is_starred, starred_at) 与 (is_starred, language, starred_at) 已建立")
    func v3PerfIndexesCreated() throws {
        let db = try makeDB()
        try db.read { db in
            // 查 SQLite 元表，确认两个性能索引都已建出
            let indexes = try String.fetchAll(
                db,
                sql: """
                    SELECT name FROM sqlite_master
                    WHERE type = 'index' AND tbl_name = 'repos'
                    ORDER BY name
                    """
            )
            #expect(indexes.contains("idx_repos_is_starred_starred_at"),
                    "v3 should create composite index for (is_starred, starred_at)")
            #expect(indexes.contains("idx_repos_is_starred_language_starred_at"),
                    "v3 should create composite index for (is_starred, language, starred_at)")
        }
    }

    // MARK: - v8 StarcatRepoCardDTO 4 字段消化（R-01 v1.2，2026-06-10）

    @Test("v8：repos 表新增 4 列（owner_avatar / subscribers_count / default_branch / open_issues_count）")
    func v8ReposNewColumnsCreated() throws {
        let db = try makeDB()
        try db.read { db in
            let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(repos)")
            let names = cols.compactMap { $0["name"] as String? }
            #expect(names.contains("owner_avatar"))
            #expect(names.contains("subscribers_count"))
            #expect(names.contains("default_branch"))
            #expect(names.contains("open_issues_count"))
        }
    }

    @Test("v8：trending_repos 表新增同名 4 列")
    func v8TrendingReposNewColumnsCreated() throws {
        let db = try makeDB()
        try db.read { db in
            let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(trending_repos)")
            let names = cols.compactMap { $0["name"] as String? }
            #expect(names.contains("owner_avatar"))
            #expect(names.contains("subscribers_count"))
            #expect(names.contains("default_branch"))
            #expect(names.contains("open_issues_count"))
        }
    }

    @Test("v8：往 repos 表写入 4 字段后能正确读出（GRDB ↔ schema 字段对齐）")
    func v8ReposRoundTripNewColumns() throws {
        let db = try makeDB()
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO repos (
                    id, owner, name, full_name, html_url,
                    owner_avatar, subscribers_count, default_branch, open_issues_count
                ) VALUES (
                    100, 'foo', 'bar', 'foo/bar', 'https://github.com/foo/bar',
                    'https://avatars.githubusercontent.com/foo.png', 42, 'main', 7
                )
                """)
        }
        try db.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT * FROM repos WHERE id = 100")
            #expect(row?["owner_avatar"] as String? == "https://avatars.githubusercontent.com/foo.png")
            #expect(row?["subscribers_count"] as Int? == 42)
            #expect(row?["default_branch"] as String? == "main")
            #expect(row?["open_issues_count"] as Int? == 7)
        }
    }

    // MARK: - v26 组织 Issue 统一时间线（2026-08-21）

    @Test("正式 v19：通知会话扩展来源字段并创建组织分页状态表")
    func v26TimelineConversationColumnsCreated() throws {
        let db = try makeDB()
        try db.read { db in
            let columns = try db.columns(in: "github_notification_threads").map(\.name)
            #expect(columns.contains("notification_thread_id"))
            #expect(columns.contains("source_kind"))
            #expect(columns.contains("organization_login"))
            #expect(columns.contains("credential_source"))
            #expect(columns.contains("issue_state"))
            #expect(try db.tableExists("github_organization_issue_sync_state"))
        }
    }

    @Test("v3：fetchAllStarred 类查询能用上新复合索引（query plan 验证）")
    func v3IndexUsedByQueryPlan() throws {
        let db = try makeDB()
        // EXPLAIN QUERY PLAN 返回的 detail 列里包含 "USING INDEX <name>" 这样的描述。
        // 空表也能拿到 plan，足够验证 planner 把索引选进来。
        try db.read { db in
            let plans = try Row.fetchAll(
                db,
                sql: """
                    EXPLAIN QUERY PLAN
                    SELECT * FROM repos WHERE is_starred = 1 ORDER BY starred_at DESC
                    """
            )
            let details = plans.compactMap { $0["detail"] as String? }.joined(separator: " | ")
            #expect(details.contains("idx_repos_is_starred_starred_at"),
                    "WHERE is_starred=1 ORDER BY starred_at DESC 应该走 idx_repos_is_starred_starred_at，实际计划：\(details)")
        }
    }
}
