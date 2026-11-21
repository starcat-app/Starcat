//
//  MyInsightsViewModelTests.swift
//  StarcatTests
//
//  验证洞察快照的请求身份、同身份刷新及迟到结果保护。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("My insights view model")
struct MyInsightsViewModelTests {

    @Test("首次加载成功后展示真实范围快照")
    func initialLoadUsesProviderSnapshot() async {
        let provider = MyInsightsProviderStub(outcomes: [
            .snapshot(snapshot(scope: .starred, projects: 3))
        ])
        let viewModel = MyInsightsViewModel(provider: provider)
        let request = request()

        await viewModel.load(request)

        #expect(viewModel.state(for: request) == .loaded)
        #expect(viewModel.snapshot(for: request)?.metrics.first?.value == 3)
    }

    @Test("刷新失败保留旧快照并显示 stale")
    func refreshFailureKeepsPreviousSnapshot() async {
        let provider = MyInsightsProviderStub(outcomes: [
            .snapshot(snapshot(scope: .starred, projects: 3)),
            .failure
        ])
        let viewModel = MyInsightsViewModel(provider: provider)
        let request = request()
        await viewModel.load(request)

        await provider.setLoadGateEnabled(true)
        let refreshTask = Task { await viewModel.refresh(request) }
        await provider.waitForLoadStart()
        #expect(viewModel.state(for: request) == .refreshing)
        #expect(viewModel.snapshot(for: request)?.metrics.first?.value == 3)
        await provider.releaseLoadGate()
        await refreshTask.value

        #expect(viewModel.state(for: request) == .stale)
        #expect(viewModel.snapshot(for: request)?.metrics.first?.value == 3)
        #expect(await provider.invalidateCount == 1)
    }

    @Test("切换范围的首帧及查询中均无旧范围数据")
    func scopeSwitchHidesPreviousSnapshot() async {
        let provider = MyInsightsProviderStub(outcomes: [
            .snapshot(snapshot(scope: .starred, projects: 3)),
            .snapshot(snapshot(scope: .knowledge, projects: 9))
        ])
        let viewModel = MyInsightsViewModel(provider: provider)
        let starred = request()
        let knowledge = request(scope: .knowledge)
        await viewModel.load(starred)
        #expect(viewModel.state(for: knowledge) == .idle)
        #expect(viewModel.snapshot(for: knowledge) == nil)

        await provider.setLoadGateEnabled(true)
        let loadTask = Task { await viewModel.load(knowledge) }

        await provider.waitForLoadStart()
        #expect(viewModel.state(for: knowledge) == .loading)
        #expect(viewModel.snapshot(for: knowledge) == nil)

        await provider.releaseLoadGate()
        await loadTask.value

        #expect(viewModel.state(for: knowledge) == .loaded)
        #expect(viewModel.snapshot(for: knowledge)?.scope == .knowledge)
        #expect(viewModel.snapshot(for: knowledge)?.metrics.first?.value == 9)
    }

    @Test("切换范围失败不会继续展示旧范围数字")
    func scopeFailureClearsOldScopeSnapshot() async {
        let provider = MyInsightsProviderStub(outcomes: [
            .snapshot(snapshot(scope: .starred, projects: 3)),
            .failure
        ])
        let viewModel = MyInsightsViewModel(provider: provider)
        let starred = request()
        let knowledge = request(scope: .knowledge)
        await viewModel.load(starred)

        await viewModel.load(knowledge)

        #expect(viewModel.state(for: knowledge) == .failed)
        #expect(viewModel.snapshot(for: knowledge) == nil)
        #expect(viewModel.snapshot(for: starred) == nil)
    }

    @Test("切库或更换向量模型立即隐藏旧数字，迟到结果不能覆盖当前账号")
    func latestIdentityOwnsTheSnapshot() async {
        let provider = MyInsightsProviderStub(outcomes: [
            .snapshot(snapshot(scope: .knowledge, projects: 3)),
            .snapshot(snapshot(scope: .knowledge, projects: 6)),
            .snapshot(snapshot(scope: .knowledge, projects: 9))
        ])
        let viewModel = MyInsightsViewModel(provider: provider)
        let original = request(scope: .knowledge)
        let changedModel = request(scope: .knowledge, embeddingModel: "embed-v2")
        let changedAccount = request(scope: .knowledge, accountID: 2, databaseRevision: 1, embeddingModel: "embed-v2")
        await viewModel.load(original)
        #expect(viewModel.snapshot(for: changedModel) == nil)
        #expect(viewModel.snapshot(for: request(scope: .knowledge, databaseRevision: 1)) == nil)

        await provider.setLoadGateEnabled(true)
        let olderTask = Task { await viewModel.load(changedModel) }
        await provider.waitForLoadStart()
        await provider.setLoadGateEnabled(false)
        await viewModel.load(changedAccount)
        await provider.releaseLoadGate()
        await olderTask.value

        #expect(viewModel.snapshot(for: changedModel) == nil)
        #expect(viewModel.snapshot(for: changedAccount)?.metrics.first?.value == 9)
        #expect(viewModel.state(for: changedAccount) == .loaded)
    }

    private func request(
        scope: InsightsScope = .starred,
        accountID: Int64 = 1,
        databaseRevision: UInt64 = 0,
        embeddingModel: String = "embed-v1"
    ) -> MyInsightsViewModel.Request {
        .init(scope: scope, accountID: accountID, databaseRevision: databaseRevision, embeddingModel: embeddingModel)
    }

    private func snapshot(
        scope: InsightsScope,
        projects: Int
    ) -> MyInsightsSnapshot {
        MyInsightsSnapshot(
            scope: scope,
            generatedAt: Date(timeIntervalSince1970: 1_000),
            metrics: [
                InsightsMetric(
                    id: "projects",
                    titleKey: "insights.metric.projects",
                    value: projects,
                    detailKey: "insights.metric.projects.detail",
                    systemImage: "star.fill",
                    tintName: "yellow"
                )
            ],
            statusItems: [],
            languageItems: [],
            topicItems: [],
            licenseItems: [],
            actionItems: [],
            healthCoverage: InsightsCoverage(completed: 0, total: projects),
            openSSFCoverage: InsightsCoverage(completed: 0, total: projects),
            assetSummary: InsightsAssetSummary(
                dormantCount: 0,
                archivedCount: 0,
                unavailableCount: 0
            ),
            priorityRepositories: [],
            rhythmPoints: [],
            knowledgeCoverageItems: []
        )
    }
}

/// 暂停指定请求的返回，让测试可验证切换中的可见快照及完成顺序。
private actor MyInsightsProviderStub: MyInsightsSnapshotProviding {
    enum Outcome: Sendable {
        case snapshot(MyInsightsSnapshot)
        case failure
    }

    private var outcomes: [Outcome]
    private(set) var invalidateCount = 0
    private var loadGateEnabled = false
    private var didSignalLoadStart = false
    private var loadStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var loadReleaseContinuation: CheckedContinuation<Void, Never>?

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func setLoadGateEnabled(_ enabled: Bool) {
        loadGateEnabled = enabled
        if !enabled {
            didSignalLoadStart = false
        }
    }

    func waitForLoadStart() async {
        if didSignalLoadStart { return }
        await withCheckedContinuation { continuation in
            loadStartWaiters.append(continuation)
        }
    }

    func releaseLoadGate() {
        loadReleaseContinuation?.resume()
        loadReleaseContinuation = nil
    }

    func load(
        scope: InsightsScope,
        embeddingModel: String
    ) async throws -> MyInsightsSnapshot {
        guard !outcomes.isEmpty else { throw StubError.noOutcome }
        let outcome = outcomes.removeFirst()
        if loadGateEnabled {
            signalLoadStart()
            await withCheckedContinuation { continuation in
                loadReleaseContinuation = continuation
            }
            didSignalLoadStart = false
        }

        switch outcome {
        case .snapshot(let snapshot):
            return snapshot
        case .failure:
            throw StubError.loadFailed
        }
    }

    func invalidate() {
        invalidateCount += 1
    }

    private func signalLoadStart() {
        didSignalLoadStart = true
        let waiters = loadStartWaiters
        loadStartWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private enum StubError: Error {
        case noOutcome
        case loadFailed
    }
}
