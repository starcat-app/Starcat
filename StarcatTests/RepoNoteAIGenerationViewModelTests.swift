//
//  RepoNoteAIGenerationViewModelTests.swift
//  StarcatTests
//
//  AI 个人笔记七步状态机、README 分支、取消与冲突保护测试。
//

import Foundation
import Testing
@testable import Starcat

@Suite("AI 个人笔记状态机")
@MainActor
struct RepoNoteAIGenerationViewModelTests {

    @Test("本地 README 命中时跳过下载并传入原笔记")
    func cachedReadmeSkipsDownloadAndPreservesNote() async throws {
        let readme = RepoNoteReadmeStub(cached: "# Demo")
        let ai = RepoNoteDraftStub(result: "# 个人笔记")
        let viewModel = RepoNoteAIGenerationViewModel(readmeProvider: readme, aiService: ai)

        viewModel.start(repo: Self.repo, existingNote: "保留我的决策")
        try await waitUntil { viewModel.phase == .awaitingConfirmation }

        #expect(viewModel.stepStates[.downloadingReadme] == .skipped)
        #expect(readme.downloadCount == 0)
        #expect(ai.receivedReadme == "# Demo")
        #expect(ai.receivedNote == "保留我的决策")
        #expect(viewModel.draftMarkdown == "# 个人笔记")
        #expect(viewModel.stepStates[.awaitingConfirmation] == .running)
    }

    @Test("README 缺失时显式走下载步骤")
    func missingReadmeDownloadsMarkdown() async throws {
        let readme = RepoNoteReadmeStub(cached: nil, downloaded: "# Downloaded")
        let viewModel = RepoNoteAIGenerationViewModel(
            readmeProvider: readme,
            aiService: RepoNoteDraftStub(result: "draft")
        )

        viewModel.start(repo: Self.repo, existingNote: "")
        try await waitUntil { viewModel.phase == .awaitingConfirmation }

        #expect(readme.downloadCount == 1)
        #expect(viewModel.stepStates[.downloadingReadme] == .completed)
        #expect(viewModel.preparedInput?.readmeMarkdown == "# Downloaded")
    }

    @Test("AI 预检失败时不读取 README")
    func preflightFailureStopsBeforeReadme() async throws {
        let readme = RepoNoteReadmeStub(cached: "# Demo")
        let ai = RepoNoteDraftStub(result: "draft", readinessError: AIClientError.missingAPIKey)
        let viewModel = RepoNoteAIGenerationViewModel(readmeProvider: readme, aiService: ai)

        viewModel.start(repo: Self.repo, existingNote: "")
        try await waitUntil { viewModel.phase == .failed }

        #expect(viewModel.stepStates[.checkingAI] == .failed(messageKey: "repo.notes.ai.error.generic"))
        #expect(viewModel.errorDetail == AIClientError.missingAPIKey.errorDescription)
        #expect(readme.cacheReadCount == 0)
        #expect(readme.downloadCount == 0)
    }

    @Test("未知底层错误不进入用户可见详情")
    func unknownErrorIsRedacted() async throws {
        let viewModel = RepoNoteAIGenerationViewModel(
            readmeProvider: RepoNoteReadmeStub(cached: nil, downloadError: RepoNoteUnknownError.sensitive),
            aiService: RepoNoteDraftStub(result: "draft")
        )

        viewModel.start(repo: Self.repo, existingNote: "")
        try await waitUntil { viewModel.phase == .failed }

        #expect(viewModel.errorMessageKey == "repo.notes.ai.error.generic")
        #expect(viewModel.errorDetail == nil)
    }

    @Test("README 下载失败精确标记下载步骤")
    func downloadFailureMarksDownloadStep() async throws {
        let readme = RepoNoteReadmeStub(
            cached: nil,
            downloadError: RepoNoteAIGenerationError.readmeNotFound
        )
        let viewModel = RepoNoteAIGenerationViewModel(
            readmeProvider: readme,
            aiService: RepoNoteDraftStub(result: "draft")
        )

        viewModel.start(repo: Self.repo, existingNote: "")
        try await waitUntil { viewModel.phase == .failed }

        #expect(viewModel.stepStates[.downloadingReadme] == .failed(
            messageKey: RepoNoteAIGenerationError.readmeNotFound.messageKey
        ))
    }

    @Test("取消生成会标记当前步骤且不进入确认")
    func cancellationStopsGeneration() async throws {
        let ai = RepoNoteDraftStub(result: "draft", suspendsUntilCancelled: true)
        let viewModel = RepoNoteAIGenerationViewModel(
            readmeProvider: RepoNoteReadmeStub(cached: "# Demo"),
            aiService: ai
        )
        viewModel.start(repo: Self.repo, existingNote: "")
        try await waitUntil { viewModel.currentStep == .generating }

        viewModel.cancel()

        #expect(viewModel.phase == .cancelled)
        #expect(viewModel.stepStates[.generating] == .cancelled)
        #expect(!viewModel.canApplyDraft)
    }

    @Test("步骤耗时运行中增长并在状态解决后冻结")
    func stepDurationAdvancesAndFreezes() async throws {
        let clock = RepoNoteStepClockStub(now: 100)
        let ai = RepoNoteControllableDraftStub()
        let viewModel = RepoNoteAIGenerationViewModel(
            readmeProvider: RepoNoteReadmeStub(cached: "# Demo"),
            aiService: ai,
            now: { clock.now }
        )

        viewModel.start(repo: Self.repo, existingNote: "original")
        try await waitUntil { viewModel.currentStep == .generating }

        clock.advance(by: 2.4)
        #expect(abs((viewModel.elapsedDuration(for: .generating) ?? 0) - 2.4) < 0.001)

        ai.complete(call: 0, snapshot: "AI draft", result: "AI draft")
        try await waitUntil { viewModel.phase == .awaitingConfirmation }
        #expect(abs((viewModel.elapsedDuration(for: .generating) ?? 0) - 2.4) < 0.001)

        clock.advance(by: 3.2)
        #expect(abs((viewModel.elapsedDuration(for: .awaitingConfirmation) ?? 0) - 3.2) < 0.001)
        #expect(viewModel.beginApplying(currentNote: "original") == "AI draft")
        #expect(abs((viewModel.elapsedDuration(for: .awaitingConfirmation) ?? 0) - 3.2) < 0.001)

        clock.advance(by: 0.8)
        viewModel.finishApplying(success: false)
        #expect(abs((viewModel.elapsedDuration(for: .saving) ?? 0) - 0.8) < 0.001)
        #expect(abs((viewModel.elapsedDuration(for: .awaitingConfirmation) ?? -1)) < 0.001)

        clock.advance(by: 1.1)
        #expect(abs((viewModel.elapsedDuration(for: .awaitingConfirmation) ?? 0) - 1.1) < 0.001)

        viewModel.discard()
        #expect(RepoNoteAIGenerationStep.allCases.allSatisfy {
            viewModel.elapsedDuration(for: $0) == nil
        })
    }

    @Test("取消生成会冻结当前步骤耗时")
    func cancellationFreezesCurrentStepDuration() async throws {
        let clock = RepoNoteStepClockStub(now: 20)
        let viewModel = RepoNoteAIGenerationViewModel(
            readmeProvider: RepoNoteReadmeStub(cached: "# Demo"),
            aiService: RepoNoteDraftStub(result: "draft", suspendsUntilCancelled: true),
            now: { clock.now }
        )
        viewModel.start(repo: Self.repo, existingNote: "")
        try await waitUntil { viewModel.currentStep == .generating }

        clock.advance(by: 1.5)
        viewModel.cancel()
        clock.advance(by: 4)

        #expect(abs((viewModel.elapsedDuration(for: .generating) ?? 0) - 1.5) < 0.001)
    }

    @Test("生成期笔记变化时阻止覆盖并保留草稿")
    func changedNoteBlocksApply() async throws {
        let viewModel = RepoNoteAIGenerationViewModel(
            readmeProvider: RepoNoteReadmeStub(cached: "# Demo"),
            aiService: RepoNoteDraftStub(result: "AI draft")
        )
        viewModel.start(repo: Self.repo, existingNote: "original")
        try await waitUntil { viewModel.phase == .awaitingConfirmation }

        let draft = viewModel.beginApplying(currentNote: "user changed")

        #expect(draft == nil)
        #expect(viewModel.phase == .failed)
        #expect(viewModel.draftMarkdown == "AI draft")
        #expect(viewModel.errorMessageKey == RepoNoteAIGenerationError.noteChanged.messageKey)
    }

    @Test("旧生成的迟到回包不能覆盖新草稿")
    func staleGenerationCannotOverwriteNewDraft() async throws {
        let ai = RepoNoteControllableDraftStub()
        let viewModel = RepoNoteAIGenerationViewModel(
            readmeProvider: RepoNoteReadmeStub(cached: "# Demo"),
            aiService: ai
        )

        viewModel.start(repo: Self.repo, existingNote: "first note")
        try await waitUntil { ai.pendingCount == 1 }
        viewModel.start(repo: Self.repo, existingNote: "second note")
        try await waitUntil { ai.pendingCount == 2 }

        ai.complete(call: 1, snapshot: "second draft", result: "second draft")
        try await waitUntil { viewModel.phase == .awaitingConfirmation }
        #expect(viewModel.draftMarkdown == "second draft")
        #expect(viewModel.sourceNoteSnapshot == "second note")

        // 第一次调用不响应 cancellation，直到新生成完成后才回传；generationID 必须拦住它。
        ai.complete(call: 0, snapshot: "late first draft", result: "late first draft")
        await Task.yield()

        #expect(viewModel.phase == .awaitingConfirmation)
        #expect(viewModel.draftMarkdown == "second draft")
        #expect(viewModel.sourceNoteSnapshot == "second note")
    }

    @Test("保存失败后保留草稿并可重试")
    func saveFailureKeepsDraftForRetry() async throws {
        let viewModel = RepoNoteAIGenerationViewModel(
            readmeProvider: RepoNoteReadmeStub(cached: "# Demo"),
            aiService: RepoNoteDraftStub(result: "AI draft")
        )
        viewModel.start(repo: Self.repo, existingNote: "original")
        try await waitUntil { viewModel.phase == .awaitingConfirmation }
        #expect(viewModel.beginApplying(currentNote: "original") == "AI draft")

        viewModel.finishApplying(success: false)

        #expect(viewModel.phase == .awaitingConfirmation)
        #expect(viewModel.draftMarkdown == "AI draft")
        #expect(viewModel.canApplyDraft)
        #expect(viewModel.stepStates[.saving] == .failed(
            messageKey: RepoNoteAIGenerationError.saveFailed.messageKey
        ))
    }

    @Test("切换仓库后可取回原生成会话且保持展开提示")
    func sessionStoreRestoresRunningRepo() async throws {
        let store = RepoNoteAIGenerationSessionStore()
        let running = RepoNoteAIGenerationViewModel(
            readmeProvider: RepoNoteReadmeStub(cached: "# Demo"),
            aiService: RepoNoteDraftStub(result: "draft", suspendsUntilCancelled: true)
        )
        let other = RepoNoteAIGenerationViewModel(
            readmeProvider: RepoNoteReadmeStub(cached: "# Other"),
            aiService: RepoNoteDraftStub(result: "other")
        )

        running.start(repo: Self.repo, existingNote: "")
        try await waitUntil { running.currentStep == .generating }
        store.retain(running, for: Self.repo.id)
        store.retain(other, for: 2)

        let restored = store.session(for: Self.repo.id)
        #expect(restored === running)
        #expect(restored?.shouldExpandNotesOnReturn == true)
        #expect(store.session(for: 2) === other)

        store.removeSession(for: Self.repo.id)
        #expect(store.session(for: Self.repo.id) == nil)
        #expect(store.session(for: 2) === other)
        running.cancel()
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            await Task.yield()
        }
        throw RepoNoteViewModelTestError.timeout
    }

    private static let repo = Repo(
        id: 1,
        owner: "owner",
        name: "demo",
        fullName: "owner/demo",
        description: nil,
        language: "Swift",
        starsCount: 1,
        forksCount: 0,
        watchersCount: 1,
        topics: nil,
        license: nil,
        homepage: nil,
        htmlUrl: "https://github.com/owner/demo",
        cloneUrl: nil,
        sshUrl: nil,
        isPrivate: false,
        isFork: false,
        isArchived: false,
        isStarred: true,
        pushedAt: nil,
        createdAt: nil,
        updatedAt: nil,
        starredAt: nil,
        cachedAt: nil
    )
}

private enum RepoNoteViewModelTestError: Error {
    case timeout
}

private enum RepoNoteUnknownError: Error, LocalizedError {
    case sensitive

    var errorDescription: String? { "provider-response-body-must-not-appear" }
}

@MainActor
private final class RepoNoteReadmeStub: RepoNoteAIReadmeProviding {
    let cached: String?
    let downloaded: String
    let downloadError: Error?
    private(set) var cacheReadCount = 0
    private(set) var downloadCount = 0

    init(cached: String?, downloaded: String = "", downloadError: Error? = nil) {
        self.cached = cached
        self.downloaded = downloaded
        self.downloadError = downloadError
    }

    func cachedMarkdown(repoID: Int64) async throws -> String? {
        cacheReadCount += 1
        return cached
    }

    func downloadMarkdown(for repo: Repo) async throws -> String {
        downloadCount += 1
        if let downloadError { throw downloadError }
        return downloaded
    }
}

@MainActor
private final class RepoNoteDraftStub: RepoNoteAIDraftGenerating {
    let result: String
    let readinessError: Error?
    let suspendsUntilCancelled: Bool
    private(set) var receivedReadme: String?
    private(set) var receivedNote: String?

    init(
        result: String,
        readinessError: Error? = nil,
        suspendsUntilCancelled: Bool = false
    ) {
        self.result = result
        self.readinessError = readinessError
        self.suspendsUntilCancelled = suspendsUntilCancelled
    }

    func ensureNoteGenerationReady() throws {
        if let readinessError { throw readinessError }
    }

    func generateNoteDraft(
        readmeMarkdown: String,
        existingNote: String,
        onDelta: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        receivedReadme = readmeMarkdown
        receivedNote = existingNote
        if suspendsUntilCancelled {
            try await Task.sleep(for: .seconds(60))
        }
        onDelta(result)
        return result
    }
}

/// 不自动响应 Task cancellation 的 AI stub，用来复现第三方 Provider 迟到回包。
@MainActor
private final class RepoNoteControllableDraftStub: RepoNoteAIDraftGenerating {
    private struct PendingCall {
        let onDelta: @MainActor (String) -> Void
        let continuation: CheckedContinuation<String, Error>
    }

    private var pendingCalls: [PendingCall] = []

    var pendingCount: Int { pendingCalls.count }

    func ensureNoteGenerationReady() throws {}

    func generateNoteDraft(
        readmeMarkdown: String,
        existingNote: String,
        onDelta: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            pendingCalls.append(PendingCall(onDelta: onDelta, continuation: continuation))
        }
    }

    func complete(call index: Int, snapshot: String, result: String) {
        let call = pendingCalls[index]
        call.onDelta(snapshot)
        call.continuation.resume(returning: result)
    }
}

/// 不依赖真实 sleep 的单调时钟，让步骤耗时断言可重复。
@MainActor
private final class RepoNoteStepClockStub {
    private(set) var now: TimeInterval

    init(now: TimeInterval) {
        self.now = now
    }

    func advance(by duration: TimeInterval) {
        now += duration
    }
}
