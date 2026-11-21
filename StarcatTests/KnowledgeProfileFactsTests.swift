//
//  KnowledgeProfileFactsTests.swift
//  StarcatTests
//
//  #210 交接样本。旧账号升级、真实写入、冻结年报和洞察复用同一组仓库。
//

import Foundation
import GRDB
import Testing
@testable import Starcat

@Suite("知识画像与年度事实")
struct KnowledgeProfileFactsTests {
    private func date(_ text: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: text))
    }

    @Test("v27 原库升级保留笔记、状态、标签和收藏账本，覆盖从迁移开始")
    func upgrade() throws {
        let queue = try DatabaseQueue()
        var migrations = DatabaseMigrator()
        DatabaseMigrations.registerAll(into: &migrations)
        try migrations.migrate(queue, upTo: "v27-repository-skill-summaries")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO repos(id,owner,name,full_name,html_url) VALUES(1,'o','a','o/a','a');
                INSERT INTO repo_notes(repo_id,content,status,library_state,edited_at)
                VALUES(1,'old note','using','in_library','2020-01-01');
                INSERT INTO tags(id,name,created_at,updated_at) VALUES('tag','old','2020','2020');
                INSERT INTO repo_tags(repo_id,tag_id,created_at) VALUES(1,'tag','2020');
                INSERT INTO user_repo_activity(id,kind,source,repo_id,full_name,html_url,occurred_at,created_at)
                VALUES('a','star','starcat',1,'o/a','a','2020-01-01','2020-01-01');
                """)
        }
        let before = Date().timeIntervalSince1970
        try migrations.migrate(queue)
        try migrations.migrate(queue)
        try queue.read { db in
            let note = try #require(try RepoNote.fetchOne(db, key: 1))
            #expect(note.content == "old note" && note.status == "using" && note.libraryState == "in_library")
            #expect(try String.fetchOne(db, sql: "SELECT tag_id FROM repo_tags") == "tag")
            #expect(try String.fetchOne(db, sql: "SELECT id FROM user_repo_activity") == "a")
            let start = try #require(try Double.fetchOne(db, sql: "SELECT started_at FROM knowledge_activity_coverage"))
            #expect(start >= before && start <= Date().timeIntervalSince1970)
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM knowledge_activity") == 0)
        }
    }

    @Test("合入 dev 后保留专项预览库的账本和覆盖起点")
    func upgradeFromProfilePreview() throws {
        let queue = try DatabaseQueue()
        var migrations = DatabaseMigrator()
        DatabaseMigrations.registerAll(into: &migrations)
        try migrations.migrate(queue, upTo: "v27-repository-skill-summaries")
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE knowledge_activity_coverage (
                    id INTEGER PRIMARY KEY CHECK (id = 1), started_at REAL NOT NULL
                );
                CREATE TABLE knowledge_activity (
                    id INTEGER PRIMARY KEY, repo_id INTEGER NOT NULL, kind TEXT NOT NULL,
                    occurred_at REAL NOT NULL, source TEXT NOT NULL
                );
                CREATE INDEX idx_knowledge_activity_time ON knowledge_activity(occurred_at);
                INSERT INTO knowledge_activity_coverage VALUES (1, 100);
                INSERT INTO knowledge_activity VALUES (1, 1, 'wroteNote', 110, 'starcat');
                INSERT INTO grdb_migrations VALUES ('v28-knowledge-activity');
                INSERT INTO repos(id,owner,name,full_name,html_url,subscribers_count)
                VALUES (1,'o','a','o/a','a',0);
                INSERT INTO repo_notes(repo_id,content,edited_at) VALUES (1,'','2020-01-01');
                """)
        }
        try migrations.migrate(queue)
        try migrations.migrate(queue)
        try queue.read { db in
            let applied = try migrations.appliedIdentifiers(db)
            #expect(applied.contains("v30-knowledge-activity"))
            #expect(!applied.contains("v28-knowledge-activity"))
            #expect(try Double.fetchOne(db, sql: "SELECT started_at FROM knowledge_activity_coverage") == 100)
            #expect(try String.fetchAll(db, sql: "SELECT kind FROM knowledge_activity") == ["wroteNote"])
            #expect(try RepoNote.fetchOne(db, key: 1)?.editedAt == nil)
            #expect(try Int.fetchOne(db, sql: "SELECT subscribers_count FROM repos WHERE id = 1") == nil)
        }
    }

    @Test("重复保存、自动已读和重放快照不重复记账，账本写失败回滚正文")
    func writesAndRollback() async throws {
        let database = try InMemoryDatabaseManager(userId: 42)
        try await database.insertRepoFixture(id: 1)
        let notes = GRDBRepoNoteRepository(database: database)
        try await notes.markAsReadIfNeeded(repoId: 1)
        try await notes.updateContent(repoId: 1, content: "\n\u{3000}\t")
        try await notes.updateStatus(repoId: 1, status: .using)
        try await notes.updateStatus(repoId: 1, status: .using)
        try await notes.updateLibraryState(repoId: 1, state: .outsideLibrary)
        try await notes.updateLibraryState(repoId: 1, state: .outsideLibrary)
        try await notes.updateStatus(repoId: 1, status: .read)
        try await notes.updateLibraryState(repoId: 1, state: .inLibrary)
        try await notes.updateContent(repoId: 1, content: "first", isAIGenerated: true)
        try await notes.updateContent(repoId: 1, content: "first ")
        try await notes.updateContent(repoId: 1, content: "second")
        try await notes.updateContent(repoId: 1, content: nil)
        try await notes.updateContent(repoId: 1, content: "third")
        let state = try #require(try await notes.find(repoId: 1))
        try await notes.upsert(state)
        try await notes.upsert(state)
        try await database.writer.write { db in
            let kinds = try String.fetchAll(db, sql: "SELECT kind FROM knowledge_activity ORDER BY id")
            #expect(kinds == ["startedUsing", "enteredLibrary", "leftLibrary", "stoppedUsing",
                              "enteredLibrary", "wroteNote", "editedNote", "wroteNote"])
            #expect(try String.fetchOne(db, sql: "SELECT source FROM knowledge_activity WHERE kind='wroteNote' ORDER BY id") == "aiNote")
            #expect(try db.columns(in: "knowledge_activity").map(\.name) == ["id", "repo_id", "kind", "occurred_at", "source"])
            try db.execute(sql: """
                CREATE TRIGGER reject_event BEFORE INSERT ON knowledge_activity
                BEGIN SELECT RAISE(ABORT, 'fixture'); END
                """)
        }
        await #expect(throws: (any Error).self) { try await notes.updateContent(repoId: 1, content: "rollback") }
        #expect(try await notes.find(repoId: 1)?.content == "third")
    }

    @Test("自然年样例与洞察同源，历史包括已取消的仓库，分类冻结，分享只出计数")
    func annualFixture() async throws {
        let database = try InMemoryDatabaseManager(userId: 42)
        try await database.insertRepoFixture(id: 1)
        try await database.insertRepoFixture(id: 2, name: "private-project")
        let ledger = GRDBUserRepoActivityRepository(database: database)
        let actor = UserRepoActivityActor(userID: 42, userName: "demo")
        func star(_ repoID: Int64, _ when: String) async throws {
            try await ledger.recordSyncedStars([.init(repoID: repoID, fullName: "o/\(repoID)", htmlURL: "", occurredAt: when)], actor: actor)
        }
        try await star(1, "2024-12-31T16:00:00Z")
        try await ledger.recordUnstar(repoID: 1, fullName: "o/1", htmlURL: "", source: .githubSync,
                                      actor: actor, occurredAt: "2025-03-01T00:00:00Z")
        try await star(1, "2025-07-01T00:00:00Z")
        try await star(2, "2025-08-01T00:00:00Z")
        try await star(2, "2025-08-01T00:00:00Z")
        let notes = GRDBRepoNoteRepository(database: database)
        try await notes.updateStatus(repoId: 1, status: .using)
        try await notes.updateContent(repoId: 1, content: "secret body")
        try await notes.markAsReadIfNeeded(repoId: 2)
        try await notes.updateContent(repoId: 2, content: "\n\u{3000}")
        try await database.writer.write { db in
            try db.execute(sql: """
                UPDATE knowledge_activity_coverage SET started_at = unixepoch('2025-07-01');
                UPDATE knowledge_activity SET occurred_at = unixepoch('2025-08-02') + id;
                UPDATE repos SET topics = '["Swift","swift","ai"]';
                UPDATE repos SET is_private = 1, is_starred = 0 WHERE id = 2;
                INSERT INTO tags(id,name,created_at,updated_at) VALUES('t','local AI','2025','2025');
                INSERT INTO repo_tags(repo_id,tag_id,created_at) VALUES(1,'t','2025');
                INSERT INTO starred_repos(repo_id,user_id,starred_at) VALUES(1,42,'2025-07-01T00:00:00Z');
                """)
        }
        let provider = KnowledgeProfileFactsProvider(database: database)
        let zone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let cutoff = try date("2026-01-01T00:00:00Z")
        let report = try await provider.annual(year: 2025, timeZone: zone, accountID: 42, scope: .starred, cutoff: cutoff)
        let insights = try await provider.fetch(window: report.window, timeZone: zone, accountID: 42, scope: .knowledge, cutoff: cutoff)
        for facts in [insights, report] {
            #expect(facts.starEvents.count == 3)
            #expect(facts.starredRepoIDs == [1, 2] && facts.writtenRepoIDs == [1])
            #expect(facts.groups(by: .topic, members: .starredInPeriod)["swift"] == [1, 2])
            #expect(facts.currentMembers.map(\.id) == [1])
            #expect(facts.currentMembers.filter(\.using).map(\.id) == [1])
            #expect(facts.repositories.filter { $0.note == .manual }.map(\.id) == [1])
            #expect(facts.events.filter(\.isDiscoveryTime).map(\.repoID) == [1])
            #expect(facts.localCoverage == .partial && facts.starCoverage == .partial)
        }
        let dashboard = GRDBMyInsightsSnapshotProvider(database: database)
        for scope in [InsightsScope.starred, .knowledge] {
            let snapshot = try await dashboard.load(scope: scope, embeddingModel: "fixture")
            let groups = report.groups(by: .topic, members: .current)
            #expect(snapshot.topicItems.first { $0.title == "swift" }?.count == groups["swift"]?.count)
        }
        let encoded = try JSONEncoder().encode(report)
        let share = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report.shareCounts)) as? [String: Any]
        #expect(Set(share?.keys.map { $0 } ?? []) == ["starActions", "distinctStarredRepos", "reposWithWriting", "starCoverage", "localCoverage"])
        #expect(share?["reposWithWriting"] as? Int == 1)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("secret body"))
        try await database.writer.write { db in try db.execute(sql: "UPDATE tags SET name='new' WHERE id='t'") }
        let fresh = try await provider.annual(year: 2025, timeZone: zone, accountID: 42, scope: .starred, cutoff: cutoff)
        let frozen = try JSONDecoder().decode(KnowledgeProfileFacts.self, from: encoded)
        #expect(frozen.groups(by: .userTag, members: .current)["local AI"] == [1])
        #expect(fresh.groups(by: .userTag, members: .current)["new"] == [1])
        let utc = try await provider.annual(year: 2025, timeZone: .gmt, accountID: 42, scope: .starred, cutoff: cutoff)
        #expect(utc.starEvents.count == 2)
        for (start, end, expected) in [("2025-04-01T00:00:00Z", "2025-05-01T00:00:00Z", KnowledgeProfileFacts.Coverage.unknown),
                                       ("2025-09-01T00:00:00Z", "2025-10-01T00:00:00Z", .complete)] {
            let window = try DateInterval(start: date(start), end: date(end))
            let month = try await provider.fetch(window: window, timeZone: zone, accountID: 42, scope: .starred, cutoff: cutoff)
            #expect(month.localCoverage == expected && month.starCoverage == .unknown)
            #expect(month.shareCounts.reposWithWriting == (expected == .complete ? 0 : nil))
        }
        await #expect(throws: KnowledgeProfileFactsProvider.QueryError.accountChanged) {
            try await provider.annual(year: 2025, timeZone: zone, accountID: 123, scope: .starred)
        }
    }

    @Test("当前收藏晚于上次取消时回退，正式回填前后的次数相同")
    func currentStarFallback() async throws {
        let database = try InMemoryDatabaseManager(userId: 42)
        try await database.insertRepoFixture(id: 1)
        let ledger = GRDBUserRepoActivityRepository(database: database)
        let actor = UserRepoActivityActor(userID: 42, userName: "demo")
        try await ledger.recordSyncedStars([.init(repoID: 1, fullName: "o/1", htmlURL: "", occurredAt: "2025-01-01T00:00:00Z")], actor: actor)
        try await ledger.recordUnstar(repoID: 1, fullName: "o/1", htmlURL: "", source: .githubSync,
                                      actor: actor, occurredAt: "2025-02-01T00:00:00Z")
        try await database.writer.write { db in
            try db.execute(sql: "INSERT INTO starred_repos(repo_id,user_id,starred_at) VALUES(1,42,'2025-03-01T00:00:00Z')")
        }
        let provider = KnowledgeProfileFactsProvider(database: database)
        let before = try await provider.annual(year: 2025, timeZone: .gmt, accountID: 42, scope: .starred)
        #expect(before.starEvents.map(\.source) == [.currentStar, .githubSync])
        try await ledger.backfillFromLocalCaches(actor: actor)
        let after = try await provider.annual(year: 2025, timeZone: .gmt, accountID: 42, scope: .starred)
        #expect(after.starEvents.map(\.date) == before.starEvents.map(\.date))
        #expect(after.starEvents.map(\.source) == [.githubSync, .githubSync])
    }
}
