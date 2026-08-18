//
//  RAGLiveAssistantPresentationView.swift
//  Starcat
//
//  RAG 流式助手消息的独立 Observation 边界。
//

import SwiftUI

/// 只订阅当前流式回答所需的高频状态。
///
/// `streamingPresentation` 会随正文 chunk 更新；运行中 Think 已改走 NSTextView 追加，
/// 不再通过 `executionSteps.details` 高频刷新。计时由标签内的局部时钟独立推进。
/// 如果这些读取发生在整个回答中栏的根 View 中，SwiftUI 会同时重算历史消息、输入框和浮层。
/// 独立子 View 让正文刷新停在当前助手消息内，历史 Markdown 继续由稳定的 Equatable 边界复用。
struct RAGLiveAssistantPresentationView: View {
    @Bindable var viewModel: KnowledgeRAGWorkspaceViewModel

    var body: some View {
        Group {
            if let snapshot = viewModel.streamingPresentation {
                RAGStreamingAssistantMessageBlock(
                    snapshot: snapshot,
                    executionTrace: viewModel.executionSteps,
                    livePlanningReasoning: viewModel.liveReasoningSession(kind: .planningReasoning),
                    liveAnswerReasoning: viewModel.liveReasoningSession(kind: .answerReasoning),
                    activityLabel: activityLabel,
                    processingDuration: viewModel.answerElapsedDuration,
                    processingStartedAt: viewModel.answerStartedAt
                )
            } else if shouldShowFallback {
                RAGAssistantMessageBlock(
                    content: viewModel.streamingAnswer,
                    citations: [],
                    createdAtLabel: nil,
                    showsActions: false,
                    executionTrace: viewModel.executionSteps,
                    livePlanningReasoning: viewModel.liveReasoningSession(kind: .planningReasoning),
                    liveAnswerReasoning: viewModel.liveReasoningSession(kind: .answerReasoning),
                    activityLabel: activityLabel,
                    processingDuration: viewModel.answerElapsedDuration,
                    processingStartedAt: viewModel.answerStartedAt,
                    suggestedActions: [],
                    onSelectCitation: { _ in },
                    onSuggestedAction: { viewModel.sendSuggestedQuestion($0) },
                    onExport: { viewModel.exportAnswer(viewModel.streamingAnswer) }
                )
            }
        }
    }

    /// 没有快照时只在确有运行态或取消/失败的完整兜底正文时建立消息块。
    private var shouldShowFallback: Bool {
        viewModel.isAnswering
            || !viewModel.executionSteps.isEmpty
            || !viewModel.streamingAnswer.isEmpty
    }

    /// 思考、检索等步骤本身已有状态行；只有尚无运行步骤或正在生成正文时补充活动文案。
    private var activityLabel: String? {
        guard viewModel.isAnswering else { return nil }
        guard let runningStep = viewModel.executionSteps.last(where: { $0.state == .running }) else {
            return Self.stateText(viewModel.answerState)
        }
        return runningStep.kind == .generation ? Self.stateText(viewModel.answerState) : nil
    }

    private static func stateText(_ state: RAGAnswerState) -> String {
        switch state {
        case .idle, .completed: return String.l10n("rag.workspace.header.ready")
        case .planning: return String.l10n("rag.workspace.state.planning")
        case .needsClarification: return String.l10n("rag.workspace.state.needsClarification")
        case .noKnowledgeRepos: return String.l10n("rag.workspace.state.noKnowledgeRepos")
        case .noCandidates: return String.l10n("rag.workspace.state.noCandidates")
        case .noIndex: return String.l10n("rag.workspace.state.noIndex")
        case .noRelevantChunks: return String.l10n("rag.workspace.state.noRelevantChunks")
        case .retrieving: return String.l10n("rag.workspace.state.retrieving")
        case .awaitingRemoteContextConfirmation: return String.l10n("rag.workspace.state.awaitingRemote")
        case .fetchingRemoteContext: return String.l10n("rag.workspace.state.fetchingRemote")
        case .generating: return String.l10n("rag.workspace.state.generating")
        case .cancelled: return String.l10n("rag.workspace.state.cancelled")
        case .failed(let message): return message
        }
    }
}
