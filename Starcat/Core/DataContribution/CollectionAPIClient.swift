//
//  CollectionAPIClient.swift
//  Starcat
//
//  starcat-collection-api 三阶段分块上传客户端。
//
//  本 actor 只负责协议和 HTTP 状态，不读取 UI 设置、不记录响应 body，也不决定重试。
//  静默重试由上层 DataContributionCoordinator 统一编排，保证网络失败不会进入正常同步状态。
//

import Foundation

protocol CollectionSnapshotUploading: Sendable {
    func upload(task: DataContributionOutboxTask) async throws
}

enum CollectionAPIError: Error, Equatable {
    case configurationMissing
    case invalidStoredPayload
    case invalidResponse
    case httpStatus(Int)
}

enum CollectionAPIConfiguration {
    /// 客户端只读取构建期注入的公开写入 key，不把 key放进 AppSettings 或 Keychain UI。
    static var apiKey: String? {
        guard let raw = Bundle.main.infoDictionary?["STARCAT_COLLECTION_API_KEY"] as? String else {
            return nil
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }
}

/// 同一 task 的 snapshot_id、payload 和块内容在所有重试中保持不变，从而利用服务端幂等键。
actor CollectionAPIClient: CollectionSnapshotUploading {
    static let maximumChunkSize = 1_000

    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession

    init(
        baseURL: URL = AppEndpoints.Collection.baseURL,
        apiKey: String = CollectionAPIConfiguration.apiKey ?? "",
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    func upload(task: DataContributionOutboxTask) async throws {
        guard !apiKey.isEmpty else { throw CollectionAPIError.configurationMissing }
        let snapshot: RecommendationSnapshot
        do {
            snapshot = try RecommendationSnapshotJSON.decoder.decode(
                RecommendationSnapshot.self,
                from: task.payload
            )
        } catch {
            throw CollectionAPIError.invalidStoredPayload
        }
        guard snapshot.snapshotID == task.id,
              snapshot.participantID == task.participantID,
              snapshot.schemaVersion == task.schemaVersion,
              snapshot.contentHash == task.contentHash else {
            throw CollectionAPIError.invalidStoredPayload
        }

        let chunks = Self.chunks(for: snapshot.repositories)
        try await send(
            method: "POST",
            path: "/api/v1/recommendation-snapshots",
            body: CreateSnapshotRequest(
                schemaVersion: snapshot.schemaVersion,
                snapshotID: snapshot.snapshotID,
                participantID: snapshot.participantID,
                capturedAt: snapshot.capturedAt,
                mode: snapshot.mode,
                contentHash: snapshot.contentHash,
                repositoryCount: snapshot.repositories.count,
                chunkCount: chunks.count
            )
        )

        for (index, repositories) in chunks.enumerated() {
            try Task.checkCancellation()
            try await send(
                method: "PUT",
                path: "/api/v1/recommendation-snapshots/\(snapshot.snapshotID)/chunks/\(index)",
                body: SnapshotChunkRequest(repositories: repositories)
            )
        }

        try await send(
            method: "POST",
            path: "/api/v1/recommendation-snapshots/\(snapshot.snapshotID)/commit",
            body: CommitSnapshotRequest(participantID: snapshot.participantID)
        )
    }

    /// 零仓库快照仍必须上传一个空块，和 Collection API 的 chunk_count 校验一致。
    private static func chunks(
        for repositories: [RecommendationSnapshotRepository]
    ) -> [[RecommendationSnapshotRepository]] {
        guard !repositories.isEmpty else { return [[]] }
        return stride(from: 0, to: repositories.count, by: maximumChunkSize).map { start in
            Array(repositories[start..<min(start + maximumChunkSize, repositories.count)])
        }
    }

    private func send<Body: Encodable>(method: String, path: String, body: Body) async throws {
        var request = URLRequest(url: AppEndpoints.appendPath(path, to: baseURL))
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try RecommendationSnapshotJSON.encoder.encode(body)

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CollectionAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            // 只把状态码交给重试策略，绝不把响应 body 带进日志或 UI。
            throw CollectionAPIError.httpStatus(http.statusCode)
        }
    }
}

private struct CreateSnapshotRequest: Encodable {
    let schemaVersion: Int
    let snapshotID: String
    let participantID: String
    let capturedAt: String
    let mode: String
    let contentHash: String
    let repositoryCount: Int
    let chunkCount: Int

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case snapshotID = "snapshot_id"
        case participantID = "participant_id"
        case capturedAt = "captured_at"
        case mode
        case contentHash = "content_hash"
        case repositoryCount = "repository_count"
        case chunkCount = "chunk_count"
    }
}

private struct SnapshotChunkRequest: Encodable {
    let repositories: [RecommendationSnapshotRepository]
}

private struct CommitSnapshotRequest: Encodable {
    let participantID: String

    enum CodingKeys: String, CodingKey {
        case participantID = "participant_id"
    }
}
