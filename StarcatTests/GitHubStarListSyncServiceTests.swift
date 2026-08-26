//
//  GitHubStarListSyncServiceTests.swift
//  StarcatTests
//
//  验证 GitHub Lists membership 写入的远端优先、幂等与单次 mutation 约束。
//

import Foundation
import GRDB
import Testing
@testable import Starcat

@Suite("GitHubStarListSyncService", .serialized)
@MainActor
struct GitHubStarListSyncServiceTests {

    private let baseURL = URL(string: "https://api.test.invalid")!

    @Test("批量新增合并现有 membership，每仓库只发一次 mutation，重复调用 no-op")
    func addRepoToListsIsIdempotentAndUsesOneMutation() async throws {
        let environment = try await makeEnvironment(existingListIDs: ["list-a"])
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let query = try Self.graphQLQuery(from: request)
            if query.contains("repository(owner:") {
                return (Self.response(200, for: request), Data(#"{"data":{"repository":{"id":"repo-node"}}}"#.utf8))
            }
            return (Self.response(200, for: request), Data(#"{"data":{"updateUserListsForItem":{"lists":[]}}}"#.utf8))
        }

        let added = try await environment.service.addRepo(
            environment.repo,
            toLists: ["list-b", "list-c"]
        )
        #expect(added == ["list-b", "list-c"])
        #expect(try await environment.repository.listIds(forRepo: environment.repo.id) == ["list-a", "list-b", "list-c"])

        let mutationRequests = try URLProtocolStub.receivedRequests.filter {
            try Self.graphQLQuery(from: $0).contains("updateUserListsForItem")
        }
        #expect(mutationRequests.count == 1)
        let variables = try Self.graphQLVariables(from: #require(mutationRequests.first))
        #expect(variables["listIds"] as? [String] == ["list-a", "list-b", "list-c"])

        let requestCount = URLProtocolStub.receivedRequests.count
        let duplicateAdd = try await environment.service.addRepo(
            environment.repo,
            toLists: ["list-b", "list-c"]
        )
        #expect(duplicateAdd.isEmpty)
        #expect(URLProtocolStub.receivedRequests.count == requestCount)
    }

    @Test("远端 mutation 失败时不产生本地 membership，随后可安全重试")
    func remoteFailureDoesNotWriteLocalMembership() async throws {
        let environment = try await makeEnvironment(existingListIDs: ["list-a"])
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let query = try Self.graphQLQuery(from: request)
            if query.contains("repository(owner:") {
                return (Self.response(200, for: request), Data(#"{"data":{"repository":{"id":"repo-node"}}}"#.utf8))
            }
            throw URLError(.cannotConnectToHost)
        }

        await #expect(throws: (any Error).self) {
            _ = try await environment.service.addRepo(environment.repo, toLists: ["list-b"])
        }
        #expect(try await environment.repository.listIds(forRepo: environment.repo.id) == ["list-a"])
    }

    private func makeEnvironment(
        existingListIDs: [String]
    ) async throws -> (
        service: GitHubStarListSyncService,
        repository: GRDBGitHubStarListRepository,
        repo: Repo
    ) {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 1, owner: "octo", name: "one")
        let repository = GRDBGitHubStarListRepository(database: database)
        let remoteLists = ["list-a", "list-b", "list-c"].enumerated().map { index, id in
            GitHubStarListRemoteRecord(
                id: id,
                name: id,
                description: nil,
                isPrivate: false,
                position: index,
                createdAt: "2026-08-26T00:00:00Z",
                updatedAt: "2026-08-26T00:00:00Z"
            )
        }
        try await repository.replaceRemoteSnapshot(
            lists: remoteLists,
            memberships: existingListIDs.map {
                GitHubStarListRemoteMembership(listId: $0, repoFullName: "octo/one")
            },
            syncedAt: Date(timeIntervalSince1970: 0)
        )
        let repo = try await database.writer.read { db in
            try Repo.fetchOne(db, key: 1)
        }
        let requiredRepo = try #require(repo)
        let client = GitHubAPIClient(
            baseURL: baseURL,
            session: URLProtocolStub.ephemeralSession(),
            tokenProvider: StubTokenProvider(token: "test-token")
        )
        return (
            GitHubStarListSyncService(apiClient: client, repository: repository),
            repository,
            requiredRepo
        )
    }

    private nonisolated static func graphQLQuery(from request: URLRequest) throws -> String {
        let object = try JSONSerialization.jsonObject(with: try #require(request.httpBody))
        let body = try #require(object as? [String: Any])
        return try #require(body["query"] as? String)
    }

    private nonisolated static func graphQLVariables(from request: URLRequest) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: try #require(request.httpBody))
        let body = try #require(object as? [String: Any])
        return try #require(body["variables"] as? [String: Any])
    }

    private nonisolated static func response(_ statusCode: Int, for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
    }
}
