//
//  RepoNoteAIGenerationViewModel.swift
//  Starcat
//
//  AI 个人笔记生成的 README 准备适配器与七步状态机。
//

import Foundation
import Observation

/// README 读取与下载被拆成两个能力，让 UI 能如实显示“本地命中”或“下载”。
@MainActor
protocol RepoNoteAIReadmeProviding: AnyObject {
    func cachedMarkdown(repoID: Int64) async throws -> String?
    func downloadMarkdown(for repo: Repo) async throws -> String
}

/// 生产 README 适配器：仅读取 `readme_contents.content`，不把渲染 HTML 当 AI 输入。
@MainActor
final class RepoNoteAIReadmeProvider: RepoNoteAIReadmeProviding {
    private let repository: ReadmeRepository
    private let readmeAPI: ReadmeAPI

    init(repository: ReadmeRepository, readmeAPI: ReadmeAPI) {
        self.repository = repository
        self.readmeAPI = readmeAPI
    }

    func cachedMarkdown(repoID: Int64) async throws -> String? {
        try await repository.findContent(repoId: repoID)?.repoNoteNonBlank
    }

    func downloadMarkdown(for repo: Repo) async throws -> String {
        // Markdown 下载路径要求先有 readmes 主行；首次打开详情时可能尚未建立。
        if try await repository.find(repoId: repo.id) == nil {
            try Self.requireUsable(await readmeAPI.refreshReadme(for: repo))
        }
        try Self.requireUsable(await readmeAPI.refreshMarkdownIfNeeded(for: repo))

        guard let markdown = try await repository.findContent(repoId: repo.id)?.repoNoteNonBlank else {
            throw RepoNoteAIGenerationError.readmeEmpty
        }
        return markdown
    }

    private static func requireUsable(_ result: ReadmeRefreshResult) throws {
        switch result {
        case .updated, .notModified:
            return
        case .notFound:
            throw RepoNoteAIGenerationError.readmeNotFound
        case .failed(let error):
            throw error
        }
    }
}

/// 七步流程的唯一状态写入者。
///
/// `generationID` 与 `Task` 取消必须同时使用：某些第三方流式 Provider 不会立刻
/// 响应父 Task 取消，只靠 cancellation 无法阻止迟到 delta 回写新仓库 UI。
@MainActor
@Observable
final class RepoNoteAIGenerationViewModel {
    private let readmeProvider: any RepoNoteAIReadmeProviding
    private let aiService: any RepoNoteAIDraftGenerating
    private let maxReadmeLength: Int
    /// 使用单调时间源避免系统校时让步骤耗时跳变；注入闭包便于单测精确推进时间。
    private let now: @MainActor () -> TimeInterval

    private var generationTask: Task<Void, Never>?
    private var generationID: UUID?

    private(set) var phase: RepoNoteAIGenerationPhase = .idle
    private(set) var stepStates: [RepoNoteAIGenerationStep: RepoNoteAIGenerationStepState]
    private(set) var draftMarkdown = ""
    private(set) var sourceNoteSnapshot = ""
    private(set) var preparedInput: RepoNoteAIGenerationInput?
    private(set) var errorMessageKey: String?
    private(set) var errorDetail: String?
    /// running 步骤的单调起点；步骤解决后移入 `stepDurations`。
    private(set) var stepStartedAt: [RepoNoteAIGenerationStep: TimeInterval] = [:]
    /// 已解决步骤的冻结耗时，折叠面板或切换 repo 不会丢失。
    private(set) var stepDurations: [RepoNoteAIGenerationStep: TimeInterval] = [:]

    init(
        readmeProvider: any RepoNoteAIReadmeProviding,
        aiService: any RepoNoteAIDraftGenerating,
        maxReadmeLength: Int = ReadmePreprocessor.defaultMaxLength,
        now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.readmeProvider = readmeProvider
        self.aiService = aiService
        self.maxReadmeLength = maxReadmeLength
        self.now = now
        self.stepStates = Self.pendingSteps()
    }

    var currentStep: RepoNoteAIGenerationStep? {
        RepoNoteAIGenerationStep.allCases.first { stepStates[$0] == .running }
    }

    var resolvedStepCount: Int {
        RepoNoteAIGenerationStep.allCases.count { stepStates[$0]?.isResolved == true }
    }

    var isBusy: Bool { phase == .running || phase == .applying }

    /// 切回仓库时，仍需用户关注的会话应自动展开笔记区域。
    /// `completed` 已经把草稿写入编辑器，无需强制展开；其余非 idle 状态都需要露出结果或错误。
    var shouldExpandNotesOnReturn: Bool {
        switch phase {
        case .running, .awaitingConfirmation, .applying, .failed, .cancelled:
            true
        case .idle, .completed:
            false
        }
    }

    var canApplyDraft: Bool {
        phase == .awaitingConfirmation && draftMarkdown.repoNoteNonBlank != nil
    }

    /// 返回已冻结或正在增长的步骤耗时。pending / skipped 没有虚假 0 秒。
    func elapsedDuration(for step: RepoNoteAIGenerationStep) -> TimeInterval? {
        if let duration = stepDurations[step] {
            return duration
        }
        guard stepStates[step] == .running, let startedAt = stepStartedAt[step] else {
            return nil
        }
        return max(0, now() - startedAt)
    }

    func start(repo: Repo, existingNote: String) {
        cancelCurrentTask(markVisible: false)
        let runID = UUID()
        generationID = runID
        phase = .running
        stepStates = Self.pendingSteps()
        resetStepTimings()
        draftMarkdown = ""
        sourceNoteSnapshot = existingNote
        preparedInput = nil
        errorMessageKey = nil
        errorDetail = nil

        generationTask = Task { [weak self] in
            await self?.run(repo: repo, existingNote: existingNote, runID: runID)
        }
    }

    /// 取消保留已生成草稿供复制，但不允许继续应用。
    func cancel() {
        cancelCurrentTask(markVisible: true)
    }

    /// 放弃后回到干净 idle，用于切换仓库或用户明确关闭草稿。
    func discard() {
        cancelCurrentTask(markVisible: false)
        phase = .idle
        stepStates = Self.pendingSteps()
        resetStepTimings()
        draftMarkdown = ""
        sourceNoteSnapshot = ""
        preparedInput = nil
        errorMessageKey = nil
        errorDetail = nil
    }

    /// 进入保存前再比对编辑 buffer，避免生成期的手工输入被草稿覆盖。
    func beginApplying(currentNote: String) -> String? {
        guard canApplyDraft else { return nil }
        guard currentNote == sourceNoteSnapshot else {
            fail(step: .awaitingConfirmation, error: RepoNoteAIGenerationError.noteChanged)
            return nil
        }
        setStepState(.completed, for: .awaitingConfirmation)
        setStepState(.running, for: .saving)
        phase = .applying
        errorMessageKey = nil
        errorDetail = nil
        return draftMarkdown
    }

    /// 保存失败时恢复到可再次确认的阶段，不丢 AI 草稿。
    func finishApplying(success: Bool) {
        guard phase == .applying else { return }
        if success {
            setStepState(.completed, for: .saving)
            phase = .completed
            errorMessageKey = nil
            errorDetail = nil
        } else {
            setStepState(
                .failed(messageKey: RepoNoteAIGenerationError.saveFailed.messageKey),
                for: .saving
            )
            setStepState(.running, for: .awaitingConfirmation)
            phase = .awaitingConfirmation
            errorMessageKey = RepoNoteAIGenerationError.saveFailed.messageKey
            errorDetail = RepoNoteAIGenerationError.saveFailed.localizedDescription
        }
    }

    private func run(repo: Repo, existingNote: String, runID: UUID) async {
        do {
            setRunning(.checkingAI)
            try aiService.ensureNoteGenerationReady()
            try validate(runID)
            setStepState(.completed, for: .checkingAI)

            setRunning(.readingReadme)
            let cached = try await readmeProvider.cachedMarkdown(repoID: repo.id)
            try validate(runID)
            setStepState(.completed, for: .readingReadme)

            let markdown: String
            if let cached {
                markdown = cached
                setStepState(.skipped, for: .downloadingReadme)
            } else {
                setRunning(.downloadingReadme)
                markdown = try await readmeProvider.downloadMarkdown(for: repo)
                try validate(runID)
                setStepState(.completed, for: .downloadingReadme)
            }

            setRunning(.preparingNote)
            let processed = ReadmePreprocessor.process(markdown: markdown, maxLength: maxReadmeLength)
            guard let preparedMarkdown = processed.repoNoteNonBlank else {
                throw RepoNoteAIGenerationError.readmeEmpty
            }
            let input = RepoNoteAIGenerationInput(
                repoID: repo.id,
                readmeMarkdown: preparedMarkdown,
                existingNote: existingNote
            )
            preparedInput = input
            sourceNoteSnapshot = existingNote
            setStepState(.completed, for: .preparingNote)

            setRunning(.generating)
            let final = try await aiService.generateNoteDraft(
                readmeMarkdown: input.readmeMarkdown,
                existingNote: input.existingNote
            ) { [weak self] snapshot in
                guard let self, self.generationID == runID else { return }
                self.draftMarkdown = snapshot
            }
            try validate(runID)
            guard let final = final.repoNoteNonBlank else { throw AIClientError.emptyResponse }
            draftMarkdown = final
            setStepState(.completed, for: .generating)
            setStepState(.running, for: .awaitingConfirmation)
            phase = .awaitingConfirmation
            generationTask = nil
        } catch is CancellationError {
            // 显式 cancel 已经同步标记 UI；旧 runID 不允许再写任何状态。
            guard generationID == runID else { return }
            markCurrentStepCancelled()
            phase = .cancelled
            generationTask = nil
        } catch {
            guard generationID == runID else { return }
            let failedStep = currentStep ?? .generating
            fail(step: failedStep, error: error)
            generationTask = nil
        }
    }

    private func validate(_ runID: UUID) throws {
        try Task.checkCancellation()
        guard generationID == runID else { throw CancellationError() }
    }

    private func setRunning(_ step: RepoNoteAIGenerationStep) {
        setStepState(.running, for: step)
    }

    private func fail(step: RepoNoteAIGenerationStep, error: Error) {
        let key = (error as? RepoNoteAIGenerationError)?.messageKey ?? "repo.notes.ai.error.generic"
        setStepState(.failed(messageKey: key), for: step)
        phase = .failed
        errorMessageKey = key
        errorDetail = Self.userFacingDetail(for: error)
    }

    /// 只把经过本项目审计、明确提供用户文案的错误类型送到 UI。
    /// 未知底层错误可能包含数据库路径、HTTP 响应片段或 SDK dump，只显示通用 i18n 错误。
    private static func userFacingDetail(for error: Error) -> String? {
        switch error {
        case let error as RepoNoteAIGenerationError:
            return error.errorDescription
        case let error as RepoAIInsightError:
            return error.errorDescription
        case let error as AIClientError:
            return error.errorDescription
        case let error as EntitlementGateError:
            return error.errorDescription
        default:
            return nil
        }
    }

    private func cancelCurrentTask(markVisible: Bool) {
        generationTask?.cancel()
        generationTask = nil
        generationID = nil
        if markVisible, phase == .running {
            markCurrentStepCancelled()
            phase = .cancelled
        }
    }

    private func markCurrentStepCancelled() {
        if let currentStep {
            setStepState(.cancelled, for: currentStep)
        }
    }

    /// 统一收口步骤状态和计时，避免失败 / 取消 / 保存重试分别漏掉冻结逻辑。
    private func setStepState(
        _ state: RepoNoteAIGenerationStepState,
        for step: RepoNoteAIGenerationStep
    ) {
        let previousState = stepStates[step]

        if previousState == .running, state != .running,
           let startedAt = stepStartedAt.removeValue(forKey: step) {
            stepDurations[step] = max(0, now() - startedAt)
        }

        if state == .running, previousState != .running {
            stepDurations.removeValue(forKey: step)
            stepStartedAt[step] = now()
        }

        stepStates[step] = state
    }

    private func resetStepTimings() {
        stepStartedAt.removeAll(keepingCapacity: true)
        stepDurations.removeAll(keepingCapacity: true)
    }

    private static func pendingSteps() -> [RepoNoteAIGenerationStep: RepoNoteAIGenerationStepState] {
        Dictionary(uniqueKeysWithValues: RepoNoteAIGenerationStep.allCases.map { ($0, .pending) })
    }
}

private extension String {
    var repoNoteNonBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
