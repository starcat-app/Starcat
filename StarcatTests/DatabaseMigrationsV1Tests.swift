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
            "rag_chunks", "rag_chunks_fts", "rag_conversation_groups",
            "rag_conversations", "rag_messages", "rag_message_citations",
            "rag_message_remote_contexts", "rag_metadata_revision"
        ]
        try db.read { db in
            for table in expectedTables {
                let exists = try db.tableExists(table)
                #expect(exists, "Table \(table) should exist")
            }
        }
    }

    @Test("知识库 RAG 应建出 chunk FTS 与同步触发器")
    func ragChunkFTSExists() throws {
        let db = try makeDB()
        try db.read { db in
            #expect(try db.tableExists("rag_chunks_fts"))
            let triggers = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' ORDER BY name"
            )
            #expect(triggers.contains("rag_chunks_ai"))
            #expect(triggers.contains("rag_chunks_ad"))
            #expect(triggers.contains("rag_chunks_au"))
        }
    }

    @Test("RAG v7-v12 应在已应用迁移列表中，并带上最终会话、索引列与快照修订表")
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
            #expect(try db.tableExists("rag_metadata_revision"))

            let chunkColumns = try db.columns(in: "rag_chunks").map(\.name)
            #expect(chunkColumns.contains("embedding_claim_id"))

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
