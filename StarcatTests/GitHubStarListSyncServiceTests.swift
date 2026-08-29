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

    @Test("精确编辑 membership 可同时移除旧分组并加入新分组")
    func setListsReplacesRemoteAndLocalMemberships() async throws {
        let environment = try await makeEnvironment(existingListIDs: ["list-a", "list-b"])
        Self.stubSuccessfulMutations()

        try await environment.service.setLists(
            for: environment.repo,
            listIDs: ["list-b", "list-c"]
        )

        #expect(try await environment.repository.listIds(forRepo: environment.repo.id) == [
            "list-b", "list-c"
        ])
        let mutationRequests = try URLProtocolStub.receivedRequests.filter {
            try Self.graphQLQuery(from: $0).contains("updateUserListsForItem")
        }
        #expect(mutationRequests.count == 1)
        let variables = try Self.graphQLVariables(from: #require(mutationRequests.first))
        #expect(variables["listIds"] as? [String] == ["list-b", "list-c"])
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

    @Test("批量勾选只补齐缺失 membership，并跳过已经属于目标分组的仓库")
    func batchMembershipAddPreservesExistingGroupsAndSkipsNoOp() async throws {
        let environment = try await makeBatchEnvironment(
            existingListIDsByRepo: [
                "octo/one": ["list-a", "list-b"],
                "octo/two": ["list-a"]
            ]
        )
        Self.stubSuccessfulMutations()

        let summary = await environment.service.updateRepos(
            environment.targets,
            membershipIn: "list-b",
            shouldBelong: true
        )

        #expect(summary == GitHubStarListBatchMembershipSummary(
            total: 2,
            succeeded: 1,
            skipped: 1,
            failed: 0
        ))
        #expect(try await environment.repository.listIds(forRepo: 1) == ["list-a", "list-b"])
        #expect(try await environment.repository.listIds(forRepo: 2) == ["list-a", "list-b"])

        let mutationRequests = try URLProtocolStub.receivedRequests.filter {
            try Self.graphQLQuery(from: $0).contains("updateUserListsForItem")
        }
        #expect(mutationRequests.count == 1)
    }

    @Test("批量取消勾选只移除目标 membership，并保留仓库所属的其它分组")
    func batchMembershipRemovePreservesOtherGroups() async throws {
        let environment = try await makeBatchEnvironment(
            existingListIDsByRepo: [
                "octo/one": ["list-a", "list-b"],
                "octo/two": ["list-a", "list-b", "list-c"]
            ]
        )
        Self.stubSuccessfulMutations()

        let summary = await environment.service.updateRepos(
            environment.targets,
            membershipIn: "list-b",
            shouldBelong: false
        )

        #expect(summary == GitHubStarListBatchMembershipSummary(
            total: 2,
            succeeded: 2,
            skipped: 0,
            failed: 0
        ))
        #expect(try await environment.repository.listIds(forRepo: 1) == ["list-a"])
        #expect(try await environment.repository.listIds(forRepo: 2) == ["list-a", "list-c"])
    }

    @Test("批量 membership 单条失败不阻断后续汇总，失败仓库不写本地")
    func batchMembershipFailureKeepsLocalState() async throws {
        let environment = try await makeBatchEnvironment(
            existingListIDsByRepo: [
                "octo/one": ["list-a"],
                "octo/two": ["list-a"]
            ]
        )
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let query = try Self.graphQLQuery(from: request)
            let variables = try Self.graphQLVariables(from: request)
            if query.contains("repository(owner:") {
                let name = try #require(variables["name"] as? String)
                let payload = "{\"data\":{\"repository\":{\"id\":\"repo-node-\(name)\"}}}"
                return (Self.response(200, for: request), Data(payload.utf8))
            }
            if variables["itemId"] as? String == "repo-node-two" {
                throw URLError(.cannotConnectToHost)
            }
            return (Self.response(200, for: request), Data(#"{"data":{"updateUserListsForItem":{"lists":[]}}}"#.utf8))
        }

        let summary = await environment.service.updateRepos(
            environment.targets,
            membershipIn: "list-b",
            shouldBelong: true
        )

        #expect(summary == GitHubStarListBatchMembershipSummary(
            total: 2,
            succeeded: 1,
            skipped: 0,
            failed: 1
        ))
        #expect(try await environment.repository.listIds(forRepo: 1) == ["list-a", "list-b"])
        #expect(try await environment.repository.listIds(forRepo: 2) == ["list-a"])
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

    private func makeBatchEnvironment(
        existingListIDsByRepo: [String: [String]]
    ) async throws -> (
        service: GitHubStarListSyncService,
        repository: GRDBGitHubStarListRepository,
        targets: [BatchStarTarget]
    ) {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 1, owner: "octo", name: "one")
        try await database.insertRepoFixture(id: 2, owner: "octo", name: "two")
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
        let memberships = existingListIDsByRepo.flatMap { fullName, listIDs in
            listIDs.map {
                GitHubStarListRemoteMembership(listId: $0, repoFullName: fullName)
            }
        }
        try await repository.replaceRemoteSnapshot(
            lists: remoteLists,
            memberships: memberships,
            syncedAt: Date(timeIntervalSince1970: 0)
        )
        let client = GitHubAPIClient(
            baseURL: baseURL,
            session: URLProtocolStub.ephemeralSession(),
            tokenProvider: StubTokenProvider(token: "test-token")
        )
        return (
            GitHubStarListSyncService(apiClient: client, repository: repository),
            repository,
            [
                BatchStarTarget(ghRepoId: 1, owner: "octo", name: "one"),
                BatchStarTarget(ghRepoId: 2, owner: "octo", name: "two")
            ]
        )
    }

    private static func stubSuccessfulMutations() {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let query = try graphQLQuery(from: request)
            if query.contains("repository(owner:") {
                return (response(200, for: request), Data(#"{"data":{"repository":{"id":"repo-node"}}}"#.utf8))
            }
            return (response(200, for: request), Data(#"{"data":{"updateUserListsForItem":{"lists":[]}}}"#.utf8))
        }
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
