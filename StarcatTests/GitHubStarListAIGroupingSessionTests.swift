//
//  GitHubStarListAIGroupingSessionTests.swift
//  StarcatTests
//
//  验证 AI 仓库分组开始页不拉取完整仓库表，以及关闭窗口才释放未使用上下文。
//

import Foundation
import Testing
@testable import Starcat

@Suite("GitHubStarListAIGroupingSession", .serialized)
@MainActor
struct GitHubStarListAIGroupingSessionTests {

    @Test("开始页只准备 COUNT 统计，不展开全部 starred 仓库")
    func prepareManualContextDoesNotLoadRepositoryPayload() async throws {
        let environment = try await makeEnvironment(
            repoCount: 5,
            groupedRepoFullNames: ["octo/demo-1"]
        )

        await environment.session.prepareManualContext()

        #expect(environment.session.preparedRepositoryCount == 5)
        #expect(environment.session.ungroupedRepositoryCount == 4)
        #expect(environment.session.membershipCountByListID["list-1"] == 1)
        #expect(!environment.session.hasLoadedStarredRepositories)
        #expect(environment.session.mode == .manual)
        #expect(environment.session.availableLists.map(\.id) == ["list-1"])

        // 0 个以上分组时也必须能二次打开而不再拉仓库；没有分组时同样走这条短路。
        await environment.session.prepareManualContext()
        #expect(!environment.session.hasLoadedStarredRepositories)
        #expect(environment.session.preparedRepositoryCount == 5)
    }

    @Test("没有分组时开始页仍然只准备计数，二次 prepare 不展开仓库")
    func prepareWithZeroGroupsDoesNotReloadPayload() async throws {
        let environment = try await makeEnvironment(repoCount: 3, groupedRepoFullNames: [])

        await environment.session.prepareManualContext()
        #expect(environment.session.preparedRepositoryCount == 3)
        #expect(environment.session.ungroupedRepositoryCount == 3)
        #expect(environment.session.availableLists.isEmpty)
        #expect(!environment.session.hasLoadedStarredRepositories)

        await environment.session.prepareManualContext()
        #expect(!environment.session.hasLoadedStarredRepositories)
    }

    @Test("分析前才展开完整仓库和 membership")
    func ensureStarredRepositoriesLoadedFetchesPayloadOnce() async throws {
        let environment = try await makeEnvironment(
            repoCount: 3,
            groupedRepoFullNames: ["octo/demo-1"]
        )

        await environment.session.prepareManualContext()
        #expect(!environment.session.hasLoadedStarredRepositories)
        #expect(environment.session.existingListIDsByRepo.isEmpty)

        await environment.session.ensureStarredRepositoriesLoaded()
        #expect(environment.session.hasLoadedStarredRepositories)
        #expect(environment.session.preparedRepositoryIDs.sorted() == [1, 2, 3])
        #expect(environment.session.existingListIDsByRepo[1] == ["list-1"])

        await environment.session.ensureStarredRepositoriesLoaded()
        #expect(environment.session.preparedRepositoryIDs.count == 3)
    }

    @Test("关闭窗口才释放未使用的开始页上下文")
    func releaseManualContextIfUnusedClearsPreparedCounts() async throws {
        let environment = try await makeEnvironment(repoCount: 2, groupedRepoFullNames: [])

        await environment.session.prepareManualContext()
        environment.session.releaseManualContextIfUnused()

        #expect(environment.session.preparedRepositoryCount == 0)
        #expect(environment.session.ungroupedRepositoryCount == 0)
        #expect(environment.session.mode == .idle)
        #expect(!environment.session.hasLoadedStarredRepositories)
    }

    private func makeEnvironment(
        repoCount: Int,
        groupedRepoFullNames: [String]
    ) async throws -> (session: GitHubStarListAIGroupingSession, database: InMemoryDatabaseManager) {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixtures(count: repoCount)
        let listRepository = GRDBGitHubStarListRepository(database: database)
        try await listRepository.replaceRemoteSnapshot(
            lists: groupedRepoFullNames.isEmpty ? [] : [
                GitHubStarListRemoteRecord(
                    id: "list-1",
                    name: "Tools",
                    description: nil,
                    isPrivate: false,
                    position: 0,
                    createdAt: "2026-08-28T00:00:00Z",
                    updatedAt: "2026-08-28T00:00:00Z"
                )
            ],
            memberships: groupedRepoFullNames.map {
                GitHubStarListRemoteMembership(listId: "list-1", repoFullName: $0)
            },
            syncedAt: Date(timeIntervalSince1970: 0)
        )

        let client = GitHubAPIClient(
            baseURL: URL(string: "https://api.test.invalid")!,
            session: URLProtocolStub.ephemeralSession(),
            tokenProvider: StubTokenProvider(token: "test-token")
        )
        let listService = GitHubStarListSyncService(apiClient: client, repository: listRepository)
        let suiteName = "test.starcat.list-grouping.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let keychain = InMemoryKeychain()
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        let insight = RepoAIInsightService(
            summaryRepository: GRDBAISummaryRepository(database: database),
            readmeRepository: ReadmeRepository(database: database),
            settings: settings,
            keychain: keychain
        )
        let session = GitHubStarListAIGroupingSession(
            repoRepository: GRDBRepoRepository(database: database),
            listService: listService,
            insightService: insight,
            entitlementGate: EntitlementGate(
                entitlementProvider: GroupingSessionTestEntitlementProvider(isPro: true),
                userIDProvider: { 1 }
            )
        )
        return (session, database)
    }
}

@MainActor
private final class GroupingSessionTestEntitlementProvider: ProEntitlementProviding {
    let entitlement: ProEntitlement

    init(isPro: Bool) {
        self.entitlement = ProEntitlement(
            isActive: isPro,
            productID: isPro ? "test.pro" : nil,
            expirationDate: nil,
            verifiedAt: Date(),
            source: isPro ? .testEnvironment : .none
        )
    }
}
