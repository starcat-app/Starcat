//
//  BatchAIQueuePanel.swift
//  Starcat
//
//  HOM-52 - 批量标签固定工作区中的进度与审核内容。
//
//  模块职责：
//  - 展示当前批次的总进度、互斥状态 Tab 与单 job 审核列表（可滚动）。
//  - 提供单项与批量重试；暂停、取消、批量应用与关闭操作由固定工作区外壳统一承载。
//
//  关键约束：
//  - 状态列表每次只投影 100 条并渐进加载；完整选择与任务状态仍保留在 Service。
//  - 内容由固定 AppKit sheet 承载：关闭窗口不会停止队列（队列继续在后台跑，再开窗口可恢复观察），
//    对应"支持后台继续"验收点。
//  - 区分三档终态视觉：completed=绿色 / ignored=灰色 / failed=红色，搭配文字补充原因。
//  - 失败行置顶；主文案显示用户可读短句，展开区只显示轻量 HTTP 摘要，
//    完整 Request / Response JSON 仅在用户主动复制时读取。
//

import SwiftUI

struct BatchAIQueuePanel: View {

    @Bindable var service: BatchAIQueueService
    let onFilterChange: (BatchAIResultFilter) -> Void
    @State private var expandedRepoID: Int64?
    @State private var presentation = BatchAIQueuePresentationStore()
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(spacing: 0) {
            progressSummary
            Divider()
            resultToolbar
            Divider()
            jobList
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            presentation.synchronizeImmediately(from: service)
        }
        .onChange(of: service.presentationRevision) { _, _ in
            presentation.scheduleSynchronize(from: service)
        }
        .onChange(of: presentation.filter) { _, newValue in
            // 失败/已忽略的勾选只在单一 Tab 内有效；切换 Tab 清空，避免跨语义误操作。
            service.clearBulkActionSelection()
            onFilterChange(newValue)
        }
    }

    // MARK: - 进度摘要

    private var progressSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(
                format: String.l10n("githubStarLists.aiGrouping.progressFormat"),
                service.finishedCount,
                service.totalCount
            ))
            .font(interfaceScale.font(.caption))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            ProgressView(value: progressFraction)
                .progressViewStyle(.linear)
                .tint(service.failedCount > 0 ? .orange : .accentColor)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - 筛选与状态列表

    private var resultToolbar: some View {
        @Bindable var store = presentation
        return HStack(spacing: 8) {
            Picker("githubStarLists.aiGrouping.filter.label", selection: $store.filter) {
                filterLabel(
                    "githubStarLists.aiGrouping.filter.tab.actionable",
                    count: store.count(for: .actionable)
                )
                    .tag(BatchAIResultFilter.actionable)
                filterLabel("batchAI.panel.counter.pendingReview", count: store.count(for: .pendingReview))
                    .tag(BatchAIResultFilter.pendingReview)
                filterLabel("batchAI.panel.counter.completed", count: store.count(for: .completed))
                    .tag(BatchAIResultFilter.completed)
                filterLabel("batchAI.panel.counter.failed", count: store.count(for: .failed))
                    .tag(BatchAIResultFilter.failed)
                filterLabel("batchAI.panel.counter.ignored", count: store.count(for: .ignored))
                    .tag(BatchAIResultFilter.ignored)
                filterLabel("general.all", count: store.count(for: .all))
                    .tag(BatchAIResultFilter.all)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 8)

            TextField("githubStarLists.aiGrouping.search.tab", text: $store.searchText)
                .textFieldStyle(.roundedBorder)
                .font(interfaceScale.font(.caption))
                .controlSize(.small)
                .frame(width: 160)

            if store.filter == .failed {
                Button("githubStarLists.aiGrouping.retryFailed.tab") {
                    Task { await service.retryAllFailures() }
                }
                .controlSize(.small)
                .fixedSize()
                // 暂停态允许批量重试：重试会重新入队并自动恢复运行，与仓库分组窗口语义一致。
                .disabled(
                    store.count(for: .failed) == 0
                        || service.isCancelling
                        || (service.isRunning && !service.isPaused)
                        || service.isApplyingSuggestedTags
                )
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48, alignment: .leading)
    }

    private func filterLabel(_ key: LocalizedStringKey, count: Int) -> some View {
        (Text(key) + Text(verbatim: " \(count.formatted(.number.locale(locale)))"))
            .monospacedDigit()
    }

    private var jobList: some View {
        ZStack {
            if presentation.visibleJobs.isEmpty {
                if presentation.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView(
                        "githubStarLists.aiGrouping.results.empty",
                        systemImage: "tray",
                        description: Text("githubStarLists.aiGrouping.results.empty.help")
                    )
                } else {
                    ContentUnavailableView.search(text: presentation.searchText)
                }
            } else {
                List(Array(presentation.visibleJobs.enumerated()), id: \.element.id) { rowIndex, job in
                    BatchAITagReviewRow(
                        job: job,
                        rowIndex: rowIndex,
                        isExpanded: expandedRepoID == job.repoId,
                        isRepositorySelected: service.isRepoSelectedForTagApplication(repoId: job.repoId),
                        showsBulkActionCheckbox: showsBulkActionCheckboxes,
                        isBulkActionSelected: service.bulkActionRepoIDs.contains(job.repoId),
                        onToggleExpansion: { toggleExpansion(for: job) },
                        onToggleRepositorySelection: {
                            service.toggleRepoForTagApplication(repoId: job.repoId)
                        },
                        onToggleBulkActionSelection: {
                            service.toggleRepoForBulkAction(repoId: job.repoId, filter: presentation.filter)
                        },
                        onToggleTag: {
                            service.toggleSuggestedTag(repoId: job.repoId, suggestionID: $0)
                        },
                        onSelectAll: { service.selectAllSuggestedTags(repoId: job.repoId) },
                        onClearSelection: { service.clearSuggestedTagSelection(repoId: job.repoId) },
                        onApply: {
                            Task { await service.applySelectedSuggestedTags(repoId: job.repoId) }
                        },
                        onIgnore: { service.ignoreSuggestedTags(repoId: job.repoId) },
                        onRetryGeneration: { service.retry(jobId: job.repoId) }
                    )
                    .automaticListPagination(
                        appearingIndex: rowIndex,
                        visibleItemCount: presentation.visibleJobs.count,
                        loadedItemCount: presentation.visibleJobs.count,
                        hasMore: presentation.canLoadMore,
                        isLoading: false,
                        identity: "batch-ai-\(presentation.filter.rawValue)-\(presentation.searchText)"
                    ) {
                        presentation.loadMore()
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toggleExpansion(for job: BatchAIJob) {
        guard canExpand(job) else { return }
        expandedRepoID = expandedRepoID == job.repoId ? nil : job.repoId
    }

    private func canExpand(_ job: BatchAIJob) -> Bool {
        if job.errorDiagnostic != nil { return true }
        if case .failed = job.tagReviewState { return true }
        return false
    }

    // MARK: - 派生

    /// 支持批量动作勾选的 Tab；待确认/全部沿用批量应用勾选，待处理/已完成不参与批量选择。
    private var showsBulkActionCheckboxes: Bool {
        presentation.filter == .failed || presentation.filter == .ignored
    }

    private var progressFraction: Double {
        guard service.totalCount > 0 else { return 0 }
        return Double(service.finishedCount) / Double(service.totalCount)
    }

}
