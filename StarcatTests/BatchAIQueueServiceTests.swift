//
//  BatchAIQueueServiceTests.swift
//  StarcatTests
//
//  批量 AI 整理的取消传播与启动前配置校验测试。
//
//  关键约束：
//  - 用户终止必须取消正在 await 的生成调用，而不是等待 Provider 正常返回；
//  - 配置错误必须在创建 jobs 前拒绝整批，不能扩散成逐仓库失败；
//  - Chat 类任务只接受已验证 Provider 与用户显式选择的可用模型。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Batch AI queue lifecycle")
@MainActor
struct BatchAIQueueServiceTests {

    @Test("终止会取消当前生成并释放队列供下一批启动")
    func cancelStopsInflightGenerationAndAllowsRestart() async throws {
        let provider = BlockingBatchAIInsightProvider()
        let service = try makeService(insightProvider: provider)
        var repo = Repo.makeMinimal(owner: "acme", name: "first")
        repo.id = 101

        #expect(service.start(repos: [repo], options: BatchAIQueueOptions()))
        await provider.waitUntilGenerationStarts()

        service.cancel()
        await waitUntilStopped(service)

        #expect(provider.didObserveCancellation)
        #expect(!service.isRunning)
        #expect(service.jobs.count == 1)
        #expect(service.jobs.first?.status == .failed)
        #expect(service.jobs.first?.failure == .cancelled)

        var nextRepo = Repo.makeMinimal(owner: "acme", name: "second")
        nextRepo.id = 202
        #expect(service.start(repos: [nextRepo], options: BatchAIQueueOptions()))
        service.cancel()
        await waitUntilStopped(service)
    }

    @Test("配置错误在创建 jobs 前拒绝整批")
    func configurationFailureRejectsBatchBeforeEnqueue() throws {
        let provider = BlockingBatchAIInsightProvider()
        provider.validationError = RepoAIInsightError.missingAPIKey
        let service = try makeService(insightProvider: provider)
        var repo = Repo.makeMinimal(owner: "acme", name: "demo")
        repo.id = 303
        let options = BatchAIQueueOptions()

        #expect(service.configurationIssue(for: options) != nil)
        #expect(!service.start(repos: [repo], options: options))
        #expect(service.jobs.isEmpty)
        #expect(!service.isRunning)
        #expect(provider.generationCount == 0)
    }

    @Test("暂停后终止也会完整释放队列")
    func cancelWhilePausedFinalizesWithoutInflightTask() async throws {
        let provider = BlockingBatchAIInsightProvider()
        let service = try makeService(insightProvider: provider)
        var repo = Repo.makeMinimal(owner: "acme", name: "paused")
        repo.id = 404

        #expect(service.start(repos: [repo], options: BatchAIQueueOptions()))
        service.pause()
        // start() 创建的 Task 要先看见暂停并退出，才能覆盖“isRunning 但无 runLoopTask”的边界。
        await Task.yield()
        await Task.yield()

        service.cancel()
        await waitUntilStopped(service)

        #expect(!service.isRunning)
        #expect(service.jobs.isEmpty)
        #expect(provider.generationCount == 0)
    }

    private func makeService(
        insightProvider: any BatchAIInsightProviding
    ) throws -> BatchAIQueueService {
        let database = try InMemoryDatabaseManager()
        return BatchAIQueueService(
            insightService: insightProvider,
            tagRepository: GRDBTagRepository(database: database),
            repoTagRepository: GRDBRepoTagRepository(database: database),
            aiSummaryRepository: GRDBAISummaryRepository(database: database)
        )
    }

    private func waitUntilStopped(_ service: BatchAIQueueService) async {
        for _ in 0..<100 where service.isRunning {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

@Suite("AI chat task selection")
@MainActor
struct AIChatTaskSelectionTests {

    @Test("未验证 Provider 不能用于 Chat 类任务")
    func unverifiedProviderIsRejected() throws {
        let (settings, _, profileID) = try makeSettings(verified: false)
        var task = settings.aiTagsTask
        task.providerID = profileID
        task.modelID = "chat-model"

        #expect(throws: AIChatSelectionError.providerUnavailable) {
            try settings.resolveChatSelection(for: task)
        }
    }

    @Test("没有选择模型时不能用于 Chat 类任务")
    func missingModelIsRejected() throws {
        let (settings, _, profileID) = try makeSettings()
        var task = settings.aiTagsTask
        task.providerID = profileID
        task.modelID = ""
        task.useCustomModel = false

        #expect(throws: AIChatSelectionError.missingModel) {
            try settings.resolveChatSelection(for: task)
        }
    }

    @Test("非 Chat 模型不能用于标签任务")
    func incompatibleModelIsRejected() throws {
        let (settings, _, profileID) = try makeSettings(capability: .embedding)
        var task = settings.aiTagsTask
        task.providerID = profileID
        task.modelID = "chat-model"

        #expect(throws: AIChatSelectionError.incompatibleModel("chat-model")) {
            try settings.resolveChatSelection(for: task)
        }
    }

    @Test("缺少 API Key 时批量预检直接失败")
    func missingAPIKeyFailsGenerationPreflight() throws {
        let (settings, keychain, profileID) = try makeSettings()
        var task = settings.aiTagsTask
        task.providerID = profileID
        task.modelID = "chat-model"
        settings.aiTagsTask = task

        let database = try InMemoryDatabaseManager()
        let service = RepoAIInsightService(
            summaryRepository: GRDBAISummaryRepository(database: database),
            readmeRepository: ReadmeRepository(database: database),
            settings: settings,
            keychain: keychain
        )

        #expect(throws: RepoAIInsightError.missingAPIKey) {
            try service.ensureGenerationClientsReady(includeSummary: false, includeTags: true)
        }
    }

    private func makeSettings(
        verified: Bool = true,
        capability: AIModelCapability = .chat
    ) throws -> (AppSettings, InMemoryKeychain, String) {
        let suiteName = "test.starcat.batch-ai-preflight.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let keychain = InMemoryKeychain()
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        let profileID = "test-provider"
        settings.aiProviderProfiles = [
            AIProviderProfile(
                id: profileID,
                provider: .openAICompatible,
                baseURL: "https://example.com/v1",
                models: [
                    AIModelDescriptor(
                        providerID: profileID,
                        name: "chat-model",
                        capability: capability
                    )
                ],
                lastTestStatus: verified ? .success(modelCount: 1) : .notTested
            )
        ]
        return (settings, keychain, profileID)
    }
}

/// 可控阻塞的批量洞察 Provider：只用于验证父 Task 的取消是否传到 in-flight await。
@MainActor
private final class BlockingBatchAIInsightProvider: BatchAIInsightProviding {
    var validationError: Error?
    private(set) var generationCount = 0
    private(set) var didObserveCancellation = false
    private var generationStartWaiters: [CheckedContinuation<Void, Never>] = []

    func ensureGenerationClientsReady(includeSummary: Bool, includeTags: Bool) throws {
        if let validationError { throw validationError }
    }

    func generateBatchInsight(
        for repo: Repo,
        existingTagHints: AITagHints,
        includeSummary: Bool,
        includeTags: Bool
    ) async throws -> RepoAIInsightGeneration {
        generationCount += 1
        let waiters = generationStartWaiters
        generationStartWaiters.removeAll()
        waiters.forEach { $0.resume() }

        do {
            try await Task.sleep(for: .seconds(30))
        } catch is CancellationError {
            didObserveCancellation = true
            throw CancellationError()
        }
        throw CancellationError()
    }

    func waitUntilGenerationStarts() async {
        guard generationCount == 0 else { return }
        await withCheckedContinuation { continuation in
            generationStartWaiters.append(continuation)
        }
    }
}
