//
//  KnowledgeRAGCoreTests.swift
//  StarcatTests
//
//  覆盖 Query Planner 校验、结构化候选、混合融合、无命中早停和会话 citation 生命周期。
//

import Darwin
import Foundation
import GRDB
import Testing
@testable import Starcat

@Suite("Knowledge RAG Core")
struct KnowledgeRAGCoreTests {
    @Test("索引状态读模型统一空态、覆盖率与问题计数")
    func indexStatusProjectionMapsCoverage() {
        #expect(RAGIndexStatusProjection.empty.isKnowledgeBaseEmpty)
        #expect(RAGIndexStatusProjection.empty.fraction == 0)

        let projection = RAGIndexStatusProjection(
            knowledgeRepoCount: 4,
            indexedRepoCount: 3,
            totalChunks: 20,
            readyChunks: 15,
            pendingChunks: 2,
            failedChunks: 1,
            staleChunks: 2
        )

        #expect(!projection.isKnowledgeBaseEmpty)
        #expect(projection.indexedRepoCount == 3)
        #expect(projection.fraction == 0.75)
        #expect(projection.issueChunkCount == 5)
        #expect(projection.pendingChunks == 2)
        #expect(projection.failedChunks == 1)
        #expect(projection.staleChunks == 2)
    }

    @Test("单 source 重建只读取对应数据")
    func sourceAwareReadPlan() {
        let readme = RAGSourceReadPlan(sources: [.readme])
        #expect(readme.readsReadme && !readme.readsNote && !readme.readsSummary)
        #expect(!readme.readsTags && !readme.readsMetadataSnapshot)

        let notes = RAGSourceReadPlan(sources: [.notes])
        #expect(!notes.readsReadme && notes.readsNote && !notes.readsSummary)
        #expect(!notes.readsTags && !notes.readsMetadataSnapshot)

        let summary = RAGSourceReadPlan(sources: [.summary])
        #expect(!summary.readsReadme && !summary.readsNote && summary.readsSummary)
        #expect(!summary.readsTags && !summary.readsMetadataSnapshot)

        let metadata = RAGSourceReadPlan(sources: [.metadata])
        #expect(!metadata.readsReadme && metadata.readsNote && !metadata.readsSummary)
        #expect(metadata.readsTags && metadata.readsMetadataSnapshot)
    }

    @Test("单仓摘要读取只返回该仓库最新记录")
    func latestSummaryForRepository() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 7_001)
        try await database.insertRepoFixture(id: 7_002)
        let repository = GRDBAISummaryRepository(database: database)
        try await repository.upsert(.init(
            repoId: 7_001,
            model: "older",
            sourceHash: "older",
            summaryJson: "{}",
            generatedAt: "2026-07-15T00:00:00Z"
        ))
        try await repository.upsert(.init(
            repoId: 7_001,
            model: "newer",
            sourceHash: "newer",
            summaryJson: "{}",
            generatedAt: "2026-07-16T00:00:00Z"
        ))
        try await repository.upsert(.init(
            repoId: 7_002,
            model: "other-repo",
            sourceHash: "other",
            summaryJson: "{}",
            generatedAt: "2026-07-17T00:00:00Z"
        ))

        #expect(try await repository.fetchLatest(repoId: 7_001)?.model == "newer")
        #expect(try await repository.fetchLatest(repoId: 9_999) == nil)
    }
    @Test("README 重建使用有界并发且进度按完成数单调递增")
    func readmeRebuildUsesBoundedConcurrencyWithStableProgress() async throws {
        let probe = RAGBoundedConcurrencyProbe()

        try await RAGBoundedTaskExecutor.forEach(
            Array(0..<9),
            maxConcurrentTasks: 3,
            operation: { _ in try await probe.performWork() },
            didComplete: { completed in await probe.recordCompletion(completed) }
        )

        let snapshot = await probe.snapshot()
        #expect(snapshot.maximumConcurrentTasks == 3)
        #expect(snapshot.completionCounts == Array(1...9))
    }

    @Test("README 有界并发继续传播取消")
    func boundedReadmeRebuildPreservesCancellation() async throws {
        let task = Task {
            try await RAGBoundedTaskExecutor.forEach(
                Array(0..<20),
                maxConcurrentTasks: 3,
                operation: { _ in try await Task.sleep(for: .seconds(1)) },
                didComplete: { _ in }
            )
        }

        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test("知识库结构化分析只执行白名单 DSL 并返回 Star 排行")
    func knowledgeBaseAnalyticsExecutesWhitelistedRanking() async throws {
        let database = try InMemoryDatabaseManager()
        for id in 1...3 {
            try await database.insertRepoFixture(id: Int64(id))
            try await GRDBRepoNoteRepository(database: database).updateLibraryState(repoId: Int64(id), state: .inLibrary)
        }
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE repos SET stars_count = 80 WHERE id = 1")
            try db.execute(sql: "UPDATE repos SET stars_count = 120 WHERE id = 2")
            try db.execute(sql: "UPDATE repos SET stars_count = 10 WHERE id = 3")
        }

        let result = try await KnowledgeBaseAnalyticsExecutor(database: database).execute(
            plan: .init(dimension: .repository, measure: .maxStars, limit: 1),
            filters: .init()
        )

        #expect(result.rows == [.init(dimensionValue: "octo/demo-2", value: 120)])
        #expect(result.promptContext().contains("octo/demo-2: 120"))

        let plan = try KnowledgeRAGQueryPlanner.decodeAndValidate("""
            {"mode":"structured_only","semanticQuery":"ignored","filters":{},"analytics":{"dimension":"repository","measure":"max_stars","direction":"desc","limit":9999},"remoteContextRequests":[],"confidence":"high","userVisiblePlan":{}}
            """, fallbackQuestion: "Star 最多的项目")
        #expect(plan.mode == .structuredOnly)
        #expect(plan.semanticQuery.isEmpty)
        #expect(plan.analytics?.limit == 100)
    }

    @Test("知识库元数据快照提供全局统计与 Star Top 10")
    func knowledgeBaseMetadataSnapshotProvidesGlobalFacts() async throws {
        let database = try InMemoryDatabaseManager()
        for id in 1...3 {
            try await database.insertRepoFixture(id: Int64(id))
            try await GRDBRepoNoteRepository(database: database).updateLibraryState(repoId: Int64(id), state: .inLibrary)
        }
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE repos SET stars_count = 80, language = 'Swift', pushed_at = datetime('now') WHERE id = 1")
            try db.execute(sql: "UPDATE repos SET stars_count = 120, language = 'Python', is_starred = 0 WHERE id = 2")
            try db.execute(sql: "UPDATE repos SET stars_count = 10, language = NULL WHERE id = 3")
            try db.execute(sql: "UPDATE repo_notes SET status = 'using', library_updated_at = datetime('now') WHERE repo_id = 1")
            try db.execute(sql: "UPDATE repo_notes SET status = 'inbox', library_updated_at = datetime('now') WHERE repo_id = 2")
            try db.execute(sql: "UPDATE repo_notes SET content = 'human note', edited_at = datetime('now') WHERE repo_id = 2")
            try db.execute(sql: "UPDATE repo_notes SET content = 'AI note', is_ai_generated = 1, edited_at = datetime('now', '-90 days') WHERE repo_id = 3")
            try db.execute(sql: """
                INSERT INTO ai_summaries (repo_id, model, source_hash, summary_json, generated_at)
                VALUES (1, 'summary-model', 'summary-hash', '{}', datetime('now'))
                """)
            // 同一仓库的旧模型缓存不能放大覆盖率或近 30 天仓库数。
            try db.execute(sql: """
                INSERT INTO ai_summaries (repo_id, model, source_hash, summary_json, generated_at)
                VALUES (1, 'old-summary-model', 'old-summary-hash', '{}', datetime('now', '-90 days'))
                """)
            try db.execute(sql: """
                INSERT INTO rag_chunks (
                    repo_id, source, source_id, parent_type, parent_key, parent_title, chunk_key,
                    chunk_index, section_path, title, content, content_hash, token_count, is_truncated,
                    embedding_model, embedding_status, created_at, updated_at
                ) VALUES (
                    1, 'summary', '', 'summary', 'summary', 'AI Summary', 'summary:0',
                    0, '', 'AI summary', 'summary content', 'summary-chunk-hash', 2, 0,
                    'embed-v1', 'ready', datetime('now'), datetime('now')
                )
                """)
            try db.execute(sql: """
                INSERT INTO rag_chunks (
                    repo_id, source, source_id, parent_type, parent_key, parent_title, chunk_key,
                    chunk_index, section_path, title, content, content_hash, token_count, is_truncated,
                    embedding_model, embedding_status, created_at, updated_at
                ) VALUES
                    (1, 'readme', '', 'readme', 'readme', 'README', 'readme:0', 0, '', 'README', 'failed readme', 'readme-failed', 2, 0, 'embed-v1', 'failed', datetime('now'), datetime('now')),
                    (2, 'readme', '', 'readme', 'readme', 'README', 'readme:0', 0, '', 'README', 'stale readme', 'readme-stale', 2, 0, 'embed-v0', 'ready', datetime('now'), datetime('now')),
                    (2, 'notes', '', 'notes', 'notes', 'Private note', 'notes:0', 0, '', 'Private note', 'excluded note', 'note-excluded', 2, 0, 'embed-v1', 'ready', datetime('now'), datetime('now')),
                    (1, 'metadata', '', 'metadata', 'metadata', 'Metadata', 'metadata:0', 0, '', 'Metadata', 'keyword facts', 'metadata-keyword', 2, 0, NULL, 'keyword_only', datetime('now'), datetime('now'))
                """)
            try db.execute(sql: """
                INSERT INTO rag_chunk_overrides (
                    chunk_id, original_title, original_section_path, original_content, is_excluded, updated_at
                )
                SELECT id, title, section_path, content, 1, datetime('now')
                FROM rag_chunks WHERE content_hash = 'note-excluded'
                """)
        }

        let snapshot = try await KnowledgeBaseMetadataSnapshotProvider(
            database: database,
            embeddingModel: "embed-v1"
        ).fetch()
        let summaryCoverage = snapshot.sourceIndexCoverage.first(where: { $0.source == RAGChunkSource.summary })
        let readmeCoverage = snapshot.sourceIndexCoverage.first(where: { $0.source == RAGChunkSource.readme })
        let noteCoverage = snapshot.sourceIndexCoverage.first(where: { $0.source == RAGChunkSource.notes })
        let metadataCoverage = snapshot.sourceIndexCoverage.first(where: { $0.source == RAGChunkSource.metadata })

        #expect(snapshot.projectCount == 3)
        #expect(snapshot.starredProjectCount == 2)
        #expect(snapshot.retainedAfterUnstarCount == 1)
        #expect(snapshot.knownLanguageProjectCount == 2)
        #expect(snapshot.unknownLanguageProjectCount == 1)
        #expect(snapshot.starredStatusCounts.contains(.init(name: "using", count: 1)))
        #expect(snapshot.starredStatusCounts.contains(.init(name: "unread", count: 1)))
        #expect(snapshot.starredTaggedProjectCount == 0)
        #expect(snapshot.starredUntaggedProjectCount == 2)
        #expect(snapshot.aiSummaryProjectCount == 1)
        #expect(snapshot.privateNoteProjectCount == 2)
        #expect(snapshot.aiGeneratedNoteProjectCount == 1)
        #expect(snapshot.privateNotesEditedInLast30DaysProjectCount == 1)
        #expect(snapshot.aiSummariesGeneratedInLast30DaysProjectCount == 1)
        #expect(summaryCoverage?.chunkCount == 1)
        #expect(summaryCoverage?.readyChunkCount == 1)
        #expect(readmeCoverage?.repositoryCount == 2)
        #expect(readmeCoverage?.failedChunkCount == 1)
        #expect(readmeCoverage?.staleChunkCount == 1)
        #expect(noteCoverage?.repositoryCount == 1)
        #expect(noteCoverage?.chunkCount == 0)
        #expect(metadataCoverage?.readyChunkCount == 1)
        #expect(snapshot.indexHealth.totalChunks == 4)
        #expect(snapshot.indexHealth.readyChunks == 1)
        #expect(snapshot.indexHealth.keywordOnlyChunks == 1)
        #expect(snapshot.indexHealth.failedChunks == 1)
        #expect(snapshot.indexHealth.staleChunks == 1)
        #expect(
            snapshot.indexHealth.totalChunks == snapshot.indexHealth.readyChunks
                + snapshot.indexHealth.keywordOnlyChunks
                + snapshot.indexHealth.pendingChunks
                + snapshot.indexHealth.failedChunks
                + snapshot.indexHealth.staleChunks
        )
        #expect(snapshot.excludedChunkCount == 1)
        #expect(snapshot.withoutReadmeSourceProjectCount == 1)
        #expect(snapshot.withoutIndexableSourceProjectCount == 1)
        #expect(snapshot.topStarredRepositories.first == .init(repoID: 2, fullName: "octo/demo-2", stars: 120))
        #expect(snapshot.promptContext().contains("octo/demo-2 (120 stars)"))

        let prompt = KnowledgeRAGPromptBuilder().build(
            question: "知识库有多少项目？",
            plan: RAGQueryPlan(mode: .structuredOnly, semanticQuery: ""),
            retrieval: RAGRetrievalResult(candidates: [], bundles: [], childHits: []),
            metadataSnapshot: snapshot,
            remoteBlocks: [],
            attachmentContexts: []
        )
        #expect(prompt.userPrompt.contains("Authoritative local knowledge-base metadata snapshot"))
        #expect(prompt.userPrompt.contains("3 in-library repositories"))
        #expect(prompt.userPrompt.contains("1 repositories have an AI summary"))
        #expect(prompt.userPrompt.contains("keyword-ready 1"))
    }

    @Test("知识库元数据快照按数据库修订号缓存并在写入后失效")
    func knowledgeBaseMetadataSnapshotUsesRevisionCache() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 991)
        try await GRDBRepoNoteRepository(database: database).updateLibraryState(repoId: 991, state: .inLibrary)
        let cache = KnowledgeBaseMetadataSnapshotCache()
        let provider = KnowledgeBaseMetadataSnapshotProvider(
            database: database,
            embeddingModel: "embed-v1",
            cache: cache
        )

        let first = try await provider.fetch()
        let cached = try await provider.fetch()
        #expect(cached == first)

        try await database.writer.write { db in
            try db.execute(sql: "UPDATE repos SET stars_count = 321 WHERE id = 991")
        }
        let refreshed = try await provider.fetch()
        #expect(refreshed.generatedAt != first.generatedAt)
        #expect(refreshed.topStarredRepositories.first?.stars == 321)
    }

    @Test("关键词可搜索分片批量查询正确展开 repo ID 占位符")
    func keywordSearchableChunksExpandRepositoryPlaceholders() async throws {
        let database = try InMemoryDatabaseManager()
        for id in 1...2 {
            try await database.insertRepoFixture(id: Int64(id))
            try await GRDBRepoNoteRepository(database: database)
                .updateLibraryState(repoId: Int64(id), state: .inLibrary)
        }
        try await database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO rag_chunks (
                    repo_id, source, source_id, parent_type, parent_key, parent_title, chunk_key,
                    chunk_index, section_path, title, content, content_hash, token_count, is_truncated,
                    embedding_model, embedding_status, created_at, updated_at
                ) VALUES
                    (1, 'readme', '', 'readme_section', 'readme', 'README', 'readme:0', 0, '', 'README', 'ready', 'ready-hash', 1, 0, 'embed-v1', 'ready', datetime('now'), datetime('now')),
                    (2, 'metadata', '', 'metadata', 'metadata', 'Metadata', 'metadata:0', 0, '', 'Metadata', 'keyword', 'keyword-hash', 1, 0, NULL, 'keyword_only', datetime('now'), datetime('now'))
                """)
        }

        let chunks = try await GRDBRAGChunkRepository(database: database)
            .fetchKeywordSearchableChunks(model: "embed-v1", repoIDs: [1, 2])

        #expect(Set(chunks.map(\.contentHash)) == ["ready-hash", "keyword-hash"])
    }

    @Test("知识库库存统计按入库仓库去重，并禁止按维度分组")
    func knowledgeBaseInventoryAnalyticsUsesWhitelistedCoverageMetrics() async throws {
        let database = try InMemoryDatabaseManager()
        for id in 1...3 {
            try await database.insertRepoFixture(id: Int64(id))
            try await GRDBRepoNoteRepository(database: database).updateLibraryState(repoId: Int64(id), state: .inLibrary)
        }
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE repo_notes SET content = 'human note', edited_at = datetime('now') WHERE repo_id = 1")
            try db.execute(sql: "UPDATE repo_notes SET content = 'AI note', is_ai_generated = 1, edited_at = datetime('now', '-90 days') WHERE repo_id = 2")
            try db.execute(sql: "INSERT INTO ai_summaries (repo_id, model, source_hash, summary_json, generated_at) VALUES (1, 'a', 'a', '{}', datetime('now'))")
            try db.execute(sql: "INSERT INTO ai_summaries (repo_id, model, source_hash, summary_json, generated_at) VALUES (1, 'b', 'b', '{}', datetime('now'))")
            try db.execute(sql: """
                INSERT INTO rag_chunks (
                    repo_id, source, source_id, parent_type, parent_key, parent_title, chunk_key,
                    chunk_index, section_path, title, content, content_hash, token_count, is_truncated,
                    embedding_model, embedding_status, created_at, updated_at
                ) VALUES
                    (1, 'readme', '', 'readme', 'readme', 'README', 'readme:0', 0, '', 'README', 'readme', 'analytics-readme', 1, 0, 'embed-v1', 'ready', datetime('now'), datetime('now')),
                    (2, 'notes', '', 'notes', 'notes', 'Private note', 'notes:0', 0, '', 'Private note', 'excluded', 'analytics-excluded', 1, 0, 'embed-v1', 'ready', datetime('now'), datetime('now'))
                """)
            try db.execute(sql: """
                INSERT INTO rag_chunk_overrides (
                    chunk_id, original_title, original_section_path, original_content, is_excluded, updated_at
                )
                SELECT id, title, section_path, content, 1, datetime('now')
                FROM rag_chunks WHERE content_hash = 'analytics-excluded'
                """)
        }
        let executor = KnowledgeBaseAnalyticsExecutor(database: database)
        let summaryResult = try await executor.execute(
            plan: .init(measure: .repositoriesWithAISummary),
            filters: .init()
        )
        let noteResult = try await executor.execute(
            plan: .init(measure: .repositoriesWithPrivateNotes),
            filters: .init()
        )
        let aiNoteResult = try await executor.execute(
            plan: .init(measure: .repositoriesWithAIGeneratedNotes),
            filters: .init()
        )
        let recentNoteResult = try await executor.execute(
            plan: .init(measure: .repositoriesWithRecentlyEditedPrivateNotes),
            filters: .init()
        )
        let recentSummaryResult = try await executor.execute(
            plan: .init(measure: .repositoriesWithRecentlyGeneratedAISummaries),
            filters: .init()
        )
        let excludedResult = try await executor.execute(
            plan: .init(measure: .excludedRAGChunks),
            filters: .init()
        )
        let withoutREADMEResult = try await executor.execute(
            plan: .init(measure: .repositoriesWithoutREADME),
            filters: .init()
        )
        let withoutSourceResult = try await executor.execute(
            plan: .init(measure: .repositoriesWithoutIndexableSource),
            filters: .init()
        )

        #expect(summaryResult.rows == [.init(dimensionValue: nil, value: 1)])
        #expect(noteResult.rows == [.init(dimensionValue: nil, value: 2)])
        #expect(aiNoteResult.rows == [.init(dimensionValue: nil, value: 1)])
        #expect(recentNoteResult.rows == [.init(dimensionValue: nil, value: 1)])
        #expect(recentSummaryResult.rows == [.init(dimensionValue: nil, value: 1)])
        #expect(excludedResult.rows == [.init(dimensionValue: nil, value: 1)])
        #expect(withoutREADMEResult.rows == [.init(dimensionValue: nil, value: 2)])
        #expect(withoutSourceResult.rows == [.init(dimensionValue: nil, value: 2)])
        #expect(throws: RAGQueryPlannerError.self) {
            try KnowledgeBaseAnalyticsPlan(dimension: .language, measure: .repositoriesWithAISummary).validated()
        }
    }

    @Test("索引刷新汇总分别记录仓库构建与向量分片")
    func indexRefreshSummaryKeepsRepositoryAndEmbeddingCountsSeparate() {
        let summary = RAGIndexRefreshSummary(
            totalRepos: 1_880,
            readmesProcessed: 1_880,
            sourceReposProcessed: 1_880,
            embeddingProcessed: 12_345,
            embeddingTotal: 20_281,
            readyChunksBeforeEmbedding: 3_000,
            totalChunksAtEmbedding: 20_281,
            completedAt: nil
        )

        #expect(summary.sourceReposProcessed == 1_880)
        #expect(summary.embeddingProcessed == 12_345)
        #expect(summary.embeddingTotal == 20_281)
        #expect(summary.embeddingReadyChunks == 15_345)
    }

    @Test("仅 embedding 阶段暴露本轮分片进度")
    func indexingStatusExposesOnlyActiveEmbeddingProgress() {
        let active = RAGIndexingStatus.embedding(processedChunks: 12, totalChunks: 30)

        #expect(active.embeddingProgress?.processedChunks == 12)
        #expect(active.embeddingProgress?.totalChunks == 30)
        #expect(RAGIndexingStatus.idle.embeddingProgress == nil)
    }

    @MainActor
    @Test("RAG 最新选择请求不会接受过期结果")
    func latestRequestGateRejectsStaleResult() {
        let gate = RAGLatestRequestGate()
        let first = gate.begin()
        let second = gate.begin()

        #expect(!gate.isCurrent(first))
        #expect(gate.isCurrent(second))
    }

    @Test("RAG 会话展示缓存按最近使用顺序有界淘汰")
    func conversationPresentationCacheUsesLRUEviction() {
        func snapshot(id: UUID, title: String) -> RAGConversationPresentationSnapshot {
            RAGConversationPresentationSnapshot(
                detail: RAGConversationDetail(
                    summary: RAGConversationSummary(
                        id: id,
                        title: title,
                        isPinned: false,
                        pinnedAt: nil,
                        groupID: nil,
                        createdAt: "2026-07-15T00:00:00Z",
                        updatedAt: "2026-07-15T00:00:00Z"
                    ),
                    messages: [],
                    contextSummary: nil
                ),
                outlineTurns: [],
                citations: []
            )
        }

        let firstID = UUID()
        let secondID = UUID()
        let thirdID = UUID()
        var cache = RAGConversationPresentationCache(capacity: 2)
        cache.insert(snapshot(id: firstID, title: "first"))
        cache.insert(snapshot(id: secondID, title: "second"))

        let recentlyUsedFirst = cache.value(for: firstID)
        #expect(recentlyUsedFirst?.detail.summary.title == "first")
        cache.insert(snapshot(id: thirdID, title: "third"))

        let evictedSecond = cache.value(for: secondID)
        let retainedFirst = cache.value(for: firstID)
        let retainedThird = cache.value(for: thirdID)
        #expect(cache.count == 2)
        #expect(evictedSecond == nil)
        #expect(retainedFirst != nil)
        #expect(retainedThird != nil)
    }

    @Test("RAG 会话展示缓存同时受消息数与文本字节预算约束")
    func conversationPresentationCacheUsesMessageAndByteBudgets() {
        func snapshot(id: UUID, messages: [String]) -> RAGConversationPresentationSnapshot {
            let summary = RAGConversationSummary(
                id: id,
                title: "预算测试",
                isPinned: false,
                pinnedAt: nil,
                groupID: nil,
                createdAt: "2026-07-16T00:00:00Z",
                updatedAt: "2026-07-16T00:00:00Z"
            )
            return RAGConversationPresentationSnapshot(
                detail: RAGConversationDetail(
                    summary: summary,
                    messages: messages.map {
                        RAGStoredMessage(
                            id: UUID(), conversationID: id, role: .assistant, content: $0,
                            model: nil, citations: [], remoteContextAudits: [], createdAt: summary.createdAt
                        )
                    },
                    contextSummary: nil
                ),
                outlineTurns: [],
                citations: []
            )
        }

        let firstID = UUID()
        let secondID = UUID()
        let oversizedID = UUID()
        let first = snapshot(id: firstID, messages: ["一", "二"])
        let second = snapshot(id: secondID, messages: ["三", "四"])
        let oversized = snapshot(id: oversizedID, messages: [String(repeating: "x", count: 400)])
        var cache = RAGConversationPresentationCache(
            capacity: 24,
            maxMessageCount: 3,
            maxEstimatedTextBytes: 256
        )

        let insertedFirst = cache.insert(first)
        let insertedSecond = cache.insert(second)
        #expect(insertedFirst)
        #expect(insertedSecond)
        #expect(cache.value(for: firstID) == nil)
        #expect(cache.value(for: secondID) != nil)
        #expect(cache.messageCount == 2)
        #expect(cache.estimatedTextBytes <= 256)
        let insertedOversized = cache.insert(oversized)
        #expect(!insertedOversized)
        #expect(cache.value(for: oversizedID) == nil)

        var prefetchCache = RAGConversationPresentationCache(
            capacity: 24,
            maxMessageCount: 3,
            maxEstimatedTextBytes: 1_024
        )
        let retainedFirst = prefetchCache.insert(first)
        let insertedPrefetch = prefetchCache.insertPrefetched(second)
        #expect(retainedFirst)
        #expect(!insertedPrefetch)
        #expect(prefetchCache.value(for: firstID) != nil)
        #expect(prefetchCache.value(for: secondID) == nil)
    }

    @Test("RAG 会话运行态按会话聚合且默认值完整")
    func conversationRuntimeStateIsConversationScoped() {
        let firstID = UUID()
        let secondID = UUID()
        var states: [UUID: RAGConversationRuntimeState] = [:]
        var first = RAGConversationRuntimeState()
        first.answerState = .planning
        first.streamingAnswer = "后台回答"
        first.elapsedDuration = 3
        states[firstID] = first
        states[secondID] = RAGConversationRuntimeState()

        #expect(states[firstID]?.answerState == .planning)
        #expect(states[firstID]?.streamingAnswer == "后台回答")
        #expect(states[firstID]?.elapsedDuration == 3)
        #expect(states[secondID]?.answerState == .idle)
        #expect(states[secondID]?.streamingAnswer == "")
        #expect(states[secondID]?.queryPlan == nil)
        #expect(states[secondID]?.retrieval == nil)
        #expect(states[secondID]?.remoteBlocks.isEmpty == true)
        #expect(states[secondID]?.executionSteps.isEmpty == true)
    }

    @Test("持久化轮次增量追加消息与大纲且保持幂等")
    func conversationPresentationAppendsPersistedTurnIncrementally() {
        let conversationID = UUID()
        let summary = RAGConversationSummary(
            id: conversationID,
            title: "增量会话",
            isPinned: false,
            pinnedAt: nil,
            groupID: nil,
            createdAt: "2026-07-16T00:00:00Z",
            updatedAt: "2026-07-16T00:01:00Z"
        )
        let user = RAGStoredMessage(
            id: UUID(), conversationID: conversationID, role: .user, content: "新增问题",
            model: nil, citations: [], remoteContextAudits: [], createdAt: "2026-07-16T00:01:00Z"
        )
        let assistant = RAGStoredMessage(
            id: UUID(), conversationID: conversationID, role: .assistant, content: "新增回答",
            model: "test", citations: [], remoteContextAudits: [], createdAt: "2026-07-16T00:01:01Z"
        )
        let turn = RAGPersistedConversationTurn(summary: summary, userMessage: user, assistantMessage: assistant)
        let empty = RAGConversationPresentationSnapshot(
            detail: RAGConversationDetail(summary: summary, messages: [], contextSummary: nil),
            outlineTurns: [],
            citations: []
        )

        let appended = empty.appending(turn, summary: summary)
        let duplicate = appended.appending(turn, summary: summary)
        let rebuilt = RAGConversationPresentationSnapshot(
            detail: appended.detail,
            outlineTurns: appended.outlineTurns,
            citations: appended.citations
        )
        #expect(appended.detail.messages == [user, assistant])
        #expect(appended.outlineTurns.map(\.userMessageID) == [user.id])
        #expect(appended.estimatedTextUTF8Bytes == rebuilt.estimatedTextUTF8Bytes)
        #expect(duplicate.detail.messages == appended.detail.messages)
        #expect(duplicate.outlineTurns == appended.outlineTurns)
    }

    @Test("RAG Composer 草稿按会话隔离保存与恢复")
    func composerDraftStoreIsolatesPerConversation() {
        let firstID = UUID()
        let secondID = UUID()
        var store = RAGComposerDraftStore()

        let firstAttachment = RAGComposerAttachment(
            id: UUID(),
            filename: "notes.md",
            contentType: "text/markdown",
            sizeInBytes: 12,
            localURL: URL(fileURLWithPath: "/tmp/notes.md"),
            handling: .textContext
        )
        store.save(
            RAGComposerDraftSnapshot(
                draftQuestion: "compare these repos",
                selectedRepoContexts: [],
                attachments: [firstAttachment],
                githubLinkContexts: [],
                explicitRepoMode: .prefer,
                webSearchEnabled: true,
                deepThinkingEnabled: true
            ),
            for: firstID
        )
        store.save(
            RAGComposerDraftSnapshot(
                draftQuestion: "other question",
                selectedRepoContexts: [],
                attachments: [],
                githubLinkContexts: [],
                explicitRepoMode: .only,
                webSearchEnabled: false
            ),
            for: secondID
        )

        let restoredFirst = store.draft(for: firstID)
        let restoredSecond = store.draft(for: secondID)
        #expect(restoredFirst?.draftQuestion == "compare these repos")
        #expect(restoredFirst?.attachments.map(\.filename) == ["notes.md"])
        #expect(restoredFirst?.explicitRepoMode == .prefer)
        #expect(restoredFirst?.webSearchEnabled == true)
        #expect(restoredFirst?.deepThinkingEnabled == true)
        #expect(restoredSecond?.draftQuestion == "other question")
        #expect(restoredSecond?.attachments.isEmpty == true)
        #expect(restoredSecond?.webSearchEnabled == false)
        #expect(restoredSecond?.deepThinkingEnabled == false)

        store.update(firstID) { draft in
            draft.draftQuestion = ""
            draft.attachments = []
        }
        #expect(store.draft(for: firstID)?.draftQuestion == "")
        #expect(store.draft(for: firstID)?.attachments.isEmpty == true)
        #expect(store.draft(for: secondID)?.draftQuestion == "other question")

        store.remove(secondID)
        #expect(store.draft(for: secondID) == nil)
        #expect(store.count == 1)

        store.removeAll()
        #expect(store.count == 0)
        #expect(store.draft(for: firstID) == nil)
    }

    @MainActor
    @Test("RAG Markdown 固定正则缓存不改变引用链接与段落格式")
    func ragMarkdownRegexCachePreservesDisplayFormatting() {
        let citation = fixtureCitation(marker: "S1")

        let display = RAGMarkdownText.prepareForDisplay("[S1]octo/demo", citations: [citation])
        let repositoryDisplay = RAGMarkdownText.prepareForDisplay(
            "[octo/demo](https://github.com/octo/demo)",
            citations: []
        )
        let nonRepositoryDisplay = RAGMarkdownText.prepareForDisplay(
            "[octo/demo issues](https://github.com/octo/demo/issues)",
            citations: []
        )

        #expect(display.contains("[S1](starcat-rag://citation/\(citation.id.uuidString))"))
        #expect(display.contains("\n\nocto/demo"))
        #expect(repositoryDisplay.contains(
            "[![octo avatar](starcat-rag-avatar://octo)](https://github.com/octo/demo) [octo/demo](https://github.com/octo/demo)"
        ))
        #expect(!nonRepositoryDisplay.contains("starcat-rag-avatar"))
    }

    @Test("RAG Markdown 仅拆出标准表格并保留代码围栏")
    func ragMarkdownTableParserPreservesFencedPipes() {
        let source = """
        Before

        | Name | Stars |
        | --- | ---: |
        | Starcat | 42 |

        ```swift
        let pipeline = "a | b"
        ```

        After
        """

        #expect(RAGMarkdownTableParser.split(source) == [
            .markdown("Before\n"),
            .table("| Name | Stars |\n| --- | ---: |\n| Starcat | 42 |"),
            .markdown("\n```swift\nlet pipeline = \"a | b\"\n```\n\nAfter")
        ])
    }

    @Test("Planner: 无筛选问题保持 semantic_only")
    func plannerSemanticOnly() throws {
        let plan = try KnowledgeRAGQueryPlanner.decodeAndValidate("""
            {
              "mode":"semantic_only",
              "semanticQuery":"适合本地 RAG 的 Swift 项目",
              "filters":{},
              "sort":null,
              "candidateLimit":null,
              "remoteContextRequests":[],
              "confidence":"high",
              "clarificationQuestion":null,
              "userVisiblePlan":{"scope":"知识库","chips":[],"semantic":"适合本地 RAG 的 Swift 项目"}
            }
            """, fallbackQuestion: "原问题")
        #expect(plan.mode == .semanticOnly)
        #expect(!plan.filters.hasEffectiveConditions)
    }

    @Test("Planner: 用户可见查询规划会被保留并限制长度")
    func plannerKeepsUserVisiblePlanningNotes() throws {
        let plan = try KnowledgeRAGQueryPlanner.decodeAndValidate("""
            {
              "mode":"semantic_only",
              "semanticQuery":"Swift 并发问题",
              "filters":{},
              "remoteContextRequests":[],
              "confidence":"high",
              "userVisiblePlan":{
                "scope":"知识库",
                "chips":[],
                "semantic":"Swift 并发问题",
                "planningNotes":["先确认问题聚焦 Swift 并发，再从知识库证据中检索。", "优先匹配 README、笔记和摘要中的相关段落。"]
              }
            }
            """, fallbackQuestion: "原问题")

        #expect(plan.userVisiblePlan.planningNotes.count == 2)
        #expect(plan.userVisiblePlan.planningNotes.first?.contains("Swift 并发") == true)
    }

    @Test("Planner: 非知识库问题进入 guided_discovery 并清空数据访问")
    func plannerGuidedDiscoveryCannotAccessData() throws {
        let plan = try KnowledgeRAGQueryPlanner.decodeAndValidate("""
            {
              "mode":"guided_discovery",
              "semanticQuery":"天气",
              "filters":{"languages":["Swift"]},
              "remoteContextRequests":[{"resource":"github_issues","query":"weather","reason":"不应执行","maxRepos":5,"perRepoLimit":10}],
              "confidence":"high",
              "fallbackQuestions":["介绍知识库中的 Swift 项目", "介绍知识库中的 Swift 项目", "比较两个相关项目"],
              "userVisiblePlan":{"scope":"知识库提问引导","chips":[],"semantic":""}
            }
            """, fallbackQuestion: "今天天气如何")

        #expect(plan.mode == .guidedDiscovery)
        #expect(plan.semanticQuery.isEmpty)
        #expect(!plan.filters.hasEffectiveConditions)
        #expect(plan.remoteContextRequests.isEmpty)
        #expect(plan.fallbackQuestions == ["介绍知识库中的 Swift 项目", "比较两个相关项目"])
    }

    @Test("执行层为最新 open issues 补齐 GitHub 实时请求")
    func networkIntentResolverBackfillsLiveGitHubIssues() {
        let resolved = RAGNetworkIntentResolver.resolve(
            question: "这个项目最新的 open issues 是什么",
            plan: RAGQueryPlan(mode: .guidedDiscovery, semanticQuery: ""),
            composerContext: RAGComposerContext(
                explicitRepoIDs: [21],
                explicitRepoReferences: [.init(id: 21, fullName: "waydabber/BetterDisplay")]
            )
        )

        #expect(resolved.remoteContextRequests.count == 1)
        #expect(resolved.remoteContextRequests.first?.resource == .githubIssues)
        #expect(resolved.remoteContextRequests.first?.state == .open)
        #expect(resolved.remoteContextRequests.first?.query.isEmpty == true)
        #expect(resolved.mode == .semanticOnly)
        #expect(resolved.requiresLiveEvidence)
        #expect(resolved.webSearchRequests.isEmpty)
    }

    @Test("Composer 联网开关把知识库外事实问题转为受限 Web 查询")
    func networkIntentResolverCreatesExplicitWebQuery() {
        let resolved = RAGNetworkIntentResolver.resolve(
            question: "这个项目与同类方案有什么区别？",
            plan: RAGQueryPlan(mode: .guidedDiscovery, semanticQuery: ""),
            composerContext: RAGComposerContext(
                explicitRepoIDs: [21],
                explicitRepoReferences: [.init(id: 21, fullName: "waydabber/BetterDisplay")],
                webSearchRepoReferences: [.init(id: 21, fullName: "waydabber/BetterDisplay")],
                webSearchEnabled: true
            )
        )

        #expect(resolved.mode == .semanticOnly)
        #expect(resolved.webSearchRequests.count == 1)
        #expect(resolved.webSearchRequests.first?.query.contains("waydabber/BetterDisplay") == true)
        #expect(resolved.remoteContextRequests.isEmpty)
    }

    @Test("Composer 联网 fallback 使用 Planner 语义查询而非原始指代")
    func networkIntentResolverUsesSemanticQueryForWebFallback() {
        let resolved = RAGNetworkIntentResolver.resolve(
            question: "我问的是这个项目，应该如何配置 LLM API",
            plan: RAGQueryPlan(mode: .semanticOnly, semanticQuery: "如何配置 LLM API"),
            composerContext: RAGComposerContext(
                explicitRepoIDs: [21],
                explicitRepoReferences: [.init(id: 21, fullName: "openclaw/openclaw")],
                webSearchRepoReferences: [.init(id: 21, fullName: "openclaw/openclaw")],
                webSearchEnabled: true
            )
        )

        #expect(resolved.webSearchRequests.first?.query == "openclaw/openclaw 如何配置 LLM API")
        #expect(resolved.webSearchRequests.first?.query.contains("这个项目") == false)
    }

    @Test("关闭 Composer 联网后丢弃 Planner 普通 Web 请求")
    func networkIntentResolverRequiresExplicitWebConsent() {
        let resolved = RAGNetworkIntentResolver.resolve(
            question: "搜索网络资料",
            plan: RAGQueryPlan(
                mode: .semanticOnly,
                semanticQuery: "搜索网络资料",
                webSearchRequests: [.init(query: "Starcat RAG", reason: "补充资料")]
            ),
            composerContext: .init(webSearchEnabled: false)
        )

        #expect(resolved.webSearchRequests.isEmpty)
    }

    @Test("未授权的私有仓库身份不会进入 External Search 查询")
    func networkIntentResolverDoesNotLeakPrivateRepoName() {
        let resolved = RAGNetworkIntentResolver.resolve(
            question: "查找这个项目的外部评测",
            plan: RAGQueryPlan(
                mode: .semanticOnly,
                semanticQuery: "外部评测",
                webSearchRequests: [
                    .init(query: "secret/private-repo 外部评测", reason: "Planner 复述了私有仓库名")
                ]
            ),
            composerContext: RAGComposerContext(
                explicitRepoIDs: [99],
                explicitRepoReferences: [.init(id: 99, fullName: "secret/private-repo")],
                webSearchRepoReferences: [],
                webSearchEnabled: true
            )
        )

        #expect(resolved.webSearchRequests.first?.query == "外部评测")
        #expect(resolved.webSearchRequests.first?.query.contains("secret/private-repo") == false)
    }

    @Test("旧联网审计缺少 Provider 与结果预览时仍可解码")
    func legacyRemoteAuditDecodesWithoutNewFields() throws {
        let data = Data(#"""
            {
              "id":"21:github_issues:0",
              "repoFullName":"octo/demo",
              "resource":"github_issues",
              "querySummary":"crash",
              "status":"succeeded",
              "resultCount":1
            }
            """#.utf8)

        let item = try JSONDecoder().decode(RAGRemoteExecutionAuditItem.self, from: data)

        #expect(item.providerName == nil)
        #expect(item.resultPreviews.isEmpty)
    }

    @Test("仅 External Search 失败时显示配置入口")
    func externalSearchFailureOffersSettingsShortcut() {
        func auditItem(
            resource: RAGRemoteContextResource,
            status: RAGRemoteExecutionStatus
        ) -> RAGRemoteExecutionAuditItem {
            RAGRemoteExecutionAuditItem(
                id: "audit-\(resource.rawValue)-\(status.rawValue)",
                repoFullName: "",
                resource: resource,
                querySummary: "配置 LLM API",
                requestURL: nil,
                status: status,
                transport: nil,
                httpStatusCode: nil,
                resultCount: 0,
                errorMessage: "No available provider",
                startedAt: nil,
                completedAt: nil
            )
        }

        #expect(RAGExecutionTimeline.shouldOfferExternalSearchSettings(
            for: auditItem(resource: .externalWeb, status: .failed)
        ))
        #expect(!RAGExecutionTimeline.shouldOfferExternalSearchSettings(
            for: auditItem(resource: .externalWeb, status: .empty)
        ))
        #expect(!RAGExecutionTimeline.shouldOfferExternalSearchSettings(
            for: auditItem(resource: .githubIssues, status: .failed)
        ))
    }

    @Test("RAG 设置导航动作透传目标配置项")
    @MainActor
    func ragSettingsNavigationForwardsTarget() {
        var receivedTarget: String?
        let action = RAGSettingsNavigationAction { target in
            receivedTarget = target
        }

        action("integrations.externalSearch")

        #expect(receivedTarget == "integrations.externalSearch")
    }

    @Test("Planner: 只接收显式仓库身份、上一条用户问题和上一轮引用仓库")
    func plannerReceivesMinimalConversationContext() async throws {
        let spy = SpyRAGAIClient(chatResponse: """
            {"mode":"semantic_only","semanticQuery":"继续比较","filters":{},"remoteContextRequests":[],"confidence":"high","userVisiblePlan":{"scope":"知识库","chips":[],"semantic":"继续比较"}}
            """)
        let planner = KnowledgeRAGQueryPlanner(
            client: spy,
            model: "planner-model",
            parameters: .summaryDefault
        )
        _ = try await planner.plan(
            question: "继续比较它们",
            composerContext: RAGComposerContext(
                explicitRepoIDs: [1],
                explicitRepoReferences: [.init(id: 1, fullName: "octo/demo")],
                previousUserQuestion: "先比较数据库能力",
                previousReferencedRepos: [.init(id: 2, fullName: "octo/other")]
            )
        )

        let prompt = try #require(spy.lastChatRequest?.userPrompt)
        #expect(prompt.contains("1:octo/demo"))
        #expect(prompt.contains("先比较数据库能力"))
        #expect(prompt.contains("2:octo/other"))
        #expect(!prompt.contains("assistant answer body"))
    }

    @Test("Planner 只接收知识库聚合库存，不接收私有正文或仓库名单")
    func plannerReceivesAggregateMetadataInventoryOnly() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 1, owner: "private", name: "secret-project")
        try await GRDBRepoNoteRepository(database: database).updateLibraryState(repoId: 1, state: .inLibrary)
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE repo_notes SET content = 'do-not-send-private-note' WHERE repo_id = 1")
            try db.execute(sql: "INSERT INTO ai_summaries (repo_id, model, source_hash, summary_json, generated_at) VALUES (1, 'model', 'hash', '{\"summary\":\"do-not-send\"}', datetime('now'))")
        }
        let snapshot = try await KnowledgeBaseMetadataSnapshotProvider(
            database: database,
            embeddingModel: "embed-v1"
        ).fetch()
        let spy = SpyRAGAIClient(chatResponse: """
            {"mode":"structured_only","semanticQuery":"","filters":{},"analytics":{"dimension":null,"measure":"repositories_with_private_notes","direction":"desc","limit":1},"remoteContextRequests":[],"confidence":"high","userVisiblePlan":{}}
            """)
        let planner = KnowledgeRAGQueryPlanner(client: spy, model: "planner-model", parameters: .summaryDefault)

        _ = try await planner.plan(
            question: "有多少私有笔记？",
            composerContext: .init(),
            metadataSnapshot: snapshot,
            onReasoningDelta: { _ in },
            onDebugEvent: { _, _ in }
        )

        let prompt = try #require(spy.lastChatRequest?.userPrompt)
        #expect(prompt.contains("Authoritative local knowledge-base inventory"))
        #expect(prompt.contains("private notes: 1 repositories"))
        #expect(!prompt.contains("private/secret-project"))
        #expect(!prompt.contains("do-not-send-private-note"))
        #expect(!prompt.contains("do-not-send"))
    }

    @Test("Planner: 网络错误不伪装成 semantic fallback")
    func plannerPropagatesNetworkFailure() async {
        let planner = KnowledgeRAGQueryPlanner(
            client: SpyRAGAIClient(streamError: URLError(.notConnectedToInternet)),
            model: "test-model",
            parameters: .summaryDefault
        )

        await #expect(throws: URLError.self) {
            try await planner.plan(question: "Swift RAG", composerContext: .init())
        }
    }

    @Test("Planner: 每次 LLM 请求与返回都进入 Debug 事件")
    func plannerRecordsEveryLLMRequestInDebug() async throws {
        let planner = KnowledgeRAGQueryPlanner(
            client: SpyRAGAIClient(chatResponse: """
            {"mode":"semantic_only","semanticQuery":"Swift RAG","filters":{},"remoteContextRequests":[],"confidence":"high","userVisiblePlan":{"scope":"知识库","chips":[],"semantic":"Swift RAG"}}
            """),
            model: "planner-model",
            parameters: .summaryDefault
        )
        let recorder = RAGDebugEventRecorder()

        _ = try await planner.plan(
            question: "Swift RAG",
            composerContext: .init(),
            onReasoningDelta: { _ in },
            onDebugEvent: { stage, payload in recorder.record(stage: stage, payload: payload) }
        )

        #expect(recorder.stages == [.plannerPrompt, .plannerResponse])
        #expect(recorder.payloads.first?.contains("planner-model") == true)
        #expect(recorder.payloads.last?.contains("semantic_only") == true)
    }

    @Test("AI 流式 `<think>` 跨分片时推理与正文分离")
    func reasoningNormalizerSeparatesSplitThinkTag() {
        var normalizer = AIStreamReasoningNormalizer()
        var events = normalizer.ingest(content: "<thi", nativeReasoning: nil)
        events += normalizer.ingest(content: "nk>先检查索引</th", nativeReasoning: nil)
        events += normalizer.ingest(content: "ink>正式回答", nativeReasoning: nil)
        events += normalizer.finish()

        let reasoning = events.compactMap { event -> String? in
            if case .reasoningDelta(let text) = event { return text }
            return nil
        }.joined()
        let answer = events.compactMap { event -> String? in
            if case .delta(let text) = event { return text }
            return nil
        }.joined()
        #expect(reasoning == "先检查索引")
        #expect(answer == "正式回答")
        #expect(events.contains(.reasoningCompleted))
    }

    @Test("AI 原生 reasoning_content 优先作为推理流")
    func reasoningNormalizerUsesNativeReasoning() {
        var normalizer = AIStreamReasoningNormalizer()
        var events = normalizer.ingest(content: nil, nativeReasoning: "先分析请求")
        events += normalizer.ingest(content: "正式回答", nativeReasoning: nil)
        events += normalizer.finish()

        #expect(events.contains(.reasoningDelta("先分析请求")))
        #expect(events.contains(.delta("正式回答")))
        #expect(events.contains(.reasoningCompleted))
    }

    @Test("用户可见步骤使用真实起止时间计算耗时")
    func executionStepUsesPersistedDuration() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 10_000)
        let completedAt = startedAt.addingTimeInterval(1.25)
        let step = RAGExecutionStep(
            kind: .answerReasoning,
            state: .completed,
            startedAt: startedAt,
            completedAt: completedAt
        )

        #expect(step.elapsedDuration(at: startedAt.addingTimeInterval(99)) == 1.25)
    }

    @Test("运行中读秒由起点推进而不依赖流式快照")
    func liveDurationClockAdvancesWithoutStreamMutation() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 20_000)
        let now = startedAt.addingTimeInterval(5)

        #expect(RAGLiveDurationClock.duration(
            recordedDuration: 1,
            startedAt: startedAt,
            now: now
        ) == 5)
        #expect(RAGLiveDurationClock.duration(
            recordedDuration: 3.25,
            startedAt: nil,
            now: now
        ) == 3.25)
        #expect(RAGLiveDurationClock.duration(
            recordedDuration: 8,
            startedAt: startedAt,
            now: now
        ) == 8)
    }

    @Test("RAG 执行步骤运行中可手动折叠且完成后仍自动折叠")
    func executionDisclosureSupportsRunningManualToggle() {
        var disclosure = RAGExecutionDisclosureState()
        let running = RAGExecutionStep(kind: .retrieval, state: .running)

        #expect(disclosure.isExpanded(running))
        disclosure.toggle(running)
        #expect(!disclosure.isExpanded(running))

        var updatedRunning = running
        updatedRunning.details = ["流式更新不应覆盖用户折叠选择"]
        #expect(!disclosure.isExpanded(updatedRunning))
        disclosure.toggle(updatedRunning)
        #expect(disclosure.isExpanded(updatedRunning))

        // 阶段切换到完成态时回到默认折叠，之后仍允许用户自由展开和收起。
        let completed = RAGExecutionStep(kind: .retrieval, state: .completed)
        #expect(!disclosure.isExpanded(completed))
        disclosure.toggle(completed)
        #expect(disclosure.isExpanded(completed))
        disclosure.toggle(completed)
        #expect(!disclosure.isExpanded(completed))
    }

    @Test("RAG 处理耗时按分秒显示")
    func processingDurationUsesMinuteSecondFormat() {
        #expect(RAGProcessingDurationFormatter.string(for: 0.99) == "00:00")
        #expect(RAGProcessingDurationFormatter.string(for: 65.9) == "01:05")
        #expect(RAGProcessingDurationFormatter.string(for: -1) == "00:00")
    }

    @Test("Planner: 结构化条件和远程请求执行本地钳制")
    func plannerClampsRemoteRequest() throws {
        let plan = try KnowledgeRAGQueryPlanner.decodeAndValidate("""
            {
              "mode":"filtered_semantic",
              "semanticQuery":"数据库崩溃问题",
              "filters":{"status":"using","minStars":1000},
              "candidateLimit":9999,
              "remoteContextRequests":[{
                "resource":"github_issues","query":"crash","reason":"需要现场信息",
                "maxRepos":99,"perRepoLimit":99
              }],
              "confidence":"high",
              "userVisiblePlan":{"scope":"知识库","chips":[],"semantic":"数据库崩溃问题"}
            }
            """, fallbackQuestion: "原问题")
        #expect(plan.mode == .filteredSemantic)
        #expect(plan.candidateLimit == 1_000)
        #expect(plan.remoteContextRequests.first?.maxRepos == 5)
        #expect(plan.remoteContextRequests.first?.perRepoLimit == 10)
    }

    @Test("Planner: 远程请求去重并受总工作量预算限制")
    func plannerNormalizesRemoteRequestWorkload() throws {
        let plan = try KnowledgeRAGQueryPlanner.decodeAndValidate("""
            {
              "mode":"semantic_only", "semanticQuery":"近期风险", "filters":{},
              "remoteContextRequests":[
                {"resource":"github_issues","query":" crash ","reason":"A","maxRepos":5,"perRepoLimit":10},
                {"resource":"github_issues","query":"CRASH","reason":"duplicate","maxRepos":5,"perRepoLimit":10},
                {"resource":"github_releases","query":"latest","reason":"B","maxRepos":5,"perRepoLimit":10},
                {"resource":"github_contributors","query":"top","reason":"C","maxRepos":5,"perRepoLimit":10},
                {"resource":"github_pull_requests","query":"open","reason":"over limit","maxRepos":5,"perRepoLimit":10}
              ],
              "confidence":"high", "userVisiblePlan":{"scope":"知识库","chips":[],"semantic":"近期风险"}
            }
            """, fallbackQuestion: "原问题")
        #expect(plan.remoteContextRequests.count == 3)
        #expect(plan.remoteContextRequests.map(\.maxRepos).reduce(0, +) == 8)
        #expect(plan.remoteContextRequests.first?.query == "crash")
    }

    @Test("大文本附件只保留 Prompt 预算内的前缀")
    func attachmentProcessorReadsBoundedTextPrefix() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rag-attachment-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0x61, count: 1_000_000).write(to: url)
        let attachment = RAGComposerAttachment(
            id: UUID(),
            filename: "large.txt",
            contentType: "text/plain",
            sizeInBytes: 1_000_000,
            localURL: url,
            handling: .textContext
        )

        let contexts = try await RAGAttachmentProcessor().process([attachment])
        #expect(contexts.count == 1)
        #expect(contexts[0].content.count == 40_000)
    }

    @Test("工作台错误按可恢复操作分类，技术细节不作为普通文案")
    func workspaceErrorClassification() {
        #expect(RAGWorkspaceError(error: AIClientError.missingAPIKey).kind == .configuration)
        #expect(RAGWorkspaceError(error: GitHubRemoteContextError.http(status: 401, message: "bad token")).kind == .authentication)
        #expect(RAGWorkspaceError(error: URLError(.timedOut)).kind == .timeout)
        #expect(RAGWorkspaceError(error: RAGAttachmentError.unreadable("notes.pdf")).kind == .attachment)
        #expect(RAGWorkspaceError(error: AIClientError.emptyResponse).kind == .generation)
    }

    @Test("Planner: 日期歧义计划必须带追问")
    func plannerClarification() throws {
        let plan = try KnowledgeRAGQueryPlanner.decodeAndValidate("""
            {
              "mode":"needs_clarification",
              "semanticQuery":"Swift 库",
              "filters":{},
              "remoteContextRequests":[],
              "confidence":"needs_clarification",
              "clarificationQuestion":"开始是指加入知识库、Star、创建还是 push 时间？",
              "userVisiblePlan":{"scope":"知识库","chips":[],"semantic":"Swift 库"}
            }
            """, fallbackQuestion: "原问题")
        #expect(plan.mode == .needsClarification)
        #expect(plan.clarificationQuestion?.contains("加入知识库") == true)
    }

    @Test("候选 SQL 同时执行知识库、状态、语言和 stars 条件")
    func structuredCandidateFiltering() async throws {
        let database = try InMemoryDatabaseManager()
        for id in Int64(1)...3 {
            try await database.insertRepoFixture(id: id)
            try await GRDBRepoNoteRepository(database: database).updateLibraryState(repoId: id, state: .inLibrary)
        }
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE repos SET stars_count = 5000, language = 'Swift' WHERE id = 1")
            try db.execute(sql: "UPDATE repo_notes SET status = 'using' WHERE repo_id = 1")
            try db.execute(sql: "UPDATE repos SET stars_count = 100, language = 'Swift' WHERE id = 2")
            try db.execute(sql: "UPDATE repo_notes SET status = 'using' WHERE repo_id = 2")
            try db.execute(sql: "UPDATE repos SET stars_count = 9000, language = 'Go' WHERE id = 3")
            try db.execute(sql: "UPDATE repo_notes SET status = 'using' WHERE repo_id = 3")
        }
        let plan = RAGQueryPlan(
            mode: .filteredSemantic,
            semanticQuery: "RAG",
            filters: RAGRepoFilter(status: .using, languages: ["Swift"], minStars: 1_000)
        )
        let repository = GRDBRAGRepoCandidateRepository(database: database)
        let candidates = try await repository.fetchCandidates(plan: plan, explicitRepoIDs: [], explicitMode: .only)
        #expect(candidates.map(\.repo.id) == [1])
    }

    @Test("@repo only 由本地候选层强制收窄")
    func explicitRepoOnly() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 10)
        try await database.insertRepoFixture(id: 11)
        let notes = GRDBRepoNoteRepository(database: database)
        try await notes.updateLibraryState(repoId: 10, state: .inLibrary)
        try await notes.updateLibraryState(repoId: 11, state: .inLibrary)
        let repository = GRDBRAGRepoCandidateRepository(database: database)
        let plan = RAGQueryPlan(mode: .semanticOnly, semanticQuery: "compare")
        let candidates = try await repository.fetchCandidates(plan: plan, explicitRepoIDs: [11], explicitMode: .only)
        #expect(candidates.map(\.repo.id) == [11])
    }

    @Test("知识库浏览器仓库列表按页返回并正确标记 hasMore")
    func knowledgeBrowserRepositoryPaging() async throws {
        let database = try InMemoryDatabaseManager()
        let notes = GRDBRepoNoteRepository(database: database)
        for id in 1...25 {
            try await database.insertRepoFixture(id: Int64(id))
            try await notes.updateLibraryState(repoId: Int64(id), state: .inLibrary)
            try await database.writer.write { db in
                try db.execute(
                    sql: "UPDATE repos SET stars_count = ? WHERE id = ?",
                    arguments: [1_000 - id, id]
                )
            }
        }
        let repository = GRDBRAGRepoCandidateRepository(database: database)
        // 分页哨兵用稳定 stars 排序断言页边界；默认「最近入库」另有专用用例。
        let first = try await repository.fetchKnowledgeBrowserPage(
            query: "",
            limit: 20,
            offset: 0,
            sort: .starsDesc,
            filters: .empty
        )
        #expect(first.candidates.count == 20)
        #expect(first.hasMore == true)
        #expect(first.candidates.map(\.repo.id) == Array(1...20).map(Int64.init))

        let second = try await repository.fetchKnowledgeBrowserPage(
            query: "",
            limit: 20,
            offset: 20,
            sort: .starsDesc,
            filters: .empty
        )
        #expect(second.candidates.count == 5)
        #expect(second.hasMore == false)
        #expect(second.candidates.map(\.repo.id) == Array(21...25).map(Int64.init))

        let overlap = Set(first.candidates.map(\.repo.id)).intersection(second.candidates.map(\.repo.id))
        #expect(overlap.isEmpty)
    }

    @Test("知识库浏览器默认按 library_updated_at 倒序")
    func knowledgeBrowserDefaultsToLibraryUpdatedAtDesc() async throws {
        let database = try InMemoryDatabaseManager()
        let notes = GRDBRepoNoteRepository(database: database)
        for id in 1...3 {
            try await database.insertRepoFixture(id: Int64(id))
            try await notes.updateLibraryState(repoId: Int64(id), state: .inLibrary)
            try await database.writer.write { db in
                try db.execute(
                    sql: "UPDATE repo_notes SET library_updated_at = ? WHERE repo_id = ?",
                    arguments: ["2026-07-0\(id)T12:00:00Z", id]
                )
            }
        }
        let repository = GRDBRAGRepoCandidateRepository(database: database)
        let page = try await repository.fetchKnowledgeBrowserPage(limit: 10, offset: 0)
        #expect(page.candidates.map(\.repo.id) == [3, 2, 1])
        #expect(RAGComposerMentionSort.default == .libraryUpdatedAtDesc)
    }

    @Test("知识库浏览器列表支持关键词、语言筛选与名称排序")
    func knowledgeBrowserRepositoryQuerySortFilter() async throws {
        let database = try InMemoryDatabaseManager()
        let notes = GRDBRepoNoteRepository(database: database)
        for id in 1...4 {
            try await database.insertRepoFixture(id: Int64(id))
            try await notes.updateLibraryState(repoId: Int64(id), state: .inLibrary)
            try await database.writer.write { db in
                try db.execute(
                    sql: "UPDATE repos SET full_name = ?, language = ?, stars_count = ? WHERE id = ?",
                    arguments: [
                        id <= 2 ? "alpha/repo-\(id)" : "beta/repo-\(id)",
                        id % 2 == 0 ? "Swift" : "Go",
                        100 - id,
                        id,
                    ]
                )
            }
        }
        let repository = GRDBRAGRepoCandidateRepository(database: database)

        var languageFilter = RAGComposerMentionFilters.empty
        languageFilter.selectedLanguages = ["Swift"]
        let filtered = try await repository.fetchKnowledgeBrowserPage(
            query: "",
            limit: 10,
            offset: 0,
            sort: .starsDesc,
            filters: languageFilter
        )
        #expect(filtered.candidates.map(\.repo.id) == [2, 4])
        #expect(filtered.candidates.allSatisfy { $0.repo.language == "Swift" })

        let searched = try await repository.fetchKnowledgeBrowserPage(
            query: "alpha",
            limit: 10,
            offset: 0,
            sort: .nameAsc,
            filters: .empty
        )
        #expect(searched.candidates.map(\.repo.id) == [1, 2])
        #expect(searched.candidates.map(\.repo.fullName) == ["alpha/repo-1", "alpha/repo-2"])
    }

    @Test("上下文选择器轻量候选按关键词分页并仅在选择后回填完整仓库")
    func mentionCandidateProjectionPaging() async throws {
        let database = try InMemoryDatabaseManager()
        let notes = GRDBRepoNoteRepository(database: database)
        for id in 1...6 {
            try await database.insertRepoFixture(id: Int64(id))
            try await notes.updateLibraryState(repoId: Int64(id), state: .inLibrary)
            try await database.writer.write { db in
                try db.execute(
                    sql: "UPDATE repos SET language = ?, stars_count = ? WHERE id = ?",
                    arguments: [id <= 4 ? "Swift" : "Go", 100 - id, id]
                )
            }
        }
        let repository = GRDBRAGRepoCandidateRepository(database: database)

        let first = try await repository.fetchMentionCandidates(query: "swift", limit: 2, offset: 0)
        #expect(first.knowledgeCount == 6)
        #expect(first.matchCount == 4)
        #expect(first.candidates.count == 2)
        #expect(first.hasMore)
        #expect(first.candidates.allSatisfy { $0.normalizedSearchText.contains("swift") })

        let second = try await repository.fetchMentionCandidates(query: "swift", limit: 2, offset: 2)
        #expect(second.candidates.count == 2)
        #expect(!second.hasMore)
        #expect(Set(first.candidates.map(\.id)).isDisjoint(with: second.candidates.map(\.id)))

        let hydrated = try await repository.fetchMentionRepos(ids: [3, 1])
        #expect(hydrated.map(\.id) == [3, 1])
        try await notes.updateLibraryState(repoId: 3, state: .outsideLibrary)
        #expect(try await repository.fetchMentionRepos(ids: [3, 1]).map(\.id) == [1])
    }

    @Test("上下文选择器关键词覆盖私有笔记")
    func contextPickerCandidateMatchesPrivateNotes() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 1)
        let notes = GRDBRepoNoteRepository(database: database)
        try await notes.updateLibraryState(repoId: 1, state: .inLibrary)
        try await notes.upsert(RepoNote(
            repoId: 1,
            content: "用于替代旧版部署脚本",
            status: "unread",
            libraryState: LibraryState.inLibrary.rawValue,
            isAIGenerated: false,
            editedAt: "2026-07-16T00:00:00Z"
        ))

        let repository = GRDBRAGRepoCandidateRepository(database: database)
        let page = try await repository.fetchMentionCandidates(
            query: "替代旧版",
            limit: 20,
            offset: 0
        )

        #expect(page.matchCount == 1)
        #expect(page.candidates.map(\.id) == [1])
    }

    @Test("上下文选择器投影带出分片数、AI 摘要与私有笔记标记")
    func mentionCandidateIndexSideMetadata() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 1)
        try await database.insertRepoFixture(id: 2)
        let notes = GRDBRepoNoteRepository(database: database)
        try await notes.updateLibraryState(repoId: 1, state: .inLibrary)
        try await notes.updateLibraryState(repoId: 2, state: .inLibrary)
        try await notes.upsert(RepoNote(
            repoId: 1,
            content: "部署备忘",
            status: "unread",
            libraryState: LibraryState.inLibrary.rawValue,
            isAIGenerated: false,
            editedAt: "2026-07-17T00:00:00Z"
        ))
        try await database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO ai_summaries (repo_id, model, source_hash, summary_json, generated_at)
                VALUES (1, 'test-model', 'hash', '{}', datetime('now'))
                """)
            try db.execute(sql: """
                INSERT INTO rag_chunks (
                    repo_id, source, source_id, parent_type, parent_key, parent_title, chunk_key,
                    chunk_index, section_path, title, content, content_hash, token_count, is_truncated,
                    embedding_model, embedding_status, created_at, updated_at
                ) VALUES
                    (1, 'readme', '', 'readme', 'readme', 'README', 'readme:0', 0, '', 'README', 'a', 'h1', 1, 0, 'embed', 'ready', datetime('now'), datetime('now')),
                    (1, 'readme', '', 'readme', 'readme', 'README', 'readme:1', 1, '', 'README', 'b', 'h2', 1, 0, 'embed', 'ready', datetime('now'), datetime('now'))
                """)
        }

        let repository = GRDBRAGRepoCandidateRepository(database: database)
        let page = try await repository.fetchMentionCandidates(
            query: "",
            limit: 10,
            offset: 0,
            sort: .starsDesc,
            filters: .empty
        )
        let withMeta = try #require(page.candidates.first(where: { $0.id == 1 }))
        let bare = try #require(page.candidates.first(where: { $0.id == 2 }))
        #expect(withMeta.chunkCount == 2)
        #expect(withMeta.hasAISummary)
        #expect(withMeta.hasPrivateNote)
        #expect(bare.chunkCount == 0)
        #expect(!bare.hasAISummary)
        #expect(!bare.hasPrivateNote)
    }

    @Test("上下文选择器支持面板排序与筛选，且筛选不含知识库维度")
    func mentionCandidateSortAndFilters() async throws {
        let database = try InMemoryDatabaseManager()
        let notes = GRDBRepoNoteRepository(database: database)
        for id in 1...4 {
            try await database.insertRepoFixture(id: Int64(id))
            try await notes.updateLibraryState(repoId: Int64(id), state: .inLibrary)
            try await database.writer.write { db in
                try db.execute(
                    sql: """
                        UPDATE repos
                        SET language = ?, stars_count = ?, is_fork = ?, is_archived = ?
                        WHERE id = ?
                        """,
                    arguments: [
                        id % 2 == 0 ? "Go" : "Swift",
                        id * 10,
                        id == 4,
                        id == 3,
                        id
                    ]
                )
            }
        }

        let repository = GRDBRAGRepoCandidateRepository(database: database)

        let byStars = try await repository.fetchMentionCandidates(
            query: "",
            limit: 10,
            offset: 0,
            sort: .starsDesc,
            filters: .empty
        )
        #expect(byStars.candidates.map(\.id) == [4, 3, 2, 1])

        var filters = RAGComposerMentionFilters.empty
        filters.selectedLanguages = ["Swift"]
        filters.hideForks = true
        filters.hideArchived = true
        let filtered = try await repository.fetchMentionCandidates(
            query: "",
            limit: 10,
            offset: 0,
            sort: .starsDesc,
            filters: filters
        )
        #expect(filtered.candidates.map(\.id) == [1])
        #expect(filters.isActive)
        #expect(RAGComposerMentionFilters.empty.isActive == false)
        #expect(RAGComposerMentionSort.default == .libraryUpdatedAtDesc)
    }

    @Test("混合融合合并命中并限制每个 repo 的 child 数")
    func hybridFusionDeduplicatesAndCapsRepo() throws {
        let chunks = (1...5).map { index in fixtureChunk(id: Int64(index), repoID: index <= 4 ? 1 : 2, source: index == 1 ? .notes : .readme) }
        let keyword = chunks.map { RAGChildHit(chunk: $0, score: 1, kind: .keyword) }
        let vector = chunks.reversed().map {
            RAGChildHit(chunk: $0, score: 0.9, kind: .vector, vectorSimilarity: 0.9)
        }
        let engine = RAGHybridFusionEngine(configuration: .init(perRepoLimit: 2, totalLimit: 10))
        let hits = engine.fuse(keywordHits: keyword, vectorHits: vector)
        #expect(hits.filter { $0.chunk.repoId == 1 }.count == 2)
        #expect(hits.contains { $0.kind == .hybrid })
        #expect(hits.first(where: { $0.kind == .hybrid })?.vectorSimilarity == 0.9)
        let hybridHit = try #require(hits.first(where: { $0.kind == .hybrid }))
        let breakdown = try #require(hybridHit.scoreBreakdown)
        #expect(breakdown.keywordRank != nil)
        #expect(breakdown.vectorRank != nil)
    }

    @Test("纯 keyword 首名超过综合检索分阈值")
    func keywordOnlyHitSurvivesEvidenceThreshold() throws {
        let chunk = fixtureChunk(id: 8, repoID: 1, source: .readme)
        let hits = RAGHybridFusionEngine().fuse(
            keywordHits: [RAGChildHit(chunk: chunk, score: 1, kind: .keyword)],
            vectorHits: []
        )
        let hit = try #require(hits.first)
        #expect(hit.kind == .keyword)
        #expect(hit.score >= 0.08)
    }

    @Test("query embedding 失败时保留 keyword 检索结果")
    func embeddingFailureKeepsKeywordResults() async throws {
        let database = try InMemoryDatabaseManager()
        let chunk = fixtureChunk(id: 81, repoID: 1, source: .readme)
        let retriever = KnowledgeRAGRetriever(
            chunkRepository: GRDBRAGChunkRepository(database: database),
            keywordProvider: StubRAGKeywordProvider(
                backendName: "SQLite",
                hits: [RAGChildHit(chunk: chunk, score: 1, kind: .keyword)],
                shouldThrow: false
            ),
            vectorProvider: StubRAGVectorProvider(backendName: "SQLite", hits: [], shouldThrow: false),
            embeddingClient: SpyRAGAIClient(failEmbedding: true),
            embeddingModel: "embed"
        )

        let result = try await retriever.retrieve(
            semanticQuery: "database",
            candidates: [RAGRepoCandidate(
                repo: fixtureRepo(id: 1, isPrivate: false),
                status: .using,
                libraryUpdatedAt: nil,
                tagNames: []
            )],
            explicitMode: .only,
            explicitRepoIDs: []
        )

        #expect(result.childHits.count == 1)
        #expect(result.childHits.first?.kind == .keyword)
    }

    @Test("检索设置仅过滤向量阈值，并尊重分片来源开关")
    func retrievalSettingsFilterVectorAndSources() async throws {
        let database = try InMemoryDatabaseManager()
        let keywordChunk = fixtureChunk(id: 82, repoID: 1, source: .readme)
        let lowSimilarityChunk = fixtureChunk(id: 83, repoID: 1, source: .readme)
        let disabledSourceChunk = fixtureChunk(id: 84, repoID: 1, source: .metadata)
        let highSimilarityChunk = fixtureChunk(id: 85, repoID: 1, source: .readme)
        let retriever = KnowledgeRAGRetriever(
            chunkRepository: GRDBRAGChunkRepository(database: database),
            keywordProvider: StubRAGKeywordProvider(
                backendName: "SQLite",
                hits: [RAGChildHit(chunk: keywordChunk, score: 1, kind: .keyword)],
                shouldThrow: false
            ),
            vectorProvider: StubRAGVectorProvider(
                backendName: "SQLite",
                hits: [
                    RAGChildHit(chunk: lowSimilarityChunk, score: 0.64, kind: .vector, vectorSimilarity: 0.64),
                    RAGChildHit(chunk: disabledSourceChunk, score: 0.99, kind: .vector, vectorSimilarity: 0.99),
                    RAGChildHit(chunk: highSimilarityChunk, score: 0.80, kind: .vector, vectorSimilarity: 0.80)
                ],
                shouldThrow: false
            ),
            embeddingClient: SpyRAGAIClient(),
            embeddingModel: "embed",
            retrievalSettings: RAGRetrievalSettings(
                minimumVectorSimilarity: 0.65,
                finalEvidenceChunkLimit: 8,
                perRepositoryEvidenceLimit: 3,
                evidenceTokenBudget: 8_000,
                enabledSources: [.readme]
            )
        )

        let result = try await retriever.retrieve(
            semanticQuery: "database",
            candidates: [RAGRepoCandidate(
                repo: fixtureRepo(id: 1, isPrivate: false),
                status: .using,
                libraryUpdatedAt: nil,
                tagNames: []
            )],
            explicitMode: .only,
            explicitRepoIDs: []
        )

        #expect(Set(result.childHits.compactMap(\.chunk.id)) == [82, 85])
        #expect(result.childHits.contains { $0.kind == .keyword })
        let diagnostics = try #require(result.diagnostics)
        #expect(diagnostics.keywordRawCount == 1)
        #expect(diagnostics.keywordSourceFilteredCount == 0)
        #expect(diagnostics.vectorRawCount == 3)
        #expect(diagnostics.vectorSourceFilteredCount == 1)
        #expect(diagnostics.vectorSimilarityFilteredCount == 1)
        #expect(diagnostics.finalChildHitCount == 2)
        let trace = try #require(result.trace)
        #expect(trace.candidates.map(\.fullName) == ["octo/demo-1"])
        #expect(trace.semanticHits.contains { $0.chunkID == 84 && $0.disposition == .sourceDisabled })
        #expect(trace.semanticHits.contains { $0.chunkID == 83 && $0.disposition == .belowVectorSimilarity })
        #expect(trace.semanticHits.contains { $0.chunkID == 85 && $0.disposition == .retained })
        // 当前融合配置同时计入原始分数，0.80 的向量首名应高于纯关键词首名。
        #expect(trace.finalEvidence.map(\.chunkID) == [85, 82])
        #expect(diagnostics.debugPayload().contains(
            String(
                format: String.l10n("rag.workspace.debug.retrieval.funnel.semanticFormat"),
                3,
                1,
                1,
                1
            )
        ))
    }

    @Test("检索设置会限制最终分片总数与单仓库分片数")
    func retrievalSettingsCapFinalEvidence() async throws {
        let database = try InMemoryDatabaseManager()
        let firstRepoFirst = fixtureChunk(id: 86, repoID: 1, source: .readme)
        let firstRepoSecond = fixtureChunk(id: 87, repoID: 1, source: .readme)
        let secondRepoFirst = fixtureChunk(id: 88, repoID: 2, source: .readme)
        let thirdRepoFirst = fixtureChunk(id: 89, repoID: 3, source: .readme)
        let retriever = KnowledgeRAGRetriever(
            chunkRepository: GRDBRAGChunkRepository(database: database),
            keywordProvider: StubRAGKeywordProvider(
                backendName: "SQLite",
                hits: [
                    RAGChildHit(chunk: firstRepoFirst, score: 1, kind: .keyword),
                    RAGChildHit(chunk: firstRepoSecond, score: 1, kind: .keyword),
                    RAGChildHit(chunk: secondRepoFirst, score: 1, kind: .keyword),
                    RAGChildHit(chunk: thirdRepoFirst, score: 1, kind: .keyword)
                ],
                shouldThrow: false
            ),
            vectorProvider: StubRAGVectorProvider(backendName: "SQLite", hits: [], shouldThrow: false),
            embeddingClient: SpyRAGAIClient(),
            embeddingModel: "embed",
            retrievalSettings: RAGRetrievalSettings(
                minimumVectorSimilarity: 0.65,
                finalEvidenceChunkLimit: 3,
                perRepositoryEvidenceLimit: 1,
                evidenceTokenBudget: 8_000,
                enabledSources: [.readme]
            )
        )

        let result = try await retriever.retrieve(
            semanticQuery: "database",
            candidates: [
                RAGRepoCandidate(repo: fixtureRepo(id: 1, isPrivate: false), status: .using, libraryUpdatedAt: nil, tagNames: []),
                RAGRepoCandidate(repo: fixtureRepo(id: 2, isPrivate: false), status: .using, libraryUpdatedAt: nil, tagNames: []),
                RAGRepoCandidate(repo: fixtureRepo(id: 3, isPrivate: false), status: .using, libraryUpdatedAt: nil, tagNames: [])
            ],
            explicitMode: .only,
            explicitRepoIDs: []
        )

        #expect(result.childHits.count == 3)
        #expect(Set(result.childHits.map(\.chunk.repoId)) == [1, 2, 3])
        let diagnostics = try #require(result.diagnostics)
        #expect(diagnostics.fusion.uniqueCount == 4)
        #expect(diagnostics.fusion.perRepositoryLimitFilteredCount == 1)
        #expect(diagnostics.fusion.totalLimitFilteredCount == 0)
    }

    @Test("Rerank 在最终分片裁剪前重排，失败时保留综合检索顺序")
    func rerankReordersBeforeEvidenceLimitsAndFallsBack() async throws {
        let database = try InMemoryDatabaseManager()
        let first = fixtureChunk(id: 301, repoID: 1, source: .readme)
        let second = fixtureChunk(id: 302, repoID: 2, source: .readme)
        let third = fixtureChunk(id: 303, repoID: 3, source: .readme)
        let candidates = [1, 2, 3].map {
            RAGRepoCandidate(repo: fixtureRepo(id: Int64($0), isPrivate: false), status: .using, libraryUpdatedAt: nil, tagNames: [])
        }
        func makeRetriever(reranker: (any RAGReranking)?) -> KnowledgeRAGRetriever {
            KnowledgeRAGRetriever(
                chunkRepository: GRDBRAGChunkRepository(database: database),
                keywordProvider: StubRAGKeywordProvider(
                    backendName: "SQLite",
                    hits: [
                        RAGChildHit(chunk: first, score: 1, kind: .keyword),
                        RAGChildHit(chunk: second, score: 0.5, kind: .keyword),
                        RAGChildHit(chunk: third, score: 0.33, kind: .keyword)
                    ],
                    shouldThrow: false
                ),
                vectorProvider: StubRAGVectorProvider(backendName: "SQLite", hits: [], shouldThrow: false),
                embeddingClient: SpyRAGAIClient(),
                embeddingModel: "embed",
                // 本测试只验证 Rerank 与分片上限的先后顺序，不能让最低综合检索分再次裁掉候选。
                minimumEvidenceScore: 0,
                retrievalSettings: RAGRetrievalSettings(
                    minimumVectorSimilarity: 0.65,
                    finalEvidenceChunkLimit: 3,
                    perRepositoryEvidenceLimit: 1,
                    evidenceTokenBudget: 8_000,
                    enabledSources: [.readme]
                ),
                reranker: reranker
            )
        }

        let reordered = try await makeRetriever(
            reranker: StubRAGReranker(order: [303, 302, 301])
        ).retrieve(semanticQuery: "query", candidates: candidates, explicitMode: .only, explicitRepoIDs: [])
        #expect(reordered.childHits.compactMap(\.chunk.id) == [303, 302, 301])
        #expect(reordered.diagnostics?.rerank?.state == .completed)
        #expect(reordered.diagnostics?.rerank?.provider == .huggingFaceTEI)
        let rerankTrace = try #require(reordered.diagnostics?.rerank?.trace)
        #expect(rerankTrace.query == "query")
        #expect(rerankTrace.inputCandidates.map(\.repositoryName) == ["octo/demo-1", "octo/demo-2", "octo/demo-3"])
        #expect(rerankTrace.responseResults.map(\.inputIndex) == [2, 1, 0])
        #expect(rerankTrace.appliedOrder.compactMap(\.inputIndex) == [2, 1, 0])
        #expect(reordered.trace?.rerank == rerankTrace)

        let fallback = try await makeRetriever(
            reranker: StubRAGReranker(order: [], shouldThrow: true)
        ).retrieve(semanticQuery: "query", candidates: candidates, explicitMode: .only, explicitRepoIDs: [])
        #expect(fallback.childHits.compactMap(\.chunk.id) == [301, 302, 303])
        #expect(fallback.diagnostics?.rerank?.state == .failedFallback)
        #expect(fallback.diagnostics?.rerank?.trace?.responseResults.isEmpty == true)
    }

    @Test("Hugging Face TEI Rerank 使用 texts 协议并解析 score")
    func huggingFaceTEIRerankerUsesTEIProtocol() async throws {
        let first = fixtureChunk(id: 401, repoID: 1, source: .readme)
        let second = fixtureChunk(id: 402, repoID: 2, source: .readme)
        let client = RecordingRAGHTTPClient(
            data: Data(#"[{"index":1,"score":0.91},{"index":0,"score":0.15}]"#.utf8)
        )
        let reranker = HuggingFaceTEIRAGReranker(
            configuration: RAGRerankConfiguration(
                isEnabled: true,
                provider: .huggingFaceTEI,
                endpoint: "http://127.0.0.1:8080/rerank",
                candidateLimit: 10
            ),
            apiKey: "tei-token",
            httpClient: client
        )

        let result = try await reranker.rerank(
            query: "SwiftUI",
            candidates: [RAGChildHit(chunk: first, score: 0.4, kind: .vector), RAGChildHit(chunk: second, score: 0.3, kind: .vector)]
        )

        #expect(result.compactMap(\.hit.chunk.id) == [402, 401])
        let request = try #require(await client.lastRequest())
        #expect(request.url?.path == "/rerank")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tei-token")
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["query"] as? String == "SwiftUI")
        #expect((json["texts"] as? [String])?.count == 2)
        #expect(json["documents"] == nil)
        #expect(json["model"] == nil)
    }

    @Test("Cohere-compatible Rerank 使用 model/documents/top_n 协议")
    func cohereCompatibleRerankerUsesCohereProtocol() async throws {
        let first = fixtureChunk(id: 501, repoID: 1, source: .readme)
        let second = fixtureChunk(id: 502, repoID: 2, source: .readme)
        let client = RecordingRAGHTTPClient(
            data: Data(#"{"results":[{"index":1,"relevance_score":0.98},{"index":0,"relevance_score":0.21}]}"#.utf8)
        )
        let reranker = CohereCompatibleRAGReranker(
            configuration: RAGRerankConfiguration(
                isEnabled: true,
                provider: .cohereCompatible,
                endpoint: "https://rerank.example.test/v2/rerank",
                model: "rerank-v4.0-pro",
                candidateLimit: 10
            ),
            apiKey: "cohere-token",
            httpClient: client
        )

        let result = try await reranker.rerank(
            query: "SwiftUI",
            candidates: [RAGChildHit(chunk: first, score: 0.4, kind: .vector), RAGChildHit(chunk: second, score: 0.3, kind: .vector)]
        )

        #expect(result.compactMap(\.hit.chunk.id) == [502, 501])
        let request = try #require(await client.lastRequest())
        #expect(request.url?.path == "/v2/rerank")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer cohere-token")
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "rerank-v4.0-pro")
        #expect((json["documents"] as? [String])?.count == 2)
        #expect(json["top_n"] as? Int == 2)
        #expect(json["texts"] == nil)
    }

    @Test("Rerank 共用候选编号会截断输入并忽略越界结果")
    func rerankCandidateMappingUsesRequestSnapshot() async throws {
        // candidateLimit 的产品下限是 10，这里准备 12 项以覆盖真实归一化后的截断边界。
        let candidates = (601...612).map { id in
            RAGChildHit(chunk: fixtureChunk(id: Int64(id), repoID: Int64(id), source: .readme), score: 0.1, kind: .vector)
        }
        let teiClient = RecordingRAGHTTPClient(
            data: Data(#"[{"index":11,"score":1.0},{"index":9,"score":0.8}]"#.utf8)
        )
        let cohereClient = RecordingRAGHTTPClient(
            data: Data(#"{"results":[{"index":11,"relevance_score":1.0},{"index":0,"relevance_score":0.7}]}"#.utf8)
        )
        let base = RAGRerankConfiguration(
            isEnabled: true,
            provider: .huggingFaceTEI,
            endpoint: "http://127.0.0.1:8080/rerank",
            candidateLimit: 10
        )

        let teiResult = try await HuggingFaceTEIRAGReranker(
            configuration: base,
            httpClient: teiClient
        ).rerank(query: "query", candidates: candidates)
        var cohereConfiguration = base
        cohereConfiguration.provider = .cohereCompatible
        cohereConfiguration.model = "rerank-model"
        let cohereResult = try await CohereCompatibleRAGReranker(
            configuration: cohereConfiguration,
            apiKey: "   ",
            httpClient: cohereClient
        ).rerank(query: "query", candidates: candidates)

        #expect(teiResult.compactMap(\.hit.chunk.id) == [610])
        #expect(cohereResult.compactMap(\.hit.chunk.id) == [601])
        let teiBody = try #require(await teiClient.lastRequest()?.httpBody)
        let teiJSON = try #require(JSONSerialization.jsonObject(with: teiBody) as? [String: Any])
        #expect((teiJSON["texts"] as? [String])?.count == 10)
        let cohereRequest = try #require(await cohereClient.lastRequest())
        #expect(cohereRequest.value(forHTTPHeaderField: "Authorization") == nil)
        let cohereBody = try #require(cohereRequest.httpBody)
        let cohereJSON = try #require(JSONSerialization.jsonObject(with: cohereBody) as? [String: Any])
        #expect(cohereJSON["top_n"] as? Int == 10)
    }

    @Test("关闭全部分片来源时返回可解释的检索诊断")
    func retrievalDiagnosticsExplainDisabledSources() async throws {
        let database = try InMemoryDatabaseManager()
        let retriever = KnowledgeRAGRetriever(
            chunkRepository: GRDBRAGChunkRepository(database: database),
            keywordProvider: StubRAGKeywordProvider(backendName: "SQLite", hits: [], shouldThrow: false),
            vectorProvider: StubRAGVectorProvider(backendName: "SQLite", hits: [], shouldThrow: false),
            embeddingClient: SpyRAGAIClient(),
            embeddingModel: "embed",
            retrievalSettings: RAGRetrievalSettings(
                minimumVectorSimilarity: 0.65,
                finalEvidenceChunkLimit: 8,
                perRepositoryEvidenceLimit: 3,
                evidenceTokenBudget: 8_000,
                enabledSources: []
            )
        )

        let result = try await retriever.retrieve(
            semanticQuery: "database",
            candidates: [RAGRepoCandidate(
                repo: fixtureRepo(id: 1, isPrivate: false),
                status: .using,
                libraryUpdatedAt: nil,
                tagNames: []
            )],
            explicitMode: .only,
            explicitRepoIDs: []
        )

        let diagnostics = try #require(result.diagnostics)
        #expect(diagnostics.outcome == .sourcesDisabled)
        #expect(diagnostics.debugPayload().contains(
            String(
                format: String.l10n("rag.workspace.debug.retrieval.settings.sourcesFormat"),
                String.l10n("rag.workspace.debug.retrieval.sources.none")
            )
        ))
    }

    @Test("检索 Debug 事件延迟本地化并保留最终分片")
    func retrievalDebugEventRendersStructuredPayloadOnDemand() {
        let diagnostics = RAGRetrievalDiagnostics(
            settings: RAGRetrievalSettings(
                minimumVectorSimilarity: 0.65,
                finalEvidenceChunkLimit: 8,
                perRepositoryEvidenceLimit: 3,
                evidenceTokenBudget: 8_000,
                enabledSources: [.readme]
            ),
            candidateRepoCount: 1,
            finalChildHitCount: 3,
            bundleCount: 1,
            outcome: .completed
        )
        let event = RAGDebugEvent(
            stage: .retrieval,
            elapsedSeconds: 1,
            payload: "",
            retrievalPayload: RAGRetrievalDebugPayload(
                diagnostics: diagnostics,
                evidenceDetails: "repo: example/repository"
            )
        )

        let rendered = event.renderedPayload()
        #expect(rendered.contains(String.l10n("rag.workspace.debug.retrieval.settings.title")))
        #expect(rendered.contains(String.l10n("rag.workspace.debug.retrieval.evidenceDetails.title")))
        #expect(rendered.contains("repo: example/repository"))
    }

    @Test("Rerank Debug 作为独立 Trace 行，不写入检索详情")
    func rerankDebugEventUsesDedicatedStage() {
        let trace = RAGRerankTrace(
            query: "How do I configure BetterDisplay?",
            model: nil,
            candidateLimit: 24,
            inputCandidates: [
                .init(
                    inputIndex: 0,
                    repositoryName: "waydabber/BetterDisplay",
                    source: .readme,
                    section: "Configuration",
                    preRerankScore: 0.131
                )
            ],
            responseResults: [.init(inputIndex: 0, rerankScore: 0.842)],
            appliedOrder: [.init(rank: 1, inputIndex: 0, rerankScore: 0.842)]
        )
        let rerank = RAGRerankDiagnostics(
            state: .completed,
            provider: .huggingFaceTEI,
            candidateCount: 11,
            rerankedCount: 11,
            elapsedSeconds: 0.42,
            trace: trace
        )
        let event = RAGDebugEvent(
            stage: .rerank,
            elapsedSeconds: 1,
            payload: "",
            rerankPayload: RAGRerankDebugPayload(diagnostics: rerank)
        )
        let retrievalDiagnostics = RAGRetrievalDiagnostics(
            settings: .balanced,
            candidateRepoCount: 1,
            rerank: rerank,
            outcome: .completed
        )

        #expect(event.stage == .rerank)
        #expect(event.renderedPayload().contains(String.l10n("rag.workspace.debug.rerank.request.title")))
        #expect(event.renderedPayload().contains(trace.query))
        #expect(event.renderedPayload().contains(trace.inputCandidates[0].repositoryName))
        #expect(!event.renderedPayload().contains("Rerank Response"))
        #expect(!event.renderedPayload().contains("Rerank 返回"))
        #expect(event.renderedPayload().contains(String.l10n("rag.workspace.debug.rerank.applied.title")))
        #expect(!retrievalDiagnostics.debugPayload().contains(rerank.debugPayload()))
    }

    @Test("Rerank Debug 显示真实分数并把未参与候选压缩为备注")
    func rerankDebugRendersScoreAndCompactsTrailingCandidates() {
        let trace = RAGRerankTrace(
            query: "query",
            model: nil,
            candidateLimit: 2,
            inputCandidates: [
                .init(
                    inputIndex: 0,
                    repositoryName: "octo/first",
                    source: .readme,
                    section: "First",
                    preRerankScore: 0.5
                ),
                .init(
                    inputIndex: 1,
                    repositoryName: "octo/second",
                    source: .readme,
                    section: "Second",
                    preRerankScore: 0.4
                )
            ],
            responseResults: [.init(inputIndex: 0, rerankScore: 0.842)],
            appliedOrder: [
                .init(rank: 1, inputIndex: 0, rerankScore: 0.842),
                .init(rank: 2, inputIndex: 1, rerankScore: nil),
                .init(rank: 3, inputIndex: nil, rerankScore: nil),
                .init(rank: 4, inputIndex: nil, rerankScore: nil)
            ]
        )
        let payload = RAGRerankDebugPayload(diagnostics: RAGRerankDiagnostics(
            state: .completed,
            provider: .huggingFaceTEI,
            candidateCount: 2,
            rerankedCount: 1,
            trace: trace
        ))

        let rendered = payload.renderedText()
        let notes = payload.renderedAppliedNotes()
        let expectedAppliedLine = String(
            format: String.l10n("rag.workspace.debug.rerank.appliedResultFormat"),
            1,
            0,
            0.842
        )
        #expect(rendered.contains("- \(expectedAppliedLine)"))
        #expect(rendered.contains("0.8420"))
        #expect(!rendered.contains("0.842000"))
        #expect(!rendered.contains("Rerank Response"))
        #expect(!rendered.contains("Rerank 返回"))
        #expect(notes.count == 2)
        #expect(notes.allSatisfy { rendered.contains($0) })
        #expect(notes.contains(String(
            format: String.l10n("rag.workspace.debug.rerank.appliedUnsentNoteFormat"),
            2,
            2
        )))
    }

    @MainActor
    @Test("工作台保留独立 Rerank Debug 的结构化内容")
    func workspaceDebugEventPreservesRerankPayload() {
        let rerank = RAGRerankDiagnostics(
            state: .completed,
            provider: .huggingFaceTEI,
            candidateCount: 1,
            rerankedCount: 1,
            elapsedSeconds: 0.42,
            trace: RAGRerankTrace(
                query: "How do I configure BetterDisplay?",
                model: nil,
                candidateLimit: 24,
                inputCandidates: [],
                responseResults: [],
                appliedOrder: []
            )
        )
        let original = RAGDebugEvent(
            stage: .rerank,
            elapsedSeconds: 1,
            payload: "",
            rerankPayload: RAGRerankDebugPayload(diagnostics: rerank)
        )

        let bounded = KnowledgeRAGWorkspaceViewModel.boundedDebugEvent(original)
        let rebased = KnowledgeRAGWorkspaceViewModel.rebasedDebugEvent(bounded, offset: 2)

        #expect(bounded.rerankPayload?.diagnostics == rerank)
        #expect(rebased.rerankPayload?.diagnostics == rerank)
        #expect(rebased.elapsedSeconds == 3)
        #expect(rebased.renderedPayload().contains("How do I configure BetterDisplay?"))
    }

    @Test("RAG Debug 清空只删除当前会话的文件")
    func debugFilesDeleteOnlyCurrentConversation() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("starcat-rag-debug-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = RAGDebugFileStore(rootOverride: root)
        let conversationID = UUID()
        let otherConversationID = UUID()
        let older = fixtureDebugTrace(startedAt: Date(timeIntervalSince1970: 1_000))
        let newer = fixtureDebugTrace(startedAt: Date(timeIntervalSince1970: 2_000))
        let otherTrace = fixtureDebugTrace(startedAt: Date(timeIntervalSince1970: 3_000))

        try await store.save(trace: older, conversationID: conversationID, userMessageID: UUID())
        try await store.save(trace: newer, conversationID: conversationID, userMessageID: UUID())
        try await store.save(trace: otherTrace, conversationID: otherConversationID, userMessageID: UUID())

        let loaded = try await store.load(conversationID: conversationID)
        #expect(loaded.map(\.id) == [newer.id, older.id])
        let latestOnly = try await store.load(conversationID: conversationID, limit: 1)
        #expect(latestOnly.map(\.id) == [newer.id])

        try await store.delete(conversationID: conversationID)
        let afterDeletion = try await store.load(conversationID: conversationID)
        #expect(afterDeletion.isEmpty)
        #expect(try await store.load(conversationID: otherConversationID).map(\.id) == [otherTrace.id])
    }

    @Test("RAG Debug 写入和读取都会收敛每会话磁盘上限")
    func debugFilesRespectPerConversationDiskLimits() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("starcat-rag-debug-retention-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let conversationID = UUID()
        let generousStore = RAGDebugFileStore(
            rootOverride: root,
            maxFilesPerConversation: 10,
            maxBytesPerConversation: 1_024 * 1_024
        )
        let oldest = fixtureDebugTrace(startedAt: Date(timeIntervalSince1970: 1_000))
        let middle = fixtureDebugTrace(startedAt: Date(timeIntervalSince1970: 2_000))
        let newest = fixtureDebugTrace(startedAt: Date(timeIntervalSince1970: 3_000))
        for trace in [oldest, middle, newest] {
            try await generousStore.save(trace: trace, conversationID: conversationID, userMessageID: UUID())
        }

        // 模拟升级前已经积累的无限目录：新 Store 首次读取时必须先按新配置裁剪，
        // 且只解码仍在预算内的最新文件。
        let boundedStore = RAGDebugFileStore(
            rootOverride: root,
            maxFilesPerConversation: 2,
            maxBytesPerConversation: 1_024 * 1_024
        )
        let loaded = try await boundedStore.load(conversationID: conversationID)
        #expect(loaded.map(\.id) == [newest.id, middle.id])

        let afterUpgrade = fixtureDebugTrace(startedAt: Date(timeIntervalSince1970: 4_000))
        try await boundedStore.save(trace: afterUpgrade, conversationID: conversationID, userMessageID: UUID())
        #expect(try await boundedStore.load(conversationID: conversationID).map(\.id) == [afterUpgrade.id, newest.id])

        let directory = root.appendingPathComponent(conversationID.uuidString, isDirectory: true)
        let retainedFiles = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        ).filter { $0.pathExtension == "json" }
        #expect(retainedFiles.count == 2)

        // 总字节预算比任一记录还小时允许全部淘汰；Debug 是可丢弃数据，严格上界优先。
        let byteBoundedStore = RAGDebugFileStore(
            rootOverride: root,
            maxFilesPerConversation: 10,
            maxBytesPerConversation: 1
        )
        #expect(try await byteBoundedStore.load(conversationID: conversationID).isEmpty)
        let remainingFiles = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        #expect(remainingFiles.isEmpty)
    }

    @Test("Parent context 围绕后段命中而不是只取章节开头")
    func parentContextIncludesAnchorChunk() throws {
        let chunks = (1...4).map { index -> RAGChunk in
            var chunk = fixtureChunk(id: Int64(index), repoID: 1, source: .readme)
            chunk.chunkIndex = index - 1
            chunk.tokenCount = 900
            chunk.content = String(repeating: "content ", count: 450)
            return chunk
        }
        let selected = RAGParentContextPacker().select(
            chunks: chunks,
            anchorChunkID: 4,
            tokenLimit: 1_000
        )
        #expect(selected.map(\.id) == [4])
    }

    @Test("私有 repo 的两路检索不发送给外部 provider")
    func privateReposUseLocalProviders() async throws {
        let database = try InMemoryDatabaseManager()
        let publicRecorder = RAGRepoIDRecorder()
        let privateRecorder = RAGRepoIDRecorder()
        let chunks = GRDBRAGChunkRepository(database: database)
        let retriever = KnowledgeRAGRetriever(
            chunkRepository: chunks,
            keywordProvider: RecordingRAGKeywordProvider(backendName: "external", recorder: publicRecorder),
            vectorProvider: RecordingRAGVectorProvider(backendName: "external", recorder: publicRecorder),
            privateRepoKeywordProvider: RecordingRAGKeywordProvider(backendName: "local", recorder: privateRecorder),
            privateRepoVectorProvider: RecordingRAGVectorProvider(backendName: "local", recorder: privateRecorder),
            embeddingClient: SpyRAGAIClient(),
            embeddingModel: "embed"
        )
        let candidates = [
            RAGRepoCandidate(repo: fixtureRepo(id: 1, isPrivate: false), status: .unread, libraryUpdatedAt: nil, tagNames: []),
            RAGRepoCandidate(repo: fixtureRepo(id: 2, isPrivate: true), status: .unread, libraryUpdatedAt: nil, tagNames: [])
        ]

        _ = try await retriever.retrieve(
            semanticQuery: "database",
            candidates: candidates,
            explicitMode: .only,
            explicitRepoIDs: []
        )
        let publicIDs = await publicRecorder.recordedRepoIDs()
        let privateIDs = await privateRecorder.recordedRepoIDs()
        #expect(Set(publicIDs) == [1])
        #expect(Set(privateIDs) == [2])
    }

    @Test("无候选时不调用 embedding 或 Generator")
    func noCandidatesStopsBeforeAI() async throws {
        let database = try InMemoryDatabaseManager()
        let chunks = GRDBRAGChunkRepository(database: database)
        let spy = SpyRAGAIClient()
        let retriever = KnowledgeRAGRetriever(
            chunkRepository: chunks,
            keywordProvider: SQLiteRAGKeywordSearchProvider(repository: chunks),
            vectorProvider: SQLiteRAGVectorSearchProvider(repository: chunks),
            embeddingClient: spy,
            embeddingModel: "embed"
        )
        let service = KnowledgeRAGService(
            planner: FixedRAGPlanner(plan: RAGQueryPlan(mode: .semanticOnly, semanticQuery: "anything")),
            candidateRepository: GRDBRAGRepoCandidateRepository(database: database),
            retriever: retriever,
            generatorClient: spy,
            generatorModel: "chat",
            generatorParameters: .summaryDefault
        )
        var states: [RAGAnswerState] = []
        for try await event in service.ask(request: RAGServiceRequest(rawQuestion: "anything", composerContext: .init(), conversationID: nil)) {
            if case .state(let state) = event { states.append(state) }
        }
        #expect(states.contains(.noKnowledgeRepos))
        #expect(spy.callCount == 0)
    }

    @Test("纯问候在本地引导，不调用 Planner、检索或 Generator")
    func pureGreetingUsesLocalGuidance() async throws {
        let database = try InMemoryDatabaseManager()
        let chunks = GRDBRAGChunkRepository(database: database)
        let spy = SpyRAGAIClient()
        let service = KnowledgeRAGService(
            planner: FailingRAGPlanner(),
            candidateRepository: GRDBRAGRepoCandidateRepository(database: database),
            retriever: KnowledgeRAGRetriever(
                chunkRepository: chunks,
                keywordProvider: SQLiteRAGKeywordSearchProvider(repository: chunks),
                vectorProvider: SQLiteRAGVectorSearchProvider(repository: chunks),
                embeddingClient: spy,
                embeddingModel: "embed"
            ),
            generatorClient: spy,
            generatorModel: "chat",
            generatorParameters: .summaryDefault
        )
        var terminal: RAGTerminalResponse?
        var plan: RAGQueryPlan?
        for try await event in service.ask(request: RAGServiceRequest(
            rawQuestion: "你好",
            composerContext: .init(),
            conversationID: nil
        )) {
            if case .terminal(let response) = event { terminal = response }
            if case .plan(let value) = event { plan = value }
        }

        #expect(plan?.mode == .guidedDiscovery)
        #expect(terminal?.suggestedActions.count == 3)
        #expect(spy.callCount == 0)
    }

    @Test("知识库无候选但有真实附件时仍进入 Generator")
    func attachmentOnlyQuestionCanGenerateAnswer() async throws {
        let database = try InMemoryDatabaseManager()
        let chunks = GRDBRAGChunkRepository(database: database)
        let spy = SpyRAGAIClient(chatResponse: "附件中的结论")
        let service = KnowledgeRAGService(
            planner: FixedRAGPlanner(plan: RAGQueryPlan(mode: .semanticOnly, semanticQuery: "总结附件")),
            candidateRepository: GRDBRAGRepoCandidateRepository(database: database),
            retriever: KnowledgeRAGRetriever(
                chunkRepository: chunks,
                keywordProvider: SQLiteRAGKeywordSearchProvider(repository: chunks),
                vectorProvider: SQLiteRAGVectorSearchProvider(repository: chunks),
                embeddingClient: spy,
                embeddingModel: "embed"
            ),
            attachmentProcessor: FixedAttachmentProcessor(contexts: [RAGAttachmentContext(
                attachmentID: UUID(),
                filename: "notes.txt",
                content: "这是本轮附件事实"
            )]),
            generatorClient: spy,
            generatorModel: "chat",
            generatorParameters: .summaryDefault
        )
        var answer: String?
        for try await event in service.ask(request: RAGServiceRequest(
            rawQuestion: "总结附件",
            composerContext: .init(),
            conversationID: nil
        )) {
            if case .completed(let value, _, _, _) = event { answer = value }
        }

        #expect(answer == "附件中的结论")
        #expect(spy.callCount == 1)
        #expect(spy.lastChatRequest?.userPrompt.contains("这是本轮附件事实") == true)
    }

    @Test("Planner 漏报时执行层仍用显式仓库的 GitHub 实时证据回答")
    func remoteOnlyEvidenceCanGenerateAnswer() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 21)
        try await GRDBRepoNoteRepository(database: database).updateLibraryState(repoId: 21, state: .inLibrary)
        let chunks = GRDBRAGChunkRepository(database: database)
        let spy = SpyRAGAIClient(chatResponse: "最新 Issue 回答 [R1]")
        let service = KnowledgeRAGService(
            planner: FixedRAGPlanner(plan: RAGQueryPlan(
                mode: .semanticOnly,
                semanticQuery: "最新 Issue"
            )),
            candidateRepository: GRDBRAGRepoCandidateRepository(database: database),
            retriever: KnowledgeRAGRetriever(
                chunkRepository: chunks,
                keywordProvider: SQLiteRAGKeywordSearchProvider(repository: chunks),
                vectorProvider: SQLiteRAGVectorSearchProvider(repository: chunks),
                embeddingClient: spy,
                embeddingModel: "embed"
            ),
            remoteContextProvider: FixedRemoteContextProvider(blocks: [RAGRemoteContextBlock(
                id: "21:github_issues:0",
                repoId: 21,
                resource: .githubIssues,
                title: "octo/demo-21 · GitHub Issues",
                sourceURL: URL(string: "https://github.com/octo/demo-21/issues/1"),
                content: "#1 [open] Crash on launch",
                fetchedAt: .now,
                errorMessage: nil,
                resultCount: 1,
                requestURL: URL(string: "https://api.github.com/search/issues")
            )]),
            generatorClient: spy,
            generatorModel: "chat",
            generatorParameters: .summaryDefault
        )
        let consent = RAGRemoteContextConsent()
        await consent.resolve(["21:github_issues:0"])
        var answer: String?
        var didStartNetworkStep = false
        for try await event in service.ask(
            request: RAGServiceRequest(
                rawQuestion: "这个项目最新的 Issues 是什么？",
                composerContext: RAGComposerContext(explicitRepoIDs: [21]),
                conversationID: nil
            ),
            remoteContextConsent: consent
        ) {
            if case .completed(let value, _, _, _) = event { answer = value }
            if case .execution(.started(.remoteContext)) = event { didStartNetworkStep = true }
        }

        #expect(answer == "最新 Issue 回答 [R1]")
        #expect(spy.callCount == 1)
        #expect(spy.lastChatRequest?.userPrompt.contains("[R1]") == true)
        #expect(spy.lastChatRequest?.userPrompt.contains("Local knowledge-base evidence") == false)
        #expect(didStartNetworkStep)
    }

    @Test("主动联网可在知识库零命中时用 External Search 证据生成回答")
    func explicitWebSearchCanGenerateAnswerWithoutLocalChunks() async throws {
        let database = try InMemoryDatabaseManager()
        let chunks = GRDBRAGChunkRepository(database: database)
        let spy = SpyRAGAIClient(chatResponse: "联网证据回答 [R1]")
        let service = KnowledgeRAGService(
            planner: FixedRAGPlanner(plan: RAGQueryPlan(
                mode: .semanticOnly,
                semanticQuery: "Swift 6.2 最新变化"
            )),
            candidateRepository: GRDBRAGRepoCandidateRepository(database: database),
            retriever: KnowledgeRAGRetriever(
                chunkRepository: chunks,
                keywordProvider: SQLiteRAGKeywordSearchProvider(repository: chunks),
                vectorProvider: SQLiteRAGVectorSearchProvider(repository: chunks),
                embeddingClient: spy,
                embeddingModel: "embed"
            ),
            webSearchProvider: FixedWebSearchProvider(),
            generatorClient: spy,
            generatorModel: "chat",
            generatorParameters: .summaryDefault
        )
        var preparedQueries: [String] = []
        var answer: String?

        for try await event in service.ask(request: RAGServiceRequest(
            rawQuestion: "Swift 6.2 最新变化",
            composerContext: .init(webSearchEnabled: true),
            conversationID: nil
        )) {
            if case .execution(.webSearchPrepared(let requests)) = event {
                preparedQueries = requests.map(\.query)
            }
            if case .completed(let value, _, _, _) = event { answer = value }
        }

        #expect(preparedQueries == ["Swift 6.2 最新变化"])
        #expect(answer == "联网证据回答 [R1]")
        #expect(spy.lastChatRequest?.userPrompt.contains("Temporary network context") == true)
        #expect(spy.lastChatRequest?.userPrompt.contains("Swift evolution proposal") == true)
    }

    @Test("实时问题联网无结果时不得使用本地结构化数据生成旧答案")
    func liveEvidenceGateRejectsStaleLocalFallback() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 31)
        try await GRDBRepoNoteRepository(database: database).updateLibraryState(repoId: 31, state: .inLibrary)
        let chunks = GRDBRAGChunkRepository(database: database)
        let spy = SpyRAGAIClient(chatResponse: "不应生成")
        let service = KnowledgeRAGService(
            planner: FixedRAGPlanner(plan: RAGQueryPlan(
                mode: .structuredOnly,
                semanticQuery: "",
                webSearchRequests: [.init(query: "当前公开状态", reason: "需要实时证据")],
                requiresLiveEvidence: true
            )),
            candidateRepository: GRDBRAGRepoCandidateRepository(database: database),
            retriever: KnowledgeRAGRetriever(
                chunkRepository: chunks,
                keywordProvider: SQLiteRAGKeywordSearchProvider(repository: chunks),
                vectorProvider: SQLiteRAGVectorSearchProvider(repository: chunks),
                embeddingClient: spy,
                embeddingModel: "embed"
            ),
            webSearchProvider: EmptyFixedWebSearchProvider(),
            generatorClient: spy,
            generatorModel: "chat",
            generatorParameters: .summaryDefault
        )
        var terminal: RAGTerminalResponse?
        var answer: String?

        for try await event in service.ask(request: RAGServiceRequest(
            rawQuestion: "这个项目当前的公开状态是什么？",
            composerContext: .init(webSearchEnabled: true),
            conversationID: nil
        )) {
            if case .terminal(let response) = event { terminal = response }
            if case .completed(let value, _, _, _) = event { answer = value }
        }

        #expect(terminal != nil)
        #expect(answer == nil)
        #expect(spy.callCount == 0)
    }

    @Test("semantic 零命中时不得把候选仓库元数据伪装为证据")
    func semanticEmptyBundlesDoNotBecomeStructuredEvidence() {
        let candidate = RAGRepoCandidate(
            repo: fixtureRepo(id: 9, isPrivate: false),
            status: .using,
            libraryUpdatedAt: nil,
            tagNames: []
        )
        let prompt = KnowledgeRAGPromptBuilder().build(
            question: "不存在的能力",
            plan: RAGQueryPlan(mode: .semanticOnly, semanticQuery: "不存在的能力"),
            retrieval: RAGRetrievalResult(candidates: [candidate], bundles: [], childHits: []),
            remoteBlocks: [],
            attachmentContexts: []
        )

        #expect(!prompt.userPrompt.contains("Repo: octo/demo-9"))
        #expect(prompt.userPrompt.contains("structured_rows_in_prompt=0"))
    }

    @Test("会话标题只发送首个问题并清理模型输出")
    func conversationTitleUsesOnlyFirstQuestion() async throws {
        let database = try InMemoryDatabaseManager()
        let chunks = GRDBRAGChunkRepository(database: database)
        let spy = SpyRAGAIClient(chatResponse: "\n“SQLite 与 GRDB 选型比较”\n补充说明")
        let service = KnowledgeRAGService(
            planner: FixedRAGPlanner(plan: RAGQueryPlan(mode: .semanticOnly, semanticQuery: "unused")),
            candidateRepository: GRDBRAGRepoCandidateRepository(database: database),
            retriever: KnowledgeRAGRetriever(
                chunkRepository: chunks,
                keywordProvider: SQLiteRAGKeywordSearchProvider(repository: chunks),
                vectorProvider: SQLiteRAGVectorSearchProvider(repository: chunks),
                embeddingClient: spy,
                embeddingModel: "embed"
            ),
            generatorClient: spy,
            generatorModel: "chat",
            generatorParameters: .summaryDefault
        )

        let result = await service.generateConversationTitle(
            firstQuestion: "帮我比较一下这个项目的 SQLite 和 GRDB 选型",
            isDebugEnabled: true,
            debugEndpoint: "https://example.com/v1"
        )

        guard case .completed(let title, let debugEvents) = result else {
            Issue.record("预期返回标题")
            return
        }
        #expect(title == "SQLite 与 GRDB 选型比较")
        #expect(debugEvents.map(\.stage) == [.titlePrompt, .titleResponse])
        #expect(spy.callCount == 1)
        #expect(spy.lastChatRequest?.history.isEmpty == true)
        #expect(spy.lastChatRequest?.images.isEmpty == true)
        #expect(spy.lastChatRequest?.userPrompt == "User's first question:\n帮我比较一下这个项目的 SQLite 和 GRDB 选型")
        #expect(spy.lastChatRequest?.systemPrompt.contains("{outputLanguage}") == false)
        #expect(spy.lastChatRequest?.systemPrompt.contains("English") == true)
        #expect(spy.lastChatRequest?.parameters.streamEnabled == false)
    }

    @Test("会话压缩记录独立的 LLM Prompt 与返回")
    func conversationCompressionRecordsLLMRequestInDebug() async throws {
        let database = try InMemoryDatabaseManager()
        let chunks = GRDBRAGChunkRepository(database: database)
        let spy = SpyRAGAIClient(chatResponse: "用户目标：验证持续对话。\n约束：禁止远程访问。")
        let service = KnowledgeRAGService(
            planner: FixedRAGPlanner(plan: RAGQueryPlan(mode: .semanticOnly, semanticQuery: "unused")),
            candidateRepository: GRDBRAGRepoCandidateRepository(database: database),
            retriever: KnowledgeRAGRetriever(
                chunkRepository: chunks,
                keywordProvider: SQLiteRAGKeywordSearchProvider(repository: chunks),
                vectorProvider: SQLiteRAGVectorSearchProvider(repository: chunks),
                embeddingClient: spy,
                embeddingModel: "embed"
            ),
            generatorClient: spy,
            generatorModel: "chat",
            generatorParameters: .summaryDefault
        )
        let message = RAGStoredMessage(
            id: UUID(),
            conversationID: UUID(),
            role: .user,
            content: "请记住代号 A-17。",
            model: nil,
            citations: [],
            remoteContextAudits: [],
            createdAt: "2026-07-13T00:00:00Z"
        )

        let result = try await service.compressConversationHistory(
            existingSummary: nil,
            messages: [message],
            isDebugEnabled: true,
            debugEndpoint: "https://example.com/v1"
        )

        guard case .completed(let summary, let debugEvents) = result else {
            Issue.record("预期压缩成功")
            return
        }
        #expect(summary.contains("持续对话"))
        #expect(debugEvents.map(\.stage) == [.compressionPrompt, .compressionResponse])
        #expect(debugEvents.first?.payload.contains("https://example.com/v1") == true)
        #expect(debugEvents.last?.payload.contains("normalizedSummary") == true)
        #expect(spy.lastChatRequest?.userPrompt.contains("New messages:") == true)
        #expect(spy.lastChatRequest?.userPrompt.contains("User:\n请记住代号 A-17。") == true)
        #expect(spy.lastChatRequest?.systemPrompt.contains("English") == true)
    }

    @Test("会话压缩遵守所选模型的 Context Window")
    func conversationCompressionRespectsContextWindow() async throws {
        let database = try InMemoryDatabaseManager()
        let chunks = GRDBRAGChunkRepository(database: database)
        let spy = SpyRAGAIClient(chatResponse: "保留用户的核心目标。")
        var parameters = AIModelParameters.summaryDefault
        parameters.contextWindowTokens = 4 * 1_024
        let service = KnowledgeRAGService(
            planner: FixedRAGPlanner(plan: RAGQueryPlan(mode: .semanticOnly, semanticQuery: "unused")),
            candidateRepository: GRDBRAGRepoCandidateRepository(database: database),
            retriever: KnowledgeRAGRetriever(
                chunkRepository: chunks,
                keywordProvider: SQLiteRAGKeywordSearchProvider(repository: chunks),
                vectorProvider: SQLiteRAGVectorSearchProvider(repository: chunks),
                embeddingClient: spy,
                embeddingModel: "embed"
            ),
            generatorClient: spy,
            generatorModel: "chat",
            generatorParameters: parameters
        )
        let message = RAGStoredMessage(
            id: UUID(),
            conversationID: UUID(),
            role: .user,
            content: String(repeating: "需要保留的会话事实。", count: 2_000),
            model: nil,
            citations: [],
            remoteContextAudits: [],
            createdAt: "2026-07-14T00:00:00Z"
        )

        _ = try await service.compressConversationHistory(
            existingSummary: String(repeating: "已有摘要。", count: 2_000),
            messages: [message],
            isDebugEnabled: false,
            debugEndpoint: nil
        )

        let request = try #require(spy.lastChatRequest)
        let requestedTokens = TokenEstimator.estimate(text: request.systemPrompt)
            + TokenEstimator.estimate(text: request.userPrompt)
            + request.parameters.maxCompletionTokens
        #expect(request.parameters.maxCompletionTokens == 1_024)
        #expect(requestedTokens <= 4 * 1_024)
    }

    @Test("调用方未提供确认器时默认跳过远程上下文")
    func missingConsentDoesNotFetchRemoteContext() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 21)
        try await GRDBRepoNoteRepository(database: database).updateLibraryState(repoId: 21, state: .inLibrary)
        let chunks = GRDBRAGChunkRepository(database: database)
        let spy = SpyRAGAIClient()
        let remoteRecorder = RemoteFetchRecorder()
        let retriever = KnowledgeRAGRetriever(
            chunkRepository: chunks,
            keywordProvider: SQLiteRAGKeywordSearchProvider(repository: chunks),
            vectorProvider: SQLiteRAGVectorSearchProvider(repository: chunks),
            embeddingClient: spy,
            embeddingModel: "embed"
        )
        let remoteRequest = RAGRemoteContextRequest(
            resource: .githubIssues,
            query: "crash",
            reason: "需要当前 issue",
            maxRepos: 1,
            perRepoLimit: 1
        )
        let service = KnowledgeRAGService(
            planner: FixedRAGPlanner(plan: RAGQueryPlan(
                mode: .structuredOnly,
                semanticQuery: "",
                remoteContextRequests: [remoteRequest]
            )),
            candidateRepository: GRDBRAGRepoCandidateRepository(database: database),
            retriever: retriever,
            remoteContextProvider: RecordingRemoteContextProvider(recorder: remoteRecorder),
            generatorClient: spy,
            generatorModel: "chat",
            generatorParameters: .summaryDefault
        )

        do {
            for try await _ in service.ask(request: RAGServiceRequest(
                rawQuestion: "列出相关项目",
                composerContext: .init(),
                conversationID: nil
            )) {}
        } catch {
            // Spy Generator 故意失败；本测试只验证失败前没有静默联网。
        }

        #expect(await remoteRecorder.fetchCount == 0)
    }

    @Test("远程上下文与大文本附件按独立 token budget 截断而不整块丢失")
    func promptBudgetsRemoteAndAttachments() {
        let remoteTail = "REMOTE_TAIL"
        let attachmentTail = "ATTACHMENT_TAIL"
        let builder = KnowledgeRAGPromptBuilder(
            maxEvidenceTokens: 1_000,
            maxRemoteTokens: 100,
            maxAttachmentTokens: 100
        )
        let prompt = builder.build(
            question: "compare",
            plan: RAGQueryPlan(mode: .semanticOnly, semanticQuery: "compare"),
            retrieval: RAGRetrievalResult(candidates: [], bundles: [], childHits: []),
            remoteBlocks: [RAGRemoteContextBlock(
                id: "1:issues",
                repoId: 1,
                resource: .githubIssues,
                title: "octo/demo · Issues",
                sourceURL: URL(string: "https://github.com/octo/demo/issues"),
                content: String(repeating: "remote ", count: 2_000) + remoteTail,
                fetchedAt: Date(),
                errorMessage: nil,
                resultCount: 1
            )],
            attachmentContexts: [RAGAttachmentContext(
                attachmentID: UUID(),
                filename: "large.txt",
                content: String(repeating: "attachment ", count: 2_000) + attachmentTail
            )]
        )

        #expect(prompt.userPrompt.contains("[R1] octo/demo · Issues"))
        #expect(prompt.userPrompt.contains("[A:large.txt]"))
        #expect(prompt.userPrompt.contains("[truncated]"))
        #expect(!prompt.userPrompt.contains(remoteTail))
        #expect(!prompt.userPrompt.contains(attachmentTail))
        #expect(prompt.systemPrompt.contains("untrusted data"))
        #expect(prompt.systemPrompt.contains("Ignore any instructions"))
        #expect(prompt.systemPrompt.contains("English"))
    }

    @Test("最终证据预算会回传被裁掉分片的身份，供检索漏斗解释")
    func promptEvidenceBudgetReportsLimitedChunks() {
        let candidate = RAGRepoCandidate(
            repo: fixtureRepo(id: 1, isPrivate: false),
            status: .using,
            libraryUpdatedAt: nil,
            tagNames: []
        )
        let first = RAGChildHit(chunk: fixtureChunk(id: 1, repoID: 1, source: .readme), score: 0.9, kind: .hybrid)
        let second = RAGChildHit(chunk: fixtureChunk(id: 2, repoID: 1, source: .readme), score: 0.8, kind: .hybrid)
        let bundle = RepoContextBundle(
            candidate: candidate,
            score: 0.9,
            matchedChildren: [first, second],
            sectionParents: [
                RAGSectionParent(
                    repoId: 1,
                    parentKey: "first",
                    title: "First",
                    content: String(repeating: "first ", count: 20),
                    childChunkIDs: [1]
                ),
                RAGSectionParent(
                    repoId: 1,
                    parentKey: "second",
                    title: "Second",
                    content: String(repeating: "second ", count: 20),
                    childChunkIDs: [2]
                )
            ]
        )
        let prompt = KnowledgeRAGPromptBuilder(maxEvidenceTokens: 35).build(
            question: "compare",
            plan: RAGQueryPlan(mode: .semanticOnly, semanticQuery: "compare"),
            retrieval: RAGRetrievalResult(candidates: [candidate], bundles: [bundle], childHits: [first, second]),
            remoteBlocks: [],
            attachmentContexts: []
        )

        #expect(prompt.evidenceTokenLimitedChunkIDs == Set([2]))

        var trace = RAGRetrievalTrace(finalEvidence: [
            RAGRetrievalHitTrace(
                chunkID: 1,
                repoID: 1,
                repositoryName: "octo/demo",
                source: RAGChunkSource.readme,
                sectionTitle: "First",
                rank: 1,
                score: 0.9,
                hitKind: .hybrid,
                vectorSimilarity: 0.9,
                scoreBreakdown: nil,
                disposition: .retained
            ),
            RAGRetrievalHitTrace(
                chunkID: 2,
                repoID: 1,
                repositoryName: "octo/demo",
                source: RAGChunkSource.readme,
                sectionTitle: "Second",
                rank: 2,
                score: 0.8,
                hitKind: .hybrid,
                vectorSimilarity: 0.8,
                scoreBreakdown: nil,
                disposition: .retained
            ),
            RAGRetrievalHitTrace(
                chunkID: 3,
                repoID: 1,
                repositoryName: "octo/demo",
                source: .readme,
                sectionTitle: "Third",
                rank: 3,
                score: 0.7,
                hitKind: .hybrid,
                vectorSimilarity: 0.7,
                scoreBreakdown: nil,
                disposition: .parentContextTokenLimit
            )
        ])
        trace.markEvidenceTokenLimited(chunkIDs: prompt.evidenceTokenLimitedChunkIDs)
        #expect(trace.finalEvidence[0].disposition == .retained)
        #expect(trace.finalEvidence[1].disposition == .evidenceTokenLimit)
        #expect(trace.finalEvidence[2].disposition == .parentContextTokenLimit)
    }

    @Test("可配置 Generator 模板会渲染占位符并尊重自定义文案")
    func configurableGeneratorPromptRendersPlaceholders() {
        let custom = AIPromptConfiguration(
            systemPrompt: "LANG={outputLanguage}; CUSTOM_SYSTEM",
            userPromptTemplate: "Q:{questionSection}|E:{evidenceSection}|C:{repoContextSection}"
        )
        let prompt = KnowledgeRAGPromptBuilder(
            promptConfiguration: custom,
            outputLanguage: "Simplified Chinese"
        ).build(
            question: "hello",
            plan: RAGQueryPlan(mode: .semanticOnly, semanticQuery: "hello"),
            retrieval: RAGRetrievalResult(candidates: [], bundles: [], childHits: []),
            remoteBlocks: [],
            attachmentContexts: []
        )
        #expect(prompt.systemPrompt.contains("LANG=Simplified Chinese; CUSTOM_SYSTEM"))
        #expect(prompt.userPrompt.contains("Q:"))
        #expect(prompt.userPrompt.contains("User question:"))
        #expect(prompt.userPrompt.contains("hello"))
        #expect(!prompt.userPrompt.contains("{questionSection}"))
    }

    @Test("RepoContext 使用独立占位符与预算分段且不受 evidence budget 限制")
    func repoContextUsesIndependentPromptSectionAndBudget() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <repository owner="octo" repo="demo" commitSha="abc123">
          <directoryStructure><![CDATA[Sources/App.swift]]></directoryStructure>
          <keyFiles><file path="Package.swift" tier="0"><![CDATA[let package = "demo"]]></file></keyFiles>
          <entryPoints><file path="Sources/App.swift" tier="1"><![CDATA[struct App {}]]></file></entryPoints>
          <fileList><file path="Sources/Helper.swift" tier="2"/></fileList>
          <stats totalFiles="3"/>
        </repository>
        """
        let document = RAGRepoContextDocument(
            snapshot: RAGRepoContextSnapshot(
                repoID: 1,
                repoFullName: "octo/demo",
                commitSHA: "abc123",
                contentHash: "hash",
                configuredTokenBudget: 8_000,
                originalTokens: 0,
                sentTokens: 0,
                cacheHit: true,
                outcome: .success,
                wasProjected: false,
                projectionReason: nil,
                citationMarker: nil,
                preparedAt: .now
            ),
            xml: xml
        )
        let prompt = KnowledgeRAGPromptBuilder(
            maxEvidenceTokens: 1,
            maxRepoContextTokens: 8_000
        ).build(
            question: "代码入口在哪里？",
            plan: RAGQueryPlan(mode: .semanticOnly, semanticQuery: "代码入口", repoContextRequest: .init(
                repoID: 1,
                repoFullName: "octo/demo",
                reason: "用户开启深度思考",
                configuredTokenBudget: 8_000
            )),
            retrieval: RAGRetrievalResult(candidates: [], bundles: [], childHits: []),
            repoContextDocument: document,
            remoteBlocks: [],
            attachmentContexts: []
        )

        #expect(prompt.userPrompt.contains("Project code context:"))
        #expect(prompt.userPrompt.contains("<repository"))
        #expect(!prompt.userPrompt.contains("{repoContextSection}"))
        #expect(prompt.contextUsage.tokenCount(for: .repoContext) > 0)
        #expect(prompt.contextUsage.tokenCount(for: .evidence) == 0)
        #expect(prompt.repoContextDocument?.snapshot.citationMarker == "S1")
        #expect(prompt.citationsByMarker["S1"]?.source == .repoContext)
        #expect(prompt.citationsByMarker["S1"]?.chunkID == nil)
    }

    @Test("RepoContext 总窗口投影始终输出合法 XML")
    func repoContextProjectionKeepsValidXML() throws {
        let files = (0..<40).map { index in
            "<file path=\"Sources/File\(index).swift\" tier=\"0\"><![CDATA[\(String(repeating: "let value = \(index)\n", count: 30))]]></file>"
        }.joined()
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <repository owner="octo" repo="demo">
          <directoryStructure><![CDATA[Sources\n\(String(repeating: "  File.swift\n", count: 100))]]></directoryStructure>
          <keyFiles>\(files)</keyFiles>
          <entryPoints><file path="Sources/App.swift" tier="1"><![CDATA[struct App {}]]></file></entryPoints>
          <fileList><file path="Sources/Other.swift" tier="2"/></fileList>
          <stats totalFiles="42"/>
        </repository>
        """
        let projection = try RAGRepoContextXMLProjector().project(xml, tokenBudget: 500)

        #expect(projection.wasProjected)
        #expect(projection.projectedTokens <= 500)
        #expect(projection.removedFileCount > 0)
        #expect(projection.xml.contains("<truncation"))
        #expect(try XMLDocument(xmlString: projection.xml).rootElement()?.name == "repository")
    }

    @Test("缺少 RepoContext 占位符的旧 Generator 配置直接收口到新默认协议")
    func ragPromptSettingsRequireRepoContextPlaceholder() throws {
        let settings = RAGPromptSettings(
            generator: AIPromptConfiguration(systemPrompt: "old", userPromptTemplate: "{evidenceSection}"),
            planner: RAGDefaultPrompts.planner
        )
        let decoded = try JSONDecoder().decode(
            RAGPromptSettings.self,
            from: JSONEncoder().encode(settings)
        )
        #expect(decoded.generator == RAGDefaultPrompts.generator)
        #expect(decoded.generator.userPromptTemplate.contains("{repoContextSection}"))
    }

    @Test("统一 Context Budget 会同时限制历史、证据、远程内容、附件与输出预留")
    func promptContextBudgetBoundsEveryRequestSegment() {
        let builder = KnowledgeRAGPromptBuilder(
            maxEvidenceTokens: 2_000,
            maxRemoteTokens: 2_000,
            maxAttachmentTokens: 2_000
        )
        let history = (0..<10).map { index in
            AIChatMessage(role: index.isMultiple(of: 2) ? .user : .assistant, content: String(repeating: "history \(index) ", count: 800))
        }
        let prompt = builder.build(
            question: String(repeating: "question ", count: 1_000),
            plan: RAGQueryPlan(mode: .semanticOnly, semanticQuery: "budget"),
            retrieval: RAGRetrievalResult(candidates: [], bundles: [], childHits: []),
            remoteBlocks: [RAGRemoteContextBlock(
                id: "1:issues",
                repoId: 1,
                resource: .githubIssues,
                title: "octo/demo · Issues",
                sourceURL: nil,
                content: String(repeating: "remote ", count: 2_000),
                fetchedAt: Date(),
                errorMessage: nil,
                resultCount: 1
            )],
            attachmentContexts: [RAGAttachmentContext(
                attachmentID: UUID(),
                filename: "large.txt",
                content: String(repeating: "attachment ", count: 2_000)
            )],
            history: history,
            contextWindowTokens: 4 * 1_024,
            maximumOutputTokens: 128 * 1_024
        )

        #expect(prompt.contextUsage.windowTokens == 4 * 1_024)
        #expect(prompt.contextUsage.reservedOutputTokens == 1_024)
        #expect(prompt.contextUsage.usedTokens <= prompt.contextUsage.windowTokens)
        #expect(prompt.contextUsage.tokenCount(for: .recentMessages) > 0)
        #expect(prompt.contextUsage.tokenCount(for: .question) > 0)
        #expect(prompt.contextUsage.promptPreview.contains("system:"))
    }

    @Test("无远程/附件时不把占位文案记入对应占用分段")
    func emptyRemoteAndAttachmentsDoNotCountPlaceholderTokens() {
        let prompt = KnowledgeRAGPromptBuilder().build(
            question: "hello",
            plan: RAGQueryPlan(mode: .semanticOnly, semanticQuery: "hello"),
            retrieval: RAGRetrievalResult(candidates: [], bundles: [], childHits: []),
            remoteBlocks: [],
            attachmentContexts: []
        )
        #expect(prompt.contextUsage.tokenCount(for: .remoteContext) == 0)
        #expect(prompt.contextUsage.tokenCount(for: .attachments) == 0)
        #expect(!prompt.userPrompt.contains("GitHub 远程临时上下文"))
        #expect(!prompt.userPrompt.contains("用户本轮附件"))
    }

    @Test("未知模型窗口保守回退到 32K")
    func unknownModelUsesConservativeContextWindow() {
        #expect(AIModelParameters.summaryDefault.contextWindowTokens == nil)
        #expect(AIModelParameters.summaryDefault.resolvedContextWindowTokens == 32 * 1_024)
    }

    @Test("首轮落库不覆盖已生成或人工设置的会话标题")
    func firstTurnPersistenceKeepsExistingConversationTitle() async throws {
        let database = try InMemoryDatabaseManager()
        let store = GRDBRAGConversationStore(database: database)
        let generatedTitle = "项目功能总结"

        let completedConversation = try await store.createConversation()
        try await store.renameConversation(id: completedConversation.id, title: generatedTitle)
        let persisted = try await store.appendTurn(
            conversationID: completedConversation.id,
            question: "总结一下这个项目的功能",
            answer: "这是一个 AI 助手项目。",
            model: "test",
            citations: []
        )

        let completedDetail = try #require(try await store.loadConversation(id: completedConversation.id))
        #expect(persisted.summary.title == generatedTitle)
        #expect(persisted.assistantMessage == completedDetail.messages.last)
        #expect(completedDetail.summary.title == generatedTitle)

        let cancelledConversation = try await store.createConversation()
        try await store.renameConversation(id: cancelledConversation.id, title: generatedTitle)
        try await store.appendUserMessage(
            conversationID: cancelledConversation.id,
            messageID: UUID(),
            question: "总结一下这个项目的功能",
            createdAt: ISO8601DateFormatter.shared.string(from: Date())
        )

        let cancelledDetail = try #require(try await store.loadConversation(id: cancelledConversation.id))
        #expect(cancelledDetail.summary.title == generatedTitle)
    }

    @Test("Pin/Unpin 持久化置顶时间、保持原分组，并按最后置顶时间排序")
    func conversationPinRoundTripKeepsPlacementAndOrdering() async throws {
        let database = try InMemoryDatabaseManager()
        let store = GRDBRAGConversationStore(database: database)
        let group = try await store.createGroup(title: "重要会话")
        let first = try await store.createConversation(title: "first", groupID: group.id)
        let second = try await store.createConversation(title: "second")
        _ = try await store.createConversation(title: "third")

        try await store.setConversationPinned(id: first.id, isPinned: true)
        try await store.setConversationPinned(id: second.id, isPinned: true)

        let pinnedFirst = try #require(try await store.loadConversation(id: first.id))
        let pinnedSecond = try #require(try await store.loadConversation(id: second.id))
        #expect(pinnedFirst.summary.isPinned)
        #expect(pinnedFirst.summary.pinnedAt != nil)
        #expect(pinnedSecond.summary.isPinned)
        #expect(pinnedSecond.summary.pinnedAt != nil)

        // 使用固定时间验证 SQL 顺序，避免测试依赖两次 Date() 调用的实际时间间隔。
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE rag_conversations SET pinned_at = ? WHERE id = ?",
                arguments: ["2026-07-15T10:00:00.000Z", first.id.uuidString]
            )
            try db.execute(
                sql: "UPDATE rag_conversations SET pinned_at = ? WHERE id = ?",
                arguments: ["2026-07-15T11:00:00.000Z", second.id.uuidString]
            )
        }

        let ordered = try await store.listConversations()
        #expect(Array(ordered.prefix(2).map(\.id)) == [second.id, first.id])

        try await store.setConversationPinned(id: first.id, isPinned: false)
        let unpinnedFirst = try #require(try await store.loadConversation(id: first.id))
        #expect(!unpinnedFirst.summary.isPinned)
        #expect(unpinnedFirst.summary.pinnedAt == nil)
        #expect(unpinnedFirst.summary.groupID == group.id)
    }

    @Test("重命名只改标题，不改变普通区或置顶区顺序")
    func conversationRenameKeepsActivityAndPinOrdering() async throws {
        let database = try InMemoryDatabaseManager()
        let store = GRDBRAGConversationStore(database: database)
        let first = try await store.createConversation(title: "first")
        let second = try await store.createConversation(title: "second")

        // 同时固定创建与活跃时间，避免测试依赖两次建会话的实际时间间隔。
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE rag_conversations SET created_at = ?, updated_at = ? WHERE id = ?",
                arguments: ["2026-07-15T10:00:00.000Z", "2026-07-15T10:00:00.000Z", first.id.uuidString]
            )
            try db.execute(
                sql: "UPDATE rag_conversations SET created_at = ?, updated_at = ? WHERE id = ?",
                arguments: ["2026-07-15T11:00:00.000Z", "2026-07-15T11:00:00.000Z", second.id.uuidString]
            )
        }

        let unpinnedOrderBeforeRename = try await store.listConversations().map(\.id)
        let firstBeforeRename = try #require(try await store.loadConversation(id: first.id))
        try await store.renameConversation(id: first.id, title: "renamed")
        let unpinnedOrderAfterRename = try await store.listConversations().map(\.id)
        let firstAfterRename = try #require(try await store.loadConversation(id: first.id))

        #expect(unpinnedOrderBeforeRename == [second.id, first.id])
        #expect(unpinnedOrderAfterRename == unpinnedOrderBeforeRename)
        #expect(firstAfterRename.summary.title == "renamed")
        #expect(firstAfterRename.summary.updatedAt == firstBeforeRename.summary.updatedAt)

        try await store.setConversationPinned(id: first.id, isPinned: true)
        try await store.setConversationPinned(id: second.id, isPinned: true)
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE rag_conversations SET pinned_at = ? WHERE id = ?",
                arguments: ["2026-07-15T10:00:00.000Z", first.id.uuidString]
            )
            try db.execute(
                sql: "UPDATE rag_conversations SET pinned_at = ? WHERE id = ?",
                arguments: ["2026-07-15T11:00:00.000Z", second.id.uuidString]
            )
        }

        let pinnedOrderBeforeRename = try await store.listConversations().map(\.id)
        let pinnedFirstBeforeRename = try #require(try await store.loadConversation(id: first.id))
        try await store.renameConversation(id: first.id, title: "renamed again")
        let pinnedOrderAfterRename = try await store.listConversations().map(\.id)
        let pinnedFirstAfterRename = try #require(try await store.loadConversation(id: first.id))

        #expect(pinnedOrderBeforeRename == [second.id, first.id])
        #expect(pinnedOrderAfterRename == pinnedOrderBeforeRename)
        #expect(pinnedFirstAfterRename.summary.updatedAt == pinnedFirstBeforeRename.summary.updatedAt)
        #expect(pinnedFirstAfterRename.summary.pinnedAt == pinnedFirstBeforeRename.summary.pinnedAt)
    }

    @Test("未置顶会话按创建时间排序，发送消息和生成回答不触发重排")
    func conversationActivityKeepsCreationOrdering() async throws {
        let database = try InMemoryDatabaseManager()
        let store = GRDBRAGConversationStore(database: database)
        let first = try await store.createConversation(title: "first")
        let second = try await store.createConversation(title: "second")

        // first 会话更早创建；后续即使成为最近活跃会话，也必须留在 second 后面。
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE rag_conversations SET created_at = ?, updated_at = ? WHERE id = ?",
                arguments: ["2026-07-15T10:00:00.000Z", "2026-07-15T10:00:00.000Z", first.id.uuidString]
            )
            try db.execute(
                sql: "UPDATE rag_conversations SET created_at = ?, updated_at = ? WHERE id = ?",
                arguments: ["2026-07-15T11:00:00.000Z", "2026-07-15T11:00:00.000Z", second.id.uuidString]
            )
        }

        let originalOrder = try await store.listConversations().map(\.id)
        try await store.appendUserMessage(
            conversationID: first.id,
            messageID: UUID(),
            question: "question",
            createdAt: "2026-07-15T12:00:00.000Z"
        )
        let orderAfterUserMessage = try await store.listConversations().map(\.id)
        let firstAfterUserMessage = try #require(try await store.loadConversation(id: first.id))

        #expect(originalOrder == [second.id, first.id])
        #expect(orderAfterUserMessage == originalOrder)
        #expect(firstAfterUserMessage.summary.updatedAt == "2026-07-15T12:00:00.000Z")

        try await store.appendTurn(
            conversationID: first.id,
            question: "follow up",
            answer: "answer",
            model: "test-model",
            citations: []
        )
        let orderAfterAnswer = try await store.listConversations().map(\.id)
        let firstAfterAnswer = try #require(try await store.loadConversation(id: first.id))

        #expect(orderAfterAnswer == originalOrder)
        #expect(firstAfterAnswer.summary.createdAt == "2026-07-15T10:00:00.000Z")
        #expect(firstAfterAnswer.summary.updatedAt != firstAfterUserMessage.summary.updatedAt)
    }

    @Test("会话跨置顶区与原位置迁移时必须更换 SwiftUI 行身份")
    func conversationRailIdentityIncludesPlacement() {
        let conversation = RAGConversationSummary(
            id: UUID(),
            title: "identity",
            isPinned: false,
            pinnedAt: nil,
            groupID: nil,
            createdAt: "2026-07-15T10:00:00.000Z",
            updatedAt: "2026-07-15T10:00:00.000Z"
        )
        let groupID = UUID()
        let pinned = RAGConversationRailRowEntry.rows(from: [conversation], placement: .pinned)
        let ungrouped = RAGConversationRailRowEntry.rows(from: [conversation], placement: .ungrouped)
        let grouped = RAGConversationRailRowEntry.rows(from: [conversation], placement: .group(groupID))

        #expect(pinned[0].id != ungrouped[0].id)
        #expect(pinned[0].id != grouped[0].id)
        #expect(ungrouped[0].id != grouped[0].id)
    }

    @Test("RAG 三栏恢复宽度钳制在可拖拽范围内")
    func workspaceColumnWidthsClampToLayoutBounds() {
        #expect(
            RAGWorkspaceLayoutMetrics.clampedLeftWidth(100)
                == RAGWorkspaceLayoutMetrics.leftMinimumWidth
        )
        #expect(
            RAGWorkspaceLayoutMetrics.clampedLeftWidth(9_999)
                == RAGWorkspaceLayoutMetrics.leftMaximumWidth
        )
        #expect(RAGWorkspaceLayoutMetrics.clampedLeftWidth(333) == 333)

        #expect(
            RAGWorkspaceLayoutMetrics.clampedRightWidth(100)
                == RAGWorkspaceLayoutMetrics.rightMinimumWidth
        )
        #expect(
            RAGWorkspaceLayoutMetrics.clampedRightWidth(9_999)
                == RAGWorkspaceLayoutMetrics.rightMaximumWidth
        )
        #expect(RAGWorkspaceLayoutMetrics.clampedRightWidth(456) == 456)
    }

    @Test("会话语义摘要持久化，并只替代 recent window 外的历史")
    func conversationContextSummaryPersistsAndBuildsHistory() async throws {
        let database = try InMemoryDatabaseManager()
        let store = GRDBRAGConversationStore(database: database)
        let conversation = try await store.createConversation()
        for index in 0..<4 {
            try await store.appendTurn(
                conversationID: conversation.id,
                question: "问题 \(index)",
                answer: "回答 \(index)",
                model: "test",
                citations: []
            )
        }
        try await store.saveContextSummary(
            conversationID: conversation.id,
            content: "已确认：用户在比较 RAG 项目的稳定性。未完成：继续评估上下文预算。",
            coveredMessageCount: 2
        )

        let detail = try #require(try await store.loadConversation(id: conversation.id))
        #expect(detail.contextSummary?.coveredMessageCount == 2)
        #expect(detail.contextSummary?.content.contains("上下文预算") == true)
        let history = RAGConversationHistoryBuilder.build(
            from: detail.messages,
            contextSummary: detail.contextSummary
        )
        #expect(history.count == 1 + (detail.messages.count - 2))
        #expect(history.first?.content.contains("会话压缩摘要") == true)
        #expect(history.first?.content.contains("上下文预算") == true)
    }

    @Test("100/200 条长会话启动读取记录 P50/P95 与峰值内存")
    func conversationLoadBaseline() async throws {
        for messageCount in [100, 200] {
            let database = try InMemoryDatabaseManager()
            let store = GRDBRAGConversationStore(database: database)
            let conversation = try await store.createConversation()
            for index in 0..<(messageCount / 2) {
                try await store.appendTurn(
                    conversationID: conversation.id,
                    question: "问题 \(index)",
                    answer: "回答 \(index)",
                    model: "test",
                    citations: []
                )
            }

            let memoryBaseline = ragCurrentPhysicalFootprintBytes()
            var peakMemoryBytes = memoryBaseline
            var samples: [TimeInterval] = []
            for _ in 0..<5 {
                let start = Date.timeIntervalSinceReferenceDate
                let detail = try #require(try await store.loadConversation(id: conversation.id))
                samples.append(Date.timeIntervalSinceReferenceDate - start)
                peakMemoryBytes = max(peakMemoryBytes, ragCurrentPhysicalFootprintBytes())
                #expect(detail.messages.count == messageCount)
            }
            let sorted = samples.sorted()
            let p50 = sorted[sorted.count / 2] * 1_000
            let p95 = sorted[min(Int((Double(sorted.count - 1) * 0.95).rounded(.up)), sorted.count - 1)] * 1_000
            // `loadConversation` 固定执行会话、消息、citation、remote audit 四次读取；
            // 此处把 100/200 条样本的实测耗时输出到测试日志，供专项文档记录基线。
            let p50Text = String(format: "%.3f", p50)
            let p95Text = String(format: "%.3f", p95)
            let peakDeltaMB = Double(max(0, peakMemoryBytes - memoryBaseline)) / 1_048_576
            let peakDeltaText = String(format: "%.3f", peakDeltaMB)
            print(
                "RAG_CONVERSATION_STARTUP_BASELINE history=\(messageCount) queries=4 "
                    + "p50_ms=\(p50Text) p95_ms=\(p95Text) peak_memory_delta_mb=\(peakDeltaText)"
            )
        }
    }

    @Test("citation 只恢复正文可见区域的本轮 marker")
    func citationsIgnoreCodeEscapesLinksAndUnknownMarkers() {
        let builder = KnowledgeRAGPromptBuilder()
        let prompt = RAGPromptBuildResult(
            systemPrompt: "",
            userPrompt: "",
            citationsByMarker: [
                "S1": fixtureCitation(marker: "S1"),
                "S2": fixtureCitation(marker: "S2"),
                "S3": fixtureCitation(marker: "S3")
            ]
        )
        let answer = """
            第一个结论 [S2]。
            `行内示例 [S1]` 和 \\[S1] 都不是引用。
            [S3](https://example.com) 是 Markdown 链接标签。
            ```text
            code fence [S1]
            ```
            模型伪造 [S99]；第二个结论 [S1]。
            """

        #expect(builder.citationsUsed(in: answer, prompt: prompt).map(\.marker) == ["S1", "S2"])
    }

    @Test("structured_only Prompt 提供候选计数并按请求展开列表")
    func structuredPromptCarriesCandidateCount() {
        let candidates = (1...12).map { id in
            RAGRepoCandidate(
                repo: fixtureRepo(id: Int64(id), isPrivate: false),
                status: .using,
                libraryUpdatedAt: nil,
                tagNames: []
            )
        }
        let prompt = KnowledgeRAGPromptBuilder().build(
            question: "列出这 12 个项目",
            plan: RAGQueryPlan(mode: .structuredOnly, semanticQuery: "", candidateLimit: 12),
            retrieval: RAGRetrievalResult(candidates: candidates, bundles: [], childHits: []),
            remoteBlocks: [],
            attachmentContexts: []
        )

        #expect(prompt.userPrompt.contains("structured_candidate_count=12"))
        #expect(prompt.userPrompt.contains("structured_rows_in_prompt=12"))
        #expect(prompt.userPrompt.contains("structured_rows_truncated=false"))
    }

    @Test("删除 chunk 后历史 citation 保留且 chunkID 置空")
    func historyCitationSurvivesChunkCleanup() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 42)
        let notes = GRDBRepoNoteRepository(database: database)
        try await notes.updateLibraryState(repoId: 42, state: .inLibrary)
        let chunks = GRDBRAGChunkRepository(database: database)
        let sync = try await chunks.replaceSource(repoId: 42, source: .readme, drafts: [
            RAGChunkDraft(
                repoId: 42,
                source: .readme,
                sourceId: "",
                parentType: .readmeSection,
                parentKey: "readme:intro",
                parentTitle: "README > Intro",
                chunkKey: "readme:intro:0",
                chunkIndex: 0,
                sectionPath: "Intro",
                title: "Intro",
                content: "Evidence",
                tokenCount: 2,
                isTruncated: false
            )
        ])
        let chunkID = try #require(sync.pendingChunkIDs.first)
        let store = GRDBRAGConversationStore(database: database)
        let conversation = try await store.createConversation(title: nil)
        try await store.appendTurn(
            conversationID: conversation.id,
            question: "Q",
            answer: "A [S1]",
            model: "chat",
            citations: [RAGCitation(
                id: UUID(),
                marker: "S1",
                chunkID: chunkID,
                repoID: 42,
                repoFullName: "octo/demo-42",
                source: RAGCitationSource.readme,
                sectionTitle: "Intro",
                score: 0.9,
                hitKind: .hybrid,
                vectorSimilarity: 0.91,
                scoreBreakdown: RAGScoreBreakdown(
                    hitKind: .hybrid,
                    rrfConstant: 60,
                    keywordRank: 1,
                    keywordScore: 1,
                    keywordWeight: 1,
                    keywordScoreWeight: 0.12,
                    vectorRank: 2,
                    vectorSimilarity: 0.91,
                    vectorWeight: 1.15,
                    vectorScoreWeight: 0.20,
                    sourceWeight: 1,
                    preferredRepoBoost: 0,
                    finalScore: 0.9
                ),
                sourceURL: URL(string: "https://github.com/octo/demo-42")
            )]
        )
        try await chunks.deleteAll()
        let detail = try #require(try await store.loadConversation(id: conversation.id))
        let citation = try #require(detail.messages.last?.citations.first)
        #expect(citation.chunkID == nil)
        #expect(citation.repoFullName == "octo/demo-42")
        #expect(citation.marker == "S1")
        #expect(citation.vectorSimilarity == 0.91)
        #expect(citation.scoreBreakdown?.vectorRank == 2)
    }

    @Test("会话历史保存用户可见执行轨迹，不保存 Debug payload")
    func executionTracePersistsWithAssistantMessage() async throws {
        let database = try InMemoryDatabaseManager()
        let store = GRDBRAGConversationStore(database: database)
        let conversation = try await store.createConversation()
        let plan = RAGQueryPlan(
            mode: .filteredSemantic,
            semanticQuery: "Swift database architecture",
            filters: RAGRepoFilter(languages: ["Swift"], minStars: 500),
            candidateLimit: 24,
            webSearchRequests: [RAGWebSearchRequest(
                query: "Swift database architecture 2026",
                reason: "需要核对最新资料",
                maxResults: 6
            )],
            requiresLiveEvidence: true,
            userVisiblePlan: RAGUserVisiblePlan(
                scope: "知识库",
                semantic: "Swift database architecture",
                planningNotes: ["先筛选 Swift 仓库，再核对实时资料。"]
            )
        )
        var diagnostics = RAGRetrievalDiagnostics(
            settings: .balanced,
            candidateRepoCount: 12,
            outcome: .completed
        )
        diagnostics.keywordRawCount = 18
        diagnostics.keywordSourceFilteredCount = 2
        diagnostics.vectorRawCount = 20
        diagnostics.vectorSimilarityFilteredCount = 5
        diagnostics.fusion.uniqueCount = 24
        diagnostics.minimumEvidenceScoreFilteredCount = 4
        diagnostics.rerank = RAGRerankDiagnostics(
            state: .completed,
            candidateCount: 8,
            rerankedCount: 6
        )
        diagnostics.finalChildHitCount = 6
        diagnostics.bundleCount = 2
        let retrievalTrace = RAGRetrievalTrace(
            candidates: [.init(repoID: 21, fullName: "octo/demo-21", language: "Swift", stars: 12_345)],
            semanticHits: [.init(
                chunkID: 101,
                repoID: 21,
                repositoryName: "octo/demo-21",
                source: .readme,
                sectionTitle: "README > Storage",
                rank: 1,
                score: 0.84,
                hitKind: .vector,
                vectorSimilarity: 0.91,
                scoreBreakdown: nil,
                disposition: .retained
            )]
        )
        let retrievalSnapshot = RAGRetrievalSnapshot(result: RAGRetrievalResult(
            candidates: [],
            bundles: [],
            childHits: [],
            diagnostics: diagnostics,
            trace: retrievalTrace
        ))
        let contextSnapshot = RAGContextUsageSnapshot(usage: RAGContextUsage(
            windowTokens: 32_768,
            reservedOutputTokens: 4_096,
            tokensBySegment: [.question: 120, .evidence: 2_400, .reservedOutput: 4_096],
            promptPreview: "不得写入历史的原始 Prompt"
        ))
        let trace = [
            RAGExecutionStep(
                kind: .planning,
                state: .completed,
                details: ["先识别问题的检索意图。"],
                summary: "已规划检索",
                queryPlan: plan,
                contextUsageSnapshot: contextSnapshot
            ),
            RAGExecutionStep(
                kind: .retrieval,
                state: .completed,
                details: ["已完成本地检索。"],
                summary: "采用 2 个仓库的 6 个分片",
                retrievalSnapshot: retrievalSnapshot
            ),
            RAGExecutionStep(
                kind: .remoteContext,
                state: .completed,
                details: [],
                summary: "已获取 1 条 GitHub 上下文",
                remoteAuditItems: [RAGRemoteExecutionAuditItem(
                    id: "21:github_issues:0",
                    repoFullName: "octo/demo-21",
                    resource: .githubIssues,
                    querySummary: "crash",
                    requestURL: URL(string: "https://api.github.com/search/issues"),
                    status: .succeeded,
                    transport: .network,
                    httpStatusCode: 200,
                    resultCount: 1,
                    errorMessage: nil,
                    startedAt: Date(timeIntervalSince1970: 100),
                    completedAt: Date(timeIntervalSince1970: 101)
                )]
            ),
            RAGExecutionStep(
                kind: .generation,
                state: .completed,
                details: ["正在根据 2 组证据组织回答"],
                summary: "回答已生成，使用 2 条引用"
            )
        ]

        try await store.appendTurn(
            conversationID: conversation.id,
            question: "帮我比较两个项目",
            answer: "比较结果",
            model: "test-model",
            citations: [],
            executionTrace: trace,
            processingDuration: 12.4
        )

        let detail = try #require(try await store.loadConversation(id: conversation.id))
        #expect(detail.messages.last?.executionTrace == trace)
        #expect(detail.messages.last?.processingDuration == 12.4)
        let restoredPlanning = try #require(detail.messages.last?.executionTrace.first)
        #expect(restoredPlanning.queryPlan == plan)
        #expect(restoredPlanning.contextUsageSnapshot?.usage.promptPreview == "")
        #expect(restoredPlanning.contextUsageSnapshot?.usage.inputTokens == 2_520)
        let restoredRetrieval = try #require(
            detail.messages.last?.executionTrace.first(where: { $0.kind == .retrieval })?.retrievalSnapshot
        )
        #expect(restoredRetrieval.keywordAcceptedCount == 16)
        #expect(restoredRetrieval.vectorAcceptedCount == 15)
        #expect(restoredRetrieval.rerankedCount == 6)
        #expect(restoredRetrieval.trace == retrievalTrace)
        #expect(restoredRetrieval.trace?.candidates.first?.language == "Swift")
        #expect(restoredRetrieval.trace?.candidates.first?.stars == 12_345)
    }

    @Test("旧执行轨迹缺少计划快照字段时仍可解码")
    func legacyExecutionStepDecodesWithoutPlanSnapshots() throws {
        let data = try #require("""
        {
          "kind": "planning",
          "state": "completed",
          "details": ["legacy"],
          "summary": "done"
        }
        """.data(using: .utf8))

        let step = try JSONDecoder().decode(RAGExecutionStep.self, from: data)
        #expect(step.queryPlan == nil)
        #expect(step.retrievalSnapshot == nil)
        #expect(step.contextUsageSnapshot == nil)
    }

    @Test("旧候选仓库轨迹缺少语言与 Star 字段时仍可解码")
    func legacyRetrievalCandidateTraceDecodesWithoutPresentationMetadata() throws {
        let data = try #require("""
        {
          "repoID": 21,
          "fullName": "octo/demo-21"
        }
        """.data(using: .utf8))

        let trace = try JSONDecoder().decode(RAGRetrievalCandidateTrace.self, from: data)
        #expect(trace.language == nil)
        #expect(trace.stars == nil)
    }

    @Test("推荐问题随 assistant message 持久化仓库范围")
    func suggestedActionsPersistWithRepositoryScope() async throws {
        let database = try InMemoryDatabaseManager()
        let store = GRDBRAGConversationStore(database: database)
        let conversation = try await store.createConversation()
        let action = RAGSuggestedQuestionAction(
            question: "这个项目最近有哪些未关闭 Issues？",
            repoIDs: [21],
            explicitRepoMode: .only
        )

        try await store.appendTurn(
            conversationID: conversation.id,
            question: "你好",
            answer: "你可以继续问：",
            model: "Starcat",
            citations: [],
            suggestedActions: [action]
        )

        let detail = try #require(try await store.loadConversation(id: conversation.id))
        #expect(detail.messages.last?.suggestedActions == [action])
    }

    @Test("外部后端配置拒绝无效 endpoint")
    func backendValidation() {
        var meili = RAGMeilisearchConfiguration()
        meili.endpoint = "not a url"
        #expect(meili.validationMessage != nil)
        meili.endpoint = "ftp://localhost:7700"
        #expect(meili.validationMessage != nil)
        var qdrant = RAGQdrantConfiguration()
        qdrant.collectionName = "other/collection"
        #expect(qdrant.validationMessage != nil)
    }

    @Test("禁用 SQLite 回退时外部后端配置错误必须抛出")
    func backendValidationRespectsFallbackSwitch() {
        var configuration = RAGBackendConfiguration()
        configuration.keywordBackend = .meilisearch
        configuration.meilisearch.endpoint = "not a url"

        configuration.fallbackToSQLite = true
        #expect(throws: Never.self) {
            try configuration.validateSelectedBackendsForRuntime()
        }

        configuration.fallbackToSQLite = false
        #expect(throws: RAGExternalBackendError.self) {
            try configuration.validateSelectedBackendsForRuntime()
        }
    }

    @Test("Meilisearch 报错或空命中时回退 SQLite provider")
    func keywordBackendFallback() async throws {
        let expected = RAGChildHit(chunk: fixtureChunk(id: 90, repoID: 9, source: .readme), score: 0.8, kind: .keyword)
        let fallback = StubRAGKeywordProvider(backendName: "SQLite", hits: [expected], shouldThrow: false)

        let errorProvider = FallbackRAGKeywordSearchProvider(
            primary: StubRAGKeywordProvider(backendName: "Meilisearch", hits: [], shouldThrow: true),
            fallback: fallback
        )
        let emptyProvider = FallbackRAGKeywordSearchProvider(
            primary: StubRAGKeywordProvider(backendName: "Meilisearch", hits: [], shouldThrow: false),
            fallback: fallback
        )

        #expect(try await errorProvider.search(query: "RAG", model: "embed", repoIDs: [9], limit: 10) == [expected])
        #expect(try await emptyProvider.search(query: "RAG", model: "embed", repoIDs: [9], limit: 10) == [expected])

        let disabledErrorProvider = FallbackRAGKeywordSearchProvider(
            primary: StubRAGKeywordProvider(backendName: "Meilisearch", hits: [], shouldThrow: true),
            fallback: fallback,
            fallbackToSQLite: false
        )
        let disabledEmptyProvider = FallbackRAGKeywordSearchProvider(
            primary: StubRAGKeywordProvider(backendName: "Meilisearch", hits: [], shouldThrow: false),
            fallback: fallback,
            fallbackToSQLite: false
        )
        await #expect(throws: StubRAGProviderError.self) {
            try await disabledErrorProvider.search(query: "RAG", model: "embed", repoIDs: [9], limit: 10)
        }
        #expect(try await disabledEmptyProvider.search(query: "RAG", model: "embed", repoIDs: [9], limit: 10).isEmpty)
    }

    @Test("Meilisearch 回退不得吞掉取消")
    func keywordBackendFallbackPreservesCancellation() async {
        let provider = FallbackRAGKeywordSearchProvider(
            primary: CancellingRAGKeywordProvider(),
            fallback: StubRAGKeywordProvider(backendName: "SQLite", hits: [], shouldThrow: false)
        )

        await #expect(throws: CancellationError.self) {
            try await provider.search(query: "RAG", model: "embed", repoIDs: [9], limit: 10)
        }
    }

    @Test("Meilisearch replace 等待异步 tasks 真正完成")
    func meilisearchReplaceWaitsForTasks() async throws {
        let database = try InMemoryDatabaseManager()
        let httpClient = SequencedRAGHTTPClient(responses: [
            (Data(#"{"taskUid":1}"#.utf8), 202),
            (Data(#"{"status":"succeeded"}"#.utf8), 200),
            (Data(#"{"taskUid":2}"#.utf8), 202),
            (Data(#"{"status":"succeeded"}"#.utf8), 200)
        ])
        let provider = MeilisearchRAGProvider(
            configuration: RAGMeilisearchConfiguration(),
            apiKey: nil,
            repository: GRDBRAGChunkRepository(database: database),
            httpClient: httpClient
        )

        try await provider.replaceAll(chunks: [])

        #expect(await httpClient.requestCount == 4)
    }

    @Test("Metadata-only 变更只生成 Meilisearch 增量操作")
    func metadataOnlyExternalSyncSkipsQdrant() {
        var metadata = fixtureChunk(id: 93, repoID: 9, source: .metadata)
        metadata.embeddingStatus = .keywordOnly
        metadata.embeddingModel = nil
        metadata.embedding = nil

        var changes = RAGExternalIndexChangeSet()
        changes.recordUpserts([93])
        let plan = RAGExternalIndexSyncPlan(
            changes: changes,
            currentChunks: [metadata],
            publicKnowledgeRepoIDs: Set([9]),
            model: "embed-v1"
        )

        #expect(plan.keywordUpserts.compactMap(\.id) == [93])
        #expect(plan.keywordDeleteIDs.isEmpty)
        #expect(plan.vectorUpserts.isEmpty)
        #expect(plan.vectorDeleteIDs.isEmpty)
    }

    @Test("Meilisearch 增量同步不清空全量文档")
    func meilisearchAppliesChunkChangesIncrementally() async throws {
        let database = try InMemoryDatabaseManager()
        let httpClient = SequencedRAGHTTPClient(responses: [
            (Data(#"{"taskUid":1}"#.utf8), 202),
            (Data(#"{"status":"succeeded"}"#.utf8), 200),
            (Data(#"{"taskUid":2}"#.utf8), 202),
            (Data(#"{"status":"succeeded"}"#.utf8), 200)
        ])
        let provider = MeilisearchRAGProvider(
            configuration: RAGMeilisearchConfiguration(),
            apiKey: nil,
            repository: GRDBRAGChunkRepository(database: database),
            httpClient: httpClient
        )

        try await provider.applyChanges(
            upserts: [fixtureChunk(id: 94, repoID: 9, source: .readme)],
            deleteIDs: [91]
        )

        let requests = await httpClient.recordedRequests
        #expect(requests.count == 4)
        #expect(requests[0].url?.path.hasSuffix("/documents/delete-batch") == true)
        #expect(requests[0].httpMethod == "POST")
        #expect(requests[2].url?.path.hasSuffix("/documents") == true)
        #expect(!requests.contains { $0.httpMethod == "DELETE" })
    }

    @Test("Qdrant 增量同步只删除指定 point")
    func qdrantAppliesChunkChangesIncrementally() async throws {
        let database = try InMemoryDatabaseManager()
        let collection = #"{"result":{"config":{"params":{"vectors":{"content":{"size":2,"distance":"Cosine"}}}}}}"#
        let httpClient = SequencedRAGHTTPClient(responses: [
            (Data(collection.utf8), 200),
            (Data(#"{}"#.utf8), 200),
            (Data(#"{}"#.utf8), 200)
        ])
        let provider = QdrantRAGProvider(
            configuration: RAGQdrantConfiguration(),
            apiKey: nil,
            repository: GRDBRAGChunkRepository(database: database),
            httpClient: httpClient
        )

        try await provider.applyChanges(
            upserts: [fixtureChunk(id: 94, repoID: 9, source: .readme)],
            deleteIDs: [91]
        )

        let requests = await httpClient.recordedRequests
        #expect(requests.count == 3)
        let deleteBody = try #require(requests[1].httpBody)
        let deleteJSON = try #require(try JSONSerialization.jsonObject(with: deleteBody) as? [String: Any])
        #expect(deleteJSON["points"] as? [Int] == [91])
        #expect(deleteJSON["filter"] == nil)
    }

    @Test("Qdrant 报错或空命中时回退本地向量 provider")
    func vectorBackendFallback() async throws {
        let expected = RAGChildHit(chunk: fixtureChunk(id: 91, repoID: 9, source: .notes), score: 0.9, kind: .vector)
        let fallback = StubRAGVectorProvider(backendName: "SQLite", hits: [expected], shouldThrow: false)

        let errorProvider = FallbackRAGVectorSearchProvider(
            primary: StubRAGVectorProvider(backendName: "Qdrant", hits: [], shouldThrow: true),
            fallback: fallback
        )
        let emptyProvider = FallbackRAGVectorSearchProvider(
            primary: StubRAGVectorProvider(backendName: "Qdrant", hits: [], shouldThrow: false),
            fallback: fallback
        )

        #expect(try await errorProvider.search(queryVector: [1, 0], model: "embed", repoIDs: [9], limit: 10) == [expected])
        #expect(try await emptyProvider.search(queryVector: [1, 0], model: "embed", repoIDs: [9], limit: 10) == [expected])

        let disabledErrorProvider = FallbackRAGVectorSearchProvider(
            primary: StubRAGVectorProvider(backendName: "Qdrant", hits: [], shouldThrow: true),
            fallback: fallback,
            fallbackToSQLite: false
        )
        let disabledEmptyProvider = FallbackRAGVectorSearchProvider(
            primary: StubRAGVectorProvider(backendName: "Qdrant", hits: [], shouldThrow: false),
            fallback: fallback,
            fallbackToSQLite: false
        )
        await #expect(throws: StubRAGProviderError.self) {
            try await disabledErrorProvider.search(queryVector: [1, 0], model: "embed", repoIDs: [9], limit: 10)
        }
        #expect(try await disabledEmptyProvider.search(queryVector: [1, 0], model: "embed", repoIDs: [9], limit: 10).isEmpty)
    }

    @Test("Qdrant 回退不得吞掉取消")
    func vectorBackendFallbackPreservesCancellation() async {
        let provider = FallbackRAGVectorSearchProvider(
            primary: CancellingRAGVectorProvider(),
            fallback: StubRAGVectorProvider(backendName: "SQLite", hits: [], shouldThrow: false)
        )

        await #expect(throws: CancellationError.self) {
            try await provider.search(queryVector: [1, 0], model: "embed", repoIDs: [9], limit: 10)
        }
    }

    @Test("外部索引同步按开关决定是否吞掉普通错误，且永不吞取消")
    func externalBackendSyncFallbackPolicy() {
        #expect(throws: Never.self) {
            try RAGExternalBackendFallbackPolicy.handle(
                StubRAGProviderError.unavailable,
                fallbackToSQLite: true
            )
        }
        #expect(throws: StubRAGProviderError.self) {
            try RAGExternalBackendFallbackPolicy.handle(
                StubRAGProviderError.unavailable,
                fallbackToSQLite: false
            )
        }
        #expect(throws: CancellationError.self) {
            try RAGExternalBackendFallbackPolicy.handle(
                CancellationError(),
                fallbackToSQLite: true
            )
        }
    }

    @Test("Qdrant 已有 collection 的命名向量不匹配时在清理前失败")
    func qdrantCollectionCompatibility() async throws {
        let database = try InMemoryDatabaseManager()
        let response = """
            {"result":{"config":{"params":{"vectors":{"another":{"size":2,"distance":"Cosine"}}}}}}
            """
        let provider = QdrantRAGProvider(
            configuration: RAGQdrantConfiguration(),
            apiKey: nil,
            repository: GRDBRAGChunkRepository(database: database),
            httpClient: StaticRAGHTTPClient(data: Data(response.utf8), statusCode: 200)
        )

        do {
            try await provider.replaceAll(chunks: [fixtureChunk(id: 92, repoID: 9, source: .readme)])
            Issue.record("命名向量不匹配时不应继续清理或写入 collection")
        } catch {
            #expect(error.localizedDescription.contains("content"))
        }
    }

    @Test("GitHub Issues 响应不会把额外 repo 混入候选上下文")
    func githubIssuesRemainCandidateScoped() async throws {
        let response = """
            {
              "items": [
                {
                  "number": 1,
                  "title": "Allowed issue",
                  "state": "open",
                  "html_url": "https://github.com/octo/demo-9/issues/1",
                  "repository_url": "https://api.github.com/repos/octo/demo-9",
                  "body": "candidate body",
                  "labels": [{"name":"bug"}],
                  "comments": 2,
                  "updated_at": "2026-07-10T00:00:00Z"
                },
                {
                  "number": 2,
                  "title": "Foreign issue",
                  "state": "open",
                  "html_url": "https://github.com/other/repo/issues/2",
                  "repository_url": "https://api.github.com/repos/other/repo",
                  "body": "must not enter prompt",
                  "labels": [{"name":"foreign"}],
                  "comments": 1,
                  "updated_at": "2026-07-10T00:00:00Z"
                },
                {
                  "number": 3,
                  "title": "Same-repo pull request",
                  "state": "open",
                  "html_url": "https://github.com/octo/demo-9/pull/3",
                  "repository_url": "https://api.github.com/repos/octo/demo-9",
                  "pull_request": {"url":"https://api.github.com/repos/octo/demo-9/pulls/3"},
                  "body": "must not enter issue prompt",
                  "labels": [],
                  "comments": 0,
                  "updated_at": "2026-07-10T00:00:00Z"
                }
              ]
            }
            """
        let provider = GitHubRAGRemoteContextProvider(
            httpClient: StaticRAGHTTPClient(data: Data(response.utf8), statusCode: 200),
            token: nil,
            cache: RAGRemoteContextMemoryCache()
        )
        let request = RAGRemoteContextRequest(
            resource: .githubIssues,
            query: "crash OR(repo:other/repo)",
            reason: "验证候选边界",
            maxRepos: 1,
            perRepoLimit: 10
        )

        let recorder = RAGRemoteDebugEventRecorder()
        let blocks = await provider.fetch(
            workItems: remoteWorkItems(request: request, candidates: [RAGRepoCandidate(
                repo: fixtureRepo(id: 9, isPrivate: false),
                status: .using,
                libraryUpdatedAt: nil,
                tagNames: []
            )]),
            onProgress: { _ in },
            onDebug: { event in recorder.record(event) }
        )
        let content = try #require(blocks.first?.content)
        #expect(content.contains("Allowed issue"))
        #expect(!content.contains("Foreign issue"))
        #expect(!content.contains("foreign"))
        #expect(!content.contains("Same-repo pull request"))
        #expect(recorder.payloads.allSatisfy {
            !$0.contains("other/repo") && !$0.contains("other%2Frepo")
        })
    }

    @Test("GitHub 远程上下文逐条记录真实请求与缓存命中")
    func githubRemoteContextRecordsEachExternalRequestInDebug() async throws {
        let response = Data("{\"items\":[]}".utf8)
        let provider = GitHubRAGRemoteContextProvider(
            httpClient: StaticRAGHTTPClient(data: response, statusCode: 200),
            token: "never-log-this-token",
            cache: RAGRemoteContextMemoryCache()
        )
        let request = RAGRemoteContextRequest(
            resource: .githubIssues,
            query: "crash",
            reason: "验证 Debug Trace",
            maxRepos: 1,
            perRepoLimit: 1
        )
        let candidates = [RAGRepoCandidate(
            repo: fixtureRepo(id: 9, isPrivate: false),
            status: .using,
            libraryUpdatedAt: nil,
            tagNames: []
        )]
        let recorder = RAGRemoteDebugEventRecorder()

        _ = await provider.fetch(
            workItems: remoteWorkItems(request: request, candidates: candidates),
            onProgress: { _ in },
            onDebug: { event in recorder.record(event) }
        )
        _ = await provider.fetch(
            workItems: remoteWorkItems(request: request, candidates: candidates),
            onProgress: { _ in },
            onDebug: { event in recorder.record(event) }
        )

        #expect(recorder.stages.contains(.remoteRequest))
        #expect(recorder.stages.contains(.remoteResponse))
        #expect(recorder.payloads.contains { $0.contains("status: 200") })
        #expect(recorder.payloads.contains { $0.contains("cache: hit") })
        #expect(recorder.payloads.allSatisfy { !$0.contains("never-log-this-token") })
    }

    @Test("GitHub 远程缓存按认证 token 隔离")
    func githubRemoteCacheIsTokenScoped() async throws {
        func response(title: String) -> Data {
            Data("""
                {"items":[{
                  "number":1,"title":"\(title)","state":"open",
                  "html_url":"https://github.com/octo/demo-9/issues/1",
                  "repository_url":"https://api.github.com/repos/octo/demo-9",
                  "body":"body","labels":[],"comments":0,
                  "updated_at":"2026-07-10T00:00:00Z"
                }]}
                """.utf8)
        }
        let cache = RAGRemoteContextMemoryCache()
        let request = RAGRemoteContextRequest(
            resource: .githubIssues,
            query: "bug",
            reason: "验证账户隔离",
            maxRepos: 1,
            perRepoLimit: 10
        )
        let candidates = [RAGRepoCandidate(
            repo: fixtureRepo(id: 9, isPrivate: true),
            status: .using,
            libraryUpdatedAt: nil,
            tagNames: []
        )]
        let first = GitHubRAGRemoteContextProvider(
            httpClient: StaticRAGHTTPClient(data: response(title: "Account A"), statusCode: 200),
            token: "token-a",
            cache: cache
        )
        let second = GitHubRAGRemoteContextProvider(
            httpClient: StaticRAGHTTPClient(data: response(title: "Account B"), statusCode: 200),
            token: "token-b",
            cache: cache
        )

        _ = await first.fetch(workItems: remoteWorkItems(request: request, candidates: candidates), onProgress: { _ in })
        let secondBlocks = await second.fetch(workItems: remoteWorkItems(request: request, candidates: candidates), onProgress: { _ in })

        #expect(secondBlocks.first?.content.contains("Account B") == true)
        #expect(secondBlocks.first?.content.contains("Account A") == false)
    }

    @Test("远程上下文只持久化审计元数据")
    func remoteContextAuditPersistsMetadataOnly() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 43)
        let store = GRDBRAGConversationStore(database: database)
        let conversation = try await store.createConversation()
        let fetchedAt = Date(timeIntervalSince1970: 1_784_000_000)

        let persisted = try await store.appendTurn(
            conversationID: conversation.id,
            question: "近期 issue 有什么风险？",
            answer: "有一个待处理问题。",
            model: "test-model",
            citations: [],
            remoteContexts: [
                RAGRemoteContextBlock(
                    id: "issues-43",
                    repoId: 43,
                    resource: .githubIssues,
                    title: "GitHub Issues",
                    sourceURL: URL(string: "https://github.com/octo/demo-43/issues"),
                    content: "这段远程正文不应写入历史表。",
                    fetchedAt: fetchedAt,
                    errorMessage: nil
                ),
                RAGRemoteContextBlock(
                    id: "external-web",
                    repoId: nil,
                    resource: .externalWeb,
                    title: "Tavily · Web Search",
                    sourceURL: URL(string: "https://example.com/result"),
                    content: "普通 Web 正文同样不能写入 GitHub 审计表。",
                    fetchedAt: fetchedAt,
                    errorMessage: nil
                ),
            ]
        )

        let loaded = try await store.loadConversation(id: conversation.id)
        let detail = try #require(loaded)
        let audit = try #require(detail.messages.last?.remoteContextAudits.first)
        #expect(persisted.userMessage.content == "近期 issue 有什么风险？")
        #expect(persisted.assistantMessage == detail.messages.last)
        #expect(audit.resource == .githubIssues)
        #expect(audit.repoID == 43)
        #expect(audit.sourceURL?.absoluteString == "https://github.com/octo/demo-43/issues")
        #expect(audit.fetchedAt == ISO8601DateFormatter.shared.string(from: fetchedAt))
        #expect(detail.messages.last?.remoteContextAudits.count == 1)
        let columns = try await database.writer.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(rag_message_remote_contexts)")
                .map { (row: Row) -> String in row["name"] }
        }
        #expect(!columns.contains("content"))
    }

    @Test("大窗口短会话不会因固定消息条数被提前压缩")
    func conversationHistoryWaitsForTokenBudget() {
        let conversationID = UUID()
        let messages = (0..<8).map { index in
            RAGStoredMessage(
                id: UUID(),
                conversationID: conversationID,
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: "消息 \(index) 简短内容",
                model: index.isMultiple(of: 2) ? nil : "test-model",
                citations: [],
                remoteContextAudits: [],
                createdAt: "2026-07-11T00:00:0\(index)Z"
            )
        }

        let target = RAGConversationHistoryBuilder.compressionCoverageTarget(
            messages: messages,
            existingSummary: nil,
            contextWindowTokens: 32 * 1_024,
            maximumOutputTokens: 8 * 1_024
        )
        let history = RAGConversationHistoryBuilder.build(from: messages)
        #expect(target == 0)
        #expect(history.count == 8)
        #expect(history.first?.content.contains("消息 0") == true)
        #expect(history.last?.content.contains("消息 7") == true)
    }

    @Test("小窗口长历史按 token 预算触发压缩")
    func conversationHistoryCompressesForSmallWindow() {
        let conversationID = UUID()
        let messages = (0..<8).map { index in
            RAGStoredMessage(
                id: UUID(),
                conversationID: conversationID,
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: "消息 \(index) " + String(repeating: "long context ", count: 1_000),
                model: index.isMultiple(of: 2) ? nil : "test-model",
                citations: [],
                remoteContextAudits: [],
                createdAt: "2026-07-11T00:00:0\(index)Z"
            )
        }

        let target = RAGConversationHistoryBuilder.compressionCoverageTarget(
            messages: messages,
            existingSummary: nil,
            contextWindowTokens: 4 * 1_024,
            maximumOutputTokens: 8 * 1_024
        )
        #expect(target == 2)
    }

    @Test("压缩降级优先保留刚离窗的新消息")
    func conversationFallbackKeepsNewlyCoveredMessages() {
        let conversationID = UUID()
        let message = RAGStoredMessage(
            id: UUID(),
            conversationID: conversationID,
            role: .user,
            content: "必须保留的新约束：仅使用知识库证据。",
            model: nil,
            citations: [],
            remoteContextAudits: [],
            createdAt: "2026-07-11T00:00:00Z"
        )

        let fallback = RAGConversationContextCompressor.fallback(
            existingSummary: String(repeating: "过期摘要 ", count: 2_000),
            messages: [message],
            tokenBudget: 512
        )
        #expect(fallback.contains("必须保留的新约束"))
    }

    @Test("大纲轨只投影完整问答轮次，跳过未完成用户消息")
    func outlineRailUsesCompleteTurnsOnly() {
        let conversationID = UUID()
        let user1 = UUID()
        let assistant1 = UUID()
        let orphanUser = UUID()
        let messages = [
            RAGStoredMessage(
                id: user1,
                conversationID: conversationID,
                role: .user,
                content: "第一问\n第二行",
                model: nil,
                citations: [],
                remoteContextAudits: [],
                createdAt: "2026-07-13T01:00:00Z"
            ),
            RAGStoredMessage(
                id: assistant1,
                conversationID: conversationID,
                role: .assistant,
                content: String(repeating: "答", count: 160),
                model: "test-model",
                citations: [],
                remoteContextAudits: [],
                createdAt: "2026-07-13T01:00:05Z"
            ),
            RAGStoredMessage(
                id: orphanUser,
                conversationID: conversationID,
                role: .user,
                content: "还在生成中的问题",
                model: nil,
                citations: [],
                remoteContextAudits: [],
                createdAt: "2026-07-13T01:01:00Z"
            )
        ]

        let turns = RAGConversationOutlineBuilder.completeTurns(from: messages)
        #expect(turns.count == 1)
        #expect(turns[0].userMessageID == user1)
        #expect(turns[0].title == "第一问")
        #expect(turns[0].preview.hasSuffix("…"))
        #expect(turns[0].timestampISO8601 == "2026-07-13T01:00:05Z")
    }

    private func fixtureChunk(id: Int64, repoID: Int64, source: RAGChunkSource) -> RAGChunk {
        RAGChunk(
            id: id,
            repoId: repoID,
            source: source,
            sourceId: "",
            parentType: .readmeSection,
            parentKey: "readme:test",
            parentTitle: "Test",
            chunkKey: "chunk:\(id)",
            chunkIndex: Int(id),
            sectionPath: "Test",
            title: "Test",
            content: "content \(id)",
            contentHash: "hash-\(id)",
            tokenCount: 2,
            isTruncated: false,
            embeddingModel: "embed",
            embeddingDim: 2,
            embedding: RepoEmbedding.encode([1, 0]),
            embeddingStatus: .ready,
            embeddingError: nil,
            indexedAt: "2026-07-10T00:00:00.000Z",
            createdAt: "2026-07-10T00:00:00.000Z",
            updatedAt: "2026-07-10T00:00:00.000Z"
        )
    }

    private func fixtureCitation(marker: String) -> RAGCitation {
        RAGCitation(
            id: UUID(),
            marker: marker,
            chunkID: 1,
            repoID: 1,
            repoFullName: "octo/demo",
            source: RAGCitationSource.readme,
            sectionTitle: "README > Test",
            score: 0.9,
            hitKind: .hybrid,
            vectorSimilarity: 0.9,
            sourceURL: URL(string: "https://github.com/octo/demo")
        )
    }

    @Test("Mention picker: 已选置顶且不匹配关键词仍保留")
    func mentionPickerPinsSelectedOutsideFilter() {
        let redis = mentionFixtureRepo(id: 1, fullName: "redis/redis", language: "C", stars: 50_000)
        let jedis = mentionFixtureRepo(id: 2, fullName: "redis/jedis", language: "Java", stars: 10_000)
        let awesome = mentionFixtureRepo(id: 3, fullName: "sindresorhus/awesome", language: nil, stars: 200_000)
        let candidates = [redis, jedis, awesome].map(RAGMentionCandidate.init(repo:))

        let snapshot = RAGMentionPickerLogic.build(
            candidates: candidates,
            selected: [awesome],
            query: "redis"
        )

        #expect(snapshot.suggestions.map(\.id) == [3, 1, 2])
        #expect(snapshot.selectedCount == 1)
        #expect(snapshot.knowledgeCount == 3)
        #expect(snapshot.matchCount == 2)
        #expect(snapshot.displayedCount == 3)
        #expect(!snapshot.isTruncated)
    }

    @Test("Composer 明确上下文仓库上限为 20，禁止全选式塞库")
    func composerSelectedRepoContextCapIsTwenty() {
        #expect(RAGMentionPickerLogic.maxSelectedRepoContexts == 20)
    }

    @Test("Mention picker: 未选命中超过上限会截断并保留已选")
    func mentionPickerTruncatesUnselectedMatches() {
        let selected = mentionFixtureRepo(id: 0, fullName: "selected/repo", language: "Swift", stars: 1)
        let allCandidates: [RAGMentionCandidate] = [RAGMentionCandidate(repo: selected)]
            + (1...RAGMentionPickerLogic.unselectedDisplayLimit + 5).map { id in
                RAGMentionCandidate(repo: mentionFixtureRepo(
                    id: Int64(id),
                    fullName: "owner/repo-\(id)",
                    language: "Go",
                    stars: id
                ))
            }

        let snapshot = RAGMentionPickerLogic.build(
            candidates: allCandidates,
            selected: [selected],
            query: ""
        )

        #expect(snapshot.suggestions.first?.id == 0)
        #expect(snapshot.suggestions.count == 1 + RAGMentionPickerLogic.unselectedDisplayLimit)
        #expect(snapshot.displayedCount == 1 + RAGMentionPickerLogic.unselectedDisplayLimit)
        #expect(snapshot.matchCount == allCandidates.count)
        #expect(snapshot.isTruncated)
        #expect(RAGMentionPickerLogic.unselectedDisplayLimit == 80)
    }

    @Test("Add to library: 过滤未入库 Stars，并按关键词筛选")
    func addToLibraryFiltersOutsideLibraryStars() {
        let outside = mentionFixtureRepo(id: 1, fullName: "apple/swift", language: "C++", stars: 100)
        let inside = mentionFixtureRepo(id: 2, fullName: "apple/swift-nio", language: "Swift", stars: 50)
        let other = mentionFixtureRepo(id: 3, fullName: "redis/redis", language: "C", stars: 10)

        let candidates = RAGAddToLibraryLogic.outsideLibraryStars(
            starred: [outside, inside, other],
            libraryStateMap: [inside.id: .inLibrary]
        )
        #expect(candidates.map(\.id) == [1, 3])

        let filtered = RAGAddToLibraryLogic.filter(candidates, query: "swift")
        #expect(filtered.map(\.id) == [1])
    }

    @Test
    func addToLibraryPaginationWindowsAndPrefetches() {
        let repos = (1...75).map { mentionFixtureRepo(id: Int64($0), fullName: "o/r\($0)", language: "Go", stars: $0) }
        #expect(RAGAddToLibraryLogic.displayedRepos(repos, limit: 30).count == 30)
        #expect(RAGAddToLibraryLogic.shouldPrefetchNextPage(
            appearingIndex: 21,
            displayedLimit: 30,
            filteredCount: 75
        ))
        #expect(!RAGAddToLibraryLogic.shouldPrefetchNextPage(
            appearingIndex: 10,
            displayedLimit: 30,
            filteredCount: 75
        ))
        #expect(RAGAddToLibraryLogic.nextDisplayLimit(current: 30, filteredCount: 75) == 60)
        #expect(RAGAddToLibraryLogic.nextDisplayLimit(current: 60, filteredCount: 75) == 75)
        #expect(!RAGAddToLibraryLogic.shouldPrefetchNextPage(
            appearingIndex: 70,
            displayedLimit: 75,
            filteredCount: 75
        ))
    }

    private func mentionFixtureRepo(
        id: Int64,
        fullName: String,
        language: String?,
        stars: Int
    ) -> Repo {
        let parts = fullName.split(separator: "/", maxSplits: 1).map(String.init)
        return Repo(
            id: id,
            owner: parts.first ?? "owner",
            name: parts.count > 1 ? parts[1] : "repo",
            fullName: fullName,
            description: "Demo \(fullName)",
            language: language,
            starsCount: stars,
            forksCount: 0,
            watchersCount: 0,
            topics: "[]",
            license: nil,
            homepage: nil,
            htmlUrl: "https://github.com/\(fullName)",
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: false,
            isFork: false,
            isArchived: false,
            isStarred: true,
            pushedAt: nil,
            createdAt: nil,
            updatedAt: nil,
            starredAt: nil,
            cachedAt: nil
        )
    }

    private func fixtureRepo(id: Int64, isPrivate: Bool) -> Repo {
        Repo(
            id: id,
            owner: "octo",
            name: "demo-\(id)",
            fullName: "octo/demo-\(id)",
            description: "Demo",
            language: "Swift",
            starsCount: 100,
            forksCount: 10,
            watchersCount: 5,
            topics: "[]",
            license: "MIT",
            homepage: nil,
            htmlUrl: "https://github.com/octo/demo-\(id)",
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: isPrivate,
            isFork: false,
            isArchived: false,
            isStarred: true,
            pushedAt: nil,
            createdAt: nil,
            updatedAt: nil,
            starredAt: nil,
            cachedAt: nil
        )
    }

    /// 文件存储测试不依赖真实 Provider，只验证一轮完整 Debug Trace 的 JSON round-trip。
    private func fixtureDebugTrace(startedAt: Date) -> RAGDebugTrace {
        RAGDebugTrace(
            id: UUID(),
            category: .questionAnswer,
            startedAt: startedAt,
            state: .completed,
            events: [
                RAGDebugEvent(stage: .request, elapsedSeconds: 0, payload: "question: test")
            ]
        )
    }
}

/// 会话启动基线只读取测试宿主自身物理内存；不访问用户数据库，也不把机器差异设为门禁。
private func ragCurrentPhysicalFootprintBytes() -> Int64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
        }
    }
    return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
}

private actor RAGRepoIDRecorder {
    private var repoIDs: [Int64] = []

    func record(_ values: [Int64]) {
        repoIDs.append(contentsOf: values)
    }

    func recordedRepoIDs() -> [Int64] {
        repoIDs
    }
}

private struct RecordingRAGKeywordProvider: RAGKeywordSearchProvider {
    let backendName: String
    let recorder: RAGRepoIDRecorder

    func search(query: String, model: String, repoIDs: [Int64], limit: Int) async throws -> [RAGChildHit] {
        await recorder.record(repoIDs)
        return []
    }
}

private struct RecordingRAGVectorProvider: RAGVectorSearchProvider {
    let backendName: String
    let recorder: RAGRepoIDRecorder

    func search(queryVector: [Float], model: String, repoIDs: [Int64], limit: Int) async throws -> [RAGChildHit] {
        await recorder.record(repoIDs)
        return []
    }
}

private enum StubRAGProviderError: Error {
    case unavailable
}

private struct StubRAGKeywordProvider: RAGKeywordSearchProvider {
    let backendName: String
    let hits: [RAGChildHit]
    let shouldThrow: Bool

    func search(query: String, model: String, repoIDs: [Int64], limit: Int) async throws -> [RAGChildHit] {
        if shouldThrow { throw StubRAGProviderError.unavailable }
        return hits
    }
}

private struct StubRAGVectorProvider: RAGVectorSearchProvider {
    let backendName: String
    let hits: [RAGChildHit]
    let shouldThrow: Bool

    func search(queryVector: [Float], model: String, repoIDs: [Int64], limit: Int) async throws -> [RAGChildHit] {
        if shouldThrow { throw StubRAGProviderError.unavailable }
        return hits
    }
}

private struct CancellingRAGKeywordProvider: RAGKeywordSearchProvider {
    let backendName = "Meilisearch"

    func search(query: String, model: String, repoIDs: [Int64], limit: Int) async throws -> [RAGChildHit] {
        throw CancellationError()
    }
}

private struct CancellingRAGVectorProvider: RAGVectorSearchProvider {
    let backendName = "Qdrant"

    func search(queryVector: [Float], model: String, repoIDs: [Int64], limit: Int) async throws -> [RAGChildHit] {
        throw CancellationError()
    }
}

private struct StubRAGReranker: RAGReranking {
    let order: [Int64]
    var shouldThrow = false
    let provider: RAGRerankProvider = .huggingFaceTEI

    func rerank(query: String, candidates: [RAGChildHit]) async throws -> [(hit: RAGChildHit, score: Double)] {
        if shouldThrow { throw StubRAGProviderError.unavailable }
        return order.enumerated().compactMap { index, id in
            guard let hit = candidates.first(where: { $0.chunk.id == id }) else { return nil }
            return (hit, Double(order.count - index))
        }
    }
}

private struct StaticRAGHTTPClient: RAGHTTPClientProtocol {
    let data: Data
    let statusCode: Int

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "http://127.0.0.1")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }
}

/// 适配器测试需要断言发送的协议字段，因此记录请求而非仅返回固定响应。
private actor RecordingRAGHTTPClient: RAGHTTPClientProtocol {
    private let data: Data
    private var recordedRequest: URLRequest?

    init(data: Data) {
        self.data = data
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recordedRequest = request
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "http://127.0.0.1")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }

    func lastRequest() -> URLRequest? {
        recordedRequest
    }
}

private actor SequencedRAGHTTPClient: RAGHTTPClientProtocol {
    private var responses: [(Data, Int)]
    private(set) var requestCount = 0
    private(set) var recordedRequests: [URLRequest] = []

    init(responses: [(Data, Int)]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        requestCount += 1
        recordedRequests.append(request)
        let (data, statusCode) = responses.removeFirst()
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "http://127.0.0.1")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }
}

private struct FixedRAGPlanner: KnowledgeRAGQueryPlanning {
    var plan: RAGQueryPlan
    func plan(
        question: String,
        composerContext: RAGComposerContext,
        onReasoningDelta: @escaping (String) -> Void
    ) async throws -> RAGQueryPlan { plan }
}

private struct FailingRAGPlanner: KnowledgeRAGQueryPlanning {
    func plan(
        question: String,
        composerContext: RAGComposerContext,
        onReasoningDelta: @escaping (String) -> Void
    ) async throws -> RAGQueryPlan {
        throw StubRAGProviderError.unavailable
    }
}

private struct FixedAttachmentProcessor: RAGAttachmentProcessing {
    var contexts: [RAGAttachmentContext]

    func process(_ attachments: [RAGComposerAttachment]) async throws -> [RAGAttachmentContext] {
        contexts
    }
}

private struct FixedRemoteContextProvider: KnowledgeRAGRemoteContextProviding {
    var blocks: [RAGRemoteContextBlock]

    func fetch(
        workItems: [RAGResolvedRemoteWorkItem],
        onProgress: @escaping @Sendable (RAGRemoteContextFetchProgress) -> Void
    ) async -> [RAGRemoteContextBlock] {
        onProgress(.init(completed: workItems.count, total: workItems.count))
        return blocks
    }
}

private struct FixedWebSearchProvider: RAGWebSearchProviding {
    func fetch(
        requests: [RAGWebSearchRequest],
        onProgress: @escaping @Sendable (RAGRemoteContextFetchProgress) -> Void
    ) async -> [RAGRemoteContextBlock] {
        requests.enumerated().map { index, request in
            onProgress(.init(completed: index + 1, total: requests.count))
            let now = Date()
            return RAGRemoteContextBlock(
                id: request.id,
                repoId: nil,
                resource: .externalWeb,
                title: "Tavily · Web Search",
                sourceURL: URL(string: "https://example.com/swift"),
                content: "Swift evolution proposal and release notes",
                fetchedAt: now,
                errorMessage: nil,
                resultCount: 1,
                startedAt: now,
                completedAt: now,
                providerName: "Tavily",
                querySummary: request.query,
                resultPreviews: [.init(
                    title: "Swift release notes",
                    url: URL(string: "https://example.com/swift")!,
                    providerName: "Tavily"
                )]
            )
        }
    }
}

private struct EmptyFixedWebSearchProvider: RAGWebSearchProviding {
    func fetch(
        requests: [RAGWebSearchRequest],
        onProgress: @escaping @Sendable (RAGRemoteContextFetchProgress) -> Void
    ) async -> [RAGRemoteContextBlock] {
        requests.enumerated().map { index, request in
            onProgress(.init(completed: index + 1, total: requests.count))
            let now = Date()
            return RAGRemoteContextBlock(
                id: request.id,
                repoId: nil,
                resource: .externalWeb,
                title: "Tavily · Web Search",
                sourceURL: nil,
                content: "",
                fetchedAt: now,
                errorMessage: nil,
                outcome: .empty,
                resultCount: 0,
                startedAt: now,
                completedAt: now,
                providerName: "Tavily",
                querySummary: request.query
            )
        }
    }
}

private actor RemoteFetchRecorder {
    private(set) var fetchCount = 0

    func record() {
        fetchCount += 1
    }
}

/// Debug 回调可能来自远程 Provider 的并发 TaskGroup。测试记录器用锁收集事件，确保断言
/// 检查的是完整的请求序列，而不是依赖某个调度时机。
private final class RAGDebugEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(RAGDebugEvent.Stage, String)] = []

    var stages: [RAGDebugEvent.Stage] { lock.withLock { values.map(\.0) } }
    var payloads: [String] { lock.withLock { values.map(\.1) } }

    func record(stage: RAGDebugEvent.Stage, payload: String) {
        lock.withLock { values.append((stage, payload)) }
    }
}

private final class RAGRemoteDebugEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(RAGDebugEvent.Stage, String)] = []

    var stages: [RAGDebugEvent.Stage] { lock.withLock { values.map(\.0) } }
    var payloads: [String] { lock.withLock { values.map(\.1) } }

    func record(_ event: RAGRemoteContextDebugEvent) {
        lock.withLock { values.append((event.stage, event.payload)) }
    }
}

private struct RecordingRemoteContextProvider: KnowledgeRAGRemoteContextProviding {
    let recorder: RemoteFetchRecorder

    func fetch(
        workItems: [RAGResolvedRemoteWorkItem],
        onProgress: @escaping @Sendable (RAGRemoteContextFetchProgress) -> Void
    ) async -> [RAGRemoteContextBlock] {
        await recorder.record()
        return []
    }
}

private func remoteWorkItems(
    request: RAGRemoteContextRequest,
    candidates: [RAGRepoCandidate]
) -> [RAGResolvedRemoteWorkItem] {
    candidates.enumerated().map { index, candidate in
        RAGResolvedRemoteWorkItem(
            id: "\(candidate.repo.id):\(request.resource.rawValue):\(index)",
            candidate: candidate,
            request: request
        )
    }
}

private actor RAGBoundedConcurrencyProbe {
    private var activeTasks = 0
    private var maximumConcurrentTasks = 0
    private var completionCounts: [Int] = []

    func performWork() async throws {
        activeTasks += 1
        maximumConcurrentTasks = max(maximumConcurrentTasks, activeTasks)
        defer { activeTasks -= 1 }
        try await Task.sleep(for: .milliseconds(20))
    }

    func recordCompletion(_ completed: Int) {
        completionCounts.append(completed)
    }

    func snapshot() -> (maximumConcurrentTasks: Int, completionCounts: [Int]) {
        (maximumConcurrentTasks, completionCounts)
    }
}

private final class SpyRAGAIClient: @unchecked Sendable, AIClientProtocol {
    private let lock = NSLock()
    private var calls = 0
    private var latestChatRequest: AIChatRequest?
    private let failEmbedding: Bool
    private let chatResponse: String?
    private let streamError: Error?
    var callCount: Int { lock.withLock { calls } }
    var lastChatRequest: AIChatRequest? { lock.withLock { latestChatRequest } }

    init(failEmbedding: Bool = false, chatResponse: String? = nil, streamError: Error? = nil) {
        self.failEmbedding = failEmbedding
        self.chatResponse = chatResponse
        self.streamError = streamError
    }

    func chat(request: AIChatRequest) async throws -> AIChatResponse {
        lock.withLock {
            calls += 1
            latestChatRequest = request
        }
        if let chatResponse {
            return AIChatResponse(content: chatResponse, model: request.model, finishReason: "stop")
        }
        throw AIClientError.emptyResponse
    }

    func chatStream(request: AIChatRequest) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        lock.withLock {
            calls += 1
            latestChatRequest = request
        }
        return AsyncThrowingStream { continuation in
            if let streamError {
                continuation.finish(throwing: streamError)
            } else if let chatResponse {
                continuation.yield(.completed(AIChatResponse(
                    content: chatResponse,
                    model: request.model,
                    finishReason: "stop"
                )))
                continuation.finish()
            } else {
                continuation.finish(throwing: AIClientError.emptyResponse)
            }
        }
    }

    func chat(systemPrompt: String, userPrompt: String, model: String?) async throws -> String {
        lock.withLock { calls += 1 }
        throw AIClientError.emptyResponse
    }

    func embedding(input: String, model: String?) async throws -> [Float] {
        lock.withLock { calls += 1 }
        if failEmbedding { throw StubRAGProviderError.unavailable }
        return [1, 0]
    }

    func embeddings(inputs: [String], model: String?) async throws -> [[Float]] {
        lock.withLock { calls += 1 }
        return inputs.map { _ in [1, 0] }
    }

    func listModels() async throws -> [AIModelDescriptor] {
        lock.withLock { calls += 1 }
        return []
    }

    func testConnection() async throws {
        lock.withLock { calls += 1 }
    }
}
