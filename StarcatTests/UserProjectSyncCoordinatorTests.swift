//
//  UserProjectSyncCoordinatorTests.swift
//  StarcatTests
//
//  验证 collaborator / owner / organization_member 分页链、失败保旧值、304 和并发去重。
//

import Foundation
import Testing
@testable import Starcat

@Suite("UserProjectSyncCoordinator")
struct UserProjectSyncCoordinatorTests {
    private final class MockAPI: UserProjectsAPIProtocol, @unchecked Sendable {
        typealias Handler = @Sendable (
            ProjectAffiliation,
            UserProjectsAPIVisibility,
            Int,
            Int,
            String?
        ) async throws -> APIResponse<[GitHubUserProjectDTO]>

        private let lock = NSLock()
        private var _callCount = 0
        let handler: Handler

        init(handler: @escaping Handler) {
            self.handler = handler
        }

        var callCount: Int {
            lock.withLock { _callCount }
        }

        func userProjects(
            affiliation: ProjectAffiliation,
            visibility: UserProjectsAPIVisibility,
            page: Int,
            perPage: Int,
            ifNoneMatch: String?
        ) async throws -> APIResponse<[GitHubUserProjectDTO]> {
            lock.withLock { _callCount += 1 }
            return try await handler(affiliation, visibility, page, perPage, ifNoneMatch)
        }
    }

    private func makeRemote(
        id: Int64,
        owner: String,
        name: String,
        visibility: ProjectVisibility = .public
    ) -> GitHubUserProjectDTO {
        let user = GitHubUserDTO(
            id: 1,
            login: owner,
            name: nil,
            avatarUrl: nil,
            publicRepos: nil,
            followers: nil,
            following: nil,
            bio: nil,
            company: nil,
            location: nil,
            email: nil,
            blog: nil,
            twitterUsername: nil,
            htmlUrl: nil
        )
        return GitHubUserProjectDTO(
            repo: GitHubRepoDTO(
                id: id,
                name: name,
                fullName: "\(owner)/\(name)",
                owner: user,
                description: nil,
                language: "Swift",
                stargazersCount: Int(id),
                forksCount: 0,
                watchersCount: 0,
                topics: [],
                license: nil,
                homepage: nil,
                htmlUrl: "https://github.com/\(owner)/\(name)",
                cloneUrl: nil,
                sshUrl: nil,
                isPrivate: visibility != .public,
                fork: false,
                archived: false,
                pushedAt: nil,
                createdAt: nil,
                updatedAt: nil,
                openIssuesCount: nil,
                defaultBranch: "main",
                disabled: nil,
                isTemplate: nil,
                score: nil
            ),
            ownerType: owner == "tester" ? .user : .organization,
            visibility: visibility,
            permission: .admin
        )
    }

    private func response(
        _ values: [GitHubUserProjectDTO],
        nextPage: Int? = nil,
        etag: String? = nil
    ) -> APIResponse<[GitHubUserProjectDTO]> {
        APIResponse(
            value: values,
            linkHeader: LinkHeader(nextPage: nextPage, lastPage: nextPage),
            rateLimit: .empty,
            statusCode: 200,
            etag: etag
        )
    }

    @Test("三条 affiliation 链完整分页后分别提交")
    func syncsBothAffiliationsAndPages() async throws {
        let database = try InMemoryDatabaseManager()
        let repository = GRDBUserProjectRepository(database: database)
        let api = MockAPI { affiliation, visibility, page, perPage, _ in
            #expect(visibility == .publicOnly)
            #expect(perPage == 100)
            switch (affiliation, page) {
            case (.owner, 1):
                return response(
                    [makeRemote(id: 1, owner: "tester", name: "one")],
                    nextPage: 2,
                    etag: "\"owner\""
                )
            case (.owner, 2):
                return response([makeRemote(id: 2, owner: "tester", name: "two")])
            case (.organizationMember, 1):
                return response(
                    [makeRemote(id: 3, owner: "Acme", name: "three")],
                    etag: "\"org\""
                )
            case (.collaborator, 1):
                return response(
                    [makeRemote(id: 4, owner: "external", name: "four")],
                    etag: "\"collaborator\""
                )
            default:
                Issue.record("意外请求: \(affiliation.rawValue) page=\(page)")
                return response([])
            }
        }
        let coordinator = UserProjectSyncCoordinator(api: api, repository: repository)

        let result = try await coordinator.sync(
            userID: 7,
            authorizationSource: .oauth
        )

        #expect(result.receivedCount == 4)
        #expect(result.unchangedAffiliations.isEmpty)
        #expect(try await repository.count(userID: 7, filter: .init()) == 4)
        let ownerState = try #require(
            try await repository.fetchSyncState(
                userID: 7,
                affiliation: .owner,
                authorizationSource: .oauth
            )
        )
        let orgState = try #require(
            try await repository.fetchSyncState(
                userID: 7,
                affiliation: .organizationMember,
                authorizationSource: .oauth
            )
        )
        let collaboratorState = try #require(
            try await repository.fetchSyncState(
                userID: 7,
                affiliation: .collaborator,
                authorizationSource: .oauth
            )
        )
        #expect(ownerState.etag == "\"owner\"")
        #expect(orgState.etag == "\"org\"")
        #expect(collaboratorState.etag == "\"collaborator\"")
        #expect(ownerState.syncStatus == .succeeded)
        #expect(orgState.syncStatus == .succeeded)
        #expect(collaboratorState.syncStatus == .succeeded)
    }

    @Test("单条链失败保留旧关系并返回部分同步摘要")
    func midPaginationFailurePreservesOldRelations() async throws {
        let database = try InMemoryDatabaseManager()
        let repository = GRDBUserProjectRepository(database: database)
        try await repository.upsertPage(
            [
                makeRemote(id: 90, owner: "Acme", name: "old")
                    .remoteProject(affiliation: .organizationMember)
            ],
            userID: 7,
            authorizationSource: .githubApp,
            generation: "old-generation",
            seenAt: Date(timeIntervalSince1970: 1)
        )
        try await repository.completeGeneration(
            userID: 7,
            affiliation: .organizationMember,
            authorizationSource: .githubApp,
            generation: "old-generation",
            etag: "\"old\"",
            completedAt: Date(timeIntervalSince1970: 1)
        )

        let api = MockAPI { affiliation, _, page, _, _ in
            if affiliation == .owner {
                return response([])
            }
            if affiliation == .collaborator {
                return response([])
            }
            if page == 1 {
                return response(
                    [makeRemote(id: 91, owner: "Acme", name: "new")],
                    nextPage: 2
                )
            }
            throw NetworkError.transport(underlying: URLError(.timedOut))
        }
        let coordinator = UserProjectSyncCoordinator(api: api, repository: repository)

        let summary = try await coordinator.sync(
            userID: 7,
            authorizationSource: .githubApp
        )

        let projects = try await repository.fetchPage(
            userID: 7,
            filter: .init(),
            limit: 20,
            offset: 0
        )
        #expect(Set(projects.map(\.repo.id)).isSuperset(of: [90, 91]))
        let state = try #require(
            try await repository.fetchSyncState(
                userID: 7,
                affiliation: .organizationMember,
                authorizationSource: .githubApp
            )
        )
        #expect(state.syncStatus == .failed)
        #expect(state.errorCode == "transport")
        #expect(state.lastSuccessAt != nil)
        #expect(summary.isPartial)
        #expect(summary.failedAffiliations == [.organizationMember: "transport"])
        #expect(!summary.isOrganizationApprovalPending)
    }

    @Test("owner 成功且组织链 403 时标记组织审批待处理")
    func organizationForbiddenBecomesApprovalPending() async throws {
        let database = try InMemoryDatabaseManager()
        let repository = GRDBUserProjectRepository(database: database)
        let api = MockAPI { affiliation, _, _, _, _ in
            if affiliation == .owner {
                return response([makeRemote(id: 120, owner: "tester", name: "owner")])
            }
            if affiliation == .collaborator {
                return response([])
            }
            throw NetworkError.clientError(statusCode: 403, message: nil)
        }
        let coordinator = UserProjectSyncCoordinator(api: api, repository: repository)

        let summary = try await coordinator.sync(
            userID: 7,
            authorizationSource: .githubApp
        )

        #expect(summary.receivedCount == 1)
        #expect(summary.failedAffiliations == [.organizationMember: "client_403"])
        #expect(summary.isOrganizationApprovalPending)
    }

    @Test("组织成员关系应覆盖同一仓库的 collaborator 关系")
    func organizationRelationshipOverridesCollaborator() async throws {
        let database = try InMemoryDatabaseManager()
        let repository = GRDBUserProjectRepository(database: database)
        let api = MockAPI { affiliation, _, _, _, _ in
            switch affiliation {
            case .collaborator:
                return response([makeRemote(id: 130, owner: "Acme", name: "shared")])
            case .organizationMember:
                return response([makeRemote(id: 130, owner: "Acme", name: "shared")])
            case .owner:
                return response([])
            }
        }
        let coordinator = UserProjectSyncCoordinator(api: api, repository: repository)

        let summary = try await coordinator.sync(
            userID: 7,
            authorizationSource: .oauth
        )
        let project = try #require(try await repository.fetchProject(repoID: 130))

        #expect(summary.receivedCount == 2)
        #expect(try await repository.count(userID: 7, filter: .init()) == 1)
        #expect(project.affiliation == .organizationMember)
    }

    @Test("304 沿用旧代际并更新成功状态")
    func notModifiedKeepsGeneration() async throws {
        let database = try InMemoryDatabaseManager()
        let repository = GRDBUserProjectRepository(database: database)
        for affiliation in ProjectAffiliation.allCases {
            let repoID: Int64 = switch affiliation {
            case .owner: 101
            case .organizationMember: 102
            case .collaborator: 103
            }
            try await repository.upsertPage(
                [makeRemote(id: repoID, owner: "tester", name: affiliation.rawValue)
                    .remoteProject(affiliation: affiliation)],
                userID: 7,
                authorizationSource: .oauth,
                generation: "stable-\(affiliation.rawValue)",
                seenAt: Date(timeIntervalSince1970: 1)
            )
            try await repository.completeGeneration(
                userID: 7,
                affiliation: affiliation,
                authorizationSource: .oauth,
                generation: "stable-\(affiliation.rawValue)",
                etag: "\"\(affiliation.rawValue)\"",
                completedAt: Date(timeIntervalSince1970: 1)
            )
        }
        let api = MockAPI { affiliation, _, _, _, ifNoneMatch in
            #expect(ifNoneMatch == "\"\(affiliation.rawValue)\"")
            throw NetworkError.notModified(etag: ifNoneMatch)
        }
        let coordinator = UserProjectSyncCoordinator(api: api, repository: repository)

        let result = try await coordinator.sync(
            userID: 7,
            authorizationSource: .oauth
        )

        #expect(result.unchangedAffiliations == Set(ProjectAffiliation.allCases))
        #expect(try await repository.count(userID: 7, filter: .init()) == 3)
    }

    @Test("相同同步触发共享一个 in-flight Task")
    func deduplicatesConcurrentTriggers() async throws {
        let database = try InMemoryDatabaseManager()
        let repository = GRDBUserProjectRepository(database: database)
        let api = MockAPI { _, _, _, _, _ in
            try await Task.sleep(for: .milliseconds(50))
            return response([])
        }
        let coordinator = UserProjectSyncCoordinator(api: api, repository: repository)

        async let first = coordinator.sync(
            userID: 7,
            authorizationSource: .oauth
        )
        async let second = coordinator.sync(
            userID: 7,
            authorizationSource: .oauth
        )
        _ = try await (first, second)

        #expect(api.callCount == 3)
    }
}
