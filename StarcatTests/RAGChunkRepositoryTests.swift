//
//  RAGChunkRepositoryTests.swift
//  StarcatTests
//
//  验证 source 级稳定 diff、embedding 状态转换、知识库召回边界与 FTS 同步。
//

import Foundation
import GRDB
import Testing
@testable import Starcat

@Suite("RAGChunkRepository")
struct RAGChunkRepositoryTests {
    private func makeRepository() throws -> (InMemoryDatabaseManager, GRDBRAGChunkRepository) {
        let database = try InMemoryDatabaseManager()
        return (database, GRDBRAGChunkRepository(database: database))
    }

    @Test("全库索引刷新摘要会持久化")
    func lastIndexRefreshSummaryPersists() async throws {
        let (_, repository) = try makeRepository()
        let completedAt = Date(timeIntervalSinceReferenceDate: 12_345)
        let summary = RAGIndexRefreshSummary(
            totalRepos: 12,
            readmesProcessed: 12,
            sourceReposProcessed: 12,
            embeddingProcessed: 48,
            embeddingTotal: 48,
            readyChunksBeforeEmbedding: 120,
            totalChunksAtEmbedding: 168,
            completedAt: completedAt
        )

        try await repository.saveLastIndexRefreshSummary(summary)
        let restored = try #require(try await repository.fetchLastIndexRefreshSummary())

        #expect(restored.totalRepos == 12)
        #expect(restored.readmesProcessed == 12)
        #expect(restored.sourceReposProcessed == 12)
        #expect(restored.embeddingProcessed == 48)
        #expect(restored.totalChunksAtEmbedding == 168)
        #expect(restored.completedAt == completedAt)
    }

    @Test("内容未变复用 embedding，变化后回到 pending")
    func sourceDiffReusesAndInvalidatesEmbedding() async throws {
        let (database, repository) = try makeRepository()
        try await database.insertRepoFixture(id: 1)
        try await GRDBRepoNoteRepository(database: database).updateLibraryState(repoId: 1, state: .inLibrary)

        let first = try await repository.replaceSource(
            repoId: 1,
            source: .readme,
            drafts: [draft(repoId: 1, key: "readme:install:0", content: "Install with Swift Package Manager")]
        )
        let id = try #require(first.pendingChunkIDs.first)
        try await repository.markReady([id: [1, 0, 0]], model: "embed-v1")

        let unchanged = try await repository.replaceSource(
            repoId: 1,
            source: .readme,
            drafts: [draft(repoId: 1, key: "readme:install:0", content: "Install with Swift Package Manager")]
        )
        #expect(unchanged.reused == 1)
        #expect(unchanged.pendingChunkIDs.isEmpty)
        let reused = try #require(try await repository.fetchChunks(ids: [id]).first)
        #expect(reused.embeddingStatus == .ready)
        #expect(reused.vector == [1, 0, 0])

        let changed = try await repository.replaceSource(
            repoId: 1,
            source: .readme,
            drafts: [draft(repoId: 1, key: "readme:install:0", content: "Install with Homebrew")]
        )
        #expect(changed.changed == 1)
        #expect(changed.pendingChunkIDs == [id])
        let invalidated = try #require(try await repository.fetchChunks(ids: [id]).first)
        #expect(invalidated.embeddingStatus == .pending)
        #expect(invalidated.embedding == nil)
    }

    @Test("替换单一 source 只删除该 source 的过期 chunks")
    func sourceReplacementDoesNotTouchOtherSources() async throws {
        let (database, repository) = try makeRepository()
        try await database.insertRepoFixture(id: 2)
        _ = try await repository.replaceSource(
            repoId: 2,
            source: .readme,
            drafts: [draft(repoId: 2, key: "readme:a:0", content: "A")]
        )
        let notes = RAGChunkDraft(
            repoId: 2,
            source: .notes,
            sourceId: "",
            parentType: .notes,
            parentKey: "notes",
            parentTitle: "Notes",
            chunkKey: "notes:0",
            chunkIndex: 0,
            sectionPath: "Notes",
            title: "Notes",
            content: "Private decision",
            tokenCount: 3,
            isTruncated: false
        )
        let noteResult = try await repository.replaceSource(repoId: 2, source: .notes, drafts: [notes])
        _ = try await repository.replaceSource(repoId: 2, source: .readme, drafts: [])
        let remaining = try await repository.fetchChunks(ids: noteResult.pendingChunkIDs)
        #expect(remaining.count == 1)
        #expect(remaining.first?.source == .notes)
    }

    @Test("keyword 检索只返回知识库且 ready 的 chunk")
    func keywordSearchEnforcesKnowledgeBoundary() async throws {
        let (database, repository) = try makeRepository()
        try await database.insertRepoFixture(id: 10)
        try await database.insertRepoFixture(id: 11)
        try await GRDBRepoNoteRepository(database: database).updateLibraryState(repoId: 10, state: .inLibrary)

        let inLibrary = try await repository.replaceSource(
            repoId: 10,
            source: .readme,
            drafts: [draft(repoId: 10, key: "readme:vector:0", content: "Vector database indexing")]
        )
        let outside = try await repository.replaceSource(
            repoId: 11,
            source: .readme,
            drafts: [draft(repoId: 11, key: "readme:vector:0", content: "Vector database indexing")]
        )
        let allIDs = inLibrary.pendingChunkIDs + outside.pendingChunkIDs
        try await repository.markReady(Dictionary(uniqueKeysWithValues: allIDs.map { ($0, [1, 0]) }), model: "embed-v1")

        let hits = try await repository.keywordSearch(
            query: "vector",
            model: "embed-v1",
            repoIDs: [10, 11],
            limit: 10
        )
        #expect(hits.map(\.chunk.repoId) == [10])
    }

    @Test("Metadata 只走 FTS，不进入 embedding 队列或向量召回")
    func metadataIsKeywordOnly() async throws {
        let (database, repository) = try makeRepository()
        try await database.insertRepoFixture(id: 43)
        try await GRDBRepoNoteRepository(database: database).updateLibraryState(repoId: 43, state: .inLibrary)
        let metadata = RAGChunkDraft(
            repoId: 43,
            source: .metadata,
            sourceId: "",
            parentType: .metadata,
            parentKey: "metadata",
            parentTitle: "Repository metadata",
            chunkKey: "metadata:0",
            chunkIndex: 0,
            sectionPath: "Metadata",
            title: "Metadata",
            content: "Homepage: https://example.com/starcat",
            tokenCount: 8,
            isTruncated: false
        )

        let result = try await repository.replaceSource(repoId: 43, source: .metadata, drafts: [metadata])
        #expect(result.pendingChunkIDs.isEmpty)
        let chunk = try #require(try await repository.fetchKnowledgeChunks(repoId: 43).first)
        #expect(chunk.embeddingStatus == .keywordOnly)
        #expect(chunk.embedding == nil)
        #expect(try await repository.fetchChunksNeedingEmbedding(limit: 10).isEmpty)
        #expect(try await repository.hasReadyChunks(model: "embed-v1", repoIDs: [43]))

        let keywordHits = try await repository.keywordSearch(
            query: "homepage",
            model: "embed-v1",
            repoIDs: [43],
            limit: 10
        )
        #expect(keywordHits.map(\.chunk.id) == [chunk.id])
        let vectorHits = try await SQLiteRAGVectorSearchProvider(repository: repository).search(
            queryVector: [1, 0],
            model: "embed-v1",
            repoIDs: [43],
            limit: 10
        )
        #expect(vectorHits.isEmpty)
    }

    @Test("ready 检查只返回知识库中当前模型的可用分片")
    func readyChunkExistencePreservesRetrievalBoundary() async throws {
        let (database, repository) = try makeRepository()
        try await database.insertRepoFixture(id: 14)
        try await database.insertRepoFixture(id: 15)
        try await GRDBRepoNoteRepository(database: database).updateLibraryState(repoId: 14, state: .inLibrary)

        let inLibrary = try await repository.replaceSource(
            repoId: 14,
            source: .readme,
            drafts: [draft(repoId: 14, key: "readme:ready:0", content: "Ready")]
        )
        let outside = try await repository.replaceSource(
            repoId: 15,
            source: .readme,
            drafts: [draft(repoId: 15, key: "readme:outside:0", content: "Outside")]
        )
        try await repository.markReady(
            [inLibrary.pendingChunkIDs[0]: [1, 0], outside.pendingChunkIDs[0]: [1, 0]],
            model: "embed-v1"
        )

        #expect(try await repository.hasReadyChunks(model: "embed-v1", repoIDs: [14]))
        #expect(!(try await repository.hasReadyChunks(model: "embed-v2", repoIDs: [14])))
        #expect(!(try await repository.hasReadyChunks(model: "embed-v1", repoIDs: [15])))
    }

    @Test("SQLite 向量召回先扫描 embedding，再仅回填 Top-K 正文")
    func sqliteVectorSearchReturnsRankedHydratedChunks() async throws {
        let (database, repository) = try makeRepository()
        try await database.insertRepoFixture(id: 16)
        try await GRDBRepoNoteRepository(database: database).updateLibraryState(repoId: 16, state: .inLibrary)
        let result = try await repository.replaceSource(
            repoId: 16,
            source: .readme,
            drafts: [
                draft(repoId: 16, key: "readme:top:0", content: "Top evidence"),
                draft(repoId: 16, key: "readme:lower:0", content: "Lower evidence")
            ]
        )
        try await repository.markReady(
            [result.pendingChunkIDs[0]: [1, 0], result.pendingChunkIDs[1]: [0, 1]],
            model: "embed-v1"
        )

        let hits = try await SQLiteRAGVectorSearchProvider(repository: repository).search(
            queryVector: [1, 0],
            model: "embed-v1",
            repoIDs: [16],
            limit: 1
        )
        #expect(hits.count == 1)
        #expect(hits.first?.chunk.content == "Top evidence")
    }

    @Test("批量 parent 读取保持知识库、embedding 与 parent 边界")
    func batchParentFetchPreservesRetrievalBoundary() async throws {
        let (database, repository) = try makeRepository()
        try await database.insertRepoFixture(id: 12)
        try await database.insertRepoFixture(id: 13)
        try await GRDBRepoNoteRepository(database: database).updateLibraryState(repoId: 12, state: .inLibrary)
        try await GRDBRepoNoteRepository(database: database).updateLibraryState(repoId: 13, state: .inLibrary)

        let first = try await repository.replaceSource(
            repoId: 12,
            source: .readme,
            drafts: [draft(repoId: 12, key: "readme:install:0", content: "Install")]
        )
        let second = try await repository.replaceSource(
            repoId: 13,
            source: .readme,
            drafts: [draft(repoId: 13, key: "readme:install:0", content: "Other install")]
        )
        try await repository.markReady(
            [first.pendingChunkIDs[0]: [1, 0], second.pendingChunkIDs[0]: [1, 0]],
            model: "embed-v1"
        )

        let chunks = try await repository.fetchChunks(
            parents: [
                .init(repoID: 12, parentKey: "readme:test"),
                .init(repoID: 13, parentKey: "readme:test"),
                .init(repoID: 12, parentKey: "missing")
            ],
            model: "embed-v1"
        )
        #expect(chunks.map(\.repoId) == [12, 13])
    }

    @Test("coverage 区分 ready pending failed stale")
    func coverageCountsStatuses() async throws {
        let (database, repository) = try makeRepository()
        try await database.insertRepoFixture(id: 20)
        try await GRDBRepoNoteRepository(database: database).updateLibraryState(repoId: 20, state: .inLibrary)
        let result = try await repository.replaceSource(
            repoId: 20,
            source: .readme,
            drafts: [
                draft(repoId: 20, key: "readme:a:0", content: "Alpha"),
                draft(repoId: 20, key: "readme:b:0", content: "Beta")
            ]
        )
        try await repository.markReady([result.pendingChunkIDs[0]: [1, 0]], model: "embed-v1")
        try await repository.markFailed(chunkIDs: [result.pendingChunkIDs[1]], error: "test")

        let coverage = try await repository.coverage(model: "embed-v1")
        #expect(coverage.knowledgeRepoCount == 1)
        #expect(coverage.indexedRepoCount == 1)
        #expect(coverage.totalChunks == 2)
        #expect(coverage.readyChunks == 1)
        #expect(coverage.failedChunks == 1)
    }

    @Test("索引问题分片按待处理失败过期分类读取")
    func indexIssueChunksAreFilteredByStatus() async throws {
        let (database, repository) = try makeRepository()
        try await database.insertRepoFixture(id: 21)
        try await GRDBRepoNoteRepository(database: database).updateLibraryState(repoId: 21, state: .inLibrary)
        let result = try await repository.replaceSource(
            repoId: 21,
            source: .readme,
            drafts: [
                draft(repoId: 21, key: "readme:stale:0", content: "Stale"),
                draft(repoId: 21, key: "readme:failed:0", content: "Failed"),
                draft(repoId: 21, key: "readme:pending:0", content: "Pending")
            ]
        )
        try await repository.markReady([result.pendingChunkIDs[0]: [1, 0]], model: "embed-old")
        try await repository.markFailed(chunkIDs: [result.pendingChunkIDs[1]], error: "quota")

        let pending = try await repository.fetchIndexIssueChunks(kind: .pending, model: "embed-new", limit: 5, offset: 0)
        let failed = try await repository.fetchIndexIssueChunks(kind: .failed, model: "embed-new", limit: 5, offset: 0)
        let stale = try await repository.fetchIndexIssueChunks(kind: .stale, model: "embed-new", limit: 5, offset: 0)

        #expect(pending.chunks.map(\.chunkKey) == ["readme:pending:0"])
        #expect(failed.chunks.map(\.embeddingError) == ["quota"])
        #expect(stale.chunks.map(\.chunkKey) == ["readme:stale:0"])
    }

    @Test("知识库浏览器按仓库聚合索引状态且隔离非知识库数据")
    func knowledgeBrowserIndexAndChunksRespectLibraryBoundary() async throws {
        let (database, repository) = try makeRepository()
        try await database.insertRepoFixture(id: 30)
        try await database.insertRepoFixture(id: 31)
        try await GRDBRepoNoteRepository(database: database).updateLibraryState(repoId: 30, state: .inLibrary)

        let library = try await repository.replaceSource(
            repoId: 30,
            source: .readme,
            drafts: [
                draft(repoId: 30, key: "readme:a:0", content: "Alpha"),
                draft(repoId: 30, key: "readme:b:0", content: "Beta")
            ]
        )
        _ = try await repository.replaceSource(
            repoId: 31,
            source: .readme,
            drafts: [draft(repoId: 31, key: "readme:outside:0", content: "Outside")]
        )
        try await repository.markReady([library.pendingChunkIDs[0]: [1, 0]], model: "embed-v1")

        let indexes = try await repository.knowledgeRepositoryIndexes(model: "embed-v1")
        #expect(indexes.count == 1)
        #expect(indexes.first?.repoID == 30)
        #expect(indexes.first?.totalChunks == 2)
        #expect(indexes.first?.readyChunks == 1)
        #expect(indexes.first?.pendingChunks == 1)
        #expect(try await repository.fetchKnowledgeChunks(repoId: 30).count == 2)
        #expect(try await repository.fetchKnowledgeChunks(repoId: 31).isEmpty)
    }

    @Test("知识库浏览器不展示已排除的 chunk")
    func knowledgeBrowserOmitsExcludedChunks() async throws {
        let (database, repository) = try makeRepository()
        try await database.insertRepoFixture(id: 32)
        try await GRDBRepoNoteRepository(database: database).updateLibraryState(repoId: 32, state: .inLibrary)

        let result = try await repository.replaceSource(
            repoId: 32,
            source: .readme,
            drafts: [draft(repoId: 32, key: "readme:excluded:0", content: "Excluded")]
        )
        let chunkID = try #require(result.pendingChunkIDs.first)
        try await repository.setKnowledgeChunkExcluded(id: chunkID, isExcluded: true)

        #expect(try await repository.fetchKnowledgeChunks(repoId: 32).isEmpty)
    }

    @Test("知识库浏览器分片按页读取并报告是否还有下一页")
    func managedKnowledgeChunksArePaginated() async throws {
        let (database, repository) = try makeRepository()
        try await database.insertRepoFixture(id: 35)
        try await GRDBRepoNoteRepository(database: database).updateLibraryState(repoId: 35, state: .inLibrary)
        _ = try await repository.replaceSource(
            repoId: 35,
            source: .readme,
            drafts: [
                draft(repoId: 35, key: "readme:page:0", content: "One"),
                draft(repoId: 35, key: "readme:page:1", content: "Two"),
                draft(repoId: 35, key: "readme:page:2", content: "Three")
            ]
        )

        let first = try await repository.fetchManagedKnowledgeChunks(repoId: 35, limit: 2, offset: 0)
        #expect(first.chunks.count == 2)
        #expect(first.hasMore)

        let second = try await repository.fetchManagedKnowledgeChunks(repoId: 35, limit: 2, offset: 2)
        #expect(second.chunks.count == 1)
        #expect(!second.hasMore)
    }

    @Test("人工覆盖与排除在源重建后保留且可恢复")
    func knowledgeChunkOverrideSurvivesSourceRebuild() async throws {
        let (database, repository) = try makeRepository()
        try await database.insertRepoFixture(id: 40)
        try await GRDBRepoNoteRepository(database: database).updateLibraryState(repoId: 40, state: .inLibrary)
        let first = try await repository.replaceSource(
            repoId: 40,
            source: .readme,
            drafts: [draft(repoId: 40, key: "readme:manual:0", content: "Original")]
        )
        let id = try #require(first.pendingChunkIDs.first)
        try await repository.saveKnowledgeChunkOverride(id: id, title: "Manual", sectionPath: "Manual", content: "Edited")
        try await repository.setKnowledgeChunkExcluded(id: id, isExcluded: true)

        _ = try await repository.replaceSource(
            repoId: 40,
            source: .readme,
            drafts: [draft(repoId: 40, key: "readme:manual:0", content: "Updated source")]
        )
        let disabled = try #require(try await repository.fetchManagedKnowledgeChunks(repoId: 40, limit: 5, offset: 0).chunks.first)
        #expect(disabled.isExcluded)

        try await repository.restoreKnowledgeChunk(id: id)
        let restored = try #require(try await repository.fetchManagedKnowledgeChunks(repoId: 40, limit: 5, offset: 0).chunks.first)
        #expect(restored.chunk.content == "Updated source")
        #expect(!restored.isExcluded)
        #expect(!restored.hasOverride)
    }

    @Test("停用分片保留在浏览器管理列表但不计入可召回索引")
    func disabledChunkRemainsVisibleButIsExcludedFromIndexStatistics() async throws {
        let (database, repository) = try makeRepository()
        try await database.insertRepoFixture(id: 41)
        try await GRDBRepoNoteRepository(database: database).updateLibraryState(repoId: 41, state: .inLibrary)
        let result = try await repository.replaceSource(
            repoId: 41,
            source: .readme,
            drafts: [draft(repoId: 41, key: "readme:excluded:0", content: "Excluded")]
        )
        let id = try #require(result.pendingChunkIDs.first)
        try await repository.setKnowledgeChunkExcluded(id: id, isExcluded: true)

        let page = try await repository.fetchManagedKnowledgeChunks(repoId: 41, limit: 5, offset: 0)
        #expect(page.chunks.count == 1)
        #expect(page.chunks.first?.isExcluded == true)
        #expect(try await repository.coverage(model: "embed-v1").totalChunks == 0)
        #expect(try await repository.knowledgeRepositoryIndexes(model: "embed-v1").first?.totalChunks == 0)
    }

    @Test("永久删除分片会阻止后续 source 重建重新生成它")
    func permanentlyDeletedChunkStaysRemovedAfterSourceRebuild() async throws {
        let (database, repository) = try makeRepository()
        try await database.insertRepoFixture(id: 42)
        try await GRDBRepoNoteRepository(database: database).updateLibraryState(repoId: 42, state: .inLibrary)
        let source = draft(repoId: 42, key: "readme:removed:0", content: "Removed")
        let first = try await repository.replaceSource(repoId: 42, source: .readme, drafts: [source])
        let id = try #require(first.pendingChunkIDs.first)

        try await repository.permanentlyDeleteKnowledgeChunk(id: id)
        #expect(try await repository.fetchManagedKnowledgeChunks(repoId: 42, limit: 5, offset: 0).chunks.isEmpty)

        let rebuilt = try await repository.replaceSource(repoId: 42, source: .readme, drafts: [source])
        #expect(rebuilt.inserted == 0)
        #expect(try await repository.fetchManagedKnowledgeChunks(repoId: 42, limit: 5, offset: 0).chunks.isEmpty)
    }

    private func draft(repoId: Int64, key: String, content: String) -> RAGChunkDraft {
        RAGChunkDraft(
            repoId: repoId,
            source: .readme,
            sourceId: "",
            parentType: .readmeSection,
            parentKey: "readme:test",
            parentTitle: "README > Test",
            chunkKey: key,
            chunkIndex: 0,
            sectionPath: "Test",
            title: "Test",
            content: content,
            tokenCount: TokenEstimator.estimate(text: content),
            isTruncated: false
        )
    }
}
