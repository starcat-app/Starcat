//
//  RepoNoteAIGenerationModels.swift
//  Starcat
//
//  AI 个人笔记生成的固定步骤、阶段与输入快照。
//

import Foundation

/// 生成流程的七个固定步骤。raw order 同时是 UI 展示顺序与进度计算契约。
enum RepoNoteAIGenerationStep: Int, CaseIterable, Identifiable, Sendable {
    case checkingAI
    case readingReadme
    case downloadingReadme
    case preparingNote
    case generating
    case awaitingConfirmation
    case saving

    var id: Int { rawValue }

    var titleKey: String {
        switch self {
        case .checkingAI: "repo.notes.ai.step.checkingAI"
        case .readingReadme: "repo.notes.ai.step.readingReadme"
        case .downloadingReadme: "repo.notes.ai.step.downloadingReadme"
        case .preparingNote: "repo.notes.ai.step.preparingNote"
        case .generating: "repo.notes.ai.step.generating"
        case .awaitingConfirmation: "repo.notes.ai.step.awaitingConfirmation"
        case .saving: "repo.notes.ai.step.saving"
        }
    }
}

/// 每一步的可视状态。失败保留稳定 i18n key，技术细节单独存在 ViewModel。
enum RepoNoteAIGenerationStepState: Equatable, Sendable {
    case pending
    case running
    case completed
    case skipped
    case failed(messageKey: String)
    case cancelled

    var isResolved: Bool {
        switch self {
        case .completed, .skipped: true
        case .pending, .running, .failed, .cancelled: false
        }
    }
}

/// 顶层阶段只决定当前允许的操作；不用它反推每个步骤状态。
enum RepoNoteAIGenerationPhase: Equatable, Sendable {
    case idle
    case running
    case awaitingConfirmation
    case applying
    case completed
    case failed
    case cancelled
}

/// 一次生成的冻结输入，确保生成期用户继续编辑时不会偷换上下文。
struct RepoNoteAIGenerationInput: Equatable, Sendable {
    let repoID: Int64
    let readmeMarkdown: String
    let existingNote: String
}

/// ViewModel 只依赖个人笔记需要的两个 AI 能力，方便用假实现验证取消与流式竞态。
@MainActor
protocol RepoNoteAIDraftGenerating: AnyObject {
    func ensureNoteGenerationReady() throws
    func generateNoteDraft(
        readmeMarkdown: String,
        existingNote: String,
        onDelta: @escaping @MainActor (String) -> Void
    ) async throws -> String
}

extension RepoAIInsightService: RepoNoteAIDraftGenerating {}

/// 可诊断且可国际化的本地流程错误。
enum RepoNoteAIGenerationError: Error, LocalizedError, Equatable, Sendable {
    case readmeNotFound
    case readmeEmpty
    case noteChanged
    case saveFailed

    var messageKey: String {
        switch self {
        case .readmeNotFound: "repo.notes.ai.error.readmeNotFound"
        case .readmeEmpty: "repo.notes.ai.error.readmeEmpty"
        case .noteChanged: "repo.notes.ai.error.noteChanged"
        case .saveFailed: "repo.notes.ai.error.saveFailed"
        }
    }

    var errorDescription: String? { String.l10n(messageKey) }
}
