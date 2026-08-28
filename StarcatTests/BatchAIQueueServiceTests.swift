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

    @Test("人工模式保留全部标签建议并默认全选")
    func manualRunKeepsSuggestionsForInlineReview() async throws {
        let provider = ImmediateBatchAIInsightProvider(suggestions: Self.sampleSuggestions)
        let database = try InMemoryDatabaseManager()
        let tagRepository = GRDBTagRepository(database: database)
        let repoTagRepository = GRDBRepoTagRepository(database: database)
        let service = makeService(
            insightProvider: provider,
            database: database,
            tagRepository: tagRepository,
            repoTagRepository: repoTagRepository
        )
        var repo = Repo.makeMinimal(owner: "acme", name: "review")
        repo.id = 505
        repo.description = "A compact repository description"
        repo.ownerAvatar = "https://avatars.example.com/acme.png"
        var options = BatchAIQueueOptions()
        options.actions = [.tags]
        options.autoApplyTags = false

        #expect(service.start(repos: [repo], options: options))
        await waitUntilStopped(service)

        let job = try #require(service.jobs.first)
        #expect(job.repoDescription == repo.description)
        #expect(job.ownerAvatarURL == repo.ownerAvatar)
        #expect(job.suggestedTags == Self.sampleSuggestions)
        #expect(job.selectedSuggestedTagIDs == Set(Self.sampleSuggestions.map(\.id)))
        #expect(job.tagReviewState == .pending)
        #expect(service.pendingTagReviewCount == 1)
        #expect(try await repoTagRepository.fetchTags(forRepo: repo.id).isEmpty)
    }

    @Test("摘要上下文开关作为本次任务参数传给 Provider")
    func summaryContextOverridesAreForwardedPerRun() async throws {
        let provider = ImmediateBatchAIInsightProvider(suggestions: [])
        let service = try makeService(insightProvider: provider)
        var repo = Repo.makeMinimal(owner: "acme", name: "summary-context")
        repo.id = 909
        var options = BatchAIQueueOptions()
        options.actions = [.summary]
        options.codeContextEnabledOverride = false
        options.externalContextEnabledOverride = true

        #expect(service.start(repos: [repo], options: options))
        await waitUntilStopped(service)

        #expect(provider.lastCodeContextEnabledOverride == false)
        #expect(provider.lastExternalContextEnabledOverride == true)
    }

    @Test("标签任务按仓库消费并限制为五路并发")
    func tagGenerationUsesBoundedWorkerConcurrency() async throws {
        let provider = ConcurrentBatchAIInsightProvider(delay: .milliseconds(40))
        let service = try makeService(insightProvider: provider)
        let repos = makeRepos(count: 20, startingAt: 1_000)
        var options = BatchAIQueueOptions()
        options.actions = [.tags]

        #expect(service.start(repos: repos, options: options))
        await waitUntilStopped(service)

        #expect(provider.batchSizes.isEmpty)
        #expect(provider.individualCallCount == 20)
        #expect(provider.maximumActiveIndividualCalls == 5)
        #expect(service.jobs.allSatisfy { $0.status == .completed })
        #expect(service.processingJobIDs.isEmpty)
    }

    @Test("Worker 完成仓库后即时写回并继续领取下一项")
    func workerPublishesCompletionBeforeSlowerRequestFinishes() async throws {
        let blockedRepoID: Int64 = 1_101
        let provider = StaggeredBatchAIInsightProvider(blockedRepoID: blockedRepoID)
        let service = try makeService(insightProvider: provider)
        let repos = makeRepos(count: 3, startingAt: 1_100)
        var options = BatchAIQueueOptions()
        options.actions = [.tags]

        #expect(service.start(repos: repos, options: options))
        await provider.waitUntilBlockedCallStarts()
        for _ in 0..<100 where service.finishedCount < 2 {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(service.isRunning)
        #expect(service.finishedCount == 2)
        #expect(service.jobs.first(where: { $0.repoId == blockedRepoID })?.status == .processing)
        #expect(service.jobs.first(where: { $0.repoId == 1_100 })?.status == .completed)
        #expect(service.jobs.first(where: { $0.repoId == 1_102 })?.status == .completed)
        #expect(provider.individualCallCount == 3)

        provider.releaseBlockedCall()
        await waitUntilStopped(service)
        #expect(service.finishedCount == 3)
    }

    @Test("摘要任务保持单仓请求并限制为五路并发")
    func summaryGenerationUsesBoundedIndividualConcurrency() async throws {
        let provider = ConcurrentBatchAIInsightProvider(delay: .milliseconds(40))
        let service = try makeService(insightProvider: provider)
        let repos = makeRepos(count: 5, startingAt: 2_000)
        var options = BatchAIQueueOptions()
        options.actions = [.summary]

        #expect(service.start(repos: repos, options: options))
        await waitUntilStopped(service)

        #expect(provider.batchSizes.isEmpty)
        #expect(provider.individualCallCount == 5)
        #expect(provider.maximumActiveIndividualCalls == 5)
        #expect(service.jobs.allSatisfy { $0.didGenerateSummary })
    }

    @Test("队列展示快照每次渐进加载一百条且保留完整总数")
    func presentationStorePaginatesLargeQueue() async throws {
        let provider = ConcurrentBatchAIInsightProvider(delay: .milliseconds(5))
        let service = try makeService(insightProvider: provider)
        let repos = makeRepos(count: 205, startingAt: 3_000)
        var options = BatchAIQueueOptions()
        options.actions = [.tags]

        #expect(service.start(repos: repos, options: options))
        await waitUntilStopped(service)

        let presentation = BatchAIQueuePresentationStore()
        presentation.synchronizeImmediately(from: service)
        #expect(presentation.totalJobCount == 205)
        #expect(presentation.visibleJobs.count == 100)
        #expect(presentation.canLoadMore)

        presentation.loadMore()
        #expect(presentation.visibleJobs.count == 200)
        presentation.loadMore()
        #expect(presentation.visibleJobs.count == 205)
        #expect(!presentation.canLoadMore)
    }

    @Test("确认只应用用户保留的标签并创建新标签")
    func confirmAppliesOnlySelectedSuggestions() async throws {
        let provider = ImmediateBatchAIInsightProvider(suggestions: Self.sampleSuggestions)
        let database = try InMemoryDatabaseManager()
        let tagRepository = GRDBTagRepository(database: database)
        let repoTagRepository = GRDBRepoTagRepository(database: database)
        let service = makeService(
            insightProvider: provider,
            database: database,
            tagRepository: tagRepository,
            repoTagRepository: repoTagRepository
        )
        var repo = Repo.makeMinimal(owner: "acme", name: "apply")
        repo.id = 606
        // repo_tags 有外键约束；生产环境中的批量输入必然来自 repositories 表，
        // 测试也必须先建立同样的前置状态，避免把 fixture 缺失误判为应用逻辑失败。
        try await database.insertRepoFixture(id: repo.id, owner: "acme", name: "apply")
        var options = BatchAIQueueOptions()
        options.actions = [.tags]

        #expect(service.start(repos: [repo], options: options))
        await waitUntilStopped(service)
        service.toggleSuggestedTag(repoId: repo.id, suggestionID: Self.sampleSuggestions[1].id)
        await service.applySelectedSuggestedTags(repoId: repo.id)

        let tags = try await repoTagRepository.fetchTags(forRepo: repo.id)
        #expect(tags.map(\.name) == ["Swift"])
        #expect(try await tagRepository.fetchAll().map(\.name) == ["Swift"])
        #expect(service.jobs.first?.tagReviewState == .applied)
        #expect(service.pendingTagReviewCount == 0)
    }

    @Test("待确认结果会阻止新批次覆盖直到用户忽略")
    func pendingReviewBlocksReplacementBatch() async throws {
        let provider = ImmediateBatchAIInsightProvider(suggestions: Self.sampleSuggestions)
        let service = try makeService(insightProvider: provider)
        var first = Repo.makeMinimal(owner: "acme", name: "first-review")
        first.id = 707
        var second = Repo.makeMinimal(owner: "acme", name: "second-review")
        second.id = 808
        var options = BatchAIQueueOptions()
        options.actions = [.tags]

        #expect(service.start(repos: [first], options: options))
        await waitUntilStopped(service)
        #expect(!service.start(repos: [second], options: options))

        service.ignoreSuggestedTags(repoId: first.id)
        #expect(service.start(repos: [second], options: options))
        await waitUntilStopped(service)
    }

    @Test("放弃待确认结果后清空会话并允许启动下一批")
    func discardPendingReviewAllowsReplacementBatch() async throws {
        let provider = ImmediateBatchAIInsightProvider(suggestions: Self.sampleSuggestions)
        let service = try makeService(insightProvider: provider)
        var first = Repo.makeMinimal(owner: "acme", name: "discard-first")
        first.id = 810
        var second = Repo.makeMinimal(owner: "acme", name: "discard-second")
        second.id = 811
        var options = BatchAIQueueOptions()
        options.actions = [.tags]

        #expect(service.start(repos: [first], options: options))
        await waitUntilStopped(service)
        #expect(service.hasPendingTagReview)
        #expect(service.canDiscardCurrentSession)

        #expect(service.discardCurrentSession())
        #expect(service.jobs.isEmpty)
        #expect(service.options == nil)
        #expect(!service.hasPendingTagReview)
        #expect(service.start(repos: [second], options: options))
        await waitUntilStopped(service)
    }

    private static let sampleSuggestions = [
        AITagSuggestion(name: "Swift", confidence: 0.96, reason: "主要开发语言"),
        AITagSuggestion(name: "CLI", confidence: 0.82, reason: "提供命令行工具")
    ]

    private func makeRepos(count: Int, startingAt firstID: Int64) -> [Repo] {
        (0..<count).map { offset in
            var repo = Repo.makeMinimal(owner: "acme", name: "repo-\(offset)")
            repo.id = firstID + Int64(offset)
            return repo
        }
    }

    private func makeService(
        insightProvider: any BatchAIInsightProviding
    ) throws -> BatchAIQueueService {
        let database = try InMemoryDatabaseManager()
        return makeService(
            insightProvider: insightProvider,
            database: database,
            tagRepository: GRDBTagRepository(database: database),
            repoTagRepository: GRDBRepoTagRepository(database: database)
        )
    }

    private func makeService(
        insightProvider: any BatchAIInsightProviding,
        database: InMemoryDatabaseManager,
        tagRepository: any TagRepositoryProtocol,
        repoTagRepository: any RepoTagRepositoryProtocol
    ) -> BatchAIQueueService {
        BatchAIQueueService(
            insightService: insightProvider,
            tagRepository: tagRepository,
            repoTagRepository: repoTagRepository,
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

    func generateBatchTagSuggestions(
        for repos: [Repo],
        tagHintsByRepoID: [Int64: AITagHints]
    ) async throws -> [Int64: [AITagSuggestion]] {
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

    func generateBatchInsight(
        for repo: Repo,
        existingTagHints: AITagHints,
        includeSummary: Bool,
        includeTags: Bool,
        codeContextEnabledOverride: Bool?,
        externalContextEnabledOverride: Bool?
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

/// 立即返回固定标签的 Provider，用于验证“生成后审核”与落库边界。
@MainActor
private final class ImmediateBatchAIInsightProvider: BatchAIInsightProviding {
    let suggestions: [AITagSuggestion]
    private(set) var lastCodeContextEnabledOverride: Bool?
    private(set) var lastExternalContextEnabledOverride: Bool?

    init(suggestions: [AITagSuggestion]) {
        self.suggestions = suggestions
    }

    func ensureGenerationClientsReady(includeSummary: Bool, includeTags: Bool) throws {}

    func generateBatchTagSuggestions(
        for repos: [Repo],
        tagHintsByRepoID: [Int64: AITagHints]
    ) async throws -> [Int64: [AITagSuggestion]] {
        Dictionary(uniqueKeysWithValues: repos.map { ($0.id, suggestions) })
    }

    func generateBatchInsight(
        for repo: Repo,
        existingTagHints: AITagHints,
        includeSummary: Bool,
        includeTags: Bool,
        codeContextEnabledOverride: Bool?,
        externalContextEnabledOverride: Bool?
    ) async throws -> RepoAIInsightGeneration {
        lastCodeContextEnabledOverride = codeContextEnabledOverride
        lastExternalContextEnabledOverride = externalContextEnabledOverride
        return RepoAIInsightGeneration(
            insight: RepoAIInsight(
                oneLiner: "",
                summary: "",
                summaryMarkdown: nil,
                platforms: [],
                suitableFor: [],
                strengths: [],
                risks: [],
                minimalExample: nil,
                suggestedTags: includeTags ? suggestions : [],
                model: "test-model",
                generatedAt: ISO8601DateFormatter.shared.string(from: Date()),
                contextMetadata: nil,
                externalContextMarkdown: nil,
                generationContextSettings: nil
            ),
            tagErrorMessage: nil,
            contextDegradationReason: nil,
            externalContextDegradationReason: nil
        )
    }
}

/// 一个仓库保持阻塞、其余仓库立即返回，用于验证 Worker 不会等待慢请求才统一回写。
@MainActor
private final class StaggeredBatchAIInsightProvider: BatchAIInsightProviding {
    private let blockedRepoID: Int64
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var blockedStartWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var individualCallCount = 0

    init(blockedRepoID: Int64) {
        self.blockedRepoID = blockedRepoID
    }

    func ensureGenerationClientsReady(includeSummary: Bool, includeTags: Bool) throws {}

    func generateBatchTagSuggestions(
        for repos: [Repo],
        tagHintsByRepoID: [Int64: AITagHints]
    ) async throws -> [Int64: [AITagSuggestion]] {
        Issue.record("仓库级 Worker 不应调用批量标签接口")
        return [:]
    }

    func generateBatchInsight(
        for repo: Repo,
        existingTagHints: AITagHints,
        includeSummary: Bool,
        includeTags: Bool,
        codeContextEnabledOverride: Bool?,
        externalContextEnabledOverride: Bool?
    ) async throws -> RepoAIInsightGeneration {
        individualCallCount += 1
        if repo.id == blockedRepoID {
            await withCheckedContinuation { continuation in
                blockedContinuation = continuation
                let waiters = blockedStartWaiters
                blockedStartWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
        return RepoAIInsightGeneration(
            insight: RepoAIInsight(
                oneLiner: "",
                summary: "",
                summaryMarkdown: nil,
                platforms: [],
                suitableFor: [],
                strengths: [],
                risks: [],
                minimalExample: nil,
                suggestedTags: [],
                model: "test-model",
                generatedAt: ISO8601DateFormatter.shared.string(from: .now),
                contextMetadata: nil,
                externalContextMarkdown: nil,
                generationContextSettings: nil
            ),
            tagErrorMessage: nil,
            contextDegradationReason: nil,
            externalContextDegradationReason: nil
        )
    }

    func waitUntilBlockedCallStarts() async {
        guard blockedContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            blockedStartWaiters.append(continuation)
        }
    }

    func releaseBlockedCall() {
        blockedContinuation?.resume()
        blockedContinuation = nil
    }
}

/// 记录同时活跃调用数的 Provider，用于验证队列只并发网络阶段、不并发状态写入。
@MainActor
private final class ConcurrentBatchAIInsightProvider: BatchAIInsightProviding {
    private let delay: Duration
    private var activeBatchCalls = 0
    private var activeIndividualCalls = 0

    private(set) var batchSizes: [Int] = []
    private(set) var individualCallCount = 0
    private(set) var maximumActiveBatchCalls = 0
    private(set) var maximumActiveIndividualCalls = 0

    init(delay: Duration) {
        self.delay = delay
    }

    func ensureGenerationClientsReady(includeSummary: Bool, includeTags: Bool) throws {}

    func generateBatchTagSuggestions(
        for repos: [Repo],
        tagHintsByRepoID: [Int64: AITagHints]
    ) async throws -> [Int64: [AITagSuggestion]] {
        batchSizes.append(repos.count)
        activeBatchCalls += 1
        maximumActiveBatchCalls = max(maximumActiveBatchCalls, activeBatchCalls)
        defer { activeBatchCalls -= 1 }
        try await Task.sleep(for: delay)
        return Dictionary(uniqueKeysWithValues: repos.map { ($0.id, []) })
    }

    func generateBatchInsight(
        for repo: Repo,
        existingTagHints: AITagHints,
        includeSummary: Bool,
        includeTags: Bool,
        codeContextEnabledOverride: Bool?,
        externalContextEnabledOverride: Bool?
    ) async throws -> RepoAIInsightGeneration {
        individualCallCount += 1
        activeIndividualCalls += 1
        maximumActiveIndividualCalls = max(maximumActiveIndividualCalls, activeIndividualCalls)
        defer { activeIndividualCalls -= 1 }
        try await Task.sleep(for: delay)
        return RepoAIInsightGeneration(
            insight: RepoAIInsight(
                oneLiner: "",
                summary: "",
                summaryMarkdown: nil,
                platforms: [],
                suitableFor: [],
                strengths: [],
                risks: [],
                minimalExample: nil,
                suggestedTags: [],
                model: "test-model",
                generatedAt: ISO8601DateFormatter.shared.string(from: .now),
                contextMetadata: nil,
                externalContextMarkdown: nil,
                generationContextSettings: nil
            ),
            tagErrorMessage: nil,
            contextDegradationReason: nil,
            externalContextDegradationReason: nil
        )
    }
}
