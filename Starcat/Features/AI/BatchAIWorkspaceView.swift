//
//  BatchAIWorkspaceView.swift
//  Starcat
//
//  AI 标签整理的固定尺寸工作区。
//
//  SwiftUI 只负责配置、队列状态与审核交互；窗口生命周期和固定尺寸由
//  BatchAIWorkspaceWindowController 持有。启动成功后在同一个窗口内从配置页切换到审核页，
//  避免两个独立 sheet 造成流程割裂，也保证关闭窗口不会终止后台队列。
//

import SwiftUI
import ThinkingOrbsKit

struct BatchAIWorkspacePreflightContext {
    let scope: BatchAIRepositoryScope
    let pendingCount: Int
    let skippedTaggedCount: Int
    /// 标签库为空时，启动按钮进入纯本地词表引导，不依赖 AI Provider 配置。
    let requiresTaxonomyBootstrap: Bool
}

enum BatchAIWorkspaceInitialMode {
    case preflight(BatchAIWorkspacePreflightContext)
    case taxonomy(TagTaxonomyBootstrapReviewModel)
    case expansion(TagTaxonomyBootstrapReviewModel)
    case review
}

enum BatchAIWorkspaceStartOutcome {
    case reviewStarted
    case taxonomy(TagTaxonomyBootstrapSession)
    case cancelled
    case failed(String?)
}

/// 首次标签体系的准备页。
///
/// 这段本地分析可能需要扫描数千个仓库与 README；必须在用户点击后立即替换预检内容，
/// 明确告诉用户当前阶段。只有逐仓分析阶段展示确定进度，数据库整批读取与候选聚合继续使用
/// 系统不确定进度，避免伪造百分比。
private struct TagTaxonomyBootstrapPreparingView: View {
    let progress: TagTaxonomyBootstrapProgress

    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: BusinessIcon.Symbol.tags.systemImage)
                .font(interfaceScale.font(.iconLarge))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text("batchAI.taxonomy.preparing.title")
                .font(interfaceScale.font(.panelTitle))

            Text(phaseTitleKey)
                .font(interfaceScale.font(.body))
                .foregroundStyle(.secondary)

            if progress.phase == .analyzingRepositories,
               let total = progress.totalRepositoryCount,
               total > 0 {
                ProgressView(
                    value: Double(progress.completedRepositoryCount),
                    total: Double(total)
                )
                .progressViewStyle(.linear)
                .frame(width: 360)

                Text(verbatim: String(
                    format: String.l10n("batchAI.taxonomy.preparing.progressFormat"),
                    progress.completedRepositoryCount,
                    total
                ))
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            } else {
                ProgressView()
                    .controlSize(.large)
            }

            Label("batchAI.taxonomy.preparing.local", systemImage: "lock.shield")
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var phaseTitleKey: LocalizedStringKey {
        switch progress.phase {
        case .loadingLocalData:
            "batchAI.taxonomy.preparing.loadingData"
        case .analyzingRepositories:
            "batchAI.taxonomy.preparing.analyzing"
        case .buildingCandidates:
            "batchAI.taxonomy.preparing.buildingCandidates"
        }
    }
}

struct BatchAIWorkspaceView: View {
    @Bindable var service: BatchAIQueueService
    @Binding var options: BatchAIQueueOptions

    let canPrepareCodeContext: Bool
    let hasUsableExternalSearchProvider: Bool
    let onStart: (
        BatchAIWorkspacePreflightContext,
        @escaping TagTaxonomyBootstrapProgressHandler
    ) async -> BatchAIWorkspaceStartOutcome
    let onConfirmTaxonomy: (TagTaxonomyBootstrapSession, [TagTaxonomyCandidate]) async -> String?
    let onClose: () -> Void

    @State private var mode: BatchAIWorkspaceInitialMode
    @State private var isStarting = false
    @State private var startTask: Task<Void, Never>?
    @State private var startRequestID: UUID?
    @State private var taxonomyPreparationProgress: TagTaxonomyBootstrapProgress?
    @State private var operationError: String?
    @State private var showDiscardConfirmation = false
    @State private var reviewFilter: BatchAIResultFilter = .actionable
    private let originatingPreflightContext: BatchAIWorkspacePreflightContext?
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    /// 预检要读 AI 任务配置；挂上 dependencies 后，设置页改完 Provider / Key 再回工作区会刷新按钮态。
    @Environment(AppDependencies.self) private var dependencies

    init(
        service: BatchAIQueueService,
        initialMode: BatchAIWorkspaceInitialMode,
        options: Binding<BatchAIQueueOptions>,
        canPrepareCodeContext: Bool,
        hasUsableExternalSearchProvider: Bool,
        onStart: @escaping (
            BatchAIWorkspacePreflightContext,
            @escaping TagTaxonomyBootstrapProgressHandler
        ) async -> BatchAIWorkspaceStartOutcome,
        onConfirmTaxonomy: @escaping (
            TagTaxonomyBootstrapSession,
            [TagTaxonomyCandidate]
        ) async -> String?,
        onClose: @escaping () -> Void
    ) {
        self.service = service
        _mode = State(initialValue: initialMode)
        _options = options
        self.canPrepareCodeContext = canPrepareCodeContext
        self.hasUsableExternalSearchProvider = hasUsableExternalSearchProvider
        self.onStart = onStart
        self.onConfirmTaxonomy = onConfirmTaxonomy
        self.onClose = onClose
        if case .preflight(let context) = initialMode {
            self.originatingPreflightContext = context
        } else {
            self.originatingPreflightContext = nil
        }
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
        .frame(width: AIOrganizationLayout.windowSize.width, height: AIOrganizationLayout.windowSize.height)
        .font(interfaceScale.font(.body))
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
        .onAppear(perform: presentPendingExpansionIfNeeded)
        .onChange(of: service.pendingTagExpansionSession) { _, _ in
            presentPendingExpansionIfNeeded()
        }
        .onDisappear {
            // 固定工作区关闭后不再需要首次分析结果；取消还能阻止迟到回调重新写入已销毁窗口状态。
            startRequestID = nil
            startTask?.cancel()
            startTask = nil
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            AIOrganizationIconBadge(
                symbol: BusinessIcon.Symbol.tags.systemImage, tint: .purple, typography: .iconLarge
            )
            VStack(alignment: .leading, spacing: 2) {
                Text("batchAI.organizeTags.title")
                    .font(interfaceScale.font(.panelTitle))
                Text(headerSubtitleKey)
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
        .padding(.horizontal, 14)
        .frame(height: AIOrganizationLayout.headerHeight)
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .preflight(let context):
            if let taxonomyPreparationProgress {
                TagTaxonomyBootstrapPreparingView(progress: taxonomyPreparationProgress)
            } else {
                BatchAIOptionsSheet(
                    pendingCount: context.pendingCount,
                    skippedTaggedCount: context.skippedTaggedCount,
                    options: $options,
                    canPrepareCodeContext: canPrepareCodeContext,
                    hasUsableExternalSearchProvider: hasUsableExternalSearchProvider,
                    requiresTaxonomyBootstrap: context.requiresTaxonomyBootstrap
                )
            }
        case .taxonomy(let model):
            TagTaxonomyBootstrapView(model: model)
        case .expansion(let model):
            TagTaxonomyBootstrapView(model: model)
        case .review:
            VStack(spacing: 0) {
                if let error = service.tagExpansionError {
                    HStack(spacing: 10) {
                        Label {
                            Text(verbatim: error)
                                .lineLimit(2)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .font(interfaceScale.font(.caption))
                        .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("batchAI.expansion.retry") {
                            Task { await service.retryTagExpansionDiscovery() }
                        }
                        .disabled(service.isRunning)
                    }
                    .padding(.horizontal, 20)
                    .frame(minHeight: 42)
                    Divider()
                }
                BatchAIQueuePanel(service: service) { reviewFilter = $0 }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        Group {
            switch mode {
            case .preflight(let context):
                let issue = configurationIssue(for: context)
                HStack(spacing: 10) {
                    if let operationError {
                        Label {
                            Text(verbatim: operationError)
                                .lineLimit(2)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .font(interfaceScale.font(.caption))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else if let issue {
                        Label {
                            Text(verbatim: issue)
                                .lineLimit(2)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .font(interfaceScale.font(.caption))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else if isPreparingTaxonomy {
                        Label("batchAI.taxonomy.preparing.local", systemImage: "lock.shield")
                            .font(interfaceScale.font(.caption))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if context.requiresTaxonomyBootstrap {
                        Label("batchAI.taxonomy.preflight.local", systemImage: "checkmark.shield")
                            .font(interfaceScale.font(.caption))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Label {
                            Text(verbatim: String(
                                format: String.l10n("batchAI.generateTags.action.tags.descFormat"),
                                dependencies.settings.clampedAITagSuggestionCounts.minimum,
                                dependencies.settings.clampedAITagSuggestionCounts.maximum
                            ))
                        } icon: {
                            Image(systemName: "checkmark.shield")
                        }
                            .font(interfaceScale.font(.caption))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button("general.cancel") {
                        if isPreparingTaxonomy {
                            cancelTaxonomyPreparation()
                        } else {
                            onClose()
                        }
                    }
                        .keyboardShortcut(.cancelAction)
                        .disabled(isStarting && !isPreparingTaxonomy)
                    Button {
                        start(context)
                    } label: {
                        if isPreparingTaxonomy {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("batchAI.taxonomy.preparing.action")
                            }
                        } else {
                            Label("batchAI.generateTags.start", systemImage: "sparkles")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        isStarting
                            || !options.isValidForStart
                            || context.pendingCount == 0
                            || issue != nil
                    )
                }
                .controlSize(.regular)
                .padding(.horizontal, 14)
                .frame(height: AIOrganizationLayout.footerHeight)
            case .taxonomy(let model):
                HStack(spacing: 10) {
                    taxonomyFooterMessage(model)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("batchAI.taxonomy.back") {
                        guard let originatingPreflightContext else { return }
                        operationError = nil
                        mode = .preflight(originatingPreflightContext)
                    }
                    .disabled(isStarting || originatingPreflightContext == nil)
                    Button("batchAI.taxonomy.confirm") {
                        confirmTaxonomy(model)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isStarting || !model.hasValidSelection)
                }
                .padding(.horizontal, 14)
                .frame(height: AIOrganizationLayout.footerHeight)
            case .expansion(let model):
                HStack(spacing: 10) {
                    expansionFooterMessage(model)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("batchAI.expansion.skip") {
                        skipExpansion()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isStarting)
                    Button("batchAI.expansion.confirm") {
                        confirmExpansion(model)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isStarting || !model.hasValidSelection)
                }
                .padding(.horizontal, 14)
                .frame(height: AIOrganizationLayout.footerHeight)
            case .review:
                AIOrganizationReviewFooter(
                    discardTitle: "batchAI.panel.discard.action",
                    canDiscard: service.canDiscardCurrentSession,
                    selectionSummary: tagSelectionSummary,
                    canApply: service.selectedTagReviewRepositoryCount > 0,
                    isApplying: service.isApplyingSuggestedTags,
                    showsApplyActions: showsFooterApplyActions,
                    showsSelectionControls: showsFooterSelectionControls,
                    canSelectAll: selectionCanSelectAll,
                    canClearSelection: selectionCanClear,
                    onSelectAll: {
                        if showsBulkActionSelection {
                            service.selectAllReposForBulkAction(filter: reviewFilter)
                        } else {
                            service.selectAllTagReviewRepositories()
                        }
                    },
                    onClearSelection: {
                        if showsBulkActionSelection {
                            service.clearBulkActionSelection()
                        } else {
                            service.clearTagReviewRepositorySelection()
                        }
                    },
                    bulkActionTitle: footerBulkActionTitle,
                    canRunBulkAction: canRunBulkAction,
                    onBulkAction: {
                        Task { await service.applyBulkAction(filter: reviewFilter) }
                    },
                    onDiscard: { showDiscardConfirmation = true },
                    onApply: {
                        Task { await service.applySelectedTagReviewRepositories() }
                    }
                )
            }
        }
    }

    private func configurationIssue(for context: BatchAIWorkspacePreflightContext) -> String? {
        // 空标签库使用本地引导，不应被尚未配置的 LLM / Jev Key 阻塞。
        guard !context.requiresTaxonomyBootstrap else { return nil }
        // 显式读取任务配置与服务商列表，建立对 AppSettings 的观察，避免只改 Key 后底栏仍显示旧预检。
        _ = dependencies.settings.aiTagsTask
        _ = dependencies.settings.aiSummaryTask
        _ = dependencies.settings.aiProviderProfiles
        return service.configurationIssue(for: options)
    }

    @ViewBuilder
    private func taxonomyFooterMessage(_ model: TagTaxonomyBootstrapReviewModel) -> some View {
        if let error = model.operationError ?? operationError {
            Label {
                Text(verbatim: error)
                    .lineLimit(2)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(interfaceScale.font(.caption))
            .foregroundStyle(.secondary)
        } else if !model.hasValidSelection {
            Label("batchAI.taxonomy.validation", systemImage: "exclamationmark.triangle.fill")
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
        } else {
            Label("batchAI.taxonomy.footer", systemImage: "lock.shield")
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func expansionFooterMessage(_ model: TagTaxonomyBootstrapReviewModel) -> some View {
        if let error = model.operationError ?? operationError {
            Label {
                Text(verbatim: error)
                    .lineLimit(2)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(interfaceScale.font(.caption))
            .foregroundStyle(.secondary)
        } else if !model.hasValidSelection {
            Label("batchAI.expansion.validation", systemImage: "exclamationmark.triangle.fill")
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
        } else {
            Label("batchAI.expansion.footer", systemImage: "lock.shield")
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 审核底栏按 Tab 派生

    /// 支持批量动作勾选的 Tab；待确认/全部沿用批量应用勾选，待处理/已完成不参与批量选择。
    private var showsBulkActionSelection: Bool {
        reviewFilter == .failed || reviewFilter == .ignored
    }

    /// 待处理与已完成没有可勾选行，也不该出现隐藏选择的应用按钮，底栏只保留放弃。
    private var showsFooterApplyActions: Bool {
        reviewFilter != .completed && reviewFilter != .actionable
    }

    private var showsFooterSelectionControls: Bool {
        showsFooterApplyActions
    }

    private var footerBulkActionTitle: LocalizedStringKey? {
        guard showsBulkActionSelection else { return nil }
        return switch reviewFilter {
        case .failed: "githubStarLists.aiGrouping.bulkAction.retry"
        case .ignored: "githubStarLists.aiGrouping.bulkAction.unignore"
        default: nil
        }
    }

    private var selectionCanSelectAll: Bool {
        if showsBulkActionSelection {
            return service.bulkActionSelectedCount(for: reviewFilter)
                < service.bulkActionSelectableCount(for: reviewFilter)
        }
        return service.selectedTagReviewRepositoryCount < service.pendingTagReviewCount
    }

    private var selectionCanClear: Bool {
        if showsBulkActionSelection {
            return service.bulkActionSelectedCount(for: reviewFilter) > 0
        }
        return service.selectedTagReviewRepositoryCount > 0
    }

    private var canRunBulkAction: Bool {
        guard service.bulkActionSelectedCount(for: reviewFilter) > 0 else { return false }
        switch reviewFilter {
        case .failed:
            // 与工具栏“重试失败项”同一门槛：取消中和标签落库中禁止；暂停态允许。
            return !service.isCancelling
                && !service.isApplyingSuggestedTags
                && (!service.isRunning || service.isPaused)
        case .ignored:
            return !service.isApplyingSuggestedTags
        default:
            return false
        }
    }

    private var isReviewMode: Bool {
        if case .review = mode { true } else { false }
    }

    private var headerSubtitleKey: LocalizedStringKey {
        if isPreparingTaxonomy { return "batchAI.taxonomy.preparing.subtitle" }
        if case .taxonomy = mode { return "batchAI.taxonomy.subtitle" }
        if case .expansion = mode { return "batchAI.expansion.subtitle" }
        return "batchAI.organizeTags.subtitle.compact"
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            if showsThinkingOrb {
                // running 态用思考球替换 sparkles 图标；其余态仍用 SF Symbol。
                // 思考球内部只读系统 accessibilityReduceMotion，不读 starcatReduceMotion
                //（后者还 OR 了「设置→关闭应用内动画」），所以把偏好通过 paused 传进去补全兜底。
                ThinkingOrb(
                    state: .composing,
                    size: .px20,
                    theme: .auto,
                    paused: reduceMotion
                )
                // 思考球自带 a11y 标签「Composing…」，与本地化 statusTitle 重复，
                // 从无障碍树隐藏，让 Text(statusTitle) 作为唯一状态表述。
                .accessibilityHidden(true)
            } else {
                Image(systemName: statusIcon)
            }
            Text(statusTitle)
        }
        .font(interfaceScale.font(.captionStrong))
        .foregroundStyle(statusTint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(statusTint.opacity(0.18), in: .capsule)
    }

    /// running 且未在取消中才显示思考球。取消中 isRunning 仍为 true
    /// （isCancelling = cancelRequested && isRunning），必须排除，否则停止态也会画成球。
    private var showsThinkingOrb: Bool {
        service.isRunning && !service.isCancelling
    }

    private var tagSelectionSummary: String {
        let count = showsBulkActionSelection
            ? service.bulkActionSelectedCount(for: reviewFilter)
            : service.selectedTagReviewRepositoryCount
        return String(format: String.l10n("batch.selectedCountFormat"), count)
    }

    private var statusTitle: String {
        if service.isCancelling { return String.l10n("batchAI.panel.cancelling") }
        if service.isPaused { return String.l10n("batchAI.panel.paused") }
        if service.isRunning { return String.l10n("batchAI.organizeTags.running") }
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
        let requestID = UUID()
        isStarting = true
        startRequestID = requestID
        taxonomyPreparationProgress = context.requiresTaxonomyBootstrap ? .loadingLocalData : nil
        operationError = nil
        startTask = Task {
            let outcome = await onStart(context) { progress in
                // 用户可能已经取消并重新开始；旧任务的迟到进度不能覆盖新一轮窗口状态。
                guard startRequestID == requestID else { return }
                taxonomyPreparationProgress = progress
            }
            guard startRequestID == requestID, !Task.isCancelled else { return }
            isStarting = false
            startTask = nil
            startRequestID = nil
            taxonomyPreparationProgress = nil
            switch outcome {
            case .reviewStarted:
                mode = .review
            case .taxonomy(let session):
                mode = .taxonomy(TagTaxonomyBootstrapReviewModel(session: session))
            case .cancelled:
                break
            case .failed(let message):
                operationError = message
            }
        }
    }

    private var isPreparingTaxonomy: Bool {
        isStarting && taxonomyPreparationProgress != nil
    }

    private func cancelTaxonomyPreparation() {
        guard isPreparingTaxonomy else { return }
        startRequestID = nil
        startTask?.cancel()
        startTask = nil
        taxonomyPreparationProgress = nil
        isStarting = false
        operationError = nil
    }

    private func confirmTaxonomy(_ model: TagTaxonomyBootstrapReviewModel) {
        guard !isStarting, model.hasValidSelection else { return }
        isStarting = true
        model.operationError = nil
        Task {
            let error = await onConfirmTaxonomy(model.session, model.selectedCandidates)
            isStarting = false
            if let error {
                model.operationError = error
            } else {
                mode = .review
            }
        }
    }

    private func confirmExpansion(_ model: TagTaxonomyBootstrapReviewModel) {
        guard !isStarting, model.hasValidSelection else { return }
        isStarting = true
        model.operationError = nil
        Task {
            let error = await service.confirmPendingTagExpansion(
                selectedCandidates: model.selectedCandidates
            )
            isStarting = false
            if let error {
                model.operationError = error
            } else {
                mode = .review
            }
        }
    }

    private func skipExpansion() {
        guard !isStarting else { return }
        isStarting = true
        Task {
            await service.skipPendingTagExpansion()
            isStarting = false
            operationError = nil
            mode = .review
        }
    }

    private func presentPendingExpansionIfNeeded() {
        guard let session = service.pendingTagExpansionSession else { return }
        if case .expansion = mode { return }
        // 预检与首次建词表属于尚未启动的新任务，不能被旧会话的恢复状态覆盖。
        guard case .review = mode else { return }
        operationError = nil
        mode = .expansion(TagTaxonomyBootstrapReviewModel(session: session))
    }

    private func closeWorkspace() {
        // 会话清理由 WindowController 的统一 dismiss 出口执行，确保系统关闭路径语义一致。
        onClose()
    }

    private func discardCurrentSession() {
        guard service.discardCurrentSession() else { return }
        onClose()
    }
}
