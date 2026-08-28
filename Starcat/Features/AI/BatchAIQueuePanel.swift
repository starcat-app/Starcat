//
//  BatchAIQueuePanel.swift
//  Starcat
//
//  HOM-52 - 批量标签固定工作区中的进度与审核内容。
//
//  模块职责：
//  - 展示当前批次的总进度、剩余时间、当前 repo、单 job 状态列表（可滚动）。
//  - 提供单项与批量重试；暂停、取消、批量应用与关闭操作由固定工作区外壳统一承载。
//
//  关键约束：
//  - 状态列表每次只投影 100 条并渐进加载；完整选择与任务状态仍保留在 Service。
//  - 内容由固定 AppKit sheet 承载：关闭窗口不会停止队列（队列继续在后台跑，再开窗口可恢复观察），
//    对应"支持后台继续"验收点。
//  - 区分三档终态视觉：completed=绿色 / ignored=灰色 / failed=红色，搭配文字补充原因。
//  - 失败行置顶；主文案显示用户可读短句，展开区只显示轻量 HTTP 摘要，
//    完整 Request / Response JSON 仅在用户主动复制时读取。
//  - 进度条下方「当前任务」行固定高度占位，避免有/无文案时 sheet 跳动。
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
            HStack(alignment: .center, spacing: 6) {
                Text(String(format: String.l10n("batchAI.panel.progressFormat"), service.finishedCount, service.totalCount))
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                if service.isCancelling {
                    Text("batchAI.panel.cancelling")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.red.opacity(0.18), in: Capsule())
                        .foregroundStyle(.red)
                } else if service.isPaused {
                    Text("batchAI.panel.paused")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.yellow.opacity(0.2), in: Capsule())
                        .foregroundStyle(.orange)
                }
                Spacer()
                if let remaining = service.estimatedTimeRemaining, !service.isFinished, remaining > 0 {
                    Label {
                        Text(formattedRemaining(remaining))
                            .font(.caption.monospacedDigit())
                    } icon: {
                        Image(systemName: "clock")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: progressFraction)
                .progressViewStyle(.linear)
                .tint(service.failedCount > 0 ? .orange : .accentColor)
            // 固定高度占位：有/无「当前任务」文案时都占同一行，避免 sheet 上下跳动。
            currentJobLabel
                .frame(height: Self.currentJobLabelHeight, alignment: .leading)
            countersRow
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    /// caption + small ProgressView 的稳定行高；必须与 `currentJobLabel` 占位一致。
    private static let currentJobLabelHeight: CGFloat = 18

    @ViewBuilder
    private var currentJobLabel: some View {
        if service.isCancelling {
            // 取消已传给当前 AI 调用；这里只展示短暂的状态收口，不再误导为等待正常完成。
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("batchAI.panel.cancelling")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else if service.processingJobIDs.count > 1 {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(String(
                    format: String.l10n("batch.progress.processingFormat"),
                    service.finishedCount + service.processingJobIDs.count,
                    service.totalCount
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        } else if let currentId = service.processingJobIDs.first,
           let currentJob = service.jobs.first(where: { $0.repoId == currentId }) {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(String(format: String.l10n("batchAI.panel.currentFormat"), currentJob.repoFullName))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } else if service.hasPendingTagReview {
            Label("batchAI.panel.review.pending", systemImage: "checklist")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                .lineLimit(1)
        } else if service.isFinished {
            Label("batchAI.panel.finished", systemImage: "checkmark.seal.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .lineLimit(1)
        } else {
            // 与上方同结构的隐形占位，保证暂停 / 间歇态行高不塌。
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(verbatim: " ")
                    .font(.caption)
                    .lineLimit(1)
            }
            .accessibilityHidden(true)
            .opacity(0)
        }
    }

    private var countersRow: some View {
        HStack(spacing: 14) {
            counter(label: "batchAI.panel.counter.completed", count: service.completedCount, color: .green)
            if service.ignoredCount > 0 {
                counter(label: "batchAI.panel.counter.ignored", count: service.ignoredCount, color: .gray)
            }
            if service.failedCount > 0 {
                counter(label: "batchAI.panel.counter.failed", count: service.failedCount, color: .red)
            }
            if service.pendingTagReviewCount > 0 {
                counter(
                    label: "batchAI.panel.counter.pendingReview",
                    count: service.pendingTagReviewCount,
                    color: .accentColor
                )
            }
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
        guard !job.suggestedTags.isEmpty || job.errorDiagnostic != nil else { return }
        expandedRepoID = expandedRepoID == job.repoId ? nil : job.repoId
    }

    // MARK: - 派生

    private var progressFraction: Double {
        guard service.totalCount > 0 else { return 0 }
        return Double(service.finishedCount) / Double(service.totalCount)
    }

    private func formattedRemaining(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return String(format: String.l10n("batchAI.panel.remainingSecondsFormat"), Int(seconds.rounded()))
        }
        let minutes = Int((seconds / 60).rounded())
        return String(format: String.l10n("batchAI.panel.remainingMinutesFormat"), minutes)
    }
}
