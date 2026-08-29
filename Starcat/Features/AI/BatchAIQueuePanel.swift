//
//  BatchAIQueuePanel.swift
//  Starcat
//
//  HOM-52 - 批量标签固定工作区中的进度与审核内容。
//
//  模块职责：
//  - 展示当前批次的总进度、状态统计与单 job 审核列表（可滚动）。
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
    @State private var expandedRepoID: Int64?
    @State private var presentation = BatchAIQueuePresentationStore()

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
    }

    // MARK: - 进度摘要

    private var progressSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(
                format: String.l10n("githubStarLists.aiGrouping.progressFormat"),
                service.finishedCount,
                service.totalCount
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            ProgressView(value: progressFraction)
                .progressViewStyle(.linear)
                .tint(service.failedCount > 0 ? .orange : .accentColor)
            countersRow
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var countersRow: some View {
        HStack(spacing: 18) {
            // 待确认属于已处理但尚未完成审核，不能再计入“成功”造成重复统计。
            counter(label: "batchAI.panel.counter.completed", count: resolvedCompletedCount, color: .green)
            counter(
                label: "batchAI.panel.counter.pendingReview",
                count: service.pendingTagReviewCount,
                color: .accentColor
            )
            counter(label: "batchAI.panel.counter.failed", count: service.failedCount, color: .red)
            counter(label: "batchAI.panel.counter.ignored", count: service.ignoredCount, color: .gray)
            Spacer()
        }
    }

    private func counter(label: LocalizedStringKey, count: Int, color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.caption)
            Text(verbatim: "\(count)").font(.caption.monospacedDigit())
        }
        .foregroundStyle(.secondary)
    }

    // MARK: - 筛选与状态列表

    private var resultToolbar: some View {
        @Bindable var store = presentation
        return HStack(spacing: 8) {
            Picker("githubStarLists.aiGrouping.filter.label", selection: $store.filter) {
                filterLabel("githubStarLists.aiGrouping.filter.tab.actionable", count: actionableCount)
                    .tag(BatchAIResultFilter.actionable)
                filterLabel("batchAI.panel.counter.pendingReview", count: service.pendingTagReviewCount)
                    .tag(BatchAIResultFilter.pendingReview)
                filterLabel("batchAI.panel.counter.failed", count: service.failedCount)
                    .tag(BatchAIResultFilter.failed)
                filterLabel("batchAI.panel.counter.completed", count: resolvedCompletedCount)
                    .tag(BatchAIResultFilter.completed)
                filterLabel("batchAI.panel.counter.ignored", count: service.ignoredCount)
                    .tag(BatchAIResultFilter.ignored)
                filterLabel("general.all", count: service.totalCount)
                    .tag(BatchAIResultFilter.all)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 8)

            TextField("githubStarLists.aiGrouping.search.tab", text: $store.searchText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 160)

            Button("githubStarLists.aiGrouping.retryFailed.tab") {
                service.retryAllFailed()
            }
            .controlSize(.small)
            .fixedSize()
            .disabled(service.failedCount == 0 || service.isCancelling)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48, alignment: .leading)
    }

    private func filterLabel(_ key: LocalizedStringKey, count: Int) -> some View {
        Text(key) + Text(verbatim: " \(count)")
    }

    private var actionableCount: Int {
        max(0, service.totalCount - resolvedCompletedCount - service.ignoredCount)
    }

    private var resolvedCompletedCount: Int {
        max(0, service.completedCount - service.pendingTagReviewCount)
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
                        onToggleExpansion: { toggleExpansion(for: job) },
                        onToggleRepositorySelection: {
                            service.toggleRepoForTagApplication(repoId: job.repoId)
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
        guard job.errorDiagnostic != nil else { return }
        expandedRepoID = expandedRepoID == job.repoId ? nil : job.repoId
    }

    // MARK: - 派生

    private var progressFraction: Double {
        guard service.totalCount > 0 else { return 0 }
        return Double(service.finishedCount) / Double(service.totalCount)
    }

}
