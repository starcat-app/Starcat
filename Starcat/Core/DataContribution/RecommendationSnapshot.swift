//
//  RecommendationSnapshot.swift
//  Starcat
//
//  公开 Star 数据贡献的完整快照与跨语言 canonical JSON。
//
//  关键约束：
//  - 私有仓必须在 DTO 构造前过滤，不能依赖服务端补救。
//  - repositories 按 repo_id 升序去重，保证 Swift / Go / Python hash 一致。
//  - starred_at 即使为空也必须显式编码为 null；省略字段会改变 canonical hash。
//  - content_hash 不参与自身 hash 计算。
//

import CryptoKit
import Foundation

/// 推荐训练只需要公开仓库 ID 与用户 Star 时间，不携带名称、标签或本地行为。
struct RecommendationSnapshotRepository: Codable, Equatable, Sendable {
    let repoID: Int64
    let starredAt: String?

    enum CodingKeys: String, CodingKey {
        case repoID = "repo_id"
        case starredAt = "starred_at"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(repoID, forKey: .repoID)
        if let starredAt {
            try container.encode(starredAt, forKey: .starredAt)
        } else {
            // Optional 的 synthesized Encodable 会省略 nil；协议要求固定写 null。
            try container.encodeNil(forKey: .starredAt)
        }
    }
}

/// Starcat 与 Collection API 之间可持久化、可幂等重试的完整业务快照。
struct RecommendationSnapshot: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let snapshotID: String
    let participantID: String
    let capturedAt: String
    let mode: String
    let contentHash: String
    let repositories: [RecommendationSnapshotRepository]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case snapshotID = "snapshot_id"
        case participantID = "participant_id"
        case capturedAt = "captured_at"
        case mode
        case contentHash = "content_hash"
        case repositories
    }

    /// 固定 JSON 选项是跨语言 fixture 的一部分，不能随调用方 encoder 偏好变化。
    func encodedPayload() throws -> Data {
        try RecommendationSnapshotJSON.encoder.encode(self)
    }
}

/// 纯函数式快照工厂，便于直接验证隐私过滤、排序与 hash，不依赖数据库或网络。
enum RecommendationSnapshotBuilder {
    static func build(
        repositories: [Repo],
        participantID: String,
        snapshotID: String = UUID().uuidString.lowercased(),
        capturedAt: Date
    ) throws -> RecommendationSnapshot {
        var seenRepoIDs: Set<Int64> = []
        let publicRepositories = repositories
            .filter { $0.isStarred && !$0.isPrivate }
            .sorted { $0.id < $1.id }
            .compactMap { repo -> RecommendationSnapshotRepository? in
                guard seenRepoIDs.insert(repo.id).inserted else { return nil }
                return RecommendationSnapshotRepository(
                    repoID: repo.id,
                    starredAt: RecommendationSnapshotJSON.normalizedDate(repo.starredAt)
                )
            }

        let canonical = RecommendationSnapshotCanonical(
            schemaVersion: 1,
            snapshotID: snapshotID,
            participantID: participantID,
            capturedAt: RecommendationSnapshotJSON.string(from: capturedAt),
            mode: "full",
            repositories: publicRepositories
        )
        let canonicalData = try RecommendationSnapshotJSON.encoder.encode(canonical)
        let digest = SHA256.hash(data: canonicalData)
        let contentHash = "sha256:" + digest.map { String(format: "%02x", $0) }.joined()

        return RecommendationSnapshot(
            schemaVersion: canonical.schemaVersion,
            snapshotID: canonical.snapshotID,
            participantID: canonical.participantID,
            capturedAt: canonical.capturedAt,
            mode: canonical.mode,
            contentHash: contentHash,
            repositories: canonical.repositories
        )
    }
}

/// Hash 输入刻意不含 content_hash，字段名称与服务端 canonical 契约保持一致。
private struct RecommendationSnapshotCanonical: Encodable {
    let schemaVersion: Int
    let snapshotID: String
    let participantID: String
    let capturedAt: String
    let mode: String
    let repositories: [RecommendationSnapshotRepository]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case snapshotID = "snapshot_id"
        case participantID = "participant_id"
        case capturedAt = "captured_at"
        case mode
        case repositories
    }
}

enum RecommendationSnapshotJSON {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static var decoder: JSONDecoder { JSONDecoder() }

    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func normalizedDate(_ value: String?) -> String? {
        guard let date = ISO8601DateFormatter.githubDate(from: value) else {
            return nil
        }
        return string(from: date)
    }
}
