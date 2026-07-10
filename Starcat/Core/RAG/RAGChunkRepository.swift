//
//  RAGChunkRepository.swift
//  Starcat
//
//  知识库 RAG chunk 的数据库边界。
//
//  Repository 在一个事务内完成 source 级 diff：内容未变时复用原 embedding，内容变化时
//  清空旧向量并标记 pending，不再存在的稳定 key 才删除。所有召回查询都在 SQL 内 join
//  `repo_notes.library_state = in_library`，避免调用方遗漏知识库边界。
//

import Foundation
import GRDB

protocol RAGChunkRepositoryProtocol: Sendable {
    func replaceSource(repoId: Int64, source: RAGChunkSource, drafts: [RAGChunkDraft]) async throws -> RAGChunkSyncResult
    func fetchChunks(ids: [Int64]) async throws -> [RAGChunk]
    func fetchChunks(repoId: Int64, parentKey: String, model: String) async throws -> [RAGChunk]
    func fetchChunksNeedingEmbedding(limit: Int) async throws -> [RAGChunk]
    func fetchReadyChunks(model: String, repoIDs: [Int64]) async throws -> [RAGChunk]
    func keywordSearch(query: String, model: String, repoIDs: [Int64], limit: Int) async throws -> [RAGKeywordHit]
    func markReady(_ embeddings: [Int64: [Float]], model: String) async throws
    func markFailed(chunkIDs: [Int64], error: String) async throws
    func markStaleForOtherModels(currentModel: String) async throws
    func coverage(model: String) async throws -> RAGIndexCoverage
    func totalBytes() async throws -> Int64
    func deleteAll() async throws
}

struct GRDBRAGChunkRepository: RAGChunkRepositoryProtocol {
    private let database: any DatabaseManaging

    init(database: any DatabaseManaging) {
        self.database = database
    }

    func replaceSource(
        repoId: Int64,
        source: RAGChunkSource,
        drafts: [RAGChunkDraft]
    ) async throws -> RAGChunkSyncResult {
        precondition(drafts.allSatisfy { $0.repoId == repoId && $0.source == source })
        return try await database.writer.write { db in
            let existing = try RAGChunk.fetchAll(
                db,
                sql: "SELECT * FROM rag_chunks WHERE repo_id = ? AND source = ?",
                arguments: [repoId, source.rawValue]
            )
            let existingByIdentity = Dictionary(uniqueKeysWithValues: existing.map {
                (Self.identity(sourceId: $0.sourceId, chunkKey: $0.chunkKey), $0)
            })
            let incomingIdentities = Set(drafts.map { Self.identity(sourceId: $0.sourceId, chunkKey: $0.chunkKey) })
            let now = ISO8601DateFormatter.shared.string(from: Date())

            var inserted = 0
            var changed = 0
            var reused = 0
            var pendingIDs: [Int64] = []

            for draft in drafts {
                let identity = Self.identity(sourceId: draft.sourceId, chunkKey: draft.chunkKey)
                if var row = existingByIdentity[identity] {
                    let contentChanged = row.contentHash != draft.contentHash
                    row.parentType = draft.parentType
                    row.parentKey = draft.parentKey
                    row.parentTitle = draft.parentTitle
                    row.chunkIndex = draft.chunkIndex
                    row.sectionPath = draft.sectionPath
                    row.title = draft.title
                    row.content = draft.content
                    row.contentHash = draft.contentHash
                    row.tokenCount = draft.tokenCount
                    row.isTruncated = draft.isTruncated
                    row.updatedAt = now
                    if contentChanged {
                        row.embeddingModel = nil
                        row.embeddingDim = nil
                        row.embedding = nil
                        row.embeddingStatus = .pending
                        row.embeddingError = nil
                        row.indexedAt = nil
                        changed += 1
                    } else {
                        reused += 1
                    }
                    try row.update(db)
                    if row.embeddingStatus != .ready, let id = row.id {
                        pendingIDs.append(id)
                    }
                } else {
                    var row = RAGChunk(
                        id: nil,
                        repoId: draft.repoId,
                        source: draft.source,
                        sourceId: draft.sourceId,
                        parentType: draft.parentType,
                        parentKey: draft.parentKey,
                        parentTitle: draft.parentTitle,
                        chunkKey: draft.chunkKey,
                        chunkIndex: draft.chunkIndex,
                        sectionPath: draft.sectionPath,
                        title: draft.title,
                        content: draft.content,
                        contentHash: draft.contentHash,
                        tokenCount: draft.tokenCount,
                        isTruncated: draft.isTruncated,
                        embeddingModel: nil,
                        embeddingDim: nil,
                        embedding: nil,
                        embeddingStatus: .pending,
                        embeddingError: nil,
                        indexedAt: nil,
                        createdAt: now,
                        updatedAt: now
                    )
                    try row.insert(db)
                    if let id = row.id { pendingIDs.append(id) }
                    inserted += 1
                }
            }

            let staleIDs = existing.compactMap { row -> Int64? in
                let identity = Self.identity(sourceId: row.sourceId, chunkKey: row.chunkKey)
                return incomingIdentities.contains(identity) ? nil : row.id
            }
            if !staleIDs.isEmpty {
                let placeholders = Array(repeating: "?", count: staleIDs.count).joined(separator: ",")
                let arguments = staleIDs.map { $0 as DatabaseValueConvertible }
                try db.execute(
                    sql: "DELETE FROM rag_chunks WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(arguments)
                )
            }
            return RAGChunkSyncResult(
                inserted: inserted,
                changed: changed,
                reused: reused,
                deleted: staleIDs.count,
                pendingChunkIDs: pendingIDs
            )
        }
    }

    func fetchChunks(ids: [Int64]) async throws -> [RAGChunk] {
        guard !ids.isEmpty else { return [] }
        return try await database.writer.read { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let arguments = ids.map { $0 as DatabaseValueConvertible }
            return try RAGChunk.fetchAll(
                db,
                sql: "SELECT * FROM rag_chunks WHERE id IN (\(placeholders)) ORDER BY chunk_index",
                arguments: StatementArguments(arguments)
            )
        }
    }

    func fetchChunks(repoId: Int64, parentKey: String, model: String) async throws -> [RAGChunk] {
        try await database.writer.read { db in
            try RAGChunk.fetchAll(db, sql: """
                SELECT c.*
                FROM rag_chunks c
                JOIN repo_notes n ON n.repo_id = c.repo_id AND n.library_state = 'in_library'
                WHERE c.repo_id = ? AND c.parent_key = ?
                  AND c.embedding_status = 'ready' AND c.embedding_model = ?
                ORDER BY c.chunk_index
                """, arguments: [repoId, parentKey, model])
        }
    }

    func fetchChunksNeedingEmbedding(limit: Int) async throws -> [RAGChunk] {
        guard limit > 0 else { return [] }
        return try await database.writer.read { db in
            try RAGChunk.fetchAll(db, sql: """
                SELECT c.*
                FROM rag_chunks c
                JOIN repo_notes n ON n.repo_id = c.repo_id AND n.library_state = 'in_library'
                WHERE c.embedding_status IN ('pending', 'failed', 'stale')
                ORDER BY
                    CASE c.source
                        WHEN 'notes' THEN 0
                        WHEN 'summary' THEN 1
                        WHEN 'readme' THEN 2
                        ELSE 3
                    END,
                    c.updated_at ASC
                LIMIT ?
                """, arguments: [limit])
        }
    }

    func fetchReadyChunks(model: String, repoIDs: [Int64]) async throws -> [RAGChunk] {
        guard !repoIDs.isEmpty else { return [] }
        return try await database.writer.read { db in
            let placeholders = Array(repeating: "?", count: repoIDs.count).joined(separator: ",")
            var arguments: [any DatabaseValueConvertible] = [model]
            arguments.append(contentsOf: repoIDs)
            return try RAGChunk.fetchAll(db, sql: """
                SELECT c.*
                FROM rag_chunks c
                JOIN repo_notes n ON n.repo_id = c.repo_id AND n.library_state = 'in_library'
                WHERE c.embedding_status = 'ready'
                  AND c.embedding_model = ?
                  AND c.repo_id IN (\(placeholders))
                ORDER BY c.repo_id, c.source, c.chunk_index
                """, arguments: StatementArguments(arguments))
        }
    }

    func keywordSearch(query: String, model: String, repoIDs: [Int64], limit: Int) async throws -> [RAGKeywordHit] {
        let ftsQuery = FTSQuery.sanitize(query)
        guard !ftsQuery.isEmpty, !repoIDs.isEmpty, limit > 0 else { return [] }
        return try await database.writer.read { db in
            let placeholders = Array(repeating: "?", count: repoIDs.count).joined(separator: ",")
            var arguments: [any DatabaseValueConvertible] = [ftsQuery, model]
            arguments.append(contentsOf: repoIDs)
            arguments.append(limit)
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.*, bm25(rag_chunks_fts, 4.0, 2.0, 1.0) AS keyword_rank
                FROM rag_chunks_fts
                JOIN rag_chunks c ON c.id = rag_chunks_fts.rowid
                JOIN repo_notes n ON n.repo_id = c.repo_id AND n.library_state = 'in_library'
                WHERE rag_chunks_fts MATCH ?
                  AND c.embedding_status = 'ready'
                  AND c.embedding_model = ?
                  AND c.repo_id IN (\(placeholders))
                ORDER BY keyword_rank ASC
                LIMIT ?
                """, arguments: StatementArguments(arguments))
            return try rows.map { row in
                RAGKeywordHit(chunk: try RAGChunk(row: row), rank: row["keyword_rank"])
            }
        }
    }

    func markReady(_ embeddings: [Int64: [Float]], model: String) async throws {
        guard !embeddings.isEmpty else { return }
        try await database.writer.write { db in
            let now = ISO8601DateFormatter.shared.string(from: Date())
            for (id, vector) in embeddings where !vector.isEmpty {
                try db.execute(sql: """
                    UPDATE rag_chunks
                    SET embedding = ?, embedding_dim = ?, embedding_model = ?,
                        embedding_status = 'ready', embedding_error = NULL,
                        indexed_at = ?, updated_at = ?
                    WHERE id = ?
                    """, arguments: [RepoEmbedding.encode(vector), vector.count, model, now, now, id])
            }
        }
    }

    func markFailed(chunkIDs: [Int64], error: String) async throws {
        guard !chunkIDs.isEmpty else { return }
        try await database.writer.write { db in
            let placeholders = Array(repeating: "?", count: chunkIDs.count).joined(separator: ",")
            var arguments: [any DatabaseValueConvertible] = [String(error.prefix(500))]
            arguments.append(contentsOf: chunkIDs)
            try db.execute(sql: """
                UPDATE rag_chunks
                SET embedding_status = 'failed', embedding_error = ?
                WHERE id IN (\(placeholders))
                """, arguments: StatementArguments(arguments))
        }
    }

    func markStaleForOtherModels(currentModel: String) async throws {
        try await database.writer.write { db in
            try db.execute(sql: """
                UPDATE rag_chunks
                SET embedding_status = 'stale'
                WHERE embedding_model IS NOT NULL AND embedding_model != ?
                """, arguments: [currentModel])
        }
    }

    func coverage(model: String) async throws -> RAGIndexCoverage {
        try await database.writer.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT
                    (SELECT COUNT(*) FROM repo_notes WHERE library_state = 'in_library') AS knowledge_repos,
                    COUNT(DISTINCT CASE WHEN c.embedding_status = 'ready' AND c.embedding_model = ? THEN c.repo_id END) AS indexed_repos,
                    COUNT(c.id) AS total_chunks,
                    SUM(CASE WHEN c.embedding_status = 'ready' AND c.embedding_model = ? THEN 1 ELSE 0 END) AS ready_chunks,
                    SUM(CASE WHEN c.embedding_status = 'pending' THEN 1 ELSE 0 END) AS pending_chunks,
                    SUM(CASE WHEN c.embedding_status = 'failed' THEN 1 ELSE 0 END) AS failed_chunks,
                    SUM(CASE WHEN c.embedding_status = 'stale' OR (c.embedding_model IS NOT NULL AND c.embedding_model != ?) THEN 1 ELSE 0 END) AS stale_chunks
                FROM repo_notes n
                LEFT JOIN rag_chunks c ON c.repo_id = n.repo_id
                WHERE n.library_state = 'in_library'
                """, arguments: [model, model, model])
            return RAGIndexCoverage(
                knowledgeRepoCount: row?["knowledge_repos"] ?? 0,
                indexedRepoCount: row?["indexed_repos"] ?? 0,
                totalChunks: row?["total_chunks"] ?? 0,
                readyChunks: row?["ready_chunks"] ?? 0,
                pendingChunks: row?["pending_chunks"] ?? 0,
                failedChunks: row?["failed_chunks"] ?? 0,
                staleChunks: row?["stale_chunks"] ?? 0
            )
        }
    }

    func totalBytes() async throws -> Int64 {
        try await database.writer.read { db in
            try Int64.fetchOne(db, sql: """
                SELECT COALESCE(SUM(length(content) + COALESCE(length(embedding), 0)), 0)
                FROM rag_chunks
                """) ?? 0
        }
    }

    func deleteAll() async throws {
        try await database.writer.write { db in
            _ = try RAGChunk.deleteAll(db)
        }
    }

    private static func identity(sourceId: String, chunkKey: String) -> String {
        "\(sourceId)\u{1F}\(chunkKey)"
    }
}
