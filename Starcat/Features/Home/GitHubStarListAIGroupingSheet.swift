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
    let onApplied: @MainActor () async -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.locale) private var locale
    @Environment(AppDependencies.self) private var dependencies
    @State private var presentation = GitHubStarListAIGroupingPresentationStore()
    @State private var showApplyConfirmation = false
    @State private var showDiscardConfirmation = false
    /// 新建分组挂在本窗口根上，避免 Preflight 再 nested 一层；macOS nested sheet 会误触发父视图 onDisappear。
    @State private var showCreateGroupSheet = false
    /// nested Sheet 可能让父内容重复触发 onAppear；首帧事件每次窗口生命周期只记一次。
    @State private var hasMarkedFirstFrame = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        // 固定窗口：min/max 同值，避免 macOS sheet 按内容把窗口撑出屏幕。
        .frame(minWidth: 960, maxWidth: 960, minHeight: 640, maxHeight: 640)
        .clipped()
        .onAppear {
            guard !hasMarkedFirstFrame else { return }
            hasMarkedFirstFrame = true
            PerformanceTracer.shared.mark(.gitHubStarListAIGroupingFirstFrame)
        }
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
        .sheet(isPresented: $showCreateGroupSheet) {
            GitHubStarListEditorSheet(
                list: nil,
                service: dependencies.githubStarListSyncService,
                onSaved: {
                    await session.reloadListsAndRules()
                    session.onMembershipsChanged?()
                }
            )
            .onAppear {
                PerformanceTracer.shared.mark(.gitHubStarListCreateFirstFrame)
            }
            // 与侧栏新建分组同一口径。不要套 appSheetRootEnvironment：嵌套 sheet 再注入整棵
            // AppDependencies 会让首帧变慢，而且编辑器并不读取那些环境对象。
            .appLocaleEnvironment()
            .starcatAnimationOverride()
            .environment(\.starcatInterfaceScale, interfaceScale)
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
                .font(interfaceScale.font(.iconLarge))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("githubStarLists.aiGrouping.title")
                    .font(interfaceScale.font(.workspaceTitle))
                Text("githubStarLists.aiGrouping.subtitle.compact")
                    .font(interfaceScale.font(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // 开始页没有分析任务，不展示暂停/进行中 pill，避免和原型里误放到预览稿的状态抢标题。
            if presentation.snapshot.totalCount > 0 {
                Label(progressTitleKey, systemImage: progressStatusIcon)
                    .font(interfaceScale.font(.captionStrong))
                    .foregroundStyle(progressStatusTint)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(progressStatusTint.opacity(0.18), in: .capsule)
            }
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
                session: session,
                showCreateGroupSheet: $showCreateGroupSheet
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
                filter: presentation.filter,
                availableLists: presentation.snapshot.availableLists,
                hasMore: presentation.canLoadMore,
                onToggleList: session.toggleSelection,
                onSelectAllSuggestions: session.selectAllSuggestions,
                onClearSelection: session.clearSelection,
                onApply: { session.applySelected(repoIDs: Set([$0])) },
                onIgnore: session.ignore,
                onRetryAnalysis: session.retryAnalysis,
                onRetryApply: session.retryApply,
                onLoadMore: presentation.loadMore
            )
        }
    }

    private var progressSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(
                format: String.l10n("githubStarLists.aiGrouping.progressFormat"),
                locale: locale,
                presentation.snapshot.analyzedCount,
                presentation.snapshot.totalCount
            ))
            .font(interfaceScale.font(.caption))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            ProgressView(
                value: Double(presentation.snapshot.analyzedCount),
                total: Double(max(presentation.snapshot.totalCount, 1))
            )
            HStack(spacing: 18) {
                metricButton(
                    "githubStarLists.aiGrouping.metric.pendingReview",
                    value: presentation.snapshot.suggestionCount,
                    icon: "circle.fill",
                    tint: .accentColor,
                    filter: .suggestions
                )
                metricButton(
                    "githubStarLists.aiGrouping.metric.noMatch",
                    value: presentation.snapshot.noMatchCount,
                    icon: "minus.circle",
                    tint: .secondary,
                    filter: .noMatch
                )
                metricButton(
                    "githubStarLists.aiGrouping.filter.analysisFailed",
                    value: presentation.snapshot.analysisFailedCount,
                    icon: "exclamationmark.triangle.fill",
                    tint: .orange,
                    filter: .analysisFailed
                )
                metricButton(
                    "githubStarLists.aiGrouping.filter.applyFailed",
                    value: presentation.snapshot.applyFailedCount,
                    icon: "exclamationmark.circle.fill",
                    tint: .red,
                    filter: .applyFailed
                )
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var resultToolbar: some View {
        @Bindable var store = presentation
        return HStack(spacing: 8) {
            Picker("githubStarLists.aiGrouping.filter.label", selection: $store.filter) {
                filterLabel(.actionable, snapshot: store.snapshot).tag(GitHubStarListAIResultFilter.actionable)
                filterLabel(.suggestions, snapshot: store.snapshot).tag(GitHubStarListAIResultFilter.suggestions)
                filterLabel(.applyFailed, snapshot: store.snapshot).tag(GitHubStarListAIResultFilter.applyFailed)
                filterLabel(.applied, snapshot: store.snapshot).tag(GitHubStarListAIResultFilter.applied)
                filterLabel(.all, snapshot: store.snapshot).tag(GitHubStarListAIResultFilter.all)
                filterLabel(.automaticallyIgnored, snapshot: store.snapshot).tag(GitHubStarListAIResultFilter.automaticallyIgnored)
                filterLabel(.ignored, snapshot: store.snapshot).tag(GitHubStarListAIResultFilter.ignored)
            }
            .pickerStyle(.segmented)
            .controlSize(.regular)
            .labelsHidden()
            // 分段控件按内容宽度贴左，不要拉满整行把每个 tab 撑出大块留白。
            .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 8)

            TextField("githubStarLists.aiGrouping.search.tab", text: $store.searchText)
                .textFieldStyle(.roundedBorder)
                .font(interfaceScale.font(.caption))
                .controlSize(.small)
                .frame(width: 128)
                .layoutPriority(1)

            Button("githubStarLists.aiGrouping.retryFailed.tab") {
                session.retryAllRecoverableApplyFailures()
            }
            .controlSize(.small)
            .fixedSize()
            .layoutPriority(1)
            .disabled(session.isApplying || store.snapshot.recoverableApplyFailureCount == 0)
        }
        .padding(.horizontal, 20)
        // 工具栏高度固定并从左侧开始排版；空结果只影响下方容器，不再把此行垂直居中。
        .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if presentation.snapshot.totalCount == 0 {
                Label("githubStarLists.aiGrouping.privacy", systemImage: "lock.shield")
                    .font(interfaceScale.font(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("action.close") { dismiss() }
                Button("githubStarLists.aiGrouping.start") {
                    Task { await session.startManual() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    session.isLoadingContext
                        || session.isStartingManual
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
                    locale: locale,
                    presentation.snapshot.selectedRepositoryCount,
                    presentation.snapshot.selectedListCount
                ))
                .font(interfaceScale.font(.caption))
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
        .padding(.vertical, 10)
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

    private var progressStatusTint: Color {
        if session.isApplying || session.isRunning {
            .accentColor
        } else if presentation.snapshot.totalCount > 0,
                  presentation.snapshot.analyzedCount == presentation.snapshot.totalCount {
            .green
        } else {
            .orange
        }
    }

    private func metricButton(
        _ title: LocalizedStringKey,
        value: Int,
        icon: String,
        tint: Color,
        filter: GitHubStarListAIResultFilter
    ) -> some View {
        Button {
            presentation.filter = filter
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(interfaceScale.font(.captionSmall))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(title)
                Text(value, format: .number.locale(locale))
                    .monospacedDigit()
            }
            .font(interfaceScale.font(.caption))
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
        Text(verbatim: "\(String.l10n(filter.tabTitleKey))  \(snapshot.count(for: filter).formatted(.number.locale(locale)))")
            .monospacedDigit()
    }
}
