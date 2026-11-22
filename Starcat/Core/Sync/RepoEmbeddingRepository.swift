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
//  - 是否需要重建向量的判定逻辑（diff / 阈值）放在 `SemanticSearchService` 中，
//    Repository 只负责按主键存取 `snapshot_payload` + 向量 BLOB。
//

import Foundation
import GRDB

protocol RepoEmbeddingRepositoryProtocol: Sendable {
    func fetchEmbeddings(model: String, repoIDs: [Int64]) async throws -> [RepoEmbedding]
    func fetchEmbeddingsByRepoID(model: String, repoIDs: [Int64]) async throws -> [Int64: RepoEmbedding]
    /// 当前模型在给定候选仓里已有向量的条数。Search Center 底栏覆盖率用，不拉 BLOB。
    func countEmbeddings(model: String, repoIDs: [Int64]) async throws -> Int
    func upsert(_ embeddings: [RepoEmbedding]) async throws
}

struct GRDBRepoEmbeddingRepository: RepoEmbeddingRepositoryProtocol {

    private let database: any DatabaseManaging

    init(database: any DatabaseManaging) {
        self.database = database
    }

    func fetchEmbeddings(model: String, repoIDs: [Int64]) async throws -> [RepoEmbedding] {
        guard !repoIDs.isEmpty else { return [] }
        return try await database.writer.read { db in
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

    func countEmbeddings(model: String, repoIDs: [Int64]) async throws -> Int {
        guard !repoIDs.isEmpty else { return 0 }
        // 分块避免 SQLite 变量上限；覆盖率只关心 COUNT，不必一次塞进全部 ID。
        var total = 0
        let chunkSize = 500
        var start = repoIDs.startIndex
        while start < repoIDs.endIndex {
            let end = repoIDs.index(start, offsetBy: chunkSize, limitedBy: repoIDs.endIndex) ?? repoIDs.endIndex
            let chunk = Array(repoIDs[start..<end])
            total += try await countEmbeddingsChunk(model: model, repoIDs: chunk)
            start = end
        }
        return total
    }

    func upsert(_ embeddings: [RepoEmbedding]) async throws {
        guard !embeddings.isEmpty else { return }
        try await database.writer.write { db in
            for var embedding in embeddings {
                try embedding.save(db)
            }
        }
    }

    private func countEmbeddingsChunk(model: String, repoIDs: [Int64]) async throws -> Int {
        try await database.writer.read { db in
            let placeholders = Array(repeating: "?", count: repoIDs.count).joined(separator: ",")
            var args: [any DatabaseValueConvertible] = [model]
            args.append(contentsOf: repoIDs)
            return try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM repo_embeddings
                WHERE model = ? AND repo_id IN (\(placeholders))
                """, arguments: StatementArguments(args)) ?? 0
        }
    }
}
