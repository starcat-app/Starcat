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

    private var generationTask: Task<Void, Never>?
    private var generationID: UUID?

    private(set) var phase: RepoNoteAIGenerationPhase = .idle
    private(set) var stepStates: [RepoNoteAIGenerationStep: RepoNoteAIGenerationStepState]
    private(set) var draftMarkdown = ""
    private(set) var sourceNoteSnapshot = ""
    private(set) var preparedInput: RepoNoteAIGenerationInput?
    private(set) var errorMessageKey: String?
    private(set) var errorDetail: String?

    init(
        readmeProvider: any RepoNoteAIReadmeProviding,
        aiService: any RepoNoteAIDraftGenerating,
        maxReadmeLength: Int = ReadmePreprocessor.defaultMaxLength
    ) {
        self.readmeProvider = readmeProvider
        self.aiService = aiService
        self.maxReadmeLength = maxReadmeLength
        self.stepStates = Self.pendingSteps()
    }

    var currentStep: RepoNoteAIGenerationStep? {
        RepoNoteAIGenerationStep.allCases.first { stepStates[$0] == .running }
    }

    var resolvedStepCount: Int {
        RepoNoteAIGenerationStep.allCases.count { stepStates[$0]?.isResolved == true }
    }

    var isBusy: Bool { phase == .running || phase == .applying }

    var canApplyDraft: Bool {
        phase == .awaitingConfirmation && draftMarkdown.repoNoteNonBlank != nil
    }

    func start(repo: Repo, existingNote: String) {
        cancelCurrentTask(markVisible: false)
        let runID = UUID()
        generationID = runID
        phase = .running
        stepStates = Self.pendingSteps()
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
        stepStates[.awaitingConfirmation] = .completed
        stepStates[.saving] = .running
        phase = .applying
        errorMessageKey = nil
        errorDetail = nil
        return draftMarkdown
    }

    /// 保存失败时恢复到可再次确认的阶段，不丢 AI 草稿。
    func finishApplying(success: Bool) {
        guard phase == .applying else { return }
        if success {
            stepStates[.saving] = .completed
            phase = .completed
            errorMessageKey = nil
            errorDetail = nil
        } else {
            stepStates[.saving] = .failed(messageKey: RepoNoteAIGenerationError.saveFailed.messageKey)
            stepStates[.awaitingConfirmation] = .running
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
            stepStates[.checkingAI] = .completed

            setRunning(.readingReadme)
            let cached = try await readmeProvider.cachedMarkdown(repoID: repo.id)
            try validate(runID)
            stepStates[.readingReadme] = .completed

            let markdown: String
            if let cached {
                markdown = cached
                stepStates[.downloadingReadme] = .skipped
            } else {
                setRunning(.downloadingReadme)
                markdown = try await readmeProvider.downloadMarkdown(for: repo)
                try validate(runID)
                stepStates[.downloadingReadme] = .completed
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
            stepStates[.preparingNote] = .completed

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
            stepStates[.generating] = .completed
            stepStates[.awaitingConfirmation] = .running
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
        stepStates[step] = .running
    }

    private func fail(step: RepoNoteAIGenerationStep, error: Error) {
        let key = (error as? RepoNoteAIGenerationError)?.messageKey ?? "repo.notes.ai.error.generic"
        stepStates[step] = .failed(messageKey: key)
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
            stepStates[currentStep] = .cancelled
        }
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
