//
//  BatchAIQueuePanel.swift
//  Starcat
//
//  HOM-52 - 批量整理进度浮动面板。
//
//  模块职责：
//  - 展示当前批次的总进度、剩余时间、当前 repo、单 job 状态列表（可滚动）。
//  - 提供暂停 / 继续 / 取消 / 单项重试 / 重试全部 控件。
//  - 完成后允许用户关闭并 reset 队列。
//
//  关键约束：
//  - 状态列表用 ScrollView + LazyVStack 强行限定最大高度 320pt，避免"处理 1000 项时 UI 爆炸"
//    （dong4j 2026-06-06 16:13 评审第 3 条）。
//  - 面板用 .sheet 承载：关闭面板不会停止队列（队列继续在后台跑，再开面板可恢复观察），
//    对应"支持后台继续"验收点。
//  - 区分三档终态视觉：completed=绿色 / ignored=灰色 / failed=红色，搭配文字补充原因。
//  - 失败行置顶；主文案显示用户可读短句，展开区只显示轻量 HTTP 摘要，
//    完整 Request / Response JSON 仅在用户主动复制时读取。
//  - 进度条下方「当前任务」行固定高度占位，避免有/无文案时 sheet 跳动。
//

import SwiftUI

struct BatchAIQueuePanel: View {

    @Bindable var service: BatchAIQueueService

    /// 调用方提供的关闭回调（关闭 sheet）。
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            progressSummary
            Divider()
            jobList
                .frame(minHeight: 200, maxHeight: 320)
            if service.failedCount > 0 {
                Divider()
                failedFooter
            }
        }
        .frame(width: 520)
        .padding(0)
    }

    // MARK: - 顶部 header（标题 + 操作按钮）

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
            Text("batchAI.panel.title")
                .font(.headline)
            Spacer()
            if !service.isFinished, service.isRunning {
                if service.isPaused {
                    Button {
                        service.resume()
                    } label: {
                        Label("batchAI.panel.resume", systemImage: "play.fill")
                            .labelStyle(.iconOnly)
                    }
                    .help("batchAI.panel.resume")
                } else {
                    Button {
                        service.pause()
                    } label: {
                        Label("batchAI.panel.pause", systemImage: "pause.fill")
                            .labelStyle(.iconOnly)
                    }
                    .help("batchAI.panel.pause")
                }
                Button(role: .destructive) {
                    service.cancel()
                } label: {
                    Label("batchAI.panel.cancel", systemImage: "stop.fill")
                        .labelStyle(.iconOnly)
                }
                .help("batchAI.panel.cancel")
                // 用户已经点过取消但 in-flight job 还没跑完时禁用，避免重复点击让人困惑。
                .disabled(service.isCancelling)
            }
            SheetCloseButton(
                action: {
                    if service.isFinished {
                        service.reset()
                    }
                    onClose()
                },
                iconFont: .system(size: 16, weight: .medium),
                frameSize: 26
            )
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
        } else if let currentId = service.currentJobId,
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

    // MARK: - 状态列表（可滚动）

    private var jobList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(displayedJobs) { job in
                    JobRow(job: job, onRetry: {
                        service.retry(jobId: job.repoId)
                    })
                    Divider()
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
    }

    /// 失败置顶，组内保持原队列相对顺序，方便用户先处理问题项。
    private var displayedJobs: [BatchAIJob] {
        let failed = service.jobs.filter { $0.status == .failed }
        let others = service.jobs.filter { $0.status != .failed }
        return failed + others
    }

    // MARK: - 失败底栏

    private var failedFooter: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(String(format: String.l10n("batchAI.panel.failedSummaryFormat"), service.failedCount))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("batchAI.panel.retryAll") {
                service.retryAllFailed()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.08))
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

// MARK: - JobRow

/// 单 job 行：图标 + repo 名 + 状态文本 + 右侧 retry 按钮（仅 failed 显示）。
///
/// 性能：用 LazyVStack 懒加载，行内只渲染轻量元素（无 markdown / 图像）。
/// 大批次（1000+）滚动时也只渲染可视行，不会爆 CPU。
/// 失败行默认只显示短文案；有诊断详情时才露出「查看详情」折叠区。
private struct JobRow: View {
    let job: BatchAIJob
    let onRetry: () -> Void

    @State private var isDiagnosticExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon
                .frame(width: 16, height: 16)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: job.repoFullName)
                    .font(.subheadline.monospaced())
                    .lineLimit(1)
                if let detail = detailText {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(isDiagnosticExpanded ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if job.status == .failed, let diagnostic = expandableDiagnostic {
                    diagnosticDisclosure(diagnostic)
                }
            }

            Spacer(minLength: 6)

            if job.status == .failed {
                Button {
                    onRetry()
                } label: {
                    Text("batchAI.panel.retry")
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func diagnosticDisclosure(_ diagnostic: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                isDiagnosticExpanded.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(isDiagnosticExpanded ? 90 : 0))
                Text(isDiagnosticExpanded ? "batchAI.panel.row.hideDetails" : "batchAI.panel.row.showDetails")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()

        if isDiagnosticExpanded {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: diagnostic)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                // 展开区只渲染短诊断；完整 Request / Response JSON 到用户点击复制时才读取。
                // 图标与文案固定占位，避免反馈态撑缩 sheet。
                CopyFeedbackButton(
                    providesContent: { copyableFailureReport },
                    tooltip: "batchAI.panel.row.copyDetails"
                ) { didCopy in
                    HStack(spacing: 4) {
                        Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                            .font(.system(size: 11, weight: .regular))
                            .frame(width: 12, height: 12)
                            .foregroundStyle(didCopy ? Color.green : .secondary)
                            .contentTransition(.symbolEffect(.replace))
                        ZStack(alignment: .leading) {
                            // 用更长的「复制详情」撑开宽度，避免切到「已复制」时整行收缩。
                            Text("batchAI.panel.row.copyDetails")
                                .font(.caption)
                                .hidden()
                            Text(didCopy ? "batchAI.panel.row.copiedDetails" : "batchAI.panel.row.copyDetails")
                                .font(.caption)
                                .foregroundStyle(didCopy ? Color.green : .secondary)
                        }
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    /// 剪贴板内容：短文案 + 完整诊断；payload 不参与上方展开区的 Text 渲染。
    private var copyableFailureReport: String {
        BatchAIQueueService.copyableFailureReport(
            repoFullName: job.repoFullName,
            message: failureMessage,
            diagnostic: job.copyDiagnostic ?? job.errorDiagnostic
        )
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch job.status {
        case .queued:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        case .processing:
            ProgressView()
                .controlSize(.small)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .ignored:
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.gray)
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }

    /// 副标题：根据状态拼接（已应用标签 / 被忽略的标签 / 错误信息）。
    private var detailText: String? {
        switch job.status {
        case .queued:
            return nil
        case .processing:
            return String.l10n("batchAI.panel.row.processing")
        case .completed:
            if !job.appliedTagNames.isEmpty {
                let tagsStr = job.appliedTagNames.prefix(5).joined(separator: ", ")
                return String(format: String.l10n("batchAI.panel.row.appliedTagsFormat"), tagsStr)
            }
            return job.didGenerateSummary
                ? String.l10n("batchAI.panel.row.summaryOnly")
                : String.l10n("batchAI.panel.row.completedNoTags")
        case .ignored:
            let names = job.ignoredTagsBelowThreshold.prefix(3).map { suggestion in
                "\(suggestion.name)(\(Int((suggestion.confidence * 100).rounded()))%)"
            }.joined(separator: ", ")
            return String(format: String.l10n("batchAI.panel.row.ignoredFormat"), names)
        case .failed:
            return failureMessage
        }
    }

    /// 每次渲染都从结构化失败重新查表，应用语言切换后不会残留失败发生时的旧语言。
    private var failureMessage: String {
        job.failure?.localizedMessage ?? String.l10n("batchAI.panel.row.failedUnknown")
    }

    /// 仅当诊断与短文案不同时才提供展开入口。
    private var expandableDiagnostic: String? {
        guard let diagnostic = job.errorDiagnostic?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !diagnostic.isEmpty
        else { return nil }
        let short = failureMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard diagnostic != short else { return nil }
        return diagnostic
    }
}
