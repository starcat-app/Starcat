//
//  RepoAICodeContextRequestTests.swift
//  StarcatTests
//
//  单仓 AI 摘要“本次跳过代码上下文”的请求级并发语义测试。
//
//  关键约束：
//  - skip 必须取消正在执行的 provider 子任务；
//  - 取消不能向上终止摘要生成，而要收敛成 `.featureDisabled`；
//  - 未点击 skip 时必须原样返回 provider outcome，避免改变正常生成路径；
//  - 摘要会话按 repo 复用，切换详情不能丢失当前仓的运行态。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Repo AI code context request control")
@MainActor
struct RepoAICodeContextRequestTests {

    @Test("开始前跳过时不执行代码上下文操作")
    func skipBeforeResolveBypassesOperation() async throws {
        let request = RepoAICodeContextRequest()
        var didRunOperation = false

        request.skip()
        let outcome = try await request.resolve {
            didRunOperation = true
            return .degraded(.networkUnavailable)
        }

        #expect(!didRunOperation)
        guard case .featureDisabled = outcome else {
            Issue.record("主动跳过应按 featureDisabled 继续摘要生成")
            return
        }
    }

    @Test("执行中跳过会取消子任务并继续摘要生成")
    func skipWhileResolvingCancelsOnlyContextTask() async throws {
        let request = RepoAICodeContextRequest()
        let signal = OperationStartSignal()

        let resolvingTask = Task { @MainActor in
            try await request.resolve {
                await signal.markStarted()
                try await Task.sleep(for: .seconds(30))
                return .degraded(.networkUnavailable)
            }
        }

        await signal.waitUntilStarted()
        request.skip()
        let outcome = try await resolvingTask.value

        guard case .featureDisabled = outcome else {
            Issue.record("取消中的代码上下文任务应降级为本次跳过")
            return
        }
    }

    @Test("未跳过时保留 provider 的正常结果")
    func normalResolutionPreservesOutcome() async throws {
        let request = RepoAICodeContextRequest()
        let outcome = try await request.resolve {
            .degraded(.networkUnavailable)
        }

        guard case .degraded(.networkUnavailable) = outcome else {
            Issue.record("未跳过时不应改写 provider outcome")
            return
        }
    }

    @Test("单仓摘要每个真实代码上下文步骤预留三秒缓冲")
    func contextStepDelayIsThreeSeconds() {
        #expect(RepoAIInsightService.codeContextStepStartDelay == .seconds(3))
    }

    @Test("步骤缓冲可被本次跳过立即取消")
    func contextStepDelayIsCancellable() async throws {
        let task = Task {
            try await RepoAIInsightService.waitBeforeCodeContextStep()
        }

        // 确保 task 已获得一次调度机会，再模拟用户在缓冲期点击「跳过本次」。
        await Task.yield()
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test("两次生成各自独立的 request，旧次跳过不影响新次")
    func skipOnOneRequestDoesNotAffectAnother() async throws {
        let first = RepoAICodeContextRequest()
        let second = RepoAICodeContextRequest()

        first.skip()
        let firstOutcome = try await first.resolve {
            Issue.record("已跳过的 request 不应再执行 operation")
            return .degraded(.networkUnavailable)
        }
        guard case .featureDisabled = firstOutcome else {
            Issue.record("第一次跳过后应返回 featureDisabled")
            return
        }

        var didRunSecond = false
        let secondOutcome = try await second.resolve {
            didRunSecond = true
            return .degraded(.networkUnavailable)
        }

        #expect(didRunSecond)
        guard case .degraded(.networkUnavailable) = secondOutcome else {
            Issue.record("第二次未跳过的 request 应保留 provider 结果")
            return
        }
    }

    @Test("同仓复用摘要会话，不同仓状态互相隔离")
    func insightSessionsAreScopedByRepo() throws {
        let store = try makeInsightSessionStore()

        let firstA = store.viewModel(for: 101)
        let secondA = store.viewModel(for: 101)
        let repoB = store.viewModel(for: 202)

        #expect(firstA === secondA)
        #expect(firstA !== repoB)
    }

    @Test("清空会话后不复用旧用户的摘要状态")
    func clearingInsightSessionsDropsCachedViewModels() async throws {
        let store = try makeInsightSessionStore()
        let oldSession = store.viewModel(for: 101)

        await store.removeAll()
        let newSession = store.viewModel(for: 101)

        #expect(oldSession !== newSession)
    }

    @Test("空闲会话超出上限时按 LRU 淘汰最旧仓")
    func idleSessionsAreEvictedByLRU() throws {
        let store = try makeInsightSessionStore(maxIdleSessionCount: 2)

        let first = store.viewModel(for: 1)
        _ = store.viewModel(for: 2)
        _ = store.viewModel(for: 3)

        #expect(store.retainedSessionCount == 2)
        // 最旧的 1 应被淘汰；再取 1 会得到新实例。
        #expect(store.viewModel(for: 1) !== first)
        #expect(store.retainedSessionCount == 2)
    }

    /// 使用真实内存仓储装配 Store，只验证 session 身份与生命周期，不触发网络或 Keychain。
    private func makeInsightSessionStore(
        maxIdleSessionCount: Int = RepoAIInsightSessionStore.defaultMaxIdleSessionCount
    ) throws -> RepoAIInsightSessionStore {
        let database = try InMemoryDatabaseManager()
        let suiteName = "test.starcat.repo-ai-session.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let keychain = InMemoryKeychain()
        let service = RepoAIInsightService(
            summaryRepository: GRDBAISummaryRepository(database: database),
            readmeRepository: ReadmeRepository(database: database),
            settings: AppSettings(defaults: defaults, keychain: keychain),
            keychain: keychain
        )
        return RepoAIInsightSessionStore(
            service: service,
            tagRepository: GRDBTagRepository(database: database),
            repoTagRepository: GRDBRepoTagRepository(database: database),
            maxIdleSessionCount: maxIdleSessionCount
        )
    }
}

/// 让并发测试等待 operation 确实进入执行态，避免依赖 `Task.yield()` 的调度时序。
private actor OperationStartSignal {
    private var didStart = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        didStart = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
