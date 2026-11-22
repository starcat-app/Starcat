//
//  RepoEmbedding.swift
//  Starcat
//
//  AI 语义搜索的 SQLite 向量缓存模型（详见 `docs/3-设计/详细设计/26-向量搜索改进.md`）。
//
//  模块职责：
//  - 把 repo 的语义向量持久化到 `repo_embeddings` 表。
//  - 以 Float32 BLOB 保存 embedding，避免引入 sqlite-vss / sqlite-vec 动态扩展。
//  - 把"上次进过向量"的结构化快照（IndexedSnapshot）存为压缩 JSON，让 diff 算法判定
//    是否需要重建向量，替代旧 v1 的 `content_hash` 全等比对。
//
//  关键约束：
//  - 主键是 `(repo_id, model)`；同一个 repo 可为不同 embedding model 保存不同向量。
//  - `snapshotPayload` 是 `IndexedSnapshot` 的压缩 BLOB：
//    - body：AI 摘要与 README 并存（摘要在前），都没有才用 description+topics
//    - notes：用户私有笔记（可空）
//    - metadata：fullName / description / language / topics / license / homepage 元数据元组
//  - BLOB 编/解码保持在本模型内，业务层只处理 `[Float]`，不接触二进制细节。
//
import Foundation
import GRDB

struct RepoEmbedding: Codable, FetchableRecord, MutablePersistableRecord, Equatable, Sendable {

    static let databaseTableName = "repo_embeddings"

    var repoId: Int64
    var model: String
    var dimensions: Int
    var embedding: Data

    /// 查询先保留压缩字节，需要内容比对时才解码，避免批量读取时常驻全部正文。
    var snapshotPayload: Data
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case repoId = "repo_id"
        case model
        case dimensions
        case embedding
        case snapshotPayload = "snapshot_payload"
        case updatedAt = "updated_at"
    }

    init(
        repoId: Int64,
        model: String,
        vector: [Float],
        snapshotPayload: Data,
        updatedAt: String
    ) {
        self.repoId = repoId
        self.model = model
        self.dimensions = vector.count
        self.embedding = Self.encode(vector)
        self.snapshotPayload = snapshotPayload
        self.updatedAt = updatedAt
    }

    var vector: [Float] {
        Self.decode(embedding)
    }

    /// Float32 数组直接按内存布局写入 BLOB。
    ///
    /// 为什么可以这样做：
    /// - Starcat 的向量缓存是本机 SQLite 私有数据，不跨 CPU 架构传输。
    /// - 相比 JSON 数组，BLOB 体积更小、读写更快,也避免 Double/Float 来回转换。
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
