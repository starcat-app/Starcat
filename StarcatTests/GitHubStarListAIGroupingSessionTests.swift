//
//  GitHubStarListAIGroupingSessionTests.swift
//  StarcatTests
//
//  验证 AI 仓库分组的轻量开始页、五 Worker 队列与单仓渐进回写。
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

    @Test("AI 分组按仓库消费并限制为五路并发")
    func groupingUsesFiveSingleRepoWorkers() async throws {
        let provider = ConcurrentGitHubStarListSuggestionProvider(delay: .milliseconds(40))
        let environment = try await makeEnvironment(
            repoCount: 20,
            groupedRepoFullNames: [],
            aiRule: (instruction: "Developer tools", autoApplyEnabled: false),
            insightService: provider
        )

        await environment.session.prepareManualContext()
        await environment.session.startManual()
        await waitUntilStopped(environment.session)

        #expect(provider.callSizes.count == 20)
        #expect(provider.callSizes.allSatisfy { $0 == 1 })
        #expect(provider.maximumActiveCalls == 5)
        #expect(environment.session.jobs.allSatisfy { $0.status == .completed })
    }

    @Test("Worker 完成仓库后立即回写，不等待慢请求统一收口")
    func groupingPublishesCompletionBeforeSlowerRequestFinishes() async throws {
        let blockedRepoID: Int64 = 2
        let provider = ConcurrentGitHubStarListSuggestionProvider(
            delay: .milliseconds(5),
            blockedRepoID: blockedRepoID
        )
        let environment = try await makeEnvironment(
            repoCount: 8,
            groupedRepoFullNames: [],
            aiRule: (instruction: "Developer tools", autoApplyEnabled: false),
            insightService: provider
        )

        await environment.session.prepareManualContext()
        await environment.session.startManual()
        await provider.waitUntilBlockedCallStarts()
        for _ in 0..<200 where environment.session.analyzedCount < 7 {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(environment.session.isRunning)
        #expect(environment.session.analyzedCount == 7)
        #expect(environment.session.jobs.first(where: { $0.id == blockedRepoID })?.status == .analyzing)
        #expect(environment.session.jobs.filter { $0.id != blockedRepoID }.allSatisfy { $0.status == .completed })

        provider.releaseBlockedCall()
        await waitUntilStopped(environment.session)
        #expect(environment.session.jobs.allSatisfy { $0.status == .completed })
    }

    @Test("多选入口只分析冻结的仓库，并把已有分组名称交给 AI")
    func selectedScopeUsesOnlyFrozenRepositoriesAndExistingGroupNames() async throws {
        let provider = ConcurrentGitHubStarListSuggestionProvider(delay: .milliseconds(5))
        let environment = try await makeEnvironment(
            repoCount: 4,
            groupedRepoFullNames: ["octo/demo-2"],
            aiRule: (instruction: "Developer tools", autoApplyEnabled: false),
            insightService: provider
        )
        await environment.session.prepareManualContext()
        let repositories = try await GRDBRepoRepository(database: environment.database).fetchAllStarred()
        let selectedRepositories = repositories.filter { [2, 4].contains($0.id) }
        let preflightContext = GitHubStarListAIGroupingPreflightContext(
            repositoryCount: 2,
            ungroupedRepositoryCount: 1,
            availableLists: environment.session.availableLists,
            membershipCountByListID: ["list-1": 1],
            rulesByListID: environment.session.rulesByListID
        )

        environment.session.prepareManualContext(
            from: preflightContext,
            repositories: selectedRepositories,
            existingMemberships: [2: ["list-1"], 4: []]
        )
        await environment.session.startManual()
        await waitUntilStopped(environment.session)

        #expect(environment.session.preparedRepositoryCount == 2)
        #expect(Set(provider.calledRepoIDs) == [2, 4])
        #expect(provider.existingListNamesByRepo[2] == ["Tools"])
        #expect(provider.existingListNamesByRepo[4] == [])
    }

    @Test("暂停只阻止领取新仓库，继续后完成剩余队列")
    func pauseWaitsBeforeNextClaimAndResumeCompletesQueue() async throws {
        let provider = ConcurrentGitHubStarListSuggestionProvider(
            delay: .milliseconds(100),
            blockedRepoID: 2
        )
        let environment = try await makeEnvironment(
            repoCount: 8,
            groupedRepoFullNames: [],
            aiRule: (instruction: "Developer tools", autoApplyEnabled: false),
            insightService: provider
        )

        await environment.session.prepareManualContext()
        await environment.session.startManual()
        await provider.waitUntilBlockedCallStarts()
        environment.session.pauseAnalysis()
        #expect(environment.session.isRunning)
        #expect(environment.session.isPaused)

        // 首批五个请求可以正常收口，但暂停期间不能再领取第六个仓库。
        try? await Task.sleep(for: .milliseconds(160))
        #expect(provider.callSizes.count == 5)

        environment.session.resumeAnalysis()
        provider.releaseBlockedCall()
        await waitUntilStopped(environment.session)

        #expect(!environment.session.isPaused)
        #expect(provider.callSizes.count == 8)
        #expect(environment.session.jobs.allSatisfy { $0.status == .completed })
    }

    private func makeEnvironment(
        repoCount: Int,
        groupedRepoFullNames: [String],
        aiRule: (instruction: String, autoApplyEnabled: Bool)? = nil,
        insightService: (any GitHubStarListSuggestionProviding)? = nil
    ) async throws -> (session: GitHubStarListAIGroupingSession, database: InMemoryDatabaseManager) {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixtures(count: repoCount)
        let listRepository = GRDBGitHubStarListRepository(database: database)
        let hasList = !groupedRepoFullNames.isEmpty || aiRule != nil
        try await listRepository.replaceRemoteSnapshot(
            lists: hasList ? [
                GitHubStarListRemoteRecord(
                    id: "list-1",
                    name: "Tools",
                    description: nil,
                    isPrivate: false,
                    position: 0,
                    createdAt: "2026-08-28T00:00:00Z",
                    updatedAt: "2026-08-28T00:00:00Z"
                )
            ] : [],
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
        if let aiRule {
            try await listService.saveAIRule(
                listID: "list-1",
                instruction: aiRule.instruction,
                autoApplyEnabled: aiRule.autoApplyEnabled
            )
        }
        let suiteName = "test.starcat.list-grouping.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let keychain = InMemoryKeychain()
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        let resolvedInsightService: any GitHubStarListSuggestionProviding
        if let insightService {
            resolvedInsightService = insightService
        } else {
            resolvedInsightService = RepoAIInsightService(
                summaryRepository: GRDBAISummaryRepository(database: database),
                readmeRepository: ReadmeRepository(database: database),
                settings: settings,
                keychain: keychain
            )
        }
        let session = GitHubStarListAIGroupingSession(
            repoRepository: GRDBRepoRepository(database: database),
            listService: listService,
            insightService: resolvedInsightService,
            entitlementGate: EntitlementGate(
                entitlementProvider: GroupingSessionTestEntitlementProvider(isPro: true),
                userIDProvider: { 1 }
            )
        )
        return (session, database)
    }

    private func waitUntilStopped(_ session: GitHubStarListAIGroupingSession) async {
        for _ in 0..<400 {
            if !session.isRunning { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("GitHub Lists AI 分组未在预期时间内结束")
    }
}

/// 同时记录在途请求，并可阻塞指定仓库，验证固定 Worker 数和逐仓即时回写。
@MainActor
private final class ConcurrentGitHubStarListSuggestionProvider: GitHubStarListSuggestionProviding {
    private let delay: Duration
    private let blockedRepoID: Int64?
    private var activeCalls = 0
    private var blockedCallStarted = false
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var blockedStartWaiters: [CheckedContinuation<Void, Never>] = []

    private(set) var callSizes: [Int] = []
    private(set) var calledRepoIDs: [Int64] = []
    private(set) var existingListNamesByRepo: [Int64: [String]] = [:]
    private(set) var maximumActiveCalls = 0

    init(delay: Duration, blockedRepoID: Int64? = nil) {
        self.delay = delay
        self.blockedRepoID = blockedRepoID
    }

    func generateGitHubListSuggestions(
        for repos: [Repo],
        candidates: [GitHubStarListAIContext],
        existingListIDsByRepo: [Int64: Set<String>],
        existingListNamesByRepo: [Int64: [String]]
    ) async throws -> [Int64: [GitHubStarListAISuggestion]] {
        callSizes.append(repos.count)
        activeCalls += 1
        maximumActiveCalls = max(maximumActiveCalls, activeCalls)
        defer { activeCalls -= 1 }

        guard let repo = repos.first, repos.count == 1 else {
            Issue.record("分组 Worker 每次必须只提交一个仓库")
            return [:]
        }
        calledRepoIDs.append(repo.id)
        self.existingListNamesByRepo[repo.id] = existingListNamesByRepo[repo.id] ?? []
        if repo.id == blockedRepoID {
            await withCheckedContinuation { continuation in
                blockedContinuation = continuation
                blockedCallStarted = true
                let waiters = blockedStartWaiters
                blockedStartWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        } else {
            try await Task.sleep(for: delay)
        }
        return [repo.id: []]
    }

    func waitUntilBlockedCallStarts() async {
        guard !blockedCallStarted else { return }
        await withCheckedContinuation { continuation in
            blockedStartWaiters.append(continuation)
        }
    }

    func releaseBlockedCall() {
        blockedContinuation?.resume()
        blockedContinuation = nil
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
