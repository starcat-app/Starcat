//
//  RepoEmbeddingRepository.swift
//  Starcat
//
//  AI 语义搜索向量缓存 Repository。
//
//  模块职责：
//  - 读写 `repo_embeddings` 表；
//  - 为语义搜索服务提供“哪些 repo 需要重新向量化”的判断；
//  - 批量 upsert embedding，保证索引更新是数据库事务内的原子操作。
//
//  关键约束：
//  - 本仓库只处理本地缓存，不直接调用 AI 服务。
//  - `content_hash` 由上层按 repo 文本生成；仓库只做精确比较。
//

import Foundation
import GRDB

protocol RepoEmbeddingRepositoryProtocol: Sendable {
    func fetchEmbeddings(model: String, repoIDs: [Int64]) async throws -> [RepoEmbedding]
    func fetchEmbeddingsByRepoID(model: String, repoIDs: [Int64]) async throws -> [Int64: RepoEmbedding]
    func upsert(_ embeddings: [RepoEmbedding]) async throws
}

struct GRDBRepoEmbeddingRepository: RepoEmbeddingRepositoryProtocol {

    private let writer: any DatabaseWriter

    init(database: any DatabaseManaging) {
        self.writer = database.writer
    }

    func fetchEmbeddings(model: String, repoIDs: [Int64]) async throws -> [RepoEmbedding] {
        guard !repoIDs.isEmpty else { return [] }
        return try await writer.read { db in
            let placeholders = Array(repeating: "?", count: repoIDs.count).joined(separator: ",")
            var args: [any DatabaseValueConvertible] = [model]
            args.append(contentsOf: repoIDs)
            return try RepoEmbedding.fetchAll(db, sql: """
                SELECT * FROM repo_embeddings
                WHERE model = ? AND repo_id IN (\(placeholders))
                """, arguments: StatementArguments(args))
        }
    }

    func fetchEmbeddingsByRepoID(model: String, repoIDs: [Int64]) async throws -> [Int64: RepoEmbedding] {
        let rows = try await fetchEmbeddings(model: model, repoIDs: repoIDs)
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.repoId, $0) })
    }

    func upsert(_ embeddings: [RepoEmbedding]) async throws {
        guard !embeddings.isEmpty else { return }
        try await writer.write { db in
            for var embedding in embeddings {
                try embedding.save(db)
            }
        }
    }
}
