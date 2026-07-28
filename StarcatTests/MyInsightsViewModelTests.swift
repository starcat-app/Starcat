//
//  MyInsightsViewModelTests.swift
//  StarcatTests
//
//  验证“我的洞察”首屏、范围切换原地刷新、刷新失败保留旧值及主动缓存失效状态。
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

        await viewModel.load(scope: .starred, embeddingModel: "embed-v1")

        #expect(viewModel.state == .loaded)
        #expect(viewModel.hasContent)
        #expect(viewModel.snapshot.metrics.first?.value == 3)
    }

    @Test("刷新失败保留旧快照并显示 stale")
    func refreshFailureKeepsPreviousSnapshot() async {
        let provider = MyInsightsProviderStub(outcomes: [
            .snapshot(snapshot(scope: .starred, projects: 3)),
            .failure
        ])
        let viewModel = MyInsightsViewModel(provider: provider)
        await viewModel.load(scope: .starred, embeddingModel: "embed-v1")

        await viewModel.refresh(scope: .starred, embeddingModel: "embed-v1")

        #expect(viewModel.state == .stale)
        #expect(viewModel.snapshot.metrics.first?.value == 3)
        #expect(await provider.invalidateCount == 1)
    }

    @Test("切换范围时进入 refreshing 并保留旧快照直到新数据返回")
    func scopeSwitchKeepsSnapshotWhileRefreshing() async {
        let provider = MyInsightsProviderStub(outcomes: [
            .snapshot(snapshot(scope: .starred, projects: 3)),
            .snapshot(snapshot(scope: .knowledge, projects: 9))
        ])
        let viewModel = MyInsightsViewModel(provider: provider)
        await viewModel.load(scope: .starred, embeddingModel: "embed-v1")

        // 仅对第二次 load 开闸门，便于断言中间态仍保留旧快照。
        await provider.setLoadGateEnabled(true)
        let loadTask = Task {
            await viewModel.load(scope: .knowledge, embeddingModel: "embed-v1")
        }

        await provider.waitForLoadStart()
        #expect(viewModel.state == .refreshing)
        #expect(viewModel.isRefreshing)
        #expect(!viewModel.isInitialLoading)
        #expect(viewModel.hasContent)
        #expect(viewModel.snapshot.metrics.first?.value == 3)

        await provider.releaseLoadGate()
        await loadTask.value

        #expect(viewModel.state == .loaded)
        #expect(viewModel.snapshot.scope == .knowledge)
        #expect(viewModel.snapshot.metrics.first?.value == 9)
    }

    @Test("切换范围失败不会继续展示旧范围数字")
    func scopeFailureClearsOldScopeSnapshot() async {
        let provider = MyInsightsProviderStub(outcomes: [
            .snapshot(snapshot(scope: .starred, projects: 3)),
            .failure
        ])
        let viewModel = MyInsightsViewModel(provider: provider)
        await viewModel.load(scope: .starred, embeddingModel: "embed-v1")

        await viewModel.load(scope: .knowledge, embeddingModel: "embed-v1")

        #expect(viewModel.state == .failed)
        #expect(!viewModel.hasContent)
        #expect(viewModel.snapshot.scope == .knowledge)
        #expect(viewModel.snapshot.metrics.isEmpty)
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
            priorityRepositories: []
        )
    }
}

/// 可闸门的 stub：在 `load` 真正返回前让测试断言「仍保留旧快照 + refreshing」。
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
        if loadGateEnabled {
            signalLoadStart()
            await withCheckedContinuation { continuation in
                loadReleaseContinuation = continuation
            }
            didSignalLoadStart = false
        }

        guard !outcomes.isEmpty else {
            throw StubError.noOutcome
        }
        switch outcomes.removeFirst() {
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
