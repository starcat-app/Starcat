//
//  CollectionAPIClientTests.swift
//  StarcatTests
//
//  验证公开 Star 快照的 create → chunks → commit HTTP 契约。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Collection API Client", .serialized)
struct CollectionAPIClientTests {
    private let baseURL = URL(string: "https://collection.test.invalid")!

    @Test("1001 个仓库应按 create、两个 chunk、commit 顺序上传")
    func uploadsChunkedSnapshot() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: request.url?.path == "/api/v1/recommendation-snapshots" ? 202 : 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data("{\"data\":{}}".utf8))
        }
        let client = CollectionAPIClient(
            baseURL: baseURL,
            apiKey: "client-test-key",
            session: URLProtocolStub.ephemeralSession()
        )
        let task = try makeTask(repositoryCount: 1_001)

        try await client.upload(task: task)

        let requests = URLProtocolStub.receivedRequests
        #expect(requests.map(\.httpMethod) == ["POST", "PUT", "PUT", "POST"])
        #expect(requests.map { $0.url?.path } == [
            "/api/v1/recommendation-snapshots",
            "/api/v1/recommendation-snapshots/2d7f6691-8f4f-4f1f-9381-f0786f0fc994/chunks/0",
            "/api/v1/recommendation-snapshots/2d7f6691-8f4f-4f1f-9381-f0786f0fc994/chunks/1",
            "/api/v1/recommendation-snapshots/2d7f6691-8f4f-4f1f-9381-f0786f0fc994/commit",
        ])
        #expect(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer client-test-key"
        })

        let createBody = try #require(requests[0].httpBody)
        let createJSON = try #require(
            JSONSerialization.jsonObject(with: createBody) as? [String: Any]
        )
        #expect(createJSON["repository_count"] as? Int == 1_001)
        #expect(createJSON["chunk_count"] as? Int == 2)

        let firstChunk = try repositoryCount(in: requests[1])
        let secondChunk = try repositoryCount(in: requests[2])
        #expect(firstChunk == 1_000)
        #expect(secondChunk == 1)
    }

    @Test("零仓库快照仍应发送一个空 chunk")
    func uploadsOneEmptyChunk() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let client = CollectionAPIClient(
            baseURL: baseURL,
            apiKey: "key",
            session: URLProtocolStub.ephemeralSession()
        )

        try await client.upload(task: makeTask(repositoryCount: 0))

        #expect(URLProtocolStub.receivedRequests.count == 3)
        #expect(try repositoryCount(in: URLProtocolStub.receivedRequests[1]) == 0)
    }

    @Test("非 2xx 响应只暴露状态码而不解析响应 body")
    func rejectsHTTPFailureWithoutBodyLeak() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!
            return (response, Data("participant_id must not escape".utf8))
        }
        let client = CollectionAPIClient(
            baseURL: baseURL,
            apiKey: "key",
            session: URLProtocolStub.ephemeralSession()
        )

        await #expect(throws: CollectionAPIError.httpStatus(422)) {
            try await client.upload(task: makeTask(repositoryCount: 1))
        }
        #expect(URLProtocolStub.receivedRequests.count == 1)
    }

    @Test("缺少构建期 key 时不应发出网络请求")
    func missingKeyStopsBeforeNetwork() async throws {
        URLProtocolStub.reset()
        let client = CollectionAPIClient(
            baseURL: baseURL,
            apiKey: "",
            session: URLProtocolStub.ephemeralSession()
        )

        await #expect(throws: CollectionAPIError.configurationMissing) {
            try await client.upload(task: makeTask(repositoryCount: 1))
        }
        #expect(URLProtocolStub.receivedRequests.isEmpty)
    }

    private func makeTask(repositoryCount: Int) throws -> DataContributionOutboxTask {
        let repositories = (0..<repositoryCount).map {
            RecommendationSnapshotRepository(repoID: Int64($0 + 1), starredAt: nil)
        }
        let snapshot = RecommendationSnapshot(
            schemaVersion: 1,
            snapshotID: "2d7f6691-8f4f-4f1f-9381-f0786f0fc994",
            participantID: "63b7d101-88c0-4cee-859f-c61f64d8db96",
            capturedAt: "2026-08-23T08:30:00Z",
            mode: "full",
            contentHash: "sha256:" + String(repeating: "a", count: 64),
            repositories: repositories
        )
        return DataContributionOutboxTask(
            id: snapshot.snapshotID,
            accountID: 42,
            participantID: snapshot.participantID,
            schemaVersion: snapshot.schemaVersion,
            payload: try snapshot.encodedPayload(),
            contentHash: snapshot.contentHash,
            state: .pending,
            attemptCount: 0,
            nextAttemptAt: nil
        )
    }

    private func repositoryCount(in request: URLRequest) throws -> Int {
        let data = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(json["repositories"] as? [Any]).count
    }
}
