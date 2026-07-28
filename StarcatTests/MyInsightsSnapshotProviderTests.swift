//
//  MyInsightsSnapshotProviderTests.swift
//  StarcatTests
//
//  覆盖“我的洞察”真实 SQLite 快照的范围、状态、RAG 动作项和缓存失效口径。
//

import Foundation
import GRDB
import Testing
@testable import Starcat

@Suite("My insights snapshot provider")
struct MyInsightsSnapshotProviderTests {

    @Test("收藏范围把缺失 note 计为未读并派生已整理")
    func starredScopeUsesManageStatusSemantics() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 1, starredAt: "2026-07-01T00:00:00Z")
        try await database.insertRepoFixture(id: 2, starredAt: "2026-05-01T00:00:00Z")
        try await database.insertRepoFixture(id: 3, starredAt: "2026-07-20T00:00:00Z")

        let notes = GRDBRepoNoteRepository(database: database)
        try await notes.updateStatus(repoId: 2, status: .read)
        try await notes.updateStatus(repoId: 3, status: .using)

        let tag = Tag.fixture(id: "swift", name: "Swift")
        try await GRDBTagRepository(database: database).create(tag)
        try await database.writer.write { db in
            var assignment = RepoTag(
                repoId: 2,
                tagId: tag.id,
                createdAt: "2026-07-27T00:00:00Z"
            )
            try assignment.insert(db)
            try db.execute(sql: "UPDATE repos SET language = NULL WHERE id = 1")
        }

        try await GRDBRepoHealthRepository(database: database).upsert(
            healthSnapshot(repoId: 2, maintenanceScore: 40)
        )
        try await GRDBOpenSSFScoreRepository(database: database).upsert(
            OpenSSFScoreRecord(
                repoId: 2,
                fetchStatus: .success,
                aggregateScore: 4,
                checksJSON: nil,
                scoreDate: "2026-07-27",
                fetchedAt: "2026-07-27T00:00:00Z",
                lastError: nil
            )
        )

        let now = try #require(
            ISO8601DateFormatter().date(from: "2026-07-27T00:00:00Z")
        )
        let provider = GRDBMyInsightsSnapshotProvider(
            database: database,
            now: { now }
        )
        let snapshot = try await provider.load(scope: .starred, embeddingModel: "embed-v1")

        #expect(metric("projects", in: snapshot) == 3)
        #expect(metric("new", in: snapshot) == 2)
        #expect(metric("using", in: snapshot) == 1)
        #expect(metric("organized", in: snapshot) == 2)
        #expect(distribution("unread", in: snapshot.statusItems) == 1)
        #expect(distribution("read", in: snapshot.statusItems) == 1)
        #expect(distribution("using", in: snapshot.statusItems) == 1)
        #expect(action(.untagged, in: snapshot) == 2)
        #expect(action(.unread, in: snapshot) == 1)
        #expect(action(.healthPending, in: snapshot) == 2)
        #expect(action(.openSSFPending, in: snapshot) == 2)
        #expect(action(.maintenanceRisk, in: snapshot) == 1)
        #expect(action(.securityRisk, in: snapshot) == 1)
        #expect(snapshot.healthCoverage == InsightsCoverage(completed: 1, total: 3))
        #expect(snapshot.openSSFCoverage == InsightsCoverage(completed: 1, total: 3))
        let unknownLanguage = snapshot.languageItems.first {
            $0.title == "insights.technology.license.unknown"
        }
        #expect(unknownLanguage?.count == 1)
    }

    @Test("知识库范围复用 RAG 来源与索引状态口径")
    func knowledgeScopeUsesRAGCoverageSemantics() async throws {
        let database = try InMemoryDatabaseManager()
        let notes = GRDBRepoNoteRepository(database: database)
        for id in 10...13 {
            try await database.insertRepoFixture(id: Int64(id))
        }
        for id in 10...12 {
            try await notes.updateLibraryState(repoId: Int64(id), state: .inLibrary)
        }
        try await database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO rag_chunks (
                    repo_id, source, source_id, parent_type, parent_key, parent_title, chunk_key,
                    chunk_index, section_path, title, content, content_hash, token_count, is_truncated,
                    embedding_model, embedding_status, created_at, updated_at
                ) VALUES
                    (10, 'readme', '', 'readme', 'readme', 'README', 'readme:0',
                     0, '', 'README', 'ready', 'insights-ready', 1, 0,
                     'embed-v1', 'ready', datetime('now'), datetime('now')),
                    (11, 'metadata', '', 'metadata', 'metadata', 'Metadata', 'metadata:0',
                     0, '', 'Metadata', 'stale', 'insights-stale', 1, 0,
                     'old-model', 'ready', datetime('now'), datetime('now'))
                """)
        }

        let provider = GRDBMyInsightsSnapshotProvider(database: database)
        let snapshot = try await provider.load(scope: .knowledge, embeddingModel: "embed-v1")

        #expect(metric("projects", in: snapshot) == 3)
        #expect(action(.missingReadme, in: snapshot) == 2)
        #expect(action(.missingIndexableContent, in: snapshot) == 1)
        #expect(action(.indexIssues, in: snapshot) == 1)
        #expect(!snapshot.actionItems.contains(where: { $0.id == .allActions }))

        let changedModel = try await provider.load(
            scope: .knowledge,
            embeddingModel: "embed-v2"
        )
        #expect(action(.indexIssues, in: changedModel) == 2)
    }

    @Test("revision 变化、主动刷新和 60 秒上限都会失效缓存")
    func revisionAndTTLInvalidateCache() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 21)
        let initialDate = try #require(
            ISO8601DateFormatter().date(from: "2026-07-27T00:00:00Z")
        )
        let clock = TestInsightsClock(initialDate)
        let provider = GRDBMyInsightsSnapshotProvider(
            database: database,
            now: { clock.now() }
        )

        let first = try await provider.load(scope: .starred, embeddingModel: "embed-v1")
        clock.advance(by: 30)
        let cached = try await provider.load(scope: .starred, embeddingModel: "embed-v1")
        #expect(cached.generatedAt == first.generatedAt)

        try await database.insertRepoFixture(id: 22)
        let revised = try await provider.load(scope: .starred, embeddingModel: "embed-v1")
        #expect(metric("projects", in: revised) == 2)
        #expect(revised.generatedAt > first.generatedAt)

        clock.advance(by: 10)
        await provider.invalidate()
        let manuallyRefreshed = try await provider.load(
            scope: .starred,
            embeddingModel: "embed-v1"
        )
        #expect(manuallyRefreshed.generatedAt > revised.generatedAt)

        clock.advance(by: 61)
        let expired = try await provider.load(scope: .starred, embeddingModel: "embed-v1")
        #expect(expired.generatedAt > manuallyRefreshed.generatedAt)
    }

    @Test("语言前八名之外合并为其他且不丢未知语言")
    func languageDistributionUsesTopEightAndOther() async throws {
        let database = try InMemoryDatabaseManager()
        for id in 30...39 {
            try await database.insertRepoFixture(id: Int64(id))
        }
        try await database.writer.write { db in
            for (offset, language) in [
                "Swift", "Go", "Python", "Rust", "Java", "Kotlin", "Ruby", "C",
                "C++"
            ].enumerated() {
                try db.execute(
                    sql: "UPDATE repos SET language = ? WHERE id = ?",
                    arguments: [language, 30 + offset]
                )
            }
            try db.execute(sql: "UPDATE repos SET language = NULL WHERE id = 39")
        }

        let snapshot = try await GRDBMyInsightsSnapshotProvider(
            database: database
        ).load(scope: .starred, embeddingModel: "embed-v1")

        #expect(snapshot.languageItems.count == 9)
        #expect(distribution("other", in: snapshot.languageItems) == 2)
        #expect(snapshot.languageItems.reduce(0) { $0 + $1.count } == 10)
    }

    @Test("空库与缺失派生数据返回稳定零值")
    func emptyDatabaseReturnsStableZeroValues() async throws {
        let database = try InMemoryDatabaseManager()
        let snapshot = try await GRDBMyInsightsSnapshotProvider(
            database: database
        ).load(scope: .starred, embeddingModel: "embed-v1")

        #expect(metric("projects", in: snapshot) == 0)
        #expect(snapshot.statusItems.allSatisfy { $0.count == 0 && $0.fraction == 0 })
        #expect(snapshot.actionItems.allSatisfy { $0.count == 0 })
        #expect(snapshot.healthCoverage == InsightsCoverage(completed: 0, total: 0))
        #expect(snapshot.openSSFCoverage == InsightsCoverage(completed: 0, total: 0))
        #expect(snapshot.assetSummary == InsightsAssetSummary(
            dormantCount: 0,
            archivedCount: 0,
            unavailableCount: 0
        ))
        #expect(snapshot.priorityRepositories.isEmpty)
    }

    @Test("资产清理独立计数并按 Star 数筛选高价值待整理仓库")
    func assetCleanupAndPriorityRepositoriesUseTruthfulSignals() async throws {
        let database = try InMemoryDatabaseManager()
        for id in 60...63 {
            try await database.insertRepoFixture(id: Int64(id))
        }

        let notes = GRDBRepoNoteRepository(database: database)
        try await notes.updateStatus(repoId: 61, status: .read)
        try await notes.updateStatus(repoId: 62, status: .read)

        let tag = Tag.fixture(id: "organized", name: "Organized")
        try await GRDBTagRepository(database: database).create(tag)
        try await database.writer.write { db in
            for repoID in [62, 63] {
                var assignment = RepoTag(
                    repoId: Int64(repoID),
                    tagId: tag.id,
                    createdAt: "2026-07-27T00:00:00Z"
                )
                try assignment.insert(db)
            }
            try db.execute(sql: """
                UPDATE repos
                SET stars_count = CASE id
                        WHEN 60 THEN 1000
                        WHEN 61 THEN 900
                        WHEN 62 THEN 800
                        ELSE 700
                    END,
                    pushed_at = CASE
                        WHEN id = 60 THEN '2024-01-01T00:00:00Z'
                        ELSE '2026-07-01T00:00:00Z'
                    END,
                    is_archived = CASE WHEN id = 60 THEN 1 ELSE 0 END,
                    access_state = CASE WHEN id = 61 THEN 'unavailable' ELSE 'accessible' END
                WHERE id BETWEEN 60 AND 63
                """)
        }

        let now = try #require(
            ISO8601DateFormatter().date(from: "2026-07-27T00:00:00Z")
        )
        let snapshot = try await GRDBMyInsightsSnapshotProvider(
            database: database,
            now: { now }
        ).load(scope: .starred, embeddingModel: "embed-v1")

        #expect(snapshot.assetSummary == InsightsAssetSummary(
            dormantCount: 1,
            archivedCount: 1,
            unavailableCount: 1
        ))
        #expect(snapshot.priorityRepositories.map(\.id) == [60, 61, 63])
        #expect(snapshot.priorityRepositories[0].isUnread)
        #expect(snapshot.priorityRepositories[0].isUntagged)
        #expect(!snapshot.priorityRepositories[1].isUnread)
        #expect(snapshot.priorityRepositories[1].isUntagged)
        #expect(snapshot.priorityRepositories[2].isUnread)
        #expect(!snapshot.priorityRepositories[2].isUntagged)
    }

    @Test("非收藏但已入库仓库只进入知识库范围")
    func knowledgeScopeIncludesNonStarredLibraryRepo() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 50)
        try await GRDBRepoNoteRepository(database: database).updateLibraryState(
            repoId: 50,
            state: .inLibrary
        )
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE repos SET is_starred = 0 WHERE id = 50")
        }
        let provider = GRDBMyInsightsSnapshotProvider(database: database)

        let starred = try await provider.load(scope: .starred, embeddingModel: "embed-v1")
        let knowledge = try await provider.load(scope: .knowledge, embeddingModel: "embed-v1")

        #expect(metric("projects", in: starred) == 0)
        #expect(metric("projects", in: knowledge) == 1)
        #expect(action(.missingReadme, in: knowledge) == 1)
    }

    private func metric(_ id: String, in snapshot: MyInsightsSnapshot) -> Int? {
        snapshot.metrics.first(where: { $0.id == id })?.value
    }

    private func distribution(_ id: String, in items: [InsightsDistributionItem]) -> Int? {
        items.first(where: { $0.id == id })?.count
    }

    private func action(_ id: InsightsSelection, in snapshot: MyInsightsSnapshot) -> Int? {
        snapshot.actionItems.first(where: { $0.id == id })?.count
    }

    private func healthSnapshot(repoId: Int64, maintenanceScore: Double) -> RepoHealthSnapshot {
        RepoHealthSnapshot(
            repoId: repoId,
            overallScore: 60,
            grade: "D",
            maintenanceScore: maintenanceScore,
            popularityScore: 60,
            qualityScore: 60,
            securityScore: 60,
            payloadJSON: "{}",
            computedAt: "2026-07-27T00:00:00Z",
            staleAfter: "2026-07-28T00:00:00Z",
            fetchStatus: .success,
            lastError: nil
        )
    }
}

/// 测试专用可变时钟；锁只保护同步 Date 值，不跨 await。
private final class TestInsightsClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}
