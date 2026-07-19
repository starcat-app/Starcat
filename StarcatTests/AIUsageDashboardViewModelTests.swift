//
//  AIUsageDashboardViewModelTests.swift
//  StarcatTests
//
//  验证 AI 用量面板的加载、错误、取消与并发请求代际保护。
//

import Foundation
import Testing
@testable import Starcat

@Suite("AI 用量面板状态")
@MainActor
struct AIUsageDashboardViewModelTests {

    @Test("成功加载更新快照并结束 loading")
    func successfulReload() async throws {
        let repository = ControllableAIUsageRepository()
        let viewModel = AIUsageDashboardViewModel(repository: repository)
        let task = Task { await viewModel.reload() }
        try await waitForPendingCallCount(1, repository: repository)

        await repository.succeed(call: 0, with: Self.snapshot(totalTokens: 120))
        await task.value

        #expect(viewModel.snapshot.summary.totalTokens == 120)
        #expect(!viewModel.isLoading)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("失败展示错误且结束 loading")
    func failedReload() async throws {
        let repository = ControllableAIUsageRepository()
        let viewModel = AIUsageDashboardViewModel(repository: repository)
        let task = Task { await viewModel.reload() }
        try await waitForPendingCallCount(1, repository: repository)

        await repository.fail(call: 0, with: TestFailure.expected)
        await task.value

        #expect(viewModel.errorMessage != nil)
        #expect(!viewModel.isLoading)
    }

    @Test("当前加载取消后不展示错误并结束 loading")
    func cancelledReload() async throws {
        let repository = ControllableAIUsageRepository()
        let viewModel = AIUsageDashboardViewModel(repository: repository)
        let task = Task { await viewModel.reload() }
        try await waitForPendingCallCount(1, repository: repository)

        await repository.fail(call: 0, with: CancellationError())
        await task.value

        #expect(viewModel.errorMessage == nil)
        #expect(!viewModel.isLoading)
    }

    @Test("旧筛选请求晚返回时不覆盖新快照")
    func staleReloadDoesNotOverrideLatestSnapshot() async throws {
        let repository = ControllableAIUsageRepository()
        let viewModel = AIUsageDashboardViewModel(repository: repository)
        let oldTask = Task { await viewModel.reload() }
        try await waitForPendingCallCount(1, repository: repository)

        viewModel.filter.model = "new-model"
        let newTask = Task { await viewModel.reload() }
        try await waitForPendingCallCount(2, repository: repository)

        await repository.succeed(call: 1, with: Self.snapshot(totalTokens: 220))
        await newTask.value
        await repository.succeed(call: 0, with: Self.snapshot(totalTokens: 110))
        await oldTask.value

        #expect(viewModel.snapshot.summary.totalTokens == 220)
        #expect(!viewModel.isLoading)
    }

    private func waitForPendingCallCount(
        _ expectedCount: Int,
        repository: ControllableAIUsageRepository
    ) async throws {
        for _ in 0..<200 {
            if await repository.pendingCallCount >= expectedCount { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("等待 Repository 收到第 \(expectedCount) 个统计请求超时")
    }

    private static func snapshot(totalTokens: Int) -> AIUsageStatisticsSnapshot {
        var snapshot = AIUsageStatisticsSnapshot.empty
        snapshot.summary.totalTokens = totalTokens
        snapshot.summary.callCount = 1
        return snapshot
    }
}

private enum TestFailure: Error {
    case expected
}

/// 通过显式恢复 continuation 精确控制请求返回顺序，避免并发测试依赖真实时间竞争。
private actor ControllableAIUsageRepository: AIUsageRepositoryProtocol {
    private var pendingCalls: [CheckedContinuation<AIUsageStatisticsSnapshot, any Error>?] = []

    var pendingCallCount: Int { pendingCalls.count }

    func insert(_ event: AIUsageEvent) async throws {}

    func fetchRecent(limit: Int) async throws -> [AIUsageEvent] { [] }

    func summary(
        filter: AIUsageFilter,
        now: Date,
        calendar: Calendar
    ) async throws -> AIUsageSummary { .empty }

    func statistics(
        filter: AIUsageFilter,
        now: Date,
        calendar: Calendar,
        recentLimit: Int
    ) async throws -> AIUsageStatisticsSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            pendingCalls.append(continuation)
        }
    }

    func succeed(call index: Int, with snapshot: AIUsageStatisticsSnapshot) {
        takeContinuation(at: index)?.resume(returning: snapshot)
    }

    func fail(call index: Int, with error: any Error) {
        takeContinuation(at: index)?.resume(throwing: error)
    }

    private func takeContinuation(
        at index: Int
    ) -> CheckedContinuation<AIUsageStatisticsSnapshot, any Error>? {
        guard pendingCalls.indices.contains(index) else {
            Issue.record("不存在第 \(index) 个待恢复的统计请求")
            return nil
        }
        defer { pendingCalls[index] = nil }
        return pendingCalls[index]
    }
}
