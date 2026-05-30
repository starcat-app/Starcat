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

    @Test("v1 迁移应建出所有 P0 表")
    func allTablesCreated() throws {
        let db = try makeDB()
        let expectedTables = [
            "repos", "starred_repos", "tags", "repo_tags",
            "repo_notes", "readmes", "saved_searches",
            "sync_state", "tag_stats_cache"
        ]
        try db.read { db in
            for table in expectedTables {
                let exists = try db.tableExists(table)
                #expect(exists, "Table \(table) should exist")
            }
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
}
