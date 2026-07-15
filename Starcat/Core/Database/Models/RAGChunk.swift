//
//  RAGChunk.swift
//  Starcat
//
//  知识库 RAG 的 child chunk 持久化模型。
//
//  关键约束：
//  - repo 是检索聚合父对象，chunk 只承担精确召回、embedding、FTS 和 citation。
//  - `chunkKey` 在同一 repo/source 内稳定，README 中插入无关章节时不应让后续 chunk 全部换 ID。
//  - embedding 是可重建缓存；正文变化必须清空旧向量并回到 pending，不能把旧向量配给新正文。
//

import CryptoKit
import Foundation
import GRDB

enum RAGChunkSource: String, CaseIterable, Codable, Sendable {
    case readme
    case notes
    case summary
    case metadata
}

enum RAGChunkParentType: String, Codable, Sendable {
    case repo
    case readmeSection = "readme_section"
    case notes
    case summary
    case metadata
}

enum RAGEmbeddingStatus: String, CaseIterable, Codable, Sendable {
    case pending
    case ready
    case failed
    case stale
    /// Metadata 是精确事实索引：只进入 FTS，避免动态 GitHub 数据反复消耗 embedding 配额。
    case keywordOnly = "keyword_only"
}

struct RAGChunk: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable, Sendable {
    static let databaseTableName = "rag_chunks"

    var id: Int64?
    var repoId: Int64
    var source: RAGChunkSource
    var sourceId: String
    var parentType: RAGChunkParentType
    var parentKey: String
    var parentTitle: String
    var chunkKey: String
    var chunkIndex: Int
    var sectionPath: String
    var title: String
    var content: String
    var contentHash: String
    var tokenCount: Int
    var isTruncated: Bool
    var embeddingModel: String?
    var embeddingDim: Int?
    var embedding: Data?
    var embeddingStatus: RAGEmbeddingStatus
    var embeddingError: String?
    /// 当前 Embedding 网络请求的所有权。source 更新会清空它，旧请求因此无法写回新正文。
    var embeddingClaimID: String? = nil
    var indexedAt: String?
    var createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case repoId = "repo_id"
        case source
        case sourceId = "source_id"
        case parentType = "parent_type"
        case parentKey = "parent_key"
        case parentTitle = "parent_title"
        case chunkKey = "chunk_key"
        case chunkIndex = "chunk_index"
        case sectionPath = "section_path"
        case title
        case content
        case contentHash = "content_hash"
        case tokenCount = "token_count"
        case isTruncated = "is_truncated"
        case embeddingModel = "embedding_model"
        case embeddingDim = "embedding_dim"
        case embedding
        case embeddingStatus = "embedding_status"
        case embeddingError = "embedding_error"
        case embeddingClaimID = "embedding_claim_id"
        case indexedAt = "indexed_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    var vector: [Float] {
        guard let embedding else { return [] }
        return RepoEmbedding.decode(embedding)
    }

    mutating func setReadyEmbedding(_ vector: [Float], model: String, at timestamp: String) {
        embedding = RepoEmbedding.encode(vector)
        embeddingDim = vector.count
        embeddingModel = model
        embeddingStatus = .ready
        embeddingError = nil
        embeddingClaimID = nil
        indexedAt = timestamp
        updatedAt = timestamp
    }

    static func hash(_ content: String) -> String {
        let digest = SHA256.hash(data: Data(content.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Builder 输出的无数据库身份草稿。Repository 负责复用原 row id 与 embedding。
struct RAGChunkDraft: Equatable, Sendable {
    var repoId: Int64
    var source: RAGChunkSource
    var sourceId: String
    var parentType: RAGChunkParentType
    var parentKey: String
    var parentTitle: String
    var chunkKey: String
    var chunkIndex: Int
    var sectionPath: String
    var title: String
    var content: String
    var tokenCount: Int
    var isTruncated: Bool

    var contentHash: String { RAGChunk.hash(content) }
}

struct RAGChunkSyncResult: Equatable, Sendable {
    var inserted: Int
    var changed: Int
    var reused: Int
    var deleted: Int
    var pendingChunkIDs: [Int64]
    /// 本 source 同步后仍存在的 chunk；外部索引只需对这些 ID 重新评估 upsert。
    var affectedChunkIDs: [Int64]
    /// 删除后本地已无法再回读 source，因此在事务返回值中保留最小身份。
    var deletedChunks: [RAGDeletedChunkIdentity]

    static let empty = RAGChunkSyncResult(
        inserted: 0,
        changed: 0,
        reused: 0,
        deleted: 0,
        pendingChunkIDs: [],
        affectedChunkIDs: [],
        deletedChunks: []
    )
}

struct RAGDeletedChunkIdentity: Equatable, Hashable, Sendable {
    var id: Int64
    var source: RAGChunkSource
}

struct RAGIndexCoverage: Equatable, Sendable {
    var knowledgeRepoCount: Int
    var indexedRepoCount: Int
    var totalChunks: Int
    var readyChunks: Int
    var pendingChunks: Int
    var failedChunks: Int
    var staleChunks: Int

    var fraction: Double {
        guard totalChunks > 0 else { return 0 }
        return Double(readyChunks) / Double(totalChunks)
    }
}

struct RAGKeywordHit: Equatable, Sendable {
    var chunk: RAGChunk
    /// SQLite bm25 越小越相关；Provider 会统一转换成越大越好的分数。
    var rank: Double
}
