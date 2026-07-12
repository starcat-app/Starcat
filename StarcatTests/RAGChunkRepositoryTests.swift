//
//  RAGChunkRepositoryTests.swift
//  StarcatTests
//
//  验证 source 级稳定 diff、embedding 状态转换、知识库召回边界与 FTS 同步。
//

import GRDB
import Testing
@testable import Starcat

@Suite("RAGChunkRepository")
struct RAGChunkRepositoryTests {
    private func makeRepository() throws -> (InMemoryDatabaseManager, GRDBRAGChunkRepository) {
        let database = try InMemoryDatabaseManager()
        return (database, GRDBRAGChunkRepository(database: database))
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
