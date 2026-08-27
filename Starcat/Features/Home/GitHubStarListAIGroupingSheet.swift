//
//  GitHubStarListAIGroupingSheet.swift
//  Starcat
//
//  GitHub Lists AI 分组的人工审核窗口。
//
//  页面默认只展示待处理结果，并通过缓存快照、搜索防抖和 100 条渐进加载承载大库。
//  每个仓库的选择始终是 List ID 集合，一个项目可以同时加入多个用户已创建的分组。
//

import SwiftUI

struct GitHubStarListAIGroupingSheet: View {
    let session: GitHubStarListAIGroupingSession
    let autoGroupingSettings: GitHubStarListAutoGroupingSettings
    let onApplied: @MainActor () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var presentation = GitHubStarListAIGroupingPresentationStore()
    @State private var showApplyConfirmation = false
    @State private var showDiscardConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 880, height: 640)
        .task {
            session.onMembershipsChanged = {
                Task { await onApplied() }
            }
            await session.prepareManualContext()
            presentation.synchronizeImmediately(from: session)
        }
        .onChange(of: session.presentationRevision) { _, _ in
            presentation.scheduleSynchronize(from: session)
        }
        .onDisappear {
            session.releaseManualContextIfUnused()
        }
        .confirmationDialog(
            "githubStarLists.aiGrouping.applyConfirm.title",
            isPresented: $showApplyConfirmation,
            titleVisibility: .visible
        ) {
            Button("action.apply") { session.applySelected() }
            Button("general.cancel", role: .cancel) {}
        } message: {
            Text(String(
                format: String.l10n("githubStarLists.aiGrouping.applyConfirm.messageFormat"),
                presentation.snapshot.selectedRepositoryCount,
                presentation.snapshot.selectedListCount
            ))
        }
        .confirmationDialog(
            "githubStarLists.aiGrouping.discard.title",
            isPresented: $showDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("githubStarLists.aiGrouping.discard.action", role: .destructive) {
                session.discardManualSession()
                Task {
                    await session.prepareManualContext()
                    presentation.synchronizeImmediately(from: session)
                }
            }
            Button("general.cancel", role: .cancel) {}
        } message: {
            Text("githubStarLists.aiGrouping.discard.message")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title3)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("githubStarLists.aiGrouping.title")
                    .font(.headline)
                Text("githubStarLists.aiGrouping.subtitle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(progressTitleKey, systemImage: progressStatusIcon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.quaternary, in: .capsule)
            SheetCloseButton { dismiss() }
        }
        .padding(.horizontal, 20)
        .frame(height: 64)
    }

    @ViewBuilder
    private var content: some View {
        if session.isLoadingContext || !presentation.isReady {
            loadingState
        } else if let message = session.contextErrorMessage {
            ContentUnavailableView(
                "githubStarLists.aiGrouping.loadFailed",
                systemImage: "exclamationmark.triangle",
                description: Text(verbatim: message)
            )
        } else if presentation.snapshot.totalCount == 0 {
            GitHubStarListAIGroupingPreflightView(
                snapshot: presentation.snapshot,
                autoGroupingSettings: autoGroupingSettings
            )
        } else {
            reviewWorkspace
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("githubStarLists.aiGrouping.preparing")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var reviewWorkspace: some View {
        VStack(spacing: 0) {
            progressSummary
            Divider()
            resultToolbar
            Divider()
            GitHubStarListAIGroupingResultList(
                items: presentation.visibleItems,
                searchText: presentation.searchText,
                availableLists: presentation.snapshot.availableLists,
                onToggleList: session.toggleSelection,
                onSelectAllSuggestions: session.selectAllSuggestions,
                onClearSelection: session.clearSelection,
                onIgnore: session.ignore,
                onRetryAnalysis: session.retryAnalysis,
                onRetryApply: session.retryApply,
                onLoadMore: presentation.loadMore
            )
        }
    }

    private var progressSummary: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(progressTitleKey)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(String(
                    format: String.l10n("githubStarLists.aiGrouping.progressFormat"),
                    presentation.snapshot.analyzedCount,
                    presentation.snapshot.totalCount
                ))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            ProgressView(
                value: Double(presentation.snapshot.analyzedCount),
                total: Double(max(presentation.snapshot.totalCount, 1))
            )
            HStack(spacing: 22) {
                metricButton(
                    "githubStarLists.aiGrouping.metric.suggested",
                    value: presentation.snapshot.suggestionCount,
                    icon: "sparkles",
                    filter: .suggestions
                )
                metricButton(
                    "githubStarLists.aiGrouping.metric.noMatch",
                    value: presentation.snapshot.noMatchCount,
                    icon: "minus.circle",
                    filter: .noMatch
                )
                metricButton(
                    "githubStarLists.aiGrouping.filter.analysisFailed",
                    value: presentation.snapshot.analysisFailedCount,
                    icon: "exclamationmark.triangle",
                    filter: .analysisFailed
                )
                metricButton(
                    "githubStarLists.aiGrouping.filter.applyFailed",
                    value: presentation.snapshot.applyFailedCount,
                    icon: "icloud.slash",
                    filter: .applyFailed
                )
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
    }

    private var resultToolbar: some View {
        @Bindable var store = presentation
        return HStack(spacing: 12) {
            Picker("githubStarLists.aiGrouping.filter.label", selection: $store.filter) {
                filterLabel(.actionable, snapshot: store.snapshot).tag(GitHubStarListAIResultFilter.actionable)
                filterLabel(.suggestions, snapshot: store.snapshot).tag(GitHubStarListAIResultFilter.suggestions)
                filterLabel(.applyFailed, snapshot: store.snapshot).tag(GitHubStarListAIResultFilter.applyFailed)
                filterLabel(.applied, snapshot: store.snapshot).tag(GitHubStarListAIResultFilter.applied)
                filterLabel(.all, snapshot: store.snapshot).tag(GitHubStarListAIResultFilter.all)
            }
            .pickerStyle(.segmented)
            .frame(width: 450)

            TextField("githubStarLists.aiGrouping.search.placeholder", text: $store.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)

            Spacer(minLength: 0)

            if store.snapshot.recoverableApplyFailureCount > 0 {
                Button("githubStarLists.aiGrouping.retryRecoverable") {
                    session.retryAllRecoverableApplyFailures()
                }
                .disabled(session.isApplying)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 20)
        // 工具栏高度固定并从左侧开始排版；空结果只影响下方容器，不再把此行垂直居中。
        .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if presentation.snapshot.totalCount == 0 {
                Spacer()
                Button("action.close") { dismiss() }
                Button("githubStarLists.aiGrouping.start") {
                    Task { await session.startManual() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    session.isLoadingContext
                        || session.preparedRepositoryCount == 0
                        || candidateListDisplays.isEmpty
                )
            } else {
                if session.isRunning {
                    Button("githubStarLists.aiGrouping.stop", action: session.stopAnalysis)
                } else if presentation.snapshot.hasContinuableJobs {
                    Button("githubStarLists.aiGrouping.continue", action: session.continueManual)
                }

                if !session.isRunning, !session.isApplying {
                    Button("githubStarLists.aiGrouping.discard.action", role: .destructive) {
                        showDiscardConfirmation = true
                    }
                }

                Spacer()
                Text(String(
                    format: String.l10n("githubStarLists.aiGrouping.selectionSummaryFormat"),
                    presentation.snapshot.selectedRepositoryCount,
                    presentation.snapshot.selectedListCount
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

                Button("action.close") { dismiss() }
                Button("githubStarLists.aiGrouping.applySelected") {
                    showApplyConfirmation = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(presentation.snapshot.selectedRepositoryCount == 0 || session.isApplying)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 58)
    }

    private var candidateListDisplays: [GitHubStarListAIListDisplay] {
        presentation.snapshot.availableLists.filter {
            !$0.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var progressTitleKey: LocalizedStringKey {
        if session.isApplying {
            "githubStarLists.aiGrouping.applying"
        } else if session.isRunning {
            "githubStarLists.aiGrouping.running"
        } else if presentation.snapshot.totalCount > 0,
                  presentation.snapshot.analyzedCount == presentation.snapshot.totalCount {
            "githubStarLists.aiGrouping.status.finished"
        } else {
            "batchAI.panel.paused"
        }
    }

    private var progressStatusIcon: String {
        if session.isApplying { "icloud.and.arrow.up" }
        else if session.isRunning { "sparkles" }
        else if presentation.snapshot.totalCount > 0,
                presentation.snapshot.analyzedCount == presentation.snapshot.totalCount { "checkmark.circle" }
        else { "pause.circle" }
    }

    private func metricButton(
        _ title: LocalizedStringKey,
        value: Int,
        icon: String,
        filter: GitHubStarListAIResultFilter
    ) -> some View {
        Button {
            presentation.filter = filter
        } label: {
            HStack(spacing: 5) {
                Label(title, systemImage: icon)
                Text(value, format: .number)
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private func filterLabel(
        _ filter: GitHubStarListAIResultFilter,
        snapshot: GitHubStarListAIGroupingPresentationSnapshot
    ) -> some View {
        // 单个 Text 让标题和数字成为一个原生 segment，而不是两个可分别命中的子视图。
        Text(verbatim: "\(String.l10n(filter.titleKey))  \(snapshot.count(for: filter).formatted())")
            .monospacedDigit()
    }
}
