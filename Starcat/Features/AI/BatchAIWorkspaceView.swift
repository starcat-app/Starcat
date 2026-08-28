//
//  BatchAIWorkspaceView.swift
//  Starcat
//
//  批量标签生成的固定尺寸工作区。
//
//  SwiftUI 只负责配置、队列状态与审核交互；窗口生命周期和固定尺寸由
//  BatchAIWorkspaceWindowController 持有。启动成功后在同一个窗口内从配置页切换到审核页，
//  避免两个独立 sheet 造成流程割裂，也保证关闭窗口不会终止后台队列。
//

import SwiftUI

struct BatchAIWorkspacePreflightContext {
    let scope: BatchAIRepositoryScope
    let pendingCount: Int
    let skippedTaggedCount: Int

    var usesSelectedRepositories: Bool { scope.isSelectionScoped }
}

enum BatchAIWorkspaceInitialMode {
    case preflight(BatchAIWorkspacePreflightContext)
    case review
}

struct BatchAIWorkspaceView: View {
    @Bindable var service: BatchAIQueueService
    @Binding var options: BatchAIQueueOptions

    let canPrepareCodeContext: Bool
    let hasUsableExternalSearchProvider: Bool
    let onStart: (BatchAIRepositoryScope) async -> Bool
    let onClose: () -> Void

    @State private var mode: BatchAIWorkspaceInitialMode
    @State private var isStarting = false
    @State private var showDiscardConfirmation = false
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    init(
        service: BatchAIQueueService,
        initialMode: BatchAIWorkspaceInitialMode,
        options: Binding<BatchAIQueueOptions>,
        canPrepareCodeContext: Bool,
        hasUsableExternalSearchProvider: Bool,
        onStart: @escaping (BatchAIRepositoryScope) async -> Bool,
        onClose: @escaping () -> Void
    ) {
        self.service = service
        _mode = State(initialValue: initialMode)
        _options = options
        self.canPrepareCodeContext = canPrepareCodeContext
        self.hasUsableExternalSearchProvider = hasUsableExternalSearchProvider
        self.onStart = onStart
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 960, maxWidth: 960, minHeight: 640, maxHeight: 640)
        .clipped()
        .confirmationDialog(
            "batchAI.panel.discard.title",
            isPresented: $showDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("batchAI.panel.discard.action", role: .destructive, action: discardCurrentSession)
            Button("general.cancel", role: .cancel) {}
        } message: {
            Text("batchAI.panel.discard.message")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(interfaceScale.font(.iconLarge))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("batchAI.generateTags.title")
                    .font(interfaceScale.font(.workspaceTitle))
                Text(verbatim: headerSubtitle)
                    .font(interfaceScale.font(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()

            if isReviewMode {
                statusPill
                AIOrganizationTaskControls(
                    isRunning: service.isRunning,
                    isPaused: service.isPaused,
                    isStopping: service.isCancelling,
                    canContinue: false,
                    pauseTitle: "batchAI.panel.pause",
                    resumeTitle: "batchAI.panel.resume",
                    stopTitle: "batchAI.panel.cancel",
                    onPause: service.pause,
                    onResume: service.resume,
                    onContinue: {},
                    onStop: service.cancel,
                    onClose: closeWorkspace
                )
            } else {
                SheetCloseButton(action: closeWorkspace)
                    .disabled(isStarting)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 64)
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .preflight(let context):
            BatchAIOptionsSheet(
                pendingCount: context.pendingCount,
                skippedTaggedCount: context.skippedTaggedCount,
                options: $options,
                canPrepareCodeContext: canPrepareCodeContext,
                hasUsableExternalSearchProvider: hasUsableExternalSearchProvider
            )
        case .review:
            BatchAIQueuePanel(service: service)
        }
    }

    @ViewBuilder
    private var footer: some View {
        Group {
            switch mode {
            case .preflight(let context):
                HStack(spacing: 10) {
                    if let configurationIssue {
                        Label {
                            Text(verbatim: configurationIssue)
                                .lineLimit(2)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .font(interfaceScale.font(.caption))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Label("batchAI.generateTags.action.tags.desc", systemImage: "checkmark.shield")
                            .font(interfaceScale.font(.caption))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button("general.cancel", action: onClose)
                        .keyboardShortcut(.cancelAction)
                        .disabled(isStarting)
                    Button {
                        start(context)
                    } label: {
                        Text(String(
                            format: String.l10n("batchAI.generateTags.startFormat"),
                            context.pendingCount
                        ))
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        isStarting
                            || !options.isValidForStart
                            || context.pendingCount == 0
                            || configurationIssue != nil
                    )
                }
                .padding(.horizontal, 20)
                .frame(height: 58)
            case .review:
                AIOrganizationReviewFooter(
                    discardTitle: "batchAI.panel.discard.action",
                    canDiscard: service.canDiscardCurrentSession,
                    selectionSummary: tagSelectionSummary,
                    canApply: service.selectedTagReviewRepositoryCount > 0,
                    isApplying: service.isApplyingSuggestedTags,
                    onDiscard: { showDiscardConfirmation = true },
                    onApply: {
                        Task { await service.applySelectedTagReviewRepositories() }
                    }
                )
            }
        }
    }

    private var configurationIssue: String? {
        service.configurationIssue(for: options)
    }

    private var isReviewMode: Bool {
        if case .review = mode { true } else { false }
    }

    private var headerSubtitle: String {
        switch mode {
        case .preflight(let context):
            let key = context.usesSelectedRepositories
                ? "batch.selectedCountFormat"
                : "batchAI.options.subtitleFormat"
            return String(format: String.l10n(key), context.pendingCount)
        case .review:
            return String(
                format: String.l10n("batchAI.panel.progressFormat"),
                service.finishedCount,
                service.totalCount
            )
        }
    }

    private var statusPill: some View {
        Label(statusTitle, systemImage: statusIcon)
            .font(interfaceScale.font(.captionStrong))
            .foregroundStyle(statusTint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(statusTint.opacity(0.18), in: .capsule)
    }

    private var tagSelectionSummary: String {
        String(
            format: String.l10n("batch.selectedCountFormat"),
            service.selectedTagReviewRepositoryCount
        )
    }

    private var statusTitle: String {
        if service.isCancelling { return String.l10n("batchAI.panel.cancelling") }
        if service.isPaused { return String.l10n("batchAI.panel.paused") }
        if service.isRunning {
            return String(
                format: String.l10n("batch.progress.processingFormat"),
                service.finishedCount + service.processingJobIDs.count,
                service.totalCount
            )
        }
        if service.hasPendingTagReview { return String.l10n("batchAI.panel.review.pending") }
        if service.isFinished { return String.l10n("batchAI.panel.finished") }
        return String.l10n("batchAI.panel.finished")
    }

    private var statusIcon: String {
        if service.isCancelling { return "stop.fill" }
        if service.isPaused { return "pause.fill" }
        if service.isRunning { return "sparkles" }
        if service.hasPendingTagReview { return "checklist" }
        if service.isFinished { return "checkmark.seal.fill" }
        return "sparkles"
    }

    private var statusTint: Color {
        if service.isCancelling { return .red }
        if service.isPaused { return .orange }
        if service.isRunning { return .accentColor }
        if service.hasPendingTagReview { return .accentColor }
        if service.isFinished { return .green }
        return .accentColor
    }

    private func start(_ context: BatchAIWorkspacePreflightContext) {
        guard !isStarting else { return }
        isStarting = true
        Task {
            let didStart = await onStart(context.scope)
            isStarting = false
            if didStart {
                mode = .review
            }
        }
    }

    private func closeWorkspace() {
        if service.isFinished, !service.hasPendingTagReview {
            service.reset()
        }
        onClose()
    }

    private func discardCurrentSession() {
        guard service.discardCurrentSession() else { return }
        onClose()
    }
}
