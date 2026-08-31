//
//  CollectionAPILiveIntegrationTests.swift
//  StarcatTests
//
//  Starcat Swift DTO → 本机 starcat-collection-api 的显式 live E2E 入口。
//
//  默认测试运行不访问网络；只有显式开启 Live Integration 并提供 PUBLIC_KEY 时才真实上传。
//  固定 repo 1～4 与 trainer 的公开 metadata fixture 对齐；上传两个匿名主体是为了
//  让 E2E 实际训练 SVD，而不是触发单主体冷启动下的显式 skipped 降级。
//

import Foundation
import Testing
@testable import Starcat

private let shouldRunCollectionIntegration =
    ProcessInfo.processInfo.environment["STARCAT_RUN_COLLECTION_INTEGRATION"] == "1"

@Suite(
    "Collection API Live Integration",
    .enabled(if: shouldRunCollectionIntegration)
)
struct CollectionAPILiveIntegrationTests {
    @Test("Swift 快照应通过本机 Collection 三阶段提交并满足训练最小样本")
    func uploadsSwiftSnapshotToLiveCollection() async throws {
        // 显式开启 E2E 后缺少 Key 应立即失败，避免把配置错误误报成跳过或通过。
        let publicKey = try #require(CollectionAPIConfiguration.apiKey)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        let client = CollectionAPIClient(
            baseURL: AppEndpoints.Collection.baseURL,
            apiKey: publicKey,
            session: URLSession(configuration: configuration)
        )

        try await upload(
            repositoryIDs: [1, 2, 3, 4],
            starredAtOverrides: [3: "2025-07-01T00:00:00Z"],
            accountID: 42,
            using: client
        )
        try await upload(
            // 与第一名主体的训练集合保持差异，保证 SVD 矩阵存在列方差；repo 3
            // 在这里属于训练窗口，可作为第一名主体未来验证目标的协同信号。
            repositoryIDs: [1, 3, 4],
            accountID: 43,
            using: client
        )
    }

    private func upload(
        repositoryIDs: [Int64],
        starredAtOverrides: [Int64: String] = [:],
        accountID: Int64,
        using client: CollectionAPIClient
    ) async throws {
        let repositories = repositoryIDs.map { id in
            makeRepo(
                id: id,
                starredAt: id == 4
                    ? nil
                    : starredAtOverrides[id] ?? "2025-0\(id)-01T00:00:00Z"
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
