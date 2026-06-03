//
//  RepoEmbedding.swift
//  Starcat
//
//  AI 语义搜索的 SQLite 向量缓存模型。
//
//  模块职责：
//  - 把 repo 的语义向量持久化到 `repo_embeddings` 表。
//  - 以 Float32 BLOB 保存 embedding，避免引入 sqlite-vss / sqlite-vec 动态扩展。
//
//  关键约束：
//  - 主键是 `(repo_id, model)`；同一个 repo 可为不同 embedding model 保存不同向量。
//  - `content_hash` 必须来自参与向量化的文本，repo 元数据变化后据此判断是否重建。
//  - BLOB 编/解码保持在本模型内，业务层只处理 `[Float]`，不接触二进制细节。
//

import Foundation
import GRDB

struct RepoEmbedding: Codable, FetchableRecord, MutablePersistableRecord, Equatable, Sendable {

    static let databaseTableName = "repo_embeddings"

    var repoId: Int64
    var model: String
    var contentHash: String
    var dimensions: Int
    var embedding: Data
    var indexedText: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case repoId = "repo_id"
        case model
        case contentHash = "content_hash"
        case dimensions
        case embedding
        case indexedText = "indexed_text"
        case updatedAt = "updated_at"
    }

    init(repoId: Int64, model: String, contentHash: String, vector: [Float], indexedText: String, updatedAt: String) {
        self.repoId = repoId
        self.model = model
        self.contentHash = contentHash
        self.dimensions = vector.count
        self.embedding = Self.encode(vector)
        self.indexedText = indexedText
        self.updatedAt = updatedAt
    }

    var vector: [Float] {
        Self.decode(embedding)
    }

    /// Float32 数组直接按内存布局写入 BLOB。
    ///
    /// 为什么可以这样做：
    /// - Starcat 的向量缓存是本机 SQLite 私有数据，不跨 CPU 架构传输。
    /// - 相比 JSON 数组，BLOB 体积更小、读写更快，也避免 Double/Float 来回转换。
    static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }

    /// 从 BLOB 还原 Float32 数组；损坏数据直接返回空数组，让调用方跳过该条向量。
    static func decode(_ data: Data) -> [Float] {
        guard data.count % MemoryLayout<Float>.stride == 0 else { return [] }
        return data.withUnsafeBytes { rawBuffer in
            let buffer = rawBuffer.bindMemory(to: Float.self)
            return Array(buffer)
        }
    }
}
