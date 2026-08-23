//
//  CollectionAPILiveIntegrationTests.swift
//  StarcatTests
//
//  Starcat Swift DTO → 本机 starcat-collection-api 的显式 live E2E 入口。
//
//  默认测试运行不访问网络；只有显式提供 PUBLIC_KEY 构建设置时才执行真实上传。
//  固定 repo 1～4 与 trainer 的公开 metadata fixture 对齐；上传两个匿名主体是因为
//  SVD 基线至少需要 2 个主体，避免客户端上传成功但完整训练验收无法启动。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Collection API Live Integration")
struct CollectionAPILiveIntegrationTests {
    @Test("Swift 快照应通过本机 Collection 三阶段提交并满足训练最小样本")
    func uploadsSwiftSnapshotToLiveCollection() async throws {
        guard let publicKey = CollectionAPIConfiguration.apiKey else {
            // 常规单测必须完全离线；E2E 由使用说明中的显式构建设置开启。
            return
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        let client = CollectionAPIClient(
            baseURL: AppEndpoints.Collection.baseURL,
            apiKey: publicKey,
            session: URLSession(configuration: configuration)
        )

        try await upload(
            repositoryIDs: [1, 2, 3, 4],
            accountID: 42,
            using: client
        )
        try await upload(
            repositoryIDs: [1, 2, 4],
            accountID: 43,
            using: client
        )
    }

    private func upload(
        repositoryIDs: [Int64],
        accountID: Int64,
        using client: CollectionAPIClient
    ) async throws {
        let repositories = repositoryIDs.map { id in
            makeRepo(
                id: id,
                starredAt: id == 4 ? nil : "2025-0\(id)-01T00:00:00Z"
            )
        }
        let snapshot = try RecommendationSnapshotBuilder.build(
            repositories: repositories,
            participantID: UUID().uuidString.lowercased(),
            capturedAt: Date()
        )
        let task = DataContributionOutboxTask(
            id: snapshot.snapshotID,
            accountID: accountID,
            participantID: snapshot.participantID,
            schemaVersion: snapshot.schemaVersion,
            payload: try snapshot.encodedPayload(),
            contentHash: snapshot.contentHash,
            state: .pending,
            attemptCount: 0,
            nextAttemptAt: nil
        )

        try await client.upload(task: task)
    }

    private func makeRepo(id: Int64, starredAt: String?) -> Repo {
        var repo = Repo.makeMinimal(owner: "starcat-e2e", name: "repo-\(id)")
        repo.id = id
        repo.isStarred = true
        repo.isPrivate = false
        repo.starredAt = starredAt
        return repo
    }
}
