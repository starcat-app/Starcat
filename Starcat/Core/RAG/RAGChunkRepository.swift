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
    /// 移出知识库后 SQL boundary 已不再返回正文，但外部索引仍需 ID/source 删除旧文档。
    func fetchChunkIdentities(repoId: Int64) async throws -> [RAGDeletedChunkIdentity]
    func fetchChunks(repoId: Int64, parentKey: String, model: String) async throws -> [RAGChunk]
    func fetchChunks(parents: [RAGChunkParentKey], model: String) async throws -> [RAGChunk]
    /// 为最终仓库 bundle 批量读取系统 Metadata。Metadata 是 keyword_only，不得复用只查 ready 向量的 parent API。
    func fetchActiveMetadata(repoIDs: [Int64]) async throws -> [RAGChunk]
    /// 只统计知识库边界内待向量化分片，不读取正文或 embedding BLOB。
    func countChunksNeedingEmbedding() async throws -> Int
    func fetchChunksNeedingEmbedding(limit: Int) async throws -> [RAGChunk]
    func claimChunksForEmbedding(_ chunks: [RAGEmbeddingIdentity], claimID: String) async throws -> [RAGChunk]
    /// 检查当前检索是否至少有一个可用 source；包含当前模型向量和 FTS-only Metadata。
    func hasReadyChunks(model: String, repoIDs: [Int64]) async throws -> Bool
    /// 只读取向量扫描所需的列；调用方必须按页消费，避免大知识库把正文和全部向量同时留在内存。
    func fetchReadyEmbeddings(model: String, repoIDs: [Int64], afterID: Int64?, limit: Int) async throws -> [RAGChunkEmbedding]
    func fetchReadyChunks(ids: [Int64], model: String) async throws -> [RAGChunk]
    func fetchReadyChunks(model: String, repoIDs: [Int64]) async throws -> [RAGChunk]
    /// 关键词后端可同步当前模型的向量分片与本地 FTS-only Metadata；向量后端只能使用 ready 分片。
    func fetchKeywordSearchableChunks(model: String, repoIDs: [Int64]) async throws -> [RAGChunk]
    func keywordSearch(query: String, model: String, repoIDs: [Int64], limit: Int) async throws -> [RAGKeywordHit]
    func markReady(_ embeddings: [RAGEmbeddingWrite], model: String, claimID: String) async throws
    func markFailed(_ chunks: [RAGEmbeddingIdentity], claimID: String, error: String) async throws
    func markStaleForOtherModels(currentModel: String) async throws
    func coverage(model: String) async throws -> RAGIndexStatusProjection
    /// 仅持久化整轮成功的全库刷新摘要；不能与单仓库自动补建共用。
    func fetchLastIndexRefreshSummary() async throws -> RAGIndexRefreshSummary?
    func saveLastIndexRefreshSummary(_ summary: RAGIndexRefreshSummary) async throws
    func knowledgeRepositoryIndexes(model: String) async throws -> [RAGKnowledgeRepositoryIndex]
    func fetchIndexIssueChunks(kind: RAGIndexIssueKind, model: String, limit: Int, offset: Int) async throws -> RAGIndexIssueChunkPage
    func fetchKnowledgeChunks(repoId: Int64) async throws -> [RAGChunk]
    func fetchManagedKnowledgeChunks(repoId: Int64, limit: Int, offset: Int) async throws -> RAGManagedChunkPage
    func saveKnowledgeChunkOverride(id: Int64, title: String, sectionPath: String, content: String) async throws
    func setKnowledgeChunkExcluded(id: Int64, isExcluded: Bool) async throws
    func permanentlyDeleteKnowledgeChunk(id: Int64) async throws
    func restoreKnowledgeChunk(id: Int64) async throws
    func totalBytes() async throws -> Int64
    func deleteAll() async throws
}

enum RAGChunkMutationError: LocalizedError, Equatable {
    case metadataIsSystemManaged

    var errorDescription: String? {
        switch self {
        case .metadataIsSystemManaged:
            return String.l10n("rag.browser.chunk.metadataManaged")
        }
    }
}

/// SQLite BLOB 向量扫描的轻量行。正文和 citation 元数据只在最终 Top-K 确定后才回填，
/// 否则 1 万个分片会因无关正文造成不必要的峰值内存。
struct RAGChunkEmbedding: Sendable {
    var chunkID: Int64
    var repoID: Int64
    var vector: [Float]
}

/// Embedding 请求开始前记录的稳定身份。chunk id 会被 source diff 复用，所以写回必须同时校验 hash。
struct RAGEmbeddingIdentity: Hashable, Sendable {
    var chunkID: Int64
    var contentHash: String
}

/// 已完成的向量与请求开始时的正文身份绑定，Repository 负责校验 claim 后再写入。
struct RAGEmbeddingWrite: Sendable {
    var identity: RAGEmbeddingIdentity
    var vector: [Float]
}

/// 知识库浏览器的仓库级索引统计。状态按当前 embedding 模型计算，避免旧模型的 ready
/// 向量被误显示为可用。
struct RAGKnowledgeRepositoryIndex: Identifiable, Equatable, Sendable {
    var id: Int64 { repoID }
    var repoID: Int64
    var totalChunks: Int
    var readyChunks: Int
    var pendingChunks: Int
    var failedChunks: Int
    var staleChunks: Int
}

/// 浏览器使用的分片视图：原始分片仍用于检索，管理状态由覆盖层单独承载。
struct RAGManagedChunk: Identifiable, Equatable, Sendable {
    var chunk: RAGChunk
    var isExcluded: Bool
    var hasOverride: Bool
    var id: Int64 { chunk.id ?? -1 }

    /// Metadata 是维持仓库上下文完整性的系统分片，只允许查看和编辑，不允许下架或永久删除。
    var allowsRemoval: Bool { chunk.source != .metadata }
}

/// 管理器按页读取分片，避免仅为了显示少量预览就在内存中加载整个仓库。
struct RAGManagedChunkPage: Equatable, Sendable {
    var chunks: [RAGManagedChunk]
    var hasMore: Bool
}

/// Retriever 批量扩展命中章节时使用的稳定 parent 身份。
///
/// 同一个 `parentKey` 只在仓库内唯一，因此必须同时带上 repo ID；这让一次 SQL 查询可以安全
/// 取回多个仓库的 siblings，又不会把不同仓库的 README 章节混在一起。
struct RAGChunkParentKey: Hashable, Sendable {
    var repoID: Int64
    var parentKey: String
}

/// 索引面板可展开查看的非 ready 分片分类。过期同时覆盖显式 stale 与旧 embedding 模型。
enum RAGIndexIssueKind: Hashable, Sendable {
    case pending
    case failed
    case stale
}

/// 按状态分页读取异常分片，避免 Inspector 展开时一次性加载整个知识库。
struct RAGIndexIssueChunkPage: Equatable, Sendable {
    var chunks: [RAGChunk]
    var hasMore: Bool
}

struct GRDBRAGChunkRepository: RAGChunkRepositoryProtocol {
    /// SQLite 的变量上限会随构建选项变化；保留余量给 model、offset、limit 等固定参数。
    private static let maxIDsPerQuery = 900
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
            let tombstoneRows = try Row.fetchAll(
                db,
                sql: "SELECT source_id, chunk_key FROM rag_chunk_tombstones WHERE repo_id = ? AND source = ?",
                arguments: [repoId, source.rawValue]
            )
            let tombstonedIdentities = Set(tombstoneRows.map { row in
                Self.identity(sourceId: row["source_id"], chunkKey: row["chunk_key"])
            })
            let existing = try RAGChunk.fetchAll(
                db,
                sql: "SELECT * FROM rag_chunks WHERE repo_id = ? AND source = ?",
                arguments: [repoId, source.rawValue]
            )
            let existingByIdentity = Dictionary(uniqueKeysWithValues: existing.map {
                (Self.identity(sourceId: $0.sourceId, chunkKey: $0.chunkKey), $0)
            })
            let incomingIdentities = Set(drafts.map { Self.identity(sourceId: $0.sourceId, chunkKey: $0.chunkKey) })
                .subtracting(tombstonedIdentities)
            let now = ISO8601DateFormatter.shared.string(from: Date())

            var inserted = 0
            var changed = 0
            var reused = 0
            var pendingIDs: [Int64] = []
            var affectedIDs: [Int64] = []

            for draft in drafts {
                let identity = Self.identity(sourceId: draft.sourceId, chunkKey: draft.chunkKey)
                // 已永久删除的稳定 source identity 不会被 README / metadata 重建重新写回。
                guard !tombstonedIdentities.contains(identity) else { continue }
                if var row = existingByIdentity[identity] {
                    guard let rowID = row.id else { continue }
                    let override = try Row.fetchOne(db, sql: "SELECT * FROM rag_chunk_overrides WHERE chunk_id = ?", arguments: [rowID])
                    // 源刷新要更新“原始内容”快照，但实际索引内容继续尊重用户覆盖。
                    if override != nil {
                        try db.execute(sql: """
                            UPDATE rag_chunk_overrides
                            SET original_title = ?, original_section_path = ?, original_content = ?, updated_at = ?
                            WHERE chunk_id = ?
                            """, arguments: [draft.title, draft.sectionPath, draft.content, now, rowID])
                    }
                    let overrideTitle: String? = override?["override_title"]
                    let overridePath: String? = override?["override_section_path"]
                    let overrideContent: String? = override?["override_content"]
                    let effectiveTitle = overrideTitle ?? draft.title
                    let effectivePath = overridePath ?? draft.sectionPath
                    let effectiveContent = overrideContent ?? draft.content
                    let contentChanged = row.contentHash != draft.contentHash
                    row.parentType = draft.parentType
                    row.parentKey = draft.parentKey
                    row.parentTitle = draft.parentTitle
                    row.chunkIndex = draft.chunkIndex
                    row.sectionPath = effectivePath
                    row.title = effectiveTitle
                    row.content = effectiveContent
                    row.contentHash = RAGChunk.hash(effectiveContent)
                    row.tokenCount = overrideContent == nil ? draft.tokenCount : max(1, effectiveContent.count / 4)
                    row.isTruncated = draft.isTruncated
                    row.updatedAt = now
                    if source == .metadata {
                        // Metadata 是精确事实索引；即使旧版本遗留了向量，也必须在此清掉，
                        // 这样动态 GitHub 字段变化不会重新进入 embedding 队列。
                        row.embeddingModel = nil
                        row.embeddingDim = nil
                        row.embedding = nil
                        row.embeddingStatus = .keywordOnly
                        row.embeddingError = nil
                        row.embeddingClaimID = nil
                        row.indexedAt = nil
                        if contentChanged && overrideContent == nil {
                            changed += 1
                        } else {
                            reused += 1
                        }
                    } else if contentChanged && overrideContent == nil {
                        row.embeddingModel = nil
                        row.embeddingDim = nil
                        row.embedding = nil
                        row.embeddingStatus = .pending
                        row.embeddingError = nil
                        row.embeddingClaimID = nil
                        row.indexedAt = nil
                        changed += 1
                    } else {
                        reused += 1
                    }
                    try row.update(db)
                    affectedIDs.append(rowID)
                    if row.embeddingStatus == .pending || row.embeddingStatus == .failed || row.embeddingStatus == .stale,
                       let id = row.id {
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
                        embeddingStatus: source == .metadata ? .keywordOnly : .pending,
                        embeddingError: nil,
                        indexedAt: nil,
                        createdAt: now,
                        updatedAt: now
                    )
                    try row.insert(db)
                    if let id = row.id {
                        affectedIDs.append(id)
                        if source != .metadata { pendingIDs.append(id) }
                    }
                    inserted += 1
                }
            }

            let staleChunks = existing.compactMap { row -> RAGDeletedChunkIdentity? in
                let identity = Self.identity(sourceId: row.sourceId, chunkKey: row.chunkKey)
                guard !incomingIdentities.contains(identity), let id = row.id else { return nil }
                return RAGDeletedChunkIdentity(id: id, source: row.source)
            }
            let staleIDs = staleChunks.map(\.id)
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
                pendingChunkIDs: pendingIDs,
                affectedChunkIDs: affectedIDs,
                deletedChunks: staleChunks
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

    func fetchChunkIdentities(repoId: Int64) async throws -> [RAGDeletedChunkIdentity] {
        try await database.writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, source FROM rag_chunks WHERE repo_id = ? ORDER BY id",
                arguments: [repoId]
            )
            return rows.compactMap { row in
                guard let id: Int64 = row["id"],
                      let raw: String = row["source"],
                      let source = RAGChunkSource(rawValue: raw) else { return nil }
                return RAGDeletedChunkIdentity(id: id, source: source)
            }
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
                  AND NOT EXISTS (SELECT 1 FROM rag_chunk_overrides o WHERE o.chunk_id = c.id AND o.is_excluded = 1)
                ORDER BY c.chunk_index
                """, arguments: [repoId, parentKey, model])
        }
    }

    func fetchChunks(parents: [RAGChunkParentKey], model: String) async throws -> [RAGChunk] {
        guard !parents.isEmpty else { return [] }
        return try await database.writer.read { db in
            // 不能只按 parent_key 批量读取：README 常用的 section key 会在不同 repo 重复。
            // 每个 parent 使用一对绑定参数，保持与单 parent 查询完全相同的范围约束。
            var arguments: [any DatabaseValueConvertible] = [model]
            let parentConditions = parents.map { parent -> String in
                arguments.append(parent.repoID)
                arguments.append(parent.parentKey)
                return "(c.repo_id = ? AND c.parent_key = ?)"
            }.joined(separator: " OR ")
            return try RAGChunk.fetchAll(db, sql: """
                SELECT c.*
                FROM rag_chunks c
                JOIN repo_notes n ON n.repo_id = c.repo_id AND n.library_state = 'in_library'
                WHERE c.embedding_status = 'ready' AND c.embedding_model = ?
                  AND (\(parentConditions))
                  AND NOT EXISTS (SELECT 1 FROM rag_chunk_overrides o WHERE o.chunk_id = c.id AND o.is_excluded = 1)
                ORDER BY c.repo_id, c.parent_key, c.chunk_index
                """, arguments: StatementArguments(arguments))
        }
    }

    func fetchActiveMetadata(repoIDs: [Int64]) async throws -> [RAGChunk] {
        guard !repoIDs.isEmpty else { return [] }
        return try await database.writer.read { db in
            var result: [RAGChunk] = []
            for batch in Self.idBatches(repoIDs) {
                let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
                result += try RAGChunk.fetchAll(db, sql: """
                    SELECT c.*
                    FROM rag_chunks c
                    JOIN repo_notes n ON n.repo_id = c.repo_id AND n.library_state = 'in_library'
                    WHERE c.repo_id IN (\(placeholders))
                      AND c.source = 'metadata'
                      AND c.chunk_key = 'metadata:0'
                      AND c.embedding_status = 'keyword_only'
                      AND NOT EXISTS (
                          SELECT 1 FROM rag_chunk_overrides o
                          WHERE o.chunk_id = c.id AND o.is_excluded = 1
                      )
                    ORDER BY c.repo_id
                    """, arguments: StatementArguments(batch))
            }
            return result
        }
    }

    func countChunksNeedingEmbedding() async throws -> Int {
        try await database.writer.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*)
                FROM rag_chunks c
                JOIN repo_notes n ON n.repo_id = c.repo_id AND n.library_state = 'in_library'
                WHERE c.embedding_status IN ('pending', 'failed', 'stale')
                  AND NOT EXISTS (SELECT 1 FROM rag_chunk_overrides o WHERE o.chunk_id = c.id AND o.is_excluded = 1)
                """) ?? 0
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
                  AND NOT EXISTS (SELECT 1 FROM rag_chunk_overrides o WHERE o.chunk_id = c.id AND o.is_excluded = 1)
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

    func claimChunksForEmbedding(_ chunks: [RAGEmbeddingIdentity], claimID: String) async throws -> [RAGChunk] {
        guard !chunks.isEmpty, !claimID.isEmpty else { return [] }
        return try await database.writer.write { db in
            var claimed: [RAGChunk] = []
            claimed.reserveCapacity(chunks.count)
            for chunk in chunks {
                // SQLite writer 事务保证领取与回读不可交错。后来的同 chunk claim 可以接管所有权，
                // 先返回的旧请求会因 claim 不匹配而被安全丢弃。
                try db.execute(sql: """
                    UPDATE rag_chunks
                    SET embedding_status = 'pending', embedding_error = NULL, embedding_claim_id = ?
                    WHERE id = ? AND content_hash = ?
                      AND embedding_status IN ('pending', 'failed', 'stale')
                    """, arguments: [claimID, chunk.chunkID, chunk.contentHash])
                guard db.changesCount == 1,
                      let row = try RAGChunk.fetchOne(db, key: chunk.chunkID) else { continue }
                claimed.append(row)
            }
            return claimed
        }
    }

    func hasReadyChunks(model: String, repoIDs: [Int64]) async throws -> Bool {
        guard !repoIDs.isEmpty else { return false }
        for repoIDBatch in Self.idBatches(repoIDs) {
            let found = try await database.writer.read { db in
                let placeholders = Array(repeating: "?", count: repoIDBatch.count).joined(separator: ",")
                var arguments: [any DatabaseValueConvertible] = [model]
                arguments.append(contentsOf: repoIDBatch)
                return try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(
                        SELECT 1
                        FROM rag_chunks c
                        JOIN repo_notes n ON n.repo_id = c.repo_id AND n.library_state = 'in_library'
                        WHERE (
                            (c.embedding_status = 'ready' AND c.embedding_model = ?)
                            OR c.embedding_status = 'keyword_only'
                          )
                          AND c.repo_id IN (\(placeholders))
                          AND NOT EXISTS (SELECT 1 FROM rag_chunk_overrides o WHERE o.chunk_id = c.id AND o.is_excluded = 1)
                    )
                    """, arguments: StatementArguments(arguments)) ?? false
            }
            if found { return true }
        }
        return false
    }

    func fetchReadyEmbeddings(
        model: String,
        repoIDs: [Int64],
        afterID: Int64?,
        limit: Int
    ) async throws -> [RAGChunkEmbedding] {
        guard !repoIDs.isEmpty, limit > 0 else { return [] }
        // 调用方会逐个 repo ID batch 传入；这里不再做额外拆分，确保 keyset pagination
        // 的 `afterID` 在同一个稳定范围内连续推进。
        return try await database.writer.read { db in
            let placeholders = Array(repeating: "?", count: repoIDs.count).joined(separator: ",")
            var arguments: [any DatabaseValueConvertible] = [model]
            arguments.append(contentsOf: repoIDs)
            arguments.append(afterID ?? 0)
            arguments.append(limit)
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.id, c.repo_id, c.embedding
                FROM rag_chunks c
                JOIN repo_notes n ON n.repo_id = c.repo_id AND n.library_state = 'in_library'
                WHERE c.embedding_status = 'ready'
                  AND c.embedding_model = ?
                  AND c.repo_id IN (\(placeholders))
                  AND c.id > ?
                  AND NOT EXISTS (SELECT 1 FROM rag_chunk_overrides o WHERE o.chunk_id = c.id AND o.is_excluded = 1)
                ORDER BY c.id
                LIMIT ?
                """, arguments: StatementArguments(arguments))
            return rows.compactMap { row in
                let vector = RepoEmbedding.decode(row["embedding"] as Data? ?? Data())
                guard !vector.isEmpty else { return nil }
                return RAGChunkEmbedding(chunkID: row["id"], repoID: row["repo_id"], vector: vector)
            }
        }
    }

    func fetchReadyChunks(ids: [Int64], model: String) async throws -> [RAGChunk] {
        guard !ids.isEmpty else { return [] }
        var chunks: [RAGChunk] = []
        for idBatch in Self.idBatches(ids) {
            let batch = try await database.writer.read { db in
                let placeholders = Array(repeating: "?", count: idBatch.count).joined(separator: ",")
                var arguments: [any DatabaseValueConvertible] = [model]
                arguments.append(contentsOf: idBatch)
                return try RAGChunk.fetchAll(db, sql: """
                    SELECT c.*
                    FROM rag_chunks c
                    JOIN repo_notes n ON n.repo_id = c.repo_id AND n.library_state = 'in_library'
                    WHERE c.embedding_status = 'ready'
                      AND c.embedding_model = ?
                      AND c.id IN (\(placeholders))
                      AND NOT EXISTS (SELECT 1 FROM rag_chunk_overrides o WHERE o.chunk_id = c.id AND o.is_excluded = 1)
                    """, arguments: StatementArguments(arguments))
            }
            chunks.append(contentsOf: batch)
        }
        return chunks
    }

    func fetchReadyChunks(model: String, repoIDs: [Int64]) async throws -> [RAGChunk] {
        guard !repoIDs.isEmpty else { return [] }
        var chunks: [RAGChunk] = []
        for repoIDBatch in Self.idBatches(repoIDs) {
            let batch = try await database.writer.read { db in
                let placeholders = Array(repeating: "?", count: repoIDBatch.count).joined(separator: ",")
                var arguments: [any DatabaseValueConvertible] = [model]
                arguments.append(contentsOf: repoIDBatch)
                return try RAGChunk.fetchAll(db, sql: """
                    SELECT c.*
                    FROM rag_chunks c
                    JOIN repo_notes n ON n.repo_id = c.repo_id AND n.library_state = 'in_library'
                    WHERE c.embedding_status = 'ready'
                      AND c.embedding_model = ?
                      AND c.repo_id IN (\(placeholders))
                      AND NOT EXISTS (SELECT 1 FROM rag_chunk_overrides o WHERE o.chunk_id = c.id AND o.is_excluded = 1)
                    ORDER BY c.repo_id, c.source, c.chunk_index
                    """, arguments: StatementArguments(arguments))
            }
            chunks.append(contentsOf: batch)
        }
        return chunks
    }

    func fetchKeywordSearchableChunks(model: String, repoIDs: [Int64]) async throws -> [RAGChunk] {
        guard !repoIDs.isEmpty else { return [] }
        var chunks: [RAGChunk] = []
        for repoIDBatch in Self.idBatches(repoIDs) {
            let batch = try await database.writer.read { db in
                let placeholders = Array(repeating: "?", count: repoIDBatch.count).joined(separator: ",")
                var arguments: [any DatabaseValueConvertible] = [model]
                arguments.append(contentsOf: repoIDBatch)
                return try RAGChunk.fetchAll(db, sql: """
                    SELECT c.*
                    FROM rag_chunks c
                    JOIN repo_notes n ON n.repo_id = c.repo_id AND n.library_state = 'in_library'
                    WHERE (
                        (c.embedding_status = 'ready' AND c.embedding_model = ?)
                        OR c.embedding_status = 'keyword_only'
                      )
                      AND c.repo_id IN (\(placeholders))
                      AND NOT EXISTS (SELECT 1 FROM rag_chunk_overrides o WHERE o.chunk_id = c.id AND o.is_excluded = 1)
                    ORDER BY c.repo_id, c.source, c.chunk_index
                    """, arguments: StatementArguments(arguments))
            }
            chunks.append(contentsOf: batch)
        }
        return chunks
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
                  AND (
                    (c.embedding_status = 'ready' AND c.embedding_model = ?)
                    OR c.embedding_status = 'keyword_only'
                  )
                  AND c.repo_id IN (\(placeholders))
                  AND NOT EXISTS (SELECT 1 FROM rag_chunk_overrides o WHERE o.chunk_id = c.id AND o.is_excluded = 1)
                ORDER BY keyword_rank ASC
                LIMIT ?
                """, arguments: StatementArguments(arguments))
            return try rows.map { row in
                RAGKeywordHit(chunk: try RAGChunk(row: row), rank: row["keyword_rank"])
            }
        }
    }

    func markReady(_ embeddings: [RAGEmbeddingWrite], model: String, claimID: String) async throws {
        guard !embeddings.isEmpty else { return }
        try await database.writer.write { db in
            let now = ISO8601DateFormatter.shared.string(from: Date())
            for update in embeddings where !update.vector.isEmpty {
                try db.execute(sql: """
                    UPDATE rag_chunks
                    SET embedding = ?, embedding_dim = ?, embedding_model = ?,
                        embedding_status = 'ready', embedding_error = NULL,
                        embedding_claim_id = NULL,
                        indexed_at = ?, updated_at = ?
                    WHERE id = ? AND content_hash = ?
                      AND embedding_status = 'pending' AND embedding_claim_id = ?
                    """, arguments: [
                        RepoEmbedding.encode(update.vector), update.vector.count, model, now, now,
                        update.identity.chunkID, update.identity.contentHash, claimID
                    ])
            }
        }
    }

    func markFailed(_ chunks: [RAGEmbeddingIdentity], claimID: String, error: String) async throws {
        guard !chunks.isEmpty else { return }
        try await database.writer.write { db in
            for chunk in chunks {
                try db.execute(sql: """
                    UPDATE rag_chunks
                    SET embedding_status = 'failed', embedding_error = ?, embedding_claim_id = NULL
                    WHERE id = ? AND content_hash = ?
                      AND embedding_status = 'pending' AND embedding_claim_id = ?
                    """, arguments: [String(error.prefix(500)), chunk.chunkID, chunk.contentHash, claimID])
            }
        }
    }

    func markStaleForOtherModels(currentModel: String) async throws {
        try await database.writer.write { db in
            try db.execute(sql: """
                UPDATE rag_chunks
                SET embedding_status = 'stale', embedding_claim_id = NULL
                WHERE embedding_status != 'keyword_only'
                  AND embedding_model IS NOT NULL AND embedding_model != ?
                """, arguments: [currentModel])
        }
    }

    func coverage(model: String) async throws -> RAGIndexStatusProjection {
        try await database.writer.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT
                    (SELECT COUNT(*) FROM repo_notes WHERE library_state = 'in_library') AS knowledge_repos,
                    COUNT(DISTINCT CASE WHEN (c.embedding_status = 'ready' AND c.embedding_model = ?) OR c.embedding_status = 'keyword_only' THEN c.repo_id END) AS indexed_repos,
                    COUNT(c.id) AS total_chunks,
                    SUM(CASE WHEN (c.embedding_status = 'ready' AND c.embedding_model = ?) OR c.embedding_status = 'keyword_only' THEN 1 ELSE 0 END) AS ready_chunks,
                    SUM(CASE WHEN c.embedding_status = 'pending' THEN 1 ELSE 0 END) AS pending_chunks,
                    SUM(CASE WHEN c.embedding_status = 'failed' THEN 1 ELSE 0 END) AS failed_chunks,
                    SUM(CASE WHEN c.embedding_status = 'stale' OR (c.embedding_model IS NOT NULL AND c.embedding_model != ?) THEN 1 ELSE 0 END) AS stale_chunks
                FROM repo_notes n
                LEFT JOIN rag_chunks c ON c.repo_id = n.repo_id
                    AND NOT EXISTS (
                        SELECT 1 FROM rag_chunk_overrides o
                        WHERE o.chunk_id = c.id AND o.is_excluded = 1
                    )
                WHERE n.library_state = 'in_library'
                """, arguments: [model, model, model])
            return RAGIndexStatusProjection(
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

    func fetchLastIndexRefreshSummary() async throws -> RAGIndexRefreshSummary? {
        try await database.writer.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM rag_index_refresh_summary WHERE id = 1"
            ) else {
                return nil
            }
            let completedAtRaw: String = row["completed_at"]
            guard let completedAt = ISO8601DateFormatter.shared.date(from: completedAtRaw) else {
                return nil
            }
            return RAGIndexRefreshSummary(
                totalRepos: row["total_repos"],
                readmesProcessed: row["readmes_processed"],
                sourceReposProcessed: row["source_repos_processed"],
                embeddingProcessed: row["embedding_processed"],
                embeddingTotal: row["embedding_total"],
                readyChunksBeforeEmbedding: row["ready_chunks_before_embedding"],
                totalChunksAtEmbedding: row["total_chunks_at_embedding"],
                completedAt: completedAt
            )
        }
    }

    func saveLastIndexRefreshSummary(_ summary: RAGIndexRefreshSummary) async throws {
        guard let completedAt = summary.completedAt else { return }
        let completedAtRaw = ISO8601DateFormatter.shared.string(from: completedAt)
        try await database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO rag_index_refresh_summary (
                    id, total_repos, readmes_processed, source_repos_processed,
                    embedding_processed, embedding_total, ready_chunks_before_embedding,
                    total_chunks_at_embedding, completed_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    total_repos = excluded.total_repos,
                    readmes_processed = excluded.readmes_processed,
                    source_repos_processed = excluded.source_repos_processed,
                    embedding_processed = excluded.embedding_processed,
                    embedding_total = excluded.embedding_total,
                    ready_chunks_before_embedding = excluded.ready_chunks_before_embedding,
                    total_chunks_at_embedding = excluded.total_chunks_at_embedding,
                    completed_at = excluded.completed_at
                """, arguments: [
                    1,
                    summary.totalRepos,
                    summary.readmesProcessed,
                    summary.sourceReposProcessed,
                    summary.embeddingProcessed,
                    summary.embeddingTotal,
                    summary.readyChunksBeforeEmbedding,
                    summary.totalChunksAtEmbedding,
                    completedAtRaw
                ])
        }
    }

    func knowledgeRepositoryIndexes(model: String) async throws -> [RAGKnowledgeRepositoryIndex] {
        try await database.writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    n.repo_id AS repo_id,
                    COUNT(c.id) AS total_chunks,
                    SUM(CASE WHEN (c.embedding_status = 'ready' AND c.embedding_model = ?) OR c.embedding_status = 'keyword_only' THEN 1 ELSE 0 END) AS ready_chunks,
                    SUM(CASE WHEN c.embedding_status = 'pending' THEN 1 ELSE 0 END) AS pending_chunks,
                    SUM(CASE WHEN c.embedding_status = 'failed' THEN 1 ELSE 0 END) AS failed_chunks,
                    SUM(CASE WHEN c.embedding_status = 'stale' OR (c.embedding_model IS NOT NULL AND c.embedding_model != ?) THEN 1 ELSE 0 END) AS stale_chunks
                FROM repo_notes n
                LEFT JOIN rag_chunks c ON c.repo_id = n.repo_id
                    AND NOT EXISTS (
                        SELECT 1 FROM rag_chunk_overrides o
                        WHERE o.chunk_id = c.id AND o.is_excluded = 1
                    )
                WHERE n.library_state = 'in_library'
                GROUP BY n.repo_id
                """, arguments: [model, model])
            return rows.map { row in
                RAGKnowledgeRepositoryIndex(
                    repoID: row["repo_id"],
                    totalChunks: row["total_chunks"],
                    readyChunks: row["ready_chunks"],
                    pendingChunks: row["pending_chunks"],
                    failedChunks: row["failed_chunks"],
                    staleChunks: row["stale_chunks"]
                )
            }
        }
    }

    func fetchIndexIssueChunks(
        kind: RAGIndexIssueKind,
        model: String,
        limit: Int,
        offset: Int
    ) async throws -> RAGIndexIssueChunkPage {
        precondition(limit > 0 && offset >= 0)
        let predicate: String
        switch kind {
        case .pending:
            predicate = "c.embedding_status = 'pending'"
        case .failed:
            predicate = "c.embedding_status = 'failed'"
        case .stale:
            predicate = "c.embedding_status = 'stale' OR (c.embedding_model IS NOT NULL AND c.embedding_model != ?)"
        }

        return try await database.writer.read { db in
            var values: [any DatabaseValueConvertible] = [limit + 1, offset]
            if kind == .stale {
                values.insert(model, at: 0)
            }
            // values 仅包含 String / Int，均可绑定；GRDB 的可失败初始化在此不会失败。
            let arguments = StatementArguments(values)!
            let chunks = try RAGChunk.fetchAll(db, sql: """
                SELECT c.*
                FROM rag_chunks c
                JOIN repo_notes n ON n.repo_id = c.repo_id AND n.library_state = 'in_library'
                WHERE (\(predicate))
                  AND NOT EXISTS (SELECT 1 FROM rag_chunk_overrides o WHERE o.chunk_id = c.id AND o.is_excluded = 1)
                ORDER BY c.updated_at DESC
                LIMIT ? OFFSET ?
                """, arguments: arguments)
            return RAGIndexIssueChunkPage(
                chunks: Array(chunks.prefix(limit)),
                hasMore: chunks.count > limit
            )
        }
    }

    func fetchKnowledgeChunks(repoId: Int64) async throws -> [RAGChunk] {
        try await database.writer.read { db in
            try RAGChunk.fetchAll(db, sql: """
                SELECT c.*
                FROM rag_chunks c
                JOIN repo_notes n ON n.repo_id = c.repo_id AND n.library_state = 'in_library'
                LEFT JOIN rag_chunk_overrides o ON o.chunk_id = c.id
                WHERE c.repo_id = ? AND COALESCE(o.is_excluded, 0) = 0
                ORDER BY c.source, c.parent_title, c.chunk_index
                """, arguments: [repoId])
        }
    }

    func fetchManagedKnowledgeChunks(repoId: Int64, limit: Int, offset: Int) async throws -> RAGManagedChunkPage {
        precondition(limit > 0 && offset >= 0)
        return try await database.writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.*, COALESCE(o.is_excluded, 0) AS browser_is_excluded,
                       CASE WHEN o.override_content IS NULL THEN 0 ELSE 1 END AS browser_has_override
                FROM rag_chunks c
                JOIN repo_notes n ON n.repo_id = c.repo_id AND n.library_state = 'in_library'
                LEFT JOIN rag_chunk_overrides o ON o.chunk_id = c.id
                LEFT JOIN rag_chunk_tombstones t ON t.repo_id = c.repo_id
                    AND t.source = c.source
                    AND t.source_id = c.source_id
                    AND t.chunk_key = c.chunk_key
                WHERE c.repo_id = ? AND t.repo_id IS NULL
                ORDER BY c.source, c.parent_title, c.chunk_index
                LIMIT ? OFFSET ?
                """, arguments: [repoId, limit + 1, offset])
            let chunks = try rows.map { row in
                RAGManagedChunk(
                    chunk: try RAGChunk(row: row),
                    isExcluded: row["browser_is_excluded"],
                    hasOverride: row["browser_has_override"]
                )
            }
            return RAGManagedChunkPage(
                chunks: Array(chunks.prefix(limit)),
                hasMore: chunks.count > limit
            )
        }
    }

    func saveKnowledgeChunkOverride(id: Int64, title: String, sectionPath: String, content: String) async throws {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanContent.isEmpty else { return }
        try await database.writer.write { db in
            try ensureOverrideBaseline(db, chunkID: id)
            let now = ISO8601DateFormatter.shared.string(from: Date())
            let tokenCount = max(1, cleanContent.count / 4)
            try db.execute(sql: """
                UPDATE rag_chunk_overrides
                SET override_title = ?, override_section_path = ?, override_content = ?, is_excluded = 0, updated_at = ?
                WHERE chunk_id = ?
                """, arguments: [cleanTitle, sectionPath, cleanContent, now, id])
            try db.execute(sql: """
                UPDATE rag_chunks
                SET title = ?, section_path = ?, content = ?, content_hash = ?, token_count = ?,
                    embedding_model = NULL, embedding_dim = NULL, embedding = NULL,
                    embedding_status = CASE WHEN source = 'metadata' THEN 'keyword_only' ELSE 'pending' END,
                    embedding_error = NULL, embedding_claim_id = NULL, indexed_at = NULL, updated_at = ?
                WHERE id = ?
                """, arguments: [cleanTitle, sectionPath, cleanContent, RAGChunk.hash(cleanContent), tokenCount, now, id])
        }
    }

    func setKnowledgeChunkExcluded(id: Int64, isExcluded: Bool) async throws {
        try await database.writer.write { db in
            if isExcluded,
               try RAGChunk.fetchOne(db, key: id)?.source == .metadata {
                throw RAGChunkMutationError.metadataIsSystemManaged
            }
            try ensureOverrideBaseline(db, chunkID: id)
            try db.execute(sql: "UPDATE rag_chunk_overrides SET is_excluded = ?, updated_at = ? WHERE chunk_id = ?", arguments: [isExcluded, ISO8601DateFormatter.shared.string(from: Date()), id])
        }
    }

    /// 第二次删除写入 tombstone 后再删除索引行，保留“不可恢复”的用户意图而不保留可召回数据。
    func permanentlyDeleteKnowledgeChunk(id: Int64) async throws {
        try await database.writer.write { db in
            guard let chunk = try RAGChunk.fetchOne(db, key: id) else { return }
            guard chunk.source != .metadata else {
                throw RAGChunkMutationError.metadataIsSystemManaged
            }
            try db.execute(
                sql: "DELETE FROM rag_chunk_tombstones WHERE repo_id = ? AND source = ? AND source_id = ? AND chunk_key = ?",
                arguments: [chunk.repoId, chunk.source.rawValue, chunk.sourceId, chunk.chunkKey]
            )
            try db.execute(
                sql: "INSERT INTO rag_chunk_tombstones (repo_id, source, source_id, chunk_key, removed_at) VALUES (?, ?, ?, ?, ?)",
                arguments: [chunk.repoId, chunk.source.rawValue, chunk.sourceId, chunk.chunkKey, ISO8601DateFormatter.shared.string(from: Date())]
            )
            try db.execute(sql: "DELETE FROM rag_chunks WHERE id = ?", arguments: [id])
        }
    }

    func restoreKnowledgeChunk(id: Int64) async throws {
        try await database.writer.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM rag_chunk_overrides WHERE chunk_id = ?", arguments: [id]) else { return }
            let originalTitle: String = row["original_title"]
            let originalPath: String = row["original_section_path"]
            let originalContent: String = row["original_content"]
            let hasOverride: Bool = (row["override_content"] as String?) != nil
            if hasOverride {
                let now = ISO8601DateFormatter.shared.string(from: Date())
                try db.execute(sql: """
                    UPDATE rag_chunks
                    SET title = ?, section_path = ?, content = ?, content_hash = ?, token_count = ?,
                        embedding_model = NULL, embedding_dim = NULL, embedding = NULL,
                        embedding_status = CASE WHEN source = 'metadata' THEN 'keyword_only' ELSE 'pending' END,
                        embedding_error = NULL, embedding_claim_id = NULL, indexed_at = NULL, updated_at = ?
                    WHERE id = ?
                    """, arguments: [originalTitle, originalPath, originalContent, RAGChunk.hash(originalContent), max(1, originalContent.count / 4), now, id])
            }
            try db.execute(sql: "DELETE FROM rag_chunk_overrides WHERE chunk_id = ?", arguments: [id])
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
            // 清空知识库后旧统计不再代表当前索引，避免下次打开 Inspector 显示过期的成功摘要。
            try db.execute(sql: "DELETE FROM rag_index_refresh_summary")
        }
    }

    private static func identity(sourceId: String, chunkKey: String) -> String {
        "\(sourceId)\u{1F}\(chunkKey)"
    }

    private static func idBatches(_ ids: [Int64]) -> [[Int64]] {
        stride(from: 0, to: ids.count, by: maxIDsPerQuery).map {
            Array(ids[$0..<min($0 + maxIDsPerQuery, ids.count)])
        }
    }

    private func ensureOverrideBaseline(_ db: Database, chunkID: Int64) throws {
        let now = ISO8601DateFormatter.shared.string(from: Date())
        try db.execute(sql: """
            INSERT INTO rag_chunk_overrides (chunk_id, original_title, original_section_path, original_content, is_excluded, updated_at)
            SELECT id, title, section_path, content, 0, ? FROM rag_chunks WHERE id = ?
            ON CONFLICT(chunk_id) DO NOTHING
            """, arguments: [now, chunkID])
    }
}
