//
//  MyInsightsViewModelTests.swift
//  StarcatTests
//
//  验证“我的洞察”首屏、刷新失败保留旧值及主动缓存失效状态。
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
            openSSFCoverage: InsightsCoverage(completed: 0, total: projects)
        )
    }
}

private actor MyInsightsProviderStub: MyInsightsSnapshotProviding {
    enum Outcome: Sendable {
        case snapshot(MyInsightsSnapshot)
        case failure
    }

    private var outcomes: [Outcome]
    private(set) var invalidateCount = 0

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func load(
        scope: InsightsScope,
        embeddingModel: String
    ) async throws -> MyInsightsSnapshot {
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

    private enum StubError: Error {
        case noOutcome
        case loadFailed
    }
}
