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
        #expect(environment.session.preparedRepositoryIDs.sorted() == [2, 3])
        #expect(environment.session.existingListIDsByRepo[1] == ["list-1"])

        await environment.session.ensureStarredRepositoriesLoaded()
        #expect(environment.session.preparedRepositoryIDs.count == 2)
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
        #expect(environment.session.isManualSessionResolved)
        #expect(!environment.session.canDiscardManualSession)

        environment.session.releaseManualSessionOnWindowDismiss()
        #expect(environment.session.jobs.isEmpty)
        #expect(environment.session.mode == .idle)
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

    @Test("滚动期间冻结可见列表，结束后一次合入最新审核状态")
    func presentationStoreDefersVisibleRefreshWhileScrolling() async throws {
        let provider = ConcurrentGitHubStarListSuggestionProvider(
            delay: .milliseconds(1),
            suggestionsByRepoID: [
                1: [GitHubStarListAISuggestion(listId: "list-1", confidence: 0.95, reason: "Tools")]
            ]
        )
        let environment = try await makeEnvironment(
            repoCount: 1,
            groupedRepoFullNames: [],
            aiRule: (instruction: "Developer tools", autoApplyEnabled: false),
            insightService: provider
        )

        await environment.session.prepareManualContext()
        await environment.session.startManual()
        await waitUntilStopped(environment.session)

        let presentation = GitHubStarListAIGroupingPresentationStore()
        presentation.filter = .suggestions
        presentation.synchronizeImmediately(from: environment.session)
        #expect(presentation.snapshot.selectedRepositoryCount == 1)
        #expect(presentation.visibleItems.first?.isSelectedForBulkApply == true)

        presentation.setScrollInteractionActive(true)
        environment.session.toggleRepoForBulkApply(repoID: 1)
        presentation.synchronizeImmediately(from: environment.session)

        // 进度和底栏使用的新快照已更新，但滚动中的 List 仍保持同一份可见数据。
        #expect(presentation.snapshot.selectedRepositoryCount == 0)
        #expect(presentation.visibleItems.first?.isSelectedForBulkApply == true)

        presentation.setScrollInteractionActive(false)
        #expect(presentation.visibleItems.first?.isSelectedForBulkApply == false)
    }

    @Test("分组展示缓存对大结果集按一百条稳定追加")
    func presentationStorePaginatesLargeGroupingResult() async throws {
        let suggestionsByRepoID = Dictionary(uniqueKeysWithValues: (1...205).map { value in
            (
                Int64(value),
                [GitHubStarListAISuggestion(listId: "list-1", confidence: 0.95, reason: "Tools")]
            )
        })
        let provider = ConcurrentGitHubStarListSuggestionProvider(
            delay: .milliseconds(1),
            suggestionsByRepoID: suggestionsByRepoID
        )
        let environment = try await makeEnvironment(
            repoCount: 205,
            groupedRepoFullNames: [],
            aiRule: (instruction: "Developer tools", autoApplyEnabled: false),
            insightService: provider
        )

        await environment.session.prepareManualContext()
        await environment.session.startManual()
        await waitUntilStopped(environment.session)

        let presentation = GitHubStarListAIGroupingPresentationStore()
        presentation.filter = .suggestions
        presentation.synchronizeImmediately(from: environment.session)
        #expect(presentation.matchingItemCount == 205)
        #expect(presentation.visibleItems.count == 100)
        #expect(presentation.canLoadMore)

        presentation.loadMore()
        #expect(presentation.visibleItems.count == 200)
        presentation.loadMore()
        #expect(presentation.visibleItems.count == 205)
        #expect(!presentation.canLoadMore)
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

    @Test("关闭本次自动确认时，高置信度建议仍进入人工审核")
    func manualRunKeepsSuggestionsPendingWhenAutoConfirmIsOff() async throws {
        let provider = ConcurrentGitHubStarListSuggestionProvider(
            delay: .milliseconds(1),
            suggestionsByRepoID: [
                1: [GitHubStarListAISuggestion(listId: "list-1", confidence: 0.95, reason: "Tools")]
            ]
        )
        let environment = try await makeEnvironment(
            repoCount: 1,
            groupedRepoFullNames: [],
            aiRule: (instruction: "Developer tools", autoApplyEnabled: true),
            insightService: provider
        )
        URLProtocolStub.reset()

        await environment.session.prepareManualContext()
        await environment.session.startManual(autoConfirmEnabled: false, confidenceThreshold: 0.90)
        await waitUntilStopped(environment.session)

        #expect(URLProtocolStub.receivedRequests.isEmpty)
        #expect(environment.session.existingListIDsByRepo[1, default: []].isEmpty)
        #expect(environment.session.selectedListIDsByRepo[1] == ["list-1"])
        #expect(environment.session.selectedRepoIDsForBulkApply == [1])
        environment.session.clearRepoSelectionForBulkApply()
        #expect(environment.session.selectedRepoIDsForBulkApply.isEmpty)
        #expect(environment.session.selectedListIDsByRepo[1] == ["list-1"])
        environment.session.selectAllReposForBulkApply()
        #expect(environment.session.selectedRepoIDsForBulkApply == [1])
        #expect(environment.session.jobs.first?.applyState == .idle)
        #expect(environment.session.hasUnresolvedManualWork)
        #expect(environment.session.canDiscardManualSession)

        environment.session.releaseManualSessionOnWindowDismiss()
        #expect(environment.session.jobs.count == 1)
        #expect(environment.session.mode == .manual)
    }

    @Test("本次自动确认只写入达到阈值且分组已授权的建议")
    func manualAutoConfirmAppliesOnlyQualifiedSuggestions() async throws {
        let provider = ConcurrentGitHubStarListSuggestionProvider(
            delay: .milliseconds(1),
            suggestionsByRepoID: [
                1: [GitHubStarListAISuggestion(listId: "list-1", confidence: 0.95, reason: "High")],
                2: [GitHubStarListAISuggestion(listId: "list-1", confidence: 0.80, reason: "Low")]
            ]
        )
        let environment = try await makeEnvironment(
            repoCount: 2,
            groupedRepoFullNames: [],
            aiRule: (instruction: "Developer tools", autoApplyEnabled: true),
            insightService: provider
        )
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            let payload = if body.contains("repository(owner:") {
                Data(#"{"data":{"repository":{"id":"repo-node"}}}"#.utf8)
            } else {
                Data(#"{"data":{"updateUserListsForItem":{"lists":[]}}}"#.utf8)
            }
            guard let url = request.url,
                  let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
                  )
            else { throw URLError(.badURL) }
            return (response, payload)
        }

        await environment.session.prepareManualContext()
        await environment.session.startManual(autoConfirmEnabled: true, confidenceThreshold: 0.90)
        await waitUntilStopped(environment.session)

        #expect(environment.session.existingListIDsByRepo[1] == ["list-1"])
        #expect(environment.session.existingListIDsByRepo[2, default: []].isEmpty)
        #expect(environment.session.selectedListIDsByRepo[1] == [])
        #expect(environment.session.selectedListIDsByRepo[2] == ["list-1"])
        #expect(environment.session.jobs.first(where: { $0.id == 1 })?.applyState == .applied(["list-1"]))
        #expect(environment.session.jobs.first(where: { $0.id == 2 })?.applyState == .idle)

        let mutationCount = URLProtocolStub.receivedRequests.count { request in
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            return body.contains("updateUserListsForItem")
        }
        #expect(mutationCount == 1)
        #expect(environment.session.hasUnresolvedManualWork)
        #expect(environment.session.canDiscardManualSession)

        environment.session.ignore(repoID: 2)
        #expect(environment.session.isManualSessionResolved)
        #expect(!environment.session.canDiscardManualSession)
        #expect(environment.session.finishManualSessionIfResolved())
        #expect(environment.session.jobs.isEmpty)
        #expect(environment.session.mode == .idle)
    }

    @Test("持久化自动忽略会跨轮展示但不重复分析，手动重试后重新进入队列")
    func persistedAutoIgnoreRequiresExplicitRetry() async throws {
        let provider = ConcurrentGitHubStarListSuggestionProvider(delay: .milliseconds(1))
        let environment = try await makeEnvironment(
            repoCount: 2,
            groupedRepoFullNames: [],
            aiRule: (instruction: "Developer tools", autoApplyEnabled: false),
            insightService: provider
        )
        try await environment.listService.markAIAutoIgnored(
            repoID: 1,
            reason: .organizationOAuthRestriction
        )

        await environment.session.prepareManualContext()
        await environment.session.startManual()
        await waitUntilStopped(environment.session)

        #expect(provider.calledRepoIDs == [2])
        #expect(environment.session.preparedAnalysisRepositoryCount == 1)
        #expect(environment.session.preparedAutomaticallyIgnoredRepoIDs == [1])
        #expect(environment.session.jobs.first(where: { $0.id == 1 })?.automaticallyIgnoredFailure != nil)
        #expect(try await environment.listService.allAIAutoIgnoredRepos().map(\.repoId) == [1])

        await environment.session.retryAutomaticallyIgnored(repoID: 1)
        await waitUntilStopped(environment.session)

        #expect(provider.calledRepoIDs == [2, 1])
        #expect(environment.session.preparedAutomaticallyIgnoredRepoIDs.isEmpty)
        #expect(try await environment.listService.allAIAutoIgnoredRepos().isEmpty)
    }

    @Test("暂停态允许重试分析失败仓库并自动恢复运行")
    func pausedSessionRetriesAnalysisFailuresAndResumes() async throws {
        let provider = ConcurrentGitHubStarListSuggestionProvider(
            delay: .milliseconds(1),
            blockedRepoID: 1,
            failingRepoIDs: [6, 7, 8]
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

        // 等首批其余仓库收口：2-5 成功，6-8 失败，仓库 1 仍被阻塞。
        try? await Task.sleep(for: .milliseconds(120))
        // 运行中(未暂停)重试门槛保持关闭。
        #expect(environment.session.isRunning)
        #expect(!environment.session.isPaused)
        #expect(!environment.session.canRetryFailedItems)
        environment.session.pauseAnalysis()
        #expect(environment.session.isPaused)
        #expect(environment.session.jobs.filter { $0.status == .failed }.map(\.id).sorted() == [6, 7, 8])

        // 暂停态下重试门槛放开。
        #expect(environment.session.canRetryFailedItems)
        environment.session.retryAllAnalysisFailures()
        #expect(!environment.session.isPaused)
        #expect(environment.session.jobs.filter { [6, 7, 8].contains($0.id) }.allSatisfy { $0.status == .queued })

        provider.releaseBlockedCall()
        await waitUntilStopped(environment.session)

        #expect(environment.session.jobs.allSatisfy { $0.status == .completed })
        let retriedCallCount = provider.calledRepoIDs.count { [6, 7, 8].contains($0) }
        #expect(retriedCallCount == 6)
    }

    @Test("暂停态可重试自动忽略仓库，重试解除持久化忽略并重新分析")
    func pausedSessionRetriesAutomaticallyIgnoredRepo() async throws {
        let provider = ConcurrentGitHubStarListSuggestionProvider(
            delay: .milliseconds(1),
            blockedRepoID: 2
        )
        let environment = try await makeEnvironment(
            repoCount: 3,
            groupedRepoFullNames: [],
            aiRule: (instruction: "Developer tools", autoApplyEnabled: false),
            insightService: provider
        )
        try await environment.listService.markAIAutoIgnored(
            repoID: 1,
            reason: .organizationOAuthRestriction
        )

        await environment.session.prepareManualContext()
        await environment.session.startManual()
        await provider.waitUntilBlockedCallStarts()
        try? await Task.sleep(for: .milliseconds(60))
        environment.session.pauseAnalysis()
        #expect(environment.session.isPaused)
        #expect(environment.session.canRetryFailedItems)
        #expect(environment.session.jobs.first(where: { $0.id == 3 })?.status == .completed)

        await environment.session.retryAutomaticallyIgnored(repoID: 1)
        #expect(!environment.session.isPaused)
        #expect(environment.session.preparedAutomaticallyIgnoredRepoIDs.isEmpty)
        #expect(try await environment.listService.allAIAutoIgnoredRepos().isEmpty)

        provider.releaseBlockedCall()
        await waitUntilStopped(environment.session)

        #expect(provider.calledRepoIDs.contains(1))
        #expect(environment.session.jobs.first(where: { $0.id == 1 })?.status == .completed)
        #expect(environment.session.jobs.first(where: { $0.id == 1 })?.automaticallyIgnoredFailure == nil)
    }

    @Test("分析失败 Tab 支持批量勾选并按选中子集重试")
    func analysisFailedTabSupportsBulkSelectionAndSubsetRetry() async throws {
        let provider = ConcurrentGitHubStarListSuggestionProvider(
            delay: .milliseconds(1),
            failingRepoIDs: [2, 3]
        )
        let environment = try await makeEnvironment(
            repoCount: 3,
            groupedRepoFullNames: [],
            aiRule: (instruction: "Developer tools", autoApplyEnabled: false),
            insightService: provider
        )

        await environment.session.prepareManualContext()
        await environment.session.startManual()
        await waitUntilStopped(environment.session)

        #expect(environment.session.jobs.filter { $0.status == .failed }.map(\.id).sorted() == [2, 3])

        // 勾选按 Tab 语义过滤：完成的仓库 1 不可勾选进分析失败集合。
        environment.session.toggleRepoForBulkAction(repoID: 1, filter: .analysisFailed)
        #expect(environment.session.bulkActionRepoIDs.isEmpty)
        environment.session.selectAllReposForBulkAction(filter: .analysisFailed)
        #expect(environment.session.bulkActionRepoIDs == [2, 3])
        environment.session.toggleRepoForBulkAction(repoID: 3, filter: .analysisFailed)
        #expect(environment.session.bulkActionRepoIDs == [2])

        environment.session.applyBulkAction(filter: .analysisFailed)
        #expect(environment.session.bulkActionRepoIDs.isEmpty)
        await waitUntilStopped(environment.session)

        // 只有勾选的仓库 2 被重试并成功；仓库 3 保持失败。
        #expect(environment.session.jobs.first(where: { $0.id == 2 })?.status == .completed)
        #expect(environment.session.jobs.first(where: { $0.id == 3 })?.status == .failed)
        #expect(provider.calledRepoIDs.count { $0 == 2 } == 2)
        #expect(provider.calledRepoIDs.count { $0 == 3 } == 1)
    }

    @Test("无匹配 Tab 批量忽略后可在已忽略 Tab 批量取消忽略")
    func noMatchAndIgnoredTabsSupportBulkIgnoreCycle() async throws {
        let provider = ConcurrentGitHubStarListSuggestionProvider(delay: .milliseconds(1))
        let environment = try await makeEnvironment(
            repoCount: 2,
            groupedRepoFullNames: [],
            aiRule: (instruction: "Developer tools", autoApplyEnabled: false),
            insightService: provider
        )

        await environment.session.prepareManualContext()
        await environment.session.startManual()
        await waitUntilStopped(environment.session)
        #expect(environment.session.jobs.allSatisfy { $0.status == .completed })

        environment.session.selectAllReposForBulkAction(filter: .noMatch)
        #expect(environment.session.bulkActionRepoIDs == [1, 2])
        environment.session.applyBulkAction(filter: .noMatch)
        #expect(environment.session.bulkActionRepoIDs.isEmpty)
        #expect(environment.session.ignoredRepoIDs == [1, 2])

        // 已忽略 Tab 的批量动作是取消忽略；仓库回到无匹配状态。
        environment.session.selectAllReposForBulkAction(filter: .ignored)
        #expect(environment.session.bulkActionRepoIDs == [1, 2])
        environment.session.applyBulkAction(filter: .ignored)
        #expect(environment.session.bulkActionRepoIDs.isEmpty)
        #expect(environment.session.ignoredRepoIDs.isEmpty)
    }

    @Test("切换 Tab 或跨 Tab 勾选不会让批量选择串语义")
    func bulkActionSelectionIsFilteredPerTab() async throws {
        let provider = ConcurrentGitHubStarListSuggestionProvider(delay: .milliseconds(1))
        let environment = try await makeEnvironment(
            repoCount: 1,
            groupedRepoFullNames: [],
            aiRule: (instruction: "Developer tools", autoApplyEnabled: false),
            insightService: provider
        )
        await environment.session.prepareManualContext()
        await environment.session.startManual()
        await waitUntilStopped(environment.session)

        // 待确认/全部/待处理/已应用不提供批量动作勾选。
        environment.session.selectAllReposForBulkAction(filter: .all)
        #expect(environment.session.bulkActionRepoIDs.isEmpty)
        environment.session.selectAllReposForBulkAction(filter: .suggestions)
        #expect(environment.session.bulkActionRepoIDs.isEmpty)
        environment.session.selectAllReposForBulkAction(filter: .noMatch)
        #expect(environment.session.bulkActionRepoIDs == [1])
        environment.session.clearBulkActionSelection()
        #expect(environment.session.bulkActionRepoIDs.isEmpty)
    }

    @Test("已应用结果可展开后精确移除原分组")
    func appliedResultCanReplaceMemberships() async throws {
        let provider = ConcurrentGitHubStarListSuggestionProvider(
            delay: .milliseconds(1),
            suggestionsByRepoID: [
                1: [GitHubStarListAISuggestion(listId: "list-1", confidence: 0.95, reason: "Tools")]
            ]
        )
        let environment = try await makeEnvironment(
            repoCount: 1,
            groupedRepoFullNames: [],
            aiRule: (instruction: "Developer tools", autoApplyEnabled: true),
            insightService: provider
        )
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            let payload = if body.contains("repository(owner:") {
                Data(#"{"data":{"repository":{"id":"repo-node"}}}"#.utf8)
            } else {
                Data(#"{"data":{"updateUserListsForItem":{"lists":[]}}}"#.utf8)
            }
            return (Self.response(200, for: request), payload)
        }

        await environment.session.prepareManualContext()
        await environment.session.startManual(autoConfirmEnabled: true, confidenceThreshold: 0.90)
        await waitUntilStopped(environment.session)
        #expect(environment.session.existingListIDsByRepo[1] == ["list-1"])

        environment.session.toggleSelection(repoID: 1, listID: "list-1")
        #expect(environment.session.editedListIDsByRepo[1] == [])
        environment.session.applyReview(repoID: 1)
        await waitUntilApplyStopped(environment.session)

        #expect(environment.session.existingListIDsByRepo[1] == [])
        #expect(environment.session.jobs.first?.applyState == .applied([]))
        #expect(environment.session.editedListIDsByRepo[1] == nil)
    }

    private func makeEnvironment(
        repoCount: Int,
        groupedRepoFullNames: [String],
        aiRule: (instruction: String, autoApplyEnabled: Bool)? = nil,
        insightService: (any GitHubStarListSuggestionProviding)? = nil
    ) async throws -> (
        session: GitHubStarListAIGroupingSession,
        database: InMemoryDatabaseManager,
        listService: GitHubStarListSyncService
    ) {
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
        return (session, database, listService)
    }

    private func waitUntilStopped(_ session: GitHubStarListAIGroupingSession) async {
        for _ in 0..<400 {
            if !session.isRunning { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("GitHub Lists AI 分组未在预期时间内结束")
    }

    private func waitUntilApplyStopped(_ session: GitHubStarListAIGroupingSession) async {
        for _ in 0..<400 {
            if !session.isApplying { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("GitHub Lists membership 应用未在预期时间内结束")
    }

    nonisolated private static func response(_ statusCode: Int, for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
    }
}

/// 同时记录在途请求，并可阻塞指定仓库，验证固定 Worker 数和逐仓即时回写。
@MainActor
private final class ConcurrentGitHubStarListSuggestionProvider: GitHubStarListSuggestionProviding {
    private let delay: Duration
    private let blockedRepoID: Int64?
    private let failingRepoIDs: Set<Int64>
    private let suggestionsByRepoID: [Int64: [GitHubStarListAISuggestion]]
    private var activeCalls = 0
    private var blockedCallStarted = false
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var blockedStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var alreadyFailedRepoIDs: Set<Int64> = []

    private(set) var callSizes: [Int] = []
    private(set) var calledRepoIDs: [Int64] = []
    private(set) var existingListNamesByRepo: [Int64: [String]] = [:]
    private(set) var maximumActiveCalls = 0

    init(
        delay: Duration,
        blockedRepoID: Int64? = nil,
        failingRepoIDs: Set<Int64> = [],
        suggestionsByRepoID: [Int64: [GitHubStarListAISuggestion]] = [:]
    ) {
        self.delay = delay
        self.blockedRepoID = blockedRepoID
        self.failingRepoIDs = failingRepoIDs
        self.suggestionsByRepoID = suggestionsByRepoID
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
        } else if failingRepoIDs.contains(repo.id),
                  !alreadyFailedRepoIDs.contains(repo.id) {
            // 每个仓库只失败一次，重试后走成功路径，便于验证重试真的重新入队。
            alreadyFailedRepoIDs.insert(repo.id)
            try await Task.sleep(for: delay)
            throw URLError(.badURL)
        } else {
            try await Task.sleep(for: delay)
        }
        return [repo.id: suggestionsByRepoID[repo.id] ?? []]
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
